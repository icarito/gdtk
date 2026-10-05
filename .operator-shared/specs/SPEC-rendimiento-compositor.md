# SPEC — Rendimiento del compositor embebido y del shell

Síntoma (2026-10-05, bastion): con gdtk como sesión, FPS bajo en Google Meet y CPU
mucho más alto que en GNOME. Este doc fija el **modelo**, las **causas medidas en el
código** y el **plan**. Nace del research de esa fecha; el estado de entrega está en
`sessions/2026-10-05_rendimiento-compositor.md`.

Leer antes: `SPEC-architecture.md` (capas), `SPEC-compositor.md` (compositor headless),
`SPEC-dmabuf.md` (zero-copy), `modules/wayland/*`, `shell/shell.gd`, `shell/layers.gd`.

## El modelo (y por qué GNOME gana por construcción)

```
GNOME:  app ──dmabuf──> Mutter (C: damage tracking, frame callbacks en vblank del CRTC,
                          direct scanout de la ventana fullscreen a un plano de HW)
gdtk:   app ──dmabuf──> wlroots EMBEBIDO (headless, SIN output/CRTC)
                              │  EGLImage -> ImageTexture de Godot
                              ▼
        sway ── scanout <── shell (Godot/GLES2) rearma TODA la UI ImGui + dibuja ventanas
```

- El shell es **cliente fullscreen de sway**; las apps viven en un wlroots **headless** sin
  CRTC (`SPEC-compositor.md` dec. 3). No hay direct scanout posible: cada frame de app pasa
  por la textura de Godot, por la escena del shell y **después** la compone sway. Dos
  composiciones + una reconstrucción de UI por frame.
- Mutter no reconstruye su UI por cada frame de video y ata los callbacks al vblank; gdtk
  los ataba al tick del motor (ver abajo, ya corregido).

## Causas en el código (anchors)

1. **Redibujo total sin damage tracking.** Cualquier commit de una ventana visible marca
   busy y pide frame completo: `shell/shell.gd:1496` (`commit_count != last_commits` →
   `request_redraw`), `:1535` (`SLEEP_ACTIVE`). ImGui es immediate-mode: `_imgui_frame`
   rearma **toda** la UI (GDScript) aunque sólo haya cambiado el contenido de una ventana.
   Con video eso ocurre ~al ritmo del video.
2. **Frame callbacks atados al tick del motor** (CORREGIDO 2026-10-05). Antes
   `WaylandCompositor::_notification` llamaba `wl_server_frame_done()` en **cada**
   `NOTIFICATION_PROCESS`; el reloj de las apps seguía al tick de Godot (~60 Hz o el sleep
   que hubiera) y no a la presentación. Ahora se emite en `end_frame()` (ver más abajo).
   `ImGuiCanvas` ya emite `redrawn` sólo cuando presenta
   (`modules/imgui/imgui_canvas.cpp:686` en el fork).
3. **Todo en el hilo principal y serializado.** `wl_server_dispatch` + import dmabuf
   (`eglCreateImageKHR`/`glEGLImageTargetTexture2DOES` por commit, sin explicit sync,
   `SPEC-dmabuf.md` §5, `modules/wayland/wl_server.c` `wl_server_bind_dmabuf`) +
   reconstrucción de UI + render, en un solo hilo. La app espera a ese loop.
4. **Riesgo de camino shm/software.** Si dmabuf no está disponible, `launch()` fuerza
   `LIBGL_ALWAYS_SOFTWARE=1` + `GSK_RENDERER=cairo` para todas las apps
   (`modules/wayland/wayland_compositor.cpp` `launch`) y el shm convierte píxel a píxel en
   C++ (`_on_frame`). Medir con `dmabuf_state`.
5. **Churn de subsurfaces de Firefox.** Una sesión dejó 14 150 líneas
   `Couldn't map window ... as subsurface because its parent is not mapped`
   (`~/.local/state/gdtk/shell.prev.log`): el timing de map de popups/subsurfaces hace
   reintentar a Firefox, y cada intento escribe a stderr.

## Decisión tomada: frame callbacks en la presentación (hecho)

`wl_server_frame_done()` se llama en `WaylandCompositor::end_frame()`
(`modules/wayland/wayland_compositor.cpp`), que corre en la señal `redrawn` de
`ImGuiCanvas` (conectada en `shell/layers.gd:23`), y **no** en `NOTIFICATION_PROCESS`. El
cliente no dibuja "al ritmo del motor" sino al ritmo al que el shell realmente mostró un
frame.

- `end_frame()` ya era load-bearing (visibilidad/throttle por `drawn`/`wl_server_set_visible`),
  así que la conexión es confiable.
- Capas y override-redirect de Xwayland también piden redraw por commit: sus surfaces pasan
  por `surface_state_import` → `_count_commit` (`wl_server.c:1575` para layer surfaces,
  `:2041` para xors). Por eso no se cuelgan al atar el callback a la presentación.
- Con `update_hz = 4` (`shell/shell.gd:1275`) el canvas presenta al menos 4 Hz en reposo:
  nunca se deja de mandar callbacks del todo.

Riesgo residual a verificar en sesión real: notificaciones layer-shell (mako), OSD y menús
de Firefox/Xwayland. Si algo dejara de pintar, volver el binario `~/gdtk/bin/godot-gdtk.prev`.

## Plan pendiente (por impacto)

- **P1 — present-only (mayor ganancia de CPU).** No rearmar la UI ImGui cuando sólo cambió
  el contenido de una ventana: marcar el canvas sucio (p. ej. `CanvasItem.update()` sobre
  `view`) en vez de `request_redraw()` en el camino de commits. `shell.gd:1496`; las ventanas
  son `TextureRect` hijos de `view` (`shell.gd:2386`–`:2425`), y `ImGuiCanvas` conserva sus
  canvas items entre builds (`imgui_canvas.cpp`). Verificar con la caja `update_hz`/`input_hz`
  (`shell.gd:1269`–`:1276`) y que la UI que sí cambia siga pidiendo `request_redraw`.
- **P2 — explicit sync en dmabuf** (`linux-drm-syncobj`) para no bloquear el hilo principal
  en el import. `SPEC-dmabuf.md` §5.
- **P3 — map de popups/subsurfaces**: arreglar el parent-mapped y bajar el ruido de Firefox
  (`wl_server.c`, popup configure/map).
- **P4 — arquitectural**: separar el compositor a su hilo/proceso, o ceder el scanout directo
  a la ventana activa (hoy imposible sin output/CRTC; cruzar con `SPEC-embedded-multi-output`).
- **P5 — medir**: HUD F1 / RPC `state` y `hud_snapshot`, `dmabuf_state`, `dmabuf_commits` vs
  `shm_commits`; `bench/session_footprint.sh` gdtk vs GNOME.

## Diagnóstico permanente (hecho)

- `host.gd` imprime `compositor dmabuf: on|off (...)` al arrancar (queda en `shell.log`).
- RPC `state` (`shell/remote.gd`) agrega `compositor: {dmabuf, dmabuf_commits, shm_commits}`.
