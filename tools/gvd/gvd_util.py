#!/usr/bin/env python3
"""gvd_util - logica pura de gvd para la tarea K18 (SPEC-ui-rework-2026-10).

Sin PyGObject, Mutter, GStreamer ni red: solo stdlib. Decide si hay que
reiniciar el pipeline del receptor (atasco de cuadros o cambio de tamano del
video), calcula el backoff del emisor, parsea tamanos de caps y de
DisplayConfig, y define el paquete UDP de control de tamano del puerto de
cursor. Se prueba con `python3 tests/gvd_resize_test.py`.
"""

import struct

DEFAULT_VIDEO_SIZE = (1280, 800)
# El receptor se presenta como una ventana normal del shell: titulo fijo y
# app_id estable (waylandsink usa g_get_prgname() para ambos; se fija desde
# gvd.py antes de crear el sink).
WINDOW_TITLE = "Pantalla compartida"
APP_ID = "gvd.SharedScreen"

# Paquete de control de tamano en el puerto del cursor (puerto de video + 1):
# 4 bytes de magia + ancho u16 + alto u16 + 4 bytes reservados = 12 bytes. Los
# datagramas de cursor siguen siendo 8 bytes (x u16, y u16, seq u32), asi que
# se distinguen por longitud y magia sin romper compatibilidad.
SIZE_CONTROL_MAGIC = b"GVDS"
SIZE_CONTROL_LEN = 12
CURSOR_LEN = 8

STALL_TIMEOUT = 5.0
BACKOFF_BASE = 1.0
BACKOFF_MAX = 5.0
MAX_RESTARTS = 5


def parse_size(s):
    """'1280x800' -> (1280, 800); None si no es valido."""
    if s is None:
        return None
    w, sep, h = str(s).strip().lower().partition("x")
    if sep == "":
        return None
    try:
        w = int(w)
        h = int(h)
    except (TypeError, ValueError):
        return None
    if w <= 0 or h <= 0:
        return None
    return (w, h)


def parse_caps_size(caps):
    """Tamano (w, h) de un caps GStreamer, o None.

    Acepta 'video/x-raw,width=1280,height=800,framerate=30/1' y variantes con
    espacios. El caps puede venir de la caps de un pad o del bus.
    """
    if not caps:
        return None
    w = h = None
    for part in str(caps).split(","):
        key, sep, value = part.strip().partition("=")
        if sep == "":
            continue
        key = key.strip().lower()
        if key not in ("width", "height"):
            continue
        try:
            token = value.strip().split()[0].split("/")[0]
            # Los caps de Gst pueden traer el tipo: 'width=(int)1280'.
            token = token.rsplit(")", 1)[-1]
            n = int(token)
        except (TypeError, ValueError, IndexError):
            continue
        if key == "width":
            w = n
        else:
            h = n
    if not w or not h or w <= 0 or h <= 0:
        return None
    return (w, h)


def size_changed(expected, observed):
    if not expected or not observed:
        return False
    try:
        return (int(expected[0]), int(expected[1])) != (int(observed[0]), int(observed[1]))
    except (TypeError, ValueError, IndexError):
        return False


def backoff_delay(attempt):
    """Backoff exponencial 1 -> 5 s para el intento `attempt` (>= 1)."""
    a = max(1, int(attempt))
    return min(BACKOFF_MAX, BACKOFF_BASE * (2 ** (a - 1)))


def restart_allowed(attempt):
    """True mientras no se supere el maximo de intentos del emisor."""
    return int(attempt) <= MAX_RESTARTS


def should_restart(now, last_buffer, expected_size, observed_size,
                   stall_timeout=STALL_TIMEOUT):
    """Decision del watchdog del receptor.

    Reinicia si no llega ningun cuadro decodificado en `stall_timeout` segundos
    desde `last_buffer`. Un cambio de tamano se renegocia sin reiniciar para
    conservar la misma superficie Wayland. Antes del primer cuadro
    (last_buffer None) no reinicia: la espera inicial la gobierna el arranque.
    """
    if last_buffer is None:
        return False
    return (now - last_buffer) > stall_timeout


