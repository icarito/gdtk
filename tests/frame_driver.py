#!/usr/bin/env python3
"""Verificación del Frame (shell/frame.gd): apps abiertas, cambio y cierre.

Requiere el shell corriendo, p.ej.:
  GDTK_CONTROL_PORT=7802 session/gdtk-session &
  GDTK_CONTROL_PORT=7802 tests/frame_driver.py
PNG en la raíz:
  frame-home.png    Frame fijo en el Home con lo que corre
  frame-f6.png      F6 sobre una app: Frame encima, la actual resaltada
  frame-switch.png  clic en otra entrada: cambia y el Frame se oculta
  frame-corner.png  mouse en la esquina superior izquierda ~250 ms
  frame-edge.png    mouse contra el borde superior (x en el medio) ~250 ms
  frame-closed.png  cerrar una ventana desde su "x"
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from windows_driver import shell_state, windows, wait_for, shot, click  # noqa: E402
from mcp_driver import McpClient, FAILED, check  # noqa: E402

APPS = ["Terminal", "Gears", "GTK"]


def frame(client):
    return shell_state(client).get("frame", {})


def item(client, activity_or_title):
    ids = {w["id"]: w.get("activity", "") for w in windows(client)}
    for it in frame(client).get("items", []):
        if activity_or_title in (it["title"], ids.get(it["id"], "")):
            return it
    return None


def key(client, combo):
    client.call_tool("gdtk_key", {"combo": combo})
    time.sleep(0.3)


def main():
    client = McpClient()
    try:
        client.send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                   "clientInfo": {"name": "gdtk-frame"}})
        client.send("notifications/initialized", {}, notify=True)

        for name in APPS:
            client.call_tool("gdtk_open", {"name": name})
            win = wait_for(lambda: any(w.get("activity") == name for w in windows(client)), 30)
            check("abre " + name, win)
            time.sleep(1.0)
        check("con una app al frente el Frame está oculto", not frame(client).get("visible"))

        client.call_tool("gdtk_home")
        time.sleep(0.5)
        check("las apps siguen vivas en el Home", len([w for w in windows(client) if w.get("parent", 0) <= 0]) >= 3)
        f = frame(client)
        check("Home: Frame visible con las 3 apps", f.get("visible") and len(f.get("items", [])) >= 3, str(f))
        shot(client, "frame-home.png")

        client.call_tool("gdtk_open", {"name": "GTK"})
        time.sleep(0.8)
        key(client, "F6")
        f = frame(client)
        cur = [it for it in f.get("items", []) if it["current"]]
        check("F6 muestra el Frame con la actual resaltada", f.get("visible") and len(cur) == 1
              and item(client, "GTK") == cur[0], str(f))
        shot(client, "frame-f6.png")

        term = item(client, "Terminal")
        click(client, term["x"] + 20, term["y"] + 10)
        time.sleep(0.8)
        st = shell_state(client)
        check("clic cambia a Terminal y oculta el Frame", st.get("view") == "Terminal"
              and not st["frame"]["visible"], st.get("view"))
        shot(client, "frame-switch.png")

        client.call_tool("gdtk_move", {"x": 0, "y": 0})
        time.sleep(0.3)
        client.call_tool("gdtk_move", {"x": 1, "y": 1})
        check("esquina caliente muestra el Frame", wait_for(lambda: frame(client).get("visible"), 3))
        shot(client, "frame-corner.png")
        client.call_tool("gdtk_move", {"x": 600, "y": 400})
        check("sacar el mouse lo oculta", wait_for(lambda: not frame(client).get("visible"), 3))

        before = shell_state(client).get("view")
        key(client, "alt+Tab")
        after = shell_state(client).get("view")
        check("Alt+Tab cambia de app sin Frame", after != before and after != "home"
              and not frame(client).get("visible"), "%s -> %s" % (before, after))

        key(client, "F6")
        key(client, "Escape")
        check("Esc oculta el Frame", wait_for(lambda: not frame(client).get("visible"), 2))

        # Super sola alterna el Frame; Super+tecla es de la app y no lo toca.
        key(client, "Super_L")
        check("Super sola muestra el Frame", wait_for(lambda: frame(client).get("visible"), 2))
        key(client, "Super_L")
        check("Super sola lo oculta", wait_for(lambda: not frame(client).get("visible"), 2))
        key(client, "super+a")
        time.sleep(0.3)
        check("Super+tecla no muestra el Frame", not frame(client).get("visible"))
        key(client, "Super_R")
        check("Super derecha también", wait_for(lambda: frame(client).get("visible"), 2))
        key(client, "Super_R")
        wait_for(lambda: not frame(client).get("visible"), 2)

        # Borde superior, x en el medio: el mouse quieto ~250 ms contra el borde.
        client.call_tool("gdtk_move", {"x": 600, "y": 400})
        time.sleep(0.3)
        client.call_tool("gdtk_move", {"x": 640, "y": 0})
        check("borde superior muestra el Frame", wait_for(lambda: frame(client).get("visible"), 3))
        shot(client, "frame-edge.png")
        client.call_tool("gdtk_move", {"x": 600, "y": 400})
        check("bajar del borde lo oculta", wait_for(lambda: not frame(client).get("visible"), 3))
        # Clic en el borde antes de cumplirse la espera (pestaña pegada arriba): no se muestra.
        click(client, 300, 0)
        time.sleep(0.8)
        check("clic en el borde no muestra el Frame", not frame(client).get("visible"))
        client.call_tool("gdtk_move", {"x": 600, "y": 400})
        time.sleep(0.3)

        key(client, "F6")
        gears = item(client, "Gears")
        gid = gears["id"]
        click(client, gears["close_x"] + 10, gears["y"] + 10)
        gone = wait_for(lambda: all(w["id"] != gid for w in windows(client)), 10)
        check("la x cierra Gears (xdg close)", gone)
        time.sleep(0.5)
        key(client, "F6") if not frame(client).get("visible") else None
        shot(client, "frame-closed.png")

        client.call_tool("gdtk_open", {"name": "Terminal"})
        time.sleep(2.5)
        client.call_tool("gdtk_home")
        time.sleep(0.5)
        check("la actividad interna sigue en el Frame tras ir al Home", item(client, "Terminal") is not None)
    finally:
        client.close()

    if FAILED:
        print("RESULTADO: FALLO (%d): %s" % (len(FAILED), ", ".join(FAILED)))
        return 1
    print("RESULTADO: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
