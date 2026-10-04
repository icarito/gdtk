# SPEC — Salidas múltiples del compositor embebido y extensión remota

Estado: propuesta implementable. Sustituye el experimento incorrecto que crea
`HEADLESS-*` en el sway anfitrión cuando gdtk actúa como emisor.

## 1. Problema observado

La sesión tiene dos niveles de composición:

```text
sway anfitrión
└─ godot-gdtk fullscreen
   └─ WaylandCompositor embebido
      └─ ventanas del usuario
```

Crear una salida headless en sway amplía el escritorio **exterior**, pero las
ventanas viven en el compositor embebido. El resultado es una salida válida y un
stream UDP válido que sólo contienen un workspace vacío. Mover el puntero o una
ventana dentro de gdtk nunca puede cruzar hacia esa salida exterior.

La extensión real debe existir en el mismo espacio de composición que las
ventanas: `WaylandCompositor`. El shell debe administrar todas las salidas, y gvd
debe capturar el framebuffer compuesto de la salida remota.

## 2. Objetivos

1. Una instancia de gdtk administra una salida interna principal y cero o más
   salidas secundarias.
2. Cada salida tiene geometría, escala, workspace, fondo y framebuffer propios.
3. Una ventana puede moverse entre salidas cruzando un borde o por una acción
   explícita.
4. El Frame, Hogar, Grupo, Vecindario, OSD y overlays globales se pintan **sólo en
   la salida principal**, salvo que una spec posterior indique otra cosa.
5. Una salida secundaria remota puede capturarse y enviarse con gvd sin crear un
   output en sway ni revelar la salida principal.
6. El mismo modelo debe admitir después monitores físicos locales: cambia el
   destino de presentación, no el modelo de ventanas ni workspaces.

## 3. No objetivos del primer corte

- Duplicar/espejar la salida principal.
- Un Frame por monitor.
- Paneles o fondos ejecutados como clientes `layer-shell` independientes por
  salida. El shell sigue siendo dueño de la presentación.
- Acelerar de entrada la captura con dmabuf/zero-copy. El primer corte puede usar
  readback acotado; debe medirlo y permitir reemplazarlo sin cambiar el contrato.
- Mover una ventana entre dos procesos de Godot o dos compositores distintos.
- Hacer que Deskflow controle la salida remota. La extensión pertenece al mismo
  seat local; el receptor sólo muestra video.

## 4. Modelo de salidas

`Host` conserva el modelo durante una recarga transaccional. La fuente única es
un diccionario de descriptores:

```gdscript
{
  "primary": {
    "id": "primary",
    "kind": "physical",
    "rect": Rect2(0, 0, 1920, 1080),
    "scale": 1.0,
    "primary": true,
    "enabled": true,
    "target": "main_viewport"
  },
  "remote:<hid>": {
    "id": "remote:<hid>",
    "kind": "remote",
    "rect": Rect2(0, 1080, 1280, 800),
    "scale": 1.0,
    "primary": false,
    "enabled": true,
    "target": "offscreen",
    "peer": "<hid>",
    "direction": "south"
  }
}
```

Reglas:

- Siempre existe exactamente una salida `primary=true`.
- `rect` usa coordenadas lógicas globales del compositor embebido.
- Las salidas no se solapan. Norte/sur/este/oeste se anclan a la principal; una
  fase posterior puede permitir una grilla libre.
- Cada salida tiene un workspace activo. Una ventana pertenece a un workspace y
  éste pertenece a una salida; no se duplican ventanas entre salidas.
- El estado persistente guarda disposición y asignaciones estables, pero una
  salida `remote:<hid>` sólo está habilitada mientras la sesión gvd esté viva.
- Al retirar una salida, todas sus ventanas vuelven a la principal antes de
  destruir su framebuffer. Nunca quedan invisibles ni huérfanas.

