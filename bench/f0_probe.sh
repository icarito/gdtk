#!/bin/sh
# F0 — Probe de medición de la sesión en seat0 (gdtk o GNOME), sólo lectura.
# Uso: bench/f0_probe.sh <label> [segundos]        (default 30s)
#
# Mide, en una ventana de N segundos, deltas de:
#  - CPU de la sesión (cgroup usage_usec; fallback suma de /proc de la sesión) en % de un core
#  - CPU del shell (godot-gdtk o gnome-shell) en % de un core
#  - cambios de contexto/s de la sesión
#  - si es gdtk: RPC state -> dmabuf_commits/s, shm_commits/s, present.{light,full}/s, commits/s,
#    scanout_suspended; y el último [FRT_PERF]/[FRT_GPU] del shell.log (ms/frame, fps)
#  - frecuencia GPU i915 (gt_cur/act_freq_mhz), MemAvailable
# Salida: ~/gdtk-bench/f0-<label>-<stamp>.json + resumen por stdout.
# NO toca la sesión: no lanza apps ni cambia foco. Sólo lee /proc, /sys, cgroup y RPC.
set -u

LABEL="${1:-sesion}"
SECS="${2:-30}"
UIDN="$(id -u)"

SID="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" {print $1; exit}')"
[ -n "$SID" ] || { echo "error: no hay sesión en seat0" >&2; exit 1; }
DESKTOP="$(loginctl show-session "$SID" -p Desktop --value 2>/dev/null)"
TYPE="$(loginctl show-session "$SID" -p Type --value 2>/dev/null)"
TS="$(loginctl show-session "$SID" -p Timestamp --value 2>/dev/null)"
SCOPE="/sys/fs/cgroup/user.slice/user-$UIDN.slice/session-$SID.scope"

# Shell a medir: godot-gdtk (gdtk) o gnome-shell (GNOME).
SHELL_PID="$(pgrep -x godot-gdtk | head -1)"
[ -n "$SHELL_PID" ] || SHELL_PID="$(pgrep -f 'godot-gdtk --video-driver' | while read p; do
	[ "$(cat /proc/$p/comm 2>/dev/null)" = godot-gdtk ] && { echo "$p"; break; }
done)"
[ -n "$SHELL_PID" ] || SHELL_PID="$(pgrep -x gnome-shell | head -1)"
[ -n "$DESKTOP" ] || { [ -n "$SHELL_PID" ] && DESKTOP="gdtk"; }
TOKEN_FILE="/run/user/$UIDN/gdtk-control.token"
[ -f "$TOKEN_FILE" ] || TOKEN_FILE=""

export F0_LABEL="$LABEL" F0_SECS="$SECS" F0_SID="$SID" F0_DESKTOP="$DESKTOP" \
	F0_TYPE="$TYPE" F0_TS="$TS" F0_SCOPE="$SCOPE" F0_SHELL_PID="$SHELL_PID" \
	F0_TOKEN_FILE="$TOKEN_FILE" F0_UID="$UIDN"

exec python3 - <<'PY'
import os, sys, time, json, socket, subprocess, glob, datetime

env = os.environ
secs = int(env["F0_SECS"])
label = env["F0_LABEL"]
scope = env["F0_SCOPE"]
shell_pid = env["F0_SHELL_PID"].strip()
token_file = env["F0_TOKEN_FILE"].strip()
hz = os.sysconf("SC_CLK_TCK")
host = socket.gethostname()
kernel = os.uname().release

def read(p, cast=str):
    try:
        with open(p) as f:
            return cast(f.read().strip())
    except Exception:
        return None

def scope_procs():
    try:
        with open(os.path.join(scope, "cgroup.procs")) as f:
            return [int(x) for x in f.read().split()]
    except Exception:
        return []

