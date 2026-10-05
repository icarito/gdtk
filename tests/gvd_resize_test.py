#!/usr/bin/env python3
"""Tests puros de K18 (SPEC-ui-rework-2026-10): receptor como ventana normal y
resistencia a cambios de layout del monitor virtual.

No abre ningun stream ni toca Mutter: solo ejercita tools/gvd/gvd_util.py (y
comprueba el pipeline del receptor cuando PyGObject esta disponible).
Uso: python3 tests/gvd_resize_test.py
"""

import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "gvd"))
import gvd_util as U  # noqa: E402


def _monitor(connector, width, height, current=True):
    mode = ("%dx%d" % (width, height), width, height, 59.97, 1.0, [],
            {"is-current": current})
    return ((connector, "vendor", "product", "serial"), [mode],
            {"display-name": connector})


class ParseTest(unittest.TestCase):
    def test_parse_size(self):
        self.assertEqual(U.parse_size("1280x800"), (1280, 800))
        self.assertEqual(U.parse_size(" 1920X1080 "), (1920, 1080))
        self.assertIsNone(U.parse_size("1280"))
        self.assertIsNone(U.parse_size("x800"))
        self.assertIsNone(U.parse_size("0x800"))
        self.assertIsNone(U.parse_size(None))

    def test_parse_caps_size(self):
        self.assertEqual(
            U.parse_caps_size("video/x-raw,width=1280,height=800,framerate=30/1"),
            (1280, 800))
        self.assertEqual(
            U.parse_caps_size("video/x-raw, width=(int)1600, height=(int)900"),
            (1600, 900))
        self.assertIsNone(U.parse_caps_size("video/x-raw,framerate=30/1"))
        self.assertIsNone(U.parse_caps_size(""))

    def test_size_changed(self):
        self.assertTrue(U.size_changed((1280, 800), (1600, 900)))
        self.assertFalse(U.size_changed((1280, 800), (1280, 800)))
        self.assertFalse(U.size_changed(None, (1280, 800)))
        self.assertFalse(U.size_changed((1280, 800), None))

    def test_backoff_and_attempts(self):
        self.assertEqual([U.backoff_delay(i) for i in range(1, 6)],
                         [1.0, 2.0, 4.0, 5.0, 5.0])
        self.assertEqual(U.backoff_delay(99), 5.0)
        self.assertTrue(U.restart_allowed(1))
        self.assertTrue(U.restart_allowed(U.MAX_RESTARTS))
        self.assertFalse(U.restart_allowed(U.MAX_RESTARTS + 1))

    def test_should_restart(self):
        # Cambio de tamano: reinicia aunque el flujo este fresco.
        # El sink renegocia caps sin destruir/recrear su superficie Wayland.
        self.assertFalse(U.should_restart(100.0, 99.5, (1280, 800), (1600, 900)))
        # Atasco: mas de 5 s sin cuadros decodificados.
        self.assertFalse(U.should_restart(100.0, 99.5, (1280, 800), (1280, 800)))
        self.assertTrue(U.should_restart(106.0, 99.5, (1280, 800), (1280, 800)))
        # Antes del primer cuadro no reinicia por watchdog.
        self.assertFalse(U.should_restart(999.0, None, (1280, 800), None))

    def test_scale_cursor(self):
        self.assertEqual(U.scale_cursor(640, 400, (1280, 800), (1920, 1080)),
                         (960, 540))
        self.assertEqual(U.scale_cursor(10, 10, (0, 0), (1280, 800)), (10, 10))


class WireTest(unittest.TestCase):
    def test_size_control_roundtrip(self):
        packet = U.encode_size_control(1600, 900)
        self.assertEqual(len(packet), U.SIZE_CONTROL_LEN)
        self.assertEqual(U.decode_size_control(packet), (1600, 900))

    def test_size_control_rejects_cursor_and_garbage(self):
        self.assertIsNone(U.decode_size_control(U.pack_cursor(1, 2, 3)))
        self.assertIsNone(U.decode_size_control(b"nope"))
        self.assertIsNone(U.decode_size_control(b"GVDS" + struct.pack("!HH", 0, 0)))

    def test_cursor_roundtrip_and_datagram(self):
        cur = U.pack_cursor(0x1234, 0x00FF, 0xDEADBEEF)
        self.assertEqual(U.unpack_cursor(cur), (0x1234, 0x00FF, 0xDEADBEEF))
        self.assertEqual(U.read_datagram(cur),
                         ("cursor", (0x1234, 0x00FF, 0xDEADBEEF)))
        self.assertEqual(U.read_datagram(U.encode_size_control(800, 600)),
                         ("size", (800, 600)))
        self.assertIsNone(U.read_datagram(b"\x00"))


