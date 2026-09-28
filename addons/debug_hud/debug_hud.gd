extends Node

# HUD de debug reutilizable (SPEC-hud, SPEC-hud-remote).
#
# Pensado como autoload. El proyecto anfitrion lo dibuja cada frame con
# `DebugHud.draw(canvas)`, donde canvas es un ImGuiCanvas del modulo `imgui`.
#
# El colector de metricas (DebugMetrics) corre en `_process` aunque no haya
# ImGui ni canvas; la vista ImGui solo se dibuja si `render_local` es true.
# Con `remote_source` definido, la vista dibuja los snapshots que llegan de
# otra instancia (visor remoto).

const DebugMetrics = preload("debug_metrics.gd")

var enabled = true
# HUD completo abierto (F1 / ` si hotkeys). El widget mini se muestra si show_mini.
var visible = false
var show_mini = true
var hotkeys = true
# Sin HUD a la vista no se muestrea, salvo que alguien pida snapshots (control remoto).
var _snapshot_ms = -100000
# 0=arriba-izq, 1=arriba-der, 2=abajo-izq, 3=abajo-der.
var mini_corner = 3
var scale = 1.0

# Politica de vista (SPEC-hud-remote 2). Con false el dispositivo no dibuja el
# HUD (solo corre el colector). Fuentes: ProjectSettings debug_hud/render_local
# (default true), env GDTK_HUD_LOCAL=0|1 (gana), y el hook render_local_resolver.
var render_local = true
var render_local_resolver = null
var render_local_resolver_method = "resolve_render_local"

# Visor remoto: "host:puerto" hace poll de hud_snapshot a remote_hz.
var remote_source = ""
var remote_hz = 4.0
var remote_token_path = ""
var remote_status = "inactivo"
var remote_connected = false
var remote_error = ""

var metrics = null # colector local
var mirror = null # espejo del remoto
var _remote_has_data = false

var canvas = null
var has_implot = false

var console_filter = ""
var console_scroll = true

var command_text = ""
var command_history = []
var command_index = -1
var command_label = 0
var command_refocus = false

var commands = {}

var _current_tab = 0

# Grupos colapsables de la pestana Graficas.
var GROUPS = [
	["Frame", ["TIME_FPS", "TIME_PROCESS", "TIME_PHYSICS_PROCESS"]],
	["Render", ["RENDER_DRAW_CALLS_IN_FRAME", "RENDER_2D_DRAW_CALLS_IN_FRAME", "RENDER_OBJECTS_IN_FRAME", "RENDER_VERTICES_IN_FRAME", "RENDER_MATERIAL_CHANGES_IN_FRAME", "RENDER_SHADER_CHANGES_IN_FRAME", "RENDER_SURFACE_CHANGES_IN_FRAME", "RENDER_2D_ITEMS_IN_FRAME"]],
	["Memoria", ["MEMORY_STATIC", "MEMORY_DYNAMIC", "MEMORY_STATIC_MAX", "RENDER_VIDEO_MEM_USED", "RENDER_TEXTURE_MEM_USED", "RENDER_VERTEX_MEM_USED"]],
	["Objetos", ["OBJECT_COUNT", "OBJECT_RESOURCE_COUNT", "OBJECT_NODE_COUNT", "OBJECT_ORPHAN_NODE_COUNT"]],
	["Fisica", ["PHYSICS_3D_ACTIVE_OBJECTS", "PHYSICS_3D_COLLISION_PAIRS", "PHYSICS_3D_ISLAND_COUNT"]],
	["Audio", ["AUDIO_OUTPUT_LATENCY"]],
	["GPU", ["gpu", "frt_frame", "frt_render", "frt_sync", "frt_other"]],
]

# Unidades por serie para la tabla de Monitores (el resto son cuentas).
var UNITS = {
	"TIME_PROCESS": "ms", "TIME_PHYSICS_PROCESS": "ms", "collector_us": "us",
	"MEMORY_STATIC": "MB", "MEMORY_DYNAMIC": "MB", "MEMORY_STATIC_MAX": "MB",
	"MEMORY_DYNAMIC_MAX": "MB", "MEMORY_MESSAGE_BUFFER_MAX": "MB",
	"RENDER_VIDEO_MEM_USED": "MB", "RENDER_TEXTURE_MEM_USED": "MB",
	"RENDER_VERTEX_MEM_USED": "MB", "RENDER_USAGE_VIDEO_MEM_TOTAL": "MB",
	"gpu": "ms", "frt_frame": "ms", "frt_idle": "ms", "frt_phys": "ms",
	"frt_phys_sum": "ms", "frt_render": "ms", "frt_sync": "ms", "frt_other": "ms",
}

