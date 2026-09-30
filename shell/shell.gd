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
	# 'Salir' ya no es una actividad del anillo: es una acción de sesión del ícono central
	# del Hogar (ver _draw_home / popup ##home_session).
]

const TYPE_DELAY = 60
const SHOT_DELAY = 90
const SHOT_MAX_FRAMES = 900

onready var compositor = Host.compositor
var view = null          # Control que dibuja las ventanas (se crea en _ready)
var view_layer = null    # CanvasLayer -1 debajo de ImGui

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
# Lanzamientos wayland esperando su toplevel, en orden (la última es la más reciente).
# Puede haber varios a la vez; `expect` son tokens para casar app_id/título cuando el
# compositor ya publica ese dato, así una ventana que llega fuera de orden se asocia
# con el lanzamiento correcto.
var pending_launches = []
var requested_sizes = {}
var last_geo = {}        # id -> último tamaño observado del cliente (para reafirmar el slot)
# Los buffers wayland vienen con alfa premultiplicado.
var premult_material = null

var frame_count = 0
var screenshot_path = ""
var open_on_start = ""
var recovery = Host.sc("res://recovery.gd").new()
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

# Home: fila(s) de actividades o grilla de apps instaladas (Tab alterna).
var apps = Host.sc("res://apps.gd").new()
var apps_view = false
# Íconos XDG del anillo: rasterizar uno o dos por frame (el SVG bloquea el frame).
var home_icon_loads = 0

# Favoritos del anillo (SPEC-sugar-home-visual): ids de app fijados por la persona,
# persistidos en $XDG_CONFIG_HOME/gdtk/ring-favorites.json. El anillo = ACTIVITIES
# (sin duplicar) + estos favoritos resueltos por `apps`.
var ring_favorites = []
var ring_saved = []
# Layout animado del anillo: posición mostrada por nombre, animación en curso e
# instante de entrada (fade/escala breve). Se limpia cuando el ítem sale.
var ring_pos = {}
var ring_anim = {}
var ring_intro = {}
var ring_layout = []      # rects del último dibujo (para el drag con ratón)
var ring_press = null     # entrada pulsada aún sin arrastrar
var ring_drag = null      # entrada que se está arrastrando
var ring_from = Vector2.ZERO
var ring_grab = Vector2.ZERO
var ring_suppress = ""     # nombre cuya activación se ignora tras un drag
var ring_drop = null       # entrada destino resaltada mientras se arrastra

# Vecindario: modelo de Wi-Fi y vista nativa bajo el Frame ImGui.
var neighborhood = null
var neighborhood_ui = null
var neighborhood_view = false
var nb_version = -1

# Input remoto por libei (Deskflow, lan-mouse): EIS + portal RemoteDesktop en el módulo.
var remote_input = null
var input_requests = []  # pedidos de otros procesos esperando el diálogo
var eis_cursor = null  # sin cursor propio el host (cage/sway) no lo mueve: se dibuja uno

# Diagnóstico de entrada (ver remote.gd state.input): cuentan eventos que llegan al shell.
var input_motion_count = 0
var input_button_count = 0
var input_touch_count = 0
var input_last_button = {}
var input_last_key = {}
var last_key_target = -1  # última ventana que recibió teclas (para reenviar sueltas)

# --- Pantallas ---
# Cada ventana raíz ocupa una "pantalla" a tamaño completo (1:1: se pide el tamaño al
# cliente). Por default todas van en una sola fila horizontal y sólo la enfocada está
# a la vista: cambiar de pantalla desliza (Ctrl+Alt+←/→, ver _focus_dir). Varias
# ventanas pueden compartir una pantalla: son un "grupo" (split) que se arma arrastrando
# un ítem sobre otro en el Frame y se deshace arrastrándolo fuera.
# `minimized` son ventanas ocultas (siguen vivas; se restauran desde el Frame).
# Alt+Tab cambia de app (ventana), Ctrl+Alt+←/→ cambia de pantalla en la fila.
var tiles = []           # orden de las ventanas visibles (una por entrada, sin minimizadas)
var groups = []          # Array de Array de ids: pantallas partidas (2+ ventanas)
var minimized = {}       # id -> true
var unit_focus = {}      # id-líder de la pantalla -> último miembro enfocado
var focused_tile = -1
var tile_mode = false
var tile_nodes = {}      # id -> Control (contenedor de capas de la ventana)
var tile_rects = {}      # id -> Rect2 en coords de la vista
var tile_fit = {}        # id -> {"scale", "offset"}: transform del contenido (para input)
var tile_anim = {}       # id -> {"from": Vector2, "since": int}
var tile_fade = {}       # id -> ms en que apareció (fade-in)
var tile_intro = {}      # id -> true: falta su primera textura para animar la entrada
var expose = false
var expose_sel = 0
var expose_cards = {}    # id -> Rect2 de la tarjeta en exposé
var ghosts = []          # cierres/minimizados animados: {"node", "from", "to", "since"}
var ghost_layer = null   # capa por encima de apps y Home para el fantasma de cierre
# Rect (coords de vista) del ícono que lanzó la próxima ventana: ancla la animación de
# entrada (escala desde el ícono). Se consume en _add_tile; expira a los pocos segundos.
var pending_origin = null
var pending_origin_since = 0
# Notificación de arranque: nombre de actividad -> ms en que se pidió lanzarla.
# Mientras siga acá y la actividad no tenga ventana/estado abierto, su ítem pulsa.
var starting = {}
# SVG de Sugar ya rasterizados: "nombre|stroke|fill" -> ImageTexture.
var sugar_icons = {}
# Animación de transformación (entrar/salir de exposé): id -> {"from_pos", "from_scale", "since"}.
var view_anim = {}
# Pantalla completa (Alt+F11): la ventana enfocada ocupa todo y se esconde el Frame.
var fullscreen_id = -1
# Proporción de reparto de una franja partida: id -> peso (default 1). Asa de borde.
var split_weight = {}
var handles = []         # asas de la franja enfocada: {"x", "y", "h", "i", "left", "right"}
var hover_handle = null
var resize_handle = null
var expose_scroll = 0.0  # exposé: fila única con scroll horizontal
var expose_scroll_target = 0.0
var expose_auto = true   # true = centrar la seleccionada; false = scroll manual (rueda)
var pan = 0.0            # scroll suave entre workspaces (Super+rueda): offset continuo
var pan_active = false   # true mientras se panea; cae al más cercano al soltar Super
# Hogar como pantalla extra al final de la fila (índice units.size()): su deslizamiento
# discreto (flechas/rueda con el Frame) se anima; el continuo (Super+rueda) usa `pan`.
var home_slide_since = -1
var home_slide_from = 0.0
var home_slide_to = 0.0
var window_dragging = false  # Super+arrastre de una ventana: el view no reenvía al cliente
var instant_switch = false   # Alt+Tab: reubicar las pantallas sin animación (1 frame)
var focus_flash = 0      # ms del último cambio de foco (borde que destella)
var tiles_ui = null
var expose_bg = null     # fondo oscuro de exposé, detrás de los tiles
const TILE_GAP = 3.0
const TILE_ANIM_MS = 320
const TILE_FADE_MS = 440
const GHOST_MS = 380
const INTRO_MS = 480
const EXPOSE_MS = 430
const FOCUS_FLASH_MS = 260
const HANDLE_HIT = 7.0
const EXPOSE_PAD = 28.0
const EXPOSE_GAP = 18.0
const MOD_KEYS = [KEY_CONTROL, KEY_SHIFT, KEY_ALT, KEY_META, KEY_SUPER_L, KEY_SUPER_R]

# Hogar: fila(s) de favoritos centradas (SPEC-sugar-home-visual). Pareja XO para la
# insignia de identidad del Frame; íconos de actividad con fill claro + stroke
# oscuro-medio, y estados por contorno/atenuación además del color (SPEC-resource-ring).
const XO_FILL = Color(0.78, 0.30, 0.52, 1.0)
const XO_STROKE = Color(0.34, 0.15, 0.29, 1.0)
# Íconos Sugar de actividad: la placa del círculo es oscura, así que el relleno va
# claro para despegarla y el trazo oscuro-medio para definir la silueta.
const SUGAR_FILL = Color(0.96, 0.95, 0.90, 1.0)
const SUGAR_STROKE = Color(0.32, 0.30, 0.38, 1.0)
# Favoritos/actividades: círculos grandes en fila horizontal centrada. Todos los
# tamaños salen de la unidad de rejilla (ver grid_unit), no de constantes en px.
const HOME_BG_TOP = Color(0.12, 0.13, 0.17, 1.0)
const HOME_BG_BOTTOM = Color(0.05, 0.06, 0.09, 1.0)
# Bloque "Apps" del Hogar: misma familia biselada (gris azulado) que los bloques del Frame.
const HOME_BLOCK_FACE = Color(0.27, 0.31, 0.41, 1.0)
const HOME_BLOCK_LIGHT = Color(0.53, 0.59, 0.73, 1.0)
const HOME_BLOCK_DARK = Color(0.07, 0.08, 0.13, 1.0)
const HOME_BLOCK_TEXT = Color(0.92, 0.93, 0.97, 1.0)
const HOME_BEVEL = 2.0
const RING_PLATE = Color(0.10, 0.11, 0.14, 0.88)
const RING_CLOSED = Color(0.62, 0.64, 0.70, 0.55)
const RING_OPEN = Color(0.98, 0.72, 0.30, 0.95)
const RING_FOCUS = Color(0.55, 0.80, 1.0, 1.0)
const RING_MIN = Color(0.56, 0.59, 0.68, 0.90)  # minimizada: contorno punteado atenuado
const RING_LABEL = Color(0.90, 0.91, 0.94, 1.0)
const RING_LABEL_DIM = Color(0.72, 0.74, 0.79, 1.0)
# Favorito cerrado (app fijada al anillo sin ventana viva): contorno más definido
# que una actividad cerrada, sin fingir "abierto" (SPEC-sugar-home-visual).
const RING_FAVORITE = Color(0.66, 0.68, 0.76, 0.95)
# Animación del layout del anillo y de la barra del Frame al reacomodar.
const LAYOUT_MS = 220
const RING_INTRO_MS = 260
const DRAG_PX = 8.0

# Íconos Sugar: los SVG traen un DOCTYPE con entidades &stroke_color;/&fill_color;.
# Se cargan como texto, se sustituyen por los colores pedidos y se rasterizan a una
# ImageTexture cacheada (el motor no expone load_svg_from_string en este árbol).
const SUGAR_DIR = "res://icons/sugar/"
const SUGAR_RASTER = 192  # px del SVG al rasterizar (se dibuja a ~120)
# Actividades sin ícono XDG con un ícono Sugar razonable (el resto usa inicial).
const SUGAR_ACTIVITY_ICONS = {
	"Panel": "preferences-system",
	"Gears": "emblem-busy",
	"Chat": "document-send",
	"Deskflow": "network-wired",
}
# Notificación de arranque estilo Sugar: pulso ~1.2 s hasta que aparece la ventana.
const STARTING_MAX_MS = 15000
const STARTING_PERIOD_S = 1.2


# Unidad de rejilla única del Hogar y del Frame: la pantalla se reparte en celdas
# cuadradas de U px (16 columnas x 10 filas en 1280x800, que da 80). El mínimo de 80
# garantiza que el ícono de 64 entre holgado en cualquier resolución razonable.
# Todo bloque/salto del Hogar y del Frame sale de acá; no se repiten números.
func grid_unit(vp):
	return max(80.0, floor(min(vp.x / 16.0, vp.y / 10.0)))


# Alto de las barras del Frame (superior e inferior). Una unidad completa; si la
# pantalla es tan baja que dos barras de U tapan el área de apps, se usa media
# unidad (sin bajar de 64, el ícono más chico antes del caso extremo).
func frame_bar_h(vp):
	var u = grid_unit(vp)
	if vp.y >= 3.0 * u:
		return u
	return max(64.0, floor(u * 0.5))


# Ícono del botón Inicio del Frame (Sugar: símbolo de hogar).
func home_icon_tex():
	return _load_sugar_svg("go-home", SUGAR_STROKE, SUGAR_FILL)


# Ícono del bloque Vecindario del Frame (Sugar: red inalámbrica).
func neighborhood_icon_tex():
	return _load_sugar_svg("network-wireless", SUGAR_STROKE, SUGAR_FILL)


