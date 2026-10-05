# HANDOFF — Scanout directo (P4)

Para retomar con contexto fresco. Diseño completo en
`specs/SPEC-scanout-directo.md`; historia en `sessions/2026-10-05_rendimiento-compositor.md`
y deuda en `plans/tech-debt.md`.

## Objetivo (una línea)

Sacar el contenido de la ventana activa (fullscreen/axis-aligned) del camino de
Godot, para no pagar una pasada de composición por frame; mantener Frame/OSD/input.

## Estado a la fecha (2026-10-05)

Ya entregado y commiteado (no rehacer):

- **P1 present-only** (`d4661dd`): commit de ventana → `view.update()` +
  `send_frame_callbacks()` sin rearmar ImGui. Medido `present {light:>full}`.
- **Frame callbacks en la presentación** (`end_frame`, mismo commit).
- **P2 explicit sync** (`874e5b2`): `linux-drm-syncobj-v1` on por defecto; espera GPU
  del acquire, release con el buffer; `GDTK_NO_EXPLICIT_SYNC` para desactivar.
- **P3** (`fa72cad`): el warning de subsurfaces de Firefox es de GTK (cliente); se
  silenciaron los logs calientes del shell con `GDTK_DEBUG_INPUT`.
- Diagnóstico: `host.gd` imprime `compositor dmabuf:`/`compositor sync explícito:`;
  RPC `state` expone `compositor{dmabuf,explicit_sync,commits}` y `present{light,full}`.
- Desplegado en bastion y cupid; cupid corre P1+P2.

Pendiente: **P4**. PoC de F2 (opción B) **ya implementado y validado en instancia aislada**
el 2026-10-05 (ver abajo). Falta la parte de shell (app mode / gate con Frame) y deploy.

### Integración con shell y ciclo de vida (`b67fe49`, 2026-10-05)

Resuelto el solapamiento con overlays y el cierre del puente:

- `wl_server` expone `scanout_suspended` (`wl_server_scanout_set_suspended`/`_suspended`);
  el shell lo pausa desde `_scanout_tick()` (shell.gd) cuando dibuja un overlay:
  OSD de volumen/brillo, Frame, exposé o Vecindario. Al pausar, las ventanas en scanout
  vuelven al camino textura reimportando su último dmabuf (`scanout_off_reimport`), así
  no queda hueco antes del próximo commit. La reanudación es implícita (próximo dmabuf).
- El candidato se anula además si el toplevel tiene un popup abierto (menú del cliente,
  lo dibuja Godot y la subsurface lo taparía) o si otra ventana visible comparte la
  salida principal (`scanout_has_visible_sibling`); `wl_server_set_visible` re-evalúa y
  aparta sin esperar commits.
- `gdtk_scanout_reset()` destruye las subsurfaces al recrear/destruir el compositor
  embebido (llamado en `wl_server_create` y `wl_server_destroy`); antes quedaban
  huérfanas mostrando el último frame.
- RPC `state` → `compositor.scanout_suspended`. Test `tests/scanout_overlay_test.gd`
  (10 ok) sobre la política de pausa.

Validado e2e en sway headless aislado (`tools/verify_all.sh` sin FAIL; ver evidencia en
la sesión `sessions/2026-10-05_rendimiento-compositor.md`): fullscreen dmabuf congela
`dmabuf_commits`; `media show` → `scanout_suspended:true` y `dmabuf_commits` vuelve a
subir; al terminar el OSD se reanuda y se congela.


## Resultado PoC F2 opción B (2026-10-05)

**§7.1 resuelto: SÍ se puede.** SDL expone `info.info.wl.surface` en `SDL_SysWMinfo`
(`/usr/include/SDL2/SDL_syswm.h:295-303`) y FRT ya usa `SDL_GetWindowWMInfo` en
`platform/frt/frt_wl_gestures.cc`. Funciona con subsurfaces.

Implementado (motor, sin tocar `shell.gd`):

