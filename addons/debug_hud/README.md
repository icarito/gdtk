# Debug HUD

HUD de debug reutilizable para cualquier proyecto Godot 3 que tenga el modulo
`imgui` (de gdtk) compilado en su binario. Incluye captura de logs en C++
(`DebugLog`), un widget mini siempre visible y un HUD completo con graficas,
consola y monitores de rendimiento.

## Instalacion

1. Copia `addons/debug_hud/` a la raiz del proyecto destino.
2. Registralo como autoload en `project.godot`:

   ```
   [autoload]

   DebugHud="*res://addons/debug_hud/debug_hud.gd"
   ```

3. En el nodo `ImGuiCanvas` que ya use el proyecto, dibuja el HUD cada frame.
   Si tu escena emite la senal `imgui_frame` del `ImGuiCanvas`, conecta:

   ```gdscript
   func _ready():
       connect("imgui_frame", self, "_on_imgui_frame")

   func _on_imgui_frame():
       # ... dibujo propio ...
       DebugHud.draw(self)
   ```

   `DebugHud.draw(canvas)` es idempotente: fija el canvas y dibuja lo que
   corresponda. Debe llamarse una vez por frame, despues del resto de la UI.

## API

- `DebugHud.enabled` (`bool`): si es `false` el HUD no dibuja nada.
- `DebugHud.visible` (`bool`): HUD completo abierto/cerrado.
- `DebugHud.mini_corner` (`int`): 0=arriba-izq, 1=arriba-der, 2=abajo-izq,
  3=abajo-der (por defecto 3).
- `DebugHud.scale` (`float`): escala del widget mini.
- `DebugHud.set_canvas(canvas)`: fija el `ImGuiCanvas` anfitrion.
- `DebugHud.set_enabled(v)`: equivalente a asignar `enabled`.
- `DebugHud.toggle()`: abre/cierra el HUD completo.
- `DebugHud.register_command(name, target, method, help)`: registra un comando
  de consola. `target.call(method, args)` recibe el texto tras el nombre
  (o `""` si no hay) y devuelve la salida (String) que se imprime y se
  devuelve por `command_output`.
- `DebugHud.render_local` (`bool`): con `false` no se dibuja la vista ImGui (el
  colector sigue corriendo). Ver mas abajo.
- `DebugHud.remote_source` (`"host:puerto"`): visor remoto; hace poll de
  `hud_snapshot` a `remote_hz` (4 por defecto) y dibuja lo que llega.
- `DebugHud.start_remote(host, port)` / `DebugHud.stop_remote()`.
- `DebugHud.apply_snapshot(dict)`: alimenta el espejo remoto.
- `DebugHud.snapshot(since_frame)` y `DebugHud.command_output(line)`.

