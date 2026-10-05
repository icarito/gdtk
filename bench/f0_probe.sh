#!/bin/sh
# F0 — Probe de medición de la sesión gráfica activa en seat0 (gdtk o GNOME), sólo lectura.
# Uso: bench/f0_probe.sh <label> [segundos]        (default 30s)
#
# Mide en una ventana de N segundos (deltas), comparable entre escritorios:
#  - CPU de la máquina: cores ocupados en promedio (busy activo / tiempo), de /proc/stat.
#  - CPU del shell (godot-gdtk o gnome-shell) en % de un core; nombre detectado por comm.
#  - cambios de contexto globales/s (/proc/stat ctxt) y de la sesión (best-effort).
#  - frecuencia GPU i915 (gt_cur/act_freq_mhz), MemAvailable.
#  - si el shell es gdtk: RPC state -> dmabuf_commits/s, shm_commits/s, present.{light,full}/s,
#    scanout/scanout_suspended; y el último [FRT_PERF]/[FRT_GPU] de shell.log (si FRT_PERF=1).
# Salida: ~/gdtk-bench/f0-<label>-<stamp>.json + resumen por stdout.
# NO toca la sesión: no lanza apps ni cambia foco. Sólo lee /proc, /sys y RPC.
set -u

LABEL="${1:-sesion}"
SECS="${2:-30}"
UIDN="$(id -u)"

SID="$(loginctl list-sessions --no-legend 2>/dev/null | awk '$4 == "seat0" {print $1; exit}')"
[ -n "$SID" ] || { echo "error: no hay sesión en seat0" >&2; exit 1; }
TYPE="$(loginctl show-session "$SID" -p Type --value 2>/dev/null)"
TS="$(loginctl show-session "$SID" -p Timestamp --value 2>/dev/null)"
SCOPE="/sys/fs/cgroup/user.slice/user-$UIDN.slice/session-$SID.scope"

# Shell a medir: godot-gdtk (gdtk) o gnome-shell (GNOME).
SHELL_PID="$(pgrep -x godot-gdtk | head -1)"
[ -n "$SHELL_PID" ] || SHELL_PID="$(pgrep -f 'godot-gdtk --video-driver' | while read p; do
	[ "$(cat /proc/$p/comm 2>/dev/null)" = godot-gdtk ] && { echo "$p"; break; }
done)"
[ -n "$SHELL_PID" ] || SHELL_PID="$(pgrep -x gnome-shell | head -1)"
TOKEN_FILE="/run/user/$UIDN/gdtk-control.token"
[ -f "$TOKEN_FILE" ] || TOKEN_FILE=""

export F0_LABEL="$LABEL" F0_SECS="$SECS" F0_SID="$SID" F0_TYPE="$TYPE" F0_TS="$TS" \
	F0_SCOPE="$SCOPE" F0_SHELL_PID="$SHELL_PID" F0_TOKEN_FILE="$TOKEN_FILE" F0_UID="$UIDN"

exec python3 - <<'PY'
import os, sys, time, json, socket, datetime, glob

env = os.environ
secs = int(env["F0_SECS"])
label = env["F0_LABEL"]
scope = env["F0_SCOPE"]
shell_pid = env["F0_SHELL_PID"].strip()
token_file = env["F0_TOKEN_FILE"].strip()
hz = os.sysconf("SC_CLK_TCK")
ncpu = os.cpu_count()
host = socket.gethostname()
kernel = os.uname().release


def read(p, cast=str):
    try:
        with open(p) as f:
            return cast(f.read().strip())
    except Exception:
        return None


def comma(p):
    try:
        with open(p) as f:
            return f.read().strip()
    except Exception:
        return ""


shell_name = read("/proc/%s/comm" % shell_pid) if shell_pid else None
is_gdtk = bool(shell_pid) and shell_name == "godot-gdtk"
desktop = "gdtk" if is_gdtk else ("GNOME" if shell_name == "gnome-shell" else "?")


