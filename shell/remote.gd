extends Node

# Paso 6: control remoto del shell por JSON-RPC 2.0 sobre TCP en localhost.
# El acceso remoto es por ssh; el token vive en $XDG_RUNTIME_DIR (0700 del usuario).

const DEFAULT_PORT = 7777
const LINE_FEED = 10

onready var shell = get_parent()

var server = null
var token = ""
var token_path = ""
var cleaned = false
var connections = []
var event_queue = []


func _ready():
	var runtime_dir = OS.get_environment("XDG_RUNTIME_DIR")
	if runtime_dir == "":
		printerr("Remote: XDG_RUNTIME_DIR no está definido; no se abre el servidor")
		return

	token = Crypto.new().generate_random_bytes(16).hex_encode()
	token_path = runtime_dir.plus_file("gdtk-control.token")
	var file = File.new()
	var err = file.open(token_path, File.WRITE)
	if err != OK:
		printerr("Remote: no se pudo escribir el token en ", token_path, " (error ", err, ")")
		token = ""
		return
	file.store_string(token)
	file.close()
	_start_watchdog()

	var port = DEFAULT_PORT
	var env_port = OS.get_environment("GDTK_CONTROL_PORT")
	if env_port != "":
		port = int(env_port)

	server = TCP_Server.new()
	var lerr = server.listen(port, "127.0.0.1")
	if lerr != OK:
		printerr("Remote: no se pudo escuchar en 127.0.0.1:", port, " (error ", lerr, ")")
		server = null
		_remove_token()
		return

	print("Remote: escuchando en 127.0.0.1:", port)
	set_process(true)


func _notification(what):
	if what == NOTIFICATION_WM_QUIT_REQUEST or what == NOTIFICATION_EXIT_TREE:
		_cleanup()


func _exit_tree():
	_cleanup()


func _cleanup():
	if cleaned:
		return
	cleaned = true
	if server != null:
		server.stop()
		server = null
	for conn in connections:
		if conn.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			conn.peer.disconnect_from_host()
	connections = []
	_remove_token()


func _remove_token():
	if token_path != "" and token != "":
		var dir = Directory.new()
		dir.remove(token_path)
		token = ""


# Si el motor muere sin pasar por _exit_tree (p.ej. al matar cage, que deja caer el display
# y termina el proceso de golpe), este vigilante borra el token en cuanto el shell desaparece.
# Va en su propia sesión y cierra los fds heredados (si no, retendría el socket Wayland y cage
# no terminaría al salir el cliente).
func _start_watchdog():
	var close_fds = "i=3; while [ $i -le 64 ]; do eval \"exec $i>&-\" 2>/dev/null; i=$((i+1)); done; "
	var loop = "while kill -0 %d 2>/dev/null; do sleep 1; done; rm -f '%s'" % [OS.get_process_id(), token_path]
	OS.execute("setsid", ["sh", "-c", close_fds + loop], false)


func _process(delta):
	if server == null:
		return

	while server.is_connection_available():
		var peer = server.take_connection()
		peer.set_no_delay(true)
		connections.append({"peer": peer, "buf": PoolByteArray(), "authed": false, "close": false})

	for i in range(connections.size() - 1, -1, -1):
		var conn = connections[i]
		_poll_connection(conn)
		if conn.close:
			if conn.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				conn.peer.disconnect_from_host()
			connections.remove(i)

	if event_queue.size() > 0:
		Input.parse_input_event(event_queue.pop_front())


func _poll_connection(conn):
	var peer = conn.peer
	var status = peer.get_status()
	if status != StreamPeerTCP.STATUS_CONNECTED:
		conn.close = true
		return
	var available = peer.get_available_bytes()
	if available > 0:
		var data = peer.get_partial_data(available)
		if data[0] == OK:
			var buf = conn.buf
			buf.append_array(data[1])
			conn.buf = buf
	while true:
		var idx = -1
		for i in range(conn.buf.size()):
			if conn.buf[i] == LINE_FEED:
				idx = i
				break
		if idx < 0:
			break
		var line_bytes = null
		if idx > 0:
			line_bytes = conn.buf.subarray(0, idx - 1)
		if idx + 1 <= conn.buf.size() - 1:
			conn.buf = conn.buf.subarray(idx + 1, conn.buf.size() - 1)
		else:
			conn.buf = PoolByteArray()
		if line_bytes != null:
			var line = line_bytes.get_string_from_utf8().strip_edges()
			if line != "":
				_handle_line(conn, line)


