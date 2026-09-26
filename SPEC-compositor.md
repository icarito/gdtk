# SPEC — Paso 4: compositor Wayland anidado dentro de Godot (POC)

Objetivo: que el shell (`shell/`) sea un **servidor** Wayland. Una app externa (alacritty,
es2gears_wayland, gtk4-widget-factory) se conecta a un socket de Godot y su ventana aparece
**como textura dentro del shell**, con teclado y mouse reenviados. Mínimo que funcione; nada
"para después". Leer antes: `modules/imgui/*`, `shell/shell.gd`, `shell/shell.tscn`, `SPEC-shell.md`.

## Rutas y reglas (igual que antes)

- Repo: `/run/media/icarito/DATA/icarito/Proyectos/gdtk`. Motor: `/home/icarito/Proyectos/godot3-box3d/godot`
  (no tocar su git ni sus fuentes; no correr `scripts/build.sh` del fork; no pisar binarios sin sufijo `gdtk`).
- Fork (sólo lectura): `/home/icarito/Proyectos/godot3-box3d/godot-box3d-3`.
- NO hacer `git add -A`: hay un archivo ajeno sin trackear en `shell/` (crash dump de otro programa).
  Agregar archivos por nombre.

## Decisiones ya tomadas (no cambiarlas)

1. **wlroots 0.19** del sistema (`pkg-config wlroots-0.19`), headers en `/usr/include/wlroots-0.19`.
   Verificar cada firma contra esos headers antes de usarla.
2. **Renderer pixman** (`wlr_pixman_renderer_create()`), NO gles2/autocreate. Motivo: el renderer GL
   de wlroots hace `eglMakeCurrent` en el hilo principal y rompe el contexto GL de Godot. Con pixman no
   hay EGL de wlroots en el proceso. Consecuencia: sólo buffers `wl_shm`; los clientes GL usan el
   fallback software de Mesa (lanzarlos con `LIBGL_ALWAYS_SOFTWARE=1`).
3. **Backend headless** (`wlr_headless_backend_create(loop)`), sin outputs salvo que un cliente se
   niegue a arrancar sin `wl_output` (en ese caso: `wlr_headless_add_output` + `wlr_output_create_global`,
   y documentarlo en el reporte).
4. **Copia por CPU** de cada commit a una `ImageTexture` de Godot vía `wlr_texture_read_pixels` con
   `DRM_FORMAT_ABGR8888` (= bytes R,G,B,A = `Image::FORMAT_RGBA8`). Marcar en el código con
   `// ponytail: copia CPU por commit; zero-copy = dmabuf + EGLImage sobre texture_get_texid()`.
5. **Glue de wlroots en C puro** (`wl_server.c` + `wl_server.h`), porque los headers de wlroots no
   compilan como C++. El nodo Godot (C++) sólo ve la API C de `wl_server.h`. Compilar con `-DWLR_USE_UNSTABLE`.
6. Sólo se muestra la **surface principal** del toplevel (sin subsurfaces, popups ni recorte por
   geometry; las sombras CSD de GTK se ven, está bien). Coordenadas de input = coordenadas locales
   de esa surface.

## Módulo `modules/wayland/`

```
config.py        # can_build: platform in ("frt", "x11") y `pkg-config --exists wlroots-0.19`
SCsub            # env_mod.Append(CPPDEFINES=["WLR_USE_UNSTABLE"]); ParseConfig cflags en env del módulo;
                 # libs (wlroots-0.19 wayland-server xkbcommon pixman-1) en `env` (el del link final)
xdg-shell-protocol.h   # generado UNA vez y commiteado:
                 # wayland-scanner server-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml xdg-shell-protocol.h
wl_server.h / wl_server.c   # glue C
wayland_compositor.h / .cpp # nodo Godot
register_types.h / .cpp
```

### `wl_server.c` (C)

Estado: `wl_display`, `wl_event_loop`, backend headless, renderer pixman, `wlr_compositor_create(display, 5, renderer)`,
`wlr_subcompositor_create`, `wlr_data_device_manager_create`, `wlr_xdg_shell_create(display, 3)`,
`wlr_renderer_init_wl_shm(renderer, display)`, `wlr_seat_create(display, "seat0")` con capacidades
pointer|keyboard, un **wlr_keyboard virtual** (`wlr_keyboard_init` con un `static const struct wlr_keyboard_impl`
con sólo `.name`, keymap `xkb_keymap_new_from_names(ctx, NULL, 0)` — respeta `XKB_DEFAULT_*`,
`wlr_seat_set_keyboard`), `wlr_backend_start`, `wl_display_add_socket_auto`.

