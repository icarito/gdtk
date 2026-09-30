# SPEC — Applets del Frame (controles independientes tipo Window Maker)

Estado: primer corte implementado y desplegado en Tengu (2026-09-29); Bluetooth,
teclado y enlace siguen especificados para cortes posteriores. Complementa
`SPEC-sugar-frame-blocks.md` (retícula y bordes) y `SPEC-sugar-spatial.md` (el orden
del layout sale de `shell._units()`; el Frame no guarda una segunda copia). Habla sólo
de controles: no cambia navegación, tiling ni cierre de apps.

## Idea

El Frame separa los ítems de ventanas de CPU, MEM, SWP y reloj, antes dibujados
como un bloque fijo. Cada control es un **applet**: un bloque cuadrado con valor y estado, que la
persona **fija, quita y ordena** como los appicons/Dock de Window Maker. Un applet no es
una ventana: comunica su estado aunque su etiqueta no quepa y muestra el nombre completo
al enfocarlo. Sugar ya ponía CPU/memoria en el borde del Frame; gdtk los vuelve ciudadanos
de primera clase y sumables/quitables por la persona.

## Modelo de applet

Usar una lista corta de controles incorporados, cada uno con un `id` estable:
`reloj`, `cpu`, `memoria`, `swap`, `bluetooth`, `teclado`, `deskflow`, `enlace`.
`frame.gd` decide posición, foco y gesto; `sysmon.gd` sigue midiendo CPU/RAM/swap.
Separar código en otro módulo sólo cuando una implementación concreta lo necesite.

### Estados (comunes a todos)

| estado | cuándo | se muestra |
|---|---|---|
| `activo` | encendido/conectado/en uso | valor + ícono/contorno lleno |
| `listo` | disponible sin vínculo | valor + contorno |
| `apagado` | desactivado por la persona | texto atenuado, sin relleno |
| `cambiando` | acción en curso | texto «…»; bloquea re-disparo |
| `sin_dato` | no se pudo medir/consultar | texto «sin dato» |
| `no_disponible` | falta el binario/adaptador | texto breve; sigue siendo removible |
| `error` | la orden falló | último texto conocido + motivo |

Reglas anti-ficción (mismas que el anillo): sin medición no se dibuja barra ni se
estima; no se inventa un valor. El estado se distingue por **contorno, relleno y
texto**, nunca sólo por color.

## Applets

| id | fuente real | primaria | secundaria |
|---|---|---|---|
| `reloj` | `OS.get_time()` (ya en `frame.gd`) | lectura; fecha más adelante | fijar/quitar |
| `cpu` | `/proc/stat` (`sysmon.gd`, 1 s) | lectura de porcentaje; historial más adelante | fijar/quitar |
| `memoria` | `/proc/meminfo` (`sysmon.gd`) | RAM global y porcentaje | fijar/quitar |
| `swap` | `/proc/meminfo` (`sysmon.gd`) | swap global y porcentaje | fijar/quitar |
| `bluetooth` | BlueZ; `blueman-manager` ya instalado en Tengu | abrir gestión de dispositivos | encender/apagar, cuando el estado esté integrado |
| `teclado` | `~/.config/gdtk/keyboard` y `localectl status` | abrir selector de distribución | mostrar variante/opciones |
| `deskflow` | `shell.service_pids` + `_service_running` | prender/apagar (`_toggle_service`) | detalle en Vecindario (cuando exista) |
| `enlace` | `nmcli -t -f TYPE,STATE,CONNECTION dev` | abrir Vecindario | — (sólo indicador) |

- **Wi-Fi no es un applet de control.** Su gestión pertenece a Vecindario
  (`SPEC-sugar-journal-neighborhood.md`). En el Frame sólo puede aparecer el bloque
  `enlace`, **de lectura**, con estado del vínculo y enlace a Vecindario; mientras
  Vecindario no exista, el bloque no se muestra: no se duplica el control en el Frame.
- **Bluetooth sí es local** (radio + periféricos): encender/apagar y ver conectados se
  hace desde el Frame; `blueman-manager` se abre como toplevel, no como vista interna.
