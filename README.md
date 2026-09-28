# gdtk — toolkit UI inmediato para Godot 3 (fork godot-box3d-3)

Objetivo: UIs propias y ligeras (cliente XMPP móvil, shell tipo Sugar) sobre el
fork Godot 3.6 `godot-box3d-3`, usando Dear ImGui como capa de widgets.

## Factibilidad (resumen, sep 2026)

| Pieza | Veredicto | Nota |
|---|---|---|
| ImGui dentro de Godot 3 | Viable | Módulo C++ (`custom_modules`), render por `VisualServer.canvas_item_add_triangle_array`, un canvas item hijo por `ImDrawCmd` para el scissor (`canvas_item_set_custom_rect` + `set_clip`). Funciona igual en GLES2/GLES3/FRT. |
| Teclado en pantalla Android/iOS | Viable, barato | `io.WantTextInput` → `OS.show_virtual_keyboard()`; Godot ya entrega el texto como `InputEventKey.unicode`. |
| IME CJK / emoji color | Riesgo alto | ImGui no tiene preedit/composición; atlas CJK pesa (Noto CJK ≈ decenas de MB de atlas si no se usa carga dinámica, ImGui ≥1.92). Emoji a color requiere FreeType + `ImGuiFreeTypeBuilderFlags_LoadColor`. Para chat multilenguaje serio: `LineEdit` de Godot para el campo de entrada, ImGui para el resto. |
| Wayland (cliente) | Ya resuelto | El fork trae FRT/SDL2 con EGL nativo en Wayland. |
| Shell tipo Sugar (kiosk) | Viable | Godot a pantalla completa bajo `cage` (o `gamescope`); actividades = escenas dentro del mismo proceso. Sin logind/DRM propios. |
| Godot como compositor Wayland | Investigación | `gdwlroots` (Godot 3, usado por Simula) embebe wlroots: surfaces como texturas. Hay que ser dueño de DRM master, seat (libseat/logind), XWayland, y perseguir la API inestable de wlroots. Hacerlo después del kiosk. |
| XMPP | Viable | Nativo: libstrophe (C, TLS+SCRAM, cross-compila fácil para NDK/iOS) como módulo. Pure-GDScript sobre `StreamPeerSSL` sólo para prototipo. Background: Android necesita foreground service; iOS sólo push (XEP-0357 + APNs) — código nativo fuera de Godot en ambos. |

Alternativas a ImGui evaluadas: Nuklear/microui (mismos problemas de IME, menos
widgets), RmlUi (HTML/CSS, más pesado), Clay (sólo layout). ImGui gana por
ecosistema y porque el problema de texto es igual en todas.

## Arquitectura propuesta

```
Godot 3.6 fork (FRT/SDL2, Wayland, módulo `imgui`) + este repo (`modules/wayland`, shell, demos)
  └─ nodo ImGuiCanvas (Node2D): contexto ImGui, input, render vía VisualServer
      └─ GDScript llama API inmediata en la señal `imgui_frame`
Fase 2: modules/xmpp (libstrophe) → señales message_received / send_message()
Fase 3: shell Sugar bajo `cage`; luego gdwlroots si hace falta embeber apps externas
```

## Build

gdtk compila en su **propio árbol del motor**, `~/Proyectos/godot3-box3d/godot-dev` (un `git worktree`
del mismo commit que `godot`, con los parches del fork aplicados). El árbol `godot` queda para Odisea
y las ramas del fork: así ninguno le cambia los parches al otro y scons no recompila todo al alternar.
La caché de objetos (`SCONS_CACHE=~/.cache/scons-godot3`, en `~/.zshrc` y en `deploy.sh`) es
compartida entre árboles y ramas.

El binario que se despliega es **sin editor** (`tools=no`, `extra_suffix=gdtklite`, sin los módulos
de `NO_MODULES` en `deploy.sh`: física, audio, red, VR, gltf...); lo compila `deploy.sh`. Para
desarrollo sigue sirviendo el build con editor:

```sh
cd ~/Proyectos/godot3-box3d/godot-dev
# desplegado (lo mismo que hace deploy.sh):
scons -j8 platform=frt arch=x86_64 target=release_debug tools=no frt_desktop_gl=yes production=yes \
  lto=none use_static_cpp=no extra_suffix=gdtklite imgui_implot3d=yes \
  custom_modules=$HOME/Proyectos/godot3-box3d/godot-box3d-3-gdtk,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules \
  $(for m in bullet csg gridmap enet upnp webrtc websocket webxr mobile_vr gdnative visual_script theora webm \
    vorbis opus ogg stb_vorbis minimp3 gltf jsonrpc camera opensimplex raycast box3d decal; do echo module_${m}_enabled=no; done)
# desarrollo con editor: tools=yes extra_suffix=gdtk, sin los module_*_enabled=no
./run_shell.sh; ./run_compositor.sh; tests/control_test.sh   # verificación
./deploy.sh icarito@192.168.18.163                            # a la X200 (tengu)
```
