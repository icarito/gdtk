#!/usr/bin/env python3
"""Verificación del Paso 8 (SPEC-windows.md).

Conduce el shell por el puente MCP (tests/mcp_driver.py) y guarda los PNG
pedidos en la raíz del repo:
  win-gtk.png / win-menu.png   (auxiliares para ubicar el menú)
  win-about.png                diálogo About centrado sobre la widget factory
  win-about-closed.png         diálogo cerrado y la ventana responde
  win-firefox.png              ventana suelta abierta como actividad dinámica
  win-ring.png                 la actividad nueva en el anillo al volver a home
  win-ring-closed.png          la actividad dinámica desaparece al cerrar

Coordenadas configurables por entorno:
  GDTK_MENU_X/Y    botón ☰ de la widget factory
  GDTK_ABOUT_X/Y   ítem About del menú
  GDTK_CHECK_X/Y   un checkbutton de la widget factory
  GDTK_DYN_CMD     comando a teclear en la Terminal (default "firefox")
"""

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from mcp_driver import McpClient, FAILED, check, content_text, write_png  # noqa: E402


def shell_state(client):
    value = content_text(client.call_tool("gdtk_state"))
    return value if isinstance(value, dict) else {}


def windows(client):
    return shell_state(client).get("windows", [])


def activities(client):
    return shell_state(client).get("activities", [])


def wait_for(fn, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            value = fn()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(0.3)
    return None


def shot(client, name):
    result = client.call_tool("gdtk_screenshot", {"max_width": 1280})
    ok = write_png(result, os.path.join(ROOT, name))
    check("gdtk_screenshot -> %s" % name, ok and not result.get("isError"))
    return ok


def click(client, x, y):
    client.call_tool("gdtk_click", {"x": float(x), "y": float(y)})


def env_xy(prefix, dx, dy):
    return float(os.environ.get("GDTK_%s_X" % prefix, dx)), float(os.environ.get("GDTK_%s_Y" % prefix, dy))


def activate_about_dbus():
    """Abre el diálogo About con la acción `app.about` por D-Bus.

    En este entorno el header CSD de la widget factory queda recortado por la
    vista 1:1 (se alinea `get_geometry`, que empieza debajo de la barra de
    título), así que el ☰ no es clickeable; se invoca la misma acción que
    dispararía ese item de menú.
    """
    try:
        listing = subprocess.check_output(["busctl", "--user", "list"], stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        return False
    bus = ""
    for line in listing.decode("utf-8", "replace").splitlines():
        if "gtk4-widget-fac" in line and line.startswith(":"):
            bus = line.split()[0]
            break
    if bus == "":
        return False
    try:
        subprocess.run([
            "gdbus", "call", "--session", "--dest", bus,
            "--object-path", "/org/gtk/WidgetFactory4",
            "--method", "org.gtk.Actions.Activate",
            "about", "[]", "{}",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        return True
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False


def scenario_about(client):
    print("== 1) diálogo About sobre su padre ==")
    client.call_tool("gdtk_open", {"name": "GTK"})
    win = wait_for(lambda: next((w for w in windows(client) if w.get("activity") == "GTK"), None), 30)
    check("ventana GTK visible", win is not None, str(win))
    time.sleep(1.0)
    shot(client, "win-gtk.png")

    menu_x, menu_y = env_xy("MENU", 24, 71)
    click(client, menu_x, menu_y)
    time.sleep(0.8)
    shot(client, "win-menu.png")
    about_x, about_y = env_xy("ABOUT", 110, 300)
    click(client, about_x, about_y)

    dialog = wait_for(lambda: next((w for w in windows(client) if w.get("parent", 0) > 0), None), 3)
    mode = "click"
    if dialog is None:
        print("el ☰ no es clickeable (header CSD recortado); activando app.about por D-Bus")
        check("activar app.about por D-Bus", activate_about_dbus())
        dialog = wait_for(lambda: next((w for w in windows(client) if w.get("parent", 0) > 0), None), 10)
        mode = "dbus"
    check("aparece un diálogo con parent", dialog is not None, "%s %s" % (mode, dialog))
    time.sleep(1.2)
    shot(client, "win-about.png")

    client.call_tool("gdtk_key", {"combo": "Escape"})
    closed = wait_for(lambda: not any(w.get("parent", 0) > 0 for w in windows(client)), 10)
    check("el diálogo se cierra", closed)
    time.sleep(0.5)
    shot(client, "win-about-closed.png")

    check_x, check_y = env_xy("CHECK", 19, 471)
    click(client, check_x, check_y)
    time.sleep(0.4)
    shot(client, "win-check.png")


def scenario_dynamic(client):
    print("== 2) ventana suelta -> actividad dinámica ==")
    client.call_tool("gdtk_home")
    time.sleep(0.3)
    client.call_tool("gdtk_open", {"name": "Terminal"})
    term = wait_for(lambda: next((w for w in windows(client) if w.get("activity") == "Terminal"), None), 30)
    check("ventana Terminal visible", term is not None, str(term))
    time.sleep(1.0)

    vp = shell_state(client).get("viewport", [1280, 683])
    click(client, vp[0] * 0.5, vp[1] * 0.5)
    time.sleep(0.3)

    before = set(activities(client))
    cmd = os.environ.get("GDTK_DYN_CMD", "firefox")
    client.call_tool("gdtk_type", {"text": cmd + "\n"})

    new_name = wait_for(lambda: (set(activities(client)) - before) or None, 25)
    if new_name is None:
        check("aparece una actividad dinámica en <= 25 s", False, str(activities(client)))
        return
    name = sorted(new_name)[0]
    print("actividad dinámica:", name)
    check("aparece una actividad dinámica en <= 25 s", True, name)
    time.sleep(1.5)
    shot(client, "win-firefox.png")

    client.call_tool("gdtk_home")
    time.sleep(0.5)
    shot(client, "win-ring.png")
    check("la actividad dinámica está en el anillo", name in activities(client))

    dynamic_window = next((w for w in windows(client) if w.get("activity") == name), None)
    check("hay ventana para la actividad dinámica", dynamic_window is not None, str(dynamic_window))
    if dynamic_window is not None:
        client.call_tool("gdtk_close_window", {"id": dynamic_window["id"]})
        gone = wait_for(lambda: name not in activities(client), 10)
        check("al cerrar, la actividad dinámica desaparece del anillo", gone)
        time.sleep(0.5)
        shot(client, "win-ring-closed.png")


def main():
    client = McpClient()
    try:
        client.send("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "gdtk-windows"},
        })
        client.send("notifications/initialized", {}, notify=True)
        scenario_about(client)
        scenario_dynamic(client)
    finally:
        client.close()

    if FAILED:
        print("RESULTADO: FALLO (%d): %s" % (len(FAILED), ", ".join(FAILED)))
        return 1
    print("RESULTADO: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