El modelo puro vive fuera de `shell.gd` (por ejemplo
`shell/output_layout.gd`) y resuelve validación, anclaje, cruce de bordes,
selección de destino y retorno de ventanas. I/O, captura y procesos no entran en
ese módulo.

## 5. Contrato Wayland del compositor embebido

`modules/wayland/` deja de anunciar un único `wl_output` implícito y mantiene una
colección explícita de outputs lógicos. Por output:

- `wl_output` global con nombre estable, tamaño lógico, modo, escala y
  `done`;
- ubicación dentro del layout global;
- lista de surfaces actualmente presentadas;
- señal de frame independiente y reloj común monotónico;
- estado `enabled/disabled` y motivo de retirada.

API mínima C propuesta (nombres finales pueden adaptarse al estilo del módulo):

```c
int wl_server_output_add(wl_server *s, const char *name,
    int x, int y, int width, int height, int scale, int primary);
int wl_server_output_configure(wl_server *s, int output_id,
    int x, int y, int width, int height, int scale);
void wl_server_output_remove(wl_server *s, int output_id);
void wl_server_toplevel_set_output(wl_server *s, int toplevel_id, int output_id);
int wl_server_toplevel_output(wl_server *s, int toplevel_id);
```

Al cambiar una ventana de salida, el servidor emite los `wl_surface.enter` y
`wl_surface.leave` correspondientes. `xdg_toplevel.set_fullscreen(output)` se
honra dentro de la salida solicitada; sin output explícito usa la salida actual.
El tamaño maximizado/fullscreen se calcula contra el rect útil de esa salida, no
contra el viewport principal.

`WaylandCompositor` expone equivalentes GDScript y señales:

```text
output_added(id)
output_changed(id)
output_removed(id)
toplevel_output_changed(toplevel_id, output_id)
```

No se crea un seat por salida. Teclado y puntero forman un único seat y el foco
sigue a la ventana, incluso al cruzar una frontera.

## 6. Responsabilidad del shell

El shell compone cada salida a partir de la misma fuente de ventanas, pero con
un contexto de render independiente:

```text
OutputContext
├─ output_id
├─ viewport / render target
├─ logical_rect
├─ workspace activo
├─ lista z-order de ventanas
├─ ventana enfocada
├─ daño acumulado
└─ presentation_target: main | offscreen | physical
```

### Salida principal

Se presenta en el viewport actual de Godot y conserva:

- fondo y espacio de actividades;
- Hogar, Grupo, Vecindario y Diario;
- Frame y dockapps;
- OSD, exposé global y diálogos del sistema;
- cursor local cuando corresponda.

### Salidas secundarias

Se renderizan en `Viewport` offscreen con fondo y ventanas, pero sin Frame ni
vistas Sugar globales. Sólo muestran:

- el workspace asignado;
- ventanas, diálogos y popups de ese workspace;
- decoraciones de ventana;
- cursor local compuesto en la captura, si está dentro de esa salida.

El Frame no se oculta por coordenadas: directamente no forma parte del árbol de
render de un `OutputContext` secundario. Esto evita filtrarlo accidentalmente al
stream y permite que la resolución remota completa sea área útil.

Los `layer-shell` de aplicaciones se asignan a la salida pedida por el cliente.
En el primer corte, capas `background/bottom` pueden dibujarse en esa salida;
capas `top/overlay` ajenas al shell deben respetar su output y nunca replicarse.

## 7. Ventanas, navegación e input

### Asignación y movimiento

- Una ventana nueva aparece en la salida que contiene el puntero/foco que la
  originó; fallback: principal.
- Arrastrar una ventana a través de un borde confirmado cambia su `output_id` y
  transforma sus coordenadas al espacio de destino.
- Como gdtk usa ventanas internas, el cruce lo decide el modelo del shell; no se
  delega en sway.
- Acción explícita en el menú de ventana: `Mover a pantalla principal` o
  `Mover a <equipo/monitor>`.
