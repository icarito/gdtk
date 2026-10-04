# SPEC — Paso 5: zero-copy dmabuf en el compositor (GL de verdad en los clientes)

Hoy (`SPEC-compositor.md`, ya hecho) el compositor usa renderer pixman y sólo `wl_shm`: los clientes
dibujan por software (`LIBGL_ALWAYS_SOFTWARE=1`) y cada commit se copia dos veces por CPU
(`wlr_texture_read_pixels` + `ImageTexture::set_data`). Objetivo: los clientes usan la GPU y Godot
samplea sus buffers **sin copia**, importándolos como EGLImage en su propio contexto GL.
Leer antes: `modules/wayland/*`, `shell/shell.gd`.

## Reglas (igual que antes)

- Repo `/run/media/icarito/DATA/icarito/Proyectos/gdtk`; motor `/home/icarito/Proyectos/godot3-box3d/godot`
  (no tocar su git/fuentes, no `scripts/build.sh`, sólo binarios con sufijo `gdtk`).
- `git add` por nombre (hay un archivo ajeno sin trackear en `shell/`). Sin push.
- Verificar CADA firma contra `/usr/include/wlroots-0.19`, `/usr/include/EGL`, `/usr/include/GLES2`.

## Decisiones (no cambiarlas)

1. **Sin renderer en wlroots**: `wlr_compositor_create(display, 5, NULL)`. Se quita el renderer pixman.
   `wl_shm` con `wlr_shm_create(display, 2, formats, n)` (`wlr/types/wlr_shm.h`; formatos
   `DRM_FORMAT_ARGB8888`, `DRM_FORMAT_XRGB8888`). Seguir usando el backend headless.
2. **Leer el buffer nosotros** en el commit: `surface->current.buffer` (`struct wlr_buffer *`).
   - `wlr_buffer_get_dmabuf(buf, &attribs)` true → camino dmabuf.
   - si no, `wlr_buffer_begin_data_ptr_access(buf, WLR_BUFFER_DATA_PTR_ACCESS_READ, &data, &format, &stride)`
     → camino shm: pasar el puntero directo al callback (con su `format` y `stride`), sin copia en C;
     `wlr_buffer_end_data_ptr_access` al volver. En C++ convertir a RGBA8 una sola vez
     (ARGB8888/XRGB8888 little-endian = bytes B,G,R,A → swap R/B; XRGB → A=255).
   - Retener con `wlr_buffer_lock` el buffer vigente de cada toplevel y hacer `wlr_buffer_unlock` del
     anterior cuando llega uno nuevo (y en destroy). Así el cliente no reusa un buffer que Godot samplea.
3. **Todo lo EGL/GL en `wl_server.c`** (C), obteniendo funciones con `eglGetProcAddress`
   (`glBindTexture`, `glGetIntegerv`, `glEGLImageTargetTexture2DOES`) para no linkear libGL/libGLES.
   Linkear sólo `egl` (`pkg-config egl`). Display: `eglGetCurrentDisplay()` llamado dentro de
   `wl_server_create` (se llama desde `start()` en el hilo principal con el contexto de Godot activo).
   Si devuelve `EGL_NO_DISPLAY` (binario x11 = GLX) o faltan las extensiones
   `EGL_EXT_image_dma_buf_import(_modifiers)` o la función GL → **no** anunciar dmabuf (sólo shm) y
   loguear el motivo una vez. Idem si la env `GDTK_FORCE_SHM=1`.
4. **Anunciar linux-dmabuf** con `wlr_linux_dmabuf_v1_create(display, 4, &feedback)`, feedback armado a mano:
   - `main_device` = `st_rdev` de `stat("/dev/dri/renderD128")` (env `GDTK_DRM_RENDER_NODE` para cambiarlo).
   - un tranche (`wlr_linux_dmabuf_feedback_add_tranche`) con `target_device` = main_device y un
     `wlr_drm_format_set` llenado con `eglQueryDmaBufFormatsEXT` + `eglQueryDmaBufModifiersEXT`
     (omitir modifiers `external_only`; incluir `DRM_FORMAT_MOD_INVALID` si la lista viene vacía).
   - liberar sólo con `wlr_linux_dmabuf_feedback_v1_finish` después de crear (ya libera los
     `formats` de cada tranche; NO llamar además `wlr_drm_format_set_finish` sobre ellos → double free).
   - `wlr_linux_dmabuf_v1_set_check_dmabuf_callback`: aceptar sólo `n_planes == 1` y que
     `eglCreateImageKHR` funcione (crear y destruir). Si falla, el cliente cae a shm solo.
