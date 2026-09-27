# SPEC — Paso 8: diálogos y ventanas sin actividad

Hoy el shell sólo muestra un toplevel si viene de un `launch` pendiente de una actividad
(`_on_toplevel_added` en `shell/shell.gd`). Todo lo demás queda invisible:
- **Diálogos** (GTK "About", selectores de archivo): son toplevels con `parent`. Si es modal, la ventana
  padre queda insensible esperando un diálogo que no se ve → parece colgada.
- **Ventanas lanzadas desde otra app** (p.ej. `firefox` desde la terminal): no tienen actividad → nadie
  las muestra.
Leer antes: `shell/shell.gd`, `shell/remote.gd`, `modules/wayland/*` (capas por surface del paso 7,
escala 1:1 con `get_geometry`, `view_offset`).

## Reglas (igual que antes)

- Repo `/run/media/icarito/DATA/icarito/Proyectos/gdtk`; motor `/home/icarito/Proyectos/godot3-box3d/godot`
  (sólo binarios con sufijo `gdtk`; no tocar su git/fuentes). wlroots **0.20**; verificar firmas en
  `/usr/include/wlroots-0.20`. `git add` por nombre (archivo ajeno sin trackear en `shell/`). Sin push.
- Build:
  ```sh
  cd /home/icarito/Proyectos/godot3-box3d/godot
  scons -j8 platform=frt arch=x86_64 target=release_debug tools=yes frt_desktop_gl=yes production=yes lto=none use_static_cpp=no progress=no extra_suffix=gdtk custom_modules=/home/icarito/Proyectos/godot3-box3d/godot-box3d-3,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules
  ```
- **No** usar `pkill -f`/`pgrep -f` con patrones que aparezcan en tu propia línea de comando (mata tu shell).

## 1. C / nodo: exponer parent y app_id

- `wl_server.h`: `int wl_server_parent(wl_server *s, int id)` → id del toplevel cuyo `tl` es
  `t->tl->parent` (0 si no tiene); `const char *wl_server_app_id(wl_server *s, int id)` (`tl->app_id` o "").
- Señal nueva opcional no hace falta: el padre puede cambiar (`tl->events.set_parent`); basta con
  consultarlo en cada frame.
- `WaylandCompositor`: `get_parent(id) -> int`, `get_app_id(id) -> String`.

## 2. Shell: diálogos sobre su padre

- Un toplevel con padre es un **diálogo**: no se asigna a ninguna actividad; se dibuja **encima de la
  vista de su ventana raíz** (subir por `get_parent` hasta el toplevel sin padre), **centrado** en la
  vista (usar `get_geometry` del diálogo para centrar el contenido, sin sombras), con sus capas (popups
  incluidos, igual que la ventana principal). Varios diálogos: en orden de creación, el último arriba.
- Al aparecer un diálogo: `set_size` NO (que use su tamaño preferido), `compositor.focus(dialog_id)`.
  Al cerrarse: foco de vuelta a la ventana que quede arriba (otro diálogo o la raíz).
- **Input**: hit-test de arriba hacia abajo: si el puntero cae dentro del rect (geometría) de un diálogo
  → `pointer_motion(dialog_id, coords locales del diálogo)`; si no, la ventana raíz como hoy. Botones
  al último destino del motion. Teclado al que tenga foco (el diálogo más reciente).
- Si la actividad de la raíz no está visible, el diálogo tampoco (se verá al volver a ella).

## 3. Shell: ventanas sin actividad → actividad dinámica

- Toplevel **sin padre** que no corresponde a un `launch` pendiente → crear en caliente una actividad
  wayland (como ya hace `launch` en `remote.gd`) con nombre = `app_id` capitalizado sin dominio
  (`org.mozilla.firefox` → `Firefox`; si vacío, el título; si también, `Ventana <id>`), asignarle el
  id, agregarla al anillo, y **abrirla** (una ventana nueva pasa al frente, como en cualquier
  escritorio). Si el nombre ya existe, sufijo ` 2`, ` 3`...
- Cuando esa ventana se cierra, quitar la actividad dinámica del anillo (las fijas de `ACTIVITIES`
  originales nunca se quitan). Si estaba visible → home.
- `state` del control remoto debe reflejar todo (actividad de cada ventana; diálogos con `"parent": id`).

## Verificación (obligatoria; cage anidado + control remoto como en `tests/`)

1. Abrir GTK → menú ☰ → "About GTK Widget Factory" (o el ítem About que exista) → `screenshot`
   `win-about.png`: diálogo visible centrado sobre la widget factory. Clic en su botón de cerrar (o
   `key Escape`) → `screenshot` `win-about-closed.png`: diálogo cerrado y la widget factory responde
   (p.ej. click en un checkbutton cambia su estado).
2. Abrir Terminal y `type` `firefox\n` (si firefox no está, `gtk4-demo\n`) → esperar hasta 20 s a que
   aparezca una actividad nueva en `state` → `screenshot` `win-firefox.png`: la ventana visible y la
   actividad nueva en el anillo al volver a home (`home` + `screenshot` `win-ring.png`).
   Cerrar la ventana (`close_window`) → la actividad desaparece del anillo.
3. `./run_compositor.sh`, `./run_shell.sh`, `tests/control_test.sh` siguen pasando.
Leer todos los PNG y describirlos.

## Entregable

- Commit `feat(shell): diálogos sobre su ventana padre y actividades dinámicas para ventanas sueltas`
  terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: qué muestran los PNG, desvíos, errores literales. No modificar README.md ni SPEC*.md.
