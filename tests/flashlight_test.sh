#!/bin/sh
# Verificación del Paso 13: Linterna de casco con ImGui (ver SPEC-flashlight.md).
#
# 1) Screenshot directo de la actividad Linterna (cage anidado).
# 2) Control remoto GLES3 y GLES2: click en ENCENDER/APAGAR, forzar batería baja,
#    recortes 210x80 del widget compacto apagado y encendido.
# 3) Resume los FLASHLIGHT_METRICS de cada corrida.
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
	suffix="$3"      # "" o -gles2
	log="$GDTK/kilo_flash${suffix}.log"
	rm -f "$XDG_RUNTIME_DIR/gdtk-control-$port.token"
	echo "== control remoto: driver=$driver (log $log) =="
	GDTK_VIDEO_DRIVER="$driver" GDTK_CONTROL_PORT="$port" \
		"$GDTK/session/gdtk-session" >"$log" 2>&1 &
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

	GDTK_CONTROL_PORT="$port" GDTK_FLASH_SUFFIX="$suffix" python3 "$GDTK/tests/flashlight_driver.py"
	rc=$?

	kill "$SHELL_PID" 2>/dev/null
	sleep 1
	kill -9 "$SHELL_PID" 2>/dev/null
	SHELL_PID=""
	return $rc
}

echo "== 1) screenshot directo de Linterna =="
timeout 90 "$GDTK/session/gdtk-session" -- --open=Linterna --screenshot="$GDTK/flashlight.png"
rc=$?
if [ "$rc" -ne 0 ] || [ ! -f "$GDTK/flashlight.png" ]; then
	echo "FALLO: screenshot directo (rc=$rc)"
	exit 1
fi

echo "== 2) control remoto GLES3 =="
run_remote GLES3 7801 "" || exit 1

echo "== 3) control remoto GLES2 =="
run_remote GLES2 7802 "-gles2" || exit 1

echo "== 4) métricas FLASHLIGHT_METRICS =="
for log in "$GDTK/kilo_flash.log" "$GDTK/kilo_flash-gles2.log"; do
	if [ -f "$log" ]; then
		echo "-- $log"
		grep "FLASHLIGHT_METRICS" "$log" | tail -14
	else
		echo "-- $log (sin log)"
	fi
done

echo "RESULTADO: OK"
