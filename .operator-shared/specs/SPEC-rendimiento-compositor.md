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

## Decisión tomada: present-only (hecho)

Ante un commit de ventana visible, el shell re-muestra sin rearmar ImGui
(`shell.gd:_present_commit`): `view.update()` (marca el canvas sucio) +
`compositor.send_frame_callbacks()` (frame callbacks de la presentación). Con UI viva
(exposé, `tile_anim`/`wm_anim`, Vecindario) cae al camino completo. Medido: `present
light=61 full=0`. La textura de la ventana se actualiza in-place (dmabuf/shm), así que no
hace falta reasignar `TextureRect`.

Antes de eso, los frame callbacks ya se atan a la **presentación**: `wl_server_frame_done()`
se llama en `WaylandCompositor::end_frame()` (señal `redrawn` de `ImGuiCanvas`), no en
`NOTIFICATION_PROCESS`. Capas y xors también piden redraw por commit
(`surface_state_import` → `_count_commit`), así que no se cuelgan; `update_hz=4` garantiza
callbacks aun en reposo.

## Decisión tomada: sincronización explícita (hecho)

`linux-drm-syncobj-v1` anunciado (`wl_server.c:setup_syncobj`): en cada commit dmabuf con
punto de acquire, se espera el fence **en la GPU** (export del punto a `sync_file` +
`eglWaitSyncKHR` sobre `EGL_ANDROID_native_fence_sync`), y el release se libera con el buffer
(`wlr_linux_drm_syncobj_v1_state_signal_release_with_buffer`). Fallback a implicit sync si
falta EGL fence o el punto no materializó. Estado en `shell.log` y RPC (compositor.explicit_sync);
`GDTK_NO_EXPLICIT_SYNC` fuerza el camino viejo. Probado en cupid (Haswell): `on`, Firefox por
dmabuf sin regresiones (ningún cliente optó aún por adjuntar puntos).

## Plan pendiente (por impacto)

- ~~**P1 — present-only**~~ y ~~**P2 — explicit sync**~~: hechos.
- **P3 — warning de subsurfaces**: es bookkeeping de GTK3/Firefox (cliente), no un bug del
  compositor; no se arregla desde acá. Mitigado el ruido propio del shell (`[cursor]`,
  `[osd-key]`, arrastre) con `GDTK_DEBUG_INPUT=1`.
- **P4 — arquitectural**: separar el compositor a su hilo/proceso, o ceder el scanout directo
  a la ventana activa (hoy imposible sin output/CRTC; cruzar con `SPEC-embedded-multi-output`).
- **P5 — medir**: HUD F1 / RPC `state` y `hud_snapshot`, `dmabuf_state`, `dmabuf_commits` vs
  `shm_commits`; `bench/session_footprint.sh` gdtk vs GNOME.

## Diagnóstico permanente (hecho)

- `host.gd` imprime `compositor dmabuf: on|off (...)` al arrancar (queda en `shell.log`).
- RPC `state` (`shell/remote.gd`) agrega `compositor: {dmabuf, dmabuf_commits, shm_commits}`.
