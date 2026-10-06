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
import select
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
# Buffer RTP por defecto: holgado para Wi-Fi (jitter 2.4G medido hasta cientos de ms).
# Con 30 ms casi todo paquete llegaba tarde y `drop-on-latency` los tiraba (0 frames);
# 120 ms absorbe la ráfaga sin volver la latencia inaceptable. Ajustable con
# `--jitter-ms` (0 = sin reordenamiento, LAN estable).
DEFAULT_JITTER_MS = 120

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
import gvd_util as U  # noqa: E402  (K18: logica pura, sin GI/Mutter)

WINDOW_TITLE = U.WINDOW_TITLE
APP_ID = U.APP_ID
CURSOR_HELPER = "gvd-cursor"
CURSOR_HELPER_SRC = "gvd-cursor.c"
CURSOR_MAX_HZ = 120.0
VIDEO_DSCP = 8  # CS1/scavenger: Deskflow queda por encima cuando la red honra DSCP.
VIDEO_NICE = 5  # El input interactivo conserva prioridad de CPU sin privilegios.

# Captura wlroots (sway/gdtk): helper wlr-screencopy que escribe frames crudos por
# stdout. Sustituye a PipeWire/Mutter cuando el escritorio no es GNOME.
CAPTURE_HELPER = "gvd-capture"
CAPTURE_HELPER_SRC = "gvd-capture.c"
CAPTURE_PROTO_DIR = "protocols"
CAPTURE_PROTO_C = "wlr-screencopy-unstable-v1-protocol.c"
CAPTURE_PROTO_H = "wlr-screencopy-unstable-v1-client-protocol.h"
CAPTURE_FORMATS = {"XR24": "BGRx", "AR24": "BGRA", "AB24": "RGBA"}

# Colorimetría forzada del stream. Sin esto el encoder etiqueta bt601 (default) y
# los sinks que asumen bt709/HD muestran colores desviados. Override con
# GVD_COLORIMETRY (p. ej. bt601) o "" para no forzar.
COLORIMETRY = os.environ.get("GVD_COLORIMETRY", "bt709")
POSITIONS = ("right", "left", "above", "below")

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


def lower_video_priority():
    """Baja sólo esta tarea; nunca intenta elevar Deskflow ni requiere privilegios."""
    try:
        os.nice(VIDEO_NICE)
    except OSError as e:
        log(f"[!] no pude bajar prioridad de video: {e}")


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


def _capture_deps_ok():
    """gcc + wayland-client + el codigo de protocolo vendorizado."""
    if not shutil.which("gcc"):
        return False, "falta gcc"
    proto = os.path.join(HERE, CAPTURE_PROTO_DIR)
    if not os.path.exists(os.path.join(proto, CAPTURE_PROTO_C)):
        return False, "falta el codigo del protocolo wlr-screencopy"
    try:
        subprocess.check_output(["pkg-config", "--exists", "wayland-client"])
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False, "falta wayland-client (dev)"
    return True, ""


def ensure_capture_helper():
    """Compila gvd-capture.c + el protocolo wlr-screencopy si hace falta."""
    src = os.path.join(HERE, CAPTURE_HELPER_SRC)
    out = os.path.join(HERE, CAPTURE_HELPER)
    proto = os.path.join(HERE, CAPTURE_PROTO_DIR)
    proto_c = os.path.join(proto, CAPTURE_PROTO_C)
    if not os.path.exists(src):
        log(f"[!] falta {src}")
        return None
    ok, why = _capture_deps_ok()
    if not ok:
        log(f"[!] captura wlroots no disponible: {why}")
        return None
    newest = max(os.path.getmtime(src), os.path.getmtime(proto_c))
    if os.path.exists(out) and os.path.getmtime(out) >= newest:
        return out
    try:
        cflags = subprocess.check_output(
            ["pkg-config", "--cflags", "wayland-client"], text=True).split()
        libs = subprocess.check_output(
            ["pkg-config", "--libs", "wayland-client"], text=True).split()
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        log(f"[!] pkg-config wayland-client: {e}")
        return None
    cmd = ["gcc", "-O2", "-o", out, src, proto_c, "-I", proto] + cflags + libs
    log("[*] compilando captura wlroots: " + " ".join(cmd))
    if subprocess.run(cmd).returncode != 0:
        log("[!] compilacion de gvd-capture fallo")
        return None
    return out


def wlr_capture_available():
    if not os.environ.get("WAYLAND_DISPLAY"):
        return False
    ok, _ = _capture_deps_ok()
    if not ok:
        return False
    return ensure_capture_helper() is not None


def wlr_capture_ready():
    """Como above pero sin compilar: solo deps + sesion Wayland (para caps)."""
    if not os.environ.get("WAYLAND_DISPLAY"):
        return False
    ok, _ = _capture_deps_ok()
    return ok


