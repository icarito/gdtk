#!/usr/bin/env python3
"""Driver del test de control remoto (Paso 6).

Por defecto habla con mcp/gdtk_mcp.py por stdio y ejecuta la secuencia completa.
Con `--negative` comprueba que un auth con token incorrecto devuelve -32001.
"""

import base64
import json
import os
import select
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MCP = os.path.join(ROOT, "mcp", "gdtk_mcp.py")
DEFAULT_PORT = 7777

FAILED = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    line = "[%s] %s" % (status, label)
    if detail:
        line += " — " + detail
    print(line)
    sys.stdout.flush()
    if not condition:
        FAILED.append(label)


class McpClient:
    def __init__(self):
        log_path = os.path.join(tempfile.gettempdir(), "gdtk-mcp-driver.log")
        self._log = open(log_path, "wb")
        self.proc = subprocess.Popen(
            [sys.executable, MCP],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._log,
        )
        self.next_id = 1

    def _readline(self, timeout=20):
        ready = select.select([self.proc.stdout], [], [], timeout)
        if not ready[0]:
            raise RuntimeError("timeout esperando respuesta del puente MCP")
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("el puente MCP cerró la salida")
        return json.loads(line.decode("utf-8"))

    def send(self, method, params=None, notify=False):
        request = {"jsonrpc": "2.0", "method": method}
        if not notify:
            request["id"] = self.next_id
            self.next_id += 1
        if params is not None:
            request["params"] = params
        self.proc.stdin.write((json.dumps(request) + "\n").encode("utf-8"))
        self.proc.stdin.flush()
        if notify:
            return None
        return self._readline()

    def call_tool(self, name, arguments=None):
        response = self.send("tools/call", {"name": name, "arguments": arguments or {}})
        return response.get("result", {})

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self._log.close()


def content_text(result):
    for item in result.get("content", []):
        if item.get("type") == "text":
            try:
                return json.loads(item.get("text", ""))
            except ValueError:
                return item.get("text", "")
    return None


def content_image(result):
    for item in result.get("content", []):
        if item.get("type") == "image":
            return item.get("data", "")
    return ""


def write_png(result, path):
    data = content_image(result)
    if not data:
        return False
    with open(path, "wb") as handle:
        handle.write(base64.b64decode(data))
    return True


def run_full():
    client = McpClient()
    try:
        result = client.send("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "gdtk-test"},
        })
        info = result.get("result", {})
        check("initialize responde protocolVersion pedido",
              info.get("protocolVersion") == "2025-06-18", str(info.get("protocolVersion")))
        check("initialize capabilities.tools",
              "tools" in (info.get("capabilities") or {}))
        check("initialize serverInfo.name == gdtk",
              (info.get("serverInfo") or {}).get("name") == "gdtk")

        client.send("notifications/initialized", {}, notify=True)

        result = client.send("tools/list")
        tools = result.get("result", {}).get("tools", [])
        check("tools/list >= 11 tools", len(tools) >= 11, "%d tools" % len(tools))

        result = client.call_tool("gdtk_state")
        state = content_text(result)
        check("gdtk_state view=home", isinstance(state, dict) and state.get("view") == "home",
              json.dumps(state)[:200] if state else str(result))

        # Ya no hay actividades internas de demo (Chat/Panel): se abre una ventana
        # real (es2gears) y se ejercita el puente de input por RPC sobre ella.
        result = client.call_tool("gdtk_home")
        check("gdtk_home sin error", not result.get("isError"))

        result = client.call_tool("gdtk_launch", {"cmd": "es2gears_wayland"})
        payload = content_text(result)
        pid = payload.get("pid") if isinstance(payload, dict) else None
        check("gdtk_launch es2gears_wayland con pid", not result.get("isError") and (pid or -1) >= 0,
              str(payload))

        time.sleep(3.0)
        state = content_text(client.call_tool("gdtk_state"))
        windows = state.get("windows", []) if isinstance(state, dict) else []
        check("gdtk_state una ventana tras launch", len(windows) == 1, str(windows))

        # Clic y tecleo: sólo se ejercita la vía (es2gears no consume el texto).
        viewport = state.get("viewport", [1280, 683]) if isinstance(state, dict) else [1280, 683]
        click_x = float(os.environ.get("GDTK_TEST_CLICK_X", viewport[0] * 0.5))
        click_y = float(os.environ.get("GDTK_TEST_CLICK_Y", viewport[1] * 0.5))
        result = client.call_tool("gdtk_click", {"x": click_x, "y": click_y})
        check("gdtk_click", not result.get("isError"), "x=%.0f y=%.0f" % (click_x, click_y))
        check("gdtk_type", not client.call_tool("gdtk_type", {"text": "hola mcp\n"}).get("isError"))

        result = client.call_tool("gdtk_screenshot", {"max_width": 1280})
        ok = write_png(result, os.path.join(ROOT, "mcp-gears.png"))
        check("gdtk_screenshot -> mcp-gears.png", ok and not result.get("isError"))
    finally:
        client.close()


def run_negative():
    port = int(os.environ.get("GDTK_CONTROL_PORT") or DEFAULT_PORT)
    request = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "auth",
                          "params": {"token": "deadbeef" * 4}}) + "\n"
    sock = None
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=10)
        sock_file = sock.makefile("rwb")
        sock_file.write(request.encode("utf-8"))
        sock_file.flush()
        line = sock_file.readline()
        response = json.loads(line.decode("utf-8"))
        code = (response.get("error") or {}).get("code")
        check("token incorrecto -> -32001", code == -32001, json.dumps(response))
    except OSError as exc:
        check("conexión TCP para test negativo", False, str(exc))
    finally:
        if sock is not None:
            sock.close()


def main():
    if "--negative" in sys.argv:
        run_negative()
    else:
        run_full()
    if FAILED:
        print("RESULTADO: FALLO (%d): %s" % (len(FAILED), ", ".join(FAILED)))
        return 1
    print("RESULTADO: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
