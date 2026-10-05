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
3. **Build + instalación en bastion**: gdtklite reconstruido (incremental, ~10 s) e instalado en
   `~/gdtk/bin/godot-gdtk`; backup del binario anterior en `~/gdtk/bin/godot-gdtk.prev`.
   Scripts sincronizados a `~/gdtk/`.
4. **P1 present-only** (mayor ahorro de CPU): ante un commit de ventana, el shell re-muestra
   re-marcando el canvas (`view.update()`) y manda los frame callbacks con
   `compositor.send_frame_callbacks()` (nativo), **sin** rearmar la UI ImGui
   (`shell.gd:_present_commit`). Con la UI viva (exposé, `tile_anim`/`wm_anim`, Vecindario) cae
   al camino completo. Medido headless: `present light=61 full=0` con Gears.
5. **`input_capture_cursor_test.gd`**: el harness no declaraba `chrome_drag`/`_capture_drag_held`
   (rotura desde 9cf7e57); `verify_all` queda verde.
6. **P2 explicit sync** (`linux-drm-syncobj-v1`): anunciado con feedback propio; en cada commit
   dmabuf con acquire, espera el fence en la GPU (`sync_file` + `eglWaitSyncKHR`) y libera el
   release con el buffer (helper de wlroots). Fallback a implicit sync; `GDTK_NO_EXPLICIT_SYNC`
   para desactivar. Estado en `shell.log` y RPC `state` (`compositor.explicit_sync`).

Commits: `d4661dd` (frame_done + present-only), `c1fca3f` (diagnóstico dmabuf), `6eabcbf`/
`350b1a6`/`9e13d2d` (docs), `ac5d938` (fix test), `1fc2431` (métricas present), `874e5b2` (P2).

## Prueba en cupid.local (2026-10-05)

Sesión gdtk de cupid (i5-4300U, Haswell) actualizada con `deploy.sh icarito@cupid.local` y
shell reiniciado (sin apps abiertas; autorizado por el operador). Resultado:
`compositor dmabuf: on`, `compositor sync explícito: on`. Firefox lanzado por el RPC: 73
commits dmabuf + 3 shm, y **`present {light:76, full:0}`** (P1 evitando el rebuild de ImGui).
Ningún cliente adjuntó aún puntos de sync (Mesa/Firefox no optaron), así que el camino
acquire/release no se ejercitó end-to-end; el global queda anunciado para cuando un cliente lo
use. Sin crash-loop (el rc=134 fue el crash conocido al matar el shell viejo).

No se commiteó el WIP ajeno (`shell.gd`/`remote.gd`: PEER_CALL, lanzamiento con `sh -c`, RPC
`peers`/`share_window`), que sigue en el árbol.

## Evidencia / validación

Harness aislado: `sway` headless (`WLR_BACKENDS=headless WLR_RENDERER=pixman`,
`XDG_RUNTIME_DIR=/tmp/kilo/wl`) + el shell como cliente SDL/wayland, `--open=Gears
--screenshot`. Software GL (llvmpipe), pero dmabuf quedó `on`.

| corrida | binario | resultado |
|---|---|---|
| baseline | `~/gdtk/bin/godot-gdtk` viejo | `commit_count=60 dmabuf_commits=60 shm_commits=0 dmabuf: on`, png 1280×720 stdev 33.26 |
| frame_done | gdtklite rebuild | `commit_count=57 dmabuf_commits=57 dmabuf: on`, png stdev 33.26 |
| + present-only | gdtklite rebuild (con contador temporal) | `present light=61 full=0`, `commit_count=61 dmabuf_commits=61`, y `FORCE_SHM` 61 por shm |
| desplegado | `~/gdtk` (present-only) | `commit_count=61 dmabuf_commits=61 dmabuf: on`, png stdev 33.28 |

`verify_all`: todo `ok` salvo 3 cuelgues conocidos por `RemoteInput` (sin FAIL).

Cierre del harness: `sway` headless detenido; `/tmp/kilo/wl` queda como runtime de pruebas.

## Decisiones

- **No** se aplicaron cambios de motor sin poder validarlos: el harness headless permitió
  verificar el cambio de `frame_done` (Gears + shm) antes de instalar.
- El redibujo completo del shell (P1 del spec) es la mayor ganancia de CPU, pero toca el
  contrato de presentación (`ImGuiCanvas` + `shell.gd`) y necesita iteración visual: queda como
  próximo paso, no como acción corta a ciegas.
- La advertencia de subsurfaces de Firefox y el explicit sync quedan documentados (P2/P3).

## Verificado / descartado

- **linux-dmabuf con feedback v4 correcto** (`wl_server.c:setup_dmabuf`: main_device = render
  node, tranche con formatos, versión 4). No es la causa de que las apps caigan a software.
- **P1 no rompe GTK/terminal**: Terminal (shm/dmabuf) 7 commits y captura válida;
  `gtk4-widget-factory` no renderiza headless **igual con el binario viejo** (no es regresión).
- **`control_test.sh` `gdtk_state view=home`** falla por carrera de arranque de la primera
  llamada (falla con y sin el campo `compositor`); preexistente, ajeno a P1.
- RPC `state` ahora expone `present:{light,full}` (commit) para medir P1 en la sesión real.

## Cómo retomar

- **P1 y P2: hechos.** Próximo: **P3** map de popups/subsurfaces (ruido de Firefox) y **P4**
  arquitectural (compositor en otro hilo/proceso o scanout directo).
- Medir en la sesión gdtk: `shell.log` (`compositor dmabuf:`, `compositor sync explícito:`) y RPC
  `state` (`compositor.dmabuf_commits`/`shm_commits`, `compositor.explicit_sync`, `present`).
- **Rollback del binario**: `cp ~/gdtk/bin/godot-gdtk.prev ~/gdtk/bin/godot-gdtk` (reinicia la
  sesión para tomar el cambio de motor).
- Verificar en sesión real (no headless): notificaciones layer-shell, OSD y menús de
  Firefox/Xwayland siguen pintando; arrastre/exposé siguen tomando el camino completo.