var _policy_resolved = false
var _accum = 0.0
var _remote_accum = 0.0
var _remote_peer = null
var _remote_buf = PoolByteArray()


func _ready():
	_init_metrics()
	register_command("help", self, "_cmd_help", "Muestra esta ayuda")
	register_command("clear", self, "_cmd_clear", "Limpia el log y la consola")
	register_command("fps", self, "_cmd_fps", "fps <n>: limite de FPS (0 = sin limite)")
	register_command("timescale", self, "_cmd_timescale", "timescale <x>: escala de tiempo")
	register_command("vsync", self, "_cmd_vsync", "vsync on|off")
	register_command("quit", self, "_cmd_quit", "Cierra la aplicacion")
	if OS.is_debug_build():
		register_command("eval", self, "_cmd_eval", "eval <expresion>: evalua sobre la escena actual")


func _init_metrics():
	metrics = DebugMetrics.new()


func _process(delta):
	if metrics == null:
		_init_metrics()
	if not _policy_resolved:
		_resolve_policy()
	var wanted = visible or show_mini or OS.get_ticks_msec() - _snapshot_ms < 5000
	if not wanted:
		pass
	elif metrics.sample_hz > 0.0:
		var period = 1.0 / metrics.sample_hz
		_accum += delta
		if _accum >= period:
			_accum -= period
			metrics.sample()
			# Con el HUD abierto las gráficas avanzan aunque no haya input.
			if visible and canvas != null and canvas.has_method("request_redraw"):
				canvas.request_redraw()
	else:
		metrics.sample()
	if remote_source != "":
		_poll_remote(delta)


# --- API publica ---

func set_canvas(p_canvas):
	canvas = p_canvas


func set_enabled(p_enabled):
	enabled = p_enabled


func toggle():
	visible = not visible


func register_command(name, target, method, help = ""):
	commands[name] = {"target": target, "method": method, "help": help}


# Salida del comando remoto: en builds no debug solo los comandos inocuos.
func command_output(line):
	var stripped = line.strip_edges()
	var space = stripped.find(" ")
	var name = stripped if space < 0 else stripped.substr(0, space)
	var safe = ["help", "fps", "vsync", "timescale"]
	if not OS.is_debug_build() and not safe.has(name):
		return "comando no permitido en release: " + name
	return run_command(line)


func snapshot(since_frame = -1):
	_snapshot_ms = OS.get_ticks_msec()
	return metrics.snapshot(since_frame)


func start_remote(host, port):
	_stop_remote()
	remote_source = "%s:%d" % [host, int(port)]
	mirror = DebugMetrics.new()
	_remote_has_data = false
	remote_status = "conectando"
	remote_error = ""
	_remote_accum = 1e9
	print("DebugHud: visor remoto -> ", remote_source)


func stop_remote():
	_stop_remote()
	remote_source = ""
	mirror = null
	_remote_has_data = false
	remote_status = "inactivo"


func _stop_remote():
	if _remote_peer != null:
		if _remote_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			_remote_peer.disconnect_from_host()
		_remote_peer = null
	_remote_buf = PoolByteArray()
	remote_connected = false


func apply_snapshot(snap):
	if mirror == null:
		mirror = DebugMetrics.new()
	mirror.apply_snapshot(snap)
	_remote_has_data = true


# --- Politica render_local ---

