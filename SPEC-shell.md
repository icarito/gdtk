# SPEC — Paso 3: shell tipo Sugar bajo `cage` (FRT/SDL2, Wayland nativo)

Continúa el POC de `SPEC.md` (ya hecho: `modules/imgui`, `demo/`). Mínimo que funcione,
sin abstracciones extra. Leer primero `modules/imgui/imgui_canvas.{h,cpp}` y `demo/main.gd`.

## Rutas

- Repo: `/run/media/icarito/DATA/icarito/Proyectos/gdtk` (git ya inicializado; commitear al final).
- Motor: `/home/icarito/Proyectos/godot3-box3d/godot` (ya parcheado, `platform/frt` ya presente). NO tocar su git, NO correr `scripts/build.sh` del fork (re-clona/re-parchea FRT), NO pisar binarios existentes en `bin/`.
- Fork de módulos (sólo lectura): `/home/icarito/Proyectos/godot3-box3d/godot-box3d-3`.

## 1. Ampliar la API de `ImGuiCanvas` (retrocompatible, la demo debe seguir andando)

- `begin(title: String, flags: int = 0) -> bool`
- `set_next_window_pos(pos: Vector2, always: bool = false)` y `set_next_window_size(size, always = false)` → `ImGuiCond_Always` si `always`, si no `FirstUseEver`.
- `set_cursor_pos(pos: Vector2)` → `ImGui::SetCursorPos`.
- `button(label: String, size: Vector2 = Vector2()) -> bool`.
- Constantes de clase (vía `ClassDB::bind_integer_constant`, accesibles como `ImGuiCanvas.WINDOW_NO_DECORATION` y dentro del script como `WINDOW_NO_DECORATION`):
  `WINDOW_NO_DECORATION, WINDOW_NO_BACKGROUND, WINDOW_NO_MOVE, WINDOW_NO_SAVED_SETTINGS, WINDOW_NO_BRING_TO_FRONT_ON_FOCUS` con los valores de `ImGuiWindowFlags_*`.
- Propiedad exportada `frame_rounding: float = 0.0` → `ImGui::GetStyle().FrameRounding` (aplicar en READY antes de `ScaleAllSizes`).

Defaults con `DEFVAL(...)` en `bind_method`.

## 2. Proyecto `shell/` (Godot 3, sin assets binarios)

```
shell/project.godot   # main_scene=res://shell.tscn; emulate_mouse_from_touch=false;
                      # application/run/low_processor_mode=true, low_processor_mode_sleep_usec=16000;
                      # display/window/size/fullscreen no hace falta (cage maximiza)
shell/shell.tscn      # raíz: ImGuiCanvas con script shell.gd, frame_rounding=12
shell/shell.gd
shell/activities/chat.gd   # extends Reference; func draw(ui) — el chat mock de demo/main.gd movido aquí
```

`shell.gd` (extends ImGuiCanvas), conectado a `imgui_frame`:

- Tabla de actividades como `const ACTIVITIES = [...]`, cada una un Dictionary:
  - `{"name": "Chat", "script": "res://activities/chat.gd"}` → interna.
  - `{"name": "Terminal", "cmd": ["alacritty", "kgx"]}` → externa: el primer ejecutable encontrado en PATH (comprobar con `OS.execute("sh", ["-c", "command -v " + exe], true, out)`), lanzado con `OS.execute(exe, [], false)` (no bloqueante). Imprimir `launched <exe> pid <pid>`; si ninguno existe, mostrar el error en la vista home (`text`).
  - `{"name": "Salir", "quit": true}` → `get_tree().quit()` (termina la sesión cage).
