# Cuelgue del shell en bastion (2026-10-04 00:00) — resuelto f26c8a4

Síntoma: a los segundos de arrancar, el mouse se movía (sway) pero el shell no reaccionaba; Firefox
"crasheaba" con `Error reading events from display: Tubería rota`, una consecuencia del cierre de sesión, no la causa.

Causa (W20, cableado del lead): sobre una app, `_on_chrome_input` aplicaba el cursor del cliente y
`_on_view_input` lo pisaba con la flecha (`_reset_cursor`) en el mismo motion. Godot 3
`Input.set_default_cursor_shape` inyecta un InputEventMouseMotion falso en cada cambio de forma →
alternancia app↔flecha realimentada sin fin; el hilo principal sólo procesaba motions (estado R).

Diagnóstico reproducible (cupid): RPC 7777 (`auth` token + `launch xfce4-terminal` + `move` en barrido),
el RPC deja de responder; `sudo -n gdb -p <pid> -batch -ex bt` → InputDefault::flush_buffered_events →
Viewport::_gui_input_event → GDScript, con Ref<InputEventMouseMotion>::instance() en las muestras.
(ptrace_scope=1: gdb necesita sudo; `pkill -f`/`pgrep -f` con el patrón en la línea de ssh se mata a sí mismo.)

Fix: una sola decisión de cursor por motion en `_on_view_input` (app bajo el puntero → `_apply_client_cursor`,
si no `_reset_cursor`); `_apply_client_cursor` sólo aplica si cambió la clave. Verificado en cupid con
xfce4-terminal + VS Code (peor respuesta RPC 0.10 s). Desplegado a bastion (~/gdtk), tengu, cupid (shell md5 9f2d221c).
