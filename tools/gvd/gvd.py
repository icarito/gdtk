#!/usr/bin/env python3
"""gvd - GNOME Virtual Display: send a virtual monitor over H.264/RTP, recv on tengu.

Un solo archivo, Python 3 + PyGObject/Gio + gst-launch-1.0 (sin pip/root).

    gvd.py send --host IP [--port 5600] [--size 1280x800] [--fps 30]
                [--bitrate 8000] [--position right|left|above|below]
                [--encoder auto|va|x264] [--local] [--stats]
    gvd.py recv [--port 5600] [--transport udp|tcp]
                [--sink auto|ffplay|gl|xv|wayland] [--stats]

Reutiliza la receta del spike_virtual.py (SPEC-gvd-0b-results.md).
"""

import argparse
import glob
import json
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

SC_NAME = "org.gnome.Mutter.ScreenCast"
SC_PATH = "/org/gnome/Mutter/ScreenCast"
SC_IFACE = "org.gnome.Mutter.ScreenCast"
SESSION_IFACE = "org.gnome.Mutter.ScreenCast.Session"
STREAM_IFACE = "org.gnome.Mutter.ScreenCast.Stream"

DC_NAME = "org.gnome.Mutter.DisplayConfig"
DC_PATH = "/org/gnome/Mutter/DisplayConfig"
DC_IFACE = "org.gnome.Mutter.DisplayConfig"

METHOD_TEMPORARY = 1

GST = "gst-launch-1.0"
GST_INSPECT = "gst-inspect-1.0"
DEFAULT_PORT = 5600
DEFAULT_SIZE = "1280x800"
DEFAULT_FPS = 30
DEFAULT_BITRATE = 8000
DEFAULT_JITTER_MS = 30

HERE = os.path.dirname(os.path.abspath(__file__))
CURSOR_HELPER = "gvd-cursor"
CURSOR_HELPER_SRC = "gvd-cursor.c"
CURSOR_MAX_HZ = 120.0

# cursor-mode de Mutter ScreenCast
CURSOR_MODE = {"hidden": 0, "embedded": 1, "separate": 2}
SINK_ELEMENTS = {
    "gl": "glimagesink",
    "xv": "xvimagesink",
    "wayland": "waylandsink",
}
SINK_ORDER = {
    "auto": ["gl", "xv", "wayland"],
    "gl": ["gl"],
    "xv": ["xv"],
    "wayland": ["wayland"],
}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def parse_size(s):
    w, _, h = s.lower().partition("x")
    return int(w), int(h)


# --------------------------------------------------------------- encoder choice

