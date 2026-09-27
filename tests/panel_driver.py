#!/usr/bin/env python3
"""Verificación del Paso 10 (SPEC-imgui-api.md): actividad Panel por control remoto.

Conduce el shell por el puente MCP (puerto GDTK_CONTROL_PORT, p.ej. 7798) y
guarda en la raíz del repo:
  panel-pie-open.png    anillo radial abierto con el sector "Esfera" resaltado
  panel-pie-done.png    la malla cambió a esfera tras soltar
  panel-implot-demo.png ventana Demo ImPlot abierta desde el menú "Ver"

Coordenadas configurables:
  GDTK_SCENE_X/Y   centro de la imagen de la ventana "Escena"
  GDTK_MENU_X/Y    ítem "Ver" de la barra de menú del Panel
  GDTK_IMPLOT_X/Y  ítem "Demo ImPlot" del menú desplegable
"""

import math
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from mcp_driver import McpClient, FAILED, check, content_text, write_png  # noqa: E402


def shot(client, name):
    result = client.call_tool("gdtk_screenshot", {"max_width": 1280})
    ok = write_png(result, os.path.join(ROOT, name))
    check("gdtk_screenshot -> %s" % name, ok and not result.get("isError"))
    return ok


def mouse_button(client, x, y, button, pressed):
    result = client.call_tool("gdtk_mouse_button",
                              {"x": float(x), "y": float(y), "button": button, "pressed": pressed})
    check("gdtk_mouse_button(%d,%d,b=%d,p=%s)" % (x, y, button, pressed), not result.get("isError"))


def main():
    scene_x = float(os.environ.get("GDTK_SCENE_X", 304))
    scene_y = float(os.environ.get("GDTK_SCENE_Y", 257))
    menu_x = float(os.environ.get("GDTK_MENU_X", 22))
    menu_y = float(os.environ.get("GDTK_MENU_Y", 62))
    implot_x = float(os.environ.get("GDTK_IMPLOT_X", 34))
    implot_y = float(os.environ.get("GDTK_IMPLOT_Y", 96))

    client = McpClient()
    try:
        client.send("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "gdtk-panel"},
        })
        client.send("notifications/initialized", {}, notify=True)

        client.call_tool("gdtk_open", {"name": "Panel"})
        time.sleep(2.0)
        state = content_text(client.call_tool("gdtk_state"))
        check("Panel abierto", isinstance(state, dict) and state.get("view") == "Panel",
              str(state.get("view") if isinstance(state, dict) else state))
        shot(client, "panel-initial.png")

        # Clic derecho sobre la Escena abre el menú radial centrado en el puntero.
        mouse_button(client, scene_x, scene_y, 2, True)
        time.sleep(0.5)

        # Mover al centro del sector "Esfera" (índice 1 de 7, a radio ~70 px).
        angle = -math.pi / 2.0 + 1.5 * (2.0 * math.pi / 7.0)
        hx = scene_x + math.cos(angle) * 70.0
        hy = scene_y + math.sin(angle) * 70.0
        client.call_tool("gdtk_move", {"x": hx, "y": hy})
        time.sleep(0.6)
        shot(client, "panel-pie-open.png")

        mouse_button(client, hx, hy, 2, False)
        time.sleep(0.8)
        shot(client, "panel-pie-done.png")

        # Menú "Ver" -> "Demo ImPlot".
        client.call_tool("gdtk_click", {"x": menu_x, "y": menu_y})
        time.sleep(0.6)
        shot(client, "panel-menu.png")
        client.call_tool("gdtk_click", {"x": implot_x, "y": implot_y})
        time.sleep(2.0)
        shot(client, "panel-implot-demo.png")
    finally:
        client.close()

    if FAILED:
        print("RESULTADO: FALLO (%d): %s" % (len(FAILED), ", ".join(FAILED)))
        return 1
    print("RESULTADO: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