- `modules/wayland/scanout.c` + `scanout.h`: puente cliente hacia sway. Sobre la
  conexión Wayland de SDL abre cola privada, bindea `wl_compositor`/`wl_subcompositor`/
  `zwp_linux_dmabuf_v1`, crea una `wl_subsurface` de la ventana de Godot (input region
  vacía, `place_above`), y arma un `wl_buffer` dmabuf con `zwp_linux_buffer_params_v1`
  (fd compartido, zero-copy). Puentea el release de sway → `wlr_buffer_unlock` del
  compositor embebido.
- `modules/wayland/SCsub`: vendoriza `protocols/linux-dmabuf-v1.xml` y genera el
  protocolo cliente.
- `modules/wayland/wl_server.c`: en `surface_state_import`, si el toplevel raíz es xdg
  fullscreen en la salida principal y hay dmabuf, **presenta al host y no crea textura
  Godot**; refs `scanout_ref` retienen el `wlr_buffer` hasta el release del host;
  `scanout_on_release`/`scanout_off`; gate `GDTK_SCANOUT_DIRECT`.
- `modules/wayland/wayland_compositor.*`: `scanout_enabled()`/`scanout_state()`.
- `platform/frt/frt_wl_gestures.cc` (repo motor `godot-gdtk-slug/platform/frt`): pasa
  `wl_display`+`wl_surface` de SDL al módulo vía símbolo **weak** (`extern "C"`; cuidado:
  sin `extern "C"` el símbolo queda manglado y nunca enlaza).
- `shell/remote.gd`: RPC `state` → `compositor.scanout`/`scanout_on` (diagnóstico).

Validación aislada (sway headless `WLR_RENDERER=gles2`, Intel Iris Xe, es2gears):

- RPC `fullscreen` sobre el toplevel → `compositor.scanout == "on"`.
- `dmabuf_commits` **congelado** (459 en 6 s) con la app a 31 FPS → Godot no importa.
- Viewport de Godot entre 2 capturas (2 s): diff **0.0** (congelado). Salida de sway
  (`grim`): diff medio ~6-7 → la app anima en sway vía subsurface.

Limitaciones del PoC: solo xdg (no Xwayland), solo fullscreen en la **salida principal**,
`place_above` (sin transparencia: Frame/OSD quedan tapados; se necesita RGBA/alpha para el
hueco), sync explícito no reenviado a sway (confiar en implicit sync). Ciclo de vida de
subsurface **resuelto** en `b67fe49` (`gdtk_scanout_reset`); el solapamiento con overlays
se resuelve pausando el scanout (`b67fe49`). Gateado por `GDTK_SCANOUT_DIRECT` (off
por defecto ⇒ sin regresión).

Multi-monitor: Fase C (ventanas en salidas secundarias + cruce por arrastre + menú
"Mover a <monitor>") implementada en `shell/output_layout.gd` (`transfer_rect`,
`clamp_local`) y `shell/shell.gd`; tests `output_layout_test` ok=72, `span_layout_test`
ok=29, `window_output_transfer_test` ok=22, 0 fallas.

## Próximo paso

1. ~~Integrar en shell (app mode / apagar scanout al abrir Frame) y decidir transparencia
   para Frame/OSD encima.~~ Hecho (`b67fe49`): se pausa con overlay; **decisión: no hub
   de alpha**, se vuelve al camino textura mientras el overlay está visible.
2. ~~Reenviar/exponer sync explícito a sway y cerrar el ciclo de vida de la subsurface.~~
   Ciclo de vida cerrado (`gdtk_scanout_reset` + `1de3cac`). Sync explícito a sway
   **sigue pendiente**: hoy se confía en implicit sync (Mesa/Intel); documentado abajo.
3. F0 medir GPU/frame antes de generalizar (ver abajo). Pendiente; requiere sesión viva.
4. Siguiente alcance: Xwayland y salidas secundarias (hoy sólo xdg fullscreen en la
   principal) y subsurfaces de cliente con contenido (hoy sólo se miran popups).



## Anclajes de código

- Import dmabuf→EGLImage→texture: `modules/wayland/wl_server.c:3146`
  (`wl_server_bind_dmabuf`), sync en `syncobj_apply`.