- Una ventana fullscreen no cruza por arrastre hasta salir de fullscreen.

### Puntero

El shell mantiene una posición global y deriva `(output_id, posición local)`.
Al cruzar un borde:

1. actualiza salida bajo el puntero;
2. limpia el foco de la surface anterior;
3. hit-test en el nuevo `OutputContext`;
4. reenvía enter/motion a la nueva surface;
5. invalida ambos cursores/framebuffers.

Durante una extensión remota, el puntero sigue siendo local al emisor. El
receptor ve el cursor compuesto, pero no inyecta input. Pointer lock queda
confinado a la salida donde se adquirió y bloquea el cruce hasta liberarse.

### Teclado y foco

Hay un solo foco de teclado global. Cambiar de salida por puntero o acción enfoca
la ventana correspondiente. El Frame permanece invocable en la principal; al
abrirlo mientras el foco está en una secundaria, se muestra en la principal sin
mover automáticamente la ventana enfocada.

## 8. Captura de una salida interna

gvd gana un backend explícito `gdtk`; no debe inferir que
`XDG_CURRENT_DESKTOP=gdtk` equivale al sway anfitrión.

Flujo:

```text
acción Extender
→ Host crea output remote:<hid>
→ shell crea OutputContext offscreen 1280×800
→ receptor remoto confirma escucha
→ gvd send --capture gdtk --output remote:<hid>
→ broker entrega sólo frames dañados + keepalive
→ encoder H.264/UDP existente
```

El contrato entre Godot y gvd es un socket Unix privado bajo
`$XDG_RUNTIME_DIR/gdtk/`, con permisos `0600`, no un puerto TCP. Handshake mínimo:

```json
{"v":1,"op":"open","output":"remote:<hid>","format":"BGRx","fps":30}
{"v":1,"ok":true,"width":1280,"height":800,"stride":5120}
```

Después del handshake, los frames viajan por fd/memoria compartida, no como JSON
ni base64. Cada frame lleva secuencia, timestamp monotónico, tamaño, stride y
rectángulos de daño. Debe existir backpressure: si el encoder está atrasado se
descartan frames intermedios y se conserva el más nuevo; nunca se bloquea el hilo
de render.

MVP permitido: doble buffer compartido y copia/readback a un worker limitado a
30 fps. Objetivo posterior: exportar el render target por dmabuf y evitar copia.
La interfaz del broker no cambia entre ambos.

La captura incluye fondo, ventanas, decoraciones, popups y cursor de esa salida.
Excluye deliberadamente Frame, OSD global y cualquier contenido de la salida
principal. Si el output desaparece, el broker envía EOF con razón y gvd termina
limpiamente.

No implementar `zwlr_screencopy_manager_v1` fingiendo capturar el output hasta
que el framebuffer compuesto sea realmente la fuente. El broker privado es el
MVP; screencopy estándar puede adaptarse encima después.

## 9. Ciclo de vida de “Extender”

### Inicio transaccional

1. Validar peer, autorización y resolución solicitada.
2. Abrir/confirmar receptor remoto.
3. Crear descriptor `remote:<hid>` deshabilitado.
4. Crear output Wayland y `OutputContext`; esperar primer framebuffer válido.
5. Abrir broker y encoder.
6. Habilitar el output en el layout y recién entonces marcar la sesión `active`.

Si cualquier paso falla, se deshace en orden inverso y la UI muestra el error
real. No se deja una pantalla negra navegable.

### Detención

1. Impedir nuevas asignaciones al output.
2. Mover sus ventanas a la principal, conservando orden y tamaño razonable.
3. Mover puntero/foco a la principal si estaban en la salida retirada.
4. Cerrar encoder/broker/receptor.
5. Retirar output Wayland y `OutputContext`.
6. Publicar estado `stopped`.

