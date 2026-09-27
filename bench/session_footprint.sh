#!/bin/sh
# Huella en reposo de la sesión gráfica activa en seat0 (gdtk vs XFCE en la misma máquina).
# Corre EN el host:   ssh icarito@tengu sh gdtk/bench/session_footprint.sh [segundos]   (default 60)
# Comparar:           sh session_footprint.sh --compare a.json b.json
#
# Qué mide:
#  - PSS (smaps_rollup) de todos los procesos del scope session-N.scope + el Xorg que lanza
#    lightdm FUERA del scope (en sesiones Wayland el compositor/Xwayland ya está dentro).
#    PSS reparte las páginas compartidas (libs) entre quienes las usan: sumar PSS no cuenta doble.
#  - memory.current del scope (incluye page cache y kernel cargados al cgroup; no incluye Xorg).
#  - Aparte, user@1000.service (dbus, pipewire, portales, gvfs...): es común a ambos escritorios,
#    pero XFCE suele despertar más servicios por D-Bus, así que se reporta sin sumarlo.
#  - CPU en reposo: delta de usage_usec del scope + utime/stime del Xorg externo, en % de UN core.
#  - Cambios de contexto/s (voluntarios+involuntarios) de los mismos procesos: proxy barato de
#    wakeups (powertop pide root y ensucia la medición).
#  - MemAvailable global (/proc/meminfo): segunda métrica, independiente de cómo contemos procesos.
# Qué es comparable: XFCE recién entrado sin apps abiertas vs gdtk en el Home, sin tocar nada;
#  esperar >=30 s tras el login (se avisa si no); mismo kernel, misma pantalla, mismos servicios.
#  Lo que el usuario lance a mano dentro de la sesión (p.ej. deskflow) también cuenta: ciérralo
#  o compáralo en ambas. Procesos lanzados por ssh (otra sesión, p.ej. gdtk_mcp.py) NO cuentan.
# Qué NO mide: tiempo de arranque, GPU/VRAM (GM45 usa RAM compartida vía GEM, sólo se ve en parte
#  en el PSS del proceso que mapea los buffers), consumo en uso activo, disco.

if [ "$1" = "--compare" ]; then
	exec python3 - "$2" "$3" <<'EOF'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
print(f"{'':28}{a['desktop']:>14}{b['desktop']:>14}{'b-a':>10}")
for k in ("session_pss_kb", "scope_memory_current_kb", "user_services_pss_kb", "mem_available_kb",
          "cpu_pct_core", "ctxsw_per_s", "nprocs"):
    d = b[k] - a[k]
    print(f"{k:28}{a[k]:>14}{b[k]:>14}{round(d, 2):>10}")
EOF
fi

SECS="${1:-60}"
SID=$(loginctl list-sessions --no-legend | awk '$4 == "seat0" {print $1; exit}')
[ -n "$SID" ] || { echo "no hay sesión en seat0"; exit 1; }
prop() { loginctl show-session "$SID" -p "$1" --value; }
DESKTOP=$(prop Desktop); DISPLAY_=$(prop Display); UIDN=$(prop User)
SINCE=$(( $(date +%s) - $(date -d "$(prop Timestamp)" +%s) ))
[ "$SINCE" -ge 30 ] || echo "AVISO: la sesión lleva ${SINCE}s; espera >=30 s tras el login" >&2
U=/sys/fs/cgroup/user.slice/user-$UIDN.slice
SCOPE=$U/session-$SID.scope
SUDO=; [ "$(id -u)" = 0 ] || SUDO="sudo -n"

# Xorg del display manager (fuera del scope) que sirve el Display de esta sesión.
XPID=
[ -n "$DISPLAY_" ] && for p in $(pgrep -x Xorg); do
	tr '\0' ' ' </proc/$p/cmdline | grep -q " $DISPLAY_ " && XPID=$p
done
SPIDS="$(cat $SCOPE/cgroup.procs) $XPID"
UPIDS=$(find $U/user@$UIDN.service -name cgroup.procs -exec cat {} + 2>/dev/null)

