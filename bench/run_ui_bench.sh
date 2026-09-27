#!/bin/sh
# Benchmark ImGui vs controles nativos de Godot (SPEC-hud D).
#
# Corre la matriz: driver (GLES2/GLES3) x ui (godot/imgui) x modo
# (estatico/dinamico) x N (20/100/400) bajo cage anidado, con vsync off y 120
# frames de calentamiento + 600 medidos, y escribe bench/RESULTS.md.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GDTK_GODOT="${GDTK_GODOT:-/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk}"
RESULTS_DIR="$HERE/results"
mkdir -p "$RESULTS_DIR"

export SDL_VIDEODRIVER=wayland
export SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
	export XDG_RUNTIME_DIR="/run/user/$(id -u)"
fi

WARMUP="${BENCH_WARMUP:-120}"
FRAMES="${BENCH_FRAMES:-600}"
TIMEOUT="${BENCH_TIMEOUT:-180}"

echo "== ui_bench: $GDTK_GODOT ==" >"$RESULTS_DIR/run.log"

for driver in GLES2 GLES3; do
	for ui in godot imgui; do
		for mode in static dynamic; do
			for n in 20 100 400; do
				out="$RESULTS_DIR/${driver}_${ui}_${mode}_${n}.json"
				rm -f "$out"
				echo "-- $driver $ui $mode N=$n"
				timeout "$TIMEOUT" cage -s -- "$GDTK_GODOT" --video-driver "$driver" \
					--path "$HERE/ui_bench" -- \
					"--ui=$ui" "--mode=$mode" "--n=$n" \
					"--warmup=$WARMUP" "--frames=$FRAMES" "--out=$out" \
					>>"$RESULTS_DIR/run.log" 2>&1
				rc=$?
				if [ "$rc" -ne 0 ] || [ ! -f "$out" ]; then
					echo "   FALLO (rc=$rc, out=$out)" | tee -a "$RESULTS_DIR/run.log"
				fi
			done
		done
	done
done

python3 - "$RESULTS_DIR" "$ROOT/bench/RESULTS.md" <<'PY'
import glob
import json
import os
import sys

results_dir, out_path = sys.argv[1], sys.argv[2]
rows = []
for path in sorted(glob.glob(os.path.join(results_dir, "*.json"))):
    with open(path) as handle:
        data = json.load(handle)
    metrics = data["metrics"]
    rows.append({
        "driver": os.path.basename(path).split("_")[0],
        "ui": data["ui"],
        "mode": data["mode"],
        "n": data["n"],
        "frame_mean": metrics["frame_ms"]["mean"],
        "frame_p95": metrics["frame_ms"]["p95"],
        "process_mean": metrics["process_ms"]["mean"],
        "draw_calls": metrics["draw_calls"]["mean"],
        "items_2d": metrics["items_2d"]["mean"],
        "draw_2d": metrics["draw_2d"]["mean"],
        "mem_mb": metrics["mem_static"]["mean"] / 1048576.0,
        "nodes": metrics["nodes"]["mean"],
    })

order = {"GLES2": 0, "GLES3": 1}
rows.sort(key=lambda r: (order.get(r["driver"], 9), r["ui"], r["mode"], r["n"]))

lines = []
lines.append("# Benchmark ImGui vs controles de Godot\n")
lines.append("Generado por `bench/run_ui_bench.sh` con el binario FRT de gdtk, bajo")
lines.append("cage anidado, vsync off, 120 frames de calentamiento y 600 medidos.")
lines.append("")
lines.append("## Tabla\n")
lines.append("| driver | ui | modo | N | frame ms (media) | frame ms (p95) | process ms (media) | draw calls | 2D items | 2D draws | mem MB | nodos |")
lines.append("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for r in rows:
    lines.append("| %s | %s | %s | %d | %.2f | %.2f | %.3f | %.1f | %.1f | %.1f | %.1f | %.0f |" % (
        r["driver"], r["ui"], r["mode"], r["n"], r["frame_mean"], r["frame_p95"],
        r["process_mean"], r["draw_calls"], r["items_2d"], r["draw_2d"], r["mem_mb"], r["nodes"]))

def find(driver, ui, mode, n):
    for r in rows:
        if r["driver"] == driver and r["ui"] == ui and r["mode"] == mode and r["n"] == n:
            return r
    return None

lines.append("")
lines.append("## Conclusiones medidas\n")
conclusions = []
for mode in ("static", "dynamic"):
    for driver in ("GLES2", "GLES3"):
        g = find(driver, "godot", mode, 400)
        i = find(driver, "imgui", mode, 400)
        if g and i:
            if g["frame_mean"] < i["frame_mean"]:
                winner, loser = "Godot", "ImGui"
                best, worst = g, i
            else:
                winner, loser = "ImGui", "Godot"
                best, worst = i, g
            conclusions.append(
                "%s %s N=400: gana %s (%.2f ms de frame vs %.2f ms, %.0f%% menos)."
                % (driver, mode, winner, best["frame_mean"], worst["frame_mean"],
                   100.0 * (worst["frame_mean"] - best["frame_mean"]) / max(worst["frame_mean"], 1e-6)))
for driver in ("GLES2", "GLES3"):
    g = find(driver, "godot", "dynamic", 400)
    i = find(driver, "imgui", "dynamic", 400)
    if g and i:
        conclusions.append(
            "%s dynamic N=400 draw calls: Godot %.0f vs ImGui %.0f; 2D items: Godot %.0f vs ImGui %.0f."
            % (driver, g["draw_calls"], i["draw_calls"], g["items_2d"], i["items_2d"]))
for r in rows:
    if r["n"] == 400 and r["mode"] == "static":
        conclusions.append(
            "%s static N=400 %s: mem %.1f MB, nodos %.0f."
            % (r["driver"], r["ui"], r["mem_mb"], r["nodes"]))
for c in conclusions[:5]:
    lines.append("- " + c)
lines.append("")

with open(out_path, "w") as handle:
    handle.write("\n".join(lines) + "\n")
print("RESULTADO: OK -> %s (%d filas)" % (out_path, len(rows)))
PY