- **Teclado**: `session/keyboard.sh` lee `~/.config/gdtk/keyboard`
  (`XKB_DEFAULT_LAYOUT/VARIANT/OPTIONS`) y cae a `localectl`; sway y el compositor
  embebido leen `XKB_DEFAULT_*` al arrancar. `session/sway.conf` no fija `input xkb_*`.
  El selector ofrece sólo distribuciones válidas y escribe este archivo de forma
  atómica, sin aceptar texto de shell arbitrario: el archivo se ejecuta mediante `.`.
  Si se aplica una distribución en vivo a sway, el applet debe indicar que el shell
  embebido puede conservar el mapa anterior. **Límite honesto**: el keymap de los clientes
  del compositor embebido (`modules/wayland/wl_server.c:1253`) y del input remoto
  (`modules/wayland/remote_input.cpp:272`) se compila al arrancar; un cambio en caliente
  puede no alcanzar a las apps internas hasta reiniciar el shell. El applet lo dice; no
  lo oculta.
- **Deskflow**: ya es servicio en `ACTIVITIES` (`shell/shell.gd:12`) con `_toggle_service`
  y `_service_running` (`kill -0`); el applet reusa eso, no inventa un segundo ciclo de
  vida. `recovery.gd` ya persiste `service_pids`, así que su estado sobrevive a un reload.

### Memoria del Frame ≠ anillo de Hogar

- El applet `memoria` mide **memoria global de la máquina** (`/proc/meminfo`), absoluta y
  a 1 Hz, igual que el `sysmon` actual. No es por app.
- El anillo de Hogar mide **memoria por instancia** de actividad, relativa y sujeta a
  atribución real por PID; puede quedar «sin dato» (`SPEC-sugar-resource-ring.md`).
- No comparten escala ni código de dibujo: el Frame nunca se recicla para lo por-app y
  el anillo no duplica el monitoreo global. Prohibido sumar PSS/RSS al total del Frame.

## Interacción, fijado y orden

- **Fijar/quitar**: un botón `+` al final de la zona de applets abre la lista de
  controles disponibles; pulsar fija/desfija (marca de verificación). Quitar un applet no
  borra su estado ni la config del sistema.
- **Ordenar**: arrastrar un bloque horizontalmente con el mouse; el destino se marca y
  Esc cancela (mismo gesto que el reordenamiento de ventanas en `frame.gd`). Con teclado,
  flechas mueven la selección y Ctrl+←/→ mueven el applet elegido en el orden.
- **Teclado**: la selección del Frame (`sel`) recorre también los applets, después de los
  ítems de ventanas. Enter/Espacio = primaria; Ctrl+←/→ reordena; Delete quita.
  La apertura del selector con Menú o Shift+F10 queda para otro corte.
- **Ratón**: clic izquierdo = primaria; clic derecho = selector de controles. Zona pulsable
  ≥ 28 px de alto (el Frame mide `FRAME_H = 48`); no se agranda el Frame.

## Persistencia mínima

- Archivo: `$XDG_CONFIG_HOME/gdtk/frame-applets.json` (por defecto
  `~/.config/gdtk/frame-applets.json`), junto a `~/.config/gdtk/keyboard`.
- Contenido actual: `{"bottom":["cpu","memoria","swap","reloj","deskflow"]}`.
  La lista contiene los `id` visibles en orden; omitir uno lo oculta. Los otros bordes
  podrán añadirse cuando se implemente su composición. **No** guarda
  layout de ventanas ni grupos: eso sigue en `shell._units()`.
- Escritura atómica y sólo al cambiar. Si falta o está corrupto → defaults (reloj, cpu,
  memoria, swap, deskflow visibles) sin romper el arranque. `id` desconocido se ignora y se
  conserva para una versión futura.

## Muestreo, coste y fallos

- Se muestrea sólo con el Frame visible o en Home, como `sysmon` hoy; nunca oculto, nunca
  por frame. `/proc` y reloj a 1 s; `bluetoothctl`, `nmcli`, `localectl` y `swaymsg` a
  ≥ 5 s (lanzan procesos: el X200 es lento). Cada muestra que cambia llama
  `request_redraw()`; sin cambios, el shell duerme (`IDLE_MS`).
- Binario/adaptador ausente → `no_disponible` con motivo; no reintenta en bucle.
- Orden con salida ≠ 0 o timeout → `error`/`sin_dato`, se descarta el valor; al
  normalizar se recupera solo.
