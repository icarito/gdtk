#!/bin/sh
# Test del store de versiones y de la promocion semantica del supervisor (C2).
# No toca el store ni la sesion real: todo va en un tmpdir, con una "instalacion"
# temporal que copia los scripts reales y un gdtk-preflight controlable.
# Los shells de prueba son dobles que escriben (o no) un heartbeat atomico.
# Uso: tests/version_store_test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok=0; fail=0
check() { # check <desc> <cond-rc>
	if [ "$2" -eq 0 ]; then echo "ok   $1"; ok=$((ok + 1)); else echo "FAIL $1"; fail=$((fail + 1)); fi
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: falta jq"; exit 0; }
command -v rsync >/dev/null 2>&1 || { echo "SKIP: falta rsync"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GDTK_STORE="$TMP/store"
export XDG_STATE_HOME="$TMP/state"
export XDG_RUNTIME_DIR="$TMP/run"
export GDTK_TEST_PREFLIGHT_LOG="$TMP/preflight.log"
mkdir -p "$XDG_STATE_HOME/gdtk" "$XDG_RUNTIME_DIR/gdtk" "$TMP/inst/session" "$TMP/inst/shell"

# Aislamiento de la sesion real: el supervisor llama `pkill -x deskflow*` al terminar
# el shell. En pruebas ese pkill debe ser un no-op para no matar el Deskflow real.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/pkill"
chmod +x "$TMP/bin/pkill"
export PATH="$TMP/bin:$PATH"

# Instalacion de prueba: copias reales de los scripts a ejercitar.
cp "$ROOT/session/gdtk-version" "$ROOT/session/gdtk-supervisor" "$ROOT/session/gdtk-health" \
	"$TMP/inst/session/"
printf '[application]\nconfig/name="test"\n' >"$TMP/inst/shell/project.godot"
printf 'extends Reference\n' >"$TMP/inst/shell/x.gd"

# Preflight controlable: registra su invocacion y responde segun env.
cat >"$TMP/inst/session/gdtk-preflight" <<EOF
#!/bin/sh
echo "\$*" >> "$GDTK_TEST_PREFLIGHT_LOG"
exit "\${GDTK_TEST_PREFLIGHT_RC:-0}"
EOF
chmod +x "$TMP/inst/session/"*

V="$TMP/inst/session/gdtk-version"
SUP="$TMP/inst/session/gdtk-supervisor"
H="$TMP/inst/session/gdtk-health"
SUPLOG="$XDG_STATE_HOME/gdtk/supervisor.log"
clear_log() { : >"$SUPLOG"; }
last_good_id() { basename "$(readlink "$GDTK_STORE/last_good" 2>/dev/null)" 2>/dev/null; }

# --- gdtk-health: validacion del heartbeat atomico -------------------------------
printf '{"pid":4242,"generation":1,"sequence":5,"monotonic_ms":10,"reload":"ready"}\n' \
	>"$XDG_RUNTIME_DIR/gdtk/health.json"
check "health ok con pid correcto" "$([ "$("$H" probe 4242 | cut -f1)" = ok ]; echo $?)"
check "health sequence correcta" "$([ "$("$H" probe 4242 | cut -f2)" = 5 ]; echo $?)"
check "health valid sale 0" "$("$H" valid 4242 >/dev/null; echo $?)"
check "health wrongpid con pid ajeno" "$([ "$("$H" probe 1 | cut -f1)" = wrongpid ]; echo $?)"
check "health valid falla con pid ajeno" "$([ "$("$H" valid 1 >/dev/null; echo $?)" -ne 0 ]; echo $?)"
touch -d '1 hour ago' "$XDG_RUNTIME_DIR/gdtk/health.json"
check "health stale por frescura" "$([ "$(GDTK_HEALTH_STALE_AFTER=1 "$H" probe 4242 | cut -f1)" = stale ]; echo $?)"
printf 'no-es-json\n' >"$XDG_RUNTIME_DIR/gdtk/health.json"
check "health invalid con JSON roto" "$([ "$("$H" probe 4242 | cut -f1)" = invalid ]; echo $?)"
rm -f "$XDG_RUNTIME_DIR/gdtk/health.json"
check "health absent sin archivo" "$([ "$("$H" probe 4242 | cut -f1)" = absent ]; echo $?)"

# --- Store: snapshots, punteros y rollback --------------------------------------
# v1 sale de un arbol semilla distinto para que el arbol vivo "difiera".
mkdir -p "$TMP/seed/shell"
printf '[application]\n' >"$TMP/seed/shell/project.godot"
"$V" snapshot --from "$TMP/seed" --no-check --id v1 --use >/dev/null 2>&1
"$V" good v1 >/dev/null 2>&1
"$V" snapshot --from "$TMP/seed" --no-check --id v2 >/dev/null 2>&1
check "snapshot v1/v2 existen" "$([ -d "$GDTK_STORE/content/v1/shell" ] && [ -d "$GDTK_STORE/content/v2/shell" ]; echo $?)"
check "current es v1" "$([ "$("$V" current)" = v1 ]; echo $?)"
check "last_good es v1" "$([ "$(last_good_id)" = v1 ]; echo $?)"
"$V" use v2 >/dev/null 2>&1
check "use mueve current a v2" "$([ "$("$V" current)" = v2 ]; echo $?)"
"$V" rollback >/dev/null 2>&1
check "rollback vuelve a v1" "$([ "$("$V" current)" = v1 ]; echo $?)"

# --- autogood: ahora SIN --no-check (debe pasar por gdtk-preflight) --------------
"$V" use v1 >/dev/null 2>&1; "$V" good v1 >/dev/null 2>&1
lg_before="$(last_good_id)"
: >"$GDTK_TEST_PREFLIGHT_LOG"
GDTK_TEST_PREFLIGHT_RC=1 "$V" autogood >/dev/null 2>&1; rc=$?
check "autogood falla si preflight falla" "$([ "$rc" -ne 0 ]; echo $?)"
check "autogood no cambia last_good si preflight falla" "$([ "$(last_good_id)" = "$lg_before" ]; echo $?)"
check "autogood ejecuto gdtk-preflight" "$([ -s "$GDTK_TEST_PREFLIGHT_LOG" ]; echo $?)"
: >"$GDTK_TEST_PREFLIGHT_LOG"
GDTK_TEST_PREFLIGHT_RC=0 "$V" autogood >/dev/null 2>&1; rc=$?
lg_after="$(last_good_id)"
check "autogood promueve con preflight ok" "$([ "$rc" -eq 0 ]; echo $?)"
check "autogood cambio last_good" "$([ -n "$lg_after" ] && [ "$lg_after" != "$lg_before" ]; echo $?)"
check "autogood dejo last_good en good" "$([ "$(jq -r .status "$GDTK_STORE/content/$lg_after/meta.json")" = good ]; echo $?)"

# --- Dobles de shell: heartbeat que avanza, que se estanca, ausente o ajeno -----
cat >"$TMP/hb_advance" <<'EOF'
#!/bin/sh
d="${XDG_RUNTIME_DIR:-/tmp}/gdtk"; mkdir -p "$d"
i=0
while :; do
	i=$((i + 1))
	t="$d/.h.$$"
	printf '{"pid":%s,"generation":1,"sequence":%s,"monotonic_ms":%s,"reload":"ready"}\n' "$$" "$i" "$i" >"$t"
	mv -f "$t" "$d/health.json"
	sleep "${GDTK_HEALTH_INTERVAL:-1}"
done
EOF
cat >"$TMP/hb_stall" <<'EOF'
#!/bin/sh
d="${XDG_RUNTIME_DIR:-/tmp}/gdtk"; mkdir -p "$d"
t="$d/.h.$$"
printf '{"pid":%s,"generation":1,"sequence":1,"monotonic_ms":1,"reload":"ready"}\n' "$$" >"$t"
mv -f "$t" "$d/health.json"
while :; do sleep 1; done
EOF
cat >"$TMP/hb_absent" <<'EOF'
#!/bin/sh
while :; do sleep 1; done
EOF
cat >"$TMP/hb_wrongpid" <<'EOF'
#!/bin/sh
d="${XDG_RUNTIME_DIR:-/tmp}/gdtk"; mkdir -p "$d"
i=0
while :; do
	i=$((i + 1))
	t="$d/.h.$$"
	printf '{"pid":999999,"generation":1,"sequence":%s,"monotonic_ms":%s,"reload":"ready"}\n' "$i" "$i" >"$t"
	mv -f "$t" "$d/health.json"
	sleep 1
done
EOF
chmod +x "$TMP/hb_advance" "$TMP/hb_stall" "$TMP/hb_absent" "$TMP/hb_wrongpid"
unset GDTK_HEALTH_KILL_HUNG GDTK_TEST_PREFLIGHT_RC
reset_good_v1() { "$V" use v1 >/dev/null 2>&1; "$V" good v1 >/dev/null 2>&1; rm -f "$XDG_RUNTIME_DIR/gdtk/health.json"; }

# Caso 1: heartbeat estancado -> NO promueve (aunque el PID siga vivo).
reset_good_v1; clear_log; : >"$GDTK_TEST_PREFLIGHT_LOG"
GDTK_PROMOTE_AFTER=1 GDTK_HEALTH_INTERVAL=1 GDTK_HEALTH_TIMEOUT=2 \
	timeout 5 "$SUP" "$TMP/hb_stall" --path /nope >/dev/null 2>&1
check "estancado NO promueve" "$([ "$(last_good_id)" = v1 ]; echo $?)"
check "estancado reporta hung" "$(grep -q 'sin progreso' "$SUPLOG"; echo $?)"
check "estancado no mata (default)" "$(! grep -q 'termino el shell colgado' "$SUPLOG"; echo $?)"
check "estancado no intenta promocion" "$(! grep -q 'guardado como last_good' "$SUPLOG"; echo $?)"

# Caso 2: heartbeat que avanza -> SI promueve.
reset_good_v1; clear_log; : >"$GDTK_TEST_PREFLIGHT_LOG"
GDTK_PROMOTE_AFTER=1 GDTK_HEALTH_INTERVAL=1 GDTK_HEALTH_TIMEOUT=4 \
	timeout 7 "$SUP" "$TMP/hb_advance" --path /nope >/dev/null 2>&1
lg="$(last_good_id)"
check "avanza SI promueve" "$([ -n "$lg" ] && [ "$lg" != v1 ]; echo $?)"
check "avanza deja last_good good" "$([ "$(jq -r .status "$GDTK_STORE/content/$lg/meta.json")" = good ]; echo $?)"
check "avanza lo registra en el supervisor" "$(grep -q 'guardado como last_good' "$SUPLOG"; echo $?)"
check "avanza corrio preflight" "$([ -s "$GDTK_TEST_PREFLIGHT_LOG" ]; echo $?)"

# Caso 3: sin heartbeat -> no promueve y no mata (compatibilidad de arranque).
reset_good_v1; clear_log
GDTK_PROMOTE_AFTER=1 GDTK_HEALTH_INTERVAL=1 GDTK_HEALTH_TIMEOUT=2 \
	timeout 4 "$SUP" "$TMP/hb_absent" --path /nope >/dev/null 2>&1
check "sin heartbeat no promueve" "$([ "$(last_good_id)" = v1 ]; echo $?)"
check "sin heartbeat no reporta hung" "$(! grep -q 'sin progreso' "$SUPLOG"; echo $?)"

# Caso 4: heartbeat de otro PID -> no promueve y no mata.
reset_good_v1; clear_log
GDTK_PROMOTE_AFTER=1 GDTK_HEALTH_INTERVAL=1 GDTK_HEALTH_TIMEOUT=2 \
	timeout 4 "$SUP" "$TMP/hb_wrongpid" --path /nope >/dev/null 2>&1
check "PID ajeno no promueve" "$([ "$(last_good_id)" = v1 ]; echo $?)"

# Caso 5: la muerte por cuelgue SOLO con GDTK_HEALTH_KILL_HUNG=1.
reset_good_v1; clear_log
GDTK_HEALTH_KILL_HUNG=1 GDTK_PROMOTE_AFTER=99 GDTK_HEALTH_INTERVAL=1 GDTK_HEALTH_TIMEOUT=2 \
	timeout 5 "$SUP" "$TMP/hb_stall" --path /nope >/dev/null 2>&1
check "KILL_HUNG=1 termina el colgado" "$(grep -q 'termino el shell colgado' "$SUPLOG"; echo $?)"
check "KILL_HUNG=1 no promueve" "$([ "$(last_good_id)" = v1 ]; echo $?)"

echo "version_store_test: ok=$ok FAIL=$fail"
[ "$fail" -eq 0 ]
