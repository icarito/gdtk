#!/bin/sh
# Test unitario de session/gdtk-health: validacion del heartbeat atomico (C2).
# Solo usa temporales; no toca la sesion real. Uso: tests/gdtk_health_test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/session/gdtk-health"
ok=0; fail=0
check() {
	if [ "$2" -eq 0 ]; then echo "ok   $1"; ok=$((ok + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: falta jq"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export XDG_RUNTIME_DIR="$TMP/run"
export GDTK_HEALTH_FILE="$TMP/custom/health.json"
mkdir -p "$TMP/custom"
write() { printf '%s\n' "$1" >"$TMP/custom/health.json"; }
probe() { "$H" probe "$1" 2>/dev/null; }
state() { probe "$1" | cut -f1; }

check "absent cuando no hay archivo" "$([ "$(state 4242)" = absent ]; echo $?)"
check "valid falla sin archivo" "$([ "$("$H" valid 4242 >/dev/null 2>&1; echo $?)" -ne 0 ]; echo $?)"

write '{"pid":4242,"generation":7,"sequence":91,"monotonic_ms":123456,"reload":"ready"}'
check "ok con pid correcto" "$([ "$(state 4242)" = ok ]; echo $?)"
check "probe emite 4 campos" "$([ "$(probe 4242 | awk -F'\t' '{print NF}')" = 4 ]; echo $?)"
check "probe preserva sequence" "$([ "$(probe 4242 | cut -f2)" = 91 ]; echo $?)"
check "probe preserva reload" "$([ "$(probe 4242 | cut -f3)" = ready ]; echo $?)"
check "valid sale 0 con ok" "$("$H" valid 4242 >/dev/null; echo $?)"

check "wrongpid con pid ajeno" "$([ "$(state 1)" = wrongpid ]; echo $?)"
check "valid falla con pid ajeno" "$([ "$("$H" valid 1 >/dev/null 2>&1; echo $?)" -ne 0 ]; echo $?)"

write '{"pid":4242,"sequence":1,"reload":"ready"}'
touch -d '1 hour ago' "$GDTK_HEALTH_FILE"
check "stale si el archivo es viejo" "$([ "$(GDTK_HEALTH_STALE_AFTER=1 "$H" probe 4242 | cut -f1)" = stale ]; echo $?)"
check "valid falla si stale" "$([ "$(GDTK_HEALTH_STALE_AFTER=1 "$H" valid 4242 >/dev/null 2>&1; echo $?)" -ne 0 ]; echo $?)"

write 'esto no es json'
check "invalid con JSON roto" "$([ "$(state 4242)" = invalid ]; echo $?)"
write '{"pid":"abc","sequence":1,"reload":"ready"}'
check "invalid con pid no numerico" "$([ "$(state 4242)" = invalid ]; echo $?)"
write '{"pid":4242,"reload":"ready"}'
check "invalid sin sequence" "$([ "$(state 4242)" = invalid ]; echo $?)"
write '{}'
check "invalid sin pid" "$([ "$(state 4242)" = invalid ]; echo $?)"

# Lectura atomica: se renombra un nuevo contenido encima y se lee el nuevo.
printf '{"pid":4242,"sequence":1,"reload":"ready"}\n' >"$TMP/custom/.tmp"
mv -f "$TMP/custom/.tmp" "$GDTK_HEALTH_FILE"
check "lee el contenido renombrado" "$([ "$(probe 4242 | cut -f2)" = 1 ]; echo $?)"

echo "gdtk_health_test: ok=$ok FAIL=$fail"
[ "$fail" -eq 0 ]
