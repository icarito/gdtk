# Plan — Paridad de rendering con GNOME (meta: sesión diaria)

Estado: **propuesta**. Nace del análisis post-P4 (2026-10-05): hoy gdtk empata con
Mutter sólo en el caso "un fullscreen dmabuf en la salida principal, sin overlays".
Fuera de ese caso la brecha es arquitectónica (compositor anidado + sin KMS/planos).

Leer antes: `SPEC-rendimiento-compositor.md`, `SPEC-compositor.md`,
`SPEC-embedded-multi-output.md`, `SPEC-scanout-directo.md`,
`plans/HANDOFF-scanout-directo.md`, `plans/bastion-migration.md`,
`plans/tech-debt.md`, `sessions/2026-10-05_rendimiento-compositor.md`.

## 1. Objetivo

Acercar el rendering de gdtk al de una sesión GNOME/Mutter para **uso diario en
bastion**, medido, no por paridad de features. Meta concreta: con video fullscreen,
tiled y multi-monitor, CPU/GPU y fluidez comparables a GNOME (dentro del margen que
fije F0), sin los caminos software que motivaron el research original.

No-objetivos de este plan: HDR, color management, VRR como features de producto;
duplicar/espejar salidas; paridad de efectos del shell. Eso queda para después y no
debe bloquear la meta diaria.

## 2. Punto de partida (qué ya está)

- **P1 present-only**, **P2 explicit sync** cliente↔compositor embebido, **P3
  subsurfaces/popups**, **P4 scanout directo** (puente dmabuf→sway con pausa por
  overlay): entregados y commiteados.
- Paridad real sólo en el caso P4: app fullscreen dmabuf en la principal → el buffer
  llega a sway sin pasar por la composición de Godot. Es el equivalente al
  "unredirect fullscreen" de Mutter.
- Deuda conocida (ver `tech-debt.md`): sync explícito a sway sin cerrar, Xwayland y
  salidas secundarias fuera de P4, subsurfaces con contenido, sin medir GPU/frame.

## 3. Diagnóstico de la brecha (por qué no estamos a la par)

1. **Composición doble.** Cualquier cosa fuera del fullscreen solitario se compone
   dos veces: app → textura de Godot → escena del shell → ventana de Godot → sway.
   Mutter compone **una** vez. anchors: `shell/shell.gd:_update_tile`,
   `_imgui_frame`, `modules/wayland/wl_server.c:surface_state_import`.
2. **Sin KMS/planos.** El compositor embebido es headless sin CRTC
   (`SPEC-compositor.md` dec. 3, hoy parcialmente obsoleta): no hay plano de cursor
   de hardware, ni overlay planes (MPO), ni scanout por ventana; la única salida a
   hardware es P4 (un buffer, una salida, fullscreen, xdg).
3. **Cursor dibujado por software.** `shell/_apply_client_cursor` +
   `eis_cursor`: mover el mouse recomposición/redibujo; Mutter mueve un plano KMS sin
   redibujar.
4. **Damage/partial ausente.** El shell recompone de más; no hay daño por región.
   (Deuda M1: `wl_surface_damage_buffer` en FRT para span.)
5. **Scheduling.** Frame callbacks atados al loop de Godot + presentación de sway;
   sin vblank por salida, sin presentation feedback.
6. **Cobertura P4 y multi-output.** `GDTK_SPAN` OFF y Fase C sin validar en hardware.

Nota: `SPEC-compositor.md` decisiones 2 (pixman/shm-only) y 6 (sin
subsurfaces/popups) quedaron **superseded** por P2/P3/P4; al tocar esa spec, marcar
como histórico.

## 4. Estrategia: dos tracks, decididos por F0

- **Track A (sin KMS)**: exprimir el diseño anidado — damage/frame-scheduling,
  cursor por el host, cobertura de P4, multi-output. Mayor parte de la ganancia
  percibida con riesgo acotado y sin reescribir presentación.
