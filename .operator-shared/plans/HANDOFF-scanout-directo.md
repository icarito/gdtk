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

Pendiente: **P4** (este handoff). Nada de P4 está implementado.

## Primer paso recomendado

1. **F0 — medir** antes de diseñar más: costo GPU/frame del shell y por-ventana
   (HUD F1, parches `FRT_PERF` `[FRT_GPU]`, dos lecturas de RPC `state`). Sin esto no
   se cuantifica la ganancia.
2. **Resolver el bloqueante §7.1 del spec**: ¿FRT/SDL exponen la `wl_surface` de la
   ventana para crear una `wl_subsurface` del lado cliente? Si no, la opción B
   (puente dmabuf hacia sway) necesita una superficie separada o un cambio de
   engine. **Investigar esto primero**; define si B es viable.
3. Recién entonces, PoC de F2 en instancia aislada, con feature flag
   `GDTK_SCANOUT_DIRECT` y fallback al camino P1.

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
