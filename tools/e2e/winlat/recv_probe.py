#!/usr/bin/env python3
"""Receptor de PRUEBA (en cupid): mismo pipeline que `gvd recv` pero con appsink; decodifica el
reloj de stamp_app.py de cada frame y reporta (ahora - estampa) = latencia captura->decodificado,
sin pantalla ni shell. uso: recv_probe.py [puerto=5611] [segundos=12] [jitter_ms=30]"""
import sys, time, json
import gi
gi.require_version("Gst", "1.0")
from gi.repository import Gst
Gst.init(None)
PRE = [1, 0, 1, 0, 1, 1, 0, 0]; CELL = 12; NB = 36
port = int(sys.argv[1]) if len(sys.argv) > 1 else 5611
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 12
jit = int(sys.argv[3]) if len(sys.argv) > 3 else 30
p = Gst.parse_launch(
    f'udpsrc port={port} buffer-size=4194304 caps="application/x-rtp,media=video,encoding-name=H264,payload=96,clock-rate=90000" ! '
    f'rtpjitterbuffer latency={jit} drop-on-latency=true do-lost=true ! rtph264depay wait-for-keyframe=true ! '
    'video/x-h264,alignment=au ! h264parse ! avdec_h264 ! videoconvert ! video/x-raw,format=GRAY8 ! '
    'appsink name=s emit-signals=false sync=false max-buffers=1 drop=true')
sink = p.get_by_name("s")
p.set_state(Gst.State.PLAYING)
res = []; t_end = time.time() + secs
while time.time() < t_end:
    smp = sink.emit("try-pull-sample", Gst.SECOND // 5)
    if smp is None:
        continue
    now = time.time_ns() // 1000000
    caps = smp.get_caps().get_structure(0); w = caps.get_value("width")
    b = smp.get_buffer(); ok, m = b.map(Gst.MapFlags.READ)
    row = bytes(m.data[8 * w:9 * w]); b.unmap(m)
    for x0 in range(0, w - CELL * (8 + NB) + 1):
        if all((row[x0 + k * CELL + 6] > 128) == bool(v) for k, v in enumerate(PRE)):
            st = sum((1 if row[x0 + (8 + i) * CELL + 6] > 128 else 0) << (NB - 1 - i) for i in range(NB))
            res.append((now - st) % (1 << NB)); break
p.set_state(Gst.State.NULL)
res.sort()
print(json.dumps({"n": len(res), "min": res[0], "p50": res[len(res) // 2], "p90": res[int(len(res) * .9)], "max": res[-1]} if res else {"n": 0}))