- **Track B (KMS)**: dejar de ser anidado (backend DRM propio). Paridad real; es
  reescribir la capa de presentación. **No arrancar sin F0.**

## F0 — Medir y fijar la meta (bloqueante, primero)

Sin números no se elige track. Extender lo que ya existe, no inventar HUD nuevo.

- Medir gdtk **vs GNOME** en el mismo hardware (bastion) y mismo contenido:
  - RPC `state` (`compositor.dmabuf_commits`/`shm_commits`, `present.{light,full}`,
    `scanout_suspended`), `shell.log` (`compositor dmabuf`).
  - `bench/session_footprint.sh` (gdtk vs GNOME), `intel_gpu_top` (GPU %),
    `pidstat -t` para hilos del shell.
  - Latencia input→fotón (sonda simple; anotar el método).
- Escenarios: (a) video fullscreen; (b) Meet; (c) 2 ventanas tiled; (d) 2 monitores
  (`GDTK_SPAN=1` en aislado, nunca sesión viva).
- **Salida**: tabla gdtk vs GNOME (CPU shell, CPU GPU-proceso, GPU %, FPS app,
  frames compuestos/seg) y el **gate de decisión**:
  - fullscreen ya empata y la brecha está sólo en tiled/multi-ventana → **Track A**;
  - la brecha es grande en todos los casos → evaluar **Track B** antes de invertir más
    en A.

### F0 — Resultados (2026-10-05, bastion: i7-1185G7 / Iris Xe, 8 cores)

Método: `bench/f0_probe.sh` (sólo lectura; CPU del shell + "desktop" = session.slice+app.slice
o session scope, sin agentes; GPU por `gt_freq`; `[FRT_PERF]`/`[FRT_GPU]` con `FRT_PERF=1`
vía flag `~/.gdtk-frt-perf`). GLES3 pasó a default en `e7898cd` (`session/gdtk-session-sway`).

| escenario | shell CPU (% core) | render (ms) | GPU (ms) | present |
|---|---|---|---|---|
| gdtk GLES3 Home reposo | 3,3 | 0,09 | — | 0 |
| gdtk GLES3 video fullscreen (estático) | 4,3 | 0,22 | 0,7–1,8 | ≈ dmabuf 27/s |
| gdtk GLES3 video fullscreen, solo (Firefox) | 5,3 | 0,24 | 0,88 | ≈ dmabuf 26/s, **scanout off** |
| gdtk GLES3 2 tiled + video | 9,2 | 0,49 | 0,91 | ≈ dmabuf 26/s |
| gdtk GLES3 tiled + interacción | ~15 | 0,53 | 0,74 | ≈ dmabuf 24/s |
| GNOME video (mismo host) | gnome-shell 6,4 (5,5–9,2) | — | — | — |

Hallazgos:
1. **GLES3 fue el gran salto**: el mismo tiled/video que en GLES2 medía shell ~23–25% ahora
   da 9–15%, y habilita `[FRT_GPU]`. Sin GLES3 no hay ms de GPU.
2. **Fullscreen estático ya está a la par de GNOME** (shell 4,3–5,3% vs 6,4%; GPU <2 ms).
3. Bajo interacción/tiled el shell sube por **redibujo completo**: el costo restante es
   daño/partial (A1) y cursor (A2), no falta de KMS.
4. **P4/scanout casi no engancha en uso real**: con la ventana fullscreen y sola, `scanout`
   quedó **off**. Hipótesis: Firefox commitea el video en una **subsurface**, no en la surface
   raíz, y `scanout_candidate` exige la raíz (`t->tl->base->surface == st->surface`); también
   puede ser un popup xdg no vacío. Con es2gears (raíz directa) sí engancha. **A investigar**:
   aceptar la subsurface con contenido / mirar por-ventana; pero como GLES3 ya compone un
   fullscreen a ~5% de un core, la ganancia de scanout hoy es marginal.