Caída de red o receptor ejecuta la misma retirada tras una ventana breve de
reconexión. La salida no puede quedar activa indefinidamente sin consumidor.

## 10. Multi-monitor físico posterior

El modelo anterior es deliberadamente independiente del destino:

| Destino | `OutputContext` | Presentación |
|---|---|---|
| pantalla principal | viewport actual | ventana fullscreen de Godot |
| monitor físico adicional | viewport secundario | ventana borderless colocada por el anfitrión |
| pantalla remota | viewport offscreen | broker de captura → gvd |

Cuando Godot/FRT soporte varias ventanas nativas de presentación, cada monitor
físico recibe un `OutputContext`. El Frame continúa sólo en la salida marcada
principal. Desconectar un monitor usa exactamente la misma política de retorno de
ventanas que detener una salida remota.

No se considera soporte multi-monitor real si sólo se crean outputs en sway sin
vincularlos a outputs del compositor embebido.

## 11. Rendimiento y scheduling

- El hilo de render nunca espera al encoder, red, socket o readback anterior.
- Cada salida mantiene daño independiente. Una secundaria sin cambios sólo emite
  keepalive a la frecuencia mínima que requiera gvd.
- `wl_surface.frame` se responde según visibilidad en cualquier salida; una
  ventana visible en secundaria no puede quedar throttled por no estar en la
  principal.
- Presupuesto MVP para 1280×800@30: medir CPU, GPU, bytes copiados y frames
  descartados. El HUD expone por output `fps_render`, `fps_capture`, `dropped`,
  `readback_ms` y `encoder_queue`.
- Si no se sostiene la frecuencia, se degrada fps antes que bloquear el shell.
- La resolución no cambia silenciosamente. Un resize coordina output, broker,
  encoder y receptor mediante el mecanismo existente de control de tamaño.

## 12. Seguridad y privacidad

- Crear una salida remota requiere acción explícita y peer autorizado.
- El broker sólo acepta al mismo UID y un token efímero entregado por fd o archivo
  `0600`; el token no aparece en argv ni logs.
- El peer nunca elige nombres arbitrarios de outputs ni obtiene acceso a la
  principal.
- Logs identifican la salida por alias humano o id local, sin secretos.
- Al comenzar, la UI dice claramente que sólo será visible lo movido a esa
  pantalla adicional.
- Existe siempre una acción local visible para detener la extensión.

## 13. Compatibilidad y migración

- `gvd --capture wlr --virtual` sigue válido para un sway convencional cuyas apps
  sean clientes directos de sway.
- En una sesión gdtk, `local_emit_backend()` devuelve `gdtk`, nunca `wlr`, cuando
  el broker de outputs internos esté disponible.
- Hasta que el broker anuncie capacidad, “Extender mi escritorio” se muestra
  deshabilitado con una razón honesta. No debe volver a crear `HEADLESS-*` en el
  sway anfitrión.
- `caps --json` añade capacidades versionadas, por ejemplo:

```json
{
  "capture": {"gdtk_outputs": true, "protocol": 1},
  "virtual_output": {"embedded": true, "max": 4}
}
```

La presencia de `SWAYSOCK` no prueba soporte de extensión dentro de gdtk.

## 14. Fases de implementación

### Fase A — honestidad inmediata

- Detectar la sesión anidada y no usar `--virtual` exterior.
- Deshabilitar extensión desde gdtk mientras falte capacidad embedded.
- Test que impida regresión a `backend=wlr + SWAYSOCK` para desktop `gdtk`.

### Fase B — modelo y outputs internos

- `output_layout.gd` puro y tests.
- outputs múltiples en `wl_server`/`WaylandCompositor`.
- asignación de toplevels, enter/leave, maximize/fullscreen por output.
- `OutputContext` principal + secundario en instancia aislada.

### Fase C — composición e input

- render offscreen de fondo/ventanas/popups/decoraciones/cursor;
- Frame exclusivo de principal;
- cruce de puntero y arrastre de ventanas;
- retirada segura con retorno de ventanas.