func _ready():
	connect("imgui_frame", self, "_imgui_frame")
	compositor.connect("toplevel_added", self, "_on_toplevel_added")
	compositor.connect("toplevel_removed", self, "_on_toplevel_removed")
	compositor.connect("toplevel_activate", self, "_on_toplevel_activate")
	# Cambios de ventanas: rearmar la UI (el Frame las lista, recovery espera la suya).
	compositor.connect("toplevel_added", self, "_redraw_on_signal")
	compositor.connect("toplevel_removed", self, "_redraw_on_signal")
	view_layer = CanvasLayer.new()
	view_layer.name = "ViewLayer"
	view_layer.layer = -1
	add_child(view_layer)
	view = Control.new()
	view.name = "View"
	view.visible = false
	view.mouse_filter = Control.MOUSE_FILTER_STOP
	view.rect_clip_content = false
	view_layer.add_child(view)
	view.connect("gui_input", self, "_on_view_input")
	# Hijo después de Remote: su _input corre antes que el de ImGui (F6, Alt+Tab).
	frame = Host.sc("res://frame.gd").new()
	frame.name = "Frame"
	add_child(frame)
	_load_ring()
	# Vecindario: parser/estado del Wi-Fi. El hilo arranca al abrir la vista; este
	# nodo sigue dueño del resultado en memoria hasta que el shell se recarga.
	neighborhood = Host.sc("res://neighborhood.gd").new()
	neighborhood_ui = Control.new()
	neighborhood_ui.name = "NeighborhoodUI"
	neighborhood_ui.set_script(Host.sc("res://neighborhood_ui.gd"))
	neighborhood_ui.shell = self
	neighborhood_ui.model = neighborhood
	neighborhood_ui.visible = false
	view_layer.add_child(neighborhood_ui)
	# Notificaciones y demás layer-shell, encima de todo (después del Frame: su _input va antes).
	add_child(Host.sc("res://layers.gd").new())

	# Capa de dialogos encima de la vista de la actividad.
	dialog_view = Control.new()
	dialog_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dialog_view.rect_clip_content = true
	dialog_view.visible = false
	view_layer.add_child(dialog_view)

	# Bordes de foco, títulos y tarjetas de exposé: se dibuja a mano (Control._draw) y no
	# captura input, así los clics siguen llegando a los tiles (una ventana ImGui sí lo haría).
	tiles_ui = Control.new()
	tiles_ui.name = "TilesUI"
	tiles_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tiles_ui.rect_clip_content = false
	tiles_ui.set_script(Host.sc("res://tiles_ui.gd"))
	tiles_ui.shell = self
	view_layer.add_child(tiles_ui)

	# Fondo de exposé: detrás de los tiles (View) para no tapar las miniaturas.
	expose_bg = ColorRect.new()
	expose_bg.color = Color(0.05, 0.06, 0.08, 0.92)
	expose_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	expose_bg.visible = false
	view_layer.add_child(expose_bg)
	view_layer.move_child(expose_bg, 0)

	for arg in OS.get_cmdline_args():
		if arg.begins_with("--screenshot="):
			screenshot_path = arg.substr("--screenshot=".length())
		elif arg.begins_with("--open="):
			open_on_start = arg.substr("--open=".length())
		elif arg.begins_with("--type="):
			type_text = arg.substr("--type=".length())

	remote_input = Host.remote_input
	remote_input.connect("access_requested", self, "_on_input_access")
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

	if Host.live_reload:
		_adopt_windows()
	else:
		recovery.load(self)
	if open_on_start != "":
		_open_by_name(open_on_start)


# Guarda el layout (orden/grupos/pesos/foco/fullscreen/minimizadas) para restaurarlo
# tras una recarga en caliente (ver main.reload_shell).
func _save_layout():
	var gs = []
	for g in groups:
		gs.append(g.duplicate())
	Host.layout = {"tiles": tiles.duplicate(), "groups": gs, "weights": split_weight.duplicate(),
		"minimized": minimized.keys(), "focused": focused_tile, "fullscreen": fullscreen_id}


# Al recargar el shell, las apps siguen vivas en el compositor del Host: se rearma el
# estado (actividades y tiles) desde los toplevels existentes.
func _adopt_windows():
	var roots = []
	for id in compositor.get_ids():
		if compositor.get_parent_id(id) > 0:
			if not dialogs.has(id):
				dialogs.append(id)
		else:
			roots.append(id)
	for id in roots:
		var name = _unique_activity_name(_window_activity_name(id))
		wayland_ids[name] = id
		ACTIVITIES.append({"name": name, "wayland": [], "dynamic": true})
		_add_tile(id)
	var lay = Host.layout
	Host.layout = {}
	if typeof(lay) == TYPE_DICTIONARY and lay.get("tiles", []).size() > 0 and not roots.empty():
		var known = {}
		for id in roots:
			known[id] = true
		var order = []
		for id in lay["tiles"]:
			if known.has(id):
				order.append(id)
				known.erase(id)
		for id in known.keys():
			order.append(id)
		tiles = order
		for id in lay.get("minimized", []):
			if tiles.has(id):
				minimized[id] = true
				tiles.erase(id)
		groups = []
		for g in lay.get("groups", []):
			var gg = []
			for id in g:
				if tiles.has(id):
					gg.append(id)
			if gg.size() >= 2:
				groups.append(gg)
		split_weight = {}
		for k in lay.get("weights", {}):
			split_weight[int(k)] = lay["weights"][k]
		var f = int(lay.get("focused", -1))
		_focus_tile(f if tiles.has(f) else (tiles[tiles.size() - 1] if not tiles.empty() else -1))
		fullscreen_id = int(lay.get("fullscreen", -1))
		if not tiles.has(fullscreen_id):
			fullscreen_id = -1
		# Deja `tiles` en orden de franja (miembros de un grupo contiguos) para que el
		# exposé muestre el mismo orden que los workspaces.
		_rebuild_tiles(_units())
		request_redraw()
		return
	if not roots.empty():
		_focus_tile(roots[roots.size() - 1])
	request_redraw()


# Diagnóstico: geometría y capas por ventana (para el mapeo de puntero).
func geom_state():
	var out = {}
	for id in tiles:
		var geo = compositor.get_geometry(id)
		var layers = compositor.get_layers(id)
		var mn = Vector2(1e9, 1e9)
		var mx = Vector2(-1e9, -1e9)
		var l0 = [0, 0, 0, 0]
		for i in range(layers.size()):
			var rt = layers[i].rect
			mn = Vector2(min(mn.x, rt.position.x), min(mn.y, rt.position.y))
			mx = Vector2(max(mx.x, rt.position.x + rt.size.x), max(mx.y, rt.position.y + rt.size.y))
			if i == 0:
				l0 = [rt.position.x, rt.position.y, rt.size.x, rt.size.y]
		out[str(id)] = {"geo": [geo.position.x, geo.position.y, geo.size.x, geo.size.y],
			"l0": l0, "union": [mn.x, mn.y, mx.x - mn.x, mx.y - mn.y], "n": layers.size()}
	return out


# Recupera modificadores pegados: reenvía sueltas de Ctrl/Shift/Alt/Super a la app y
# limpia el estado del shell (paneo/Super).
func release_modifiers():
	var id = _current_wayland_id()
	if id < 0:
		id = last_key_target
	if id >= 0:
		for sc in MOD_KEYS:
			var ev = InputEventKey.new()
			ev.scancode = sc
			ev.physical_scancode = sc
			ev.pressed = false
			compositor.key(ev)
	pan = 0.0
	pan_active = false
	if frame != null:
		frame.super_press = null
	request_redraw()


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
	# Vecindario: el hilo deja el último resultado; si cambió y la vista está a la
	# vista, se pide un frame (sin sondeo periódico en reposo).
	if neighborhood != null and neighborhood.running():
		neighborhood.poll()
		if neighborhood.version != nb_version:
			nb_version = neighborhood.version
			if neighborhood_view:
				request_redraw()
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
	_tick_home_slide()
	# Fundido al cambiar de vista (ver frame.transition); 0 = ImGuiStyleVar_Alpha.
	var fade = frame.transition()
	if fade < 1.0:
		push_style_var_float(0, fade)
	if current_activity == null:
		if neighborhood_view:
			neighborhood_ui.refresh()
		else:
			_draw_home(_home_x(_units()))
	else:
		_draw_activity()
		# Paneo/animación hacia el Hogar: se dibuja deslizándose junto a las ventanas.
		if _home_anim_active() or pan_active:
			var hx = _home_x(_units())
			var vp = get_viewport_rect().size
			if hx > -vp.x and hx < vp.x:
				_draw_home(hx)
	if fade < 1.0:
		pop_style_var()

	# Tiling: con alguna ventana abierta y una actividad wayland activa se muestran todos
	# los tiles a la vez; en Home o en una actividad de script, la vista se oculta. La
	# vista también se muestra para el paneo/animación que trae o lleva al Hogar.
	tile_mode = current_activity != null and current_activity.has("wayland") and not tiles.empty()
	var row = tile_mode or (not tiles.empty() and (_home_anim_active() or pan_active))
	view.visible = row
	neighborhood_ui.visible = neighborhood_view and current_activity == null
	if row:
		_update_tiles()
	instant_switch = false  # ya se reubicaron sin animación en este frame
	var id = _current_wayland_id()
	_update_dialogs(id)
	if tiles_ui != null:
		tiles_ui.rect_size = get_viewport_rect().size
		tiles_ui.refresh()
	if expose_bg != null:
		expose_bg.rect_size = get_viewport_rect().size
		expose_bg.visible = expose
	frame.draw(self)
	_update_ghosts(OS.get_ticks_msec())

	_draw_input_requests()
	# HUD de debug global (autoload DebugHud): Super+F6 lo abre en cualquier actividad (frame.gd).
	DebugHud.draw(self)

	frame_count += 1
	_run_test_logic()


# --- Pantallas: una fila horizontal; cada pantalla puede tener varias apps ---

# El grupo (franja con varias apps) que contiene la ventana, o null si va suelta.
func _group_of(id):
	for g in groups:
		if g.has(id):
			return g
	return null


# Miembros de la pantalla de una ventana: su grupo, o ella sola.
func _unit_members(id):
	var g = _group_of(id)
	return g if g != null else [id]


# Unidades en orden de `tiles`: cada grupo una vez (en la posición de su primer miembro).
func _units():
	var out = []
	var seen = {}
	for id in tiles:
		if seen.has(id):
			continue
		var g = _group_of(id)
		if g != null:
			out.append(g)
			for m in g:
				seen[m] = true
		else:
			out.append([id])
			seen[id] = true
	return out


func _focused_unit_index(units):
	for u in range(units.size()):
		if units[u].has(focused_tile):
			return u
	return 0


# La fila incluye una ranura extra: el Hogar, siempre al final (índice units.size()).
# ¿La pantalla actual es el Hogar? (el Hogar no es una actividad ni un toplevel).
func _at_home():
	return current_activity == null


func _home_anim_active():
	return home_slide_since >= 0


# Índice continuo de la fila (0..units.size(), donde units.size() es el Hogar): la
# pantalla ancla (la enfocada, o el Hogar) más el offset de paneo o de la animación.
func _row_s(units):
	var n = units.size()
	if home_slide_since >= 0:
		var k = clamp(float(OS.get_ticks_msec() - home_slide_since) / TILE_ANIM_MS, 0.0, 1.0)
		return lerp(home_slide_from, home_slide_to, _ease(k))
	var vp = get_viewport_rect().size
	var a = float(n) if _at_home() else float(_focused_unit_index(units))
	return a + pan / max(vp.x, 1.0)


# Ranura de la última pantalla que tuvo el foco (para volver desde el Hogar).
func _last_focus_unit(units):
	var ui = _focused_unit_index_of(units, focused_tile)
	if ui < 0:
		ui = units.size() - 1
	return ui


# x del Hogar dentro de la fila: 0 = centrado en pantalla, ±ancho = fuera de vista.
func _home_x(units):
	var vp = get_viewport_rect().size
	return (float(units.size()) - _row_s(units)) * vp.x