Toplevels: lista enlazada o array de structs `{int id; struct wlr_xdg_toplevel *tl; listeners; bool mapped;}`
con ids incrementales desde 1. Escuchar `xdg_shell->events.new_toplevel`, y por toplevel:
`surface->events.commit`, `surface->events.map`, `surface->events.unmap`, `tl->events.destroy`.

**Trampa conocida:** en el commit con `tl->base->initial_commit == true` hay que llamar
`wlr_xdg_toplevel_set_size(tl, default_w, default_h)` (eso agenda el configure); si no, el cliente
espera para siempre y nunca mapea.

API C (callbacks para que el C++ reciba eventos, sin polling):

```c
typedef struct wl_server wl_server;
typedef struct {
	void *ud;
	void (*added)(void *ud, int id);
	void (*removed)(void *ud, int id);
	// pixels RGBA8 contiguos (stride = w*4), válidos sólo durante la llamada
	void (*frame)(void *ud, int id, const unsigned char *rgba, int w, int h);
	void (*title)(void *ud, int id, const char *title);
} wl_server_callbacks;

wl_server *wl_server_create(wl_server_callbacks cb, int default_w, int default_h); // NULL si falla
const char *wl_server_socket(wl_server *s);
void wl_server_dispatch(wl_server *s);   // wl_event_loop_dispatch(loop, 0) + wl_display_flush_clients
void wl_server_frame_done(wl_server *s); // wlr_surface_send_frame_done(CLOCK_MONOTONIC) a cada toplevel mapeado
void wl_server_set_size(wl_server *s, int id, int w, int h);
void wl_server_close(wl_server *s, int id);           // wlr_xdg_toplevel_send_close
void wl_server_focus(wl_server *s, int id);           // set_activated + wlr_seat_keyboard_notify_enter
void wl_server_pointer_motion(wl_server *s, int id, double x, double y, uint32_t time_ms); // enter si cambia de surface + motion + frame
void wl_server_pointer_button(wl_server *s, uint32_t time_ms, uint32_t evdev_button, int pressed); // + frame
void wl_server_pointer_axis(wl_server *s, uint32_t time_ms, double dy);   // rueda vertical, + frame
void wl_server_key(wl_server *s, uint32_t time_ms, uint32_t evdev_key, int pressed);
	// wlr_keyboard_notify_key(&kb, &(struct wlr_keyboard_key_event){..., .update_state = true})
	// luego wlr_seat_keyboard_notify_modifiers(seat, &kb.modifiers) y wlr_seat_keyboard_notify_key(...)
void wl_server_destroy(wl_server *s);    // wl_display_destroy_clients + wl_display_destroy
```

`frame` se emite en cada commit de una surface mapeada con textura (`wlr_surface_get_texture`):
leer con `wlr_texture_read_pixels` a un buffer propio (realloc si cambia el tamaño) y llamar al callback.

### `WaylandCompositor : Node` (C++)

- Propiedad `default_size: Vector2 = (1024, 700)`.
- `start() -> String`: crea el server, `set_process(true)`, devuelve el nombre del socket ("" + `ERR_PRINT` si falla).
- `NOTIFICATION_PROCESS`: `wl_server_dispatch` y luego `wl_server_frame_done`.
- `launch(cmd: String, args: PoolStringArray = []) -> int`: `OS::execute("env", ["-u", "DISPLAY",
  "WAYLAND_DISPLAY=<socket>", "GDK_BACKEND=wayland", "GSK_RENDERER=cairo", "LIBGL_ALWAYS_SOFTWARE=1",
  "SDL_VIDEODRIVER=wayland", cmd, ...args], false, &pid)`; devuelve pid (-1 si falla).
- Por toplevel: `Ref<ImageTexture>` (en `frame`: si cambió el tamaño `create_from_image(img, 0)`, si no `set_data(img)`), título.
- Métodos: `get_texture(id) -> Texture`, `get_title(id) -> String`, `get_ids() -> Array`,
  `set_size(id, Vector2)`, `close(id)`, `focus(id)`, `pointer_motion(id, Vector2)`,
  `pointer_button(button_index: int, pressed: bool)` (BUTTON_LEFT/RIGHT/MIDDLE → BTN_LEFT/RIGHT/MIDDLE
  de `linux/input-event-codes.h`; BUTTON_WHEEL_UP/DOWN → `pointer_axis(∓10)` sólo en press),
  `key(event: InputEventKey)` → `event.physical_scancode` → código evdev con una tabla estática (letras,
  dígitos, espacio, Enter, Backspace, Tab, Escape, flechas, Home/End/Delete, Shift/Ctrl/Alt izq.,
  `- = [ ] ; ' , . /` y backslash). Tiempo = `OS::get_ticks_msec()`.
