extends Node

# HUD de debug reutilizable (SPEC-hud C). Pensado como autoload: el proyecto
# anfitrion lo dibuja cada frame con `DebugHud.draw(canvas)`, donde canvas es
# un ImGuiCanvas del modulo `imgui`.
#
# Costo cero cuando esta oculto: solo el widget mini se dibuja; con
# `enabled = false` no se dibuja nada.

var enabled = true
# HUD completo abierto (F1 / `). El widget mini siempre se muestra.
var visible = false
# 0=arriba-izq, 1=arriba-der, 2=abajo-izq, 3=abajo-der.
var mini_corner = 3
var scale = 1.0

var canvas = null
var has_implot = false

const HISTORY_SECONDS = 10.0
const MAX_FRAME_TIMES = 120
const MAX_LOGS = 2000

var t_hist = []
var s_fps = []
var s_frame = []
var s_mem = []
var s_dyn = []

var frame_times = []
var last_frame_usec = 0

var logs = []
var last_log_id = 0
var console_filter = ""
var console_scroll = true

var command_text = ""
var command_history = []
var command_index = -1
var command_label = 0
var command_refocus = false

var commands = {}

var _current_tab = 0


func _ready():
	register_command("help", self, "_cmd_help", "Muestra esta ayuda")
	register_command("clear", self, "_cmd_clear", "Limpia el log y la consola")
	register_command("fps", self, "_cmd_fps", "fps <n>: limite de FPS (0 = sin limite)")
	register_command("timescale", self, "_cmd_timescale", "timescale <x>: escala de tiempo")
	register_command("vsync", self, "_cmd_vsync", "vsync on|off")
	register_command("quit", self, "_cmd_quit", "Cierra la aplicacion")
	if OS.is_debug_build():
		register_command("eval", self, "_cmd_eval", "eval <expresion>: evalua sobre la escena actual")


# --- API publica ---

func set_canvas(p_canvas):
	canvas = p_canvas


func set_enabled(p_enabled):
	enabled = p_enabled


func toggle():
	visible = not visible


func register_command(name, target, method, help = ""):
	commands[name] = {"target": target, "method": method, "help": help}


func draw(c):
	if not enabled:
		return
	canvas = c
	has_implot = c.has_method("implot_begin_plot")

	if c.is_key_pressed(KEY_F1) or c.is_key_pressed(KEY_QUOTELEFT):
		visible = not visible

	_push_series()
	_fetch_logs()
	_draw_mini(c)
	if visible:
		_draw_full(c)


# --- Series ---

func _push_series():
	var now = OS.get_ticks_usec()
	var ft = 16.0
	if last_frame_usec > 0:
		ft = float(now - last_frame_usec) / 1000.0
		if ft <= 0.0 or ft > 1000.0:
			ft = 16.0
	last_frame_usec = now
	frame_times.append(ft)
	while frame_times.size() > MAX_FRAME_TIMES:
		frame_times.pop_front()

	var t = float(OS.get_ticks_msec()) / 1000.0
	t_hist.append(t)
	s_fps.append(Performance.get_monitor(Performance.TIME_FPS))
	s_frame.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	s_mem.append(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)
	s_dyn.append(Performance.get_monitor(Performance.MEMORY_DYNAMIC) / 1048576.0)
	while t_hist.size() > 0 and t - t_hist[0] > HISTORY_SECONDS:
		t_hist.pop_front()
		s_fps.pop_front()
		s_frame.pop_front()
		s_mem.pop_front()
		s_dyn.pop_front()


func _pool(values):
	var out = PoolRealArray()
	out.resize(values.size())
	for i in range(values.size()):
		out[i] = values[i]
	return out


# --- Widget mini ---

func _fps_color(fps):
	if fps >= 55.0:
		return Color(0.35, 1.0, 0.45)
	if fps >= 30.0:
		return Color(1.0, 0.85, 0.3)
	return Color(1.0, 0.35, 0.35)