Decisión: **Track A (sin KMS)**. No se justifica DRM/KMS todavía; priorizar A1 (damage) y
A2 (cursor del host). Caveats: entorno real del usuario, agentes de fondo, varianza por
interacción; GNOME no se midió en tiled/multi-monitor.

## Track A — sin KMS (por impacto)

**Estado 2026-10-05**: A1 (commit path) y A2 (cursor) ya están mayormente cubiertos.
- **A1** — el commit de una ventana ya usa `_present_commit` (present-only, P1): no rearma
  ImGui salvo UI viva (`shell.gd:1579-1582`, `1632`). Lo que queda es interacción/hover, que
  rearma por ser ImGui immediate-mode; damage fino dentro de ImGui es caro y de bajo retorno.
- **A2** — el cursor **ya lo dibuja el host** (SDL → sway); `eis_cursor` sólo es fallback
  X11/remoto y queda invisible en Wayland (`shell.gd:11298`, `_move_eis_cursor`). Bug corregido:
  el reset por cambio de surface del mismo toplevel (`c1b594e`) hacía reaparecer el cursor en
  video fullscreen (Firefox subsurface).
- **A3 — DIFERIDO (bajo retorno)**. Diagnóstico con `state.compositor.scanout_reason` (root-only):
  con el video fullscreen de Firefox el motivo queda **"sin commit del root (aun)"**, o sea el
  toplevel **nunca commitea la surface raíz con dmabuf** (el video va por **subsurface**). P4 sólo
  evalúa candidato en el commit del root ⇒ no puede enganchar. Soportarlo requiere scanout de
  **subsurface con contenido** (posición/stacking/daño) — complejo y riesgoso, y con GLES3 el
  fullscreen ya compone a ~5% de un core. Se deja el `scanout_reason` como diagnóstico permanente
  y se prioriza A5.
- Luego **A5** (multi-output / `GDTK_SPAN`) — requiere validación con 2 monitores reales.
- **A1 (perfilado, 2026-10-05)**: el costo está en **armar la UI ImGui**. `_imgui_frame`
  (GDScript) mide **~7,6 ms por build** y se invoca **24/s idle** y **48/s con motion** →
  ~18% / ~36% de un core (calza con lo medido). El ritmo lo decide `ImGuiCanvas::_notification`
  (`godot-box3d-3-gdtk/imgui/imgui_canvas.cpp:655`): arma a `update_hz`(4) por tiempo, a
  `input_hz`(60) mientras hay input reciente (≤250 ms), y **siempre** con `requested_redraw`
  (que el motion/hover dispara). Notas:
  - El `fps` del profiler **no** es la tasa del loop (`frame_time` excluye el sleep); el loop
    sí está paeado (~60).
  - Bajar `input_hz` 60→30 dio poco (48→40 builds/s) porque `requested_redraw` manda igual.
  - `input_hz`/`update_hz` **sí** se consumen (en el módulo C++), no eran variables muertas.
  - **Desglose por sección** (medido, tiled): `frame.draw()` = **6,6 ms (88%)**, `tiles` 0,7,
    `setup` 0,1, `home` 0,03, `tail` 0,02, `deco` 0,002. En **fullscreen** `frame.draw` early-returnea
    (`frame.gd:4117`, no hay Frame) → por eso el video fullscreen era barato.
  Próximo (sin KMS): **abaratir `frame.draw`** (`frame.gd:4112`, 4.576 líneas — perfilado interno de
  applets/layout) y/o no marcar `requested_redraw` por hover-motion. Medir en entorno quieto/aislado.


- **A1 — Damage/partial.** No recomponer la UI entera por commit: daño por
  ventana/región y `_present_commit` extendido. Depende de A-experimento M1
  (`wl_surface_damage_buffer` en FRT). anchors: `shell.gd` `_present_commit`,
  `commit_count`, `_update_tile`.
