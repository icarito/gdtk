extends ImGuiCanvas

var ACTIVITIES = [
	{"name": "Chat", "script": "res://activities/chat.gd"},
	{"name": "Panel", "script": "res://activities/panel.gd"},
	{"name": "Terminal", "wayland": ["alacritty"]},
	{"name": "Gears", "wayland": ["es2gears_wayland"]},
	{"name": "GTK", "wayland": ["gtk4-widget-factory"]},
	# Servicio: el botón prende/apaga un proceso en segundo plano (no abre vista).
	# Deskflow: en X11 inyecta por XTest; en Wayland (cage, sway) pide el portal RemoteDesktop
	# y le llega un fd del EIS del shell (RemoteInput): se le da permiso sin preguntar.
	{"name": "Deskflow", "service": "deskflow-core client --new-instance -s ~/gdtk/deskflow-client.conf"},
	{"name": "Salir", "quit": true},
]

const TYPE_DELAY = 60
const SHOT_DELAY = 90
const SHOT_MAX_FRAMES = 900

onready var compositor = $Compositor
onready var view = $ViewLayer/View

var current_activity = null
var activity_instance = null
# Instancias de actividades internas abiertas: se conservan al ir al Home o a otra
# ventana (el Frame las lista); sólo cerrarlas desde el Frame las descarta.
var script_instances = {}
var frame = null
var activity_error = ""
var last_launch_pid = -1

var wayland_ids = {}
var pending_wayland = ""
var requested_sizes = {}
# Los buffers wayland vienen con alfa premultiplicado.
var premult_material = null

var frame_count = 0
var screenshot_path = ""
var open_on_start = ""
var recovery = preload("res://recovery.gd").new()
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

# Home: anillo de actividades o grilla de apps instaladas (Tab alterna).
var apps = preload("res://apps.gd").new()
var apps_view = false

# Input remoto por libei (Deskflow, lan-mouse): EIS + portal RemoteDesktop en el módulo.
var remote_input = null
var input_requests = []  # pedidos de otros procesos esperando el diálogo
var eis_cursor = null  # sin cursor propio el host (cage/sway) no lo mueve: se dibuja uno

# --- Tiling ---
# Cada ventana raíz vive en un tile, uno al lado del otro (1:1, sin escalar: se pide
# el tamaño del tile al cliente). `focused_tile` recibe teclado y clics; `tiles` es el
# orden de layout. `expose` es la vista de miniaturas (las mismas ventanas, escaladas).
var tiles = []
var focused_tile = -1
var tile_mode = false
var tile_nodes = {}      # id -> Control (contenedor de capas del tile)
var tile_rects = {}      # id -> Rect2 en coords de la vista
var tile_anim = {}       # id -> {"from": Vector2, "since": int}
var tile_fade = {}       # id -> ms en que apareció (fade-in)
var expose = false
var expose_sel = 0
var expose_cards = {}    # id -> Rect2 de la tarjeta en exposé
var focus_flash = 0      # ms del último cambio de foco (borde que destella)
var tiles_ui = null
var expose_bg = null     # fondo oscuro de exposé, detrás de los tiles
const TILE_GAP = 3.0
const TILE_ANIM_MS = 150
const TILE_FADE_MS = 150
const FOCUS_FLASH_MS = 260