func _draw_mini(c):
	var s = scale
	var w = 180.0 * s
	var h = 56.0 * s
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
		var fps = Performance.get_monitor(Performance.TIME_FPS)
		var mem = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
		c.text_colored(_fps_color(fps), "FPS %.0f" % fps)
		c.same_line()
		c.text("mem %.0f MB" % mem)
		if has_implot:
			var plot_flags = c.IMPLOT_FLAGS_CANVAS_ONLY | c.IMPLOT_FLAGS_NO_INPUTS
			if c.implot_begin_plot("##spark", Vector2(w - 14.0, h - 30.0), plot_flags):
				c.implot_setup_axes("", "", c.IMPLOT_AXIS_NO_DECORATIONS, c.IMPLOT_AXIS_NO_DECORATIONS)
				var n = frame_times.size()
				var xs = PoolRealArray()
				xs.resize(n)
				for i in range(n):
					xs[i] = i
				c.implot_plot_line("##ft", xs, _pool(frame_times))
				c.implot_end_plot()
		else:
			c.plot_lines("##spark", _pool(frame_times), "", 0.0, 0.0, Vector2(w - 14.0, h - 30.0))
		if c.is_item_hovered() and c.is_mouse_clicked(0):
			visible = true
	c.end()


# --- HUD completo ---

func _draw_full(c):
	var vp = c.get_viewport_rect().size
	c.set_next_window_pos(Vector2(vp.x * 0.08, vp.y * 0.08), true)
	c.set_next_window_size(Vector2(vp.x * 0.84, vp.y * 0.84), true)
	c.set_next_window_bg_alpha(0.88)
	var flags = c.WINDOW_NO_SAVED_SETTINGS
	if c.begin("Debug HUD##debug_hud", flags, true):
		if not c.is_window_open():
			visible = false
		if c.begin_tab_bar("##hud_tabs"):
			if c.begin_tab_item("Graficas"):
				_current_tab = 0
				_tab_graphs(c)
				c.end_tab_item()
			if c.begin_tab_item("Consola"):
				_current_tab = 1
				_tab_console(c)
				c.end_tab_item()
			if c.begin_tab_item("Monitores"):
				_current_tab = 2
				_tab_monitors(c)
				c.end_tab_item()
			c.end_tab_bar()
	c.end()


func _plot_height(c, count):
	var avail = c.get_content_region_avail()
	return max((avail.y - 6.0 * float(count)) / float(count), 80.0)


func _tab_graphs(c):
	var t = float(OS.get_ticks_msec()) / 1000.0
	var n = t_hist.size()
	if n == 0:
		c.text("Sin datos todavia")
		return
	var h = _plot_height(c, 3)
	var w = (c.get_content_region_avail().x - 8.0) * 0.5
	var xs = _pool(t_hist)
	var fps = _pool(s_fps)
	var frame = _pool(s_frame)
	var mem = _pool(s_mem)
	var dyn = _pool(s_dyn)
	if has_implot:
		if c.implot_begin_plot("FPS", Vector2(w, h)):
			c.implot_setup_axes("t", "fps", c.IMPLOT_AXIS_AUTOFIT, c.IMPLOT_AXIS_AUTOFIT)
			c.implot_setup_axis_limits(c.IMPLOT_AXIS_X1, t - HISTORY_SECONDS, t, true)
			c.implot_plot_line("fps", xs, fps)
			c.implot_end_plot()
		c.same_line()
		if c.implot_begin_plot("Frame time (ms)", Vector2(w, h)):
			c.implot_setup_axes("t", "ms", c.IMPLOT_AXIS_AUTOFIT, c.IMPLOT_AXIS_AUTOFIT)
			c.implot_setup_axis_limits(c.IMPLOT_AXIS_X1, t - HISTORY_SECONDS, t, true)
			c.implot_plot_line("ms", xs, frame)
			c.implot_end_plot()
		c.new_line()
		if c.implot_begin_plot("Memoria (MB)", Vector2(-1, h)):
			c.implot_setup_axes("t", "MB", c.IMPLOT_AXIS_AUTOFIT, c.IMPLOT_AXIS_AUTOFIT)
			c.implot_setup_axis_limits(c.IMPLOT_AXIS_X1, t - HISTORY_SECONDS, t, true)
			c.implot_plot_line("estatica", xs, mem)
			c.implot_plot_line("dinamica", xs, dyn)
			c.implot_end_plot()
	else:
		c.plot_lines("FPS", fps, "", 0.0, 0.0, Vector2(w, h))
		c.same_line()
		c.plot_lines("Frame time (ms)", frame, "", 0.0, 0.0, Vector2(w, h))
		c.plot_lines("Memoria (MB)", mem, "", 0.0, 0.0, Vector2(-1, h))

	c.separator()
	c.text("objetos %.0f  nodos %.0f  huerfanos %.0f  draws %.0f  obj/frame %.0f" % [
		Performance.get_monitor(Performance.OBJECT_COUNT),
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		Performance.get_monitor(Performance.RENDER_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_OBJECTS_IN_FRAME),
	])
	c.text("fisica 2D act %.0f  fisica 3D act %.0f  pares 3D %.0f" % [
		Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
	])


