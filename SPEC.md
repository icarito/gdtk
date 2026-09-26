# SPEC — POC módulo `imgui` para Godot 3.6

Implementar un módulo C++ de Godot 3.6 que integre Dear ImGui y una demo que lo use.
Mínimo que funcione. Nada de abstracciones extra, nada "para después".

## Rutas

- Repo de trabajo: `/run/media/icarito/DATA/icarito/Proyectos/gdtk` (hacer `git init` si no existe y commitear al final).
- Fuente del motor (Godot 3.6.4-rc, ya parcheado, NO modificar nada ahí salvo los artefactos de build):
  `/home/icarito/Proyectos/godot3-box3d/godot`
- Fork de módulos existentes (sólo lectura, sirve de ejemplo de módulo): `/home/icarito/Proyectos/godot3-box3d/godot-box3d-3` (ver `box3d/` y `decal/` para `config.py`, `SCsub`, `register_types.*`).

## Archivos a crear

```
modules/imgui/config.py
modules/imgui/SCsub
modules/imgui/register_types.h / .cpp
modules/imgui/imgui_canvas.h / .cpp
modules/imgui/thirdparty/imgui/      # Dear ImGui v1.91.9 (git clone --depth 1 --branch v1.91.9 https://github.com/ocornut/imgui), sólo imgui*.cpp/h, imconfig.h, imstb*.h, LICENSE.txt
demo/project.godot
demo/main.tscn   (raíz: ImGuiCanvas con script main.gd)
demo/main.gd
.gitignore       (ignorar demo/.import, *.png de salida)
```

`SCsub`: compilar los .cpp de thirdparty con `env_imgui = env_modules.Clone()`, añadir `thirdparty/imgui` al CPPPATH, desactivar warnings de thirdparty si molestan. No usar backends de ImGui (`backends/`); escribimos el nuestro.

## Clase `ImGuiCanvas : Node2D`

Estado: un `ImGuiContext*` propio (crear en constructor, destruir en destructor; `ImGui::SetCurrentContext` antes de cada uso), `Ref<ImageTexture>` del atlas de fuentes, un `Vector<RID>` pool de canvas items hijos.

Propiedad exportada: `float scale = 1.0` (multiplica `FontGlobalScale` y `ScaleAllSizes` al inicio; en Android default recomendado 2.5 — sólo propiedad, sin autodetección).

Ciclo:
1. `NOTIFICATION_READY`: construir atlas (`io.Fonts->GetTexDataAsRGBA32`) → `Image` FORMAT_RGBA8 → `ImageTexture` (flags 0, sin filtro/mipmaps), `io.Fonts->SetTexID` con el `RID` del texture (guardar en un `ImTextureID` como puntero a un `RID` miembro o usar índice; basta con soportar una sola textura). `set_process(true)`, `set_process_input(true)`.
2. `NOTIFICATION_PROCESS`:
   - `io.DisplaySize` = tamaño del viewport visible; `io.DeltaTime = max(delta, 1e-4)`.
   - `ImGui::NewFrame()`; `emit_signal("imgui_frame")`; `ImGui::Render()`.
   - Render: por cada `ImDrawList`, por cada `ImDrawCmd` (ignorar `UserCallback`): tomar/crear un canvas item hijo del pool (`VS::canvas_item_create`, `canvas_item_set_parent(child, get_canvas_item())`), `canvas_item_clear`, `canvas_item_set_custom_rect(child, true, clip_rect)`, `canvas_item_set_clip(child, true)`, `canvas_item_set_draw_index(child, n)`, y `canvas_item_add_triangle_array` con los índices `IdxBuffer[IdxOffset .. IdxOffset+ElemCount]` y los vértices (pos, uv, color). Color de vértice: `IM_COL32` es ABGR en u32 → `Color(r/255, g/255, b/255, a/255)`. Los items del pool no usados este frame: `canvas_item_clear`.
   - Liberar los RIDs del pool en el destructor (`VS::free`).
