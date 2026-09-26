extends ImGuiCanvas

const ACTIVITIES = [
	{"name": "Chat", "script": "res://activities/chat.gd"},
	{"name": "Terminal", "cmd": ["alacritty", "kgx"]},
	{"name": "Salir", "quit": true},
]

var current_activity = null
var activity_instance = null
var activity_error = ""

var frame_count = 0
var screenshot_path = ""
var open_on_start = ""


func _ready():
	connect("imgui_frame", self, "_imgui_frame")
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--screenshot="):
			screenshot_path = arg.substr("--screenshot=".length())
		elif arg.begins_with("--open="):
			open_on_start = arg.substr("--open=".length())
	if open_on_start != "":
		_open_by_name(open_on_start)


func _imgui_frame():
	if current_activity == null:
		_draw_home()
	else:
		_draw_activity()

	frame_count += 1
	if screenshot_path != "" and frame_count >= 30:
		_capture(screenshot_path)


func _draw_home():
	var vp = get_viewport_rect().size
	set_next_window_pos(Vector2.ZERO, true)
	set_next_window_size(vp, true)
	var flags = WINDOW_NO_DECORATION | WINDOW_NO_BACKGROUND | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS | WINDOW_NO_BRING_TO_FRONT_ON_FOCUS
	if begin("##home", flags):
		var center = vp * 0.5

		var user = OS.get_environment("USER")
		if user == "":
			user = "user"
		var user_size = Vector2(150, 150)
		set_cursor_pos(center - user_size * 0.5)
		button(user, user_size)

		var radius = 0.3 * min(vp.x, vp.y)
		var btn_size = Vector2(110, 110)
		for i in range(ACTIVITIES.size()):
			var angle = -PI / 2.0 + TAU * float(i) / float(ACTIVITIES.size())
			var pos = center + Vector2(cos(angle), sin(angle)) * radius - btn_size * 0.5
			set_cursor_pos(pos)
			if button(ACTIVITIES[i].name, btn_size):
				_activate(i)

		var t = OS.get_time()
		var clock = "%02d:%02d" % [t.hour, t.minute]
		set_cursor_pos(Vector2(vp.x - 100.0, vp.y - 45.0))
		text(clock)

		if activity_error != "":
			set_cursor_pos(Vector2(20.0, vp.y - 45.0))
			text(activity_error)
	end()


func _draw_activity():
	var vp = get_viewport_rect().size
	var bar_h = 48.0
	set_next_window_pos(Vector2.ZERO, true)
	set_next_window_size(Vector2(vp.x, bar_h), true)
	var bar_flags = WINDOW_NO_DECORATION | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS
	if begin("##bar", bar_flags):
		var activity_name = current_activity.name
		if button("Inicio"):
			_go_home()
		same_line()
		text(activity_name)
	end()

	if current_activity == null:
		return

	set_next_window_pos(Vector2(0.0, bar_h), true)
	set_next_window_size(Vector2(vp.x, vp.y - bar_h), true)
	var body_flags = WINDOW_NO_DECORATION | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS
	if begin("##activity", body_flags):
		if activity_instance != null and activity_instance.has_method("draw"):
			activity_instance.draw(self)
	end()


func _activate(index):
	var activity = ACTIVITIES[index]
	if activity.has("quit") and activity.quit:
		get_tree().quit()
		return
	if activity.has("script"):
		activity_instance = load(activity.script).new()
		current_activity = activity
		activity_error = ""
		return
	if activity.has("cmd"):
		_launch_external(activity)


func _open_by_name(name):
	for i in range(ACTIVITIES.size()):
		if ACTIVITIES[i].name == name:
			_activate(i)
			return
	activity_error = "Actividad desconocida: " + name


func _launch_external(activity):
	var found = ""
	for exe in activity.cmd:
		var out = []
		var code = OS.execute("sh", ["-c", "command -v " + exe], true, out)
		if code == 0 and out.size() > 0 and String(out[0]).strip_edges() != "":
			found = exe
			break
	if found == "":
		activity_error = "No se encontró: " + PoolStringArray(activity.cmd).join(", ")
		return
	var pid = OS.execute(found, [], false)
	print("launched ", found, " pid ", pid)
	activity_error = ""


func _go_home():
	current_activity = null
	activity_instance = null


func _capture(path):
	var image = get_viewport().get_texture().get_data()
	image.flip_y()
	var err = image.save_png(path)
	if err != OK:
		printerr("screenshot: no se pudo guardar ", path, " (error ", err, ")")
	get_tree().quit()