func _resolve_policy():
	var value = true
	if ProjectSettings.has_setting("debug_hud/render_local"):
		value = bool(ProjectSettings.get_setting("debug_hud/render_local"))
	var env = OS.get_environment("GDTK_HUD_LOCAL")
	if env == "0":
		value = false
	elif env == "1":
		value = true
	if render_local_resolver != null:
		var resolved = null
		if typeof(render_local_resolver) == TYPE_DICTIONARY:
			var target = render_local_resolver.get("target")
			var method = render_local_resolver.get("method", render_local_resolver_method)
			if target != null and target.has_method(method):
				resolved = target.call(method)
		elif render_local_resolver.has_method(render_local_resolver_method):
			resolved = render_local_resolver.call(render_local_resolver_method)
		if resolved != null:
			value = bool(resolved)
	render_local = value
	if metrics != null:
		metrics.profile["render_local"] = value
	_policy_resolved = true
	print("DebugHud: render_local=", value)


# --- Vista ---

func draw(c):
	if not enabled:
		return
	if metrics == null:
		_init_metrics()
	if not _policy_resolved:
		_resolve_policy()
	if not render_local:
		return
	canvas = c
	has_implot = c.has_method("implot_begin_plot")

	if hotkeys and (c.is_key_pressed(KEY_F1) or c.is_key_pressed(KEY_QUOTELEFT)):
		visible = not visible

	var m = _view_metrics()
	if show_mini:
		_draw_mini(c, m)
	if visible:
		_draw_full(c, m)


func _view_metrics():
	if remote_source != "" and mirror != null and _remote_has_data:
		return mirror
	return metrics


func _unit(name):
	return UNITS.get(name, "")


func _color(fps):
	if fps >= 55.0:
		return Color(0.35, 1.0, 0.45)
	if fps >= 30.0:
		return Color(1.0, 0.85, 0.3)
	return Color(1.0, 0.35, 0.35)


# --- Widget mini ---

func _draw_mini(c, m):
	var s = scale
	var w = 220.0 * s
	var h = 76.0 * s
	var vp = c.get_viewport_rect().size
	var pos = Vector2(8.0, 8.0)
	if mini_corner == 1 or mini_corner == 3:
		pos.x = vp.x - w - 8.0
	if mini_corner == 2 or mini_corner == 3:
		pos.y = vp.y - h - 8.0

	c.set_next_window_pos(pos, true)
	c.set_next_window_size(Vector2(w, h), true)
	c.set_next_window_bg_alpha(0.55)
	var flags = c.WINDOW_NO_DECORATION | c.WINDOW_NO_MOVE | c.WINDOW_NO_RESIZE | c.WINDOW_NO_SAVED_SETTINGS | c.WINDOW_NO_SCROLLBAR | c.WINDOW_NO_TITLE_BAR | c.WINDOW_NO_BRING_TO_FRONT_ON_FOCUS
	if c.begin("##debug_mini", flags):
		var fps = m.latest.get("TIME_FPS", Performance.get_monitor(Performance.TIME_FPS))
		var mem = m.latest.get("MEMORY_STATIC", Performance.get_monitor(Performance.MEMORY_STATIC) * DebugMetrics.MB)
		var draws = m.latest.get("RENDER_DRAW_CALLS_IN_FRAME", 0.0)
		var verts = m.latest.get("RENDER_VERTICES_IN_FRAME", 0.0)
		c.text_colored(_color(fps), "FPS %.0f" % fps)
		c.same_line()
		c.text("mem %.0f MB" % mem)
		c.text("draws %.0f  verts %.0f" % [draws, verts])
		var spark = m.series.get("TIME_PROCESS")
		if spark != null and spark.size() > 1:
			if has_implot:
				var plot_flags = c.IMPLOT_FLAGS_CANVAS_ONLY | c.IMPLOT_FLAGS_NO_INPUTS
				if c.implot_begin_plot("##spark", Vector2(w - 14.0, h - 50.0), plot_flags):
					c.implot_setup_axes("", "", c.IMPLOT_AXIS_NO_DECORATIONS, c.IMPLOT_AXIS_NO_DECORATIONS)
					c.implot_plot_line("##ft", _index_pool(spark.size()), _pool(spark))
					c.implot_end_plot()
			else:
				c.plot_lines("##spark", _pool(spark), "", 0.0, 0.0, Vector2(w - 14.0, h - 50.0))
		if c.is_item_hovered() and c.is_mouse_clicked(0):
			visible = true
	c.end()


# --- HUD completo ---