func _ready():
	connect("imgui_frame", self, "_imgui_frame")
	compositor.connect("toplevel_added", self, "_on_toplevel_added")
	compositor.connect("toplevel_removed", self, "_on_toplevel_removed")
	compositor.connect("toplevel_activate", self, "_on_toplevel_activate")
	# Cambios de ventanas: rearmar la UI (el Frame las lista, recovery espera la suya).
	compositor.connect("toplevel_added", self, "_redraw_on_signal")
	compositor.connect("toplevel_removed", self, "_redraw_on_signal")
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	view.connect("gui_input", self, "_on_view_input")
	# Hijo después de Remote: su _input corre antes que el de ImGui (F6, Alt+Tab).
	frame = preload("res://frame.gd").new()
	frame.name = "Frame"
	add_child(frame)
	# Notificaciones y demás layer-shell, encima de todo (después del Frame: su _input va antes).
	add_child(preload("res://layers.gd").new())

	# Capa de dialogos encima de la vista de la actividad.
	dialog_view = Control.new()
	dialog_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dialog_view.rect_clip_content = true
	dialog_view.visible = false
	$ViewLayer.add_child(dialog_view)

	# Bordes de foco, títulos y tarjetas de exposé: se dibuja a mano (Control._draw) y no
	# captura input, así los clics siguen llegando a los tiles (una ventana ImGui sí lo haría).
	tiles_ui = Control.new()
	tiles_ui.name = "TilesUI"
	tiles_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tiles_ui.rect_clip_content = false
	tiles_ui.set_script(preload("res://tiles_ui.gd"))
	tiles_ui.shell = self
	$ViewLayer.add_child(tiles_ui)

	# Fondo de exposé: detrás de los tiles (View) para no tapar las miniaturas.
	expose_bg = ColorRect.new()
	expose_bg.color = Color(0.05, 0.06, 0.08, 0.92)
	expose_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	expose_bg.visible = false
	$ViewLayer.add_child(expose_bg)
	$ViewLayer.move_child(expose_bg, 0)

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

	remote_input = RemoteInput.new()
	remote_input.name = "RemoteInput"
	add_child(remote_input)
	remote_input.connect("access_requested", self, "_on_input_access")
	var rerr = remote_input.start()
	if rerr != "":
		print("RemoteInput: ", rerr)
	eis_cursor = _make_eis_cursor()

	# Sin redibujo continuo: ImGui se arma sólo con input (a input_hz), con
	# request_redraw() (commits Wayland, señales, control remoto) o al cambiar el minuto (reloj).
	# Los tests con --screenshot cuentan frames: ahí se deja el modo histórico.
	if screenshot_path == "":
		# Nada periódico: el reloj pide su frame justo cuando cambia el minuto.
		update_hz = 0.001
		input_hz = 60.0
		_arm_clock()
	# El colector del HUD corría en cada vuelta del loop (60/s) aunque nada cambie.
	DebugHud.metrics.sample_hz = 4.0
	# Ni widget mini ni F1: el HUD completo se abre con Super+F6 (frame.gd).
	DebugHud.show_mini = false
	DebugHud.hotkeys = false

	# Las sesiones apagan audio/hidapi de SDL para el shell (hilos que despiertan sin
	# uso); vacías, las apps que lanza el compositor vuelven a los valores por defecto.
	for v in ["SDL_AUDIODRIVER", "SDL_JOYSTICK_HIDAPI", "SDL_HIDAPI_LIBUSB"]:
		OS.set_environment(v, "")

	recovery.load(self)
	if open_on_start != "":
		_open_by_name(open_on_start)


var last_commits = 0
# Loop del motor: sin input, commits ni animación por IDLE_MS, duerme más entre vueltas
# (60 -> 4 vueltas/s en reposo). El primer evento tras el reposo tarda hasta SLEEP_IDLE.
const IDLE_MS = 3000
const SLEEP_ACTIVE = 16000
const SLEEP_IDLE = 250000
var last_activity = 0


# Un commit Wayland puede traer capas/texturas nuevas (y con dmabuf el VisualServer
# no se entera de que cambió el contenido): se rearma el frame siguiente.
func _process(_delta):
	var now = OS.get_ticks_msec()
	if compositor.commit_count != last_commits:
		last_commits = compositor.commit_count
		last_activity = now
		request_redraw()
	if activity_instance != null and activity_instance.get("animate"):
		last_activity = now
	if screenshot_path == "":
		var sleep = SLEEP_IDLE if now - last_activity > IDLE_MS else SLEEP_ACTIVE
		if OS.low_processor_usage_mode_sleep_usec != sleep:
			OS.low_processor_usage_mode_sleep_usec = sleep


func _arm_clock():
	var t = OS.get_time()
	get_tree().create_timer(60.05 - t.second).connect("timeout", self, "_on_minute")


func _on_minute():
	request_redraw()
	_arm_clock()


func _redraw_on_signal(_id):
	request_redraw()


