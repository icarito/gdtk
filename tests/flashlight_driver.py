#!/usr/bin/env python3
"""Verificación del Paso 13 (Linterna de casco con ImGui) por control remoto.

Abre la actividad Linterna, apunta a la pantalla 3D que reporta el shell, mueve el
puntero sobre ella, hace click en ENCENDER/APAGAR y fuerza batería baja con el botón
de debug del overlay. Guarda en la raíz del repo (sufijo GDTK_FLASH_SUFFIX, p.ej.
-gles2):

  flashlight.png         pantalla 3D en reposo (APAGADA)
  flashlight-on.png      tras el click, ENCENDIDA
  flashlight-low.png     batería baja (STATE_ALARM)
  flashlight-widget.png      recorte 210x80 del widget compacto (apagado)
  flashlight-widget-on.png   recorte 210x80 del widget compacto (encendido)

El recorte usa los puntos `widget_tl`/`widget_br` que expone la actividad; con PIL
queda exactamente 210x80. Si PIL no está, se saltea el recorte (no es FAIL).
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from mcp_driver import McpClient, FAILED, check, content_text, write_png  # noqa: E402

SUFFIX = os.environ.get("GDTK_FLASH_SUFFIX", "")


def shot(client, name):
    result = client.call_tool("gdtk_screenshot", {"max_width": 4096})
    ok = write_png(result, os.path.join(ROOT, name))
    check("gdtk_screenshot -> %s" % name, ok and not result.get("isError"))
    return ok


def crop_png(src_name, dst_name, tl, br):
    try:
        from PIL import Image
    except ImportError:
        check("PIL disponible para recortar %s" % dst_name, True, "sin PIL: se omite el recorte")
        return
    src = os.path.join(ROOT, src_name)
    dst = os.path.join(ROOT, dst_name)
    img = Image.open(src)
    x0 = max(0, int(round(min(tl["x"], br["x"]))))
    y0 = max(0, int(round(min(tl["y"], br["y"]))))
    x1 = min(img.width, int(round(max(tl["x"], br["x"]))))
    y1 = min(img.height, int(round(max(tl["y"], br["y"]))))
    img.crop((x0, y0, x1, y1)).save(dst)
    check("%s recortado %dx%d" % (dst_name, x1 - x0, y1 - y0), x1 > x0 and y1 > y0)


def main():
    client = McpClient()
    try:
        client.send("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "gdtk-flashlight"},
        })
        client.send("notifications/initialized", {}, notify=True)

        client.call_tool("gdtk_open", {"name": "Linterna"})
        time.sleep(3.0)
        state = content_text(client.call_tool("gdtk_state"))
        view = state.get("view") if isinstance(state, dict) else None
        check("Linterna abierta", view == "Linterna", str(view))

        points = state.get("holo_points") if isinstance(state, dict) else None
        if not isinstance(points, dict):
            check("holo_points presente", False, str(state))
            return 1
        for key in ("button", "force_low", "widget_tl", "widget_br"):
            check("holo_points.%s presente" % key, isinstance(points.get(key), dict), str(points.get(key)))

        screen = state.get("holo_screen") if isinstance(state, dict) else None
        check("holo_screen presente",
              isinstance(screen, dict) and screen.get("w", 0) > 40 and screen.get("h", 0) > 40,
              str(screen))

        # 1) Reposo: pantalla APAGADA + recorte del widget compacto apagado.
        shot(client, "flashlight%s.png" % SUFFIX)
        crop_png("flashlight%s.png" % SUFFIX, "flashlight-widget%s.png" % SUFFIX,
                 points["widget_tl"], points["widget_br"])

        # 2) Puntero en 30 pasos sobre la pantalla 3D (cursor por shader), luego click
        #    en ENCENDER/APAGAR.
        if isinstance(screen, dict) and screen.get("w", 0) > 0:
            x0 = screen["x"] + screen["w"] * 0.15
            x1 = screen["x"] + screen["w"] * 0.85
            y = screen["y"] + screen["h"] * 0.35
            for i in range(30):
                t = float(i) / 29.0
                client.call_tool("gdtk_move", {"x": x0 + (x1 - x0) * t, "y": y})
                time.sleep(1.0 / 30.0)
            time.sleep(0.5)

        button = points.get("button")
        if isinstance(button, dict):
            client.call_tool("gdtk_move", {"x": button["x"], "y": button["y"]})
            time.sleep(0.5)
            client.call_tool("gdtk_click", {"x": button["x"], "y": button["y"]})
            time.sleep(1.5)
        shot(client, "flashlight-on%s.png" % SUFFIX)
        crop_png("flashlight-on%s.png" % SUFFIX, "flashlight-widget-on%s.png" % SUFFIX,
                 points["widget_tl"], points["widget_br"])

        # 3) Forzar batería baja con el botón de debug del overlay.
        force = points.get("force_low")
        if isinstance(force, dict):
            client.call_tool("gdtk_move", {"x": force["x"], "y": force["y"]})
            time.sleep(0.5)
            client.call_tool("gdtk_click", {"x": force["x"], "y": force["y"]})
            time.sleep(1.5)
        shot(client, "flashlight-low%s.png" % SUFFIX)
    finally:
        client.close()

    if FAILED:
        print("RESULTADO: FALLO (%d): %s" % (len(FAILED), ", ".join(FAILED)))
        return 1
    print("RESULTADO: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