func _fetch_logs():
	if not Engine.has_singleton("DebugLog"):
		return
	var incoming = DebugLog.get_entries(last_log_id)
	for entry in incoming:
		logs.append(entry)
		last_log_id = entry["id"]
	while logs.size() > MAX_LOGS:
		logs.pop_front()


func _tab_console(c):
	var avail = c.get_content_region_avail()
	console_filter = c.input_text("Filtro", console_filter)
	c.same_line()
	c.checkbox("Autoscroll", console_scroll)
	c.same_line()
	if c.button("Limpiar"):
		logs = []
		if Engine.has_singleton("DebugLog"):
			DebugLog.clear()

	var log_h = max(avail.y - 96.0, 80.0)
	if c.begin_child("##hud_log", Vector2(-1, log_h)):
		for entry in logs:
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

	# Tras enviar, el id del widget cambia y ImGui pierde el foco; lo recuperamos
	# en el siguiente frame (SetKeyboardFocusHere afecta al input que se dibuja despues).
	if command_refocus and c.has_method("set_keyboard_focus_here"):
		c.set_keyboard_focus_here()
	command_refocus = false

	var result = c.input_text_enter("##hud_cmd_%d" % command_label, command_text)
	command_text = result["text"]
	if result["submitted"]:
		var line = command_text
		command_text = ""
		# Cambiar el id del widget resetea el estado interno de ImGui tras enviar.
		command_label += 1
		run_command(line)
		command_refocus = true

	# Historial con flechas; is_key_pressed lee el input que ya capturo ImGui.
	if c.is_key_pressed(KEY_UP):
		_history_move(1)
	elif c.is_key_pressed(KEY_DOWN):
		_history_move(-1)

	c.same_line()
	c.text("Enter ejecuta; flechas: historial")


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