def scope_usage_usec():
    v = read(os.path.join(scope, "cpu.stat"))
    if v:
        for line in v.splitlines():
            if line.startswith("usage_usec"):
                return int(line.split()[1])
    # fallback: suma de utime+stime de los procesos del scope
    tot = 0
    for p in scope_procs():
        s = read("/proc/%d/stat" % p)
        if not s:
            continue
        try:
            r = s[s.rfind(")") + 2:].split()
            tot += int(r[11]) + int(r[12])
        except Exception:
            pass
    return tot * (1000000 // hz)

def proc_cpu_ticks(pid):
    s = read("/proc/%s/stat" % pid)
    if not s:
        return None
    try:
        r = s[s.rfind(")") + 2:].split()
        return int(r[11]) + int(r[12])
    except Exception:
        return None

def ctxsw(procs):
    tot = 0
    for p in procs:
        s = read("/proc/%d/status" % p)
        if not s:
            continue
        for line in s.splitlines():
            if "ctxt_switches" in line:
                try:
                    tot += int(line.split()[1])
                except Exception:
                    pass
    return tot

def gpu_freq():
    for c in sorted(glob.glob("/sys/class/drm/card*/gt_cur_freq_mhz")):
        v = read(c, int)
        if v is not None:
            return v
    return None

def gpu_act():
    for c in sorted(glob.glob("/sys/class/drm/card*/gt_act_freq_mhz")):
        v = read(c, int)
        if v is not None:
            return v
    return None

def mem_available_kb():
    v = read("/proc/meminfo")
    if not v:
        return None
    for line in v.splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1])
    return None