func _draw_full(c, m):
	var vp = c.get_viewport_rect().size
	c.set_next_window_pos(Vector2(vp.x * 0.08, vp.y * 0.08), true)
	c.set_next_window_size(Vector2(vp.x * 0.84, vp.y * 0.84), true)
	c.set_next_window_bg_alpha(0.88)
	var flags = c.WINDOW_NO_SAVED_SETTINGS
	if c.begin("Debug HUD##debug_hud", flags, true):
		if not c.is_window_open():
			visible = false
		if remote_source != "":
			c.text_colored(Color(0.5, 0.85, 1.0), "REMOTO %s  [%s]  frame %d" % [remote_source, remote_status, int(m.frame)])
		if c.begin_tab_bar("##hud_tabs"):
			if c.begin_tab_item("Graficas"):
				_current_tab = 0
				_tab_graphs(c, m)
				c.end_tab_item()
			if c.begin_tab_item("Monitores"):
				_current_tab = 1
				_tab_monitors(c, m)
				c.end_tab_item()
			if c.begin_tab_item("Consola"):
				_current_tab = 2
				_tab_console(c, m)
				c.end_tab_item()
			c.end_tab_bar()
	c.end()


func _available(name, m):
	var arr = m.series.get(name)
	return arr != null and arr.size() > 1


# Con FRT_PERF el grupo GPU va primero para que se vea sin scroll.
func _ordered_groups(m):
	var out = []
	var frt = m.profile.get("frt_perf", false)
	if frt:
		for group in GROUPS:
			if group[0] == "GPU":
				out.append(group)
	for group in GROUPS:
		if group[0] == "GPU" and frt:
			continue
		out.append(group)
	return out


func _tab_graphs(c, m):
	if m.frame < 2:
		c.text("Sin datos todavia")
		return
	_remote_log_footer(c, m)
	var avail = c.get_content_region_avail()
	var plot_h = max((avail.y - 30.0) / 3.0, 90.0)
	for group in _ordered_groups(m):
		var names = []
		for name in group[1]:
			if _available(name, m):
				names.append(name)
		if names.size() == 0:
			continue
		if c.tree_node(group[0], c.TREE_NODE_DEFAULT_OPEN):
			if has_implot:
				if c.implot_begin_plot(group[0], Vector2(-1, plot_h)):
					c.implot_setup_axes("", "", c.IMPLOT_AXIS_AUTOFIT, c.IMPLOT_AXIS_AUTOFIT)
					for name in names:
						var arr = m.series[name]
						c.implot_plot_line(name, _index_pool(arr.size()), _pool(arr))
					c.implot_end_plot()
			else:
				for name in names:
					c.plot_lines(name, _pool(m.series[name]), "", 0.0, 0.0, Vector2(-1, plot_h * 0.5))
			c.tree_pop()


func _remote_log_footer(c, m):
	if remote_source == "":
		return
	c.separator()
	var count = m.logs.size()
	var first = max(count - 4, 0)
	for i in range(first, count):
		var entry = m.logs[i]
		var text = str(entry["text"])
		if entry["is_error"]:
			c.text_colored(Color(1.0, 0.35, 0.35), text)
		else:
			c.text(text)


func _tab_monitors(c, m):
	var avail = c.get_content_region_avail()
	var rows = []
	for entry in m.MONITORS:
		rows.append(entry[0])
	if m.profile.get("frt_perf", false):
		for name in DebugMetrics.FRT_SERIES:
			if m.series.has(name):
				rows.append(name)
	if m.series.has("collector_us"):
		rows.append("collector_us")
	if c.begin_child("##hud_mon", Vector2(-1, max(avail.y - 8.0, 80.0))):
		if c.begin_table("##hud_mon_table", 5, c.TABLE_BORDERS | c.TABLE_ROW_BG | c.TABLE_RESIZABLE):
			c.table_setup_column("Monitor")
			c.table_setup_column("Actual")
			c.table_setup_column("Min")
			c.table_setup_column("Max")
			c.table_setup_column("Media")
			c.table_headers_row()
			for name in rows:
				var st = m.stats(name)
				var unit = _unit(name)
				c.table_next_row()
				c.table_next_column()
				c.text(name)
				c.table_next_column()
				c.text("%.2f %s" % [st["latest"], unit])
				c.table_next_column()
				c.text("%.2f" % st["min"])
				c.table_next_column()
				c.text("%.2f" % st["max"])
				c.table_next_column()
				c.text("%.2f" % st["avg"])
			c.end_table()
	c.end_child()


