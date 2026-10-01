#!/bin/sh
# Corre todos los tests headless de tests/ y resume ok/FAIL. Uso: tools/verify_all.sh
G="${GDTK_GODOT:-/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk}"
cd "$(dirname "$0")/.." || exit 1
bad=0
for t in tests/*_test.gd; do
	out=$(timeout 60 "$G" --no-window --path shell -s "$PWD/$t" 2>&1); rc=$?
	ok=$(printf '%s\n' "$out" | grep -c '^ok'); fail=$(printf '%s\n' "$out" | grep -c '^FAIL')
	st=OK; [ "$rc" -ne 0 ] || [ "$fail" -gt 0 ] && { st=MAL; bad=1; }
	[ "$rc" -eq 124 ] && st="CUELGA(conocido si carga shell.gd: RemoteInput)"
	printf '%-45s ok=%-3s FAIL=%-2s rc=%-3s %s\n' "$t" "$ok" "$fail" "$rc" "$st"
done
exit $bad
