extends ImGuiCanvas

var ACTIVITIES = [
	{"name": "Chat", "script": "res://activities/chat.gd"},
	{"name": "Terminal", "wayland": ["alacritty"]},
	{"name": "Gears", "wayland": ["es2gears_wayland"]},
	{"name": "GTK", "wayland": ["gtk4-widget-factory"]},
	{"name": "Salir", "quit": true},
]

const BAR_H = 48.0
const TYPE_DELAY = 60
const SHOT_DELAY = 90
const SHOT_MAX_FRAMES = 900

onready var compositor = $Compositor
onready var view = $ViewLayer/View

var current_activity = null
var activity_instance = null
var activity_error = ""
var last_launch_pid = -1

var wayland_ids = {}
var pending_wayland = ""

var frame_count = 0
var screenshot_path = ""
var open_on_start = ""
var type_text = ""
var typed = false
var type_queue = []
var type_done_frame = -1
var tex_ready_frame = -1


func _ready():
	connect("imgui_frame", self, "_imgui_frame")
	compositor.connect("toplevel_added", self, "_on_toplevel_added")
	compositor.connect("toplevel_removed", self, "_on_toplevel_removed")
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	view.connect("gui_input", self, "_on_view_input")

	for arg in OS.get_cmdline_args():
		if arg.begins_with("--screenshot="):
			screenshot_path = arg.substr("--screenshot=".length())
		elif arg.begins_with("--open="):
			open_on_start = arg.substr("--open=".length())
		elif arg.begins_with("--type="):
			type_text = arg.substr("--type=".length())

	var socket = compositor.start()
	if socket == "":
		activity_error = "No se pudo iniciar el compositor wayland"
		printerr(activity_error)
	else:
		print("compositor socket: ", socket)

	if open_on_start != "":
		_open_by_name(open_on_start)


func _imgui_frame():
	if current_activity == null:
		_draw_home()
	else:
		_draw_activity()

	var id = _current_wayland_id()
	if id >= 0:
		var tex = compositor.get_texture(id)
		view.texture = tex
		if tex != null and tex_ready_frame < 0:
			tex_ready_frame = frame_count

	frame_count += 1
	_run_test_logic()


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
	set_next_window_pos(Vector2.ZERO, true)
	set_next_window_size(Vector2(vp.x, BAR_H), true)
	var bar_flags = WINDOW_NO_DECORATION | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS
	if begin("##bar", bar_flags):
		if button("Inicio"):
			_go_home()
		same_line()
		var title = current_activity.name
		var id = _current_wayland_id()
		if id >= 0:
			var wtitle = compositor.get_title(id)
			if wtitle != "":
				title = wtitle
		text(title)
	end()

	if current_activity == null:
		return
	if current_activity.has("script") and activity_instance != null and activity_instance.has_method("draw"):
		set_next_window_pos(Vector2(0.0, BAR_H), true)
		set_next_window_size(Vector2(vp.x, vp.y - BAR_H), true)
		var body_flags = WINDOW_NO_DECORATION | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS
		if begin("##activity", body_flags):
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
	if activity.has("wayland"):
		_open_wayland(activity)


func _open_by_name(name):
	for i in range(ACTIVITIES.size()):
		if ACTIVITIES[i].name == name:
			_activate(i)
			return
	activity_error = "Actividad desconocida: " + name


func _open_wayland(activity):
	var name = activity.name
	current_activity = activity
	activity_instance = null
	activity_error = ""
	pending_wayland = ""

	var id = -1
	if wayland_ids.has(name) and _id_alive(wayland_ids[name]):
		id = wayland_ids[name]

	if id >= 0:
		_show_view(id)
		compositor.focus(id)
		return

	var vp = get_viewport_rect().size
	view.rect_position = Vector2(0.0, BAR_H)
	view.rect_size = Vector2(vp.x, max(vp.y - BAR_H, 1.0))
	compositor.default_size = view.rect_size
	view.visible = false

	var cmd = activity.wayland[0]
	var args = PoolStringArray()
	for i in range(1, activity.wayland.size()):
		args.push_back(activity.wayland[i])

	pending_wayland = name
	var pid = compositor.launch(cmd, args)
	last_launch_pid = pid
	if pid < 0:
		pending_wayland = ""
		activity_error = "No se pudo lanzar " + cmd
		_go_home()
	else:
		print("launched ", cmd, " pid ", pid)


func _show_view(id):
	tex_ready_frame = -1
	typed = false
	type_queue = []
	type_done_frame = -1
	view.visible = true
	view.texture = compositor.get_texture(id)


func _go_home():
	current_activity = null
	activity_instance = null
	pending_wayland = ""
	typed = false
	type_queue = []
	type_done_frame = -1
	tex_ready_frame = -1
	view.visible = false
	view.texture = null