def cpu_snapshot():
    """(busy_ticks, total_ticks, ctxt) de /proc/stat."""
    busy = total = ctxt = 0
    for line in comma("/proc/stat").splitlines():
        if line.startswith("cpu "):
            v = [int(x) for x in line.split()[1:]]
            idle = v[3] + (v[4] if len(v) > 4 else 0)  # idle + iowait
            s = sum(v)
            busy += s - idle
            total += s
        elif line.startswith("ctxt "):
            ctxt = int(line.split()[1])
    return busy, total, ctxt


def proc_cpu_ticks(pid):
    s = read("/proc/%s/stat" % pid)
    if not s:
        return None
    try:
        r = s[s.rfind(")") + 2:].split()
        return int(r[11]) + int(r[12])
    except Exception:
        return None


def scope_procs():
    try:
        with open(os.path.join(scope, "cgroup.procs")) as f:
            return [int(x) for x in f.read().split()]
    except Exception:
        return []


def scope_ctxsw():
    tot = 0
    for p in scope_procs():
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


def gpu_freq(pat):
    for c in sorted(glob.glob(pat)):
        v = read(c, int)
        if v is not None:
            return v
    return None


UID_ = env["F0_UID"]
USER_SLICE = "/sys/fs/cgroup/user.slice/user-%s.slice" % UID_
USER_SERVICE = USER_SLICE + "/user@%s.service" % UID_
# gdtk: shell+apps viven en session-<sid>.scope; GNOME: shell en session.slice y apps
# en app.slice. Excluye background.slice y scopes sueltos (agentes/SSH), que ensucian.
DESK_ROOTS = [scope, USER_SERVICE + "/session.slice", USER_SERVICE + "/app.slice"]


def usage_usec_rec(root):
    tot = 0
    if not os.path.isdir(root):
        return 0
    for dp, _dirs, _files in os.walk(root):
        st = read(os.path.join(dp, "cpu.stat"))
        if not st:
            continue
        for line in st.splitlines():
            if line.startswith("usage_usec"):
                try:
                    tot += int(line.split()[1])
                except Exception:
                    pass
    return tot


def desk_usage():
    return sum(usage_usec_rec(r) for r in DESK_ROOTS)


def mem_available_kb():
    for line in comma("/proc/meminfo").splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1])
    return None


def rpc(method, params):
    if not token_file:
        return None
    try:
        tok = open(token_file).read().strip()
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
    """Último [FRT_PERF]/[FRT_GPU] de shell.log (sólo si el shell es gdtk con FRT_PERF=1)."""
    out = {}
    if not is_gdtk:
        return out
    log = os.path.expanduser("~/.local/state/gdtk/shell.log")
    try:
        data = open(log, errors="replace").read().splitlines()
    except Exception:
        return out
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
        if "perf" in out and "gpu_ms" in out:
            break
    return out


t0 = time.time()
b0, tot0, ctxt0 = cpu_snapshot()
d0 = desk_usage()
sh0 = proc_cpu_ticks(shell_pid)
sc0 = scope_ctxsw()
st0 = rpc("state", {}) if is_gdtk else None
freqs, acts = [], []
while time.time() - t0 < secs:
    g = gpu_freq("/sys/class/drm/card*/gt_cur_freq_mhz")
    if g:
        freqs.append(g)
    a = gpu_freq("/sys/class/drm/card*/gt_act_freq_mhz")
    if a:
        acts.append(a)
    time.sleep(1.0)
t1 = time.time()
b1, tot1, ctxt1 = cpu_snapshot()
d1 = desk_usage()
sh1 = proc_cpu_ticks(shell_pid)
sc1 = scope_ctxsw()
st1 = rpc("state", {}) if is_gdtk else None
dt = t1 - t0


def r2(v):
    return round(v, 2) if v is not None else None


def per_s(a, b):
    return round((b - a) / dt, 2) if (a is not None and b is not None and dt > 0) else None


