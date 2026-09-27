#!/usr/bin/env python3
"""Verificación del Paso 12 (HoloTerminal de la Criopod) por control remoto.

Abre la actividad Criopod, apunta a la pantalla 3D que reporta el shell, mueve el
puntero en 30 pasos sobre ella, deja el cursor sobre el botón de escotilla y hace
click. Guarda en la raíz del repo:
  criopod.png          terminal en 3D en reposo
  criopod-cursor.png   cursor (shader) sobre el botón, hover resaltado
  criopod-open.png     tras el click, estado de la cápsula cambiado

El sufijo de los PNG se controla con GDTK_HOLO_SUFFIX (p.ej. -gles2).
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from mcp_driver import McpClient, FAILED, check, content_text, write_png  # noqa: E402

SUFFIX = os.environ.get("GDTK_HOLO_SUFFIX", "")


def shot(client, name):
    result = client.call_tool("gdtk_screenshot", {"max_width": 1280})
    ok = write_png(result, os.path.join(ROOT, name))
    check("gdtk_screenshot -> %s" % name, ok and not result.get("isError"))
    return ok


def main():
    client = McpClient()
    try:
        client.send("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "gdtk-holoterminal"},
        })
        client.send("notifications/initialized", {}, notify=True)

        client.call_tool("gdtk_open", {"name": "Criopod"})
        time.sleep(3.0)
        state = content_text(client.call_tool("gdtk_state"))
        view = state.get("view") if isinstance(state, dict) else None
        check("Criopod abierto", view == "Criopod", str(view))

        holo = state.get("holo_screen") if isinstance(state, dict) else None
        check("holo_screen presente",
              isinstance(holo, dict) and holo.get("w", 0) > 40 and holo.get("h", 0) > 40,
              str(holo))
        if not isinstance(holo, dict) or holo.get("w", 0) <= 0:
            return 1

        shot(client, "criopod%s.png" % SUFFIX)

        # 30 pasos a lo largo de la pantalla, en ~1 s.
        x0 = holo["x"] + holo["w"] * 0.15
        x1 = holo["x"] + holo["w"] * 0.85
        y = holo["y"] + holo["h"] * 0.35
        for i in range(30):
            t = float(i) / 29.0
            client.call_tool("gdtk_move", {"x": x0 + (x1 - x0) * t, "y": y})
            time.sleep(1.0 / 30.0)
        time.sleep(0.5)

        points = state.get("holo_points") if isinstance(state, dict) else None
        button = points.get("button") if isinstance(points, dict) else None
        check("holo_points.button presente", isinstance(button, dict), str(points))
        if isinstance(button, dict):
            client.call_tool("gdtk_move", {"x": button["x"], "y": button["y"]})
            time.sleep(1.5)
        shot(client, "criopod-cursor%s.png" % SUFFIX)

        if isinstance(button, dict):
            client.call_tool("gdtk_click", {"x": button["x"], "y": button["y"]})
            time.sleep(1.5)
        shot(client, "criopod-open%s.png" % SUFFIX)
    finally:
        client.close()

    if FAILED:
        print("RESULTADO: FALLO (%d): %s" % (len(FAILED), ", ".join(FAILED)))
        return 1
    print("RESULTADO: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
