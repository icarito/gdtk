# Sesión 2026-10-05 — Multimonitor (span) sin perder rendimiento

Pedido: “Estudia cómo lograr multimonitor sin perder rendimiento” → implementar el plan
`.kilo/plans/1791222770756-multimonitor-span-rendimiento.md`.

Contrato: `SPEC-physical-multi-monitor.md` (modo span) + `SPEC-embedded-multi-output.md`
(fases B–E) + `SPEC-rendimiento-compositor.md` (modelo de costo).

## Decisión de arquitectura (ya tomada en el spec, acá se implementa)

Una sola ventana borderless de Godot cubre el **envolvente** de todos los monitores; la
principal queda en (0,0) y el resto se reordena a su derecha con `swaymsg output <n> pos`.
Costo marginal acotado: la UI ImGui cuesta por widget (no por píxel) y vive sólo en la
principal; una ventana cuesta igual en cualquier salida. Lo que crece es el ancho de banda
de present/compose proporcional al área del 2° monitor y sólo mientras hay frames.
Multi-ventana nativa del engine: fuera de alcance v1.

## Entregado

1. **Modelo puro de span** (`shell/output_layout.gd`, Fase B/E):
   - `bounding_rect()`, `span_rects()` (principal en (0,0), resto a la derecha, sin solapes),
     `reconcile_outputs()` (alta/baja/cambio de geometría conservando asignaciones y
     devolviendo a la principal las ventanas de salidas retiradas) y `TARGET_SPAN`.
   - Tests: `tests/output_layout_test.gd` (ok=72).
2. **Módulo puro del anfitrión** (`shell/span_layout.gd`, nuevo): parseo de
   `swaymsg -t get_outputs -r`, elección de principal (externa > interna, forzable con
   `GDTK_SHELL_OUTPUT`), orden, plan de span, comandos sway (`pos` + regla de ventana
   span/single) y `state_entries()` para el RPC. Tests: `tests/span_layout_test.gd` (ok=25).
3. **Separación pantalla principal / escritorio** (`Fase 3`):
   - `shell._screen_size()` (principal; sin span = viewport) y `shell._desktop_rect()`
     (envolvente; sólo el `view`/chrome de ventanas).
   - Migrados todos los `get_viewport_rect().size` de la UI a `_screen_size()`
     (`shell.gd` 41 sitios + `frame.gd`, `layers.gd`, `system_osd.gd`, `window_deco.gd`,
     `neighborhood_ui.gd`, `apps.gd`, `expose_bg.gd`). Con una sola salida el
     comportamiento es idéntico.
4. **Controlador de span en el shell** (`Fase 4`):
   - Worker de hotplug (Thread one-shot con `OS.execute` de `swaymsg`, reap en `_process`,
     nunca en el render) + `_span_apply()`: calcula el plan, reordena sway, ajusta la
     ventana (floating borderless envolvente o fullscreen si hay una sola salida), crea/
     actualiza/quita las salidas del compositor embebido y fija `screen_size`.
   - **Gate Fase 0**: `GDTK_SPAN=1` activa, `GDTK_SPAN=0`/unset desactiva. El default
     queda OFF hasta medir el costo en hardware débil (ver “Pendiente”).
5. **Métricas** (`Fase 5`): RPC `state` expone `span {active, gate, primary, desktop,
   outputs}` (JSON-friendly) para medir sin abrir el HUD.
6. **Harness de medición** `bench/span_bench.sh` (Fase 0): sesión headless **aislada**
   (sway privado con 2 salidas, XDG/runtime/puertos propios, `GDTK_ISOLATED=1`) corriendo
   el shell con `GDTK_SPAN=0` y `=1`, midiendo CPU acumulada de shell y sway. **No se
   ejecutó en esta sesión** (requiere host aislado y el binario con clases nativas);
   correr a mano con `SPAN_BENCH_OPEN=<app> bench/span_bench.sh`.
