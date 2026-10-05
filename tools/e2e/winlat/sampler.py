#!/usr/bin/env python3
"""Corre en el RECEPTOR: toma capturas del shell (RPC screenshot), decodifica el reloj de
stamp_app.py y reporta latencia visual = hora de la captura - hora estampada.
uso: sampler.py [N] [pausa_s=1.5]  (pausa corta = screenshots seguidos que frenan el shell e inflan la latencia 2x)   (salida JSON). El error es ~ +-medio screenshot (~20-40 ms)."""
import base64, io, json, os, sys, time
sys.path.insert(0, os.path.expanduser("~/gdtk/mcp"))
from gdtk_mcp import call_shell
from PIL import Image

PRE = [1, 0, 1, 0, 1, 1, 0, 0]
CELL, NBITS = 12, 36


def decode(img):
    g = img.convert("L")
    w, h = g.size
    px = g.load()
    for y in range(4, h, 6):
        row = [px[x, y] for x in range(w)]
        for x0 in range(0, w - CELL * (len(PRE) + NBITS) + 1):
            ok = True
            for k, b in enumerate(PRE):
                v = row[x0 + k * CELL + CELL // 2]
                if (v > 128) != bool(b):
                    ok = False
                    break
            if not ok:
                continue
            bits = [1 if row[x0 + (len(PRE) + i) * CELL + CELL // 2] > 128 else 0 for i in range(NBITS)]
            return sum(b << (NBITS - 1 - i) for i, b in enumerate(bits))
    return None


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    pause = float(sys.argv[2]) if len(sys.argv) > 2 else 1.5
    res, miss = [], 0
    for _ in range(n):
        t0 = time.time_ns()
        r = call_shell("screenshot", {"max_width": 0})
        t1 = time.time_ns()
        img = Image.open(io.BytesIO(base64.b64decode(r["png_base64"])))
        stamp = decode(img)
        if stamp is None:
            miss += 1
        else:
            mid = (t0 + t1) // 2 // 1_000_000
            res.append({"lat_ms": (mid - stamp) % (1 << NBITS), "shot_ms": (t1 - t0) / 1e6})
        time.sleep(pause)
    lat = sorted(r["lat_ms"] for r in res)
    out = {"n": len(lat), "miss": miss}
    if lat:
        out.update(min=lat[0], p50=lat[len(lat) // 2], p90=lat[int(len(lat) * 0.9)], max=lat[-1],
                   shot_ms=round(sum(r["shot_ms"] for r in res) / len(res), 1), all=lat)
    print(json.dumps(out))


main()