func _send(conn, obj):
	var line = JSON.print(obj) + "\n"
	conn.peer.put_data(line.to_utf8())


func _reply(conn, id, result):
	_send(conn, {"jsonrpc": "2.0", "id": id, "result": result})


func _fail(conn, id, code, message):
	_send(conn, {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})


func _handle_line(conn, line):
	var parsed = JSON.parse(line)
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		_fail(conn, null, -32700, "parse error")
		return

	var req = parsed.result
	var id = req.get("id", null)
	var method = str(req.get("method", ""))
	var params = req.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}

	if method == "auth":
		if token != "" and str(params.get("token", "")) == token:
			conn.authed = true
			_reply(conn, id, true)
		else:
			_fail(conn, id, -32001, "unauthorized")
			conn.close = true
		return

	if not conn.authed:
		_fail(conn, id, -32001, "unauthorized")
		conn.close = true
		return

	match method:
		"state":
			_reply(conn, id, _state())
		"open":
			shell._open_by_name(str(params.get("name", "")))
			_reply(conn, id, true)
		"home":
			shell._go_home()
			_reply(conn, id, true)
		"launch":
			_launch(conn, id, params)
		"close_window":
			shell.compositor.close(int(params.get("id", -1)))
			_reply(conn, id, true)
		"screenshot":
			_reply(conn, id, _screenshot(params))
		"click":
			_click(params)
			_reply(conn, id, true)
		"move":
			_move(params)
			_reply(conn, id, true)
		"scroll":
			_scroll(params)
			_reply(conn, id, true)
		"type":
			_type(params)
			_reply(conn, id, true)
		"key":
			_key(params)
			_reply(conn, id, true)
		"quit":
			_reply(conn, id, true)
			get_tree().quit()
		_:
			_fail(conn, id, -32601, "method not found: " + method)


func _state():
	var vp = shell.get_viewport_rect().size
	var view = "home"
	if shell.current_activity != null:
		view = shell.current_activity.name

	var windows = []
	for window_id in shell.compositor.get_ids():
		var activity = ""
		for name in shell.wayland_ids.keys():
			if shell.wayland_ids[name] == window_id:
				activity = name
		windows.append({
			"id": window_id,
			"title": shell.compositor.get_title(window_id),
			"activity": activity,
			"parent": shell.compositor.get_parent_id(window_id),
		})

	var activities = []
	for activity in _activity_list():
		activities.append(activity.name)

	return {
		"view": view,
		"viewport": [vp.x, vp.y],
		"wayland_socket": shell.compositor.start(),
		"windows": windows,
		"activities": activities,
	}


func _activity_list():
	var script = shell.get_script()
	if script != null and script.has_method("get_script_constant_map"):
		var map = script.get_script_constant_map()
		if map.has("ACTIVITIES"):
			return map["ACTIVITIES"]
	return shell.ACTIVITIES


func _launch(conn, id, params):
	var cmd = str(params.get("cmd", ""))
	if cmd == "":
		_fail(conn, id, -32602, "invalid params: cmd requerido")
		return
	var raw_args = params.get("args", [])
	var args = []
	if typeof(raw_args) == TYPE_ARRAY:
		for arg in raw_args:
			args.append(str(arg))

	_ensure_activity(cmd, args)
	shell.last_launch_pid = -1
	shell._open_by_name(cmd)
	_reply(conn, id, {"pid": shell.last_launch_pid})


func _ensure_activity(cmd, args):
	var list = _activity_list()
	for activity in list:
		if activity.has("name") and activity.name == cmd:
			return
	var entry = {"name": cmd, "wayland": [cmd]}
	for arg in args:
		entry.wayland.append(arg)
	shell.ACTIVITIES.append(entry)


func _screenshot(params):
	var max_width = int(params.get("max_width", 1280))
	var image = get_viewport().get_texture().get_data()
	image.flip_y()
	if max_width > 0 and image.get_width() > max_width:
		var height = int(round(float(image.get_height()) * float(max_width) / float(image.get_width())))
		image.resize(max_width, height, Image.INTERPOLATE_BILINEAR)
	var png = image.save_png_to_buffer()
	return {"png_base64": Marshalls.raw_to_base64(png)}