- **A2 — Cursor por el host.** Usar el cursor de sway (plano KMS de sway) en vez de
  dibujarlo dentro de la superficie de Godot, de modo que mover el mouse no
  redibuje la shell. anchors: `shell.gd:_apply_client_cursor`,
  `wayland_compositor` cursor, FRT/SDL cursor.
- **A3 — Cobertura de P4.** Xwayland, salidas secundarias, subsurfaces con
  contenido; y mantener scanout con overlays chicos (OSD de esquina) por región/hole
  o plano en vez de pausar todo. anchors: `wl_server.c` `scanout_candidate`,
  `scanout_has_visible_sibling`, `scanout_off_reimport`.
- **A4 — Frame scheduling.** Emitir frame callbacks/presentación al vblank de sway y
  por salida, no al loop de Godot. anchors: `wayland_compositor.cpp:end_frame`,
  `wl_server_frame_done`.
- **A5 — Multi-output.** Completar `SPEC-embedded-multi-output` Fases B/C y activar
  `GDTK_SPAN=1` por defecto recién tras M1 y validación con 2 monitores reales.
  anchors: `shell/output_layout.gd`, `shell/span_layout.gd`, `settings/pages/monitors.gd`.

## Track B — KMS real (paridad plena)

- **B1 — Desacoplar el compositor** a su hilo/proceso (P4 del
  `SPEC-rendimiento-compositor`) para no serializar import/render con Godot.
- **B2 — Backend DRM**: gdtk toma CRTC/planos → overlay planes, cursor de hardware,
  scanout por ventana, damage por plano.
- **B3 — Sync explícito end-to-end** hasta KMS.
- **B4 — Por salida**: frame callbacks en vblank, presentation feedback; color/HDR
  sólo si se decide como producto.

Prerequisito duro de B2: presentación multi-ventana nativa en FRT/SDL
(`SPEC-embedded-multi-output` §10). Sin eso, el anidado sigue siendo el techo.

## 5. Riesgos y decisiones abiertas

- Track B reescribe presentación y rompe el modelo "Godot cliente de sway": costo y
  riesgo altos; sólo con F0 a favor.
- A2 (cursor del host) puede chocar con pointer lock y cursor por-surface
  (`request_set_cursor`); evaluar interacción antes de diseñar.
- Metas de "paridad" pueden inflarse: anclar todo a la medición de F0 y a la meta de
  uso diario de `plans/bastion-migration.md`.

## 6. Verificación y criterios de aceptación

- Cada fase: instancia aislada (`bench/span_bench.sh` como molde: runtime/puerto
  propios, `GDTK_ISOLATED=1`), tests nuevos, y el **gate numérico de F0**.
- Aceptación: bastion diario con video, tiled y 2 monitores sin brecha perceptible y
  CPU/GPU del shell comparables a GNOME; ningún camino software forzado.

## 7. Orden propuesto

1. **F0** (medir, fijar gate). **HECHO** (2026-10-05): decisión **Track A**; GLES3 default
   ya entregado (`e7898cd`). ← siguiente acción.
2. **A1 + A2** (damage + cursor del host) — es donde quedó el costo restante.
3. **A3 + A4 + A5** (cobertura P4, scheduling, multi-output).
4. Re-evaluar **B1→B4** con los números de F0 y el resultado de A.

## 8. Archivos previstos

- `shell/shell.gd`, `shell/host.gd`, `shell/output_layout.gd`,
  `shell/span_layout.gd`, `settings/pages/monitors.gd`.
- `modules/wayland/{wl_server.c,wayland_compositor.cpp,scanout.c}`.
- `platform/frt` (damage, cursor/SDL, presentación multi-ventana).
- `bench/` (medición gdtk vs GNOME), `tests/`.
- Specs a actualizar: `SPEC-compositor.md` (marcar superseded), `SPEC-scanout-directo.md`.