func _imgui_frame():
	# Actividades internas animadas (Panel con animación) piden frames continuos.
	if activity_instance != null and activity_instance.get("animate"):
		request_redraw()
	recovery.tick(self)
	_process_unmanaged()
	# Fundido al cambiar de vista (ver frame.transition); 0 = ImGuiStyleVar_Alpha.
	var fade = frame.transition()
	if fade < 1.0:
		push_style_var_float(0, fade)
	if current_activity == null:
		_draw_home()
	else:
		_draw_activity()
	if fade < 1.0:
		pop_style_var()

	# Tiling: con alguna ventana abierta y una actividad wayland activa se muestran todos
	# los tiles a la vez; en Home o en una actividad de script, la vista se oculta.
	tile_mode = current_activity != null and current_activity.has("wayland") and not tiles.empty()
	if tile_mode:
		view.visible = true
		_update_tiles()
	else:
		view.visible = false
	var id = _current_wayland_id()
	_update_dialogs(id)
	if tiles_ui != null:
		tiles_ui.rect_size = get_viewport_rect().size
		tiles_ui.refresh()
	if expose_bg != null:
		expose_bg.rect_size = get_viewport_rect().size
		expose_bg.visible = expose
	frame.draw(self)

	_draw_input_requests()
	# HUD de debug global (autoload DebugHud): Super+F6 lo abre en cualquier actividad (frame.gd).
	DebugHud.draw(self)

	frame_count += 1
	_run_test_logic()


# --- Tiling: varios toplevels a la vez, uno por tile ---

# Hasta 3 ventanas en una fila; con más, grilla de columnas = techo(sqrt(n)).
func _tile_cols():
	var n = tiles.size()
	if n <= 3:
		return max(n, 1)
	return int(ceil(sqrt(float(n))))


func _compute_tile_layout():
	tile_rects.clear()
	var n = tiles.size()
	if n == 0:
		return
	var vp = get_viewport_rect().size
	var cols = _tile_cols()
	var rows = int(ceil(float(n) / float(cols)))
	var gap = TILE_GAP
	var cw = (vp.x - gap * float(cols + 1)) / float(cols)
	var ch = (vp.y - gap * float(rows + 1)) / float(rows)
	for i in range(n):
		var c = i % cols
		var r = i / cols
		tile_rects[tiles[i]] = Rect2(gap + float(c) * (cw + gap), gap + float(r) * (ch + gap), cw, ch)


# Tarjetas de exposé: grilla centrada de hasta 3 miniaturas por fila.
func _compute_expose_layout():
	expose_cards.clear()
	var n = tiles.size()
	if n == 0:
		return
	var vp = get_viewport_rect().size
	expose_sel = int(clamp(expose_sel, 0, max(n - 1, 0)))
	var cols = 3 if n > 3 else n
	var rows = int(ceil(float(n) / float(cols)))
	var pad = 28.0
	var gap = 18.0
	var cw = (vp.x - pad * 2.0 - gap * float(cols - 1)) / float(cols)
	var ch = (vp.y - pad * 2.0 - gap * float(rows - 1)) / float(rows)
	for i in range(n):
		var c = i % cols
		var r = i / cols
		expose_cards[tiles[i]] = Rect2(pad + float(c) * (cw + gap), pad + float(r) * (ch + gap), cw, ch)


func _tile_node(id):
	var node = tile_nodes.get(id)
	if node == null or not is_instance_valid(node):
		_ensure_premult_material()
		node = Control.new()
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		node.rect_clip_content = true
		view.add_child(node)
		tile_nodes[id] = node
	return node


# Un TextureRect por capa del árbol del toplevel, reusado por índice (raíz -> popups).
func _fill_nodes(box, layers, off):
	_ensure_premult_material()
	while box.get_child_count() < layers.size():
		var t = TextureRect.new()
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.expand = true
		t.stretch_mode = TextureRect.STRETCH_SCALE
		t.material = premult_material
		t.visible = false
		box.add_child(t)
	for i in range(layers.size()):
		var node = box.get_child(i)
		var layer = layers[i]
		var size = layer.rect.size
		if (size.x <= 0.0 or size.y <= 0.0) and layer.texture != null:
			size = layer.texture.get_size()
		node.texture = layer.texture
		node.rect_position = layer.rect.position + off
		node.rect_size = size
		node.visible = layer.texture != null
	for i in range(layers.size(), box.get_child_count()):
		box.get_child(i).visible = false


func _update_tiles():
	view.rect_size = get_viewport_rect().size
	compositor.default_size = view.rect_size
	if expose:
		_compute_expose_layout()
	else:
		_compute_tile_layout()
	for id in tile_nodes.keys():
		if not tiles.has(id):
			var node = tile_nodes[id]
			tile_nodes.erase(id)
			tile_rects.erase(id)
			expose_cards.erase(id)
			tile_anim.erase(id)
			tile_fade.erase(id)
			if node != null and is_instance_valid(node):
				node.queue_free()
	var now = OS.get_ticks_msec()
	for id in tiles:
		if _id_alive(id):
			_update_tile(id, now)
			if expose:
				compositor.get_layers(id)  # cuenta como dibujado: la miniatura sigue viva