# Toda la fila a tamaño completo: la pantalla enfocada (o el Hogar) en (0,0) y el resto
# a ±ancho, para que cambiar de pantalla deslice de costado. La fila incluye el Hogar
# como ranura extra al final (índice units.size()).
func _compute_slide_layout():
	tile_rects.clear()
	var units = _units()
	var vp = get_viewport_rect().size
	# Pantalla completa: la ventana ocupa todo; el resto queda fuera de pantalla.
	if fullscreen_id >= 0 and tiles.has(fullscreen_id):
		for id in tiles:
			tile_rects[id] = Rect2(0.0, 0.0, vp.x, vp.y) if id == fullscreen_id else Rect2(vp.x * 2.0, 0.0, vp.x, vp.y)
		return
	var s = _row_s(units)
	for u in range(units.size()):
		var area = Rect2((float(u) - s) * vp.x, 0.0, vp.x, vp.y)
		var members = units[u]
		if members.size() == 1:
			tile_rects[members[0]] = area
		else:
			_split_rects(members, area)


# Peso de reparto de una ventana dentro de su franja (default 1: partes iguales).
func _weight(id):
	return float(split_weight.get(id, 1.0))


# Las apps de una franja van en UNA fila, sin tope; el ancho se reparte por pesos
# (el asa de borde ajusta los pesos de las dos ventanas vecinas).
func _split_rects(members, area):
	var n = members.size()
	if n == 0:
		return
	var gap = TILE_GAP
	var total = 0.0
	for m in members:
		total += max(_weight(m), 0.001)
	var avail = area.size.x - gap * float(n + 1)
	var x = area.position.x + gap
	for i in range(n):
		var w = avail * max(_weight(members[i]), 0.001) / total
		tile_rects[members[i]] = Rect2(x, area.position.y, w, area.size.y)
		x += w + gap


# Asas de la franja enfocada (sólo si tiene varias apps): coordenada x del borde
# entre cada par, para dibujar/arrastrar la redimensión.
func _compute_handles():
	handles = []
	if expose or fullscreen_id >= 0 or _at_home() or _home_anim_active():
		hover_handle = null
		resize_handle = null
		return
	var units = _units()
	if units.empty():
		return
	var u = units[_focused_unit_index(units)]
	if u.size() < 2:
		return
	var vp = get_viewport_rect().size
	for i in range(u.size() - 1):
		var r = tile_rects.get(u[i])
		if r == null:
			continue
		var x = r.position.x + r.size.x + TILE_GAP * 0.5
		if x < -8.0 or x > vp.x + 8.0:
			continue
		handles.append({"x": x, "y": r.position.y, "h": r.size.y, "i": i, "left": u[i], "right": u[i + 1]})
	# Reapunta las asas activas a las entradas nuevas: si no, la dibujada queda con la
	# posición vieja y parece que no sigue al mouse (los rects sí se recalculan).
	hover_handle = _find_handle(hover_handle)
	resize_handle = _find_handle(resize_handle)


func _find_handle(h):
	if h == null:
		return null
	for nh in handles:
		if nh.left == h.left and nh.right == h.right:
			return nh
	return null


func _handle_at(pos):
	for h in handles:
		if abs(pos.x - h.x) <= HANDLE_HIT and pos.y >= h.y and pos.y <= h.y + h.h:
			return h
	return null


# Transform de contenido por ventana, para el control remoto (claves string = JSON).
func fits_state():
	var out = {}
	for id in tile_fit.keys():
		var fit = tile_fit[id]
		out[str(id)] = {"scale": fit.scale, "offset": [fit.offset.x, fit.offset.y]}
	return out


# Mueve el borde hasta mouse_x repartiendo el ancho combinado de las dos ventanas.
func _resize_to(h, mouse_x):
	var rl = tile_rects.get(h.left)
	var rr = tile_rects.get(h.right)
	if rl == null or rr == null:
		return
	var left = rl.position.x
	var right = rr.position.x + rr.size.x
	var frac = clamp((mouse_x - left) / max(right - left, 1.0), 0.12, 0.88)
	var wsum = _weight(h.left) + _weight(h.right)
	split_weight[h.left] = wsum * frac
	split_weight[h.right] = wsum * (1.0 - frac)


# Exposé: TODAS las tarjetas en una sola fila horizontal, en el mismo orden que la franja
# de workspaces (`tiles`); si no entran, scroll horizontal (rueda) o centra la elegida.
func _compute_expose_layout():
	expose_cards.clear()
	var n = tiles.size()
	if n == 0:
		return
	var vp = get_viewport_rect().size
	expose_sel = int(clamp(expose_sel, 0, max(n - 1, 0)))
	var ch = vp.y - EXPOSE_PAD * 2.0
	var cw = clamp(vp.x * 0.6, 240.0, 720.0)
	var total = EXPOSE_PAD * 2.0 + float(n) * cw + float(max(n - 1, 0)) * EXPOSE_GAP
	var max_scroll = max(total - vp.x, 0.0)
	if expose_auto:
		var sel_left = EXPOSE_PAD + float(expose_sel) * (cw + EXPOSE_GAP)
		expose_scroll_target = clamp(sel_left + cw * 0.5 - vp.x * 0.5, 0.0, max_scroll)
	else:
		expose_scroll_target = clamp(expose_scroll_target, 0.0, max_scroll)
	expose_scroll = lerp(expose_scroll, expose_scroll_target, 0.25)
	if abs(expose_scroll - expose_scroll_target) > 0.5:
		request_redraw()
	for i in range(n):
		var x = EXPOSE_PAD + float(i) * (cw + EXPOSE_GAP) - expose_scroll
		expose_cards[tiles[i]] = Rect2(x, EXPOSE_PAD, cw, ch)


# Rueda en exposé: desplaza la tira sin cambiar la selección.
func _expose_scroll_by(px):
	expose_auto = false
	expose_scroll_target += px
	request_redraw()


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
# `scale`/`offset` mapean las coords del cliente al slot: si el cliente es más chico o
# más grande que su slot, se escala y centra para que llene (ver _content_fit).
func _fill_nodes(box, layers, scale, offset):
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
		node.rect_position = layer.rect.position * scale + offset
		node.rect_size = size * scale
		node.visible = layer.texture != null
	for i in range(layers.size(), box.get_child_count()):
		box.get_child(i).visible = false


# Offset (local al nodo del slot) para mostrar el contenido del cliente (tamaño `csize`,
# origen `cpos`) dentro del slot `ssize`. No escala nunca: 1:1 y centrado. Si el cliente
# es más chico que el slot, queda centrado; si es más grande, se lo recorta el slot
# (rect_clip_content). El redimensionado real lo hace compositor.set_size.
func _content_fit(csize, ssize, cpos):
	if csize.x <= 0.0 or csize.y <= 0.0:
		return {"scale": 1.0, "offset": -cpos}
	return {"scale": 1.0, "offset": -cpos + (ssize - csize) * 0.5}


func _update_tiles():
	view.rect_size = get_viewport_rect().size
	compositor.default_size = view.rect_size
	if expose:
		_compute_expose_layout()
	else:
		_compute_slide_layout()
	_compute_handles()
	for id in tile_nodes.keys():
		if not tiles.has(id):
			var node = tile_nodes[id]
			tile_nodes.erase(id)
			tile_rects.erase(id)
			expose_cards.erase(id)
			tile_anim.erase(id)
			tile_fade.erase(id)
			tile_intro.erase(id)
			view_anim.erase(id)
			tile_fit.erase(id)
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
	var rect = tile_rects.get(id, Rect2(Vector2.ZERO, view.rect_size))
	# El cliente puede no ocupar el slot (elige tamaño propio, o se achica al cambiar
	# de fuente): se centra 1:1 y, si es más grande que el slot, se reduce para que entre.
	var fit = _content_fit(geo.size, rect.size, geo.position)
	_fill_nodes(node, layers, fit.scale, fit.offset)
	tile_fit[id] = fit

	if expose:
		# Miniatura: se escala el nodo entero (la app conserva su tamaño de tile) y se
		# centra, animando desde su transform de pantalla (ver _toggle_expose).
		var card = expose_cards.get(id, Rect2(Vector2.ZERO, view.rect_size))
		var size = node.rect_size
		if size.x <= 0.0 or size.y <= 0.0:
			size = card.size
		var s = min(min(card.size.x / max(size.x, 1.0), card.size.y / max(size.y, 1.0)), 1.0)
		var tpos = card.position + (card.size - size * s) * 0.5
		var a = view_anim.get(id)
		if a != null:
			var e = _ease(float(now - a.since) / EXPOSE_MS)
			node.rect_position = a.from_pos.linear_interpolate(tpos, e)
			var sc = lerp(float(a.from_scale), s, e)
			node.rect_scale = Vector2(sc, sc)
			if float(now - a.since) >= EXPOSE_MS:
				view_anim.erase(id)
			else:
				request_redraw()
		else:
			node.rect_scale = Vector2(s, s)
			node.rect_position = tpos
		node.modulate = Color(1, 1, 1, 1)
		node.visible = true
		return

	# Vuelta de exposé: se interpola desde la tarjeta hasta su rect de pantalla.
	if view_anim.has(id):
		var a = view_anim[id]
		var e = _ease(float(now - a.since) / EXPOSE_MS)
		node.rect_position = a.from_pos.linear_interpolate(rect.position, e)
		var sc = lerp(float(a.from_scale), 1.0, e)
		node.rect_scale = Vector2(sc, sc)
		node.rect_size = rect.size
		node.visible = true
		node.modulate = Color(1, 1, 1, 1)
		if geo.size != Vector2.ZERO and requested_sizes.get(id) != rect.size:
			requested_sizes[id] = rect.size
			compositor.set_size(id, rect.size)
		if float(now - a.since) >= EXPOSE_MS:
			view_anim.erase(id)
		else:
			request_redraw()
		return

	# Entrada: escala y se traslada desde el ícono que la lanzó (o desde el borde
	# derecho, mismo tamaño). El placeholder con spinner lo dibuja tiles_ui hasta que
	# llega la primera textura. El tamaño del cliente queda en el destino (1:1).
	if tile_intro.has(id):
		var info = tile_intro[id]
		if layers.size() > 0 and layers[0].texture != null:
			info["ready"] = true
		var k = clamp(float(now - info.since) / INTRO_MS, 0.0, 1.0)
		var e = _ease(k)
		var from = info.get("from")
		if from == null:
			from = Rect2(Vector2(view.rect_size.x, rect.position.y), rect.size)
		var s = lerp(_intro_scale(from, rect), 1.0, e)
		var center = (from.position + from.size * 0.5).linear_interpolate(rect.position + rect.size * 0.5, e)
		var pos = center - rect.size * s * 0.5
		node.rect_scale = Vector2(s, s)
		node.rect_position = pos
		node.rect_size = rect.size
		node.visible = true
		node.modulate = Color(1, 1, 1, min(e, 1.0))
		info["rect"] = Rect2(pos, rect.size * s)
		if geo.size != Vector2.ZERO and requested_sizes.get(id) != rect.size:
			requested_sizes[id] = rect.size
			compositor.set_size(id, rect.size)
		if k >= 1.0:
			tile_intro.erase(id)
			node.rect_scale = Vector2.ONE
			node.rect_position = rect.position
		else:
			request_redraw()
		return

	# Desliza desde donde estaba a su celda nueva (reacomodar, cambiar de pantalla).
	# Durante el paneo (Super+rueda) se posiciona directo, sin animación, para que el
	# movimiento continuo no pelee con el easing.
	var pos = rect.position
	if pan_active or instant_switch or home_slide_since >= 0:
		tile_anim.erase(id)
	elif tile_anim.has(id):
		var a = tile_anim[id]
		var k = clamp(float(now - a.since) / TILE_ANIM_MS, 0.0, 1.0)
		pos = a.from.linear_interpolate(rect.position, _ease(k))
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
	# Sólo se dibuja la pantalla que asoma: las demás quedan fuera (±ancho/±alto).
	var vp = view.rect_size
	node.visible = pos.x + rect.size.x > 0.0 and pos.x < vp.x and pos.y + rect.size.y > 0.0 and pos.y < vp.y
	node.modulate = Color(1, 1, 1, 1)

	# Ajuste 1:1: se le pide al cliente el tamaño del slot (texto nítido). Se reafirma
	# cuando el cliente se achica solo (p. ej. al cambiar la fuente) y no molesta si el
	# cliente no acepta (sólo se reintenta cuando su tamaño cambia).
	if rect.size.x > 0.0 and rect.size.y > 0.0:
		var drifted = geo.size != Vector2.ZERO and geo.size != rect.size and last_geo.get(id) != geo.size
		if requested_sizes.get(id) != rect.size or drifted:
			requested_sizes[id] = rect.size
			compositor.set_size(id, rect.size)
		last_geo[id] = geo.size
	if tex_ready_frame < 0 and id == focused_tile and layers.size() > 0 and layers[0].texture != null:
		tex_ready_frame = frame_count