3. `_input(InputEvent)` (implementar vía `NOTIFICATION`/`_input` binding de Node en 3.x: sobreescribir `void _input(const Ref<InputEvent>&)` y bindearlo, o usar `_unhandled_input` — preferir `_input` y marcar `get_tree()->set_input_as_handled()` cuando `io.WantCaptureMouse/Keyboard`):
   - `InputEventMouseMotion` → `io.AddMousePosEvent`.
   - `InputEventMouseButton` → botones 1/2/3 → `AddMouseButtonEvent(0/1/2)`; wheel up/down → `AddMouseWheelEvent`.
   - `InputEventScreenTouch` (index 0) → pos + botón 0 press/release. `InputEventScreenDrag` (index 0) → pos. (Emular mouse desde touch debe quedar apagado en demo/project.godot: `input_devices/pointing/emulate_mouse_from_touch=false`, y emulate touch from mouse también false.)
   - `InputEventKey` → mapear un subconjunto: Tab, flechas, Home/End, Delete, Backspace, Enter, Escape, Ctrl/Shift/Alt (`AddKeyEvent` + `ImGuiMod_*`), A/C/V/X/Z para atajos. Si `pressed && unicode >= 32` → `io.AddInputCharacter(unicode)`.
   - Tras `NewFrame`, si `io.WantTextInput` pasó de false→true: `OS::get_singleton()->show_virtual_keyboard("")`; true→false: `hide_virtual_keyboard()`. (Esto es todo el soporte de teclado móvil del POC.)
   - Clipboard: `io.SetClipboardTextFn/GetClipboardTextFn` → `OS::get_singleton()->set_clipboard / get_clipboard` (guardar el CharString en un miembro estático para que el puntero viva).

## API inmediata expuesta a GDScript

Sólo esto (métodos de `ImGuiCanvas`, válidos sólo dentro de la señal `imgui_frame`):

```
begin(title: String) -> bool          # ImGui::Begin; el script SIEMPRE llama end()
end()
set_next_window_pos(pos: Vector2) / set_next_window_size(size: Vector2)   # ImGuiCond_FirstUseEver
text(s: String)
text_wrapped(s: String)
button(label: String) -> bool
same_line()
separator()
checkbox(label: String, value: bool) -> bool          # devuelve el valor nuevo
input_text(label: String, value: String) -> String   # buffer interno de 1024 bytes; devuelve el nuevo valor
input_text_enter(label, value) -> Dictionary {text, submitted}   # flag EnterReturnsTrue, para el chat
begin_child(id: String, size: Vector2) -> bool / end_child()
set_scroll_here_y(ratio: float)
```

Strings: `String.utf8()` → `const char*`; de vuelta con `String::utf8()`.

## Demo (`demo/`)

`main.gd` en `_ready` conecta `imgui_frame`. Dibuja dos ventanas:

1. **"Actividades"** — estilo Sugar: 6 botones (Chat, Pintar, Escribir, Terminal, Música, Ajustes) en rejilla con `same_line`; al pulsar, `text("Abrir: X")`.
2. **"Chat XMPP (mock)"** — `begin_child` con historial (`text_wrapped` por mensaje, autoscroll con `set_scroll_here_y(1.0)` cuando llega uno nuevo), abajo `input_text_enter("##msg", borrador)` + botón "Enviar". Al enviar agrega `"yo: " + texto` y, un timer de 1 s después, una respuesta eco `"bot: " + texto`. Sin red.

Además, si se pasa `--screenshot=<ruta>` en los argumentos de usuario (`OS.get_cmdline_args()`), tras 30 frames guarda `get_viewport().get_texture().get_data()` (flip_y) como PNG en esa ruta y hace `get_tree().quit()`. Esto es la verificación automática.

## Build y verificación (obligatorio)

```sh
cd /home/icarito/Proyectos/godot3-box3d/godot
scons -j8 platform=x11 target=release_debug tools=yes progress=no extra_suffix=gdtk \
  custom_modules=/home/icarito/Proyectos/godot3-box3d/godot-box3d-3,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules
```

- Usar SIEMPRE `extra_suffix=gdtk` (no pisar `bin/godot.x11.opt.tools.64`). No tocar `bin/` fuera de ese binario nuevo. No hacer `git` nada en el árbol de godot.
- Primero importar: `bin/godot.x11.opt.tools.64.gdtk --path <gdtk>/demo --editor --quit` (o `-e --quit`) para generar `.import`.
- Luego: `bin/godot.x11.opt.tools.64.gdtk --path <gdtk>/demo -- --screenshot=<gdtk>/poc.png`, y confirmar que el PNG existe y no está vacío. Si hay display disponible (DISPLAY o WAYLAND_DISPLAY), usarlo; si no, reportarlo.
- Un script `run_demo.sh` en la raíz con esos dos comandos.

## Entregable

- Commit en `gdtk` (`git init` si hace falta) con mensaje `feat: POC módulo imgui para Godot 3.6 + demo`, terminando con la línea `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Un reporte final breve: qué compila, ruta del binario, ruta del PNG, qué quedó pendiente o roto (con el error literal).
- No push a ningún lado. No modificar `README.md` ni este `SPEC.md`.
