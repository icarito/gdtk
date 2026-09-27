#!/usr/bin/env python3
"""Verificación del HUD de debug (SPEC-hud C) por control remoto.

Conduce un shell en la actividad Panel por el puente MCP y guarda en la raíz
del repo:
  hud-graficas.png  HUD completo, pestana Graficas (F1)
  hud-consola.png   pestana Consola con un error en rojo y un print
  hud-mini.png      HUD cerrado: solo el widget mini

Coordenadas configurables con GDTK_HUD_TAB_X/Y y GDTK_HUD_CMD_X/Y.
"""

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


def main():
    tab_x = float(os.environ.get("GDTK_HUD_TAB_X", 218))
    tab_y = float(os.environ.get("GDTK_HUD_TAB_Y", 92))
    cmd_x = float(os.environ.get("GDTK_HUD_CMD_X", 400))
    cmd_y = float(os.environ.get("GDTK_HUD_CMD_Y", 596))

    client = McpClient()
    try:
        client.send("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "gdtk-hud"},
        })
        client.send("notifications/initialized", {}, notify=True)

        client.call_tool("gdtk_open", {"name": "Panel"})
        time.sleep(2.5)
        state = content_text(client.call_tool("gdtk_state"))
        check("Panel abierto", isinstance(state, dict) and state.get("view") == "Panel",
              str(state.get("view") if isinstance(state, dict) else state))

        # F1: HUD completo en la pestana Graficas.
        client.call_tool("gdtk_key", {"combo": "F1"})
        time.sleep(1.5)
        shot(client, "hud-graficas.png")

        # Pestana Consola.
        client.call_tool("gdtk_click", {"x": tab_x, "y": tab_y})
        time.sleep(0.8)
        shot(client, "hud-consola-tab.png")

        # Enfocar el campo de comando y provocar un print + un error. El control
        # remoto inyecta un evento por frame, asi que se espera de sobra.
        client.call_tool("gdtk_click", {"x": cmd_x, "y": cmd_y})
        time.sleep(0.8)
        client.call_tool("gdtk_type", {"text": "help\n"})
        time.sleep(2.5)
        client.call_tool("gdtk_click", {"x": cmd_x, "y": cmd_y})
        time.sleep(0.8)
        client.call_tool("gdtk_type", {"text": "foo\n"})
        time.sleep(2.5)
        shot(client, "hud-consola.png")

        # F1 de nuevo: solo el widget mini.
        client.call_tool("gdtk_key", {"combo": "F1"})
        time.sleep(1.5)
        shot(client, "hud-mini.png")
    finally:
        client.close()

    if FAILED:
        print("RESULTADO: FALLO (%d): %s" % (len(FAILED), ", ".join(FAILED)))
        return 1
    print("RESULTADO: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
