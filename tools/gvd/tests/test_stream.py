"""Real encode/RTP/decode smoke tests, without touching the active display.

Run: python3 -m unittest discover -s tests -v
Requires the same GStreamer plugins as GVD (VA tests skip without hardware).
"""
import socket
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import gvd
import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gst

Gst.init(None)


class StreamTest(unittest.TestCase):
    def test_ffplay_tcp_receiver(self):
        args = gvd.build_parser().parse_args([
            "recv", "--transport", "tcp", "--sink", "ffplay", "--port", "5678"])
        self.assertEqual(gvd.ffplay_command(args)[-4:], [
            "-i", "tcp://0.0.0.0:5678?listen=1", "-fs", "-an"])
        with patch.object(gvd.shutil, "which", return_value="/usr/bin/ffplay"):
            self.assertEqual(gvd.choose_sinks("auto", "tcp")[0], "ffplay")

    def test_tcp_transport(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        args = gvd.build_parser().parse_args([
            "send", "--encoder", "x264", "--transport", "tcp", "--host", "127.0.0.1",
            "--port", str(port), "--fps", "30", "--bitrate", "4000"])
        sender = gvd.Sender.__new__(gvd.Sender)
        sender.a, sender.node_id = args, 0
        tx_cmd = sender.build_pipeline()[2:]
        tx_cmd = ["videotestsrc", "is-live=true", "num-buffers=60", "pattern=ball", "!",
                  "video/x-raw,width=1280,height=800,framerate=30/1", "!"] + tx_cmd[tx_cmd.index("videoconvert"):]
        rx_args = gvd.build_parser().parse_args([
            "recv", "--transport", "tcp", "--port", str(port)])
        rx_cmd = gvd.recv_pipeline(rx_args, "glimagesink", False)[2:]
        rx_cmd = rx_cmd[:rx_cmd.index("glimagesink")] + [
            "fakesink", "name=frames", "signal-handoffs=true", "sync=false"]
        tx = Gst.parse_launch(" ".join(tx_cmd))
        rx = Gst.parse_launch(" ".join(rx_cmd))
        gvd.attach_retimestamp(tx)
        frames = []
        rx.get_by_name("frames").connect(
            "handoff", lambda _element, buffer, _pad: frames.append(buffer.pts))
        try:
            rx.set_state(Gst.State.PLAYING)
            tx.set_state(Gst.State.PLAYING)
            msg = tx.get_bus().timed_pop_filtered(
                8 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
            self.assertIsNotNone(msg)
            self.assertEqual(msg.type, Gst.MessageType.EOS)
            self.assertGreater(len(frames), 30)
        finally:
            tx.set_state(Gst.State.NULL)
            rx.set_state(Gst.State.NULL)

    # -- backend de captura wlroots (sway/gdtk), sin PipeWire -------------------
    def test_shm_capture_reader(self):
        """El lector shm cumple el contrato de gvd-capture y respeta el seqlock."""
        import struct, subprocess, tempfile, os
        w, h = 4, 2
        frame = bytes(range(w * h * 4))
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "win.frames")
            head = gvd.SHM_MAGIC + struct.pack("<QIII4s", 2, w, h, w * 4, b"AB24")
            with open(path, "wb") as f:
                f.write(head.ljust(gvd.SHM_HEADER, b"\0") + frame)
            p = subprocess.Popen([sys.executable, gvd.__file__, "__shm_capture__", path, "30"],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                self.assertEqual(p.stderr.readline().decode().split(),
                                 ["GVDCAP1", "AB24", "4", "2", "16"])
                self.assertEqual(p.stdout.read(len(frame)), frame)
                # Escritor a mitad de frame (seq impar): se repite el último completo.
                with open(path, "r+b") as f:
                    f.seek(8); f.write(struct.pack("<Q", 3))
                    f.seek(gvd.SHM_HEADER); f.write(b"\xff" * len(frame))
                self.assertEqual(p.stdout.read(len(frame)), frame)
                os.unlink(path)
                self.assertEqual(p.wait(timeout=3), 0)
            finally:
                if p.poll() is None:
                    p.kill()
        self.assertEqual(gvd.detect_capture_backend("shm"), "shm")

    def test_wlr_source_pipeline(self):
        args = gvd.build_parser().parse_args([
            "send", "--encoder", "x264", "--capture", "wlr", "--host", "127.0.0.1"])
        sender = gvd.Sender.__new__(gvd.Sender)
        sender.a, sender.node_id = args, 0
        source = ["fdsrc", "fd=0", "!", "rawvideoparse", "format=BGRx",
                  "width=1280", "height=800", "framerate=30/1", "!"]
        cmd = sender.build_pipeline(source=source)
        self.assertIn("rawvideoparse", cmd)
        self.assertNotIn("pipewiresrc", cmd)
        self.assertIn("x264enc", cmd)
        self.assertIn("rtph264pay", cmd)
        # El formato wl_shm XR24/AR24 mapea a BGRx/BGRA.
        self.assertEqual(gvd.CAPTURE_FORMATS["XR24"], "BGRx")
        self.assertEqual(gvd.CAPTURE_FORMATS["AR24"], "BGRA")

    def test_detect_capture_backend(self):
        with patch.dict(gvd.os.environ, {"XDG_CURRENT_DESKTOP": "GNOME",
                                         "WAYLAND_DISPLAY": "wayland-0"}):
            self.assertEqual(gvd.detect_capture_backend("auto"), "mutter")
        with patch.dict(gvd.os.environ, {"XDG_CURRENT_DESKTOP": "gdtk"}):
            with patch.object(gvd, "wlr_capture_available", return_value=True):
                self.assertEqual(gvd.detect_capture_backend("auto"), "wlr")
            with patch.object(gvd, "wlr_capture_available", return_value=False):
                self.assertEqual(gvd.detect_capture_backend("auto"), "mutter")
        with patch.object(gvd, "wlr_capture_available", return_value=False):
            self.assertIsNone(gvd.detect_capture_backend("wlr"))

    def test_retimestamp_repeated_source_pts(self):
        pipeline = Gst.parse_launch(
            "videotestsrc is-live=true num-buffers=12 ! "
            "identity name=bad signal-handoffs=true ! "
            "identity name=gvd_stamp signal-handoffs=true ! "
            "fakesink name=out signal-handoffs=true sync=false")
        pipeline.get_by_name("bad").connect(
            "handoff", lambda _element, buffer: setattr(buffer, "pts", 3600000000000000))
        gvd.attach_retimestamp(pipeline)
        timestamps = []
        pipeline.get_by_name("out").connect(
            "handoff", lambda _element, buffer, _pad: timestamps.append(buffer.pts))
        pipeline.use_clock(Gst.SystemClock.obtain())
        pipeline.set_state(Gst.State.PLAYING)
        message = pipeline.get_bus().timed_pop_filtered(
            5 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
        pipeline.set_state(Gst.State.NULL)
        self.assertIsNotNone(message)
        self.assertEqual(message.type, Gst.MessageType.EOS)
        self.assertEqual(len(timestamps), 12)
        self.assertGreaterEqual(timestamps[0], 3600000000000000)
        self.assertTrue(all(a < b for a, b in zip(timestamps, timestamps[1:])))

    def exercise(self, encoder, quality, impair):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        args = gvd.build_parser().parse_args([
            "send", "--encoder", encoder, "--quality", quality,
            "--fps", "30", "--bitrate", "4000", "--port", str(port)])
        sender = gvd.Sender.__new__(gvd.Sender)
        sender.a, sender.node_id = args, 0
        with patch.object(gvd, "choose_encoder", return_value=(encoder, encoder == "va")):
            tx_cmd = sender.build_pipeline()[2:]
        # Replace only capture and UDP sink: use GVD's actual encoding/payloader.
        tx_cmd = ["videotestsrc", "is-live=true", "pattern=ball", "num-buffers=120", "!",
                  "video/x-raw,width=1280,height=800,framerate=30/1", "!"] + tx_cmd[tx_cmd.index("videoconvert"):]
        tx_cmd = tx_cmd[:tx_cmd.index("udpsink")] + ["appsink", "name=packets", "emit-signals=true", "sync=false"]
        rx_args = gvd.build_parser().parse_args(["recv", "--port", str(port)])
        rx_cmd = gvd.recv_pipeline(rx_args, "glimagesink", False)[2:]
        rx_cmd = rx_cmd[:rx_cmd.index("glimagesink")] + ["fakesink", "name=frames", "signal-handoffs=true", "sync=false"]
        tx = Gst.parse_launch(" ".join(tx_cmd))
        rx = Gst.parse_launch(" ".join(rx_cmd))
        decoded = []
        rx.get_by_name("frames").connect("handoff", lambda _sink, buf, _pad: decoded.append(buf.pts))
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        state = {"timestamp": None, "frame": 0, "held": None, "dropped": False, "reordered": 0}

        def send(packet):
            udp.sendto(packet, ("127.0.0.1", port))

        def on_packet(sink):
            sample = sink.emit("pull-sample")
            buf = sample.get_buffer()
            packet = buf.extract_dup(0, buf.get_size())
            timestamp = packet[4:8]
            if timestamp != state["timestamp"]:
                if state["held"] is not None:
                    send(state["held"])
                    state["held"] = None
                state["timestamp"] = timestamp
                state["frame"] += 1
            if impair and state["frame"] == 35 and not state["dropped"]:
                state["dropped"] = True
                return Gst.FlowReturn.OK
            # Reorder pairs within one frame; never hold its final RTP packet.
            if impair and state["held"] is not None:
                send(packet)
                send(state["held"])
                state["held"] = None
                state["reordered"] += 1
            elif impair and not packet[1] & 0x80:
                state["held"] = packet
            else:
                send(packet)
            return Gst.FlowReturn.OK

        tx.get_by_name("packets").connect("new-sample", on_packet)
        try:
            rx.set_state(Gst.State.PLAYING)
            tx.set_state(Gst.State.PLAYING)
            msg = tx.get_bus().timed_pop_filtered(10 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
            self.assertIsNotNone(msg, "sender timed out")
            if msg.type == Gst.MessageType.ERROR:
                self.fail(str(msg.parse_error()))
            # Let the receiver drain its final packets without a display.
            err = rx.get_bus().timed_pop_filtered(200 * Gst.MSECOND, Gst.MessageType.ERROR)
            self.assertIsNone(err, str(err.parse_error()) if err else "")
            jitter = next(e for e in rx.iterate_elements() if e.get_factory().get_name() == "rtpjitterbuffer")
            lost = jitter.get_property("stats").get_value("num-lost")
            print(f" {encoder}/{quality}: encoded={state['frame']} decoded={len(decoded)} lost={lost}")
            if impair:
                self.assertTrue(state["dropped"])
                self.assertGreater(state["reordered"], 0)
                self.assertEqual(lost, 1)
                # At most one GOP to join, plus one GOP to recover from loss.
                self.assertGreaterEqual(len(decoded), state["frame"] - 60, "did not recover after packet loss")
                self.assertLess(len(decoded), state["frame"], "loss should suppress dependent frames")
            else:
                self.assertEqual(lost, 0)
                self.assertGreaterEqual(len(decoded), state["frame"] - 30, "did not join within one GOP")
            # Recovery must continue through the final second of the stream.
            self.assertGreaterEqual(decoded[-1], 3 * Gst.SECOND)
            self.assertGreaterEqual(decoded[-1] - decoded[0], 2 * Gst.SECOND)
        finally:
            tx.set_state(Gst.State.NULL)
            rx.set_state(Gst.State.NULL)
            udp.close()

    def test_x264_clean(self):
        self.exercise("x264", "balanced", False)

    def test_x264_loss_and_reordering(self):
        self.exercise("x264", "balanced", True)

    def test_x264_speed(self):
        self.exercise("x264", "speed", False)

    def test_va_loss_and_reordering(self):
        if not gvd.va_dry_run():
            self.skipTest("VA encoder unavailable")
        self.exercise("va", "balanced", True)
