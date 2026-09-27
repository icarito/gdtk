extends ImGuiCanvas

var ACTIVITIES = [
	{"name": "Chat", "script": "res://activities/chat.gd"},
	{"name": "Panel", "script": "res://activities/panel.gd"},
	{"name": "Terminal", "wayland": ["alacritty"]},
	{"name": "Gears", "wayland": ["es2gears_wayland"]},
	{"name": "GTK", "wayland": ["gtk4-widget-factory"]},
	# Servicio: el botón prende/apaga un proceso en segundo plano (no abre vista).
	# Deskflow inyecta input vía XTest: sólo tiene sentido en la sesión X11.
	{"name": "Deskflow", "service": "deskflow-core client --new-instance -s ~/gdtk/deskflow-client.conf", "session": "x11"},
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
var view_offset = Vector2.ZERO
var requested_sizes = {}
# Los buffers wayland vienen con alfa premultiplicado.
var premult_material = null

var frame_count = 0
var screenshot_path = ""
var open_on_start = ""
var type_text = ""
var typed = false
var type_queue = []
var type_done_frame = -1
var tex_ready_frame = -1

# Dialogos: toplevels con padre. No se asignan a ninguna actividad: se dibujan
# centrados sobre la vista de su ventana raiz, en orden de creacion (el ultimo
# arriba). El padre puede cambiar por set_parent, se consulta cada frame.
var dialogs = []
var focused_dialog = 0
var dialog_view = null
var dialog_boxes = {}
# Toplevels sin padre y sin launch pendiente: esperan app_id/titulo para crear
# la actividad dinamica (en `added` todavia no se conocen).
var unmanaged = []


func _ready():
	connect("imgui_frame", self, "_imgui_frame")
	compositor.connect("toplevel_added", self, "_on_toplevel_added")
	compositor.connect("toplevel_removed", self, "_on_toplevel_removed")
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	view.connect("gui_input", self, "_on_view_input")

	# Capa de dialogos encima de la vista de la actividad.
	dialog_view = Control.new()
	dialog_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dialog_view.rect_clip_content = true
	dialog_view.visible = false
	$ViewLayer.add_child(dialog_view)

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
	_process_unmanaged()
	if current_activity == null:
		_draw_home()
	else:
		_draw_activity()

	var id = _current_wayland_id()
	if id >= 0:
		_update_layers(id)
	_update_dialogs(id)

	# HUD de debug global (autoload DebugHud): F1/` lo abren en cualquier actividad.
	DebugHud.draw(self)

	frame_count += 1
	_run_test_logic()


# Dibuja todo el arbol de surfaces del toplevel: un TextureRect hijo por capa,
# reusado por indice, en el orden devuelto por el compositor (raiz -> popups).
func _update_layers(id):
	var layers = compositor.get_layers(id)
	var vp = get_viewport_rect().size
	view.rect_size = Vector2(vp.x, max(vp.y - BAR_H, 1.0))

	# 1:1, sin escalar: escalar el buffer (que incluye las sombras CSD) deformaba el texto.
	# Se desplaza por la geometría para que el contenido quede en el origen de la vista;
	# las sombras caen fuera y las recorta rect_clip_content.
	var geo = compositor.get_geometry(id)
	view_offset = -geo.position
	# La vista puede cambiar de tamaño después de abrir la ventana (p.ej. --fullscreen se aplica
	# tras el primer frame): se vuelve a pedir el tamaño. Se compara contra lo pedido, no contra
	# geo.size, porque hay clientes (alacritty) que redondean a su grilla de celdas.
	if geo.size != Vector2.ZERO and requested_sizes.get(id) != view.rect_size:
		requested_sizes[id] = view.rect_size
		compositor.default_size = view.rect_size
		compositor.set_size(id, view.rect_size)

	_ensure_layer_nodes(layers.size())
	for i in range(layers.size()):
		var node = view.get_child(i)
		var layer = layers[i]
		var size = layer.rect.size
		if (size.x <= 0.0 or size.y <= 0.0) and layer.texture != null:
			size = layer.texture.get_size()
		node.texture = layer.texture
		node.rect_position = layer.rect.position + view_offset
		node.rect_size = size
		node.visible = layer.texture != null
	for i in range(layers.size(), view.get_child_count()):
		view.get_child(i).visible = false

	if tex_ready_frame < 0 and layers.size() > 0 and layers[0].texture != null:
		tex_ready_frame = frame_count


func _ensure_premult_material():
	if premult_material == null:
		premult_material = CanvasItemMaterial.new()
		premult_material.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA


func _ensure_layer_nodes(count):
	_ensure_premult_material()
	while view.get_child_count() < count:
		var child = TextureRect.new()
		child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		child.expand = true
		child.stretch_mode = TextureRect.STRETCH_SCALE
		child.material = premult_material
		child.visible = false
		view.add_child(child)


# --- Dialogos: capas centradas sobre la vista de su toplevel raiz ---

func _update_dialogs(root_id):
	if dialog_view == null:
		return
	dialog_view.rect_position = Vector2(0.0, BAR_H)
	dialog_view.rect_size = view.rect_size

	for i in range(dialogs.size() - 1, -1, -1):
		if not _id_alive(dialogs[i]):
			dialogs.remove(i)
	for d in dialog_boxes.keys():
		if not _id_alive(d):
			var box = dialog_boxes[d]
			dialog_boxes.erase(d)
			if box != null and is_instance_valid(box):
				box.queue_free()

	var any_visible = false
	for d in dialogs:
		var box = dialog_boxes.get(d)
		if box == null:
			box = _new_dialog_box(d)
		var visible = root_id >= 0 and _root_of(d) == root_id
		box.visible = visible
		if visible:
			any_visible = true
			_layout_dialog(box, d)
	dialog_view.visible = any_visible and view.visible


func _new_dialog_box(d):
	var box = Control.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.rect_clip_content = true
	box.visible = false
	dialog_view.add_child(box)
	dialog_boxes[d] = box
	return box


# Centra la geometria del dialogo en la vista (sin sombras: la caja recorta).
func _layout_dialog(box, d):
	_ensure_premult_material()
	var geo = _dialog_geo(d)
	var layers = compositor.get_layers(d)
	box.rect_position = view.rect_size * 0.5 - geo.size * 0.5 - geo.position
	box.rect_size = geo.size
	while box.get_child_count() < layers.size():
		var child = TextureRect.new()
		child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		child.expand = true
		child.stretch_mode = TextureRect.STRETCH_SCALE
		child.material = premult_material
		child.visible = false
		box.add_child(child)
	for i in range(layers.size()):
		var node = box.get_child(i)
		var layer = layers[i]
		var size = layer.rect.size
		if (size.x <= 0.0 or size.y <= 0.0) and layer.texture != null:
			size = layer.texture.get_size()
		node.texture = layer.texture
		node.rect_position = layer.rect.position - geo.position
		node.rect_size = size
		node.visible = layer.texture != null
	for i in range(layers.size(), box.get_child_count()):
		box.get_child(i).visible = false


func _dialog_geo(d):
	var geo = compositor.get_geometry(d)
	if geo.size.x > 0.0 and geo.size.y > 0.0:
		return geo
	# Fallback: caja de las capas si el cliente aun no publico geometria.
	var layers = compositor.get_layers(d)
	if layers.size() == 0:
		return geo
	var mn = Vector2(1e9, 1e9)
	var mx = Vector2(-1e9, -1e9)
	for layer in layers:
		mn.x = min(mn.x, layer.rect.position.x)
		mn.y = min(mn.y, layer.rect.position.y)
		mx.x = max(mx.x, layer.rect.position.x + layer.rect.size.x)
		mx.y = max(mx.y, layer.rect.position.y + layer.rect.size.y)
	return Rect2(mn, mx - mn)


func _dialog_rect(d):
	var geo = _dialog_geo(d)
	return Rect2(view.rect_size * 0.5 - geo.size * 0.5 - geo.position, geo.size)


func _root_of(id):
	var guard = 0
	while id > 0 and guard < 32:
		var parent = compositor.get_parent_id(id)
		if parent <= 0:
			break
		id = parent
		guard += 1
	return id


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
			var label = ACTIVITIES[i].name
			if ACTIVITIES[i].has("service") and _service_running(ACTIVITIES[i].name):
				label += " *"
			if button(label + "##" + ACTIVITIES[i].name, btn_size):
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
		var title = ""
		if current_activity != null:
			title = current_activity.name
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
		_release_activity()
		activity_instance = load(activity.script).new()
		current_activity = activity
		activity_error = ""
		return
	if activity.has("wayland"):
		_open_wayland(activity)
	if activity.has("service"):
		_toggle_service(activity)


var service_pids = {}


func _toggle_service(activity):
	var name = activity.name
	if _service_running(name):
		OS.kill(service_pids[name])
		service_pids.erase(name)
		return
	if activity.has("session") and OS.get_environment("GDTK_SESSION") != activity.session:
		activity_error = name + ": sólo en la sesión " + activity.session.to_upper()
		return
	# Vía sh + & para que el proceso quede colgado de init: si lo lanzara Godot directo, al
	# morir quedaría zombie y kill -0 lo seguiría dando por vivo.
	var cmd = activity.service.replace("~/", OS.get_environment("HOME") + "/")
	var log_path = OS.get_environment("XDG_RUNTIME_DIR").plus_file("gdtk-" + name.to_lower() + ".log")
	var out = []
	# Con output, Godot 3 pasa el comando por popen (otro sh, args entre comillas dobles):
	# sin escapar, ese sh externo expande $! a vacío antes de llegar al nuestro.
	OS.execute("sh", ["-c", cmd + " >" + log_path + " 2>&1 & echo \\$!"], true, out)
	var pid = int(String(out[0]).strip_edges()) if out.size() > 0 else 0
	if pid > 0:
		service_pids[name] = pid
		activity_error = ""
	else:
		activity_error = name + ": no se pudo lanzar"


func _service_running(name):
	if not service_pids.has(name):
		return false
	if OS.execute("sh", ["-c", "kill -0 " + str(service_pids[name])], true) != 0:
		service_pids.erase(name)
		return false
	return true


func _open_by_name(name):
	for i in range(ACTIVITIES.size()):
		if ACTIVITIES[i].name == name:
			_activate(i)
			return
	activity_error = "Actividad desconocida: " + name


func _open_wayland(activity):
	var name = activity.name
	_release_activity()
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
	view.rect_clip_content = true
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
	_update_layers(id)


func _go_home():
	_release_activity()
	current_activity = null
	activity_instance = null
	pending_wayland = ""
	typed = false
	type_queue = []
	type_done_frame = -1
	tex_ready_frame = -1
	view.visible = false
	for i in range(view.get_child_count()):
		view.get_child(i).visible = false


# Las actividades tipo script pueden tener recursos propios (p.ej. el viewport
# 3D del Panel). Se les da la opcion de liberarlos al salir de la actividad.
func _release_activity():
	if activity_instance != null and activity_instance.has_method("cleanup"):
		activity_instance.cleanup()


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
	# Un toplevel con padre es un dialogo: no se asigna a ninguna actividad.
	if compositor.get_parent_id(id) > 0:
		_add_dialog(id)
		return
	if pending_wayland != "":
		var name = pending_wayland
		pending_wayland = ""
		wayland_ids[name] = id
		compositor.focus(id)
		if current_activity != null and current_activity.has("wayland") and current_activity.name == name:
			_show_view(id)
		return
	# Sin actividad: se creara una dinamica en cuanto llegue app_id/titulo.
	unmanaged.append(id)


func _add_dialog(id):
	if not dialogs.has(id):
		dialogs.append(id)
	focused_dialog = id
	compositor.focus(id)


# Toplevels sueltos: nombre = app_id capitalizado sin dominio, si no el titulo,
# si no "Ventana <id>". Se crea la actividad, se le asigna el id y se abre
# (una ventana nueva pasa al frente). El nombre debe ser unico en el anillo.
func _process_unmanaged():
	for i in range(unmanaged.size() - 1, -1, -1):
		var id = unmanaged[i]
		if not _id_alive(id):
			unmanaged.remove(i)
			continue
		# El padre llega en el commit inicial, despues de `added`: si aparecio,
		# es un dialogo, no una actividad dinamica.
		if compositor.get_parent_id(id) > 0:
			unmanaged.remove(i)
			_add_dialog(id)
			continue
		var app_id = compositor.get_app_id(id)
		var title = compositor.get_title(id)
		if app_id == "" and title == "":
			continue
		unmanaged.remove(i)
		if _activity_for_window(id) != "":
			continue
		_open_unmanaged_window(id)


func _open_unmanaged_window(id):
	var name = _unique_activity_name(_window_activity_name(id))
	var cmd = compositor.get_app_id(id)
	if cmd == "":
		cmd = name
	var activity = {"name": name, "wayland": [cmd], "dynamic": true}
	ACTIVITIES.append(activity)
	wayland_ids[name] = id

	var vp = get_viewport_rect().size
	view.rect_position = Vector2(0.0, BAR_H)
	view.rect_size = Vector2(vp.x, max(vp.y - BAR_H, 1.0))
	view.rect_clip_content = true
	compositor.default_size = view.rect_size

	current_activity = activity
	activity_instance = null
	activity_error = ""
	pending_wayland = ""
	_show_view(id)
	compositor.focus(id)
	print("actividad dinamica ", name, " para toplevel ", id)


func _activity_for_window(id):
	for name in wayland_ids.keys():
		if wayland_ids[name] == id:
			return name
	return ""


func _window_activity_name(id):
	var app_id = compositor.get_app_id(id)
	if app_id != "":
		var base = app_id
		var dot = base.rfind(".")
		if dot >= 0:
			base = base.substr(dot + 1, base.length() - dot - 1)
		if base != "":
			return base.substr(0, 1).to_upper() + base.substr(1, base.length() - 1)
	var title = compositor.get_title(id)
	if title != "":
		return title
	return "Ventana " + str(id)


func _unique_activity_name(name):
	var candidate = name
	var n = 2
	while _activity_named(candidate) >= 0:
		candidate = name + " " + str(n)
		n += 1
	return candidate


func _activity_named(name):
	for i in range(ACTIVITIES.size()):
		if str(ACTIVITIES[i].get("name", "")) == name:
			return i
	return -1


func _on_toplevel_removed(id):
	print("toplevel_removed ", id)
	var didx = dialogs.find(id)
	if didx >= 0:
		dialogs.remove(didx)
		if dialog_boxes.has(id):
			var box = dialog_boxes[id]
			dialog_boxes.erase(id)
			if box != null and is_instance_valid(box):
				box.queue_free()
		if focused_dialog == id:
			_refocus_dialog()
		return

	unmanaged.erase(id)
	var removed_name = ""
	for name in wayland_ids.keys():
		if wayland_ids[name] == id:
			removed_name = name
			wayland_ids.erase(name)
			break
	if removed_name == "":
		return
	# Las actividades dinamicas se van con su ventana; las fijas quedan.
	var index = _activity_named(removed_name)
	if index >= 0 and ACTIVITIES[index].get("dynamic", false):
		ACTIVITIES.remove(index)
	if current_activity != null and current_activity.has("wayland") and current_activity.name == removed_name:
		_go_home()


# Al cerrarse un dialogo el foco vuelve al que quede arriba: otro dialogo o la raiz.
func _refocus_dialog():
	focused_dialog = 0
	var root = _current_wayland_id()
	for i in range(dialogs.size() - 1, -1, -1):
		if _root_of(dialogs[i]) == root:
			focused_dialog = dialogs[i]
			break
	if focused_dialog > 0:
		compositor.focus(focused_dialog)
	elif root >= 0:
		compositor.focus(root)


func _on_view_input(event):
	if event is InputEventMouseMotion:
		var hit = _view_hit_test(event.position)
		if hit.id < 0:
			return
		compositor.pointer_motion(hit.id, hit.pos)
	elif event is InputEventMouseButton:
		var hit = _view_hit_test(event.position)
		if hit.id < 0:
			return
		compositor.pointer_motion(hit.id, hit.pos)
		compositor.pointer_button(event.button_index, event.pressed)
		if event.pressed:
			compositor.focus(hit.id)
			focused_dialog = hit.dialog


# Hit-test de arriba hacia abajo: el dialogo mas reciente que contenga el
# puntero; si no, la ventana raiz de la actividad (como antes).
func _view_hit_test(pos):
	var root = _current_wayland_id()
	if root < 0:
		return {"id": -1, "pos": Vector2.ZERO, "dialog": 0}
	for i in range(dialogs.size() - 1, -1, -1):
		var d = dialogs[i]
		if _root_of(d) != root:
			continue
		var rect = _dialog_rect(d)
		if rect.has_point(pos):
			var geo = _dialog_geo(d)
			return {"id": d, "pos": pos - rect.position + geo.position, "dialog": d}
	return {"id": root, "pos": pos - view_offset, "dialog": 0}


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