def rpc(method, params):
    if not token_file:
        return None
    try:
        tok = open(token_file).read().strip()
    except Exception:
        return None
    try:
        s = socket.create_connection(("127.0.0.1", 7777), timeout=2)
        f = s.makefile("rwb")
        def ex(i, m, p):
            f.write((json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": p}) + "\n").encode())
            f.flush()
            return json.loads(f.readline().decode())
        ex(1, "auth", {"token": tok})
        r = ex(2, method, params)
        s.close()
        return r.get("result")
    except Exception:
        return None

def last_frt():
    """Ultimo [FRT_PERF]/[FRT_GPU] del shell.log (si el shell arranco con FRT_PERF)."""
    out = {}
    for path in (os.path.expanduser("~/.local/state/gdtk/shell.log"),):
        try:
            data = open(path, errors="replace").read().splitlines()
        except Exception:
            continue
        for line in reversed(data):
            if line.startswith("[FRT_PERF]") and "perf" not in out:
                d = {}
                for tok in line[len("[FRT_PERF]"):].split():
                    if "=" in tok:
                        k, v = tok.split("=", 1)
                        try:
                            d[k] = float(v)
                        except Exception:
                            pass
                if d:
                    out["perf"] = d
            if line.startswith("[FRT_GPU]") and "gpu_ms" not in out:
                for tok in line.split():
                    if tok.startswith("gpu="):
                        try:
                            out["gpu_ms"] = float(tok[4:].split("ms")[0])
                        except Exception:
                            pass
        if out:
            break
    return out

t0 = time.time()
procs0 = scope_procs()
cpu0 = scope_usage_usec()
sh0 = proc_cpu_ticks(shell_pid)
ctx0 = ctxsw(procs0)
st0 = rpc("state", {}) or {}
freqs, acts = [], []
while time.time() - t0 < secs:
    g = gpu_freq()
    if g:
        freqs.append(g)
    a = gpu_act()
    if a:
        acts.append(a)
    time.sleep(1.0)
t1 = time.time()
procs1 = scope_procs()
cpu1 = scope_usage_usec()
sh1 = proc_cpu_ticks(shell_pid)
ctx1 = ctxsw(procs1)
st1 = rpc("state", {}) or {}
dt = t1 - t0

def rate(a, b):
    return round((b - a) / dt, 2) if (a is not None and b is not None and dt > 0) else None

def ratio(v, u):
    return round(v / dt, 2) if (v is not None and dt > 0) else None

c0 = st0.get("compositor", {})
c1 = st1.get("compositor", {})
p0 = st0.get("present", {})
p1 = st1.get("present", {})
rpc_ok = bool(st1)

res = {
    "host": host, "kernel": kernel, "label": label,
    "desktop": env["F0_DESKTOP"], "session": env["F0_SID"], "type": env["F0_TYPE"],
    "session_age_s": None, "seconds": round(dt, 2),
    "session_cpu_pct_core": round((cpu1 - cpu0) / dt / 1e4, 2) if dt > 0 else None,
    "shell_pid": shell_pid, "shell": "godot-gdtk" if shell_pid and "godot" in (read("/proc/%s/comm" % shell_pid) or "") else ("gnome-shell" if shell_pid else None),
    "shell_cpu_pct_core": round((sh1 - sh0) / dt / hz * 100, 2) if (sh0 is not None and sh1 is not None and dt > 0) else None,
    "ctxsw_per_s": ratio(ctx1 - ctx0, 1),
    "nprocs_session": len(procs1),
    "gpu_freq_cur_avg_mhz": round(sum(freqs) / len(freqs), 1) if freqs else None,
    "gpu_freq_act_max_mhz": max(acts) if acts else None,
    "mem_available_kb": mem_available_kb(),
    "rpc": rpc_ok,
    "gdtk": {
        "dmabuf_commits_per_s": ratio(c1.get("dmabuf_commits", 0) - c0.get("dmabuf_commits", 0), 1) if rpc_ok else None,
        "shm_commits_per_s": ratio(c1.get("shm_commits", 0) - c0.get("shm_commits", 0), 1) if rpc_ok else None,
        "present_light_per_s": ratio(p1.get("light", 0) - p0.get("light", 0), 1) if rpc_ok else None,
        "present_full_per_s": ratio(p1.get("full", 0) - p0.get("full", 0), 1) if rpc_ok else None,
        "scanout": c1.get("scanout"), "scanout_suspended": c1.get("scanout_suspended"),
        "view": st1.get("view"),
        "windows": [w.get("title") for w in st1.get("windows", [])] if rpc_ok else None,
    } if rpc_ok else None,
    "frt": last_frt() or None,
}
try:
    res["session_age_s"] = int(time.time() - datetime.datetime.strptime(env["F0_TS"], "%Y-%m-%d %H:%M:%S %Z").timestamp())
except Exception:
    pass

outdir = os.path.expanduser("~/gdtk-bench")
os.makedirs(outdir, exist_ok=True)
stamp = time.strftime("%Y%m%d-%H%M%S")
path = os.path.join(outdir, "f0-%s-%s.json" % (label.replace(" ", "_"), stamp))
json.dump(res, open(path, "w"), indent=1)

print("host=%s desktop=%s label=%s (%.0fs)" % (host, res["desktop"], label, dt))
print("  session CPU %s%% core | shell %s CPU %s%% core | %s ctxsw/s | %d procs" % (
    res["session_cpu_pct_core"], res["shell"], res["shell_cpu_pct_core"], res["ctxsw_per_s"], res["nprocs_session"]))
if res["gdtk"]:
    g = res["gdtk"]
    print("  gdtk: dmabuf %s/s shm %s/s | present light %s/s full %s/s | scanout=%s susp=%s | view=%s wins=%s" % (
        g["dmabuf_commits_per_s"], g["shm_commits_per_s"], g["present_light_per_s"], g["present_full_per_s"],
        g["scanout"], g["scanout_suspended"], g["view"], g["windows"]))
if res["frt"]:
    print("  frt: %s" % res["frt"])
print("  gpu_freq cur_avg=%s act_max=%s MHz | MemAvailable=%s MB" % (
    res["gpu_freq_cur_avg_mhz"], res["gpu_freq_act_max_mhz"], (res["mem_available_kb"] or 0) // 1024))
print(path)
PY