- Bluetooth sin adaptador (`Powered` ausente) → `no_disponible`; periférico desconectado
  → `listo` con lista vacía, sin fingir conexión.
- `swaymsg` falla (sesión cage/X11) → el applet `teclado` guarda la elección para
  la próxima sesión e indica claramente que todavía no se aplicó.
- Deskflow muere → `_service_running` borra su pid → `apagado`; primaria relanza.
- `nmcli` caído → bloque `enlace` marcado «sin dato» si está fijado.

## Accesibilidad

- Texto y valor siempre presentes; el color no carga identidad ni estado. Los íconos
  ilustrados del mockup quedan para el siguiente corte visual.
- Valor textual además de la barra/dial (p. ej. «CPU 37 %», «MEM 62 %»), visible al
  enfocar o pasar el puntero.
- Movimiento reducido: sin pulsos; los cambios de valor no animan si la persona lo pide.
- Objetivos grandes (≥ 28 px), foco con contorno contrastado, orden de foco predecible.
- No se promete lector de pantalla: ImGui/gdtk no exponen API de accesibilidad; la señal
  es textual en la propia UI.

## Primer corte (pequeño)

1. `frame.gd` carga y guarda la ubicación de los controles; los dibuja como bloques
   donde hoy están `sysmon` y reloj. Ventanas y controles mantienen gestos separados.
2. Applets sin nuevos procesos de consulta: `reloj`, `cpu`, `memoria`, `swap` (reusar el
   muestreo de `sysmon.gd`) y `deskflow` (reusar el estado y toggle existentes).
3. Fijar/quitar con `+`, reordenar con arrastre y teclado, y persistir en
   `frame-applets.json`.
4. `bluetooth` y `teclado` quedan especificados; entran en el corte siguiente, que es el
   que agrega subprocesos. El bloque `enlace` (Wi-Fi) no se implementa aquí.

### Comprobación

- 1280×720 y equipo de baja resolución: con muchas ventanas, la zona de applets conserva
  ancho mínimo y legibilidad; el Frame no crece.
- Fijar/quitar/reordenar y reiniciar el shell: el orden y la visibilidad se conservan; no
  aparece una segunda copia del layout.
- CPU/memoria en reposo y en carga: valores coherentes con `top`/`free`; sin redibujo en
  reposo (el shell duerme).
- Anillo vs Frame: dos actividades pesadas → el anillo por-instancia puede quedar «sin
  dato» y el MEM global sigue correcto; no comparten escala.
- `deskflow`: prender/apagar refleja `service_pids`/`kill -0`; el anillo lo sigue marcando.
- Fallos: renombrar `frame-applets.json` (defaults, sin crash), matar Deskflow, ausencia
  de `swaymsg`/adaptador BT → estados honestos.
- Las pruebas automáticas sólo cubren registro/persistencia/parseo de estado; la
  validación visual es manual, con capturas antes de darla por terminada.

## Límites de este corte

Sólo hay applets en el borde inferior; CPU, memoria, swap y reloj son de lectura.
No crear la vista Vecindario ni mover su control de red. No duplicar
el layout de ventanas. No tocar el motor ni el fork. Conservar las modificaciones
existentes del árbol. No hacer commit ni push.

## Referencias

- [Sugar — Introduction to the Sugar Interface](https://wiki.sugarlabs.org/go/Tutorials/Introduction_to_the_Sugar_Interface)
  (Frame: avatar a la derecha, batería/red/recursos abajo, recortes a la izquierda).
- [Window Maker — appicons/Dock](https://www.windowmaker.org/docs/FAQ.html).
- Locales: `shell/frame.gd` (reloj ~602, `sysmon.draw` ~601, arrastre/selección),
  `shell/sysmon.gd`, `shell/shell.gd` (`ACTIVITIES`, `_toggle_service` 1459,
  `_service_running` 1484, `service_pids` 1456), `shell/recovery.gd:30`,
  `session/keyboard.sh`, `session/sway.conf`, `session/gdtk-session-sway`,
  `modules/wayland/wl_server.c:1253`, `modules/wayland/remote_input.cpp:272`.
- `SPEC-sugar-frame-blocks.md`, `SPEC-sugar-resource-ring.md`,
  `SPEC-sugar-journal-neighborhood.md`, `SPEC-sugar-home-visual.md`.