def detect_capture_backend(choice="auto"):
    """auto: Mutter si el escritorio es GNOME; si no, wlroots (sway/gdtk)."""
    desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").upper()
    if choice == "mutter":
        return "mutter"
    if choice == "shm":
        return "shm"
    if choice == "wlr":
        return "wlr" if wlr_capture_available() else None
    if "GNOME" in desktop:
        return "mutter"
    return "wlr" if wlr_capture_available() else "mutter"


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
        # Backend de captura: Mutter/PipeWire (GNOME) o wlroots (sway/gdtk).
        self.backend = detect_capture_backend(getattr(args, "capture", "auto"))
        self.capture = None       # proceso gvd-capture (solo wlr)
        self.capture_hdr = None   # (fourcc, width, height, stride)
        self.virtual = None       # SwayVirtualOutput (solo wlr --virtual)
        # K18: si Mutter cambia la disposicion/tamano del monitor virtual o la
        # sesion ScreenCast se corta, se recrea sesion+pipeline sin relanzar.
        self.monitors_changed = False
        self.sub_ids = []
        self.attempt = 0
        self.last_size = (int(args.width), int(args.height))

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
        self.sub_ids.append(self.conn.signal_subscribe(
            SC_NAME, STREAM_IFACE, "PipeWireStreamAdded", self.stream_path,
            None, Gio.DBusSignalFlags.NONE, on_added, None))

    # K18: al cambiar la disposicion/tamano desde "Pantallas" de GNOME hay que
    # releer el tamano del monitor virtual y recrear sesion+pipeline.
    def subscribe_monitors(self):
        def on_changed(_conn, _sender, _path, _iface, _sig, _params, _data):
            if not self.monitors_changed:
                log("[*] MonitorsChanged: recreo la sesion de pantalla")
            self.monitors_changed = True
        self.sub_ids.append(self.conn.signal_subscribe(
            DC_NAME, DC_IFACE, "MonitorsChanged", DC_PATH,
            None, Gio.DBusSignalFlags.NONE, on_changed, None))

    def unsubscribe(self):
        for sid in self.sub_ids:
            try:
                self.conn.signal_unsubscribe(sid)
            except GLib.Error:
                pass
        self.sub_ids = []

    def read_virtual_size(self):
        """Tamano actual del monitor virtual (Meta-*) en GetCurrentState, o None."""
        try:
            _serial, monitors, _logical, _props = self.get_state()
        except GLib.Error as e:
            log(f"[!] GetCurrentState: {e.message}")
            return None
        return U.virtual_monitor_size(monitors)

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
    def build_pipeline(self, source=None):
        a = self.a
        enc, use_va = choose_encoder(a.encoder)
        log(f"[+] encoder elegido: {enc}")
        fps = a.fps
        # Without videorate, the virtual monitor's refresh controls actual FPS.
        key_interval = max(1, round(a.refresh if a.refresh is not None else fps))
        va_usage = 4 if a.quality == "balanced" else 7
        x264_preset = "veryfast" if a.quality == "balanced" else "ultrafast"
        cim = f",colorimetry={COLORIMETRY}" if COLORIMETRY else ""
        raw_caps = f"video/x-raw,framerate={fps}/1,interlace-mode=progressive{cim}"
        if enc != "va":
            raw_caps += ",format=I420"
        if source is None:
            source = ["pipewiresrc", f"path={self.node_id}",
                      "do-timestamp=true", "provide-clock=false",
                      "keepalive-time=200", "!"]
        e = [GST, "-q"] + list(source) + ["videoconvert", "!"]
        # videorate may stop a quiet virtual monitor after PipeWire keepalive frames.
        # Keep it as an opt-in limiter for experiments instead of the default path.
        if os.environ.get("GVD_VIDEORATE") == "1":
            e += ["videorate", "drop-only=false", "!",
                  raw_caps, "!"]
        elif enc != "va":
            e += [f"video/x-raw,interlace-mode=progressive,format=I420{cim}", "!"]
        if enc == "va":
            e += ["vapostproc", "!"]
            if cim:
                # Re-etiquetar DESPUÉS de vapostproc: mantiene la conversión VA y deja
                # la colorimetría correcta en el SPS (vapostproc solo pone un valor raro).
                e += [f"video/x-raw{cim}", "!"]
        if enc == "va":
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
                  "udpsink", f"host={a.host}", f"port={a.port}",
                  f"qos-dscp={VIDEO_DSCP}"]
        if not a.local and a.stats:
            log("[!] --stats no aplica al send por red (solo --local)")
        return e

    def _notify_receiver_size(self, size):
        """Primer paquete UDP de control en el puerto del cursor (K18)."""
        if not size or self.a.local:
            return
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.sendto(U.encode_size_control(size[0], size[1]),
                        (self.a.host, self.a.port + 1))
            sock.close()
            log(f"[*] aviso al receptor: video {size[0]}x{size[1]}")
        except OSError as e:
            log(f"[!] no pude avisar el tamano nuevo: {e}")

    def _sleep_interruptible(self, seconds):
        deadline = time.monotonic() + max(0.0, seconds)
        while not self.stopping and time.monotonic() < deadline:
            time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))

    def _teardown_stream(self):
        if self.cursor is not None:
            log("[*] deteniendo lector de cursor")
            self.cursor.stop()
            self.cursor = None
        if self.proc is not None and self.proc.poll() is None:
            log("[*] terminando pipeline")
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None
        if self.capture is not None:
            try:
                self.capture.stdout.close()
            except (OSError, AttributeError):
                pass
            if self.capture.poll() is None:
                self.capture.terminate()
                try:
                    self.capture.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.capture.kill()
            self.capture = None
        self.capture_hdr = None
        if self.virtual is not None:
            self.virtual.destroy()
            self.virtual = None
        self.stop_session()
        self.node_id = None
        self.session_path = None
        self.stream_path = None

    # -- captura wlroots (sway/gdtk), sin Mutter ni PipeWire
    def _read_capture_header(self, timeout=6.0):
        fd = self.capture.stderr.fileno()
        deadline = time.monotonic() + timeout
        buf = b""
        while time.monotonic() < deadline:
            r, _, _ = select.select([fd], [], [], 0.2)
            if not r:
                if self.capture.poll() is not None:
                    return None
                continue
            chunk = os.read(fd, 4096)
            if not chunk:
                return None
            buf += chunk
            for raw in buf.split(b"\n"):
                line = raw.decode("utf-8", "replace").strip()
                if line.startswith("GVDCAP1"):
                    return line
        return None

    def _drain_capture_stderr(self):
        try:
            for raw in self.capture.stderr:
                msg = raw.decode("utf-8", "replace").strip()
                if msg:
                    log("[capture] " + msg)
        except (OSError, ValueError):
            pass

    def _start_wlr_capture(self):
        if self.backend == "shm":
            return self._start_shm_capture()
        helper = ensure_capture_helper()
        if not helper:
            log("[!] sin captura wlroots")
            return False
        # --virtual: monitor headless de sway -> extension real del escritorio
        # (igual que el Meta-* de Mutter). Sin --virtual se comparte un output real.
        if getattr(self.a, "virtual", False) and self.virtual is None:
            self.virtual = SwayVirtualOutput(self.a.position,
                                             self.a.width, self.a.height)
            if self.virtual.create() is None:
                self.virtual = None
                return False
        output = self.virtual.name if self.virtual else getattr(self.a, "output", "")
        # overlay-cursor=1 mete el puntero del emisor en el frame (gvd-capture lo
        # pide al compositor); por defecto NO se transmite: el receptor usa su
        # propio puntero local (sway/Deskflow). Con --cursor-mode embedded se
        # conserva el comportamiento viejo (puntero dentro del video, sin canal
        # separado).
        overlay = "1" if getattr(self.a, "cursor_mode", "separate") == "embedded" else "0"
        argv = [helper, "--fps", str(self.a.fps), "--overlay-cursor", overlay]
        if output:
            argv += ["--output", output]
        log("[*] captura: " + " ".join(argv))
        env = None
        display = _find_wlr_wayland_display()
        if display and display != os.environ.get("WAYLAND_DISPLAY"):
            env = dict(os.environ)
            env["WAYLAND_DISPLAY"] = display
            log(f"[*] captura wlroots via WAYLAND_DISPLAY={display}")
        self.capture = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env)
        return self._adopt_capture_header("wlroots")

    def _adopt_capture_header(self, what):
        line = self._read_capture_header()
        if line is None:
            log(f"[!] sin cabecera de captura {what}")
            return False
        parts = line.split()
        try:
            fourcc, width, height, stride = parts[1], int(parts[2]), int(parts[3]), int(parts[4])
        except (IndexError, ValueError):
            log("[!] cabecera de captura invalida: " + line)
            return False
        fmt = CAPTURE_FORMATS.get(fourcc, "BGRx")
        self.capture_hdr = (fmt, width, height, stride)
        threading.Thread(target=self._drain_capture_stderr, daemon=True).start()
        log(f"[+] captura {what} {fmt} {width}x{height}")
        return True

    def _start_shm_capture(self):
        # Fuente = archivo de frames que escribe el shell gdtk (una ventana); el
        # lector es este mismo script, con el contrato de gvd-capture.
        argv = [sys.executable, os.path.abspath(__file__), "__shm_capture__",
                self.a.shm, str(self.a.fps)]
        log("[*] captura: " + " ".join(argv))
        self.capture = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE)
        return self._adopt_capture_header("shm")

    def _create_and_stream_wlr(self):
        if not self._start_wlr_capture():
            return False, None
        fmt, width, height, _stride = self.capture_hdr
        source = ["fdsrc", "fd=0", "!", "rawvideoparse", f"format={fmt}",
                  f"width={width}", f"height={height}",
                  f"framerate={self.a.fps}/1", "!"]
        cmd = self.build_pipeline(source=source)
        log("[*] send: " + " ".join(cmd))
        child_cmd = [sys.executable, os.path.abspath(__file__), "__gst_child__", *cmd[2:]]
        # gst lee los frames crudos del stdout del helper.
        self.proc = subprocess.Popen(child_cmd, stdin=self.capture.stdout)
        return True, (width, height)

    def run_wlr(self):
        rc = 0
        first = True
        try:
            while not self.stopping:
                ok, size = self._create_and_stream_wlr()
                if not ok:
                    self._teardown_stream()
                    plan = U.sender_restart_plan(self.attempt + 1, first=first)
                    if not plan["ok"]:
                        rc = 2
                        break
                    self.attempt += 1
                    log(f"[*] reintento wlr en {plan['delay']:.0f}s "
                        f"({self.attempt}/{U.MAX_RESTARTS})")
                    self._sleep_interruptible(plan["delay"])
                    first = False
                    continue
                if first:
                    self._notify_receiver_size(size)
                first = False
                while not self.stopping and self.proc is not None \
                        and self.proc.poll() is None \
                        and self.capture is not None and self.capture.poll() is None:
                    time.sleep(0.2)
                if self.stopping:
                    self._teardown_stream()
                    break
                gst_rc = self.proc.returncode if self.proc else "?"
                cap_rc = self.capture.returncode if self.capture else "?"
                if self.backend == "shm" and cap_rc == SHM_RESIZED:
                    # Ventana redimensionada: pipeline nuevo ya, sin backoff ni contar
                    # intento, y avisando el tamaño nuevo al receptor (first).
                    self._teardown_stream()
                    first = True
                    continue
                log(f"[!] emisor wlr termino (gst rc={gst_rc}, capture rc={cap_rc})")
                self._teardown_stream()
                plan = U.sender_restart_plan(self.attempt + 1, first=False)
                if not plan["ok"]:
                    rc = 2
                    break
                self.attempt += 1
                self._sleep_interruptible(plan["delay"])
        finally:
            self._teardown_stream()
        return rc

    def _create_and_stream(self, apply_position):
        # Al recrear, si el monitor virtual aun existe se adopta su tamano: la
        # nueva captura sigue el layout que la persona acaba de ajustar.
        if not apply_position:
            size = self.read_virtual_size()
            if size:
                self.a.width, self.a.height = size
        self.create_session()
        self.record_virtual()
        self.subscribe_stream()
        self.start_session()
        if self.node_id is None:
            log("[!] sin node id")
            return False, None
        time.sleep(1.5)
        if apply_position:
            self.move_virtual(self.a.position)
        size = self.read_virtual_size() or (self.a.width, self.a.height)
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
        return True, size

    def run(self):
        log(f"[*] backend de captura: {self.backend}")
        if self.backend in ("wlr", "shm"):
            return self.run_wlr()
        self.conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.subscribe_monitors()
        first = True
        rc = 0
        try:
            while not self.stopping:
                self.monitors_changed = False
                if not first:
                    self.attempt += 1
                    plan = U.sender_restart_plan(self.attempt, first=False)
                    if not plan["ok"]:
                        log("[!] demasiados reintentos de screencast; me detengo")
                        rc = 2
                        break
                    log(f"[*] recreando sesion+pipeline en {plan['delay']:.0f}s "
                        f"(intento {self.attempt}/{U.MAX_RESTARTS})")
                    self._sleep_interruptible(plan["delay"])
                    if self.stopping:
                        break
                ok, size = self._create_and_stream(apply_position=first)
                if not ok:
                    self._teardown_stream()
                    first = False
                    continue
                # `--position` solo en la primera creacion: no se pisa el layout
                # que la persona acaba de ajustar. Si el tamano cambio, se avisa.
                if not first and U.size_changed(self.last_size, size):
                    self._notify_receiver_size(size)
                self.last_size = size
                while self.proc is not None and self.proc.poll() is None:
                    if self.stopping or self.monitors_changed:
                        break
                    time.sleep(0.2)
                if self.stopping:
                    self._teardown_stream()
                    break
                if self.monitors_changed:
                    log("[*] releyendo el layout de pantallas de Mutter")
                else:
                    log(f"[!] pipeline del emisor termino "
                        f"rc={self.proc.returncode}")
                self._teardown_stream()
                first = False
        finally:
            self.unsubscribe()
            self._teardown_stream()
        return rc

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
        if self.capture is not None and self.capture.poll() is None:
            self.capture.terminate()


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
    # K18: el receptor es una ventana normal, nunca fullscreen; el shell la
    # coloca en el hueco central. NUNCA se escala: el emisor crea el monitor
    # virtual a la resolución target y el receptor la muestra 1:1. Sin
    # `force-aspect-ratio`: waylandsink pediría wp_viewporter para escalar, el
    # compositor embebido no lo implementa y el proceso aborta (segfault).
    inner = [sink, "sync=false"]
    rtp_caps = 'application/x-rtp,media=video,encoding-name=H264,payload=96,clock-rate=90000'
    if args.transport == "tcp":
        e = [GST, "-q", "tcpserversrc", "host=0.0.0.0",
             f"port={args.port}", "do-timestamp=true", "!",
             "h264parse", "!", "avdec_h264", "!", "videoconvert", "!"]
    else:
        e = [GST, "-q", "udpsrc", f"port={args.port}", "buffer-size=4194304",
             f"caps={rtp_caps}", "!",
             "rtpjitterbuffer", f"latency={args.jitter_ms}",
             "drop-on-latency=true", "do-lost=true", "do-retransmission=false", "!",
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
    patterns = []
    rt = os.environ.get("XDG_RUNTIME_DIR")
    if rt:
        patterns.append(os.path.join(rt, "sway-ipc.*.sock"))
    patterns += [f"/run/user/{uid}/sway-ipc.*.sock",
                 "/run/user/*/sway-ipc.*.sock"]
    for pat in patterns:
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[0]
    return None


def _sway_cmd(sock, *words):
    """Ejecuta un comando de sway y devuelve (ok, salida). Sin shell."""
    try:
        out = subprocess.run(["swaymsg", "-s", sock, *words],
                             capture_output=True, text=True, timeout=6)
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"[!] swaymsg: {e}")
        return False, ""
    return out.returncode == 0, out.stdout