class MutterParseTest(unittest.TestCase):
    def _monitors(self):
        return [
            _monitor("eDP-1", 1920, 1080),
            _monitor("Meta-0", 1280, 800),
            _monitor("HDMI-1", 2560, 1440, current=False),
        ]

    def test_virtual_monitor_size(self):
        self.assertEqual(U.virtual_monitor_size(self._monitors()), (1280, 800))
        self.assertEqual(U.virtual_connector(self._monitors()), "Meta-0")
        self.assertEqual(
            U.virtual_monitor_size(self._monitors(), "eDP-1"), (1920, 1080))
        self.assertIsNone(U.virtual_monitor_size([_monitor("eDP-1", 1920, 1080)]))
        self.assertIsNone(U.virtual_monitor_size(None))

    def test_session_stop_error(self):
        self.assertTrue(U.session_stop_error(
            "Session.Stop: object does not exist"))
        self.assertTrue(U.session_stop_error("No such object at path ..."))
        self.assertFalse(U.session_stop_error("Connection timed out"))

    def test_sender_restart_plan(self):
        first = U.sender_restart_plan(1, first=True, size_changed_flag=True)
        self.assertTrue(first["ok"] and first["recreate"])
        self.assertTrue(first["apply_position"])
        self.assertTrue(first["notify_receiver"])
        self.assertEqual(first["delay"], 1.0)
        later = U.sender_restart_plan(3, first=False, size_changed_flag=True)
        self.assertFalse(later["apply_position"])
        self.assertTrue(later["notify_receiver"])
        self.assertEqual(later["delay"], 4.0)
        last = U.sender_restart_plan(U.MAX_RESTARTS, first=False)
        self.assertTrue(last["ok"])
        self.assertFalse(U.sender_restart_plan(U.MAX_RESTARTS + 1)["ok"])


class ConstantsTest(unittest.TestCase):
    def test_window_identity(self):
        self.assertEqual(U.WINDOW_TITLE, "Pantalla compartida")
        self.assertTrue(U.APP_ID)


class ReceiverPipelineTest(unittest.TestCase):
    """Comprueba el pipeline del receptor si gvd importa (PyGObject)."""

    def setUp(self):
        try:
            import importlib
            self.gvd = importlib.import_module("gvd")
        except Exception as e:  # pragma: no cover - entorno sin PyGObject
            self.skipTest("gvd no importable: %s" % e)

    def test_no_fullscreen_and_fixed_title(self):
        args = self.gvd.build_parser().parse_args(
            ["recv", "--sink", "wayland", "--video-size", "1280x800"])
        cmd = self.gvd.recv_pipeline(args, "waylandsink", False)
        self.assertIn("waylandsink", cmd)
        self.assertNotIn("force-aspect-ratio=true", cmd)
        self.assertNotIn("fullscreen=true", cmd)
        self.assertEqual(self.gvd.WINDOW_TITLE, U.WINDOW_TITLE)
        self.assertEqual(self.gvd.APP_ID, U.APP_ID)

    def test_ffplay_unchanged(self):
        args = self.gvd.build_parser().parse_args(
            ["recv", "--transport", "tcp", "--sink", "ffplay"])
        self.assertEqual(self.gvd.ffplay_command(args)[-4:],
                         ["-i", "tcp://0.0.0.0:5600?listen=1", "-fs", "-an"])

    def test_watchdog_helper_imported(self):
        self.assertTrue(hasattr(self.gvd, "GstReceiver"))
        self.assertIs(self.gvd.U, U)


if __name__ == "__main__":
    unittest.main(verbosity=2)
