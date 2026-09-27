#!/bin/sh
# Verificación del Paso 12: HoloTerminal de la Criopod (ver SPEC-holoterminal.md).
#
# 1) Screenshot directo de la actividad Criopod (cage anidado).
# 2) Control remoto: reposo, puntero en 30 pasos sobre la pantalla, cursor sobre el
#    botón, click. GLES3 (criopod*.png) y GLES2 (criopod*-gles2.png).
# 3) Modo viejo (cursor en textura, Viewport siempre) para comparar números.
# 4) Resume los HOLO_METRICS de cada corrida.
set -u

GDTK="$(cd "$(dirname "$0")/.." && pwd)"
export GDTK_GODOT="${GDTK_GODOT:-/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk}"
export SDL_VIDEODRIVER=wayland
export SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
	export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

SHELL_PID=""
cleanup() {
	if [ -n "$SHELL_PID" ] && kill -0 "$SHELL_PID" 2>/dev/null; then
		kill "$SHELL_PID" 2>/dev/null
		sleep 1
		kill -9 "$SHELL_PID" 2>/dev/null
	fi
}
trap cleanup EXIT

run_remote() {
	driver="$1"      # GLES2|GLES3
	port="$2"
	suffix="$3"      # "" o -gles2 / -old
	holo_old="$4"    # 0|1
	log="$GDTK/kilo_holo${suffix}.log"
	rm -f "$XDG_RUNTIME_DIR/gdtk-control-$port.token"
	echo "== control remoto: driver=$driver holo_old=$holo_old (log $log) =="
	if [ "$holo_old" = "1" ]; then
		GDTK_HOLO_OLD=1 GDTK_VIDEO_DRIVER="$driver" GDTK_CONTROL_PORT="$port" \
			"$GDTK/session/gdtk-session" >"$log" 2>&1 &
	else
		GDTK_VIDEO_DRIVER="$driver" GDTK_CONTROL_PORT="$port" \
			"$GDTK/session/gdtk-session" >"$log" 2>&1 &
	fi
	SHELL_PID=$!

	elapsed=0
	while [ ! -f "$XDG_RUNTIME_DIR/gdtk-control-$port.token" ]; do
		if [ "$elapsed" -ge 120 ]; then
			echo "FALLO: token no apareció (driver=$driver)"
			tail -40 "$log"
			return 1
		fi
		sleep 0.5
		elapsed=$((elapsed + 1))
	done

	GDTK_CONTROL_PORT="$port" GDTK_HOLO_SUFFIX="$suffix" python3 "$GDTK/tests/holoterminal_driver.py"
	rc=$?

	kill "$SHELL_PID" 2>/dev/null
	sleep 1
	kill -9 "$SHELL_PID" 2>/dev/null
	SHELL_PID=""
	return $rc
}

echo "== 1) screenshot directo de Criopod =="
timeout 90 "$GDTK/session/gdtk-session" -- --open=Criopod --screenshot="$GDTK/criopod.png"
rc=$?
if [ "$rc" -ne 0 ] || [ ! -f "$GDTK/criopod.png" ]; then
	echo "FALLO: screenshot directo (rc=$rc)"
	exit 1
fi

echo "== 2) control remoto GLES3 =="
run_remote GLES3 7791 "" 0 || exit 1

echo "== 3) control remoto GLES2 =="
run_remote GLES2 7792 "-gles2" 0 || exit 1

echo "== 4) control remoto GLES2, modo viejo =="
run_remote GLES2 7793 "-old" 1 || exit 1

echo "== 5) métricas HOLO_METRICS =="
for log in "$GDTK/kilo_holo.log" "$GDTK/kilo_holo-gles2.log" "$GDTK/kilo_holo-old.log"; do
	if [ -f "$log" ]; then
		echo "-- $log"
		grep "HOLO_METRICS" "$log" | tail -12
	else
		echo "-- $log (sin log)"
	fi
done

echo "RESULTADO: OK"
