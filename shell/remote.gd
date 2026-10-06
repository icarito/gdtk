extends Node

# Paso 6: control remoto del shell por JSON-RPC 2.0 sobre TCP en localhost.
# El acceso remoto es por ssh; el token vive en $XDG_RUNTIME_DIR (0700 del usuario).

const DEFAULT_PORT = 7777
const LINE_FEED = 10

var shell = null  # lo setea Host/Main (sobrevive a la recarga del shell)

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

	var port = DEFAULT_PORT
	var env_port = OS.get_environment("GDTK_CONTROL_PORT")
	if env_port != "":
		port = int(env_port)

	token = Crypto.new().generate_random_bytes(16).hex_encode()
	# Con GDTK_CONTROL_PORT definido el token lleva el puerto en el nombre: una
	# prueba en otro puerto no pisa el token de una sesión real (sin la variable
	# se conserva el nombre de siempre).
	token_path = runtime_dir.plus_file("gdtk-control.token")
	if env_port != "":
		token_path = runtime_dir.plus_file("gdtk-control-%d.token" % port)

	# Escuchar ANTES de escribir el token: si otra instancia de Remote (p. ej. tras
	# una recarga) ya tiene el puerto, esta no debe pisar ni borrar su token. El
	# orden viejo escribía el token y, al fallar el listen, lo borraba: dejaba al
	# shell vivo sin token y rompía a todos los clientes del RPC (gestos, MCP).
	_port = port
	set_process(true)
	_open()


# Tras recargar (Host.reload_remote) el Remote viejo acaba de soltar el puerto y el
# bind puede fallar un rato (ERR_ALREADY_IN_USE): se reintenta cada LISTEN_RETRY_MS en
# vez de dejar al shell sin RPC hasta el próximo reinicio.
const LISTEN_RETRY_MS = 1000
var _port = 0
var _retry_at = 0


func _open():
	_retry_at = OS.get_ticks_msec() + LISTEN_RETRY_MS
	server = TCP_Server.new()
	var lerr = server.listen(_port, "127.0.0.1")
	if lerr != OK:
		printerr("Remote: no se pudo escuchar en 127.0.0.1:", _port, " (error ", lerr, "); reintento")
		server = null
		return

	var file = File.new()
	var err = file.open(token_path, File.WRITE)
	if err != OK:
		printerr("Remote: no se pudo escribir el token en ", token_path, " (error ", err, ")")
		server.stop()
		server = null
		token = ""
		_port = 0   # sin token no hay RPC posible: no reintentar
		return
	file.store_string(token)
	file.close()
	_start_watchdog()

	print("Remote: escuchando en 127.0.0.1:", _port)


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
	# Sólo borra si el archivo sigue siendo el nuestro: en una recarga se crea un
	# Remote nuevo y el viejo, al salir, borraba el token del nuevo (mismo path).
	if token_path == "" or token == "":
		return
	var f = File.new()
	var ours = true
	if f.file_exists(token_path) and f.open(token_path, File.READ) == OK:
		ours = f.get_as_text().strip_edges() == token
		f.close()
	if ours:
		Directory.new().remove(token_path)
	token = ""


# Si el motor muere sin pasar por _exit_tree (p.ej. al matar cage, que deja caer el display
# y termina el proceso de golpe), este vigilante borra el token en cuanto el shell desaparece.
# Va en su propia sesión y cierra los fds heredados (si no, retendría el socket Wayland y cage
# no terminaría al salir el cliente).
func _start_watchdog():
	var close_fds = "i=3; while [ $i -le 64 ]; do eval \"exec $i>&-\" 2>/dev/null; i=$((i+1)); done; "
	# Sólo borra el token si sigue siendo el nuestro: todas las sesiones usan la misma ruta y el
	# vigilante de una sesión vieja borraba el token de la nueva.
	var loop = "while kill -0 %d 2>/dev/null; do sleep 1; done; [ \"$(cat '%s' 2>/dev/null)\" = '%s' ] && rm -f '%s'" % [OS.get_process_id(), token_path, token, token_path]
	OS.execute("setsid", ["sh", "-c", close_fds + loop], false)