- Capas/texturas hacia GDScript: `modules/wayland/wayland_compositor.cpp:913`
  (`get_layers`: `texture`/`rect`/`key`).
- Shell: `_fill_nodes` `shell/shell.gd:2479`, `_update_tile` `:2616`,
  `_present_commit` `:1548`.
- Sesión: `session/sway.conf` (ventana Godot fullscreen), `session/gdtk-session-sway`.
- Specs: `SPEC-compositor.md` (headless), `SPEC-dmabuf.md`, `SPEC-embedded-multi-output.md`
  (§8 ya prevé exportar el render target por dmabuf), `SPEC-session-continuity.md`.

## Comandos útiles

Build del motor (árbol aislado, incremental ~5-15 s). La línea `scons` completa
está en `deploy.sh`; basta correr el deploy local y, si no se quiere desplegar, usar
esa misma invocación `scons` desde
`/home/icarito/Proyectos/godot3-box3d/godot-gdtk-slug` (custom_modules apuntando a
`godot-box3d-3-gdtk` y a `modules/` de este repo, `extra_suffix=gdtklite`).

Tests y chequeo de parseo:

```sh
tools/verify_all.sh                       # mirar ok/FAIL (3 cuelgues conocidos por RemoteInput)
~/gdtk/bin/godot-gdtk --no-window --path shell -s $PWD/tests/parse_check.gd
```

Harness headless aislado (como se usó en P1/P2:

```sh
mkdir -p /tmp/kilo/wl && chmod 700 /tmp/kilo/wl
env XDG_RUNTIME_DIR=/tmp/kilo/wl WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
  WLR_RENDERER=pixman sway -d --unsupported-gpu &
env XDG_RUNTIME_DIR=/tmp/kilo/wl WAYLAND_DISPLAY=wayland-1 SDL_VIDEODRIVER=wayland \
  <bin> --fullscreen --path shell -- --open=Gears --screenshot=/tmp/kilo/x.png
```

Deploy y prueba real (cupid, autorizado a disponer de la sesión):

```sh
./deploy.sh icarito@cupid.local
ssh cupid.local 'kill <pid-shell>; sleep 12; tail -25 ~/.local/state/gdtk/shell.log'
# rollback de motor: cp ~/gdtk/bin/godot-gdtk.prev ~/gdtk/bin/godot-gdtk
```

## Gotchas (leer antes de tocar)

- `modules/wayland/` es **motor**: recompilar y activar sólo con corte controlado
  (`SPEC-session-continuity.md`). No reiniciar la sesión de bastion con VS Code abierto.
- Todo GL corre en el **hilo de Godot** (el EGL es el suyo): no bloquear ahí.
- Los frame callbacks se mandan en `end_frame` (presentación). Capas y xors también
  piden redraw por commit (`surface_state_import` → `_count_commit`): no romper eso.
- `get_layers(id)` **cuenta como dibujado**: si se deja de dibujar una ventana por B,
  revisar la visibilidad/throttle (`wl_server_set_visible`).
- El árbol tiene **WIP ajeno** en `shell/shell.gd` y `shell/remote.gd`
  (PEER_CALL, `sh -c`, RPC `peers`/`share_window`): no revertir; stagear por hunks.
- `tests/input_capture_cursor_test.gd` ya se arregló (`ac5d938`); el harness extrae
  funciones reales de `shell.gd`, así que agregar funciones que referencien variables
  nuevas puede romperlo.
- Tests con el binario dev tools cuelgan si cargan `shell.gd` (falta `RemoteInput`):
  es ruido conocido; mirar ok/FAIL.

## Decisiones ya tomadas

- P4 por fases **A (app mode) + B (puente dmabuf)**; **C (quitar sway) descartada** por
  ahora.
- B sólo para fullscreen/axis-aligned, con fallback automático y flag
  `GDTK_SCANOUT_DIRECT`.

## No hacer

- No quitar sway ni reescribir el WM en este corte.
- No cambiar la semántica de visibilidad/frame callbacks sin tests.
- No commitear WIP ajeno ni deployar sin pedido.