func _update_tile(id, now):
	var node = _tile_node(id)
	var geo = compositor.get_geometry(id)
	var layers = compositor.get_layers(id)
	_fill_nodes(node, layers, -geo.position)

	if expose:
		# Miniatura: se escala el nodo entero (la app conserva su tamaño de tile) y se centra.
		var card = expose_cards.get(id, Rect2(Vector2.ZERO, view.rect_size))
		var size = node.rect_size
		if size.x <= 0.0 or size.y <= 0.0:
			size = card.size
		var s = min(min(card.size.x / max(size.x, 1.0), card.size.y / max(size.y, 1.0)), 1.0)
		node.rect_scale = Vector2(s, s)
		node.rect_position = card.position + (card.size - size * s) * 0.5
		node.modulate = Color(1, 1, 1, 1)
		return

	var rect = tile_rects.get(id, Rect2(Vector2.ZERO, view.rect_size))
	# Desliza desde donde estaba a su celda nueva (abrir, reacomodar, intercambiar).
	var pos = rect.position
	if tile_anim.has(id):
		var a = tile_anim[id]
		var k = clamp(float(now - a.since) / TILE_ANIM_MS, 0.0, 1.0)
		pos = a.from.linear_interpolate(rect.position, 1.0 - pow(1.0 - k, 3.0))
		if k >= 1.0:
			tile_anim.erase(id)
		else:
			request_redraw()
	elif node.rect_position.distance_to(rect.position) > 0.5:
		tile_anim[id] = {"from": node.rect_position, "since": now}
		request_redraw()
	node.rect_scale = Vector2.ONE
	node.rect_position = pos
	node.rect_size = rect.size
	# Fade-in de una ventana recién abierta.
	var mod = 1.0
	if tile_fade.has(id):
		var k = clamp(float(now - tile_fade[id]) / TILE_FADE_MS, 0.0, 1.0)
		mod = 1.0 - pow(1.0 - k, 3.0)
		if k >= 1.0:
			tile_fade.erase(id)
		else:
			request_redraw()
	node.modulate = Color(mod, mod, mod, mod)

	# 1:1 con el tamaño del tile: se le pide al cliente que se ajuste (texto nítido).
	if geo.size != Vector2.ZERO and requested_sizes.get(id) != rect.size:
		requested_sizes[id] = rect.size
		compositor.set_size(id, rect.size)
	if tex_ready_frame < 0 and id == focused_tile and layers.size() > 0 and layers[0].texture != null:
		tex_ready_frame = frame_count


func _focus_tile(id):
	if id < 0 or not _id_alive(id):
		return
	if not tiles.has(id):
		tiles.append(id)
	focused_tile = id
	focus_flash = OS.get_ticks_msec()
	var name = _activity_for_window(id)
	var i = _activity_named(name)
	if i >= 0:
		current_activity = ACTIVITIES[i]
	compositor.focus(id)
	request_redraw()


# Mueve el foco a la celda vecina. dir: -1 izq, 1 der, -2 arriba, 2 abajo (rota en la fila).
func _focus_dir(dir):
	if not tile_mode or tiles.empty():
		return
	var i = tiles.find(focused_tile)
	if i < 0:
		i = 0
	var n = tiles.size()
	var cols = _tile_cols()
	var c = i % cols
	var r = i / cols
	var nc = c
	var nr = r
	if dir == -1 or dir == 1:
		nc = posmod(c + dir, cols)
	else:
		nr = r + (1 if dir == 2 else -1)
		if nr < 0:
			nr = 0
	var j = nr * cols + nc
	if j >= 0 and j < n:
		_focus_tile(tiles[j])


# Intercambia el tile enfocado con el vecino en esa dirección (se deslizan al nuevo lugar).
func _swap_dir(dir):
	if not tile_mode or tiles.empty():
		return
	var i = tiles.find(focused_tile)
	if i < 0:
		return
	var n = tiles.size()
	var cols = _tile_cols()
	var c = i % cols
	var r = i / cols
	var nc = c
	var nr = r
	if dir == -1 or dir == 1:
		nc = c + dir
		if nc < 0 or nc >= cols:
			return
	else:
		nr = r + (1 if dir == 2 else -1)
		if nr < 0:
			return
	var j = nr * cols + nc
	if j < 0 or j >= n or j == i:
		return
	var tmp = tiles[i]
	tiles[i] = tiles[j]
	tiles[j] = tmp
	request_redraw()


