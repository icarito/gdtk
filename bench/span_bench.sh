#!/bin/sh
# Fase 0 del plan multimonitor (SPEC-physical-multi-monitor.md): mide el costo de
# correr el shell en modo span (una ventana que cubre 2 monitores) contra una sola
# salida, en una sesion headless AISLADA. NUNCA toca la sesion viva ni ~/gdtk: usa
# su propio XDG_RUNTIME_DIR, sway privado, puertos libres y GDTK_ISOLATED=1.
#
# Gate (SPEC-rendimiento-compositor + plan): si el delta de CPU del shell con video
# supera ~15% en hardware debil (cupid/Haswell), agendar M1 (parche FRT que emita
# dano de superficie) antes de activar span por defecto (hoy GDTK_SPAN=1 lo activa).
#
# Uso:
#   SPAN_BENCH_OPEN=Firefox bench/span_bench.sh [segundos]
#
#   SPAN_BENCH_OPEN   app a abrir dentro del shell (--open=<x>) para forzar frames;
#                     sin ella la corrida es ociosa y mide sobre todo reposo.
#   GDTK_GODOT        binario con clases nativas (default ~/gdtk/bin/godot-gdtk;
#                     el binario dev no trae RemoteInput y no arranca el shell).
#   SPAN_BENCH_DUR    segundos de muestra por modo (default 20).
#
# Salida: tabla con CPU acumulada (s) de shell y sway por modo, y el ratio span/off.
# Requiere: sway, swaymsg, python3. Pensado para correr a mano en un host aislado.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="${GDTK_GODOT:-$HOME/gdtk/bin/godot-gdtk}"
DUR="${SPAN_BENCH_DUR:-20}"
OPEN="${SPAN_BENCH_OPEN:-}"