def _sway_outputs(sock):
	ok, out = _sway_cmd(sock, "-t", "get_outputs")
	if not ok:
		return None
	try:
		return json.loads(out)
	except ValueError:
		return None


def _wlr_probe_display(display, timeout=1.5):
	"""Devuelve true si ese WAYLAND_DISPLAY entrega cabecera de gvd-capture."""
	helper = ensure_capture_helper()
	if not helper or not display:
		return False
	env = dict(os.environ)
	env["WAYLAND_DISPLAY"] = display
	proc = None
	try:
		proc = subprocess.Popen([helper, "--fps", "1", "--overlay-cursor", "0",
			"--once"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
		end = time.monotonic() + timeout
		buf = b""
		while time.monotonic() < end:
			if proc.stderr is not None:
				r, _, _ = select.select([proc.stderr.fileno()], [], [], 0.05)
				if r:
					chunk = os.read(proc.stderr.fileno(), 4096)
					if not chunk:
						return b"GVDCAP1" in buf
					buf += chunk
					if b"GVDCAP1" in buf:
						return True
					if b"no expone wlr-screencopy" in buf or b"no pude conectar" in buf:
						return False
			if proc.poll() is not None:
				return b"GVDCAP1" in buf
	except OSError:
		return False
	finally:
		if proc is not None:
			try:
				if proc.poll() is None:
					proc.terminate()
					proc.wait(timeout=0.5)
			except Exception:
				try:
					proc.kill()
				except Exception:
					pass
	return False


def _find_wlr_wayland_display():
	current = os.environ.get("WAYLAND_DISPLAY", "")
	if current and _wlr_probe_display(current):
		return current
	rt = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
	for path in sorted(glob.glob(os.path.join(rt, "wayland-*"))):
		if path.endswith(".lock"):
			continue
		name = os.path.basename(path)
		if name == current:
			continue
		if _wlr_probe_display(name):
			return name
	return current


class SwayVirtualOutput:
    """Monitor virtual en sway (y por tanto en gdtk con sesion sway): crea un
    output headless con `create_output`, lo ubica en la direccion pedida y lo
    desmonta al terminar. Asi el escritorio se EXTIENDE (no se espeja) tambien
    desde gdtk, igual que el monitor Meta-* de Mutter."""

    def __init__(self, direction, width, height):
        self.direction = direction if direction in POSITIONS else "right"
        self.width, self.height = int(width), int(height)
        self.name = None

    def create(self):
        sock = _find_sway_socket()
        if not sock:
            log("[!] --virtual requiere sway (SWAYSOCK); no encontrado")
            return None
        before = _sway_outputs(sock) or []
        names_before = {o.get("name") for o in before}
        ok, _ = _sway_cmd(sock, "create_output")
        if not ok:
            log("[!] sway create_output fallo")
            return None
        after = _sway_outputs(sock) or []
        new = [o for o in after if o.get("name") not in names_before]
        if not new:
            log("[!] sway no reporto el output virtual nuevo")
            return None
        self.name = new[0].get("name")
        _sway_cmd(sock, "output", self.name, "resolution",
                  f"{self.width}x{self.height}")
        _sway_cmd(sock, "output", self.name, "bg", "#000000")
        # Anclar relativo a la pantalla REAL (output enfocado o no-headless), no al
        # bounding box de todos los outputs: con outputs virtuales previos o con el
        # auto-placement de sway, max_x/max_y caia del lado equivocado. Se normaliza
        # el output real a (0,0) y el virtual se pega a su borde pedido.
        ref_name, ref = None, None
        for o in before:
            if str(o.get("name", "")).startswith("HEADLESS"):
                continue
            if o.get("focused"):
                ref_name, ref = o.get("name"), o["rect"]
                break
            if ref is None:
                ref_name, ref = o.get("name"), o["rect"]
        if ref is None:
            ref_name, ref = "eDP-1", {"x": 0, "y": 0,
                                      "width": self.width, "height": self.height}
        _sway_cmd(sock, "output", str(ref_name), "position", "0", "0")
        rw, rh = int(ref["width"]), int(ref["height"])
        pos = {
            "right": (rw, 0),
            "left": (-self.width, 0),
            "above": (0, -self.height),
            "below": (0, rh),
        }[self.direction]
        _sway_cmd(sock, "output", self.name, "position", str(pos[0]), str(pos[1]))
        log(f"[+] monitor virtual sway: {self.name} {self.width}x{self.height} "
            f"{self.direction} @ {pos}")
        return self.name

    def destroy(self):
        if not self.name:
            return
        sock = _find_sway_socket()
        if sock:
            _sway_cmd(sock, "output", self.name, "unplug")
            log(f"[*] monitor virtual {self.name} desmontado")
        self.name = None


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
    def set_video_size(self, width, height):
        """Actualiza el tamano del video: el cursor se reescala en `_map`."""
        try:
            w, h = int(width), int(height)
        except (TypeError, ValueError):
            return
        if w <= 0 or h <= 0 or (w, h) == (self.video_w, self.video_h):
            return
        log(f"[*] cursor: video ahora {w}x{h}")
        self.video_w, self.video_h = w, h

    def _recv_loop(self):
        while not self.stopping:
            try:
                data, _addr = self.udp.recvfrom(64)
            except socket.timeout:
                continue
            except OSError:
                break
            msg = U.read_datagram(data)
            if msg is None:
                continue
            kind, value = msg
            if kind == "size":
                # Control de tamano del emisor: reescala el cursor sin cortar el proceso.
                self.set_video_size(value[0], value[1])
                continue
            x, y, seq = value
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


VIDEO_SINKS = ("glimagesink", "xvimagesink", "waylandsink")


# ---------------------------------------------------------------- recv in-process

class GstReceiver:
    """Pipeline gst del receptor en el proceso actual (K18).

    Correr el pipeline dentro de gvd permite fijar titulo/app_id de la ventana
    (waylandsink usa g_get_prgname) y vigilar los cuadros decodificados: si no
    llega ninguno en ~5 s se reinicia SOLO el pipeline, sin tocar el proceso ni
    el cursor. Los cambios de tamano se renegocian en el pipeline vivo para no
    destruir y recrear la superficie Wayland (eso causa un salto en el layout).
    """

    TICK_MS = 250

    def __init__(self, args, sink, cursor=None):
        self.a = args
        self.sink = sink
        self.cursor = cursor
        self.gst = None
        self.pipeline = None
        self.loop = None
        self.timer = 0
        self.max_timer = 0
        self.restart_timer = 0
        self.lock = threading.Lock()
        self.last_buffer = None
        self.video_size = None
        self.expected = (int(args.video_w), int(args.video_h))
        self.attempt = 0
        self.restart_want = False
        self.stopping = False
        self.failed = False

    # -- pipeline
    def _build(self):
        elements = recv_pipeline(self.a, self.sink, self.a.stats)[2:]
        try:
            return self.gst.parse_launch(" ".join(elements))
        except GLib.Error as e:
            log(f"[!] GStreamer: {e.message}")
            return None

    def _sink_element(self):
        target = SINK_ELEMENTS.get(self.sink, self.sink)
        it = self.pipeline.iterate_elements()
        while True:
            res, el = it.next()
            if res != self.gst.IteratorResult.OK:
                break
            factory = el.get_factory()
            if factory is not None and factory.get_name() == target:
                return el
        return None

    def _attach(self):
        el = self._sink_element()
        if el is None:
            return
        pad = el.get_static_pad("sink")
        if pad is None:
            return
        pad.add_probe(self.gst.PadProbeType.BUFFER, self._on_buffer_probe)
        pad.add_probe(self.gst.PadProbeType.EVENT_DOWNSTREAM, self._on_event_probe)

    def _on_buffer_probe(self, _pad, _info):
        with self.lock:
            self.last_buffer = time.monotonic()
        return self.gst.PadProbeReturn.OK

    def _on_event_probe(self, _pad, info):
        event = info.get_event()
        if event is None or event.type != self.gst.EventType.CAPS:
            return self.gst.PadProbeReturn.OK
        caps = event.parse_caps()
        if caps is None:
            return self.gst.PadProbeReturn.OK
        size = U.parse_caps_size(str(caps.to_string()))
        if size is None:
            return self.gst.PadProbeReturn.OK
        with self.lock:
            self.video_size = size
            if U.size_changed(self.expected, size):
                self.expected = size
                if self.cursor is not None:
                    self.cursor.set_video_size(size[0], size[1])
        return self.gst.PadProbeReturn.OK

    def _start_pipeline(self):
        self.pipeline = self._build()
        if self.pipeline is None:
            self.failed = True
            self.request_stop()
            return False
        self._attach()
        if self.pipeline.set_state(self.gst.State.PLAYING) == \
                self.gst.StateChangeReturn.FAILURE:
            log("[!] GStreamer no pudo iniciar el pipeline del receptor")
            self._stop_pipeline()
            self.failed = True
            self.request_stop()
            return False
        with self.lock:
            self.last_buffer = None
            self.video_size = None
            self.restart_want = False
        return True

    def _stop_pipeline(self):
        if self.pipeline is not None:
            self.pipeline.set_state(self.gst.State.NULL)
            self.pipeline = None

    # -- watchdog
    def _tick(self):
        if self.stopping:
            return True
        if self.restart_timer:
            return True  # ya hay un reinicio programado: no apilar otro
        now = time.monotonic()
        with self.lock:
            last = self.last_buffer
            observed = self.video_size
            want = self.restart_want
        if last is not None and now - last < U.STALL_TIMEOUT:
            self.attempt = 0  # volvio a fluir: el backoff arranca de nuevo
        elif not want and U.should_restart(now, last, self.expected, observed):
            want = True
        if want:
            self._restart()
        return True

    def _restart(self):
        with self.lock:
            self.restart_want = False
            self.last_buffer = None  # evita re-disparar con datos viejos
            size = self.video_size
        self.attempt += 1
        delay = U.backoff_delay(self.attempt)
        if size is not None:
            self.expected = size
            if self.cursor is not None:
                self.cursor.set_video_size(size[0], size[1])
        log(f"[*] recv: reinicio pipeline ({self.attempt}) en {delay:.0f}s "
            f"video={self.expected[0]}x{self.expected[1]}")
        self._stop_pipeline()
        self.restart_timer = GLib.timeout_add(int(delay * 1000), self._restart_now)

    def _restart_now(self):
        self.restart_timer = 0
        if self.stopping:
            return False
        self._start_pipeline()
        return False

    def _on_max_seconds(self):
        self.max_timer = 0
        self.request_stop()
        return False

    def request_stop(self):
        self.stopping = True
        if self.loop is not None:
            self.loop.quit()

    def _install_signals(self):
        def on_signal(_sig, _frame):
            self.request_stop()
        signal.signal(signal.SIGINT, on_signal)
        signal.signal(signal.SIGTERM, on_signal)

    def run(self):
        gi.require_version("Gst", "1.0")
        from gi.repository import Gst
        self.gst = Gst
        Gst.init(None)
        # waylandsink toma titulo y app_id de g_get_prgname(): se fija aqui para
        # que el shell reconozca la ventana como "Pantalla compartida".
        GLib.set_prgname(WINDOW_TITLE)
        GLib.set_application_name(WINDOW_TITLE)
        if not self._start_pipeline():
            return 2
        self.loop = GLib.MainLoop()
        self._install_signals()
        self.timer = GLib.timeout_add(self.TICK_MS, self._tick)
        if self.a.max_seconds:
            self.max_timer = GLib.timeout_add(int(self.a.max_seconds * 1000),
                                              self._on_max_seconds)
        self.loop.run()
        for src in (self.timer, self.max_timer, self.restart_timer):
            if src:
                GLib.source_remove(src)
        self.timer = self.max_timer = self.restart_timer = 0
        self._stop_pipeline()
        return 2 if self.failed else 0


def _run_recv_subprocess(args, sink):
    """Sink externo (ffplay) o fallback gst-launch: sin watchdog ni titulo."""
    env = dict(os.environ)
    if args.stats:
        env["GST_DEBUG"] = "fpsdisplaysink:5"
    cmd = ffplay_command(args) if sink == "ffplay" else \
        recv_pipeline(args, sink, args.stats)
    log(f"[*] recv sink={sink}: " + " ".join(cmd))
    proc = subprocess.Popen(cmd, env=env)
    t0 = time.monotonic()
    state = {"stop": False}

    def on_signal(_sig, _frame):
        state["stop"] = True

    old_int = signal.signal(signal.SIGINT, on_signal)
    old_term = signal.signal(signal.SIGTERM, on_signal)
    try:
        while proc.poll() is None:
            if state["stop"]:
                break
            if args.max_seconds and time.monotonic() - t0 > args.max_seconds:
                break
            time.sleep(0.2)
    finally:
        signal.signal(signal.SIGINT, old_int)
        signal.signal(signal.SIGTERM, old_term)
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        return 0
    return proc.returncode if proc.returncode else 0


def _run_recv_gst(args, sink, cursor):
    try:
        gi.require_version("Gst", "1.0")
        from gi.repository import Gst
    except (ValueError, ImportError) as e:
        log(f"[!] sin GStreamer en proceso ({e}); uso gst-launch externo")
        return _run_recv_subprocess(args, sink)
    Gst.init(None)
    return GstReceiver(args, sink, cursor).run()


def run_recv(args):
    lower_video_priority()
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
    try:
        for sink in sinks:
            rc = _run_recv_subprocess(args, sink) if sink == "ffplay" \
                else _run_recv_gst(args, sink, cursor)
            if rc == 0:
                return 0
            log(f"[!] {sink} termino rc={rc}, probando siguiente")
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
            "platform": "Mutter ScreenCast (GNOME) o wlroots wlr-screencopy "
                        "(sway/gdtk)",
            "backends": {
                "mutter": "GNOME Wayland/Mutter ScreenCast",
                "wlr": "wlroots wlr-screencopy (sway, gdtk)",
            },
            "wlr_ready": wlr_capture_ready(),
            "wlr_virtual": bool(_find_sway_socket()),
            "wlr_capture_c": os.path.exists(os.path.join(HERE, CAPTURE_HELPER_SRC)),
            "wlr_capture_bin": os.path.exists(os.path.join(HERE, CAPTURE_HELPER)),
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
    s.add_argument("--capture", default="auto", choices=["auto", "mutter", "wlr", "shm"],
                   help="backend de captura: auto detecta GNOME(Mutter) o wlroots; "
                        "shm = archivo de frames de una ventana gdtk (--shm)")
    s.add_argument("--shm", default="",
                   help="--capture shm: archivo de frames (ver shm_capture)")
    s.add_argument("--output", default="",
                   help="nombre del output wlroots a capturar (default: el primero)")
    s.add_argument("--virtual", action="store_true",
                   help="--capture wlr: crear un monitor headless de sway (extension real)")
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
                   help="margen de reordenamiento RTP en ms (default: 120; 0 para LAN estable)")
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


SHM_MAGIC = b"GVDSHM1\0"
SHM_HEADER = 64
SHM_RESIZED = 3   # rc de shm_capture: cambió el tamaño, rearmar sin contar como fallo
# Sin frame nuevo sólo se repite el último cada tanto: codificar 20 fps idénticos le
# costaba 50% de CPU a un X200. Los PTS los re-estampa attach_retimestamp por reloj,
# así que el stream tolera la cadencia variable; la repetición mantiene vivo el RTP y
# acota la espera de un receptor que se reengancha.
SHM_KEEPALIVE_S = 0.5


def shm_capture(path, fps, max_frames=0):
    """Lector del archivo de frames de una ventana gdtk, con el contrato de
    gvd-capture (cabecera GVDCAP1 por stderr, frames crudos por stdout).

    Archivo (little endian): magic[8] | seq u64 | width u32 | height u32 |
    stride u32 | fourcc[4] | relleno hasta 64 | frame. seq impar = el escritor
    está a mitad de frame (seqlock): se descarta y se reintenta. Sin frame nuevo
    se repite el anterior cada SHM_KEEPALIVE_S (no a cada tick). Termina cuando
    el archivo desaparece (el shell dejó de compartir) o se cierra stdout, y con
    SHM_RESIZED si cambia el tamaño (la ventana compartida se redimensionó): el
    emisor rearma el pipeline con el tamaño nuevo."""
    import struct
    deadline = time.monotonic() + 10
    while True:
        try:
            with open(path, "rb") as f:
                head = f.read(SHM_HEADER)
            if len(head) == SHM_HEADER and head[:8] == SHM_MAGIC:
                seq, w, h, stride = struct.unpack_from("<QIII", head, 8)
                if w > 0 and h > 0 and seq >= 2:
                    break
        except OSError:
            pass
        if time.monotonic() > deadline:
            log("[!] shm: sin frames en " + path)
            return 2
        time.sleep(0.05)
    fourcc = head[28:32].decode("ascii", "replace")
    size = stride * h
    sys.stderr.write(f"GVDCAP1 {fourcc} {w} {h} {stride}\n")
    sys.stderr.flush()
    out = sys.stdout.buffer
    last_seq, frame, sent, fresh = -1, None, 0, False
    last_out = 0.0
    period = 1.0 / max(1, fps)
    nxt = time.monotonic()
    try:
        while True:
            try:
                with open(path, "rb") as f:
                    s1, w2, h2, st2 = struct.unpack_from("<QIII", f.read(SHM_HEADER), 8)
                    if s1 % 2 == 0 and (w2, h2, st2) != (w, h, stride):
                        log(f"[*] shm: {w}x{h} -> {w2}x{h2}")
                        return SHM_RESIZED
                    if s1 % 2 == 0 and s1 != last_seq:
                        f.seek(SHM_HEADER)
                        data = f.read(size)
                        f.seek(8)
                        if struct.unpack("<Q", f.read(8))[0] == s1 and len(data) == size:
                            frame, last_seq, fresh = data, s1, True
            except FileNotFoundError:
                return 0
            now = time.monotonic()
            # Sondeo fino (2 ms) y `period` sólo como tope de cadencia: dormir un periodo
            # entero sumaba hasta 1/fps de latencia a cada frame.
            if frame is not None and ((fresh and now - last_out >= period)
                                      or now - last_out >= SHM_KEEPALIVE_S):
                out.write(frame)
                out.flush()
                sent += 1
                fresh = False
                last_out = now
                if max_frames and sent >= max_frames:
                    return 0
            time.sleep(0.002)
    except (BrokenPipeError, KeyboardInterrupt):
        return 0


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "__gst_child__":
        return run_gst_child(sys.argv[2:])
    if len(sys.argv) > 3 and sys.argv[1] == "__shm_capture__":
        return shm_capture(sys.argv[2], int(sys.argv[3]))
    args = build_parser().parse_args()

    if args.cmd == "caps":
        return run_caps(args)

    if args.cmd == "recv":
        if args.jitter_ms < 0:
            raise SystemExit("[!] --jitter-ms debe ser >= 0")
        try:
            args.video_w, args.video_h = U.parse_size(args.video_size) \
                or U.DEFAULT_VIDEO_SIZE
        except (TypeError, ValueError):
            args.video_w, args.video_h = U.DEFAULT_VIDEO_SIZE

        # run_recv instala sus propias señales (GstReceiver o el sink externo);
        # no se pisa con una que aborte el pipeline en medio del reinicio.
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
    lower_video_priority()

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