func _toggle_expose(on):
	expose = on
	if on:
		expose_sel = max(tiles.find(focused_tile), 0)
	request_redraw()


func _expose_move(step):
	if tiles.empty():
		return
	expose_sel = posmod(expose_sel + step, tiles.size())
	request_redraw()


func _expose_commit():
	var id = -1
	if expose_sel >= 0 and expose_sel < tiles.size():
		id = tiles[expose_sel]
	expose = false
	if id >= 0:
		_focus_tile(id)
	request_redraw()


func _ensure_premult_material():
	if premult_material == null:
		premult_material = CanvasItemMaterial.new()
		premult_material.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA


# --- Dialogos: capas centradas sobre la vista de su toplevel raiz ---

func _update_dialogs(root_id):
	if dialog_view == null:
		return
	if expose:
		dialog_view.visible = false
		return
	dialog_view.rect_position = Vector2.ZERO
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
	box.rect_position = _dialog_rect(d).position  # centrado sobre el tile de su raíz
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
	var base = tile_rects.get(_root_of(d), Rect2(Vector2.ZERO, view.rect_size))
	return Rect2(base.position + base.size * 0.5 - geo.size * 0.5 - geo.position, geo.size)


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
	if is_key_pressed(KEY_TAB):
		apps_view = not apps_view
	if apps_view:
		_draw_apps()
		return
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

		set_cursor_pos(Vector2(vp.x - 110.0, frame.FRAME_H + 10.0))
		if button("Apps", Vector2(100, 32)):
			apps_view = true

		if activity_error != "":
			set_cursor_pos(Vector2(20.0, vp.y - 45.0))
			text(activity_error)
	end()


func _draw_apps():
	var vp = get_viewport_rect().size
	# Bajo el Frame, que en el Home está siempre.
	set_next_window_pos(Vector2(0.0, frame.FRAME_H), true)
	set_next_window_size(Vector2(vp.x, vp.y - frame.FRAME_H), true)
	if begin("##apps", WINDOW_NO_DECORATION | WINDOW_NO_BACKGROUND | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS | WINDOW_NO_BRING_TO_FRONT_ON_FOCUS):
		if button("Anillo"):
			apps_view = false
		same_line()
		var app = apps.draw(self)
		if activity_error != "":
			text(activity_error)
		if app != null:
			_launch_app(app)
	end()


# Una app de la grilla se abre como actividad wayland dinámica: sale en el
# anillo mientras viva su ventana (ver _on_toplevel_removed).
func _launch_app(app):
	apps.query = ""
	var i = _activity_named(app.name)
	if i < 0:
		ACTIVITIES.append({"name": app.name, "wayland": ["sh", "-c", app.cmd], "dynamic": true})
		i = ACTIVITIES.size() - 1
	_activate(i)
	apps.watch(self, app.name, last_launch_pid)
	# Si no se pudo lanzar, no queda colgada en el anillo.
	if pending_wayland == "" and not wayland_ids.has(app.name) and ACTIVITIES[i].get("dynamic", false):
		ACTIVITIES.remove(i)


func _draw_activity():
	# Sin barra fija: la actividad usa toda la pantalla y el Frame va encima.
	var vp = get_viewport_rect().size
	if current_activity == null:
		return
	if current_activity.has("script") and activity_instance != null and activity_instance.has_method("draw"):
		set_next_window_pos(Vector2.ZERO, true)
		set_next_window_size(vp, true)
		var body_flags = WINDOW_NO_DECORATION | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS
		if begin("##activity", body_flags):
			activity_instance.draw(self)
		end()


func _activate(index):
	var activity = ACTIVITIES[index]
	if activity.has("quit") and activity.quit:
		recovery.quit(self)
		return
	if activity.has("script"):
		_release_activity()
		if not script_instances.has(activity.name):
			script_instances[activity.name] = load(activity.script).new()
		activity_instance = script_instances[activity.name]
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
		_focus_tile(id)
		return

	var vp = get_viewport_rect().size
	view.rect_position = Vector2.ZERO
	view.rect_size = vp
	view.rect_clip_content = true
	compositor.default_size = view.rect_size

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