# Easing con rebote leve (ease-out-back): arranca rápido, se pasa un poco del destino
# y vuelve. k normalizado 0..1 (puede devolver >1 por el overshoot).
func _ease(k):
	k = clamp(k, 0.0, 1.0)
	var c1 = 1.20158
	var c3 = c1 + 1.0
	return 1.0 + c3 * pow(k - 1.0, 3.0) + c1 * pow(k - 1.0, 2.0)


# Escala inicial para la entrada: la ventana nace del tamaño del ícono (nunca > 1).
func _intro_scale(from, target):
	if target.size.x <= 0.0 or target.size.y <= 0.0:
		return 1.0
	return min(min(from.size.x / target.size.x, from.size.y / target.size.y), 1.0)


# Rect del ítem de la ventana en el Frame (si está dibujado); si no, un punto arriba.
# Es el destino de las animaciones de minimizar/cerrar (la ventana vuelve a su ítem).
func _panel_rect_for(id):
	if frame != null:
		var r = frame.item_rect(id)
		if r != null:
			return r
	return Rect2(Vector2(view.rect_size.x * 0.5 - 60.0, 2.0), Vector2(120.0, 24.0))


# Congela el cuadro on-screen de la ventana y lo anima hacia `to_rect` (o arriba si es
# null), encogiéndose. Se usa un snapshot del viewport para no depender de que el cliente
# siga teniendo vivo su buffer (dmabuf). Sirve para cerrar y para minimizar.
func _spawn_ghost(id, to_rect):
	if not view.visible:
		return
	var rect = tile_rects.get(id)
	if rect == null:
		return
	var vp = get_viewport_rect().size
	var vis = Rect2(Vector2.ZERO, vp).clip(rect)
	if vis.size.x < 8.0 or vis.size.y < 8.0:
		return
	var img = get_viewport().get_texture().get_data()
	if img == null:
		return
	img.flip_y()
	img = img.get_rect(Rect2(vis.position, vis.size))
	if img == null or img.get_width() <= 0 or img.get_height() <= 0:
		return
	if to_rect == null:
		to_rect = Rect2(Vector2(vis.position.x + vis.size.x * 0.5 - 30.0, 2.0), Vector2(60.0, 20.0))
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	var node = TextureRect.new()
	node.texture = tex
	node.expand = true
	node.stretch_mode = TextureRect.STRETCH_SCALE
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.rect_size = vis.size
	node.rect_position = vis.position
	if ghost_layer == null:
		ghost_layer = CanvasLayer.new()
		ghost_layer.layer = 1
		add_child(ghost_layer)
	ghost_layer.add_child(node)
	ghosts.append({"node": node, "from": vis, "to": to_rect, "since": OS.get_ticks_msec()})
	request_redraw()


# Anima los fantasmas: interpola posición y tamaño desde la ventana hasta el ícono, con
# alfa 1 -> 0.
func _update_ghosts(now):
	for i in range(ghosts.size() - 1, -1, -1):
		var g = ghosts[i]
		var k = clamp(float(now - g.since) / GHOST_MS, 0.0, 1.0)
		var e = _ease(k)
		var from = g.from
		var to = g.to
		var pos = from.position.linear_interpolate(to.position, e)
		var size = from.size.linear_interpolate(to.size, e)
		g.node.rect_position = pos
		g.node.rect_size = size
		g.node.modulate = Color(1, 1, 1, 1.0 - k)
		if k >= 1.0:
			g.node.queue_free()
			ghosts.remove(i)
		else:
			request_redraw()


func _focus_tile(id):
	if id < 0 or not _id_alive(id):
		return
	# Enfocar a mano cancela cualquier deslizamiento/hogar en curso y cierra la
	# grilla de Apps: el flag no debe sobrevivir al volver de la grilla a una app.
	pan = 0.0
	pan_active = false
	home_slide_since = -1
	apps_view = false
	# Enfocar una minimizada la restaura (así el teclado puede traerlas de vuelta).
	if minimized.has(id):
		minimized.erase(id)
	if not tiles.has(id):
		tiles.append(id)
		tile_intro[id] = _new_intro()
	# Enfocar otra ventana sale de pantalla completa.
	if fullscreen_id >= 0 and fullscreen_id != id:
		fullscreen_id = -1
	focused_tile = id
	focus_flash = OS.get_ticks_msec()
	# Memoriza el miembro enfocado de la pantalla (para volver a él desde otra).
	for u in _units():
		if u.has(id):
			unit_focus[u[0]] = id
			break
	var name = _activity_for_window(id)
	var i = _activity_named(name)
	if i >= 0:
		current_activity = ACTIVITIES[i]
	compositor.focus(id)
	request_redraw()


# Navegación de pantallas (una sola fila por default, con el Hogar al final).
# dir: -1 izq, 1 der. ←/→ cambian de pantalla (franja); desde la última, → llega al
# Hogar y desde el Hogar, ← vuelve a la última pantalla que tuvo el foco.
func _focus_dir(dir):
	if dir != -1 and dir != 1:
		return
	if _home_anim_active():
		return
	pan = 0.0
	pan_active = false
	var units = _units()
	var n = units.size()
	if _at_home():
		if dir < 0 and n > 0:
			_start_home_leave(units, _last_focus_unit(units))
		request_redraw()
		return
	if not tile_mode or tiles.empty():
		return
	if fullscreen_id >= 0:
		return
	var ui = _focused_unit_index(units)
	if dir > 0 and ui >= n - 1:
		_start_home_enter(units)
	else:
		_focus_unit(units, ui + dir)


# Entrada al Hogar (desde la última pantalla): anima la fila hasta la ranura n y al
# terminar confirma el cambio con _go_home (ver _tick_home_slide).
func _start_home_enter(units):
	home_slide_from = _row_s(units)
	home_slide_to = float(units.size())
	home_slide_since = OS.get_ticks_msec()
	request_redraw()


# Salida del Hogar (hacia la pantalla u): anima la fila desde la ranura n.
func _start_home_leave(units, u):
	home_slide_from = float(units.size())
	home_slide_to = float(u)
	home_slide_since = OS.get_ticks_msec()
	request_redraw()


# Cierra la animación del Hogar: entra (confirma Home) o sale (enfoca la pantalla).
func _tick_home_slide():
	if home_slide_since < 0:
		return
	var k = clamp(float(OS.get_ticks_msec() - home_slide_since) / TILE_ANIM_MS, 0.0, 1.0)
	if k < 1.0:
		request_redraw()
		return
	var to = home_slide_to
	home_slide_since = -1
	var units = _units()
	var n = units.size()
	if int(round(to)) >= n:
		_go_home()
	elif n > 0:
		_focus_unit(units, int(clamp(round(to), 0.0, float(n - 1))))
	request_redraw()


# Super+rueda: desplaza la franja de forma continua (signo +1 = siguiente). Llega hasta
# el Hogar (y desde el Hogar vuelve a las ventanas). No cambia el foco hasta soltar
# Super (_snap_pan).
func _pan_by(amount):
	if _home_anim_active():
		return
	var units = _units()
	var n = units.size()
	if n == 0:
		return
	if not (tile_mode or _at_home()):
		return
	if fullscreen_id >= 0:
		return
	var vp = get_viewport_rect().size
	var a = float(n) if _at_home() else float(_focused_unit_index(units))
	pan_active = true
	pan = clamp(pan + amount * vp.x * 0.18, -a * vp.x, (float(n) - a) * vp.x)
	request_redraw()


# Al soltar Super: cae a la pantalla más cercana según el paneo acumulado (incluido el
# Hogar, si el paneo lo alcanzó).
func _snap_pan():
	if not pan_active:
		return
	var units = _units()
	var n = units.size()
	var vp = get_viewport_rect().size
	var a = float(n) if _at_home() else float(_focused_unit_index(units))
	var delta = int(round(pan / max(vp.x, 1.0)))
	pan_active = false
	pan = 0.0
	var target = int(clamp(a + float(delta), 0.0, float(n)))
	if target >= n:
		if not _at_home():
			_go_home()
	elif (target != int(a) or _at_home()) and n > 0:
		_focus_unit(units, target)
	request_redraw()


# Super+←/→: deja la ventana enfocada en modo tiled ocupando la mitad izquierda/derecha
# (junto a otra). Maximizar (Alt+F10) es lo mismo pero ocupando todo el workspace.
func _snap_tile(dir):
	if not tile_mode or focused_tile < 0:
		return
	var units = _units()
	var ui = _focused_unit_index(units)
	var members = units[ui]
	if members.size() >= 2:
		# Ya está en una franja: la reordena para quedar a la izquierda/derecha.
		var i = members.find(focused_tile)
		if i < 0:
			return
		var j = 0 if dir < 0 else members.size() - 1
		if i != j:
			members.remove(i)
			members.insert(j, focused_tile)
			_rebuild_tiles(units)
		for m in members:
			split_weight[m] = 1.0
		_focus_tile(focused_tile)
		return
	# Suelta: la tilea con otra pantalla vecina.
	var other = -1
	for k in range(units.size()):
		if k == ui:
			continue
		other = units[k][0]
		break
	if other < 0:
		return
	if dir < 0:
		_tile_drop(other, focused_tile)  # enfocada primero = izquierda
	else:
		_tile_drop(focused_tile, other)  # enfocada segunda = derecha
	split_weight[other] = 1.0
	split_weight[focused_tile] = 1.0


# Reordena la franja moviendo la pantalla de `dragged` al lugar de la de `anchor`.
func _move_window_to(dragged, anchor, before):
	if dragged < 0 or anchor < 0 or dragged == anchor:
		return
	if not tiles.has(dragged) or not tiles.has(anchor):
		return
	var units = _units()
	var du = _focused_unit_index_of(units, dragged)
	var au = _focused_unit_index_of(units, anchor)
	if du < 0 or au < 0 or du == au:
		return
	var moved = units[du]
	units.remove(du)
	var target = _focused_unit_index_of(units, anchor)
	if target < 0:
		target = units.size() - 1
	if not before:
		target += 1
	units.insert(int(clamp(target, 0, units.size())), moved)
	_rebuild_tiles(units)
	_focus_tile(dragged)


func _focused_unit_index_of(units, id):
	for i in range(units.size()):
		if units[i].has(id):
			return i
	return -1


# Enfoca la pantalla u (recordando su último miembro enfocado).
func _focus_unit(units, u):
	if u < 0 or u >= units.size():
		return
	var members = units[u]
	var want = unit_focus.get(members[0], members[0])
	if not members.has(want):
		want = members[0]
	_focus_tile(want)


# Intercambia pantallas en la fila (←/→). ↑/↓ sin efecto con una sola fila.
func _swap_dir(dir):
	if _at_home() or _home_anim_active():
		return
	if not tile_mode or tiles.empty():
		return
	if dir != -1 and dir != 1:
		return
	var units = _units()
	var ui = _focused_unit_index(units)
	_swap_units(units, ui, ui + dir)


func _swap_units(units, a, b):
	if a < 0 or b < 0 or a >= units.size() or b >= units.size() or a == b:
		return
	var tmp = units[a]
	units[a] = units[b]
	units[b] = tmp
	_rebuild_tiles(units)


func _rebuild_tiles(units):
	var out = []
	for u in units:
		out.append_array(u)
	tiles = out
	request_redraw()


func _toggle_expose(on):
	expose = on
	if on:
		expose_sel = max(tiles.find(focused_tile), 0)
		expose_auto = true
		release_modifiers()  # no dejar Ctrl/Shift pegados en la app al entrar
	# El pasaje se anima: cada ventana arranca desde su transform actual (pantalla o tarjeta).
	var now = OS.get_ticks_msec()
	for id in tiles:
		var node = tile_nodes.get(id)
		if node != null and is_instance_valid(node):
			view_anim[id] = {"from_pos": node.rect_position, "from_scale": node.rect_scale.x, "since": now}
	request_redraw()


func _expose_move(step):
	if tiles.empty():
		return
	expose_sel = posmod(expose_sel + step, tiles.size())
	expose_auto = true  # al cambiar la selección, se recentra
	request_redraw()


func _expose_commit():
	var id = -1
	if expose_sel >= 0 and expose_sel < tiles.size():
		id = tiles[expose_sel]
	_toggle_expose(false)
	if id >= 0:
		_focus_tile(id)
	request_redraw()