func _tab_console(c, m):
	var avail = c.get_content_region_avail()
	console_filter = c.input_text("Filtro", console_filter)
	c.same_line()
	c.checkbox("Autoscroll", console_scroll)
	c.same_line()
	if c.button("Limpiar"):
		_clear_logs(m)

	var log_h = max(avail.y - 96.0, 80.0)
	if c.begin_child("##hud_log", Vector2(-1, log_h)):
		for entry in m.logs:
			var text = str(entry["text"])
			if console_filter != "" and text.findn(console_filter) < 0:
				continue
			if entry["is_error"]:
				c.text_colored(Color(1.0, 0.35, 0.35), text)
			else:
				c.text(text)
		if console_scroll:
			c.set_scroll_here_y(1.0)
	c.end_child()

	if command_refocus and c.has_method("set_keyboard_focus_here"):
		c.set_keyboard_focus_here()
	command_refocus = false

	var result = c.input_text_enter("##hud_cmd_%d" % command_label, command_text)
	command_text = result["text"]
	if result["submitted"]:
		var line = command_text
		command_text = ""
		command_label += 1
		run_command(line)
		command_refocus = true

	if c.is_key_pressed(KEY_UP):
		_history_move(1)
	elif c.is_key_pressed(KEY_DOWN):
		_history_move(-1)

	c.same_line()
	c.text("Enter ejecuta; flechas: historial")


func _clear_logs(m):
	m.logs = []
	if mirror != null:
		mirror.logs = []
	if Engine.has_singleton("DebugLog"):
		DebugLog.clear()
		m._log_cursor = DebugLog.last_id()
		m._snapshot_log_cursor = DebugLog.last_id()


func _history_move(delta):
	if command_history.size() == 0:
		return
	command_index += delta
	if command_index < 0:
		command_index = 0
	if command_index >= command_history.size():
		command_index = command_history.size() - 1
	command_text = command_history[command_index]
	command_label += 1


# --- Helpers de plots ---

func _index_pool(n):
	var out = PoolRealArray()
	out.resize(n)
	for i in range(n):
		out[i] = i
	return out


func _pool(values):
	var out = PoolRealArray()
	out.resize(values.size())
	for i in range(values.size()):
		out[i] = values[i]
	return out


# --- Comandos ---

func run_command(line):
	line = line.strip_edges()
	if line == "":
		return ""
	command_history.push_front(line)
	while command_history.size() > 50:
		command_history.pop_back()
	command_index = -1

	var space = line.find(" ")
	var name = line if space < 0 else line.substr(0, space)
	var rest = "" if space < 0 else line.substr(space + 1).strip_edges()
	if not commands.has(name):
		var msg = "comando desconocido: " + name
		printerr(msg)
		return msg
	var cmd = commands[name]
	var out = cmd["target"].callv(cmd["method"], [rest])
	var text = "" if out == null else str(out)
	if text != "":
		print(text)
	return text


func _cmd_help(_args):
	var lines = PoolStringArray(["Comandos disponibles:"])
	for name in commands.keys():
		lines.append("  %-10s %s" % [name, commands[name]["help"]])
	return lines.join("\n")


func _cmd_clear(_args):
	_clear_logs(metrics)
	return "consola limpia"


func _cmd_fps(args):
	var n = int(args) if args != "" else 0
	Engine.target_fps = n
	return "target_fps = " + str(n)


func _cmd_timescale(args):
	var x = float(args) if args != "" else 1.0
	Engine.time_scale = x
	return "time_scale = " + str(x)


func _cmd_vsync(args):
	var on = args.to_lower() != "off"
	OS.vsync_enabled = on
	return "vsync = " + str(on)


func _cmd_quit(_args):
	get_tree().quit()
	return ""