def scale_cursor(x, y, src_size, dst_size):
    """Reescala una posicion de cursor de un tamano de video a otro."""
    try:
        sw, sh = int(src_size[0]), int(src_size[1])
        dw, dh = int(dst_size[0]), int(dst_size[1])
    except (TypeError, ValueError, IndexError):
        return (int(x), int(y))
    if sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0:
        return (int(x), int(y))
    return (int(round(x * dw / sw)), int(round(y * dh / sh)))


def encode_size_control(width, height):
    """Datagrama de control con el nuevo tamano del video (puerto del cursor)."""
    w = max(0, min(65535, int(width)))
    h = max(0, min(65535, int(height)))
    return SIZE_CONTROL_MAGIC + struct.pack("!HH", w, h) + b"\x00\x00\x00\x00"


def decode_size_control(data):
    """(w, h) si `data` es un paquete de control valido, si no None."""
    if data is None or len(data) != SIZE_CONTROL_LEN:
        return None
    if data[:4] != SIZE_CONTROL_MAGIC:
        return None
    w, h = struct.unpack("!HH", data[4:8])
    if w <= 0 or h <= 0:
        return None
    return (w, h)


def pack_cursor(x, y, seq):
    return struct.pack("!HHI", int(x) & 0xFFFF, int(y) & 0xFFFF,
                       int(seq) & 0xFFFFFFFF)


def unpack_cursor(data):
    """(x, y, seq) de un datagrama de cursor, o None."""
    if data is None or len(data) < CURSOR_LEN:
        return None
    return struct.unpack("!HHI", data[:CURSOR_LEN])


def read_datagram(data):
    """Clasifica un datagrama del puerto de cursor.

    Devuelve ('size', (w, h)) o ('cursor', (x, y, seq)) o None si no es ninguno.
    """
    size = decode_size_control(data)
    if size is not None:
        return ("size", size)
    cursor = unpack_cursor(data)
    if cursor is not None:
        return ("cursor", cursor)
    return None


def virtual_connector(monitors):
    """Conector del monitor virtual de Mutter ('Meta-*') en GetCurrentState."""
    for mon in monitors or []:
        try:
            name = mon[0][0]
        except (TypeError, IndexError):
            continue
        if str(name).startswith("Meta-"):
            return str(name)
    return None


def current_mode(monitor):
    """Modo marcado is-current de un monitor, o el primero."""
    try:
        modes = monitor[1]
    except (TypeError, IndexError):
        return None
    if not modes:
        return None
    for m in modes:
        try:
            if m[6].get("is-current", False):
                return m
        except (TypeError, IndexError, AttributeError):
            continue
    return modes[0]


def mode_size(monitor):
    """(w, h) del modo actual de un monitor de GetCurrentState, o None."""
    m = current_mode(monitor)
    if not m:
        return None
    try:
        return (int(m[1]), int(m[2]))
    except (TypeError, IndexError, ValueError):
        return None


def virtual_monitor_size(monitors, connector=None):
    """Tamano del monitor virtual (Meta-*) o del conector pedido, o None."""
    for mon in monitors or []:
        try:
            conn = str(mon[0][0])
        except (TypeError, IndexError):
            continue
        if connector is None:
            if conn.startswith("Meta-"):
                return mode_size(mon)
        elif conn == str(connector):
            return mode_size(mon)
    return None


def session_stop_error(message):
    """True si el error de D-Bus indica que la sesion ScreenCast ya no existe."""
    m = str(message or "").lower()
    for needle in ("does not exist", "no such object", "unknown object",
                   "unknown method"):
        if needle in m:
            return True
    return False


def sender_restart_plan(attempt, first=False, size_changed_flag=False):
    """Plan puro del emisor tras MonitorsChanged o fin de sesion ScreenCast.

    `apply_position` solo en la primera creacion (no se pisa el layout que la
    persona acaba de ajustar); `notify_receiver` avisa al receptor del tamano
    nuevo; `delay` es el backoff antes de reintentar.
    """
    if not restart_allowed(attempt):
        return {"ok": False, "recreate": False, "apply_position": False,
                "notify_receiver": False, "delay": 0.0}
    return {"ok": True, "recreate": True, "apply_position": bool(first),
            "notify_receiver": bool(size_changed_flag),
            "delay": backoff_delay(attempt)}