# --- Grupos (pantallas partidas) y minimizar ---

func _remove_from_group(id):
	split_weight.erase(id)
	for i in range(groups.size() - 1, -1, -1):
		var g = groups[i]
		var k = g.find(id)
		if k >= 0:
			g.remove(k)
			if g.size() < 2:
				groups.remove(i)
			break
	request_redraw()


# Pantalla partida: `a` se suma a la pantalla de `b` (drag en el Frame, o teclado).
func _tile_drop(a, b):
	if a < 0 or b < 0 or a == b:
		return
	if not tiles.has(a) or not tiles.has(b):
		return
	_remove_from_group(a)
	var g = _group_of(b)
	if g == null:
		g = [b, a]
		groups.append(g)
		split_weight[b] = 1.0
		split_weight[a] = 1.0
	else:
		g.append(a)
		split_weight.erase(a)
	# Quedan contiguas (la pantalla sale en orden b, a).
	tiles.erase(a)
	var at = tiles.find(b)
	tiles.insert((at + 1) if at >= 0 else tiles.size(), a)
	unit_focus[b] = a
	_focus_tile(a)


# Saca la ventana de su grupo: vuelve a pantalla completa.
func _untile_window(id):
	if id < 0 or not tiles.has(id) or _group_of(id) == null:
		return
	_remove_from_group(id)
	_focus_tile(id)


func _minimize_window(id):
	if id < 0 or not tiles.has(id):
		return
	# La ventana se encoge hacia su ítem del Frame mientras se minimiza (animación
	# fantasma: deja claro que pasó algo). El bloque atenuado queda en el Frame y el
	# anillo del Hogar marca la actividad como minimizada.
	_spawn_ghost(id, _panel_rect_for(id))
	if fullscreen_id == id:
		fullscreen_id = -1
	_remove_from_group(id)
	minimized[id] = true
	tiles.erase(id)
	tile_fade.erase(id)
	tile_intro.erase(id)
	tile_anim.erase(id)
	view_anim.erase(id)
	# Se libera ya el nodo: si `tiles` queda vacío no habrá _update_tiles() que lo
	# limpie y podría quedar un cuadro fantasma de la ventana minimizada.
	var node = tile_nodes.get(id)
	if node != null and is_instance_valid(node):
		node.queue_free()
	tile_nodes.erase(id)
	tile_rects.erase(id)
	tile_fit.erase(id)
	expose_cards.erase(id)
	if focused_tile == id:
		focused_tile = -1
		if tiles.empty():
			_go_home()
		else:
			_focus_tile(tiles[tiles.size() - 1])
	request_redraw()


func _restore_window(id):
	if id < 0 or not _id_alive(id):
		return
	_focus_tile(id)  # ya limpia `minimized` y reinserta


# Alt+M: minimiza la ventana enfocada; si ya está minimizada, la restaura. No depende
# de que el Frame esté a la vista (ver frame.gd/_input).
func _toggle_minimize_focused():
	var id = focused_tile
	if id < 0 or not _id_alive(id):
		return
	if minimized.has(id):
		_restore_window(id)
	elif current_activity != null and tiles.has(id):
		_minimize_window(id)
	request_redraw()


# Alt+F11: pantalla completa de la ventana enfocada (ocupa todo, se esconde el Frame).
func _toggle_fullscreen():
	if fullscreen_id >= 0:
		fullscreen_id = -1
	elif focused_tile >= 0 and tiles.has(focused_tile):
		fullscreen_id = focused_tile
	if frame != null:
		frame.set_visible(false)
	request_redraw()


# Alt+F10: maximizar = sacar la ventana de su franja partida para que ocupe todo el
# workspace (una ventana sola ya llena la pantalla; el contenido se ajusta con _content_fit).
func _maximize_window(id):
	if id < 0 or not tiles.has(id):
		return
	fullscreen_id = -1
	_remove_from_group(id)
	_focus_tile(id)
	if frame != null:
		frame.set_visible(false)
	request_redraw()


# Teclado: tilea la ventana enfocada con la siguiente (arma una pantalla partida sin mouse).
func _tile_with_next():
	if not tile_mode or focused_tile < 0:
		return
	var units = _units()
	var i = _focused_unit_index(units)
	var next_id = -1
	for k in range(i + 1, units.size()):
		for m in units[k]:
			if m != focused_tile:
				next_id = m
				break
		if next_id >= 0:
			break
	if next_id >= 0:
		_tile_drop(focused_tile, next_id)


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


# Bisel clásico de 2px del Hogar (claro arriba/izq, oscuro abajo/der); `pressed` lo
# invierte. Mismo lenguaje que los bloques del Frame. `r` en coords de pantalla.
func _draw_home_bevel(r, face, pressed):
	imgui_draw_rect_filled(r, face, 0.0)
	var light = HOME_BLOCK_DARK if pressed else HOME_BLOCK_LIGHT
	var dark = HOME_BLOCK_LIGHT if pressed else HOME_BLOCK_DARK
	imgui_draw_rect_filled(Rect2(r.position, Vector2(r.size.x, HOME_BEVEL)), light, 0.0)
	imgui_draw_rect_filled(Rect2(r.position, Vector2(HOME_BEVEL, r.size.y)), light, 0.0)
	imgui_draw_rect_filled(Rect2(Vector2(r.position.x, r.end.y - HOME_BEVEL), Vector2(r.size.x, HOME_BEVEL)), dark, 0.0)
	imgui_draw_rect_filled(Rect2(Vector2(r.end.x - HOME_BEVEL, r.position.y), Vector2(HOME_BEVEL, r.size.y)), dark, 0.0)


