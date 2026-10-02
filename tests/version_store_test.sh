#!/bin/sh
# Test del store de versiones y del rollback/promocion del supervisor (Fase 1).
# No toca el store real del usuario: todo va en un tmpdir. Uso: tests/version_store_test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$ROOT/session/gdtk-version"
SUP="$ROOT/session/gdtk-supervisor"
ok=0; fail=0
check() { # check <desc> <cond-rc>
	if [ "$2" -eq 0 ]; then echo "ok   $1"; ok=$((ok + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: falta jq"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GDTK_STORE="$TMP/store"
export XDG_STATE_HOME="$TMP/state"
export XDG_RUNTIME_DIR="$TMP/run"
mkdir -p "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"

cat >"$TMP/crash" <<'EOF'
#!/bin/sh
sleep 0.2
exit 1
EOF
cat >"$TMP/okrun" <<'EOF'
#!/bin/sh
sleep 3
exit 0
EOF
chmod +x "$TMP/crash" "$TMP/okrun"

# v1: version buena de partida. v2: candidata para rollback. v3: candidata para promocion.
"$V" snapshot --from "$ROOT" --no-check --id v1 --use >/dev/null 2>&1
"$V" good v1 >/dev/null 2>&1
"$V" snapshot --from "$ROOT" --no-check --id v2 --use >/dev/null 2>&1
check "snapshot v1/v2 existen" "$([ -d "$GDTK_STORE/content/v1/shell" ] && [ -d "$GDTK_STORE/content/v2/shell" ]; echo $?)"
check "current es v2" "$([ "$("$V" current)" = v2 ]; echo $?)"
check "last_good es v1" "$([ "$(basename "$(readlink "$GDTK_STORE/last_good")")" = v1 ]; echo $?)"

"$V" rollback >/dev/null 2>&1
check "rollback vuelve a v1" "$([ "$("$V" current)" = v1 ]; echo $?)"

# Supervisor con binario que crashea: debe volver a last_good (v1) solo.
"$V" use v2 >/dev/null 2>&1
GDTK_PROMOTE_AFTER=1 timeout 4 "$SUP" "$TMP/crash" --fullscreen --path /nope >/dev/null 2>&1
check "supervisor detecta rollback" "$(grep -q 'rollback v2 -> v1' "$XDG_STATE_HOME/gdtk/supervisor.log"; echo $?)"
check "current quedo en v1 tras crash" "$([ "$("$V" current)" = v1 ]; echo $?)"

# Supervisor con binario que aguanta: debe promover la candidata a buena.
"$V" snapshot --from "$ROOT" --no-check --id v3 --use >/dev/null 2>&1
GDTK_PROMOTE_AFTER=1 timeout 8 "$SUP" "$TMP/okrun" --fullscreen --path /nope >/dev/null 2>&1
check "supervisor promueve v3" "$([ "$(basename "$(readlink "$GDTK_STORE/last_good")")" = v3 ]; echo $?)"
check "v3 estado good" "$([ "$(jq -r .status "$GDTK_STORE/content/v3/meta.json")" = good ]; echo $?)"

echo "version_store_test: ok=$ok FAIL=$fail"
[ "$fail" -eq 0 ]