func _go_home():
	_release_activity()
	current_activity = null
	activity_instance = null
	pending_wayland = ""
	typed = false
	type_queue = []
	type_done_frame = -1
	tex_ready_frame = -1
	expose = false
	view.visible = false  # los tiles siguen vivos: se vuelven a ver al enfocar una ventana


# Las actividades tipo script pueden tener recursos propios (p.ej. el viewport
# 3D del Panel). Se les da la opcion de liberarlos al salir de la actividad; la
# instancia (su estado) sigue en script_instances y los recrea al volver.
func _release_activity():
	if activity_instance != null and activity_instance.has_method("cleanup"):
		activity_instance.cleanup()


# Cerrar desde el Frame: se descarta la instancia (el Chat pierde su historial).
func _close_script_activity(name):
	if current_activity != null and current_activity.name == name:
		_go_home()
	var inst = script_instances.get(name)
	script_instances.erase(name)
	if inst != null and inst.has_method("cleanup"):
		inst.cleanup()


func _current_wayland_id():
	if not tile_mode:
		return -1
	if focused_tile >= 0 and _id_alive(focused_tile):
		return focused_tile
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
		_add_tile(id)
		_focus_tile(id)
		return
	# Sin actividad: se creara una dinamica en cuanto llegue app_id/titulo.
	unmanaged.append(id)


# xdg-activation (p.ej. clic en una notificación): la ventana pasa al frente.
func _on_toplevel_activate(id):
	var name = _activity_for_window(_root_of(id))
	if name != "":
		_open_by_name(name)
		compositor.focus(id)
		request_redraw()


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
	view.rect_position = Vector2.ZERO
	view.rect_size = vp
	view.rect_clip_content = true
	compositor.default_size = view.rect_size

	current_activity = activity
	activity_instance = null
	activity_error = ""
	pending_wayland = ""
	_add_tile(id)
	_focus_tile(id)
	print("actividad dinamica ", name, " para toplevel ", id)


func _add_tile(id):
	if not tiles.has(id):
		tiles.append(id)
		tile_fade[id] = OS.get_ticks_msec()
	request_redraw()


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
	# Sale del tiling: cierra su nodo y, si era el enfocado y no estamos en una actividad
	# de script, pasa el foco al vecino (si estamos en Chat, no se le quita la pantalla).
	var had_tile = tiles.has(id)
	tiles.erase(id)
	if had_tile:
		request_redraw()
	var script_active = current_activity != null and not current_activity.has("wayland")
	if focused_tile == id:
		focused_tile = -1
		if not script_active:
			if tiles.empty():
				_go_home()
			else:
				_focus_tile(tiles[tiles.size() - 1])
	elif not script_active and current_activity != null and current_activity.name == removed_name:
		if tiles.empty():
			_go_home()
		else:
			_focus_tile(tiles[tiles.size() - 1])


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
	if expose:
		if event is InputEventMouseButton and event.pressed:
			var hit = _view_hit_test(event.position)
			if hit.id >= 0:
				expose_sel = tiles.find(hit.id)
				_expose_commit()
		return
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
			if hit.dialog > 0:
				compositor.focus(hit.id)
				focused_dialog = hit.dialog
			else:
				focused_dialog = 0
				_focus_tile(hit.id)


# Hit-test de arriba hacia abajo: el dialogo mas reciente que contenga el puntero; si no,
# el tile bajo el puntero (cada ventana tiene su rect). En exposé, la tarjeta.
func _view_hit_test(pos):
	if expose:
		for id in tiles:
			var card = expose_cards.get(id)
			if card != null and card.has_point(pos):
				expose_sel = tiles.find(id)
				request_redraw()
				return {"id": id, "pos": Vector2.ZERO, "dialog": 0}
		return {"id": -1, "pos": Vector2.ZERO, "dialog": 0}
	for i in range(dialogs.size() - 1, -1, -1):
		var d = dialogs[i]
		var rect = _dialog_rect(d)
		if rect.has_point(pos):
			var geo = _dialog_geo(d)
			return {"id": d, "pos": pos - rect.position + geo.position, "dialog": d}
	for id in tiles:
		var r = tile_rects.get(id)
		if r != null and r.has_point(pos):
			var geo = compositor.get_geometry(id)
			return {"id": id, "pos": pos - r.position + geo.position, "dialog": 0}
	return {"id": -1, "pos": Vector2.ZERO, "dialog": 0}