def va_dry_run():
    """1 s de videotestsrc -> vapostproc -> vah264enc -> fakesink. True si anda."""
    if not shutil.which(GST):
        return False
    if subprocess.run([GST, "-q", "videotestsrc", "num-buffers=30", "!",
                       "video/x-raw,format=NV12,width=1280,height=800,"
                       "framerate=30/1", "!",
                       "vah264enc", "!", "fakesink", "sync=false"],
                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                      timeout=15).returncode == 0:
        return True
    # fallback: some drivers need vapostproc for the colour conversion
    return subprocess.run([GST, "-q", "videotestsrc", "num-buffers=30", "!",
                           "videoconvert", "!", "vapostproc", "!",
                           "vah264enc", "!", "fakesink", "sync=false"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                          timeout=15).returncode == 0


def choose_encoder(choice):
    if choice == "x264":
        return "x264", False
    if choice == "va":
        if va_dry_run():
            return "va", True
        raise SystemExit("[!] --encoder va pedido pero el dry-run fallo")
    # auto
    if va_dry_run():
        return "va", True
    return "x264", False


# --------------------------------------------------------------- cursor (send)

def ensure_cursor_helper():
    """Compila gvd-cursor.c (si hace falta) y devuelve la ruta del binario."""
    src = os.path.join(HERE, CURSOR_HELPER_SRC)
    out = os.path.join(HERE, CURSOR_HELPER)
    if not os.path.exists(src):
        log(f"[!] falta {src}")
        return None
    if os.path.exists(out) and os.path.getmtime(out) >= os.path.getmtime(src):
        return out
    if not shutil.which("gcc"):
        log("[!] falta gcc para compilar el lector de cursor")
        return None
    try:
        cflags = subprocess.check_output(
            ["pkg-config", "--cflags", "libpipewire-0.3"], text=True).split()
        libs = subprocess.check_output(
            ["pkg-config", "--libs", "libpipewire-0.3"], text=True).split()
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        log(f"[!] pkg-config libpipewire-0.3: {e}")
        return None
    cmd = ["gcc", "-O2", "-o", out, src] + cflags + libs
    log("[*] compilando lector de cursor: " + " ".join(cmd))
    if subprocess.run(cmd).returncode != 0:
        log("[!] compilacion de gvd-cursor fallo")
        return None
    return out


class CursorSender:
    """Lee x/y de gvd-cursor (stdout: 'x y id') y manda UDP al puerto+1."""

    def __init__(self, helper, node_id, width, height, host, port):
        self.host = host
        self.port = port + 1
        self.seq = 0
        self.stopping = False
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        log(f"[*] cursor: {helper} {node_id} {width} {height} -> "
            f"{host}:{self.port}")
        self.proc = subprocess.Popen(
            [helper, str(node_id), str(width), str(height)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            bufsize=1)
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        min_dt = 1.0 / CURSOR_MAX_HZ
        last = 0.0
        try:
            for line in self.proc.stdout:
                if self.stopping:
                    break
                parts = line.split()
                if len(parts) < 2:
                    continue
                try:
                    x = max(0, min(65535, int(parts[0])))
                    y = max(0, min(65535, int(parts[1])))
                except ValueError:
                    continue
                now = time.monotonic()
                if now - last < min_dt:
                    continue
                last = now
                self.seq = (self.seq + 1) & 0xFFFFFFFF
                try:
                    self.sock.sendto(struct.pack("!HHI", x, y, self.seq),
                                     (self.host, self.port))
                except OSError:
                    pass
        except (ValueError, OSError):
            pass

    def stop(self):
        self.stopping = True
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        try:
            self.sock.close()
        except OSError:
            pass


# ---------------------------------------------------------------------- send

class Sender:
    def __init__(self, args):
        if args.refresh is None:
            args.refresh = float(args.fps)
        self.a = args
        self.conn = None
        self.session_path = None
        self.stream_path = None
        self.node_id = None
        self.proc = None
        self.cursor = None
        self.stopping = False

    # -- D-Bus helpers
    def _call(self, service, path, iface, method, params=None, timeout=10000):
        return self.conn.call_sync(service, path, iface, method, params, None,
                                   Gio.DBusCallFlags.NONE, timeout, None)

    def create_session(self):
        res = self._call(SC_NAME, SC_PATH, SC_IFACE, "CreateSession",
                         GLib.Variant("(a{sv})", ({},)))
        self.session_path = res.unpack()[0]
        log(f"[+] session: {self.session_path}")

    def record_virtual(self):
        a = self.a
        cmode = CURSOR_MODE[a.cursor_mode]
        mode = {
            "size": GLib.Variant("(uu)", (a.width, a.height)),
            "refresh-rate": GLib.Variant("d", float(a.refresh)),
            "is-preferred": GLib.Variant("b", True),
        }
        options = {
            "cursor-mode": GLib.Variant("u", cmode),
            "modes": GLib.Variant("aa{sv}", [mode]),
        }
        log(f"[*] RecordVirtual cursor-mode={cmode} ({a.cursor_mode}) "
            f"size={a.width}x{a.height}@{a.refresh}")
        res = self._call(SC_NAME, self.session_path, SESSION_IFACE,
                         "RecordVirtual", GLib.Variant("(a{sv})", (options,)))
        self.stream_path = res.unpack()[0]
        log(f"[+] stream:  {self.stream_path}")

    def subscribe_stream(self):
        def on_added(_conn, _sender, _path, _iface, _sig, params, _data):
            self.node_id = params.unpack()[0]
            log(f"[+] PipeWireStreamAdded -> node id = {self.node_id}")
        self.conn.signal_subscribe(SC_NAME, STREAM_IFACE, "PipeWireStreamAdded",
                                   self.stream_path, None,
                                   Gio.DBusSignalFlags.NONE, on_added, None)

    def start_session(self):
        self._call(SC_NAME, self.session_path, SESSION_IFACE, "Start", None)
        deadline = time.monotonic() + 8.0
        ctx = GLib.MainContext.default()
        while self.node_id is None and time.monotonic() < deadline:
            while ctx.pending():
                ctx.iteration(False)
            time.sleep(0.02)

    def stop_session(self):
        if not self.session_path:
            return
        try:
            self._call(SC_NAME, self.session_path, SESSION_IFACE, "Stop", None,
                       timeout=5000)
            log("[+] Session.Stop OK")
        except GLib.Error as e:
            log(f"[!] Session.Stop: {e.message}")

    # -- DisplayConfig (receta SPEC-gvd-0b-results.md #3)
    def get_state(self):
        res = self._call(DC_NAME, DC_PATH, DC_IFACE, "GetCurrentState", None)
        return res.unpack()

    @staticmethod
    def current_mode_id(monitor):
        _spec, modes, _props = monitor
        for m in modes:
            if m[6].get("is-current", False):
                return m[0]
        return modes[0][0] if modes else None

    def find_virtual(self, monitors):
        for (spec, _modes, _props) in monitors:
            if spec[0].startswith("Meta-"):
                return spec[0]
        return None

    def phys_size(self, monitors, mons):
        total_w = total_h = 0
        for m in mons:
            connector = m[0]
            for mon in monitors:
                if mon[0][0] == connector:
                    mode_id = self.current_mode_id(mon)
                    for mm in mon[1]:
                        if mm[0] == mode_id:
                            total_w += mm[1]
                            total_h = max(total_h, mm[2])
        return total_w, total_h

    def move_virtual(self, direction):
        if direction == "right":
            log("[*] posicion right: disposicion por defecto de mutter, "
                "no se toca el layout")
            return
        try:
            serial, monitors, logical, _props = self.get_state()
        except GLib.Error as e:
            log(f"[!] GetCurrentState: {e.message}")
            return
        vconn = self.find_virtual(monitors)
        if not vconn:
            log("[!] no encontre monitor virtual (Meta-*), no muevo")
            return
        monitor_cfgs = {}
        for mon in monitors:
            connector = mon[0][0]
            monitor_cfgs[connector] = (connector, self.current_mode_id(mon), {})
        geoms = []
        virt_w = virt_h = 0
        virt_scale = 1.0
        for lm in logical:
            x, y, scale, transform, primary, mons, _p = lm
            conns = [m[0] for m in mons]
            pw, ph = self.phys_size(monitors, mons)
            lw = int(round(pw / scale))
            lh = int(round(ph / scale))
            if vconn in conns:
                virt_w, virt_h, virt_scale = lw, lh, scale
                continue
            geoms.append((x, y, lw, lh, scale, transform, primary,
                          [monitor_cfgs[c] for c in conns if c in monitor_cfgs]))
        if not geoms:
            log("[!] no hay monitores reales para anclar")
            return
        min_x = min(g[0] for g in geoms)
        min_y = min(g[1] for g in geoms)
        max_x = max(g[0] + g[2] for g in geoms)
        max_y = max(g[1] + g[3] for g in geoms)
        if direction == "left":
            vx, vy = min_x - virt_w, min_y
        elif direction == "below":
            vx, vy = min_x, max_y
        elif direction == "above":
            vx, vy = min_x, min_y - virt_h
        else:
            vx, vy = max_x, min_y
        entries = [(g[0], g[1], g[4], g[5], g[6], g[7]) for g in geoms]
        entries.append((vx, vy, virt_scale, 0, False, [monitor_cfgs[vconn]]))
        xs = [e[0] for e in entries]
        ys = [e[1] for e in entries]
        dx, dy = -min(xs), -min(ys)
        new_logical = [(e[0] + dx, e[1] + dy, e[2], e[3], e[4], e[5])
                       for e in entries]
        log(f"[*] ApplyMonitorsConfig method={METHOD_TEMPORARY} "
            f"{vconn} -> ({vx + dx},{vy + dy}) direction={direction}")
        try:
            args = GLib.Variant("(uua(iiduba(ssa{sv}))a{sv})",
                                (serial, METHOD_TEMPORARY, new_logical, {}))
            self._call(DC_NAME, DC_PATH, DC_IFACE, "ApplyMonitorsConfig", args)
            log("[+] ApplyMonitorsConfig OK")
        except GLib.Error as e:
            log(f"[!] ApplyMonitorsConfig: {e.message}")

    # -- gst
    def build_pipeline(self):
        a = self.a
        enc, use_va = choose_encoder(a.encoder)
        log(f"[+] encoder elegido: {enc}")
        fps = a.fps
        # Without videorate, the virtual monitor's refresh controls actual FPS.
        key_interval = max(1, round(a.refresh if a.refresh is not None else fps))
        va_usage = 4 if a.quality == "balanced" else 7
        x264_preset = "veryfast" if a.quality == "balanced" else "ultrafast"
        raw_caps = f"video/x-raw,framerate={fps}/1,interlace-mode=progressive"
        if enc != "va":
            raw_caps += ",format=I420"
        e = [GST, "-q", "pipewiresrc", f"path={self.node_id}",
             "do-timestamp=true", "provide-clock=false", "keepalive-time=200", "!",
             "videoconvert", "!"]
        # videorate may stop a quiet virtual monitor after PipeWire keepalive frames.
        # Keep it as an opt-in limiter for experiments instead of the default path.
        if os.environ.get("GVD_VIDEORATE") == "1":
            e += ["videorate", "drop-only=false", "!",
                  raw_caps, "!"]
        elif enc != "va":
            e += ["video/x-raw,interlace-mode=progressive,format=I420", "!"]
        if enc == "va":
            e += ["vapostproc", "!"]
            e += ["vah264enc", f"bitrate={a.bitrate}", "rate-control=cbr",
                  f"key-int-max={key_interval}", f"target-usage={va_usage}",
                  "b-frames=0", "!",
                  "video/x-h264,profile=constrained-baseline", "!"]
        else:
            e += ["x264enc", "tune=zerolatency", f"speed-preset={x264_preset}",
                  f"bitrate={a.bitrate}", f"key-int-max={key_interval}",
                  "bframes=0", "intra-refresh=false", "!",
                  "video/x-h264,profile=baseline", "!"]
        e += ["h264parse", "config-interval=-1", "!"]
        if a.transport == "tcp" and not a.local:
            e += ["video/x-h264,stream-format=byte-stream,alignment=au", "!"]
        e += ["identity", "name=gvd_stamp", "!"]
        if a.local:
            # ida y vuelta local: decode del H.264 generado
            e += ["avdec_h264", "!", "videoconvert", "!"]
            if a.stats:
                e += ["fpsdisplaysink", "text-overlay=false",
                      "video-sink=autovideosink", "sync=false"]
            else:
                e += ["autovideosink", "sync=false"]
        elif a.transport == "tcp":
            e += ["tcpclientsink", f"host={a.host}", f"port={a.port}", "sync=false"]
        else:
            e += ["rtph264pay", "config-interval=-1", "pt=96", "mtu=1200", "!",
                  "udpsink", f"host={a.host}", f"port={a.port}"]
        if not a.local and a.stats:
            log("[!] --stats no aplica al send por red (solo --local)")
        return e

    def run(self):
        self.conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.create_session()
        self.record_virtual()
        self.subscribe_stream()
        self.start_session()
        if self.node_id is None:
            log("[!] sin node id: abortando")
            self.stop_session()
            return 2
        time.sleep(1.5)
        self.move_virtual(self.a.position)

        cmd = self.build_pipeline()
        log("[*] send: " + " ".join(cmd))
        env = None
        if self.a.stats:
            env = dict(os.environ)
            env["GST_DEBUG"] = "fpsdisplaysink:5"
        # Mutter/PipeWire can publish many changed frames with the same PTS.
        # Stamp encoded buffers before RTP so frames get increasing timestamps.
        child_cmd = [sys.executable, os.path.abspath(__file__), "__gst_child__", *cmd[2:]]
        self.proc = subprocess.Popen(child_cmd, env=env)
        if self.a.cursor_mode == "separate" and not self.a.local:
            self.start_cursor()
        try:
            while self.proc.poll() is None:
                if self.stopping:
                    break
                time.sleep(0.2)
        finally:
            if self.cursor is not None:
                log("[*] deteniendo lector de cursor")
                self.cursor.stop()
                self.cursor = None
            if self.proc.poll() is None:
                log("[*] terminando pipeline")
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
        self.stop_session()
        return 0

    def start_cursor(self):
        helper = ensure_cursor_helper()
        if not helper:
            log("[!] sin lector de cursor; sigo sin cursor separado")
            return
        try:
            self.cursor = CursorSender(helper, self.node_id, self.a.width,
                                       self.a.height, self.a.host, self.a.port)
        except OSError as e:
            log(f"[!] no pude lanzar el lector de cursor: {e}")
            self.cursor = None

    def request_stop(self):
        self.stopping = True
        if self.cursor is not None:
            self.cursor.stop()
            self.cursor = None
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()


# ---------------------------------------------------------------------- recv

def gst_has_element(name):
    try:
        return subprocess.run([GST_INSPECT, name],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL).returncode == 0
    except Exception:
        return False


def choose_sinks(choice, transport="udp"):
    if choice == "ffplay":
        return ["ffplay"] if transport == "tcp" and shutil.which("ffplay") else []
    sinks = [SINK_ELEMENTS[s] for s in SINK_ORDER[choice]
             if gst_has_element(SINK_ELEMENTS[s])]
    if choice == "auto" and transport == "tcp" and shutil.which("ffplay"):
        sinks.insert(0, "ffplay")
    return sinks


def ffplay_command(args):
    return ["ffplay", "-hide_banner", "-loglevel", "warning",
            "-fflags", "nobuffer", "-flags", "low_delay", "-framedrop",
            "-f", "h264", "-i", f"tcp://0.0.0.0:{args.port}?listen=1",
            "-fs", "-an"]


def recv_pipeline(args, sink, stats):
    inner = [sink, "sync=false"]
    if sink == "waylandsink":
        inner += ["fullscreen=true"]
    else:
        inner += ["force-aspect-ratio=true"]
    rtp_caps = 'application/x-rtp,media=video,encoding-name=H264,payload=96,clock-rate=90000'
    if args.transport == "tcp":
        e = [GST, "-q", "tcpserversrc", "host=0.0.0.0",
             f"port={args.port}", "do-timestamp=true", "!",
             "h264parse", "!", "avdec_h264", "!", "videoconvert", "!"]
    else:
        e = [GST, "-q", "udpsrc", f"port={args.port}", "buffer-size=4194304",
             f"caps={rtp_caps}", "!",
             "rtpjitterbuffer", f"latency={args.jitter_ms}",
             "drop-on-latency=true", "do-lost=true", "!",
             # No RTCP feedback channel: recovery relies on periodic sender IDRs.
             "rtph264depay", "wait-for-keyframe=true", "!",
             "video/x-h264,alignment=au", "!", "h264parse", "!",
             "avdec_h264", "!", "videoconvert", "!"]
    if stats:
        e += ["fpsdisplaysink", "text-overlay=false", "sync=false",
              f"video-sink={' '.join(inner)}"]
    else:
        e += inner
    return e


def _find_sway_socket():
    path = os.environ.get("SWAYSOCK")
    if path and os.path.exists(path):
        return path
    uid = os.getuid()
    for pat in (f"/run/user/{uid}/sway-ipc.*.sock",
                "/run/user/*/sway-ipc.*.sock"):
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[0]
    return None


class SwayCursor:
    """Escucha datagramas UDP (x,y,seq) y mueve el cursor nativo de sway.

    Una sola conexion persistente al socket i3-ipc de sway; coalesce: si
    llegan varios datagramas, aplica solo el ultimo por iteracion.
    """

    I3_MAGIC = b"i3-ipc"
    I3_RUN_COMMAND = 0
    I3_GET_OUTPUTS = 3

    def __init__(self, port, video_w, video_h, sock_path):
        self.port = port + 1
        self.video_w = video_w
        self.video_h = video_h
        self.sock_path = sock_path
        self.sock = None
        self.lock = threading.Lock()
        self.latest = None
        self.last_seq = 0
        self.stopping = False
        self.output = None
        self.output_ts = 0.0
        self.warned = False

    # -- i3-ipc
    def _ipc(self, msg_type, payload=b""):
        with self.lock:
            self.sock.sendall(self.I3_MAGIC +
                              struct.pack("<II", len(payload), msg_type) +
                              payload)
            hdr = self._recv_exact(14)
            if len(hdr) < 14 or hdr[:6] != self.I3_MAGIC:
                raise OSError("respuesta i3-ipc invalida")
            length, _typ = struct.unpack("<II", hdr[6:14])
            body = self._recv_exact(length)
            return body

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise OSError("sway ipc cerro la conexion")
            buf += chunk
        return buf

    def _refresh_output(self):
        try:
            body = self._ipc(self.I3_GET_OUTPUTS)
            data = json.loads(body.decode("utf-8", "replace"))
        except (OSError, ValueError):
            return
        outs = data if isinstance(data, list) else data.get("outputs", [])
        if not isinstance(outs, list):
            return
        focused = [o for o in outs if o.get("focused") and o.get("active")]
        active = [o for o in outs if o.get("active")]
        pick = focused[0] if focused else (active[0] if active else None)
        if pick:
            self.output = pick
            self.output_ts = time.monotonic()

    def _map(self, x, y):
        out = self.output
        if not out:
            return x, y
        rect = out.get("rect", {})
        ow = rect.get("width") or self.video_w
        oh = rect.get("height") or self.video_h
        ox = rect.get("x", 0)
        oy = rect.get("y", 0)
        sx = ow / self.video_w if self.video_w else 1.0
        sy = oh / self.video_h if self.video_h else 1.0
        return (int(round(ox + x * sx)), int(round(oy + y * sy)))

    # -- threads
    def _recv_loop(self):
        while not self.stopping:
            try:
                data, _addr = self.udp.recvfrom(64)
            except socket.timeout:
                continue
            except OSError:
                break
            if len(data) < 8:
                continue
            x, y, seq = struct.unpack("!HHI", data[:8])
            if seq > self.last_seq or self.last_seq - seq > 0x7FFFFFFF:
                self.last_seq = seq
                self.latest = (x, y)

    def _apply_loop(self):
        while not self.stopping:
            now = time.monotonic()
            if now - self.output_ts > 2.0:
                self._refresh_output()
            pos = self.latest
            if pos is not None:
                self.latest = None
                x, y = self._map(pos[0], pos[1])
                try:
                    self._ipc(self.I3_RUN_COMMAND,
                              f"seat * cursor set {x} {y}".encode())
                except OSError as e:
                    if not self.warned:
                        log(f"[!] sway cursor: {e}; sigo sin cursor")
                        self.warned = True
                    return
            time.sleep(1.0 / CURSOR_MAX_HZ)

    def start(self):
        try:
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.connect(self.sock_path)
        except OSError as e:
            log(f"[!] no pude conectar a sway ({self.sock_path}): {e}")
            return False
        self._refresh_output()
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.udp.bind(("0.0.0.0", self.port))
        except OSError as e:
            log(f"[!] no pude escuchar UDP {self.port}: {e}")
            self.sock.close()
            return False
        self.udp.settimeout(0.3)
        log(f"[+] cursor sway activo: {self.sock_path} udp={self.port} "
            f"video={self.video_w}x{self.video_h} "
            f"out={self.output.get('name') if self.output else '?'}")
        threading.Thread(target=self._recv_loop, daemon=True).start()
        threading.Thread(target=self._apply_loop, daemon=True).start()
        return True

    def stop(self):
        self.stopping = True
        for s in (getattr(self, "udp", None), self.sock):
            try:
                if s is not None:
                    s.close()
            except OSError:
                pass


def run_recv(args):
    if args.sink == "ffplay" and args.transport != "tcp":
        log("[!] --sink ffplay requiere --transport tcp")
        return 2
    sinks = choose_sinks(args.sink, args.transport)
    if not sinks:
        log(f"[!] sink {args.sink} no disponible; usando fakesink")
        sinks = ["fakesink"]
    cursor = None
    if args.cursor == "sway":
        sock_path = _find_sway_socket()
        if not sock_path:
            log("[!] SWAYSOCK no encontrado; sigo sin cursor de sway")
        else:
            cursor = SwayCursor(args.port, args.video_w, args.video_h,
                                sock_path)
            if not cursor.start():
                cursor = None
    env = dict(os.environ)
    if args.stats:
        env["GST_DEBUG"] = "fpsdisplaysink:5"
    try:
        for i, sink in enumerate(sinks):
            cmd = ffplay_command(args) if sink == "ffplay" else recv_pipeline(args, sink, args.stats)
            log(f"[*] recv sink={sink}: " + " ".join(cmd))
            proc = subprocess.Popen(cmd, env=env)
            t0 = time.monotonic()
            try:
                while proc.poll() is None:
                    if args.max_seconds and \
                            time.monotonic() - t0 > args.max_seconds:
                        break
                    time.sleep(0.2)
            except KeyboardInterrupt:
                pass
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                return 0
            log(f"[!] {sink} termino rc={proc.returncode}, probando siguiente")
    finally:
        if cursor is not None:
            cursor.stop()
    log("[!] ningun sink funciono")
    return 2


# ---------------------------------------------------------------------- caps

def build_caps():
    sway_socket = _find_sway_socket()
    return {
        "schema": "gvd.caps.v1",
        "commands": ["send", "recv", "caps"],
        "defaults": {
            "port": DEFAULT_PORT,
            "cursor_port": DEFAULT_PORT + 1,
            "size": DEFAULT_SIZE,
            "fps": DEFAULT_FPS,
            "bitrate_kbps": DEFAULT_BITRATE,
            "quality": "balanced",
            "jitter_ms": DEFAULT_JITTER_MS,
            "transport": "udp",
            "sink": "auto",
            "cursor_mode": "separate",
        },
        "wire": {
            "video": "H.264 RTP/UDP or Annex B/TCP; UDP payload=96 clock-rate=90000",
            "cursor": "UDP port+1, x:u16 y:u16 seq:u32 big-endian",
            "security": "none; use only trusted LAN or a VPN/WireGuard",
        },
        "deps": {
            "gst_launch": bool(shutil.which(GST)),
            "gst_inspect": bool(shutil.which(GST_INSPECT)),
            "gcc": bool(shutil.which("gcc")),
            "pkg_config": bool(shutil.which("pkg-config")),
            "gvd_cursor_c": os.path.exists(os.path.join(HERE, CURSOR_HELPER_SRC)),
            "gvd_cursor_bin": os.path.exists(os.path.join(HERE, CURSOR_HELPER)),
        },
        "send": {
            "platform": "GNOME Wayland/Mutter ScreenCast",
            "encoders": {
                "x264": gst_has_element("x264enc"),
                "va": gst_has_element("vah264enc") and
                      gst_has_element("vapostproc"),
            },
            "positions": ["right", "left", "above", "below"],
            "cursor_modes": ["separate", "embedded"],
        },
        "recv": {
            "sinks": {**{name: gst_has_element(element)
                         for name, element in SINK_ELEMENTS.items()},
                      "ffplay": bool(shutil.which("ffplay"))},
            "cursor": {
                "sway": bool(sway_socket),
                "sway_socket": sway_socket,
            },
        },
    }


def run_caps(args):
    caps = build_caps()
    if args.json:
        print(json.dumps(caps, indent=2, sort_keys=True))
        return 0
    print("gvd caps:")
    print(f"  video: UDP RTP or TCP Annex B {caps['defaults']['port']} H.264")
    print(f"  cursor: UDP {caps['defaults']['cursor_port']} (separate)")
    print("  recv sinks: " + ", ".join(
        f"{k}={'yes' if v else 'no'}"
        for k, v in caps["recv"]["sinks"].items()))
    print("  send encoders: " + ", ".join(
        f"{k}={'yes' if v else 'no'}"
        for k, v in caps["send"]["encoders"].items()))
    return 0


# --------------------------------------------------------------------- main

def attach_retimestamp(pipeline):
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst

    stamp = pipeline.get_by_name("gvd_stamp")
    if stamp is None:
        raise ValueError("falta gvd_stamp en el pipeline")
    last_pts = -1
    base_pts = None
    first_clock_time = None
    frame_count = 0

    def on_frame(_pad, info):
        nonlocal last_pts, base_pts, first_clock_time, frame_count
        clock = pipeline.get_clock()
        if clock is None:
            return Gst.PadProbeReturn.OK
        now = max(0, clock.get_time() - pipeline.get_base_time())
        original_pts = info.get_buffer().pts
        if base_pts is None:
            base_pts = original_pts if original_pts != Gst.CLOCK_TIME_NONE else 0
            first_clock_time = now
            last_pts = base_pts - 1 if base_pts else -1
        last_pts = max(last_pts + 1, base_pts + now - first_clock_time)
        buffer = info.get_buffer().copy_deep()
        buffer.pts = last_pts
        buffer.dts = Gst.CLOCK_TIME_NONE
        buffer.duration = Gst.CLOCK_TIME_NONE
        info.set_buffer(buffer)
        frame_count += 1
        if os.environ.get("GVD_STAMP_DEBUG") == "1" and (frame_count <= 5 or frame_count % 30 == 0):
            log(f"[*] stamp frame={frame_count} old={original_pts} new={last_pts}")
        return Gst.PadProbeReturn.OK

    stamp.get_static_pad("src").add_probe(Gst.PadProbeType.BUFFER, on_frame)


def run_gst_child(elements):
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst

    Gst.init(None)
    try:
        pipeline = Gst.parse_launch(" ".join(elements))
    except GLib.Error as e:
        log(f"[!] GStreamer: {e.message}")
        return 2
    try:
        attach_retimestamp(pipeline)
    except ValueError as e:
        log(f"[!] {e}")
        return 2
    stopped = False

    def on_signal(_sig, _frame):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    pipeline.use_clock(Gst.SystemClock.obtain())
    if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
        log("[!] GStreamer no pudo iniciar el pipeline")
        pipeline.set_state(Gst.State.NULL)
        return 2
    try:
        bus = pipeline.get_bus()
        while not stopped:
            msg = bus.timed_pop_filtered(200 * Gst.MSECOND,
                                         Gst.MessageType.ERROR | Gst.MessageType.EOS)
            if msg is None:
                continue
            if msg.type == Gst.MessageType.ERROR:
                error, detail = msg.parse_error()
                log(f"[!] GStreamer: {error.message}: {detail}")
                return 1
            return 0
    finally:
        pipeline.set_state(Gst.State.NULL)
    return 0


def build_parser():
    ap = argparse.ArgumentParser(prog="gvd.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("send")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=DEFAULT_PORT)
    s.add_argument("--transport", default="udp", choices=["udp", "tcp"],
                   help="UDP/RTP o H.264 directo sobre TCP")
    s.add_argument("--size", default=DEFAULT_SIZE)
    s.add_argument("--fps", type=int, default=DEFAULT_FPS)
    s.add_argument("--bitrate", type=int, default=DEFAULT_BITRATE)
    s.add_argument("--quality", default="balanced", choices=["balanced", "speed"],
                   help="balanced=mejor compresion, speed=menor esfuerzo de encode")
    s.add_argument("--refresh", type=float, default=None,
                   help="Hz del monitor virtual (por defecto, igual a --fps)")
    s.add_argument("--position", default="right",
                   choices=["right", "left", "above", "below"])
    s.add_argument("--encoder", default="auto",
                   choices=["auto", "va", "x264"])
    s.add_argument("--local", action="store_true")
    s.add_argument("--stats", action="store_true",
                   help="imprime fps (solo --local)")
    s.add_argument("--cursor-mode", default="separate",
                   choices=["embedded", "separate"],
                   help="embedded=cursor en el video, separate=UDP aparte")

    r = sub.add_parser("recv")
    r.add_argument("--port", type=int, default=DEFAULT_PORT)
    r.add_argument("--transport", default="udp", choices=["udp", "tcp"],
                   help="debe coincidir con el transporte del emisor")
    r.add_argument("--sink", default="auto",
                   choices=["auto", "ffplay", "gl", "xv", "wayland"])
    r.add_argument("--stats", action="store_true")
    r.add_argument("--jitter-ms", type=int, default=DEFAULT_JITTER_MS,
                   help="margen de reordenamiento RTP en ms (default: 30; 0 para LAN estable)")
    r.add_argument("--max-seconds", type=float, default=0,
                   help="detener tras N segundos (0 = infinito)")
    r.add_argument("--cursor", default="sway", choices=["none", "sway"],
                   help="mover el cursor nativo de sway (auto-off sin SWAYSOCK)")
    r.add_argument("--video-size", default=DEFAULT_SIZE,
                   help="tamano del video para escalar el cursor a la salida")

    c = sub.add_parser("caps")
    c.add_argument("--json", action="store_true",
                   help="imprime capacidades para integradores como gdtk")
    return ap


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "__gst_child__":
        return run_gst_child(sys.argv[2:])
    args = build_parser().parse_args()

    if args.cmd == "caps":
        return run_caps(args)

    if args.cmd == "recv":
        if args.jitter_ms < 0:
            raise SystemExit("[!] --jitter-ms debe ser >= 0")
        try:
            args.video_w, args.video_h = parse_size(args.video_size)
        except ValueError:
            args.video_w, args.video_h = 1280, 800

        def on_recv_signal(_sig, _frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGINT, on_recv_signal)
        signal.signal(signal.SIGTERM, on_recv_signal)
        try:
            return run_recv(args)
        except KeyboardInterrupt:
            return 130

    if args.fps <= 0 or args.bitrate <= 0:
        raise SystemExit("[!] --fps y --bitrate deben ser > 0")
    if args.refresh is None:
        args.refresh = float(args.fps)
    if args.refresh <= 0:
        raise SystemExit("[!] --refresh debe ser > 0")
    args.width, args.height = parse_size(args.size)
    if not shutil.which(GST):
        log("[!] falta gst-launch-1.0")
        return 3
    sender = Sender(args)

    def on_signal(_sig, _frame):
        sender.request_stop()

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    try:
        rc = sender.run()
    except KeyboardInterrupt:
        sender.request_stop()
        sender.stop_session()
        rc = 130
    return rc


if __name__ == "__main__":
    sys.exit(main())
