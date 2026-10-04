#!/bin/sh
# Test del helper privilegiado session/gdtk-governor-helper sobre un árbol sysfs falso
# (SPEC-power-governor). No usa pkexec, sudo, ni /sys real.
#   sh tests/gdtk_governor_test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/session/gdtk-governor-helper"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failed=0

check() { # check <nombre> <rc de [ ... ]>
	if [ "$2" -eq 0 ]; then
		echo "ok   $1"
	else
		echo "FAIL $1"
		failed=$((failed + 1))
	fi
}

read_line() {
	v=""
	IFS= read -r v < "$1" 2>/dev/null || true
	printf '%s' "$v"
}

mkpolicy() { # mkpolicy <sysfs> <índice> <available> <current>
	d="$1/devices/system/cpu/cpufreq/policy$2"
	mkdir -p "$d"
	printf '%s\n' "$3" > "$d/scaling_available_governors"
	printf '%s\n' "$4" > "$d/scaling_governor"
}

run_helper() { # run_helper <sysfs> [args...]
	sf="$1"; shift
	GDTK_GOVERNOR_TEST=1 GDTK_GOVERNOR_SYSFS="$sf" sh "$HELPER" "$@"
}

# --- dos policies ---
S1="$TMP/sys1"
mkpolicy "$S1" 0 "performance powersave schedutil" "schedutil"
mkpolicy "$S1" 1 "performance powersave schedutil" "schedutil"

run_helper "$S1" >/dev/null 2>&1; [ $? -ne 0 ]
check "rechaza cero argumentos" $?

run_helper "$S1" performance extra >/dev/null 2>&1; [ $? -ne 0 ]
check "rechaza dos argumentos" $?

run_helper "$S1" "powersave; rm -rf $TMP" >/dev/null 2>&1; [ $? -ne 0 ]
check "rechaza inyección con shell" $?
[ "$(read_line "$S1/devices/system/cpu/cpufreq/policy0/scaling_governor")" = "schedutil" ]
check "inyección no toca el valor" $?

run_helper "$S1" bogus >/dev/null 2>&1; [ $? -ne 0 ]
check "rechaza governor ausente" $?

run_helper "$S1" powersave >/dev/null 2>&1; [ $? -eq 0 ]
check "aplica governor válido" $?
[ "$(read_line "$S1/devices/system/cpu/cpufreq/policy0/scaling_governor")" = "powersave" ]
check "policy0 actualizada" $?
[ "$(read_line "$S1/devices/system/cpu/cpufreq/policy1/scaling_governor")" = "powersave" ]
check "policy1 actualizada" $?

# --- fallo parcial: una policy no se puede escribir (es un directorio) ---
S2="$TMP/sys2"
mkpolicy "$S2" 0 "performance powersave" "performance"
mkpolicy "$S2" 1 "performance powersave" "performance"
rm -f "$S2/devices/system/cpu/cpufreq/policy1/scaling_governor"
mkdir "$S2/devices/system/cpu/cpufreq/policy1/scaling_governor"
run_helper "$S2" powersave >/dev/null 2>&1; [ $? -ne 0 ]
check "fallo parcial devuelve rc != 0" $?
[ "$(read_line "$S2/devices/system/cpu/cpufreq/policy0/scaling_governor")" = "powersave" ]
check "policy sana sí se escribió" $?

# --- fallback cpu0 sin policies ---
S3="$TMP/sys3"
mkdir -p "$S3/devices/system/cpu/cpu0/cpufreq"
printf '%s\n' "performance powersave" > "$S3/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
printf '%s\n' "performance" > "$S3/devices/system/cpu/cpu0/cpufreq/scaling_governor"
run_helper "$S3" powersave >/dev/null 2>&1; [ $? -eq 0 ]
check "fallback cpu0 ok" $?
[ "$(read_line "$S3/devices/system/cpu/cpu0/cpufreq/scaling_governor")" = "powersave" ]
check "fallback cpu0 actualizado" $?

# --- sin lista de governors ---
S4="$TMP/sys4"
mkdir -p "$S4/devices/system/cpu/cpufreq/policy0"
printf '%s\n' "schedutil" > "$S4/devices/system/cpu/cpufreq/policy0/scaling_governor"
run_helper "$S4" schedutil >/dev/null 2>&1; [ $? -ne 0 ]
check "sin lista de governors falla" $?

echo "----"
if [ "$failed" -eq 0 ]; then
	echo "TODO OK"
	exit 0
fi
echo "$failed FAIL"
exit 1
