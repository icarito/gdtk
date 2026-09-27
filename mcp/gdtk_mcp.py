#!/usr/bin/env python3
"""Puente MCP (stdio, JSON-RPC 2.0 por líneas) hacia el shell gdtk.

Cada tools/call abre una conexión TCP a 127.0.0.1:$GDTK_CONTROL_PORT (7777),
se autentica con el token de $XDG_RUNTIME_DIR/gdtk-control.token y cierra.
Sólo stdlib. Logs por stderr.

Uso previsto:
    claude mcp add gdtk -- ssh -T icarito@192.168.18.163 python3 gdtk/mcp/gdtk_mcp.py
"""

import json
import os
import socket
import sys
import time

DEFAULT_PORT = 7777
TIMEOUT = 10.0
PROTOCOL_VERSION = "2024-11-05"
POST_WAIT = 0.3
WAIT_AFTER = {"click", "type", "key", "open", "launch", "home"}


def log(message):
    sys.stderr.write("[gdtk-mcp] %s\n" % message)
    sys.stderr.flush()


def runtime_dir():
    return os.environ.get("XDG_RUNTIME_DIR") or ("/run/user/%d" % os.getuid())


def token_path():
    # Con GDTK_CONTROL_PORT definido el shell nombra el token con el puerto (ver
    # shell/remote.gd): una prueba en otro puerto no pisa el de la sesión real.
    if os.environ.get("GDTK_CONTROL_PORT"):
        name = "gdtk-control-%d.token" % control_port()
    else:
        name = "gdtk-control.token"
    return os.path.join(runtime_dir(), name)


def read_token():
    with open(token_path(), "r") as handle:
        return handle.read().strip()


def control_port():
    raw = os.environ.get("GDTK_CONTROL_PORT")
    try:
        return int(raw) if raw else DEFAULT_PORT
    except ValueError:
        return DEFAULT_PORT


class ShellError(Exception):
    pass


def _exchange(sock_file, request_id, method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
    sock_file.write((payload + "\n").encode("utf-8"))
    sock_file.flush()
    line = sock_file.readline()
    if not line:
        raise ShellError("el shell cerró la conexión antes de responder")
    response = json.loads(line.decode("utf-8"))
    if "error" in response:
        error = response["error"]
        raise ShellError("shell error %s: %s" % (error.get("code"), error.get("message")))
    return response.get("result")


def call_shell(method, params):
    try:
        token = read_token()
    except OSError as exc:
        raise ShellError("no se pudo leer el token (%s): %s" % (token_path(), exc))

    try:
        sock = socket.create_connection(("127.0.0.1", control_port()), timeout=TIMEOUT)
    except OSError as exc:
        raise ShellError("el shell no está corriendo en 127.0.0.1:%d (%s)" % (control_port(), exc))

    sock.settimeout(TIMEOUT)
    try:
        sock_file = sock.makefile("rwb")
        _exchange(sock_file, 1, "auth", {"token": token})
        return _exchange(sock_file, 2, method, params)
    except (OSError, ValueError, ShellError) as exc:
        if isinstance(exc, ShellError):
            raise
        raise ShellError("error de comunicación con el shell: %s" % exc)
    finally:
        sock.close()


def tool(name, description, properties, required=None):
    return {
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required or [],
            "additionalProperties": False,
        },
    }


TOOLS = [
    tool("gdtk_state", "Get the shell state: current view, viewport, wayland socket, windows and activities.", {}),
    tool("gdtk_open", "Open an activity from the home ring by name (e.g. Chat).", {"name": {"type": "string"}}, ["name"]),
    tool("gdtk_home", "Go back to the home screen.", {}),
    tool("gdtk_launch", "Launch a command in the embedded wayland compositor, add it as an activity and open it.", {"cmd": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}}}, ["cmd"]),
    tool("gdtk_close_window", "Close a wayland window by id.", {"id": {"type": "integer"}}, ["id"]),
    tool("gdtk_screenshot", "Capture the shell framebuffer as a base64 PNG.", {"max_width": {"type": "integer"}}),
    tool("gdtk_click", "Click at (x, y) with an optional button and double-click flag.", {"x": {"type": "number"}, "y": {"type": "number"}, "button": {"type": "integer"}, "double": {"type": "boolean"}}, ["x", "y"]),
    tool("gdtk_move", "Move the pointer to (x, y).", {"x": {"type": "number"}, "y": {"type": "number"}}, ["x", "y"]),
    tool("gdtk_scroll", "Scroll the wheel at (x, y); positive dy scrolls down.", {"x": {"type": "number"}, "y": {"type": "number"}, "dy": {"type": "number"}}, ["x", "y", "dy"]),
    tool("gdtk_type", "Type text as synthetic key events.", {"text": {"type": "string"}}, ["text"]),
    tool("gdtk_key", "Press a key or combo such as Enter, Escape, ctrl+c or alt+Tab.", {"combo": {"type": "string"}}, ["combo"]),
]

TOOL_METHOD = {
    "gdtk_state": "state",
    "gdtk_open": "open",
    "gdtk_home": "home",
    "gdtk_launch": "launch",
    "gdtk_close_window": "close_window",
    "gdtk_screenshot": "screenshot",
    "gdtk_click": "click",
    "gdtk_move": "move",
    "gdtk_scroll": "scroll",
    "gdtk_type": "type",
    "gdtk_key": "key",
}


def tool_result(content, is_error=False):
    return {"content": [content], "isError": is_error}


def handle_tool_call(params):
    name = params.get("name", "")
    arguments = params.get("arguments") or {}
    if name not in TOOL_METHOD:
        return tool_result({"type": "text", "text": "unknown tool: %s" % name}, True)
    method = TOOL_METHOD[name]
    try:
        result = call_shell(method, arguments)
    except ShellError as exc:
        log("%s failed: %s" % (name, exc))
        return tool_result({"type": "text", "text": str(exc)}, True)

    if name == "gdtk_screenshot":
        content = {"type": "image", "data": result.get("png_base64", ""), "mimeType": "image/png"}
    else:
        content = {"type": "text", "text": json.dumps(result)}

    if method in WAIT_AFTER:
        time.sleep(POST_WAIT)
    return tool_result(content, False)


def handle(request):
    method = request.get("method", "")
    request_id = request.get("id")
    params = request.get("params") or {}

    if method == "initialize":
        requested = params.get("protocolVersion") or PROTOCOL_VERSION
        return {"jsonrpc": "2.0", "id": request_id, "result": {
            "protocolVersion": requested,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "gdtk", "version": "0.1.0"},
        }}
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": request_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}}
    if method == "tools/call":
        return {"jsonrpc": "2.0", "id": request_id, "result": handle_tool_call(params)}
    if method.startswith("notifications/"):
        return None
    return {"jsonrpc": "2.0", "id": request_id,
            "error": {"code": -32601, "message": "method not found: %s" % method}}


def main():
    log("listening on stdio")
    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError as exc:
            log("parse error: %s" % exc)
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": None,
                "error": {"code": -32700, "message": "parse error"}}) + "\n")
            sys.stdout.flush()
            continue
        response = handle(request)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