res = {
    "host": host, "kernel": kernel, "label": label, "desktop": desktop,
    "shell": shell_name, "session": env["F0_SID"], "type": env["F0_TYPE"], "ncpu": ncpu,
    "seconds": r2(dt),
    "machine_busy_cores": r2(((b1 - b0) / hz) / dt) if dt > 0 else None,
    "machine_busy_pct_of_all": r2(100.0 * (b1 - b0) / (tot1 - tot0)) if (tot1 - tot0) > 0 else None,
    "desktop_busy_cores": r2(((d1 - d0) / 1e6) / dt) if dt > 0 else None,
    "shell_cpu_pct_core": r2((sh1 - sh0) / dt / hz * 100) if (sh0 is not None and sh1 is not None and dt > 0) else None,
    "global_ctxsw_per_s": per_s(ctxt0, ctxt1),
    "session_ctxsw_per_s": per_s(sc0, sc1),
    "session_nprocs": len(scope_procs()),
    "gpu_freq_cur_avg_mhz": round(sum(freqs) / len(freqs), 1) if freqs else None,
    "gpu_freq_act_max_mhz": max(acts) if acts else None,
    "mem_available_kb": mem_available_kb(),
}
if is_gdtk and st1:
    c0 = (st0 or {}).get("compositor", {})
    c1 = st1.get("compositor", {})
    p0 = (st0 or {}).get("present", {})
    p1 = st1.get("present", {})
    res["gdtk"] = {
        "dmabuf_commits_per_s": per_s(c0.get("dmabuf_commits", 0), c1.get("dmabuf_commits", 0)),
        "shm_commits_per_s": per_s(c0.get("shm_commits", 0), c1.get("shm_commits", 0)),
        "present_light_per_s": per_s(p0.get("light", 0), p1.get("light", 0)),
        "present_full_per_s": per_s(p0.get("full", 0), p1.get("full", 0)),
        "scanout": c1.get("scanout"), "scanout_suspended": c1.get("scanout_suspended"),
        "view": st1.get("view"),
        "windows": [w.get("title") for w in st1.get("windows", [])],
    }
    frt = last_frt()
    if frt:
        res["frt"] = frt
try:
    res["session_age_s"] = int(time.time() - datetime.datetime.strptime(env["F0_TS"], "%Y-%m-%d %H:%M:%S %Z").timestamp())
except Exception:
    pass

outdir = os.path.expanduser("~/gdtk-bench")
os.makedirs(outdir, exist_ok=True)
stamp = time.strftime("%Y%m%d-%H%M%S")
path = os.path.join(outdir, "f0-%s-%s.json" % (label.replace(" ", "_"), stamp))
json.dump(res, open(path, "w"), indent=1)

print("host=%s desktop=%s shell=%s label=%s (%.0fs, %d cpus)" % (
    host, desktop, shell_name, label, dt, ncpu))
print("  desktop %.2f cores | machine %.2f cores busy (%.1f%%) | shell %s %.2f%% core | ctxsw %s/s" % (
    res["desktop_busy_cores"] or 0, res["machine_busy_cores"] or 0, res["machine_busy_pct_of_all"] or 0,
    shell_name, res["shell_cpu_pct_core"] or 0, res["global_ctxsw_per_s"]))
if res.get("gdtk"):
    g = res["gdtk"]
    print("  gdtk: dmabuf %s/s shm %s/s | present light %s/s full %s/s | scanout=%s susp=%s | %s" % (
        g["dmabuf_commits_per_s"], g["shm_commits_per_s"], g["present_light_per_s"],
        g["present_full_per_s"], g["scanout"], g["scanout_suspended"], g["view"]))
if res.get("frt"):
    print("  frt: %s" % res["frt"])
print("  gpu_freq cur_avg=%s act_max=%s MHz | MemAvailable=%s MB" % (
    res["gpu_freq_cur_avg_mhz"], res["gpu_freq_act_max_mhz"], (res["mem_available_kb"] or 0) // 1024))
print(path)
PY