- **Vista home** (sin actividad abierta): una ventana a pantalla completa (`set_next_window_pos(Vector2.ZERO, true)`, `set_next_window_size(viewport_size, true)`, flags `WINDOW_NO_DECORATION | WINDOW_NO_BACKGROUND | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS | WINDOW_NO_BRING_TO_FRONT_ON_FOCUS`). En el centro un botón grande con el nombre de usuario (`OS.get_environment("USER")`, estilo "XO", sin acción). Las actividades en un anillo alrededor: botones de 110x110 posicionados con `set_cursor_pos` en `centro + radio * (cos a, sin a) - tamaño/2`, radio = 0.3 * min(ancho, alto). Abajo a la derecha el reloj `HH:MM` (`OS.get_time()`).
- **Actividad interna abierta**: una barra arriba (ventana de ancho completo, alto ~48, sin decoración) con botón "Inicio" (vuelve al home) y el nombre de la actividad; debajo, ventana a pantalla completa restante sin decoración donde se llama `activity.draw(self)`. La instancia se crea con `load(script).new()` al abrir y se conserva mientras la actividad está abierta (el historial del chat persiste hasta volver a home — basta así).
- Argumentos de usuario (`OS.get_cmdline_args()`):
  - `--open=<Nombre>` abre esa actividad al arrancar (sirve para kiosk y para testear).
  - `--screenshot=<ruta>`: igual que la demo (tras 30 frames guardar viewport, flip_y, PNG, quit).

## 3. Sesión

- `session/gdtk-session` (sh, ejecutable):
  ```sh
  #!/bin/sh
  HERE="$(cd "$(dirname "$0")/.." && pwd)"
  : "${GDTK_GODOT:=/home/icarito/Proyectos/godot3-box3d/godot/bin/godot.frt.opt.tools.x86_64.gdtk}"
  exec cage -s -- "$GDTK_GODOT" --path "$HERE/shell" "$@"
  ```
  (verificar el nombre real del binario que produzca el build y ajustar el default).
- `session/gdtk.desktop` (entrada para `/usr/share/wayland-sessions/`): `Name=gdtk (Sugar-like)`, `Comment=...`, `Exec=<ruta absoluta a session/gdtk-session>`, `Type=Application`, `DesktopNames=gdtk`. NO instalarlo (requiere sudo): sólo el archivo.

## 4. Build (obligatorio, en este orden)

```sh
cd /home/icarito/Proyectos/godot3-box3d/godot
M=/home/icarito/Proyectos/godot3-box3d/godot-box3d-3,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules
# a) x11 (el de la demo) — incremental
scons -j8 platform=x11 target=release_debug tools=yes progress=no extra_suffix=gdtk custom_modules=$M
# b) FRT/SDL2 desktop GL (Wayland nativo) — puede tardar (~30 min si recompila todo); usar timeout largo o correrlo en background y esperar
scons -j8 platform=frt arch=x86_64 target=release_debug tools=yes frt_desktop_gl=yes production=yes lto=none progress=no extra_suffix=gdtk custom_modules=$M
```

## 5. Verificación (obligatorio)

1. Demo intacta: `./run_demo.sh` sigue generando `poc.png`.
2. Shell en cage anidado (la sesión actual es GNOME Wayland, `WAYLAND_DISPLAY=wayland-0`; cage abre una ventana anidada):
   - `GDTK_GODOT=<bin frt gdtk> session/gdtk-session -- --screenshot=$PWD/shell-home.png` → PNG con el anillo.
   - `... -- --open=Chat --screenshot=$PWD/shell-chat.png` → PNG con barra "Inicio" + chat.
   - Confirmar en la salida que FRT usó el driver wayland de SDL (si imprime el video driver; si no, `SDL_VIDEODRIVER=wayland` explícito y confirmar que arranca).
   - Poner `timeout 60` delante de cada corrida para no colgarse.
3. Revisar ambos PNG visualmente (leerlos) y describir lo que se ve.
4. `run_shell.sh` en la raíz con los comandos de 2.

## Entregable

- Commit `feat(shell): shell tipo Sugar bajo cage + API imgui (flags, cursor, tamaño)` terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`. `.gitignore` ya ignora `*.png`.
- Reporte final breve: qué compila, rutas de binarios, qué muestran los PNG, desvíos del spec y errores literales de lo que quede roto. Sin push. No modificar `README.md`, `SPEC.md` ni este archivo.
