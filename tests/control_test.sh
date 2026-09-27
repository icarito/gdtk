#!/bin/sh
# Verificación del Paso 6: control remoto JSON-RPC + puente MCP (ver SPEC-control.md).
set -u

GDTK="$(cd "$(dirname "$0")/.." && pwd)"
export GDTK_GODOT="${GDTK_GODOT:-/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk}"
export SDL_VIDEODRIVER=wayland
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
	export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi
TOKEN="$XDG_RUNTIME_DIR/gdtk-control.token"
LOG="$GDTK/kilo_control_test.log"

SHELL_PID=""
cleanup() {
	if [ -n "$SHELL_PID" ] && kill -0 "$SHELL_PID" 2>/dev/null; then
		kill "$SHELL_PID" 2>/dev/null
		sleep 1
		kill -9 "$SHELL_PID" 2>/dev/null
	fi
}
trap cleanup EXIT

rm -f "$TOKEN"
echo "== 1) arrancando shell anidado en cage =="
"$GDTK/session/gdtk-session" >"$LOG" 2>&1 &
SHELL_PID=$!

elapsed=0
while [ ! -f "$TOKEN" ]; do
	if [ "$elapsed" -ge 60 ]; then
		echo "FALLO: el token no apareció en 30 s"
		cat "$LOG" 2>/dev/null
		exit 1
	fi
	sleep 0.5
	elapsed=$((elapsed + 1))
done
echo "token listo tras $((elapsed / 2)) s: $TOKEN"

echo "== 2) flujo completo por el puente MCP =="
python3 "$GDTK/tests/mcp_driver.py"
RC=$?
if [ "$RC" -ne 0 ]; then
	echo "FALLO: flujo MCP (rc=$RC)"
	exit 1
fi

echo "== 3) prueba negativa (token incorrecto) =="
python3 "$GDTK/tests/mcp_driver.py" --negative
RC=$?
if [ "$RC" -ne 0 ]; then
	echo "FALLO: prueba negativa (rc=$RC)"
	exit 1
fi

echo "== 4) cierre del shell y borrado del token =="
kill "$SHELL_PID" 2>/dev/null
elapsed=0
while [ -f "$TOKEN" ]; do
	if [ "$elapsed" -ge 40 ]; then
		echo "FALLO: el token sigue en $TOKEN tras cerrar el shell"
		kill -9 "$SHELL_PID" 2>/dev/null
		SHELL_PID=""
		exit 1
	fi
	sleep 0.5
	elapsed=$((elapsed + 1))
done
wait "$SHELL_PID" 2>/dev/null
SHELL_PID=""
echo "token borrado tras el cierre"

echo "RESULTADO: OK"