### Fase D — captura gdtk y gvd

- broker privado con backpressure;
- backend `gdtk` en gvd;
- inicio/detención transaccional y resize;
- métricas y recuperación ante caída.

### Fase E — monitores físicos

- targets nativos adicionales cuando FRT/Godot los soporte;
- hotplug y elección de principal;
- configuración persistente y pruebas con dos monitores reales.

## 15. Verificación obligatoria

Todo e2e corre en una instancia aislada; nunca recarga la sesión principal.

### Modelos puros

- anclaje N/S/E/O sin solapes;
- conversión global/local en bordes;
- mover ventana y puntero entre outputs;
- retirar output devuelve todas las ventanas a principal;
- siempre queda exactamente una principal.

### Protocolo Wayland

- cliente ve dos `wl_output` con nombre, tamaño y escala correctos;
- mover toplevel emite leave/enter en orden;
- maximize/fullscreen usan el tamaño del output destino;
- frame callbacks continúan en ventana visible sólo en secundaria;
- popup y diálogo permanecen en la salida de su raíz.

### Render

- captura de principal contiene Frame;
- captura de secundaria no contiene Frame, Hogar ni OSD;
- fondo, ventana, popup, decoración y cursor sí aparecen en secundaria;
- mover una ventana produce daño y cambio visible en el framebuffer remoto;
- salida vacía muestra su fondo, no negro accidental ni contenido principal.

### E2E bastion → Tengu

1. Tengu abre receptor y confirma tamaño.
2. Bastion crea `remote:<hid>` dentro del compositor embebido; `swaymsg
   get_outputs` **no** gana ningún `HEADLESS-*`.
3. Mover una ventana al borde configurado la quita de la principal y aparece en
   Tengu con movimiento continuo.
4. El Frame permanece visible sólo en bastion.
5. Puntero cruza, se ve remotamente y vuelve; teclado sigue la ventana enfocada.
6. Cortar la sesión devuelve ventana, puntero y foco a bastion.
7. Matar receptor o red produce reconexión acotada y luego retirada limpia.

### Rendimiento

- 1280×800@30 durante 10 minutos sin crecimiento de memoria/fds/threads;
- el shell sigue interactivo durante pérdida de red y encoder lento;
- métricas documentan readback y drops; ningún wait ocurre en render/UI.

## 16. Criterios de aceptación

La funcionalidad está completa cuando:

- una ventana cliente del compositor embebido cruza a una salida secundaria y se
  ve en Tengu;
- esa salida no existe en sway y no contiene Frame;
- detener o perder el vínculo nunca deja ventanas inaccesibles;
- tests prueban output enter/leave, composición, input y lifecycle;
- el camino actual `gdtk → sway HEADLESS` queda eliminado o bloqueado;
- los cambios de engine se compilan y la activación se hace únicamente en un
  corte controlado, conforme a `SPEC-session-continuity.md`.

## 17. Archivos previstos

- `modules/wayland/wl_server.{c,h}`: outputs Wayland, asignación y eventos.
- `modules/wayland/wayland_compositor.{cpp,h}`: API Godot, señales y broker de
  frame/captura.
- `shell/host.gd`: propiedad persistente de outputs y ciclo de vida.
- `shell/output_layout.gd`: modelo puro.
- `shell/shell.gd` y módulos de render/layout: `OutputContext`, composición e
  input por salida.
- `shell/gvd_launch.gd`: selección honesta de backend y lifecycle.
- `tools/gvd/`: backend `gdtk` y transporte de frames.
- `tests/`: modelos, protocolo, render aislado y e2e.

No se implementa esta spec agrandando aún más `shell.gd` con toda la lógica. El
modelo y el render por output deben quedar en módulos separados conforme a
`SPEC-architecture.md` y `plans/tech-debt.md`.
