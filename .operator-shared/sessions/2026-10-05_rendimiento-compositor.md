# Sesión 2026-10-05 — Rendimiento del compositor (research + acciones cortas)

Pedido: “el rendimiento de gdtk está un poco mal, FPS en Google Meet y alto consumo de CPU
comparado con GNOME; revisá, tal vez el problema es arquitectural”. Después: “documentá este
research y tomá las acciones cortas de una vez”.

Contrato y modelo: `specs/SPEC-rendimiento-compositor.md` (nuevo).

## Veredicto

Sí, hay una causa **arquitectural** dominante: gdtk no puede igualar a GNOME en video por
construcción (dos compositores en serie, compositor embebido sin CRTC ⇒ sin direct scanout, y
reconstrucción de la UI ImGui por cada frame de app). Además hay agravantes concretos. Detalle
y anchors en el spec.

## Entregado (hecho en esta sesión)

1. **Frame callbacks atados a la presentación** (`modules/wayland/wayland_compositor.cpp`):
   `wl_server_frame_done()` se movió de `NOTIFICATION_PROCESS` a `end_frame()`. Ya no se manda
   un callback por cada tick del motor, sino por cada frame que el shell realmente presenta.
2. **Diagnóstico runtime permanente**:
   - `shell/host.gd`: `compositor dmabuf: on|off (...)` al arrancar (queda en `shell.log`).
   - `shell/remote.gd` RPC `state`: `compositor: {dmabuf, dmabuf_commits, shm_commits}`.
3. **Build + instalación en bastion**: gdtklite reconstruido (incremental, 7.5 s) e instalado en
   `~/gdtk/bin/godot-gdtk`; backup del binario anterior en `~/gdtk/bin/godot-gdtk.prev`.
   Scripts (`shell/host.gd`, `shell/remote.gd`) sincronizados a `~/gdtk/`.

No se commiteó. No se tocó `shell.gd` más allá de lo anterior.

## Evidencia / validación

Harness aislado: `sway` headless (`WLR_BACKENDS=headless WLR_RENDERER=pixman`,
`XDG_RUNTIME_DIR=/tmp/kilo/wl`) + el shell como cliente SDL/wayland, `--open=Gears
--screenshot`. Software GL (llvmpipe), pero dmabuf quedó `on`.

| corrida | binario | resultado |
|---|---|---|
| baseline | `~/gdtk/bin/godot-gdtk` viejo | `commit_count=60 dmabuf_commits=60 shm_commits=0 dmabuf: on`, png 1280×720 stdev 33.26 |
| nuevo | gdtklite rebuild | `commit_count=57 dmabuf_commits=57 shm_commits=0 dmabuf: on`, png stdev 33.26 |
| nuevo + `GDTK_FORCE_SHM=1` | gdtklite rebuild | `commit_count=59 dmabuf_commits=0 shm_commits=59 dmabuf: off (forzado)` |
| desplegado | `~/gdtk/bin/godot-gdtk` nuevo + `~/gdtk/shell` | `commit_count=60 dmabuf_commits=60 dmabuf: on`, png stdev 33.26 |

`parse_check.gd` con el binario instalado: los 17 scripts en `ok` (rc 134 al salir es el crash
conocido, `plans/tech-debt.md`). Frame callbacks fluyen con el cambio (Gears commitea ~60 frames).

Cierre del harness: `sway` headless detenido; `/tmp/kilo/wl` queda como runtime de pruebas.

## Decisiones

- **No** se aplicaron cambios de motor sin poder validarlos: el harness headless permitió
  verificar el cambio de `frame_done` (Gears + shm) antes de instalar.
- El redibujo completo del shell (P1 del spec) es la mayor ganancia de CPU, pero toca el
  contrato de presentación (`ImGuiCanvas` + `shell.gd`) y necesita iteración visual: queda como
  próximo paso, no como acción corta a ciegas.
- La advertencia de subsurfaces de Firefox y el explicit sync quedan documentados (P2/P3).

## Cómo retomar

- Próximo y mayor: **P1 present-only** (spec §“Plan pendiente”). Anclar en `shell.gd:1496` y
  `imgui_canvas.cpp` (señal `redrawn`); probar en instancia anidada aislada antes de instalar.
- Medir en la próxima sesión gdtk: `shell.log` (línea `compositor dmabuf:`) + RPC `state`
  (`compositor.dmabuf_commits`/`shm_commits` en dos lecturas) + HUD F1 (`fps 0`).
- **Rollback del binario**: `cp ~/gdtk/bin/godot-gdtk.prev ~/gdtk/bin/godot-gdtk` (reinicia la
  sesión para tomar el cambio de motor).
- Verificar en sesión real (no headless): notificaciones layer-shell, OSD y menús de
  Firefox/Xwayland siguen pintando tras atar los callbacks a la presentación.