func _tab_monitors(c):
	var monitors = [
		["TIME_FPS", Performance.TIME_FPS],
		["TIME_PROCESS", Performance.TIME_PROCESS],
		["TIME_PHYSICS_PROCESS", Performance.TIME_PHYSICS_PROCESS],
		["MEMORY_STATIC", Performance.MEMORY_STATIC],
		["MEMORY_DYNAMIC", Performance.MEMORY_DYNAMIC],
		["MEMORY_STATIC_MAX", Performance.MEMORY_STATIC_MAX],
		["MEMORY_DYNAMIC_MAX", Performance.MEMORY_DYNAMIC_MAX],
		["MEMORY_MESSAGE_BUFFER_MAX", Performance.MEMORY_MESSAGE_BUFFER_MAX],
		["OBJECT_COUNT", Performance.OBJECT_COUNT],
		["OBJECT_RESOURCE_COUNT", Performance.OBJECT_RESOURCE_COUNT],
		["OBJECT_NODE_COUNT", Performance.OBJECT_NODE_COUNT],
		["OBJECT_ORPHAN_NODE_COUNT", Performance.OBJECT_ORPHAN_NODE_COUNT],
		["RENDER_OBJECTS_IN_FRAME", Performance.RENDER_OBJECTS_IN_FRAME],
		["RENDER_VERTICES_IN_FRAME", Performance.RENDER_VERTICES_IN_FRAME],
		["RENDER_MATERIAL_CHANGES_IN_FRAME", Performance.RENDER_MATERIAL_CHANGES_IN_FRAME],
		["RENDER_SHADER_CHANGES_IN_FRAME", Performance.RENDER_SHADER_CHANGES_IN_FRAME],
		["RENDER_SURFACE_CHANGES_IN_FRAME", Performance.RENDER_SURFACE_CHANGES_IN_FRAME],
		["RENDER_DRAW_CALLS_IN_FRAME", Performance.RENDER_DRAW_CALLS_IN_FRAME],
		["RENDER_2D_ITEMS_IN_FRAME", Performance.RENDER_2D_ITEMS_IN_FRAME],
		["RENDER_2D_DRAW_CALLS_IN_FRAME", Performance.RENDER_2D_DRAW_CALLS_IN_FRAME],
		["RENDER_VIDEO_MEM_USED", Performance.RENDER_VIDEO_MEM_USED],
		["RENDER_TEXTURE_MEM_USED", Performance.RENDER_TEXTURE_MEM_USED],
		["RENDER_VERTEX_MEM_USED", Performance.RENDER_VERTEX_MEM_USED],
		["RENDER_USAGE_VIDEO_MEM_TOTAL", Performance.RENDER_USAGE_VIDEO_MEM_TOTAL],
		["PHYSICS_2D_ACTIVE_OBJECTS", Performance.PHYSICS_2D_ACTIVE_OBJECTS],
		["PHYSICS_2D_COLLISION_PAIRS", Performance.PHYSICS_2D_COLLISION_PAIRS],
		["PHYSICS_2D_ISLAND_COUNT", Performance.PHYSICS_2D_ISLAND_COUNT],
		["PHYSICS_3D_ACTIVE_OBJECTS", Performance.PHYSICS_3D_ACTIVE_OBJECTS],
		["PHYSICS_3D_COLLISION_PAIRS", Performance.PHYSICS_3D_COLLISION_PAIRS],
		["PHYSICS_3D_ISLAND_COUNT", Performance.PHYSICS_3D_ISLAND_COUNT],
		["AUDIO_OUTPUT_LATENCY", Performance.AUDIO_OUTPUT_LATENCY],
	]
	var avail = c.get_content_region_avail()
	if c.begin_child("##hud_mon", Vector2(-1, max(avail.y - 8.0, 80.0))):
		if c.begin_table("##hud_mon_table", 2, c.TABLE_BORDERS | c.TABLE_ROW_BG | c.TABLE_RESIZABLE):
			c.table_setup_column("Monitor")
			c.table_setup_column("Valor")
			c.table_headers_row()
			for entry in monitors:
				c.table_next_row()
				c.table_next_column()
				c.text(entry[0])
				c.table_next_column()
				c.text("%.3f" % Performance.get_monitor(entry[1]))
			c.end_table()
	c.end_child()


# --- Comandos ---

func run_command(line):
	line = line.strip_edges()
	if line == "":
		return
	command_history.push_front(line)
	while command_history.size() > 50:
		command_history.pop_back()
	command_index = -1

	var space = line.find(" ")
	var name = line if space < 0 else line.substr(0, space)
	var rest = "" if space < 0 else line.substr(space + 1).strip_edges()
	if not commands.has(name):
		printerr("comando desconocido: ", name)
		return
	var cmd = commands[name]
	cmd["target"].callv(cmd["method"], [rest])


func _cmd_help(_args):
	print("Comandos disponibles:")
	for name in commands.keys():
		print("  %-10s %s" % [name, commands[name]["help"]])


func _cmd_clear(_args):
	logs = []
	if Engine.has_singleton("DebugLog"):
		DebugLog.clear()
		last_log_id = DebugLog.last_id()
	print("consola limpia")


func _cmd_fps(args):
	var n = int(args) if args != "" else 0
	Engine.target_fps = n
	print("target_fps = ", n)


func _cmd_timescale(args):
	var x = float(args) if args != "" else 1.0
	Engine.time_scale = x
	print("time_scale = ", x)


func _cmd_vsync(args):
	var on = args.to_lower() != "off"
	OS.vsync_enabled = on
	print("vsync = ", on)


func _cmd_quit(_args):
	get_tree().quit()


func _cmd_eval(expr):
	if expr == "":
		printerr("eval: falta la expresion")
		return
	var target = get_tree().current_scene
	var expression = Expression.new()
	var error = expression.parse(expr, PoolStringArray(["scene"]))
	if error != OK:
		printerr("eval: ", expression.get_error_text())
		return
	var result = expression.execute([target], null, true)
	if expression.has_execute_failed():
		printerr("eval: ", expression.get_error_text())
		return
	print(str(result))