func _process(delta):
	if server == null:
		if _port > 0 and not cleaned and OS.get_ticks_msec() >= _retry_at:
			_open()
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

	# Lo que pida el control remoto puede cambiar la UI (open, home, cerrar...).
	if shell == null or not is_instance_valid(shell):
		_fail(conn, id, -32002, "shell recargando")
		return
	shell.last_activity = OS.get_ticks_msec()
	shell.request_redraw()
	match method:
		"reload_shell":
			_reply(conn, id, true)
			Host.call_deferred("reload_shell")
		"state":
			_reply(conn, id, _state())
		"media":
			# Gancho de prueba/automatización del OSD de volumen/brillo: mismas
			# acciones que las teclas multimedia ({"action":"up"|"down"|"mute"|
			# "brightness_up"|"brightness_down"}).
			if shell.has_method("_forward_media_to_capture") \
					and shell._forward_media_to_capture(str(params.get("action", ""))):
				_reply(conn, id, true)  # viajó al equipo remoto (Deskflow)
			elif shell.system_osd != null:
				_reply(conn, id, shell.system_osd.rpc_action(params))
			else:
				_fail(conn, id, -32003, "sin system_osd")
		"open":
			shell._open_by_name(str(params.get("name", "")))
			_reply(conn, id, true)
		"home":
			shell._go_home()
			_reply(conn, id, true)
		"tile_focus":
			shell._focus_dir(int(params.get("dir", 0)))
			_reply(conn, id, true)
		"tile_swap":
			shell._swap_dir(int(params.get("dir", 0)))
			_reply(conn, id, true)
		"expose":
			shell._toggle_expose(bool(params.get("on", true)))
			_reply(conn, id, true)
		"gesture":
			# Gesto de touchpad reenviado por sway (bindgesture → session/gdtk-gesture).
			# swipe {direction}: left/right/up/down; pinch {phase}: begin/update/end.
			var kind = str(params.get("kind", "swipe"))
			if kind == "pinch":
				_reply(conn, id, shell.gesture_pinch(str(params.get("phase", "")),
					float(params.get("scale", 1.0)), int(params.get("fingers", 2))))
			else:
				_reply(conn, id, shell.gesture(kind,
					str(params.get("direction", "")), int(params.get("fingers", 3))))
		"tile_drop":
			shell._tile_drop(int(params.get("a", -1)), int(params.get("b", -1)))
			_reply(conn, id, true)
		"untile":
			shell._untile_window(int(params.get("id", -1)))
			_reply(conn, id, true)
		"minimize":
			shell._minimize_window(int(params.get("id", -1)))
			_reply(conn, id, true)
		"restore":
			shell._restore_window(int(params.get("id", -1)))
			_reply(conn, id, true)
		"fullscreen":
			shell._toggle_fullscreen()
			_reply(conn, id, true)
		"maximize":
			shell._maximize_window(int(params.get("id", -1)))
			_reply(conn, id, true)
		"snap_tile":
			shell._snap_tile(int(params.get("dir", -1)))
			_reply(conn, id, true)
		"pan":
			shell._pan_by(float(params.get("dir", 1.0)))
			_reply(conn, id, true)
		"snap_pan":
			shell._snap_pan()
			_reply(conn, id, true)
		"move_window":
			shell._move_window_to(int(params.get("a", -1)), int(params.get("anchor", -1)), bool(params.get("before", true)))
			_reply(conn, id, true)
		"wm":
			# Capa de comandos estable del modelo híbrido: {action, id?, dir?}.
			var action = str(params.get("action", ""))
			var wid = int(params.get("id", shell.focused_tile))
			var dir = params.get("dir", null)
			match action:
				"toggle":
					shell.toggle_window_mode(wid)
				"float":
					shell.set_window_mode(wid, "floating")
				"tile":
					shell.set_window_mode(wid, "tiled")
				"maximize":
					shell._toggle_maximize_window(wid)
				"arrange":
					shell.arrange_windows()
				"focus":
					shell._focus_dir(int(dir) if dir != null else 0)
				"move":
					shell._swap_dir(int(dir) if dir != null else 0)
				"anchor":
					shell.hybrid.reanchor(wid, int(dir) if dir != null else 0)
					shell.request_redraw()
				_:
					pass
			_reply(conn, id, true)
		"release_mods":
			shell.release_modifiers()
			_reply(conn, id, true)
		"launch":
			_launch(conn, id, params)
		"close_window":
			shell._close_window_id(int(params.get("id", -1)))
			_reply(conn, id, true)
		"force_close_window":
			# Cierre forzado: saca una ventana residual aunque el cliente no responda.
			shell._force_close_window_id(int(params.get("id", -1)))
			_reply(conn, id, true)
		"screenshot":
			_reply(conn, id, _screenshot(params))
		"peers":
			# Banco de pruebas e2e: equipos descubiertos ({id, label}).
			var peers = []
			var hs = shell.neighborhood.get("hosts") if shell.neighborhood != null else []
			for h in (hs if typeof(hs) == TYPE_ARRAY else []):
				peers.append({"id": str(h.get("id", "")), "label": str(h.get("label", ""))})
			_reply(conn, id, peers)
		"share_window":
			# Mismo camino que soltar el bloque de la ventana sobre un equipo del Grupo.
			shell._group_share_window(str(params.get("host", "")), int(params.get("id", -1)))
			_reply(conn, id, true)
		"unshare_window":
			shell._group_unshare_window(str(params.get("host", "")))
			_reply(conn, id, true)
		"hud_snapshot":
			_reply(conn, id, _hud_snapshot(params))
		"hud_command":
			_reply(conn, id, _hud_command(params))
		"click":
			_click(params)
			_reply(conn, id, true)
		"mouse_button":
			_mouse_button(params)
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
		"restart_shell":
			_reply(conn, id, true)
			shell.recovery.call_deferred("restart", shell)
		"quit":
			_reply(conn, id, true)
			shell.recovery.quit(shell)
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
			"app_id": shell.compositor.get_app_id(window_id),
			"activity": activity,
			"parent": shell.compositor.get_parent_id(window_id),
			"mode": shell.hybrid.mode(window_id),
			"anchor": shell.hybrid.anchor(window_id),
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
		# Pantallas: orden de las ventanas visibles, la enfocada, los grupos (split),
		# las minimizadas y la vista de exposé.
		"tiles": shell.tiles,
		"focused_tile": shell.focused_tile,
		"screens": shell._units(),
		"units": shell.wm_units,
		"modes": shell.hybrid.serialize(),
		"minimized": shell.minimized.keys(),
		"expose": shell.expose,
		"expose_sel": shell.expose_sel,
		"expose_scroll": shell.expose_scroll,
		"fullscreen": shell.fullscreen_id,
		"handles": shell.handles.size(),
		"pan": shell.pan,
		"pan_active": shell.pan_active,
		"fits": shell.fits_state(),
		"geom": shell.geom_state(),
		# Vueltas del loop, pasos de física y frames dibujados: para medir el reposo.
		"engine": [Engine.get_idle_frames(), Engine.get_physics_frames(), Engine.get_frames_drawn()],
		# Commits Wayland acumulados: dos lecturas dan commits/s (qué ventana mantiene ocupado el loop).
		"commits": shell.compositor.commit_count,
		# Rendimiento del compositor embebido (SPEC-rendimiento-compositor): si "dmabuf" es
		# "off", las apps copian por CPU y el FPS bajo/CPU alto no es del shell. Dos lecturas
		# de dmabuf_commits/shm_commits dicen por qué camino va cada app.
		"compositor": {
			"dmabuf": shell.compositor.dmabuf_state if shell.compositor.has_method("get_dmabuf_state") else "?",
			"dmabuf_commits": shell.compositor.dmabuf_commits if shell.compositor.has_method("get_dmabuf_commits") else 0,
			"shm_commits": shell.compositor.shm_commits if shell.compositor.has_method("get_shm_commits") else 0,
			"explicit_sync": shell.compositor.explicit_sync_state if shell.compositor.has_method("get_explicit_sync_state") else "?",
			"scanout": shell.compositor.scanout_state() if shell.compositor.has_method("scanout_state") else "?",
			"scanout_on": shell.compositor.scanout_enabled() if shell.compositor.has_method("scanout_enabled") else false,
			"scanout_suspended": shell.compositor.scanout_suspended() if shell.compositor.has_method("scanout_suspended") else false,
			"scanout_reason": shell.compositor.scanout_reason() if shell.compositor.has_method("scanout_reason") else "?",
		},
		# Presentaciones livianas (present-only, sin rearmar ImGui) vs completas del shell
		# (SPEC-rendimiento-compositor P1): dos lecturas muestran qué camino domina.
		"present": {"light": shell.present_light, "full": shell.present_full},
		# Span físico (SPEC-physical-multi-monitor): activo, tamaño de la pantalla
		# principal y del escritorio completo, y salidas lógicas del compositor.
		"span": shell.span_state() if shell.has_method("span_state") else {},
		# Frame: items con su posición en pantalla (vacío si no se dibujó).
		"frame": {"visible": shell.frame.drawn, "items": shell.frame.items_layout},
		# Input remoto: clientes libei conectados y pedidos esperando el diálogo.
		"remote_input": {"clients": shell.remote_input.get_client_count(), "requests": shell.input_requests.size()},
		# Diagnóstico: eventos de entrada que llegaron al shell (mouse/touch).
		"input": {"motion": shell.input_motion_count, "buttons": shell.input_button_count,
			"touch": shell.input_touch_count, "last_button": shell.input_last_button,
			"last_key": shell.input_last_key},
		# Diagnóstico del cursor (¿por qué no se ve?): modo de Godot, cursor oculto pedido
		# por la app enfocada, pointer lock, captura Deskflow y cursor dibujado del shell.
		"cursor": {"mode": Input.get_mouse_mode(), "client_hidden": shell.client_cursor_hidden,
			"client_locked": shell.client_pointer_locked, "capture": shell.mouse_locked,
			"eis_cursor": shell.eis_cursor != null and shell.eis_cursor.visible,
			"pos": [shell.get_viewport().get_mouse_position().x, shell.get_viewport().get_mouse_position().y]},
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


