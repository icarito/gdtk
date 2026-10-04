#!/bin/sh
# Lanzador de desarrollo anidado y aislado. Ver
# .operator-shared/specs/SPEC-isolated-development.md
#
# Uso: tools/run-isolated-shell.sh [--keep] [--no-supervisor] -- [argumentos Godot]
#
# No instala, sincroniza, despliega ni toca ~/gdtk. No usa pkill ni mata procesos
# por nombre: neutraliza el `pkill` del supervisor con un shim y sólo termina el
# PID que lanzó. El test del lanzador no abre Godot real (usa un doble).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHELL_DIR="$ROOT/shell"
SUPERVISOR_BIN="$ROOT/session/gdtk-supervisor"
DEFAULT_GODOT="/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk"

usage() {
	cat <<'EOF'
Uso: tools/run-isolated-shell.sh [--keep] [--no-supervisor] -- [argumentos Godot]

Corre una instancia de desarrollo del shell con runtime/XDG/store/puertos aislados
(SPEC-isolated-development.md). No instala, sincroniza ni toca ~/gdtk.

Opciones:
  --keep            conserva el directorio temporal y muestra su ruta (diagnóstico)
  --no-supervisor   ejecuta el binario directo, sin session/gdtk-supervisor
  -h, --help        esta ayuda
  --                separador; todo lo posterior llega intacto al binario Godot

Entorno:
  GDTK_GODOT                     binario a usar (default: dev documentado en AGENTS.md)
  GDTK_ISOLATED_TMPDIR           base del temporal (default $TMPDIR o /tmp; debe ser corta
                                 porque el socket Wayland no puede pasar de 108 bytes)
  GDTK_ISOLATED_PRIVATE_DBUS=0   no aislar el bus D-Bus de sesión

Aislamiento que aplica HOY (sin tocar Host):
  - XDG_RUNTIME_DIR modo 0700; XDG_STATE/DATA/CONFIG/CACHE temporales
  - GDTK_STORE, logs, pidfiles y locks dentro del temporal
  - GDTK_CONTROL_PORT y GDTK_PEER_PORT libres (nunca 7777/7788)
  - GDTK_ISOLATED=1; bus D-Bus privado si hay dbus-run-session
  - pkill neutralizado con un shim: no se mata nada por nombre; sólo se termina el PID
    lanzado (y lo que el supervisor baja al terminar su propio proceso)
  - el socket del compositor interno y el token del control remoto caen en el XDG propio

Integraciones que AÚN dependen de que el consumidor honre GDTK_ISOLATED (work-set de
Host/shell, fase posterior). Con el árbol actual, correr la instancia real puede todavía:
  - host.gd arranca WaylandCompositor, RemoteInput (EIS + backend del portal xdg), Remote
    y PeerControl sin mirar GDTK_ISOLATED. El portal/EIS sólo queda aislado si hay bus
    D-Bus privado (dbus-run-session); si no, podría registrarse en el bus de la sesión viva.
  - shell.gd no consulta GDTK_ISOLATED para servicios automáticos (Deskflow, publicación
    LAN, gvd): podrían intentar arrancar según la configuración temporal.
  - Lo que YA respeta el entorno: XDG/store (config y estado) y los puertos remote/peer
    vía GDTK_CONTROL_PORT / GDTK_PEER_PORT.
  Las pruebas de portal/EIS son un modo e2e aparte y explícito.
EOF
}

KEEP=0
SUPERVISOR=1
while [ $# -gt 0 ]; do
	case "$1" in
		--keep) KEEP=1; shift ;;
		--no-supervisor) SUPERVISOR=0; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		*) echo "[isolated] error: opción no reconocida antes de --: $1" >&2; usage >&2; exit 2 ;;
	esac
done

BIN="${GDTK_GODOT:-$DEFAULT_GODOT}"
if [ ! -x "$BIN" ]; then
	echo "[isolated] error: binario no ejecutable: $BIN" >&2
	echo "[isolated]        (definí GDTK_GODOT o compilá el binario dev de AGENTS.md)" >&2
	exit 2
fi
[ -d "$SHELL_DIR" ] || { echo "[isolated] error: falta $SHELL_DIR" >&2; exit 2; }
if [ "$SUPERVISOR" = 1 ] && [ ! -x "$SUPERVISOR_BIN" ]; then
	echo "[isolated] error: falta $SUPERVISOR_BIN (usá --no-supervisor)" >&2
	exit 2
fi

BASE="${GDTK_ISOLATED_TMPDIR:-${TMPDIR:-/tmp}}"
[ -d "$BASE" ] || mkdir -p "$BASE" || { echo "[isolated] error: no existe $BASE" >&2; exit 1; }
TMP="$(mktemp -d "$BASE/gdtk-iso.XXXXXX")" || { echo "[isolated] error: mktemp falló" >&2; exit 1; }
RUN="$TMP/run"
# El socket Wayland (/run/user/.../wayland-N) no puede superar 108 bytes.
if [ "${#RUN}" -gt 90 ]; then
	echo "[isolated] error: ruta runtime demasiado larga (${#RUN}): $RUN" >&2
	echo "[isolated]        usá GDTK_ISOLATED_TMPDIR=/tmp" >&2
	rm -rf -- "$TMP"
	exit 1