# Teclear en el Home lleva a la búsqueda de apps.
# En _input (Godot 3 lo llama también en ImGuiCanvas): con el puntero sobre el
# home ImGui marca todo como manejado y a _unhandled_input no llega nada.
func _input(event):
	last_activity = OS.get_ticks_msec()
	if event is InputEventMouse:
		_move_eis_cursor(event)
	if current_activity == null and not apps.search_active and event is InputEventKey and event.pressed \
			and event.unicode >= 32 and not (event.control or event.alt or event.meta):
		apps_view = true
		apps.type(char(event.unicode))


func _unhandled_input(event):
	if current_activity == null or not current_activity.has("wayland"):
		return
	if not (event is InputEventKey):
		return
	# Con exposé abierto el teclado es para elegir ventana, no para la app.
	if expose:
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


# --- Input remoto (libei) ---

# Permiso: sin preguntar si lo pide un servicio que el usuario prendió desde el anillo
# (Deskflow) o un hijo suyo; cualquier otro proceso, diálogo. El pid lo da el portal.
func _on_input_access(id, pid, app_id):
	var who = _proc_name(pid)
	if app_id != "":
		who = app_id + " (" + who + ")"
	if _from_service(pid):
		print("RemoteInput: control remoto permitido a ", who)
		remote_input.respond(id, true)
		return
	input_requests.append({"id": id, "who": who})
	last_activity = OS.get_ticks_msec()
	request_redraw()


func _from_service(pid):
	var guard = 0
	while pid > 1 and guard < 32:
		for name in service_pids:
			if service_pids[name] == pid and _service_running(name):
				return true
		pid = _ppid(pid)
		guard += 1
	return false


func _ppid(pid):
	var f = File.new()
	if f.open("/proc/%d/stat" % pid, File.READ) != OK:
		return 0
	var stat = f.get_line()
	f.close()
	# pid (comm) estado ppid ...: comm puede tener espacios, se corta tras el último ')'.
	return int(stat.substr(stat.find_last(")") + 2).split(" ")[1])


func _proc_name(pid):
	var f = File.new()
	if pid <= 0 or f.open("/proc/%d/comm" % pid, File.READ) != OK:
		return "proceso desconocido"
	var comm = f.get_line()
	f.close()
	return "%s, pid %d" % [comm, pid]


func _draw_input_requests():
	for i in range(input_requests.size() - 1, -1, -1):
		if not remote_input.is_pending(input_requests[i].id):
			input_requests.remove(i)
	if input_requests.empty():
		return
	var req = input_requests[0]
	var size = Vector2(460, 130)
	set_next_window_pos(get_viewport_rect().size * 0.5 - size * 0.5, true)
	set_next_window_size(size, true)
	set_next_window_bg_alpha(1.0)
	if begin("Control remoto##eis", WINDOW_NO_COLLAPSE | WINDOW_NO_RESIZE | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS):
		text_wrapped(req.who + " quiere controlar el mouse y el teclado.")
		spacing()
		if button("Permitir", Vector2(120, 32)):
			remote_input.respond(req.id, true)
		same_line()
		if button("Denegar", Vector2(120, 32)):
			remote_input.respond(req.id, false)
	end()


func _make_eis_cursor():
	var layer = CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	var arrow = PoolVector2Array([Vector2(0, 0), Vector2(0, 17), Vector2(4, 13), Vector2(7, 20),
		Vector2(10, 19), Vector2(7, 12), Vector2(12, 12)])
	var cursor = Polygon2D.new()
	cursor.polygon = arrow
	cursor.color = Color.white
	var outline = Line2D.new()
	arrow.append(arrow[0])
	outline.points = arrow
	outline.width = 1.0
	outline.default_color = Color.black
	cursor.add_child(outline)
	cursor.visible = false
	layer.add_child(cursor)
	return cursor


# Sólo con un host que no exponga wlr_virtual_pointer: en X11 se mueve el puntero real
# (warp) y en Wayland el módulo usa el cursor nativo del host (remote_pointer.c), así que
# este cursor dibujado queda como último recurso y casi nunca se ve.
func _move_eis_cursor(event):
	if event.device != RemoteInput.DEVICE_ID:
		if event is InputEventMouseMotion:
			eis_cursor.visible = false
		return
	if OS.get_environment("GDTK_SESSION") == "x11":
		Input.warp_mouse_position(event.position)
		return
	eis_cursor.position = event.position
	eis_cursor.visible = true