func _current_wayland_id():
	if current_activity == null or not current_activity.has("wayland"):
		return -1
	var name = current_activity.name
	if wayland_ids.has(name) and _id_alive(wayland_ids[name]):
		return wayland_ids[name]
	return -1


func _id_alive(id):
	return compositor.get_ids().has(id)


func _on_toplevel_added(id):
	print("toplevel_added ", id)
	if pending_wayland == "":
		return
	var name = pending_wayland
	pending_wayland = ""
	wayland_ids[name] = id
	compositor.focus(id)
	if current_activity != null and current_activity.has("wayland") and current_activity.name == name:
		_show_view(id)


func _on_toplevel_removed(id):
	print("toplevel_removed ", id)
	var removed_name = ""
	for name in wayland_ids.keys():
		if wayland_ids[name] == id:
			removed_name = name
			wayland_ids.erase(name)
			break
	if removed_name != "" and current_activity != null and current_activity.has("wayland") and current_activity.name == removed_name:
		_go_home()


func _on_view_input(event):
	var id = _current_wayland_id()
	if id < 0:
		return
	if event is InputEventMouseMotion:
		compositor.pointer_motion(id, _view_pos_to_wayland(id, event.position))
	elif event is InputEventMouseButton:
		compositor.pointer_motion(id, _view_pos_to_wayland(id, event.position))
		compositor.pointer_button(event.button_index, event.pressed)
		if event.pressed:
			compositor.focus(id)


func _view_pos_to_wayland(id, pos):
	var tex = compositor.get_texture(id)
	var tex_size = tex.get_size() if tex != null else view.rect_size
	if view.rect_size.x <= 0.0 or view.rect_size.y <= 0.0:
		return pos
	return pos * tex_size / view.rect_size


func _unhandled_input(event):
	if current_activity == null or not current_activity.has("wayland"):
		return
	if not (event is InputEventKey):
		return
	var id = _current_wayland_id()
	if id < 0:
		return
	compositor.key(event)
	get_tree().set_input_as_handled()


func _run_test_logic():
	if current_activity != null and current_activity.has("wayland") and current_activity.name == open_on_start:
		if type_text != "" and not typed and tex_ready_frame >= 0 and frame_count >= tex_ready_frame + TYPE_DELAY:
			_build_type_queue()
			typed = true

	if type_queue.size() > 0:
		_send_next_key()
		if type_queue.size() == 0:
			type_done_frame = frame_count

	if screenshot_path == "":
		return

	if current_activity != null and current_activity.has("wayland"):
		if tex_ready_frame >= 0:
			var target = tex_ready_frame + SHOT_DELAY
			if type_done_frame >= 0 and type_done_frame + 30 > target:
				target = type_done_frame + 30
			if frame_count >= target:
				_capture(screenshot_path)
			elif frame_count >= SHOT_MAX_FRAMES:
				print("screenshot: sin textura")
				_capture(screenshot_path)
		elif frame_count >= SHOT_MAX_FRAMES:
			print("screenshot: sin textura")
			_capture(screenshot_path)
	elif frame_count >= 30:
		_capture(screenshot_path)


func _build_type_queue():
	var i = 0
	while i < type_text.length():
		var ch = type_text.substr(i, 1)
		var code = _char_scancode(ch)
		if ch == "\\" and i + 1 < type_text.length() and type_text.substr(i + 1, 1) == "n":
			code = KEY_ENTER
			i += 1
		i += 1
		if code != 0:
			type_queue.push_back(code)


func _send_next_key():
	var code = type_queue.pop_front()
	var press = InputEventKey.new()
	press.physical_scancode = code
	press.scancode = code
	press.pressed = true
	compositor.key(press)
	var release = InputEventKey.new()
	release.physical_scancode = code
	release.scancode = code
	release.pressed = false
	compositor.key(release)


func _char_scancode(ch):
	var c = ord(ch)
	if c >= 97 and c <= 122:
		return KEY_A + (c - 97)
	if c >= 48 and c <= 57:
		return KEY_0 + (c - 48)
	if c == 32:
		return KEY_SPACE
	if c == 10:
		return KEY_ENTER
	return 0


func _capture(path):
	var image = get_viewport().get_texture().get_data()
	image.flip_y()
	var err = image.save_png(path)
	if err != OK:
		printerr("screenshot: no se pudo guardar ", path, " (error ", err, ")")
	print("commit_count=", compositor.commit_count, " dmabuf_commits=", compositor.dmabuf_commits, " shm_commits=", compositor.shm_commits)
	print("dmabuf: ", compositor.dmabuf_state)
	get_tree().quit()
