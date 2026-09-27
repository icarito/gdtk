# SPEC — Paso 7: popups y subsurfaces en el compositor (reusando wlroots)

Hoy cada ventana wayland se muestra con UNA textura (la surface raíz del toplevel). Tooltips, menús,
combos (xdg_popup) y subsurfaces no se ven y el input siempre va a la raíz. Objetivo: dibujar y
rutear input a **todo el árbol de surfaces** de cada toplevel, reusando lo que wlroots ya resuelve.
Leer antes: `modules/wayland/*`, `shell/shell.gd`, `shell/shell.tscn`.

## Reglas (igual que antes)

- Repo `/run/media/icarito/DATA/icarito/Proyectos/gdtk`; motor `/home/icarito/Proyectos/godot3-box3d/godot`
  (sólo binarios con sufijo `gdtk`; no tocar su git/fuentes; no `scripts/build.sh`). wlroots **0.20**.
- `git add` por nombre (archivo ajeno sin trackear en `shell/`). Sin push. No investigar la config zsh.
- Verificar cada firma contra `/usr/include/wlroots-0.20`.

## Ya hecho (no rehacer)

`wl_server.c` ya tiene (commit anterior): configure inicial de popups (`handle_new_popup` →
`wlr_xdg_surface_schedule_configure` en `initial_commit`) y `wl_server_frame_done` manda frame
callbacks a todo el árbol con `wlr_xdg_surface_for_each_surface`. Sin eso GTK4 se congelaba.

## Decisiones (reusar wlroots; no escribir a mano lo que ya existe)

1. **Layout**: `wlr_xdg_surface_for_each_surface(tl->base, iter, data)` da cada surface (raíz,
   subsurfaces, popups) con `(sx, sy)` relativos a la raíz y **en orden de dibujo**. NO calcular
   posiciones de popups a mano. NO usar `wlr_scene` (exige renderer; ver README/decisión pixman-less).
2. **Hit-test**: `wlr_xdg_surface_surface_at(tl->base, x, y, &sub_x, &sub_y)` para saber qué surface
   está bajo el puntero (popups primero). `pointer_motion` recibe coords relativas a la raíz y hace
   `wlr_seat_pointer_notify_enter(seat, surface, sub_x, sub_y)` si cambió la surface, luego motion.
   Si no hay surface bajo el punto: `wlr_seat_pointer_clear_focus`.
3. **Dismiss de popups**: lo hace el grab de popups de wlroots (el cliente pide `xdg_popup.grab` y
   wlroots manda `popup_done` al clickear fuera). No implementar nada propio; sólo confirmar que
   funciona pasando los eventos por el seat como ya se hace.
4. **Buffers por surface**: generalizar el camino actual (dmabuf→EGLImage / shm→puntero) de "la raíz"
   a "cualquier surface del árbol": escuchar `commit` de cada `wlr_surface` del árbol (o, más simple,
   en cada `wl_server_dispatch` recorrer el árbol y para cada surface cuyo `current.buffer` cambió
   desde la última vez —comparar puntero y `current.seq` si existe— reimportar). Mantener el
   `wlr_buffer_lock/unlock` por surface. Clave de surface = puntero `wlr_surface*` como `uint64`.
   Limpiar el estado de una surface en su `events.destroy`.
5. **API C** (reemplaza los callbacks por-toplevel de frame/dmabuf por por-surface):
   ```c
   typedef struct { uint64_t key; int x, y, w, h; } wl_server_layer;
   // Llena hasta max capas del toplevel id en orden de dibujo; devuelve cuántas.
   int wl_server_layers(wl_server *s, int id, wl_server_layer *out, int max);
   // callbacks: frame(ud, id, key, rgba/format/stride, w, h) y dmabuf(ud, id, key, w, h)
   void wl_server_bind_dmabuf(wl_server *s, uint64_t key, unsigned int texid);
   ```
6. **Godot (`WaylandCompositor`)**: textura por `key` (Dictionary key→ImageTexture). Nuevo método
   `get_layers(id) -> Array` de `{key, texture, rect: Rect2}` en orden de dibujo (llamando
   `wl_server_layers`). `get_texture(id)` sigue existiendo (textura de la raíz) por compatibilidad.
   Liberar texturas de keys que ya no aparecen.
7. **Shell**: la vista wayland pasa de un `TextureRect` a un `Control` "View" con hijos `TextureRect`
   (uno por capa, reusados por índice, `mouse_filter = IGNORE`, posicionados en `rect.position *
   escala`), dibujados en el orden devuelto. El input sigue entrando por `View.gui_input` con coords
   relativas a la raíz (la escala actual se mantiene). Las capas pueden salirse del rect de la raíz
   (menús que desbordan): está bien, `rect_clip_content = false`.

## Build

```sh
cd /home/icarito/Proyectos/godot3-box3d/godot
M=/home/icarito/Proyectos/godot3-box3d/godot-box3d-3,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules
scons -j8 platform=frt arch=x86_64 target=release_debug tools=yes frt_desktop_gl=yes production=yes lto=none use_static_cpp=no progress=no extra_suffix=gdtk imgui_implot3d=yes custom_modules=$M
```

## Verificación (obligatoria)

Usar el control remoto (paso 6: `mcp/gdtk_mcp.py` o JSON-RPC directo, ver `tests/`) sobre el shell en
cage anidado, con **GTK** (`gtk4-widget-factory`):
1. Abrir GTK; `move` sobre un botón con tooltip (p.ej. el de la barra de título o un toggle) y
   esperar 2 s → `screenshot` `pop-tooltip.png`: el tooltip visible junto al widget.
2. `click` en un combo (p.ej. "Andrea" / "Otto" en la primera página) → `screenshot`
   `pop-combo.png`: la lista desplegada visible y bien ubicada; `click` en otra opción → el combo
   cambia (screenshot `pop-combo-2.png`).
3. Abrir el menú (botón ☰ de la barra) → `screenshot` `pop-menu.png`; `click` fuera → el menú se
   cierra (screenshot `pop-menu-closed.png`).
4. GTK sigue respondiendo 60 s después (commits siguen subiendo; screenshot final distinto del inicial
   al mover el puntero).
5. `./run_compositor.sh` (Gears/Terminal/GTK, dmabuf on) y `tests/control_test.sh` siguen pasando.
Leer todos los PNG y describirlos.

## Entregable

- Commit `feat(wayland): popups y subsurfaces (layout y hit-test de wlroots, textura por surface)`
  terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: qué muestran los PNG, desvíos, errores literales. No modificar README.md ni SPEC*.md.