fi

umask 077
mkdir -p "$RUN" "$TMP/state" "$TMP/data" "$TMP/config" "$TMP/cache" "$TMP/store" \
	"$TMP/log" "$TMP/bin" "$TMP/tmp" || { echo "[isolated] error: mkdir" >&2; rm -rf -- "$TMP"; exit 1; }
chmod 700 "$RUN" "$TMP/state" "$TMP/data" "$TMP/config" "$TMP/cache" "$TMP/store" \
	"$TMP/log" "$TMP/bin" "$TMP/tmp" 2>/dev/null

# Shim de pkill: el supervisor (session/gdtk-supervisor) hace pkill por nombre al
# terminar el shell. En aislamiento eso mataría Deskflow real; lo neutralizamos y
# dejamos que sólo se baje el árbol de procesos que el propio supervisor controla.
cat >"$TMP/bin/pkill" <<'EOF'
#!/bin/sh
# Shim del lanzador aislado: no mata procesos por nombre.
exit 0
EOF
chmod +x "$TMP/bin/pkill"

# Puertos libres, distintos entre sí y nunca 7777/7788.
PORTS="$(python3 - <<'PY' 2>/dev/null
import socket, sys
chosen = []
for _ in range(2):
    for _ in range(1000):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", 0))
            p = s.getsockname()[1]
        finally:
            s.close()
        if p in (7777, 7788) or p in chosen:
            continue
        chosen.append(p)
        break
if len(chosen) != 2:
    sys.exit(1)
print(chosen[0], chosen[1])
PY
)" || { echo "[isolated] error: no se pudieron elegir puertos libres (¿falta python3?)" >&2; rm -rf -- "$TMP"; exit 1; }
CP="$(printf '%s' "$PORTS" | cut -d' ' -f1)"
PP="$(printf '%s' "$PORTS" | cut -d' ' -f2)"
case "$CP$PP" in *[!0-9]*|"") echo "[isolated] error: puertos inválidos: $PORTS" >&2; rm -rf -- "$TMP"; exit 1 ;; esac

# Bus D-Bus privado (best-effort) para que el backend de portal/EIS de RemoteInput no
# se registre en el bus de la sesión viva.
PRIVATE_DBUS="${GDTK_ISOLATED_PRIVATE_DBUS:-1}"
DBUS_BIN=""
if [ "$PRIVATE_DBUS" = 1 ]; then
	if command -v dbus-run-session >/dev/null 2>&1; then
		DBUS_BIN="$(command -v dbus-run-session)"
	else
		PRIVATE_DBUS=0
	fi
fi

export XDG_RUNTIME_DIR="$RUN"
export XDG_STATE_HOME="$TMP/state"
export XDG_DATA_HOME="$TMP/data"
export XDG_CONFIG_HOME="$TMP/config"
export XDG_CACHE_HOME="$TMP/cache"
export GDTK_STORE="$TMP/store"
export GDTK_CONTROL_PORT="$CP"
export GDTK_PEER_PORT="$PP"
export GDTK_ISOLATED=1
export TMPDIR="$TMP/tmp"
export PATH="$TMP/bin:$PATH"

child=""
cleanup() {
	rc=$?
	trap - EXIT INT TERM HUP
	if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
		kill -TERM "$child" 2>/dev/null
		n=0
		while kill -0 "$child" 2>/dev/null && [ "$n" -lt 50 ]; do
			sleep 0.1
			n=$((n + 1))
		done
		kill -KILL "$child" 2>/dev/null
	fi
	if [ -n "$TMP" ] && [ -d "$TMP" ]; then
		if [ "$KEEP" = 1 ]; then
			echo "[isolated] --keep: artefactos en $TMP" >&2
		else
			case "$TMP" in
				"$BASE"/gdtk-iso.*) rm -rf -- "$TMP" ;;
				*) echo "[isolated] no borro ruta inesperada: $TMP" >&2 ;;
			esac
		fi
	fi
	exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [ "$SUPERVISOR" = 1 ]; then
	MODE="supervisor"
	set -- "$SUPERVISOR_BIN" "$BIN" --path "$SHELL_DIR" "$@"
else
	MODE="directo"
	set -- "$BIN" --path "$SHELL_DIR" "$@"
fi

if [ -n "$DBUS_BIN" ]; then
	"$DBUS_BIN" -- "$@" &
	DBUS_DESC="privado"
else
	"$@" &
	DBUS_DESC="heredado"
fi
child=$!

{
	echo "[isolated] temp: $TMP"
	echo "[isolated] pid: $child"
	echo "[isolated] control_port: $CP"
	echo "[isolated] peer_port: $PP"
	echo "[isolated] modo: $MODE  dbus: $DBUS_DESC"
	echo "[isolated] GDTK_ISOLATED=1"
} >&2

wait "$child"
rc=$?
child=""
exit "$rc"