Teclas: **F1** o **`** abren/cierran el HUD. Un clic/toque en el widget mini
tambien lo abre. En tactil, el toque lo alterna.

## Pestanas

- **Graficas**: grupos colapsables (Frame, Render, Memoria, Objetos, Fisica,
  Audio y GPU) con un plot por grupo. En modo visor remoto se agrega al pie el
  log reciente que viene en el snapshot. El grupo GPU solo aparece si el motor
  trae `FRT_PERF` (lineas `[FRT_PERF]`/`[FRT_GPU]`).
- **Monitores**: tabla con el valor actual y min/max/media de la ventana
  (600 muestras) de cada monitor, mas las series FRT_PERF y el costo del
  colector (`collector_us`).
- **Consola**: log del motor capturado por `DebugLog` (errores en rojo), filtro
  de texto, autoscroll, boton limpiar e historial de comandos con flechas.

El widget mini muestra FPS, memoria estatica, **draw calls y vertices** y un
sparkline de frame time.

## Colector (`debug_metrics.gd`)

`DebugMetrics` es el colector, sin dependencia de ImGui (corre aunque el modulo
`imgui` no este compilado). Muestrea cada frame (o a `sample_hz`) los monitores
de `Performance` en buffers circulares de 600 muestras, mantiene el cursor de
`DebugLog` y expone:

```
snapshot(since_frame := -1) -> {
  frame, time,
  series: {nombre: [valores nuevos desde since_frame]},
  latest: {nombre: valor},
  logs:   [entradas nuevas de DebugLog],
  profile:{tier, flat, driver, gpu, render_local, frt_perf, sample_hz, frame},
}
```

`DebugHud` usa un `DebugMetrics` local como colector y otro "espejo" que se
alimenta con `apply_snapshot()` de los snapshots remotos. La vista dibuja del
mismo modo desde datos locales o remotos.

Series FRT_PERF (solo si el motor las imprime): `gpu`, `frt_frame`, `frt_idle`,
`frt_phys`, `frt_phys_sum`, `frt_steps`, `frt_render`, `frt_sync`,
`frt_other`, `frt_fps`.

## Perfilado remoto

La instancia perfilada corre con el colector activo y sin dibujar la vista; el
visor hace poll a 4 Hz del metodo `hud_snapshot` del control remoto TCP de gdtk
(`shell/remote.gd`) y dibuja con `render_local = true`. El transporte reutiliza
el mismo token de `mcp/gdtk_mcp.py`:

- Misma maquina: token en `$XDG_RUNTIME_DIR/gdtk-control-<puerto>.token`
  (o `gdtk-control.token` sin `GDTK_CONTROL_PORT`). El visor lo lee solo.
- Otra maquina: no se mueve el token. Se abre un tunel ssh del puerto de
  control y se apunta el visor a `127.0.0.1:<puerto-local>`:
  `ssh -N -L 7777:127.0.0.1:7777 usuario@host` y `remote_source =
  "127.0.0.1:7777"`. Para el token se puede copiar el archivo, o definir
  `GDTK_HUD_TOKEN` con la ruta a una copia.

Herramientas MCP equivalentes: `gdtk_metrics` (tabla de `latest` y resumen
min/max/media) y `gdtk_console` (`hud_command`; en builds no debug solo
`help`, `fps`, `vsync` y `timescale`).

## Politica `render_local`

Prioridad: hook `render_local_resolver` > env `GDTK_HUD_LOCAL=0|1` >
`ProjectSettings` `debug_hud/render_local` (default `true`).

El hook es un objeto con `render_local_resolver_method` (por defecto
`resolve_render_local`) o un diccionario `{target, method}`; devuelve bool (o
`null` para no decidir).

Mapeo para Odisea (proyecto anfitrion):

```gdscript
# En el autoload de Odisea, tras cargar DebugHud:
DebugHud.render_local_resolver = GLES3VendorGate
# GLES3VendorGate.resolve_render_local() -> bool:
#   return not (is_low_tier() and is_flat_mode())
```

Es decir, en gama baja con perfil plano el dispositivo no dibuja el HUD (solo
colecta) y el control remoto de Odisea (`core_v2/net/RemoteControlManager.gd`)
solo corre con `allow_low_tier_offload`; su HUD del telefono
(`core_v2/ui/hud/RemoteHudBackend.gd`) consume `widget_snapshot()`, y el
snapshot de `DebugMetrics` encaja ahi como una pantalla mas.

## Comandos incluidos

| Comando | Descripcion |
| --- | --- |
| `help` | Lista los comandos disponibles. |
| `clear` | Limpia el log y la consola. |
| `fps <n>` | `Engine.target_fps` (0 = sin limite). |
| `timescale <x>` | `Engine.time_scale`. |
| `vsync on\|off` | `OS.vsync_enabled`. |
| `quit` | Cierra la aplicacion. |
| `eval <expr>` | Evalua una `Expression` sobre la escena actual. Solo se registra en builds de debug. |

## Costo

Con el HUD cerrado solo se dibuja el widget mini. Con `DebugHud.enabled =
false` no se emite ninguna llamada a ImGui. Si no se pasa un canvas y el
proyecto no tiene ninguno, el HUD no crea nodos propios.

## Captura de logs (C++)

`DebugLog` es un singleton de `Engine` registrado por el modulo `imgui`. Su
`DebugLogger` se registra en `OS::add_logger` y guarda un buffer circular de
2000 entradas con `Mutex`. API en GDScript:

- `DebugLog.get_entries(since_id) -> Array` de diccionarios
  `{id, time_ms, text, is_error}`.
- `DebugLog.clear()`.
- `DebugLog.last_id()`.