# SPEC-hud-remote 3: el control remoto expone el colector del HUD y su consola.
func _hud():
	return get_node_or_null("/root/DebugHud")


func _hud_snapshot(params):
	var hud = _hud()
	if hud == null:
		return {"error": "DebugHud no disponible"}
	return hud.snapshot(int(params.get("since_frame", -1)))


func _hud_command(params):
	var hud = _hud()
	if hud == null:
		return {"output": "DebugHud no disponible"}
	return {"output": hud.command_output(str(params.get("line", "")))}


# Botones apretados por RPC: el motion los lleva en button_mask (como el mouse real),
# así un press + move + release arrastra (Grupo, ventanas).
var _button_mask = 0


func _event_mouse_motion(x, y, rx = 0.0, ry = 0.0):
	var event = InputEventMouseMotion.new()
	event.button_mask = _button_mask
	event.position = Vector2(x, y)
	event.global_position = Vector2(x, y)
	event.relative = Vector2(rx, ry)
	return event


func _event_mouse_button(x, y, button, pressed, double):
	var event = InputEventMouseButton.new()
	event.position = Vector2(x, y)
	event.global_position = Vector2(x, y)
	event.button_index = button
	event.pressed = pressed
	var bit = 1 << (int(button) - 1)
	_button_mask = (_button_mask | bit) if pressed else (_button_mask & ~bit)
	event.button_mask = _button_mask
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
	event_queue.push_back(_event_mouse_motion(float(params.get("x", 0.0)), float(params.get("y", 0.0)),
		float(params.get("rx", 0.0)), float(params.get("ry", 0.0))))