7. **Fix de tests preexistentes**: `client_pointer_lock_test` e `input_capture_cursor_test`
   no declaraban `debug_input` en su harness y no compilaban. Ahora `ok=17`/`ok=23`.
8. **Configuración > Monitores** (ajuste persistente del layout multi-monitor):
   - Modelo puro `settings/settings_model.gd`: campo `span {enabled, primary, order}`
     normalizado/tolerante, default apagado, `is_live("span")` y selftest.
   - Página nueva `settings/pages/monitors.gd` (registrada en `settings/main.gd`):
     casilla “Usar varios monitores”, elección de monitor principal, vista previa del
     escritorio extendido y botones ◀/▶ para el orden izquierda→derecha. Detecta las
     salidas con `swaymsg -t get_outputs -r` en un Thread (sin bloquear la UI; sin
     SWAYSOCK no hay detección y el ajuste igual se puede guardar).
   - Puente `shell/settings_bridge.gd`: `span()`; `shell.gd` lo aplica en vivo desde
     `_apply_settings()` (`_apply_span_settings()`): actualiza enabled/principal/orden,
     fuerza reap, y si se apaga vuelve a fullscreen + quita las salidas embebidas
     (`_span_off_now()`). `GDTK_SPAN=1/0` sigue forzando por encima del ajuste.
   - El plan de span (`span_layout.plan(..., order)`) respeta el orden elegido.

## Pendiente (fuera de este corte)

- **Fase C** (`SPEC-embedded-multi-output`): reubicar/renderizar ventanas en salidas
  secundarias y el cruce por arrastre. Hoy el span **extiende y anuncia** la salida
  (`add_output`/`set_toplevel_output`), pero las ventanas siguen viviendo en la principal:
  el escritorio extendido queda visible, sin Frame ni mosaico, como pide el contrato.
- **Fase 0**: correr `bench/span_bench.sh` en cupid (Haswell) y bastion con video. Si el
  delta de CPU del shell supera ~15%, aplicar M1 (parche FRT que emita
  `wl_surface_damage_buffer` antes del swap) antes de activar span por defecto.
- Activar `GDTK_SPAN=1` por defecto (hoy el gate lo deja off) una vez medida la Fase 0.

## Verificación

- `tools/verify_all.sh`: todos `ok`, sin `FAIL` (los rc=124 son los cuelgues conocidos de
  `RemoteInput` al salir). `output_layout_test` 72 ok, `span_layout_test` 29 ok,
  `settings_model_test` 58 ok, `settings_bridge_test` 20 ok.
- App Configuración: `--settings-selftest` (con `GDTK_SETTINGS` redirigido) arma todas
  las páginas, incluida Monitores, y guarda `span` con sus defaults.
- `tests/parse_check.gd` con el binario instalado: verdes `shell.gd`, `output_layout.gd`,
  `span_layout.gd` y el resto de los scripts tocados.
- **No** se tocó la sesión viva, no hubo commit, deploy ni sync a `~/gdtk`.

## Archivos

- `shell/output_layout.gd`, `shell/span_layout.gd` (nuevo), `shell/shell.gd`,
  `shell/remote.gd`, `shell/frame.gd`, `shell/layers.gd`, `shell/system_osd.gd`,
  `shell/window_deco.gd`, `shell/neighborhood_ui.gd`, `shell/apps.gd`, `shell/expose_bg.gd`,
  `shell/settings_bridge.gd`.
- `settings/settings_model.gd`, `settings/main.gd`, `settings/pages/monitors.gd` (nuevo).
- `tests/output_layout_test.gd`, `tests/span_layout_test.gd` (nuevo),
  `tests/settings_model_test.gd`, `tests/settings_bridge_test.gd`,
  `tests/parse_check.gd`, `tests/client_pointer_lock_test.gd`,
  `tests/input_capture_cursor_test.gd`.
- `bench/span_bench.sh` (nuevo).