func _event_mouse_motion(x, y):
	var event = InputEventMouseMotion.new()
	event.position = Vector2(x, y)
	event.global_position = Vector2(x, y)
	return event


func _event_mouse_button(x, y, button, pressed, double):
	var event = InputEventMouseButton.new()
	event.position = Vector2(x, y)
	event.global_position = Vector2(x, y)
	event.button_index = button
	event.pressed = pressed
	event.doubleclick = double
	return event


func _click(params):
	var x = float(params.get("x", 0.0))
	var y = float(params.get("y", 0.0))
	var button = int(params.get("button", BUTTON_LEFT))
	var double = bool(params.get("double", false))
	event_queue.push_back(_event_mouse_motion(x, y))
	event_queue.push_back(_event_mouse_button(x, y, button, true, double))
	event_queue.push_back(_event_mouse_button(x, y, button, false, double))


func _move(params):
	event_queue.push_back(_event_mouse_motion(float(params.get("x", 0.0)), float(params.get("y", 0.0))))


func _scroll(params):
	var x = float(params.get("x", 0.0))
	var y = float(params.get("y", 0.0))
	var dy = float(params.get("dy", 0.0))
	event_queue.push_back(_event_mouse_motion(x, y))
	var steps = int(abs(dy))
	if steps < 1:
		steps = 1
	var button = BUTTON_WHEEL_DOWN if dy > 0.0 else BUTTON_WHEEL_UP
	for i in range(steps):
		event_queue.push_back(_event_mouse_button(x, y, button, true, false))
		event_queue.push_back(_event_mouse_button(x, y, button, false, false))


func _type(params):
	var text = str(params.get("text", ""))
	for i in range(text.length()):
		var ch = text.substr(i, 1)
		var base = _key_event_for_char(ch)
		if base == null:
			continue
		var press = base.duplicate()
		press.pressed = true
		var release = base.duplicate()
		release.pressed = false
		event_queue.push_back(press)
		event_queue.push_back(release)


func _key_event_for_char(ch):
	var event = InputEventKey.new()
	if ch == "\n":
		event.unicode = 10
		event.scancode = KEY_ENTER
		event.physical_scancode = KEY_ENTER
		return event
	if ch == "\t":
		event.unicode = 9
		event.scancode = KEY_TAB
		event.physical_scancode = KEY_TAB
		return event
	if ch == " ":
		event.unicode = 32
		event.scancode = KEY_SPACE
		event.physical_scancode = KEY_SPACE
		return event
	var lower = ch.to_lower()
	var code = OS.find_scancode_from_string(lower)
	if code == 0:
		return null
	event.unicode = ord(ch)
	event.scancode = code
	event.physical_scancode = code
	if ch != lower:
		event.shift = true
	return event


func _key(params):
	var combo = str(params.get("combo", ""))
	if combo == "":
		return
	var parts = combo.split("+")
	var key_name = parts[parts.size() - 1]
	var code = OS.find_scancode_from_string(key_name)
	if code == 0:
		return
	var modifier_codes = []
	var shift = false
	var control = false
	var alt = false
	var meta = false
	for i in range(parts.size() - 1):
		match parts[i].to_lower():
			"ctrl", "control":
				control = true
				modifier_codes.append(KEY_CONTROL)
			"alt":
				alt = true
				modifier_codes.append(KEY_ALT)
			"shift":
				shift = true
				modifier_codes.append(KEY_SHIFT)
			"meta", "super", "cmd":
				meta = true
				modifier_codes.append(KEY_META)

	for modifier in modifier_codes:
		event_queue.push_back(_modifier_event(modifier, true))
	var press = InputEventKey.new()
	press.scancode = code
	press.physical_scancode = code
	press.shift = shift
	press.control = control
	press.alt = alt
	press.meta = meta
	press.pressed = true
	var release = press.duplicate()
	release.pressed = false
	event_queue.push_back(press)
	event_queue.push_back(release)
	for i in range(modifier_codes.size() - 1, -1, -1):
		event_queue.push_back(_modifier_event(modifier_codes[i], false))


func _modifier_event(code, pressed):
	var event = InputEventKey.new()
	event.scancode = code
	event.physical_scancode = code
	event.pressed = pressed
	return event