# pss_list pid...  ->  "pss_kb pid comm" por proceso (procesos que mueren a mitad se ignoran)
pss_list() { for p; do
	k=$($SUDO awk '/^Pss:/ {print $2}' /proc/$p/smaps_rollup 2>/dev/null) || continue
	[ -n "$k" ] && echo "$k $p $(cat /proc/$p/comm 2>/dev/null)"
done; }
# ctx pid... -> suma de cambios de contexto
ctx() { for p; do cat /proc/$p/status 2>/dev/null; done | awk '/ctxt_switches/ {s+=$2} END {print s+0}'; }
xticks() { [ -n "$XPID" ] && awk '{print $14+$15}' /proc/$XPID/stat || echo 0; }
usage() { awk '/^usage_usec/ {print $2}' $SCOPE/cpu.stat; }

# CPU: dos muestras separadas SECS segundos.
c0=$(usage); x0=$(xticks); w0=$(ctx $SPIDS); t0=$(date +%s.%N)
sleep "$SECS"
c1=$(usage); x1=$(xticks); w1=$(ctx $SPIDS); t1=$(date +%s.%N)
HZ=$(getconf CLK_TCK)
CPU=$(awk -v c="$((c1-c0))" -v x="$((x1-x0))" -v hz="$HZ" -v t0="$t0" -v t1="$t1" \
	'BEGIN {printf "%.2f", (c/1e6 + x/hz) / (t1-t0) * 100}')
CTX=$(awk -v w="$((w1-w0))" -v t0="$t0" -v t1="$t1" 'BEGIN {printf "%.1f", w/(t1-t0)}')

# Memoria: después de la ventana de CPU, así el login ya se asentó un poco más.
SLIST=$(pss_list $SPIDS | sort -rn)
PSS=$(echo "$SLIST" | awk '{s+=$1} END {print s+0}')
NPROCS=$(echo "$SLIST" | grep -c .)
UPSS=$(pss_list $UPIDS | awk '{s+=$1} END {print s+0}')
MEMCUR=$(( $(cat $SCOPE/memory.current) / 1024 ))
AVAIL=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)

TOP=$(echo "$SLIST" | head -10 | awk '{c=$0; sub(/^[^ ]+ [^ ]+ /, "", c); printf "%s{\"pss_kb\": %d, \"pid\": %d, \"comm\": \"%s\"}", (NR>1 ? ", " : ""), $1, $2, c}')
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=~/gdtk-bench/${DESKTOP:-unknown}-$STAMP.json
mkdir -p ~/gdtk-bench
cat >"$OUT" <<EOF
{"desktop": "$DESKTOP", "session": "$SID", "type": "$(prop Type)", "date": "$STAMP",
 "session_age_s": $SINCE, "seconds": $SECS, "host": "$(hostname)", "kernel": "$(uname -r)",
 "session_pss_kb": $PSS, "xorg_pid": "${XPID}", "nprocs": $NPROCS,
 "scope_memory_current_kb": $MEMCUR, "user_services_pss_kb": $UPSS, "mem_available_kb": $AVAIL,
 "cpu_pct_core": $CPU, "ctxsw_per_s": $CTX,
 "top": [$TOP]}
EOF

echo "$SLIST" | head -10 | awk '{c=$0; sub(/^[^ ]+ [^ ]+ /, "", c); printf "  %7.1f MB  %s (%s)\n", $1/1024, c, $2}'
printf '%s: PSS sesión %.1f MB (%d procs, Xorg incl.) | scope %.1f MB | servicios usuario %.1f MB | MemAvailable %.0f MB | CPU %s%% core | %s ctxsw/s\n' \
	"$DESKTOP" "$(echo "$PSS/1024" | bc -l)" "$NPROCS" "$(echo "$MEMCUR/1024" | bc -l)" \
	"$(echo "$UPSS/1024" | bc -l)" "$(echo "$AVAIL/1024" | bc -l)" "$CPU" "$CTX"
echo "$OUT"