5. **Import en la textura de Godot**, sin parchear el motor:
   - Callback nuevo `void (*dmabuf)(void *ud, int id, int w, int h)`: el C++ asegura una `ImageTexture`
     del tamaño exacto (`create(w, h, Image::FORMAT_RGBA8, 0)` si no existe o cambió el tamaño) y llama
     `wl_server_bind_dmabuf(s, id, VS::get_singleton()->texture_get_texid(tex->get_rid()))`.
   - `wl_server_bind_dmabuf`: `eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attrs)`
     (width, height, `EGL_LINUX_DRM_FOURCC_EXT`, plane0 fd/offset/pitch y, si modifier != INVALID,
     `EGL_DMA_BUF_PLANE0_MODIFIER_LO/HI_EXT`); guardar `GL_TEXTURE_BINDING_2D` actual, `glBindTexture`
     al texid, `glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, image)`, restaurar el binding,
     `eglDestroyImageKHR` (la textura conserva el storage).
   - Comentario `// ponytail: sync implícita (Mesa/Intel); explicit sync (linux-drm-syncobj) si hay tearing`.
6. **Lanzamiento** (`WaylandCompositor::launch`): quitar `LIBGL_ALWAYS_SOFTWARE=1` y `GSK_RENDERER=cairo`
   salvo que el server haya quedado en modo sólo-shm (entonces mantenerlos).
7. Contadores de solo lectura `dmabuf_commits` y `shm_commits` (reemplazan/ademas de `commit_count`, que
   sigue siendo el total). Al salir con `--screenshot` imprimir `commit_count=… dmabuf_commits=… shm_commits=…`
   y `dmabuf: on|off (<motivo>)`.

## Build

```sh
cd /home/icarito/Proyectos/godot3-box3d/godot
M=/home/icarito/Proyectos/godot3-box3d/godot-box3d-3,/run/media/icarito/DATA/icarito/Proyectos/gdtk/modules
scons -j8 platform=frt arch=x86_64 target=release_debug tools=yes frt_desktop_gl=yes production=yes lto=none progress=no extra_suffix=gdtk imgui_implot3d=yes custom_modules=$M
scons -j8 platform=x11 target=release_debug tools=yes progress=no extra_suffix=gdtk imgui_implot3d=yes custom_modules=$M
```

## Verificación (obligatoria; `timeout 90` en cada corrida; `SDL_VIDEODRIVER=wayland`)

1. `./run_compositor.sh` con el binario FRT: Gears, Terminal y GTK con **`dmabuf_commits > 0`** y
   `dmabuf: on`. Leer los PNG: colores correctos (no R/B invertidos), imagen no volteada, igual que antes.
   Para Terminal usar `--open=Terminal` con alacritty lanzado con `-e sh` si hace falta que el tecleo
   se ejecute (ver reporte anterior sobre zsh), pero NO es obligatorio que el comando se ejecute.
2. Mismo `run_compositor.sh` con `GDTK_FORCE_SHM=1`: `dmabuf: off (forzado)`, `shm_commits > 0`,
   PNG correctos (valida el camino shm nuevo sin `read_pixels`).
3. Con `GDTK_VIDEO_DRIVER=GLES2` (ya lo soporta `session/gdtk-session`): Gears con `dmabuf_commits > 0`.
4. `./run_demo.sh` y `./run_shell.sh` siguen pasando.
5. Agregar las corridas 2 y 3 a `run_compositor.sh`.

## Entregable

- Commit `feat(wayland): zero-copy dmabuf vía EGLImage en la textura de Godot; shm sin read_pixels`
  terminado en `Co-Authored-By: DeepSeek v4.1 Flash (Kilo) <noreply@kilo.ai>`.
- Reporte breve: contadores de cada corrida, qué muestran los PNG, desvíos, errores literales.
  No modificar README.md ni los SPEC*.md.