func _cmd_eval(expr):
	if expr == "":
		printerr("eval: falta la expresion")
		return "eval: falta la expresion"
	var target = get_tree().current_scene
	var expression = Expression.new()
	var error = expression.parse(expr, PoolStringArray(["scene"]))
	if error != OK:
		var msg = "eval: " + expression.get_error_text()
		printerr(msg)
		return msg
	var result = expression.execute([target], null, true)
	if expression.has_execute_failed():
		var msg = "eval: " + expression.get_error_text()
		printerr(msg)
		return msg
	return str(result)


# --- Visor remoto (poll de hud_snapshot, SPEC-hud-remote 3) ---

func _poll_remote(delta):
	var period = 1.0 / max(remote_hz, 0.1)
	_remote_accum += delta
	if _remote_accum < period:
		return
	_remote_accum -= period
	if not remote_connected:
		if _remote_connect():
			remote_status = "conectado"
		else:
			remote_status = "sin conexion"
			_stop_remote()
			return
	var since = -1 if not _remote_has_data else int(mirror.frame)
	var response = _rpc({"jsonrpc": "2.0", "id": 2, "method": "hud_snapshot", "params": {"since_frame": since}})
	if typeof(response) != TYPE_DICTIONARY or response.has("error"):
		remote_status = "sin conexion"
		_stop_remote()
		return
	apply_snapshot(response)
	remote_status = "conectado"


func _remote_connect():
	var colon = remote_source.rfind(":")
	if colon < 0:
		return false
	var host = remote_source.substr(0, colon)
	var port = int(remote_source.substr(colon + 1))
	_remote_peer = StreamPeerTCP.new()
	if _remote_peer.connect_to_host(host, port) != OK:
		_remote_peer = null
		return false
	var deadline = OS.get_ticks_msec() + 1000
	while _remote_peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and OS.get_ticks_msec() < deadline:
		_remote_peer.poll()
		OS.delay_msec(2)
	if _remote_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_remote_peer = null
		return false
	_remote_peer.set_no_delay(true)
	_remote_buf = PoolByteArray()
	var token = _read_token(port)
	if token == "":
		remote_error = "token no encontrado"
		_remote_peer = null
		return false
	var auth = _rpc({"jsonrpc": "2.0", "id": 1, "method": "auth", "params": {"token": token}})
	if auth != true:
		remote_error = "auth rechazado"
		_remote_peer = null
		return false
	remote_connected = true
	remote_error = ""
	return true


func _read_token(port):
	var path = remote_token_path
	if path == "":
		path = OS.get_environment("GDTK_HUD_TOKEN")
	if path == "":
		var runtime = OS.get_environment("XDG_RUNTIME_DIR")
		if runtime == "":
			return ""
		var dir = Directory.new()
		var per_port = runtime.plus_file("gdtk-control-%d.token" % port)
		if dir.file_exists(per_port):
			path = per_port
		else:
			path = runtime.plus_file("gdtk-control.token")
	var file = File.new()
	if file.open(path, File.READ) != OK:
		return ""
	var token = file.get_as_text().strip_edges()
	file.close()
	return token


func _rpc(obj):
	if _remote_peer == null:
		return null
	var line = JSON.print(obj) + "\n"
	if _remote_peer.put_data(line.to_utf8()) != OK:
		return null
	var text = _read_line(1500)
	if text == null:
		return null
	var parsed = JSON.parse(text)
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return null
	var response = parsed.result
	if response.has("error"):
		return null
	return response.get("result")


func _read_line(timeout_ms):
	var deadline = OS.get_ticks_msec() + timeout_ms
	while OS.get_ticks_msec() < deadline:
		if _remote_peer == null or _remote_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return null
		var available = _remote_peer.get_available_bytes()
		if available > 0:
			var data = _remote_peer.get_partial_data(available)
			if data[0] == OK:
				_remote_buf.append_array(data[1])
		var idx = -1
		for i in range(_remote_buf.size()):
			if _remote_buf[i] == 10:
				idx = i
				break
		if idx >= 0:
			var line_bytes = PoolByteArray()
			if idx > 0:
				line_bytes = _remote_buf.subarray(0, idx - 1)
			if idx + 1 < _remote_buf.size():
				_remote_buf = _remote_buf.subarray(idx + 1, _remote_buf.size() - 1)
			else:
				_remote_buf = PoolByteArray()
			return line_bytes.get_string_from_utf8()
		OS.delay_msec(2)
	return null