# Press/release por separado (el click siempre manda los dos juntos): lo necesita
# el menu radial, que se abre al presionar y elige al soltar.
func _mouse_button(params):
	var x = float(params.get("x", 0.0))
	var y = float(params.get("y", 0.0))
	var button = int(params.get("button", BUTTON_LEFT))
	var pressed = bool(params.get("pressed", true))
	event_queue.push_back(_event_mouse_motion(x, y))
	var ev = _event_mouse_button(x, y, button, pressed, false)
	# `meta`: Super sostenido (Super+arrastre para mover/redimensionar en e2e).
	ev.meta = bool(params.get("meta", false))
	event_queue.push_back(ev)


func _scroll(params):
	var x = float(params.get("x", 0.0))
	var y = float(params.get("y", 0.0))
	var dy = float(params.get("dy", 0.0))
	# Scroll horizontal del touchpad de dos dedos: el shell/compositor lo reenvia
	# como BUTTON_WHEEL_LEFT/RIGHT (=> wl_pointer axis HORIZONTAL_SCROLL). Sin dx el
	# RPC solo podia pedir scroll vertical.
	var dx = float(params.get("dx", 0.0))
	event_queue.push_back(_event_mouse_motion(x, y))
	if dy != 0.0:
		_wheel_steps(x, y, dy, BUTTON_WHEEL_DOWN, BUTTON_WHEEL_UP)
	if dx != 0.0:
		_wheel_steps(x, y, dx, BUTTON_WHEEL_RIGHT, BUTTON_WHEEL_LEFT)
	if dy == 0.0 and dx == 0.0:
		# Compatibilidad: sin eje pedido se manda un paso vertical (contrato viejo).
		_wheel_steps(x, y, 1.0, BUTTON_WHEEL_DOWN, BUTTON_WHEEL_UP)


func _wheel_steps(x, y, amount, positive, negative):
	var steps = int(abs(amount))
	if steps < 1:
		steps = 1
	var button = positive if amount > 0.0 else negative
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
	# Nombres estilo X11 (Super_L, Super_R): Godot los llama "Super L".
	if key_name.length() > 1:
		key_name = key_name.replace("_", " ")
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
