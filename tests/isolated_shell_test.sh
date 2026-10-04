#!/bin/sh
# Test del lanzador de desarrollo aislado (SPEC-isolated-development.md).
# Usa un doble del binario: NUNCA abre Godot, ni una ventana, ni toca la sesión
# principal. Uso: tests/isolated_shell_test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCH="$ROOT/tools/run-isolated-shell.sh"
ok=0
fail=0
check() { # check <desc> <condición-shell>
	if eval "$2" >/dev/null 2>&1; then
		echo "ok   $1"
		ok=$((ok + 1))
	else
		echo "FAIL $1"
		fail=$((fail + 1))
	fi
}

[ -x "$LAUNCH" ] || { echo "FAIL: $LAUNCH no existe/ejecutable"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: falta python3"; exit 0; }

WORK="$(mktemp -d)"
KEPT=""
trap 'rm -rf "$WORK"; [ -n "$KEPT" ] && rm -rf "$KEPT"' EXIT
BASE="$WORK/base"
mkdir -p "$BASE"
ORIG="$WORK/orig-run"
mkdir -p "$ORIG"

# Centinela EXTERIOR al temporal del lanzador: su cleanup no debe tocarlo.
SENTINEL="$BASE/centinela-exterior"
echo keep >"$SENTINEL"

# Doble inocuo: dumpea argv y entorno relevante y sale.
DBL="$WORK/doble"
cat >"$DBL" <<'EOF'
#!/bin/sh
if [ -n "${DBL_DUMP:-}" ]; then
	: >"$DBL_DUMP.env"
	for v in XDG_RUNTIME_DIR XDG_STATE_HOME XDG_DATA_HOME XDG_CONFIG_HOME GDTK_STORE \
		GDTK_CONTROL_PORT GDTK_PEER_PORT GDTK_ISOLATED; do
		eval "val=\${$v-}"
		printf '%s=%s\n' "$v" "$val" >>"$DBL_DUMP.env"
	done
	: >"$DBL_DUMP.args"
	for a in "$@"; do
		printf '%s\n' "$a" >>"$DBL_DUMP.args"
	done
fi
exit 0
EOF
chmod +x "$DBL"

env_of() { sed -n "s/^$2=//p" "$1"; }
tag() { sed -n "s/^\[isolated\] $2: //p" "$1"; }

# --- Preparación 1: sin --keep (prueba cleanup), con argumentos complejos ----------
OUT1="$WORK/out1"
XDG_RUNTIME_DIR="$ORIG" GDTK_GODOT="$DBL" GDTK_ISO_TMPDIR="$BASE" DBL_DUMP="$WORK/d1" \
	"$LAUNCH" --no-supervisor -- ARG1 --open=Chat "dos palabras" >"$OUT1" 2>&1
RC1=$?

# --- Preparación 2: --keep (inspeccionar artefactos y permisos) --------------------
OUT2="$WORK/out2"
XDG_RUNTIME_DIR="$ORIG" GDTK_GODOT="$DBL" GDTK_ISO_TMPDIR="$BASE" DBL_DUMP="$WORK/d2" \
	"$LAUNCH" --keep --no-supervisor -- ARG2 >"$OUT2" 2>&1
RC2=$?

T1="$(tag "$OUT1" temp)"
T2="$(tag "$OUT2" temp)"
CP1="$(tag "$OUT1" control_port)"
CP2="$(tag "$OUT2" control_port)"
PP1="$(tag "$OUT1" peer_port)"
PP2="$(tag "$OUT2" peer_port)"
KEPT="$T2"

check "preparación 1 sale 0" "[ $RC1 -eq 0 ]"
check "preparación 2 sale 0" "[ $RC2 -eq 0 ]"
check "imprime el temporal" "[ -n \"$T1\" ] && [ -n \"$T2\" ]"
check "dos rutas temporales distintas" "[ \"$T1\" != \"$T2\" ] && [ -n \"$T1\" ]"
check "dos controlled ports distintos" "[ -n \"$CP1\" ] && [ \"$CP1\" != \"$CP2\" ]"
check "dos peer ports distintos" "[ -n \"$PP1\" ] && [ \"$PP1\" != \"$PP2\" ]"
check "puertos nunca 7777/7788" "! echo \"$CP1 $CP2 $PP1 $PP2\" | grep -Eq '7777|7788'"

# 2) Ninguna ruta resuelve al XDG_RUNTIME_DIR original.
RUN1="$(env_of "$WORK/d1.env" XDG_RUNTIME_DIR)"
check "XDG_RUNTIME_DIR no es el original" "[ \"$RUN1\" != \"$ORIG\" ]"
check "XDG_RUNTIME_DIR cuelga del temporal 1" "[ \"$RUN1\" = \"$T1/run\" ]"
check "XDG_STATE_HOME cuelga del temporal 1" \
	"[ \"$(env_of "$WORK/d1.env" XDG_STATE_HOME)\" = \"$T1/state\" ]"
check "XDG_DATA_HOME cuelga del temporal 1" \
	"[ \"$(env_of "$WORK/d1.env" XDG_DATA_HOME)\" = \"$T1/data\" ]"
check "XDG_CONFIG_HOME cuelga del temporal 1" \
	"[ \"$(env_of "$WORK/d1.env" XDG_CONFIG_HOME)\" = \"$T1/config\" ]"
check "GDTK_STORE cuelga del temporal 1" \
	"[ \"$(env_of "$WORK/d1.env" GDTK_STORE)\" = \"$T1/store\" ]"
check "GDTK_ISOLATED=1 llega al ejecutable" \
	"[ \"$(env_of "$WORK/d1.env" GDTK_ISOLATED)\" = 1 ]"

# 3) Permisos 0700 del runtime (en la corrida --keep, que conservó el árbol).
check "--keep conserva el directorio temporal" "[ -d \"$T2\" ]"
check "runtime temporal existe" "[ -d \"$T2/run\" ]"
check "runtime temporal es 0700" "[ \"$(stat -c %a "$T2/run" 2>/dev/null)\" = 700 ]"

# 4) Cleanup no borra el centinela exterior y sí borra su propio temporal.
check "cleanup deja el centinela exterior" "[ -f \"$SENTINEL\" ]"
check "cleanup borra su propio temporal" "[ ! -e \"$T1\" ]"
check "cleanup no borra el temporal --keep" "[ -e \"$T2\" ]"

# 5) --keep muestra la ruta para diagnóstico.
check "--keep anuncia la ruta conservada" "grep -q 'artefactos en $T2' \"$OUT2\""

# 6) Los argumentos tras -- llegan intactos al ejecutable doble.
EXPECTED="$WORK/expected.args"
{
	printf '%s\n' '--path'
	printf '%s\n' "$ROOT/shell"
	printf '%s\n' 'ARG1'
	printf '%s\n' '--open=Chat'
	printf '%s\n' 'dos palabras'
} >"$EXPECTED"
check "argv del doble es --path shell + args intactos" "cmp -s \"$EXPECTED\" \"$WORK/d1.args\""

# 7) Sin token en la salida (el spec prohíbe imprimirlos).
check "la salida no imprime un token" "! grep -Eq '[0-9a-f]{32}' \"$OUT1\""

echo "isolated_shell_test: ok=$ok FAIL=$fail"
[ "$fail" -eq 0 ]