# `offset` corre el Hogar dentro de la fila de pantallas: 0 en su lugar, ±ancho fuera
# de vista. Así el paneo lo dibuja deslizándose junto a las ventanas, no de un salto.
func _draw_home(offset = 0.0):
	var now = OS.get_ticks_msec()
	_tick_starting(now)
	if is_key_pressed(KEY_TAB):
		apps_view = not apps_view
	if apps_view:
		_draw_apps(offset)
		return
	var vp = get_viewport_rect().size
	set_next_window_pos(Vector2(offset, 0.0), true)
	set_next_window_size(vp, true)
	var flags = WINDOW_NO_DECORATION | WINDOW_NO_BACKGROUND | WINDOW_NO_MOVE | WINDOW_NO_SAVED_SETTINGS | WINDOW_NO_BRING_TO_FRONT_ON_FOCUS
	# Sin padding el fondo y las posiciones absolutas coinciden con la vista.
	push_style_var_vec2(STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	if begin("##home", flags):
		# Fondo sobrio: degradado vertical suave (sin imagen por ahora).
		imgui_draw_rect_filled_multicolor(Rect2(Vector2.ZERO, vp), HOME_BG_TOP, HOME_BG_TOP, HOME_BG_BOTTOM, HOME_BG_BOTTOM)

		home_icon_loads = 2
		var u = grid_unit(vp)
		var pad = u * 0.125
		var btn_size = Vector2(u * 1.25, u * 1.25)
		var entries = _ring_entries()
		var layout = _orbit_layout(vp, entries.size())
		_ring_prune(entries)

		# El equipo propio ocupa el centro de la órbita; las apps quedan alrededor.
		# El ícono central (figura XO/monitor) ya no es decorativo: abre el menú de
		# sesión (Salir/Recargar), porque 'Salir' dejó de ser actividad del anillo.
		var cc = vp * 0.5
		var monitor = Rect2(cc - Vector2(u * 0.38, u * 0.30), Vector2(u * 0.76, u * 0.54))
		set_cursor_pos(monitor.position)
		push_style_color(COL_BUTTON, Color(0, 0, 0, 0))
		push_style_color(COL_BUTTON_HOVERED, Color(0, 0, 0, 0))
		push_style_color(COL_BUTTON_ACTIVE, Color(0, 0, 0, 0))
		push_style_var_float(STYLE_VAR_FRAME_ROUNDING, 0.0)
		var center_clicked = button("##home_center", monitor.size)
		var center_hover = is_item_hovered()
		pop_style_var()
		pop_style_color(3)
		var monitor_face = HOME_BLOCK_LIGHT
		if center_hover:
			monitor_face = monitor_face.linear_interpolate(Color(1, 1, 1, monitor_face.a), 0.10)
		if center_hover:
			set_tooltip("Sesión · Salir / Recargar")
		imgui_draw_rect_filled(monitor, monitor_face, 2.0)
		imgui_draw_rect_filled(Rect2(monitor.position + Vector2(4, 4), monitor.size - Vector2(8, 10)), HOME_BG_TOP, 0.0)
		imgui_draw_rect_filled(Rect2(cc + Vector2(-3, u * 0.24), Vector2(6, u * 0.13)), HOME_BLOCK_LIGHT, 0.0)
		imgui_draw_rect_filled(Rect2(cc + Vector2(-u * 0.21, u * 0.37), Vector2(u * 0.42, 4)), HOME_BLOCK_LIGHT, 0.0)
		if center_clicked:
			open_popup("##home_session")
		if begin_popup("##home_session"):
			text_disabled("Sesión")
			if menu_item("Salir"):
				recovery.quit(self)
			if menu_item("Recargar el shell"):
				recovery.restart(self)
			end_popup()

		# Anillo: ACTIVITIES + favoritos, con reacomodo animado al entrar/salir ítems.
		ring_layout = []
		ring_drop = null
		var mouse = get_mouse_pos()
		var slide = Vector2(offset, 0.0)
		for i in range(entries.size()):
			var e = entries[i]
			var pos = _ring_show(e.name, layout[i], now)
			var screen = pos + slide
			var label = e.name
			if e.activity != null and e.activity.has("service") and _service_running(e.name):
				label += " *"
			var clicked = _draw_ring_item(pos, btn_size, _ring_tex(e), label,
				_ring_state(e), e.id, starting.get(e.name, -1), _ring_appear(e.name, now))
			ring_layout.append({"entry": e, "screen": screen, "size": btn_size})
			if ring_drag != null and e.kind == "favorite" and e.name != ring_drag.name:
				var d = (mouse - (screen + btn_size * 0.5)).length()
				if d < btn_size.x * 1.6 and (ring_drop == null or d < ring_drop.dist):
					ring_drop = {"screen": screen, "size": btn_size, "dist": d, "entry": e}
			if clicked and ring_suppress != e.name:
				_ring_activate(e, pos, btn_size)
		ring_suppress = ""

		# Fantasma del ítem arrastrado, anclado al punto de agarre (no centrado).
		if ring_drag != null:
			_draw_ring_ghost(ring_drag, mouse - ring_grab, btn_size)
			if ring_drop != null:
				imgui_draw_circle(ring_drop.screen + ring_drop.size * 0.5, ring_drop.size.x * 0.5 + 3.0, RING_FOCUS, 0, 2.5)

		# Bloque Apps: tesela U x U con bisel, como los bloques del Frame.
		var apps_side = u
		var apps_pos = Vector2(vp.x - apps_side - pad, frame_bar_h(vp) + pad)
		set_cursor_pos(apps_pos)
		var apps_screen = get_cursor_screen_pos()
		push_style_color(COL_BUTTON, Color(0, 0, 0, 0))
		push_style_color(COL_BUTTON_HOVERED, Color(0, 0, 0, 0))
		push_style_color(COL_BUTTON_ACTIVE, Color(0, 0, 0, 0))
		push_style_var_float(STYLE_VAR_FRAME_ROUNDING, 0.0)
		var apps_clicked = button("##apps_btn", Vector2(apps_side, apps_side))
		var apps_held = is_item_active()
		var apps_hover = is_item_hovered()
		pop_style_var()
		pop_style_color(3)
		var apps_face = HOME_BLOCK_FACE
		if apps_hover and not apps_held:
			apps_face = apps_face.linear_interpolate(Color(1.0, 1.0, 1.0, apps_face.a), 0.08)
		_draw_home_bevel(Rect2(apps_screen, Vector2(apps_side, apps_side)), apps_face, apps_held)
		var apps_cw = 7.0 * get_imgui_scale()
		set_cursor_pos(apps_pos + Vector2((apps_side - 4.0 * apps_cw) * 0.5, (apps_side - 13.0 * get_imgui_scale()) * 0.5))
		text_colored(HOME_BLOCK_TEXT, "Apps")
		if apps_clicked:
			apps_view = true

		if activity_error != "":
			# Sobre la barra inferior, no dentro (en 800x600 la barra mide 80 px).
			set_cursor_pos(Vector2(pad, vp.y - frame_bar_h(vp) - 20.0))
			text(activity_error)
	end()
	pop_style_var()


# --- Anillo: entradas, favoritos y layout animado --------------------------------

# Ruta del archivo de favoritos: $XDG_CONFIG_HOME/gdtk/ring-favorites.json
# (~/.config/gdtk/ring-favorites.json por defecto), mismo patrón que frame-applets.json.
func _ring_path():
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		base = OS.get_environment("HOME") + "/.config"
	return base + "/gdtk/ring-favorites.json"


func _load_ring():
	ring_favorites = []
	ring_saved = []
	var f = File.new()
	if f.open(_ring_path(), File.READ) == OK:
		var txt = f.get_as_text()
		f.close()
		var res = JSON.parse(txt)
		if res.error == OK:
			var data = res.result
			var arr = data.get("favorites", []) if typeof(data) == TYPE_DICTIONARY else data
			if typeof(arr) == TYPE_ARRAY:
				for v in arr:
					if typeof(v) == TYPE_STRING and not ring_favorites.has(v):
						ring_favorites.append(v)
	ring_saved = ring_favorites.duplicate()


# Escritura atómica (tmp + rename); sin cambios reales no toca el archivo.
func _save_ring():
	if ring_saved == ring_favorites:
		return
	var path = _ring_path()
	Directory.new().make_dir_recursive(path.get_base_dir())
	var tmp = path + ".tmp"
	var w = File.new()
	if w.open(tmp, File.WRITE) != OK:
		printerr("shell: no se pudo escribir ", tmp)
		return
	w.store_string(JSON.print({"favorites": ring_favorites}))
	w.close()
	if Directory.new().rename(tmp, path) != OK:
		printerr("shell: no se pudo renombrar ", tmp, " a ", path)
		return
	ring_saved = ring_favorites.duplicate()


# Añade un favorito al anillo (Frame -> Anillo). Sin duplicar por id; el dedup por
# nombre contra ACTIVITIES se resuelve al armar las entradas.
func add_ring_favorite(app_id):
	if app_id == "" or ring_favorites.has(app_id):
		return
	ring_favorites.append(app_id)
	_save_ring()
	request_redraw()


func _app_by_id(id):
	if not apps.scanned:
		apps.scan()
	for a in apps.apps:
		if a.id == id:
			return a
	return null


# Entradas del anillo: primeras las actividades de ACTIVITIES (orden fijo), después
# los favoritos resueltos por `apps`. Sin duplicar por nombre (una app abierta ya
# figura como actividad dinámica).
func _ring_entries():
	var out = []
	var seen = {}
	for act in ACTIVITIES:
		if seen.has(act.name):
			continue
		seen[act.name] = true
		out.append({"kind": "activity", "id": act.name, "name": act.name, "activity": act, "app": null})
	if not apps.scanned:
		apps.scan()
	for id in ring_favorites:
		var app = _app_by_id(id)
		if app == null or seen.has(app.name):
			continue
		seen[app.name] = true
		out.append({"kind": "favorite", "id": app.id, "name": app.name, "activity": null, "app": app})
	return out


func _ring_tex(e):
	if e.kind == "favorite":
		return _activity_icon_of(e.app)
	return _activity_tex(e.activity)


func _ring_state(e):
	if e.kind == "favorite":
		return "favorite"
	return _activity_state(e.activity)


# Posición mostrada por nombre, animada hacia el objetivo con ease-out (~LAYOUT_MS).
# Entrada nueva: arranca en su destino y se le registra el instante de entrada para
# el fade/escala; retarget a mitad de camino continúa desde la posición actual.
func _ring_show(name, target, now):
	var cur = ring_pos.get(name)
	if cur == null:
		ring_pos[name] = target
		ring_anim.erase(name)
		ring_intro[name] = now
		return target
	var anim = ring_anim.get(name)
	if anim == null:
		if cur.distance_to(target) <= 0.5:
			ring_pos[name] = target
			return target
		anim = {"from": cur, "to": target, "since": now}
		ring_anim[name] = anim
	elif (anim.to as Vector2).distance_to(target) > 0.5:
		anim = {"from": cur, "to": target, "since": now}
		ring_anim[name] = anim
	var k = clamp(float(now - anim.since) / LAYOUT_MS, 0.0, 1.0)
	var p = (anim.from as Vector2).linear_interpolate(target, _ease_out(k))
	ring_pos[name] = p
	if k >= 1.0:
		ring_anim.erase(name)
	else:
		request_redraw()
		last_activity = now
	return p


func _ring_appear(name, now):
	var since = ring_intro.get(name, -1)
	if since < 0:
		return 1.0
	var k = clamp(float(now - since) / RING_INTRO_MS, 0.0, 1.0)
	if k < 1.0:
		request_redraw()
		last_activity = now
	return _ease_out(k)


# Descarta estado de animación de entradas que ya no están en el anillo.
func _ring_prune(entries):
	var keep = {}
	for e in entries:
		keep[e.name] = true
	for k in ring_pos.keys():
		if not keep.has(k):
			ring_pos.erase(k)
			ring_anim.erase(k)
			ring_intro.erase(k)


# Ease-out cúbico (sin overshoot): para reacomodos de layout no queremos rebote.
func _ease_out(k):
	k = clamp(k, 0.0, 1.0)
	return 1.0 - pow(1.0 - k, 3.0)


# Activar una entrada: favorito -> lanzar la app; actividad -> _activate con el pulso
# de arranque de las wayland cerradas.
func _ring_activate(e, pos, size):
	if e.kind == "favorite":
		_launch_app(e.app)
		return
	var i = _activity_named(e.name)
	if i < 0:
		return
	var act = ACTIVITIES[i]
	if act.has("wayland") and _activity_state(act) == "closed":
		pending_origin = Rect2(pos, size)
		pending_origin_since = OS.get_ticks_msec()
		starting[act.name] = OS.get_ticks_msec()
	_activate(i)


# Fantasma del arrastre del anillo: placa circular con el ícono, anclado al agarre.
func _draw_ring_ghost(entry, pos, size):
	var c = pos + size * 0.5
	var radius = size.x * 0.5 - 2.0
	imgui_draw_circle_filled(c + Vector2(2.0, 3.0), radius, Color(0, 0, 0, 0.35), 0)
	imgui_draw_circle_filled(c, radius, RING_PLATE, 0)
	imgui_draw_circle(c, radius, RING_FOCUS, 0, 2.5)
	var tex = _ring_tex(entry)
	if tex != null:
		var side = clamp(size.x * 0.56, 64.0, 72.0)
		set_cursor_pos(c - Vector2(side, side) * 0.5)
		image(tex, Vector2(side, side))
	else:
		var cw = 7.0 * get_imgui_scale()
		set_cursor_pos(c - Vector2(cw * 0.5, 6.5 * get_imgui_scale()))
		text_colored(Color(0.95, 0.85, 0.95, 1.0), entry.name.substr(0, 1))


# ¿El punto cae en la zona del anillo (Hogar a la vista)? El Frame lo consulta al
# soltar un app arrastrado para crear un favorito (Frame -> Anillo).
func is_ring_drop(pos):
	if current_activity != null or neighborhood_view:
		return false
	var vp = get_viewport_rect().size
	var top = frame_bar_h(vp)
	return pos.y > top and pos.y < vp.y - top


# Entrada del anillo cuyo rect (en pantalla) contiene el punto.
func _ring_hit(pos):
	for it in ring_layout:
		if pos.x >= it.screen.x and pos.x < it.screen.x + it.size.x \
				and pos.y >= it.screen.y and pos.y < it.screen.y + it.size.y:
			return it
	return null


# Id del favorito mostrado más cercano al punto (dentro del radio de una tesela),
# o "" si no hay ninguno cerca. `exclude_id` es el favorito arrastrado, que se salta
# para que soltarlo sobre sí mismo no lo mande al final. Un favorito arrastrado toma
# el lugar del más cercano.
func _favorite_target_near(pos, exclude_id = ""):
	var best = ""
	var bd = 1e9
	var bs = 0.0
	for it in ring_layout:
		var e = it.entry
		if e.kind != "favorite" or e.app.id == exclude_id:
			continue
		var d = (pos - (it.screen + it.size * 0.5)).length()
		if d < bd:
			bd = d
			best = e.app.id
			bs = it.size.x
	if best != "" and bd > bs * 1.6:
		return ""
	return best


# Inicio/reanudación del drag del anillo desde _input (el clic normal lo maneja ImGui).
func _ring_mouse(pressed, pos):
	if current_activity != null or apps_view or neighborhood_view:
		ring_press = null
		ring_drag = null
		ring_drop = null
		return
	if pressed:
		var hit = _ring_hit(pos)
		if hit != null:
			ring_press = hit.entry
			ring_from = pos
			ring_grab = pos - hit.screen
			ring_drag = null
	else:
		if ring_drag != null:
			_finish_ring_drag(pos)
			ring_suppress = ring_drag.name
		ring_press = null
		ring_drag = null
		ring_drop = null
		request_redraw()


func _finish_ring_drag(pos):
	var e = ring_drag
	if e == null:
		return
	# Ring -> basurero: borra el favorito (una actividad no se borra).
	if frame != null and frame.is_trash(pos):
		if e.kind == "favorite":
			ring_favorites.erase(e.app.id)
			_save_ring()
			request_redraw()
		return
	# Reordenar favoritos: el que se suelta sobre otro toma su lugar.
	if e.kind == "favorite":
		var target = _favorite_target_near(pos, e.app.id)
		if target != "":
			ring_favorites.erase(e.app.id)
			var at = ring_favorites.find(target)
			if at < 0:
				at = ring_favorites.size()
			ring_favorites.insert(at, e.app.id)
			_save_ring()
			request_redraw()


# Posiciones de las actividades en órbitas alrededor de la computadora.
func _home_layout(vp):
	return _orbit_layout(vp, ACTIVITIES.size())


func _orbit_layout(vp, n):
	var out = []
	if n <= 0:
		return out
	var u = grid_unit(vp)
	var btn = u * 1.25
	var top = frame_bar_h(vp)
	var radius = min(vp.x * 0.32, (vp.y - 2.0 * top - btn - 32.0) * 0.5)
	var inner_count = min(n, 7)
	for i in range(n):
		var count = inner_count if i < inner_count else n - inner_count
		var slot = i if i < inner_count else i - inner_count
		var r = radius if i < inner_count else radius * 1.45
		var a = (-PI * 0.5 if i < inner_count else 0.0) + TAU * float(slot) / float(count)
		var center = vp * 0.5 + Vector2(cos(a) * r, sin(a) * r)
		out.append(Vector2(clamp(center.x - btn * 0.5, 2.0, vp.x - btn - 2.0),
			clamp(center.y - btn * 0.5, top + 2.0, vp.y - top - btn - 18.0)))
	return out


# Insignia de identidad del Frame: figura XO + nombre de usuario, cacheada como
# cualquier ícono Sugar (el rasterizador vive acá; el Frame la consume).
func identity_tex():
	return _load_sugar_svg("computer-xo", XO_STROKE, XO_FILL)


# Notificación de arranque: mantiene el pulso mientras la actividad no tenga
# ventana/estado abierto y lo corta a los STARTING_MAX_MS o al llegar la ventana.
func _tick_starting(now):
	for name in starting.keys():
		if now - starting[name] > STARTING_MAX_MS:
			starting.erase(name)
			continue
		var i = _activity_named(name)
		if i < 0 or _activity_state(ACTIVITIES[i]) != "closed":
			starting.erase(name)
	if not starting.empty():
		request_redraw()


# Rasteriza un SVG de Sugar a ImageTexture cacheada. Reemplaza las entidades
# &stroke_color;/&fill_color; por los colores XO, quita el DOCTYPE y lo carga.
func _load_sugar_svg(name, stroke, fill):
	var key = name + "|" + stroke.to_html(false) + "|" + fill.to_html(false)
	if sugar_icons.has(key):
		return sugar_icons[key]
	var text = _sugar_svg_text(name, stroke, fill)
	if text == "":
		return null
	var img = Image.new()
	var ok = false
	if img.has_method("load_svg_from_string"):
		ok = img.load_svg_from_string(text, 1.0) == OK
	if not ok and img.has_method("load_svg_from_buffer"):
		ok = img.load_svg_from_buffer(text.to_utf8(), 1.0) == OK
	if not ok:
		# Fallback: este motor no expone load_svg_from_string; se escribe el SVG ya
		# sustituido en user:// y lo rasteriza el loader SVG del motor.
		ok = _load_sugar_file(img, key, text)
	if not ok or img.get_width() == 0:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	sugar_icons[key] = tex
	return tex


func _load_sugar_file(img, key, text):
	var dir = "user://sugar-icons"
	Directory.new().make_dir_recursive(dir)
	var path = dir + "/" + key.md5_text() + ".svg"
	var f = File.new()
	if f.open(path, File.WRITE) != OK:
		return false
	f.store_string(text)
	f.close()
	return img.load(path) == OK


# Texto del SVG sin DOCTYPE, con width/height agrandados y las entidades ya resueltas.
func _sugar_svg_text(name, stroke, fill):
	var f = File.new()
	if f.open(SUGAR_DIR + name + ".svg", File.READ) != OK:
		return ""
	var s = f.get_as_text()
	f.close()
	var d = s.find("<!DOCTYPE")
	if d >= 0:
		var e = s.find("]>", d)
		if e < 0:
			e = s.find(">", d) - 1
		if e >= d:
			s = s.substr(0, d) + s.substr(e + 2, s.length() - e - 2)
	var size = str(SUGAR_RASTER)
	s = s.replace('height="55px"', 'height="' + size + '"').replace('width="55px"', 'width="' + size + '"')
	s = s.replace('height="55"', 'height="' + size + '"').replace('width="55"', 'width="' + size + '"')
	s = s.replace("&stroke_color;", "#" + stroke.to_html(false))
	s = s.replace("&fill_color;", "#" + fill.to_html(false))
	return s


# Estado de una actividad en el anillo: cerrado / abierto / minimizado / enfocado.
func _activity_state(activity):
	if current_activity != null and current_activity.name == activity.name:
		return "focused"
	if activity.has("wayland") and wayland_ids.has(activity.name) and _id_alive(wayland_ids[activity.name]):
		return "minimized" if minimized.has(wayland_ids[activity.name]) else "open"
	if activity.has("script") and script_instances.has(activity.name):
		return "open"
	if activity.has("service") and _service_running(activity.name):
		return "open"
	return "closed"


# Botón circular del anillo: placa, borde por estado, ícono XDG/Sugar y etiqueta.
# `starting_since` >= 0: notificación de arranque, el ícono pulsa (escala y borde).
# `appear` (0..1): entrada nueva, escala/fade breve (ver _ring_appear).
func _draw_ring_item(pos, size, tex, label, state, id, starting_since = -1, appear = 1.0):
	appear = clamp(appear, 0.0, 1.0)
	var scale = lerp(0.72, 1.0, appear)
	set_cursor_pos(pos)
	var sp = get_cursor_screen_pos()
	var c = sp + size * 0.5
	var base_radius = size.x * 0.5 - 2.0
	var pulse = 1.0
	var glow = 0.0
	if starting_since >= 0:
		var ph = float(OS.get_ticks_msec() - starting_since) / 1000.0
		var w = sin(TAU * ph / STARTING_PERIOD_S)
		pulse = 1.0 + 0.1 * w  # escala 0.9..1.1
		glow = clamp(0.5 + 0.5 * w, 0.0, 1.0)
	var radius = base_radius * pulse * scale
	var border = RING_CLOSED
	var thickness = 1.5
	if starting_since >= 0:
		# Arrancando: además del pulso, borde más grueso y brillante.
		border = Color(1.0, 0.82, 0.40, 0.5 + 0.5 * glow)
		thickness = 2.0 + 2.5 * glow
	elif state == "focused":
		border = RING_FOCUS
		thickness = 3.5
	elif state == "minimized":
		border = RING_MIN
		thickness = 2.0
	elif state == "open":
		border = RING_OPEN
		thickness = 2.5
	elif state == "favorite":
		border = RING_FAVORITE
		thickness = 2.0
	if (get_mouse_pos() - c).length() <= radius:
		border = Color(border.r, border.g, border.b, 1.0)
	var plate = RING_PLATE
	plate.a *= appear
	var edge = border
	edge.a *= appear
	imgui_draw_circle_filled(c, radius, plate, 0)
	if starting_since >= 0:
		imgui_draw_circle(c, radius + 4.0, Color(1.0, 0.85, 0.45, (0.20 + 0.35 * glow) * appear), 0, 2.0)
	if state == "focused":
		imgui_draw_circle(c, radius + 3.0, Color(RING_FOCUS.r, RING_FOCUS.g, RING_FOCUS.b, 0.35 * appear), 0, 2.0)
	imgui_draw_circle(c, radius, edge, 0, thickness)
	if state == "open":
		# Señal de abierto además del color.
		var dot = RING_OPEN
		dot.a *= appear
		imgui_draw_circle_filled(c + Vector2(radius * 0.72, radius * 0.72), 4.0, dot, 0)

	# Área pulsable completa (mismo tamaño que la grilla anterior), sin fondo azul.
	push_style_color(COL_BUTTON, Color(0, 0, 0, 0))
	push_style_color(COL_BUTTON_HOVERED, Color(1, 1, 1, 0.05))
	push_style_color(COL_BUTTON_ACTIVE, Color(1, 1, 1, 0.12))
	push_style_var_float(STYLE_VAR_FRAME_ROUNDING, base_radius)
	var clicked = button("##ring_" + id, size)
	pop_style_var()
	pop_style_color(3)

	var cw = 7.0 * get_imgui_scale()
	if tex != null:
		# 64-72 px de ícono dentro del círculo de 1.5U: nunca por debajo de 64.
		var side = clamp(size.x * 0.56, 64.0, 72.0) * pulse * scale
		var icon_size = Vector2(side, side)
		set_cursor_pos(pos + (size - icon_size) * 0.5)
		image(tex, icon_size)
	else:
		set_cursor_pos(pos + Vector2((size.x - cw) * 0.5, (size.y - 13.0 * get_imgui_scale()) * 0.5))
		text_colored(Color(0.95, 0.85, 0.95, 1.0), label.substr(0, 1).to_upper())

	if state == "minimized":
		# Distinto de "abierta" más allá del color: ícono atenuado + contorno punteado.
		imgui_draw_circle_filled(c, radius, Color(0.05, 0.06, 0.09, 0.45 * appear), 0)
		var seg = 18
		var min_col = RING_MIN
		min_col.a *= appear
		for i in range(seg):
			if i % 2 == 1:
				var ang = TAU * float(i) / float(seg)
				imgui_draw_circle_filled(c + Vector2(cos(ang), sin(ang)) * radius, 2.0, min_col, 0)

	var lab = RING_LABEL if (state != "closed" and state != "minimized") else RING_LABEL_DIM
	lab.a *= appear
	set_cursor_pos(pos + Vector2((size.x - label.length() * cw) * 0.5, size.y + 3.0))
	text_colored(lab, label)
	return clicked


# Ícono XDG de una actividad: primero por programa de la ventana, luego por nombre.
func _activity_tex(activity):
	if not apps.scanned:
		apps.scan()
	var prog = ""
	if activity.has("wayland") and activity.wayland.size() > 0:
		prog = activity.wayland[0]
	if prog != "":
		for a in apps.apps:
			if apps._program(a.exec) == prog and _activity_icon_of(a) != null:
				return a.tex
	# Sólo apps reales buscan por nombre; las internas usan monograma.
	if activity.has("wayland"):
		var want = apps.fold(activity.name)
		for a in apps.apps:
			if apps.fold(a.name) == want and _activity_icon_of(a) != null:
				return a.tex
	# Sin ícono XDG: algunos ítems del anillo tienen uno de Sugar razonable.
	return _sugar_icon_for(activity.name)


# Ícono de una ventana sin actividad cargada (o cuya actividad no tiene ícono):
# primero el XDG del programa por el app_id del toplevel; si no hay, el Sugar por
# nombre; y por último un ícono genérico de ventana Sugar (nunca un monograma suelto).
func _window_icon(id, name):
	if id >= 0:
		var app_id = compositor.get_app_id(id)
		if app_id != "":
			var tex = _activity_tex({"name": name, "wayland": [app_id]})
			if tex != null:
				return tex
	var sugar = _sugar_icon_for(name)
	if sugar != null:
		return sugar
	return _load_sugar_svg("document-send", SUGAR_STROKE, SUGAR_FILL)


func _sugar_icon_for(name):
	var icon = SUGAR_ACTIVITY_ICONS.get(name, "")
	if icon == "":
		return null
	return _load_sugar_svg(icon, SUGAR_STROKE, SUGAR_FILL)


func _activity_icon_of(app):
	if not app.icon_tried:
		if home_icon_loads <= 0:
			request_redraw()
			return null
		home_icon_loads -= 1
		apps._load_icon(app)
	return app.tex


func _draw_apps(offset = 0.0):
	var vp = get_viewport_rect().size
	# Una celda libre a cada lado y sobre/bajo la zona desplazable.
	var u = grid_unit(vp)
	set_next_window_pos(Vector2(offset + u, u), true)
	set_next_window_size(Vector2(vp.x - 2.0 * u, vp.y - 2.0 * u), true)
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
	var act = ACTIVITIES[i]
	# Igual que el anillo: si la actividad está cerrada se registra el pulso de
	# arranque; la ventana entra animada desde el ícono de la grilla cuando llegue.
	if act.has("wayland") and _activity_state(act) == "closed":
		act["match"] = [apps._program(app.exec), app.name]
		if apps.chosen_rect != null:
			pending_origin = apps.chosen_rect
			pending_origin_since = OS.get_ticks_msec()
	_activate(i)
	# La grilla vuelve al anillo de Hogar: ahí se ve el pulso de arranque del ícono
	# hasta que llegue la ventana (la vista no salta a la actividad al lanzarla).
	apps_view = false
	apps.watch(self, app.name, last_launch_pid)
	# Si no se pudo lanzar, no queda colgada en el anillo.
	if not _pending_has(app.name) and not wayland_ids.has(app.name) and ACTIVITIES[i].get("dynamic", false):
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
		for pid in _service_processes(name):
			OS.kill(pid)
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
	if service_pids.has(name) and OS.execute("sh", ["-c", "kill -0 " + str(service_pids[name])], true) == 0:
		return true
	service_pids.erase(name)
	var pids = _service_processes(name)
	if pids.empty():
		return false
	service_pids[name] = pids[0]
	return true


func _service_processes(name):
	var service = ""
	for activity in ACTIVITIES:
		if activity.name == name:
			service = activity.get("service", "")
			break
	if service == "":
		return []
	var cmd = service.replace("~/", OS.get_environment("HOME") + "/")
	var out = []
	if OS.execute("pgrep", ["-u", OS.get_environment("USER"), "-f", "-x", cmd], true, out) != 0 or out.empty():
		return []
	var pids = []
	for line in String(out[0]).split("\n", false):
		var pid = int(line.strip_edges())
		if pid > 0:
			pids.append(pid)
	return pids


func _open_by_name(name):
	for i in range(ACTIVITIES.size()):
		if ACTIVITIES[i].name == name:
			_activate(i)
			return
	activity_error = "Actividad desconocida: " + name


# --- Cola de lanzamientos pendientes -----------------------------------------
# Varias actividades wayland pueden estar esperando su toplevel a la vez. Al llegar
# una ventana se intenta casar su app_id/título con el `expect` de algún pendiente;
# si el compositor no publica ese dato (o nada coincide) se usa la más reciente, que
# es el comportamiento histórico.

func _pending_has(name):
	for p in pending_launches:
		if p.name == name:
			return true
	return false


func _pending_add(name, expect = []):
	for p in pending_launches:
		if p.name == name:
			p["expect"] = expect
			p["since"] = OS.get_ticks_msec()
			pending_wayland = name
			return
	pending_launches.append({"name": name, "expect": expect, "since": OS.get_ticks_msec()})
	pending_wayland = name


func _pending_remove(name):
	for i in range(pending_launches.size() - 1, -1, -1):
		if pending_launches[i].name == name:
			pending_launches.remove(i)
	if pending_wayland == name:
		pending_wayland = pending_launches[pending_launches.size() - 1].name if not pending_launches.empty() else ""


func _pending_clear():
	pending_launches = []
	pending_wayland = ""


# Tokens para casar la ventana de una actividad: el programa lanzado (si no es el
# envoltorio `sh`), el nombre de la actividad y, cuando la grilla lo sabe, `match`.
func _expect_for(activity):
	var toks = []
	if activity.has("match"):
		for t in activity.match:
			toks.append(str(t))
	if activity.has("wayland") and activity.wayland.size() > 0:
		var prog = str(activity.wayland[0])
		if prog != "sh":
			toks.append(prog)
	var nm = str(activity.get("name", ""))
	if nm != "":
		toks.append(nm)
	return toks


# Pendiente al que corresponde el toplevel `id`, o "" si no hay app_id ni título
# (sin dato no se inventa: el llamador cae al comportamiento actual).
func _match_pending(id):
	var app_id = compositor.get_app_id(id)
	var title = compositor.get_title(id)
	if app_id == "" and title == "":
		return ""
	var aid = app_id.to_lower()
	var tit = title.to_lower()
	for k in range(pending_launches.size() - 1, -1, -1):
		for t in pending_launches[k].expect:
			var tok = str(t).to_lower()
			if tok == "":
				continue
			var base = tok.get_file() if tok.find("/") >= 0 else tok
			if base == "":
				continue
			var hit = aid != "" and (aid.find(base) >= 0 or base.find(aid) >= 0)
			if not hit and tit != "":
				hit = tit.find(base) >= 0
			if hit:
				return pending_launches[k].name
	return ""


func _open_wayland(activity):
	var name = activity.name
	activity_error = ""

	var id = -1
	if wayland_ids.has(name) and _id_alive(wayland_ids[name]):
		id = wayland_ids[name]

	if id >= 0:
		# Ya tenía ventana: se le sale de cualquier actividad previa y se enfoca, sin
		# pulso ni animación de entrada (no es un arranque nuevo).
		_release_activity()
		activity_instance = null
		pending_origin = null
		_pending_remove(name)
		starting.erase(name)
		current_activity = activity
		_focus_tile(id)
		return

	# Lanzamiento nuevo (actividad cerrada): la vista SE QUEDA EN HOGAR y el ícono
	# pulsa (starting / _tick_starting) hasta que llegue su toplevel. No se toca
	# current_activity, así el compositor no muestra el contenido de OTRA ventana en
	# el intervalo; cuando la ventana aparece, _on_toplevel_added enfoca y hace la
	# ampliación desde pending_origin. Si no llega en STARTING_MAX_MS el pulso se corta.
	if _pending_has(name):
		# Ya se está lanzando esta misma actividad: no lanzar un segundo proceso.
		return
	# Se conservan los otros pendientes (pueden seguir abriendo su ventana).
	_pending_add(name, _expect_for(activity))
	starting[name] = OS.get_ticks_msec()

	var vp = get_viewport_rect().size
	view.rect_position = Vector2.ZERO
	view.rect_size = vp
	view.rect_clip_content = true
	compositor.default_size = view.rect_size

	var cmd = activity.wayland[0]
	var args = PoolStringArray()
	for i in range(1, activity.wayland.size()):
		args.push_back(activity.wayland[i])

	var pid = compositor.launch(cmd, args)
	last_launch_pid = pid
	if pid < 0:
		_pending_remove(name)
		starting.erase(name)
		activity_error = "No se pudo lanzar " + cmd
		_go_home()
	else:
		print("launched ", cmd, " pid ", pid)


func _go_home():
	release_modifiers()  # no dejar modificadores pegados en la app que sale de foco
	home_slide_since = -1
	apps_view = false  # el Hogar muestra siempre la fila de favoritos, no la grilla
	neighborhood_view = false
	neighborhood_ui.selected = ""
	_release_activity()
	current_activity = null
	activity_instance = null
	_pending_clear()
	typed = false
	type_queue = []
	type_done_frame = -1
	tex_ready_frame = -1
	expose = false
	view.visible = false  # los tiles siguen vivos: se vuelven a ver al enfocar una ventana


# --- Vecindario --------------------------------------------------------------

# Abrir la vista Vecindario desde el bloque del Frame (sin actividad abierta).
func _go_neighborhood():
	if current_activity != null or apps_view:
		_go_home()
	neighborhood_view = true
	expose = false
	if neighborhood != null:
		neighborhood.start()   # idempotente: el hilo queda vivo mientras el shell viva
		neighborhood.poll()
	neighborhood_ui.refresh(true)
	request_redraw()


# Volver al Hogar desde el Vecindario (Esc, el bloque Inicio o el mismo bloque).
func _close_neighborhood():
	neighborhood_view = false
	neighborhood_ui.selected = ""
	request_redraw()


# El hilo de refresco no debe quedar vivo al recargar/cerrar el shell.
func _exit_tree():
	if neighborhood != null:
		neighborhood.stop()
		neighborhood = null


# Conectar una red: siempre por nmtui en la actividad Terminal, sin pasar secretos.
func _open_nmtui():
	_close_neighborhood()
	var name = _unique_activity_name("Terminal")
	ACTIVITIES.append({"name": name, "wayland": ["alacritty", "-e", "nmtui", "connect"], "dynamic": true})
	var i = ACTIVITIES.size() - 1
	_activate(i)
	if not _pending_has(name) and not wayland_ids.has(name):
		ACTIVITIES.remove(i)


# Encender la radio desde el estado vacío: acción explícita, nunca en silencio.
func _wifi_radio_on():
	OS.execute("nmcli", ["radio", "wifi", "on"])
	request_redraw()


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
	if pending_wayland != "" or not pending_launches.empty():
		# Con app_id/título se asocia SÓLO con el pendiente cuyo comando coincide (así
		# una ventana fuera de orden se ata a su lanzamiento, no a la más reciente).
		# Sin app_id ni título no hay dato: se usa la pendiente más reciente, el
		# comportamiento histórico. Con dato pero sin coincidencia no se inventa:
		# la ventana se trata como suelta (actividad dinámica).
		var has_data = compositor.get_app_id(id) != "" or compositor.get_title(id) != ""
		var name = _match_pending(id)
		if name == "" and not has_data:
			name = pending_wayland
		if name != "":
			_pending_remove(name)
			starting.erase(name)  # llegó la ventana: se corta la notificación de arranque
			wayland_ids[name] = id
			# Si veníamos de una actividad de script, se sueltan sus recursos transitorios
			# (la instancia se conserva); recién acá se cambia de vista, no al lanzar.
			_release_activity()
			activity_instance = null
			_add_tile(id)
			_focus_tile(id)
			return
	# Sin actividad (o sin coincidencia con app_id/título): se creara una dinamica.
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
	_pending_clear()
	_add_tile(id)
	_focus_tile(id)
	print("actividad dinamica ", name, " para toplevel ", id)


func _add_tile(id):
	if not tiles.has(id):
		tiles.append(id)
		tile_intro[id] = _new_intro()
	request_redraw()


# Entrada animada: si hay un ícono de origen reciente, escala desde él; si no, desde el
# borde derecho (mismo tamaño). `ready` pasa a true con la primera textura.
func _new_intro():
	var from = null
	if pending_origin != null and OS.get_ticks_msec() - pending_origin_since < 4000:
		from = pending_origin
	pending_origin = null
	return {"from": from, "since": OS.get_ticks_msec(), "ready": false, "rect": Rect2()}


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
	starting.erase(removed_name)
	# Las actividades dinamicas se van con su ventana; las fijas quedan.
	var index = _activity_named(removed_name)
	if index >= 0 and ACTIVITIES[index].get("dynamic", false):
		ACTIVITIES.remove(index)
	# Sale de las pantallas: congela su cuadro para la animación de cierre, limpia
	# grupo/minimizado y, si era la enfocada y no estamos en una actividad de script,
	# pasa el foco al vecino.
	var had_tile = tiles.has(id)
	if had_tile:
		_spawn_ghost(id, _panel_rect_for(id))
	if fullscreen_id == id:
		fullscreen_id = -1
	_remove_from_group(id)
	minimized.erase(id)
	unit_focus.erase(id)
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
	if window_dragging:
		return
	if expose:
		if event is InputEventMouseButton and event.pressed:
			var hit = _view_hit_test(event.position)
			if hit.id >= 0:
				expose_sel = tiles.find(hit.id)
				_expose_commit()
		return
	if event is InputEventMouseMotion:
		# Asa de redimensión de la franja: primero la arrastra, después sólo la insinúa.
		if resize_handle != null:
			_resize_to(resize_handle, event.position.x)
			request_redraw()
			return
		hover_handle = _handle_at(event.position)
		if hover_handle != null:
			request_redraw()
			return
		var hit = _view_hit_test(event.position)
		if hit.id < 0:
			return
		compositor.pointer_motion(hit.id, hit.pos)
	elif event is InputEventMouseButton:
		# Con Super la rueda es para el shell (cambiar de workspace), no para la app.
		if (event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN) \
				and Input.is_key_pressed(KEY_META):
			return
		if event.pressed and event.button_index == BUTTON_LEFT:
			var h = _handle_at(event.position)
			if h != null:
				resize_handle = h
				hover_handle = h
				request_redraw()
				return
		elif not event.pressed and resize_handle != null:
			resize_handle = null
			request_redraw()
			return
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
			# El compositor espera coords del buffer: la caja alinea la geometry en
			# rect.position, así que se suma geo.position.
			return {"id": d, "pos": pos - rect.position + _dialog_geo(d).position, "dialog": d}
	for id in tiles:
		var r = tile_rects.get(id)
		if r == null:
			continue
		var fit = tile_fit.get(id)
		var geo = compositor.get_geometry(id)
		# El contenido se dibuja en coords del buffer + offset; el compositor espera
		# coords del buffer, así que alcanza con deshacer el offset (d - offset).
		var content = r
		if fit != null and fit.scale > 0.0:
			content = Rect2(r.position + geo.position * fit.scale + fit.offset, geo.size * fit.scale)
		if content.has_point(pos):
			if fit != null and fit.scale > 0.0:
				return {"id": id, "pos": (pos - r.position - fit.offset) / fit.scale, "dialog": 0}
			return {"id": id, "pos": pos - r.position + geo.position, "dialog": 0}
	return {"id": -1, "pos": Vector2.ZERO, "dialog": 0}


# Teclear en el Home lleva a la búsqueda de apps.
# En _input (Godot 3 lo llama también en ImGuiCanvas): con el puntero sobre el
# home ImGui marca todo como manejado y a _unhandled_input no llega nada.
func _input(event):
	last_activity = OS.get_ticks_msec()
	if event is InputEventMouseMotion:
		input_motion_count += 1
		# Drag del anillo (Hogar): el clic normal lo resuelve ImGui; acá sólo se
		# detecta el arrastre una vez superado el umbral.
		if ring_press != null and ring_drag == null and event.position.distance_to(ring_from) > DRAG_PX:
			ring_drag = ring_press
			request_redraw()
		elif ring_drag != null:
			request_redraw()
	elif event is InputEventMouseButton:
		input_button_count += 1
		input_last_button = {"button": event.button_index, "pressed": event.pressed, "device": event.device, "pos": [event.position.x, event.position.y]}
		if event.button_index == BUTTON_LEFT:
			_ring_mouse(event.pressed, event.position)
	elif event is InputEventScreenTouch:
		input_touch_count += 1
	if event is InputEventKey:
		input_last_key = {"scancode": event.scancode, "physical": event.physical_scancode,
			"pressed": event.pressed, "ctrl": event.control, "shift": event.shift,
			"alt": event.alt, "meta": event.meta}
	if event is InputEventMouse:
		_move_eis_cursor(event)
	if current_activity == null and not apps.search_active and not neighborhood_view and event is InputEventKey and event.pressed \
			and event.unicode >= 32 and not (event.control or event.alt or event.meta):
		apps_view = true
		apps.type(char(event.unicode))


func _unhandled_input(event):
	if not (event is InputEventKey):
		return
	var id = _current_wayland_id()
	if id < 0:
		id = last_key_target  # última ventana que recibió teclas (exposé/Home incluidos)
	if id < 0:
		return
	if event.pressed:
		# Las pulsaciones sólo van a la app con una actividad wayland activa y sin exposé.
		if current_activity == null or not current_activity.has("wayland") or expose:
			return
		last_key_target = id
	# Las SUELTAS se reenvían siempre (aunque estemos en exposé o en Home): si no, un
	# modificador apretado antes de abrir exposé/Home queda pegado en la app.
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