[ -x "$BIN" ] || { echo "error: binario no ejecutable: $BIN" >&2; exit 2; }
command -v sway >/dev/null 2>&1 || { echo "error: falta sway" >&2; exit 2; }
command -v swaymsg >/dev/null 2>&1 || { echo "error: falta swaymsg" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: falta python3" >&2; exit 2; }

TMP="$(mktemp -d /tmp/gdtk-span.XXXXXX)" || exit 1
cleanup() {
	trap - EXIT INT TERM HUP
	[ -n "${SHELL_PID:-}" ] && kill -TERM "$SHELL_PID" 2>/dev/null
	[ -n "${SWAY_PID:-}" ] && kill -TERM "$SWAY_PID" 2>/dev/null
	sleep 0.3
	[ -n "${SHELL_PID:-}" ] && kill -KILL "$SHELL_PID" 2>/dev/null
	[ -n "${SWAY_PID:-}" ] && kill -KILL "$SWAY_PID" 2>/dev/null
	rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

free_port() {
	python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# CPU acumulada (s) de un pid, 0 si no existe. ps time = [[DD-]hh:]mm:ss.
cpu_seconds() {
	[ -n "$1" ] || { echo 0; return; }
	python3 - "$1" <<'PY' 2>/dev/null || echo 0
import subprocess, sys
try:
    out = subprocess.check_output(["ps", "-o", "time=", "-p", sys.argv[1]], text=True).strip()
except Exception:
    print(0); raise SystemExit
if not out:
    print(0); raise SystemExit
d = 0
if "-" in out:
    dd, out = out.split("-", 1); d = int(dd) * 86400
parts = [int(x) for x in out.split(":")]
if len(parts) == 2:
    secs = parts[0] * 60 + parts[1]
elif len(parts) == 3:
    secs = parts[0] * 3600 + parts[1] * 60 + parts[2]
else:
    secs = 0
print(d + secs)
PY
}

run_mode() {
	mode="$1"     # off | on
	flag="$2"     # 0 | 1
	run="$TMP/$mode"
	mkdir -p "$run/run" "$run/state" "$run/data" "$run/config" "$run/cache" "$run/store"
	chmod 700 "$run/run"
	cp="$(free_port)"; pp="$(free_port)"

	# sway headless con 2 salidas de distinto tamano (span real).
	cat >"$run/sway.conf" <<EOF
output HEADLESS-1 resolution 1920x1080 position 0 0
output HEADLESS-2 resolution 1280x800 position 1920 0
EOF
	WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=2 \
		XDG_RUNTIME_DIR="$run/run" sway -c "$run/sway.conf" >"$run/sway.log" 2>&1 &
	SWAY_PID=$!
	# Esperar el socket Wayland + IPC de sway en el runtime privado.
	wl=""
	ipc=""
	n=0
	while [ $n -lt 100 ]; do
		wl="$(ls "$run/run"/wayland-* 2>/dev/null | head -n1)"
		ipc="$(ls "$run/run"/sway-ipc.* 2>/dev/null | head -n1)"
		[ -n "$wl" ] && [ -n "$ipc" ] && break
		n=$((n + 1))
		sleep 0.1
	done
	[ -n "$wl" ] || { echo "FAIL: sway no expuso socket wayland"; return 1; }

	set -- "$BIN" --path "$ROOT/shell"
	[ -n "$OPEN" ] && set -- "$@" "--open=$OPEN"
	XDG_RUNTIME_DIR="$run/run" XDG_STATE_HOME="$run/state" XDG_DATA_HOME="$run/data" \
		XDG_CONFIG_HOME="$run/config" XDG_CACHE_HOME="$run/cache" \
		WAYLAND_DISPLAY="$(basename "$wl")" SWAYSOCK="$ipc" \
		GDTK_STORE="$run/store" GDTK_CONTROL_PORT="$cp" GDTK_PEER_PORT="$pp" \
		GDTK_ISOLATED=1 GDTK_SPAN="$flag" \
		"$@" >"$run/shell.log" 2>&1 &
	SHELL_PID=$!

	# Esperar arranque: el shell publica el control port (best-effort, sin token).
	python3 - "$cp" <<'PY' 2>/dev/null || true
import socket, sys, time
port = int(sys.argv[1])
for _ in range(150):
    s = socket.socket(); s.settimeout(0.2)
    if s.connect_ex(("127.0.0.1", port)) == 0:
        s.close(); sys.exit(0)
    s.close(); time.sleep(0.1)
sys.exit(1)
PY

	sway_cpu0="$(cpu_seconds "$SWAY_PID")"; shell_cpu0="$(cpu_seconds "$SHELL_PID")"
	sleep "$DUR"
	sway_cpu1="$(cpu_seconds "$SWAY_PID")"; shell_cpu1="$(cpu_seconds "$SHELL_PID")"
	SWAY_CPU=$((sway_cpu1 - sway_cpu0))
	SHELL_CPU=$((shell_cpu1 - shell_cpu0))
	echo "$mode $SWAY_CPU $SHELL_CPU" >>"$TMP/result"

	kill -TERM "$SHELL_PID" 2>/dev/null; SHELL_PID=""
	kill -TERM "$SWAY_PID" 2>/dev/null; sleep 0.3
	kill -KILL "$SWAY_PID" 2>/dev/null; SWAY_PID=""
	sleep 0.5
}

echo "span_bench: bin=$BIN dur=${DUR}s open='${OPEN:-<ninguna>}'"
run_mode off 0
run_mode on 1

echo ""
printf '%-6s %-12s %-12s\n' "modo" "shell_cpu(s)" "sway_cpu(s)"
off_shell=0; off_sway=0; on_shell=0; on_sway=0
while read -r mode s w; do
	printf '%-6s %-12s %-12s\n' "$mode" "$s" "$w"
	[ "$mode" = off ] && { off_shell=$s; off_sway=$w; }
	[ "$mode" = on ] && { on_shell=$s; on_sway=$w; }
done <"$TMP/result"

ratio() { # ratio a/b en % (0 si b=0)
	[ "$2" -gt 0 ] 2>/dev/null || { echo "n/a"; return; }
	echo "$((100 * $1 / $2))%"
}
echo ""
echo "delta shell span/off: $(ratio "$on_shell" "$off_shell")   delta sway span/off: $(ratio "$on_sway" "$off_sway")"
echo "GATE: si el delta del shell con video supera ~15%, aplicar M1 (dano de superficie en FRT) antes de GDTK_SPAN=1 por defecto."
