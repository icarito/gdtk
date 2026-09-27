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
  (o `""` si no hay).

Teclas: **F1** o **`** abren/cierran el HUD. Un clic/toque en el widget mini
tambien lo abre. En tactil, el toque lo alterna.

## Pestanas

- **Graficas**: FPS y frame time (ventana de 10 s), memoria estatica/dinamica,
  objetos/nodos/huerfanos, draw calls, objetos en frame y fisica.
- **Consola**: log del motor capturado por `DebugLog` (errores en rojo), filtro
  de texto, autoscroll, boton limpiar e historial de comandos con flechas.
- **Monitores**: tabla con todos los `Performance.*` y su valor.

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