- Propiedad de sólo lectura `commit_count: int` (total de `frame` recibidos; para el test).
- Señales: `toplevel_added(id)`, `toplevel_removed(id)`.
- Destructor: `wl_server_destroy`.

## Shell (`shell/`)

- `shell.tscn`: agregar hijo `WaylandCompositor` ("Compositor") y un `CanvasLayer` (layer 1) con un
  `TextureRect` "View" (oculto, `expand = true`, `stretch_mode = STRETCH_SCALE`, `mouse_filter = STOP`).
- `ACTIVITIES`: reemplazar Terminal externa por entradas de tipo wayland:
  - `{"name": "Terminal", "wayland": ["alacritty"]}`
  - `{"name": "Gears", "wayland": ["es2gears_wayland"]}`
  - `{"name": "GTK", "wayland": ["gtk4-widget-factory"]}`
  (mantener Chat y Salir; el lanzamiento externo vía cage puede quedar como código muerto → borrarlo.)
- En `_ready`: `compositor.start()`; imprimir el socket.
- Abrir actividad wayland: View ocupa `(0, 48)` a `(vp.x, vp.y)`; `compositor.default_size = View.rect_size`;
  si esa actividad ya tiene un id vivo, reusarlo; si no, `launch`, y el primer `toplevel_added` sin
  dueño se asigna a la actividad actual. `focus(id)` al asignarlo. Cada frame con la actividad visible:
  `View.texture = compositor.get_texture(id)`.
- Barra superior ImGui igual que las actividades internas ("Inicio" + título de la ventana wayland).
  "Inicio" oculta View pero NO cierra la app (como Sugar). Si llega `toplevel_removed` de la actividad
  visible → volver al home.
- Input: `View.connect("gui_input", ...)`: MouseMotion → `pointer_motion(id, pos * tex_size / rect_size)`;
  MouseButton → motion + `pointer_button`, y `focus(id)` en press. Teclado: en `_unhandled_input` del
  shell, si hay actividad wayland visible y es `InputEventKey` → `compositor.key(event)` y marcar handled.
- Args de test adicionales:
  - `--type=<texto>`: cuando la actividad wayland abierta con `--open` ya tiene textura, esperar 60 frames
    y sintetizar `InputEventKey` (press+release, `physical_scancode`) por cada carácter del texto
    (minúsculas, dígitos, espacio; `\n` literal en el argumento → Enter) llamando `compositor.key` directo.
  - `--screenshot=<ruta>` con actividad wayland: capturar cuando haya textura + 90 frames (después del
    `--type` si lo hay); tope 900 frames (capturar igual e imprimir `screenshot: sin textura`).
    Antes de salir imprimir `commit_count=<n>`.

## Build

```sh
cd /home/icarito/Proyectos/godot3-box3d/godot
M=/home/icarito/Proyectos/godot3-box3d/godot-box3d-3,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules
scons -j8 platform=frt arch=x86_64 target=release_debug tools=yes frt_desktop_gl=yes production=yes lto=none progress=no extra_suffix=gdtk custom_modules=$M
scons -j8 platform=x11 target=release_debug tools=yes progress=no extra_suffix=gdtk custom_modules=$M
```

## Verificación (obligatoria; `timeout 90` delante de cada corrida)

Con `GDTK_GODOT=<bin frt gdtk>` y `SDL_VIDEODRIVER=wayland`, vía `session/gdtk-session` (cage anidado en GNOME):

1. `-- --open=Gears --screenshot=$PWD/comp-gears.png` → engranajes visibles; `commit_count` ≥ 30
   (prueba que los frame callbacks funcionan).
2. `-- --open=Terminal --type='echo hola gdtk\n' --screenshot=$PWD/comp-term.png` → se ve `hola gdtk`
   impreso en alacritty (prueba el teclado).
3. `-- --open=GTK --screenshot=$PWD/comp-gtk.png` → widget factory visible.
4. `./run_demo.sh` y `./run_shell.sh` siguen pasando.
5. Leer los PNG y describir lo que se ve. Agregar las corridas 1–3 a un `run_compositor.sh`.

Si un cliente no arranca, probar con `WAYLAND_DEBUG=1` en su entorno (se puede pasar como arg de
`env` temporalmente) y reportar el error literal. Si alacritty falla por EGL, no buscar reemplazo (`foot` no está instalado
y `xterm` es X11): reportarlo y seguir con los otros dos.

## Entregable

- Commit (archivos agregados por nombre) `feat(wayland): compositor anidado wlroots en el shell (pixman, copia CPU)`
  terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`. Sin push.
- Reporte breve: qué compila, qué muestran los 3 PNG, `commit_count` de cada corrida, desvíos del spec,
  errores literales de lo que quede roto. No modificar README.md ni los SPEC*.md.
