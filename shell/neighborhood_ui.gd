extends Control

# K10a — Vecindario: un solo mapa 2D (rediseño).
#
# Centro "Este equipo" con ícono de monitor; vecinos como nodos circulares.
# Si Settings ya guardó una posición relativa, el mapa la refleja; si no, los
# vecinos quedan en el anillo exterior. El Wi-Fi es infraestructura: puntos chicos
# en los anillos + "Red: <SSID>".
#
# Interacción:
#   - clic izquierdo = seleccionar;
#   - clic derecho = menú popup estilo WindowMaker (paleta de menu_style.gd)
#     con acciones en lenguaje humano; las deshabilitadas muestran su razón.
#   - la edición fina de posición vive en Configuración > Pantallas.
#
# La geometría y el vocabulario viven en el helper puro neighborhood_map.gd;
# acá sólo se dibuja el snapshot y se delega la ejecución al shell. Nada de I/O
# ni procesos en refresh()/_draw()/_process(): los snapshots ya vienen de
# neighborhood.gd (Thread) y de las cachés del shell.

const MAP = preload("res://neighborhood_map.gd")
const MENU = preload("res://menu_style.gd")
const INBOX = preload("res://neighborhood_inbox.gd")

const BG = Color(0.055, 0.065, 0.095, 1.0)
const RING = Color(0.60, 0.69, 0.82, 0.20)
const RING_MID = Color(0.60, 0.69, 0.82, 0.30)
const TEXT = Color(0.91, 0.94, 0.98, 1.0)
const TEXT_DIM = Color(0.62, 0.70, 0.82, 1.0)
const HIGHLIGHT = Color(1.0, 0.84, 0.43, 1.0)
const NODE_BG = Color(0.10, 0.13, 0.20, 1.0)
const NODE_RING = Color(0.60, 0.69, 0.82, 0.40)
const NODE_SEL = Color(1.0, 0.84, 0.43, 1.0)
const NODE_DIM_ALPHA = 0.45
const CENTER_PLATE = Color(0.14, 0.18, 0.27, 1.0)
const WIFI_DOT = Color(0.55, 0.64, 0.80, 0.65)
const WIFI_DOT_ACTIVE = Color(1.0, 0.84, 0.43, 0.95)
# Bluetooth: conectado (verde), vinculado (claro) y sólo conocido (tenue).
const BT_DOT_CONNECTED = Color(0.52, 0.90, 0.58, 1.0)
const BT_DOT_PAIRED = Color(0.78, 0.84, 0.96, 0.95)
const BT_DOT_KNOWN = Color(0.55, 0.64, 0.80, 0.60)
# Íconos nuevos (The Noun Project, ver icons/np/CREDITS.txt): PNG claros. Los hosts
# llevan el ícono de su `kind` y el punto del Wi-Fi pasa a ser un ícono de AP.
const NP_DIR = "res://icons/np/"
const DEVICE_ICONS = {
	"desktop": "device-desktop",
	"laptop": "device-laptop",
	"tablet": "device-tablet",
	"mobile": "device-mobile",
	"tv": "device-tv",
}
const AP_ICON = "access-point"

# Menú contextual (estilo WindowMaker; mismas medidas que menu_style.gd).
const MENU_W = 248.0
const MENU_TITLE_H = 20.0
const MENU_ROW_H = 26.0
const MENU_SEP_H = 8.0
const MENU_REASON_H = 15.0
const MENU_PAD = 6.0
const MENU_PAD_X = 8.0

const HOST_FALLBACK_ICONS = ["sugar/network-wired", "sugar/computer-xo", "network-connected"]

var shell = null
var model = null
var selected = ""            # SSID (compatibilidad; el Wi-Fi ya no se selecciona)
var selected_host = ""       # id del vecino seleccionado
var drawn_version = -1
var drawn_size = Vector2.ZERO
var center = Vector2.ZERO
var radius = 0.0
var wifi_points = []
var bt_points = []           # dispositivos Bluetooth (proveedor del Vecindario)
var host_nodes = []
var directions = {}          # hid -> entry {"direction","confirm",...} (lo puebla el shell)
var direction_conflicts = [] # lista de {"direction","hids":[..]} (la puebla el shell)
var _actions = null          # instancia perezosa de neighborhood_actions.gd
var _directions_model = null # instancia perezosa de neighborhood_directions.gd
var _icon_cache = {}         # nombre de ícono -> ruta resuelta (evita I/O repetido)
var _tex_cache = {}          # ruta resuelta -> ImageTexture (para _draw directo)

# Arrastre (imán a una dirección al soltar).
var _drag_id = ""
var _drag_from = Vector2.ZERO
var _drag_now = Vector2.ZERO
var _dragging = false

# Menú contextual.
var _menu_host = null
var _menu_items = []
var _menu_rows = []
var _menu_rect = Rect2()
var _menu_open_pos = Vector2.ZERO
var _menu_hover = -1
var _menu_layer = null       # nodo hijo propio, por encima de íconos (ver _sync_menu)
var _menu_is_wifi = false    # true = el menú es de una red Wi-Fi, no de un host
var _menu_wifi = null        # red Wi-Fi del menú (ver _open_wifi_menu)
var _menu_is_bt = false      # true = el menú es de un dispositivo Bluetooth
var _menu_bt = null          # dispositivo Bluetooth del menú
var _since_ms = -1


func refresh(force = false):
	if model == null:
		return
	var vp = get_viewport_rect().size
	if not force and model.version == drawn_version and vp == drawn_size:
		return
	drawn_version = model.version
	drawn_size = vp
	rect_size = vp
	mouse_filter = Control.MOUSE_FILTER_STOP
	if _since_ms < 0:
		_since_ms = OS.get_ticks_msec()
	for child in get_children():
		child.free()
	wifi_points = []
	host_nodes = []
	var bar = _bar()
	var networks = model.networks if model.get("networks") != null else []
	var hosts = model.hosts if model.get("hosts") != null else []
	var radii = MAP.map_radii(vp, bar)
	center = vp * 0.5
	radius = radii.outer
	wifi_points = MAP.wifi_dots(networks, vp, bar)
	bt_points = MAP.bt_dots(model.bt_devices if model.get("bt_devices") != null else [], vp, bar)
	host_nodes = MAP.map_layout(hosts, directions, vp, bar)

	_label("Vecindario", Vector2(16, bar + 10), 220)
	_label(MAP.CENTER_TITLE, center + Vector2(-90, 34), 180, Label.ALIGN_CENTER)
	_label(local_name(), center + Vector2(-90, 54), 180, Label.ALIGN_CENTER, TEXT_DIM)
	# "Este equipo" lleva el ícono del dispositivo local (mismo kind que publica).
	_make_icon(self, "np/" + DEVICE_ICONS.get(_local_device_kind(), "device-desktop"),
		center - Vector2(26, 26), 52.0)
	var wifi_text = MAP.wifi_label(networks)
	if wifi_text != "":
		_label(wifi_text, Vector2(16, bar + 34), 360, Label.ALIGN_LEFT, TEXT_DIM)
	for d in bt_points:
		var bc = Vector2(d.pos)
		_label(_bt_label(d), Vector2(bc.x - 70, bc.y + MAP.BT_ICON_SIZE * 0.5 + 3), 140,
			Label.ALIGN_CENTER, _bt_color(d))

	for node in host_nodes:
		var host = node.host
		var id = String(node.id)
		var c = Vector2(node.center)
		var size = float(node.size)
		_label(host_label(host), Vector2(c.x - 80, c.y + size * 0.5 + 4), 160, Label.ALIGN_CENTER)
		_make_icon(self, _host_icon(host), node.pos + Vector2(4, 4), size - 8.0)
		if id == selected_host:
			var session = _session_badge(id)
			if session != "":
				_label(session, Vector2(c.x - 110, c.y + size * 0.5 + 22), 220,
					Label.ALIGN_CENTER, HIGHLIGHT)

	if host_nodes.empty():
		var msg = MAP.empty_message(host_nodes.size(), _elapsed_ms())
		if msg != "":
			_label(msg, center + Vector2(-160, 92), 320, Label.ALIGN_CENTER, TEXT_DIM)

	if _menu_host != null:
		_build_menu_rows()
	# El menú vive en un nodo propio agregado al final: los íconos/etiquetas son
	# hijos nativos y se dibujan por encima del _draw del padre, así que el menú
	# debe ser el último hijo (raise()) para no quedar oculto.
	if _menu_layer == null or not is_instance_valid(_menu_layer):
		_menu_layer = preload("res://neighborhood_menu.gd").new()
		_menu_layer.name = "MenuLayer"
		_menu_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_menu_layer)
	_menu_layer.rect_size = vp
	_menu_layer.raise()
	_sync_menu()
	update()


# Vuelca el estado del menú (filas, rect, hover) a la capa que lo dibuja.
func _sync_menu():
	if _menu_layer == null or not is_instance_valid(_menu_layer):
		return
	_menu_layer.visible = _menu_host != null
	_menu_layer.title = "Wi-Fi" if _menu_is_wifi else ("Bluetooth" if _menu_is_bt else "Vecino")
	_menu_layer.rows = _menu_rows
	_menu_layer.rect = _menu_rect
	_menu_layer.hover = _menu_hover
	_menu_layer.update()


func _elapsed_ms():
	if _since_ms < 0:
		return 0
	return OS.get_ticks_msec() - _since_ms


func _bar():
	if shell != null and shell.has_method("frame_bar_h"):
		return float(shell.frame_bar_h(get_viewport_rect().size))
	return 64.0


# --- Entrada ---------------------------------------------------------------

func _ready():
	connect("visibility_changed", self, "_on_visibility_changed")


# Al abrir la vista se reinicia el mensaje de "Buscando…" y se cierra cualquier
# menú que hubiera quedado de la visita anterior.
func _on_visibility_changed():
	if not visible:
		return
	_since_ms = -1
	_close_menu()
	call_deferred("refresh", true)


func _gui_input(event):
	if event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event)


func _on_mouse_button(event):
	var pos = Vector2(event.position)
	if event.button_index == BUTTON_RIGHT and event.pressed:
		if _menu_host != null and _menu_rect.has_point(pos):
			return
		var wifi = MAP.hit_wifi(pos, wifi_points)
		if wifi != null:
			_open_wifi_menu(wifi, pos)
			accept_event()
			return
		var bt = MAP.hit_bt(pos, bt_points)
		if bt != null:
			_open_bt_menu(bt, pos)
			accept_event()
			return
		var node = MAP.hit_node(pos, host_nodes)
		if node != null:
			_open_menu(node.host, pos)
			accept_event()
		elif _menu_host != null:
			_close_menu()
			update()
		return
	if event.button_index != BUTTON_LEFT:
		return
	if _menu_host != null:
		if event.pressed and _menu_rect.has_point(pos):
			var row = _menu_row_at(pos)
			if row != null:
				_activate_row(row)
			accept_event()
			return
		if event.pressed:
			_close_menu()
			update()
			return
	if event.pressed:
		var wifi_hit = MAP.hit_wifi(pos, wifi_points)
		if wifi_hit != null:
			_open_wifi_menu(wifi_hit, pos)
			accept_event()
			update()
			return
		var bt_hit = MAP.hit_bt(pos, bt_points)
		if bt_hit != null:
			_open_bt_menu(bt_hit, pos)
			accept_event()
			update()
			return
		var hit = MAP.hit_node(pos, host_nodes)
		if hit != null:
			selected_host = String(hit.id)
			_drag_id = ""
		else:
			selected_host = ""
			_drag_id = ""
		update()
		call_deferred("refresh", true)
	else:
		_drag_id = ""
		_dragging = false
		update()


func _on_mouse_motion(event):
	if _menu_host != null and _menu_rect.has_point(Vector2(event.position)):
		var row = _menu_row_at(Vector2(event.position))
		var idx = _menu_rows.find(row) if row != null else -1
		if idx != _menu_hover:
			_menu_hover = idx
			update()
		return
	if _drag_id != "" and (int(event.button_mask) & BUTTON_LEFT) != 0:
		_drag_now = Vector2(event.position)
		if not _dragging and (_drag_now - _drag_from).length() > 8.0:
			_dragging = true
		update()


func _on_key(event):
	if event.scancode == KEY_ESCAPE and _menu_host != null:
		_close_menu()
		update()
		accept_event()
		return
	if _menu_host == null and selected_host != "" \
			and (event.scancode == KEY_ENTER or event.scancode == KEY_KP_ENTER or event.scancode == KEY_SPACE):
		var node = _node_by_id(selected_host)
		if node != null:
			_open_menu(node.host, Vector2(node.center) + Vector2(float(node.size) * 0.5, 0.0))
			accept_event()


# --- Imán de dirección ------------------------------------------------------

# Aplica una dirección confirmada. La fuente es host_directions (misma que usan
# Pantalla y Teclado y mouse); el shell la persiste y regenera el layout. Sin
# shell (headless/tests) sólo se actualiza el snapshot local.
func _apply_direction(host_id, direction):
	var id = String(host_id)
	if id == "":
		return
	var d = String(direction)
	if d == "none":
		directions.erase(id)
	else:
		directions[id] = _directions().sanitize_entry({
			"direction": d, "confirm": "confirmed", "mode": "extend"})
	if shell != null and shell.has_method("apply_deskflow_layout"):
		shell.apply_deskflow_layout(_layout_links_for(id, d))
	call_deferred("refresh", true)
	update()


# Links para el layout: el cambio más las direcciones ya confirmadas (con su
# nombre visible como peer). Determinista y sin I/O.
func _layout_links_for(changed_id, changed_dir):
	var links = []
	var ids = []
	if typeof(directions) == TYPE_DICTIONARY:
		ids = directions.keys()
	if not ids.has(String(changed_id)):
		ids.append(String(changed_id))
	for k in ids:
		var id = String(k)
		var dir = ""
		if id == String(changed_id):
			dir = String(changed_dir)
		else:
			var entry = directions.get(id, {})
			if typeof(entry) == TYPE_DICTIONARY and String(entry.get("confirm", "")) == "confirmed":
				dir = String(entry.get("direction", ""))
		if dir == "":
			continue
		if dir == "none":
			if id == String(changed_id):
				links.append({"direction": "none", "host": id})
			continue
		if not MAP.valid_direction(dir):
			continue
		links.append({"direction": dir, "host": id, "peer": MAP.safe_peer(_label_for_id(id))})
	return links


func _label_for_id(id):
	var host = _host_by_id(model.hosts if model != null else [], id)
	return host_label(host) if host != null else String(id)


# --- Menú contextual (clic derecho) ----------------------------------------

func _open_menu(host, at):
	if typeof(host) != TYPE_DICTIONARY:
		return
	selected_host = String(host.get("id", ""))
	_menu_host = host
	_menu_is_wifi = false
	_menu_wifi = null
	_menu_is_bt = false
	_menu_bt = null
	_menu_items = MAP.neighbor_menu(host, _host_actions(host), compass_direction(selected_host),
		MAP.debug_enabled(OS.get_environment("GDTK_DEBUG")))
	_menu_open_pos = Vector2(at)
	_menu_hover = -1
	_build_menu_rows()
	update()


# Menú de una red Wi-Fi (infraestructura, no presencia social): conectar /
# desconectar / encender la radio. La ejecución la hace el shell (nmcli/nmtui).
func _open_wifi_menu(w, at):
	if typeof(w) != TYPE_DICTIONARY:
		return
	_menu_is_wifi = true
	_menu_wifi = w
	_menu_is_bt = false
	_menu_bt = null
	_menu_host = {}  # no-null: hay menú abierto (los huéspedes del menú son de host)
	_menu_items = _wifi_menu_items(w)
	_menu_open_pos = Vector2(at)
	_menu_hover = -1
	_build_menu_rows()
	update()


func _wifi_menu_items(w):
	var ssid = String(w.get("ssid", "")).strip_edges()
	var in_use = bool(w.get("in_use", false))
	var out = []
	if ssid == "":
		return out
	out.append({"kind": "wifi_connect", "id": "wifi_connect",
		"label": "Conectar a " + ssid, "enabled": not in_use,
		"reason": "ya está conectada" if in_use else "",
		"ssid": ssid, "security": String(w.get("security", ""))})
	if in_use:
		out.append({"kind": "wifi_disconnect", "id": "wifi_disconnect",
			"label": "Desconectar", "enabled": true, "reason": "", "ssid": ssid})
	out.append({"kind": "separator"})
	out.append({"kind": "wifi_radio", "id": "wifi_radio",
		"label": "Encender Wi-Fi", "enabled": true, "reason": "", "ssid": ""})
	return out


# Menú de un dispositivo Bluetooth: conectar/desconectar, vincular/olvidar y buscar.
# La ejecución la hace el shell con bluetoothctl (nunca acá).
func _open_bt_menu(d, at):
	if typeof(d) != TYPE_DICTIONARY:
		return
	_menu_is_bt = true
	_menu_bt = d
	_menu_is_wifi = false
	_menu_wifi = null
	_menu_host = {}
	_menu_items = _bt_menu_items(d)
	_menu_open_pos = Vector2(at)
	_menu_hover = -1
	_build_menu_rows()
	update()


func _bt_menu_items(d):
	var addr = String(d.get("address", "")).strip_edges()
	var name = String(d.get("name", addr)).strip_edges()
	if name == "":
		name = addr
	var out = []
	if addr == "":
		return out
	if bool(d.get("connected", false)):
		out.append({"kind": "bt_disconnect", "id": "bt_disconnect", "label": "Desconectar " + name,
			"enabled": true, "reason": "", "address": addr})
	else:
		out.append({"kind": "bt_connect", "id": "bt_connect", "label": "Conectar " + name,
			"enabled": true, "reason": "", "address": addr})
	if bool(d.get("paired", false)):
		out.append({"kind": "bt_forget", "id": "bt_forget", "label": "Olvidar " + name,
			"enabled": true, "reason": "", "address": addr})
	else:
		out.append({"kind": "bt_pair", "id": "bt_pair", "label": "Vincular " + name,
			"enabled": true, "reason": "", "address": addr})
	out.append({"kind": "separator"})
	out.append({"kind": "bt_scan", "id": "bt_scan", "label": "Buscar dispositivos",
		"enabled": true, "reason": "", "address": ""})
	return out


func _close_menu():
	_menu_host = null
	_menu_is_wifi = false
	_menu_wifi = null
	_menu_is_bt = false
	_menu_bt = null
	_menu_items = []
	_menu_rows = []
	_menu_rect = Rect2()
	_menu_hover = -1


func _row_height(item):
	if String(item.get("kind", "")) == "separator":
		return MENU_SEP_H
	var h = MENU_ROW_H
	if String(item.get("reason", "")) != "":
		h += MENU_REASON_H
	return h


func _build_menu_rows():
	_menu_rows = []
	if _menu_host == null:
		return
	var vp = rect_size
	if vp.x <= 0.0 or vp.y <= 0.0:
		vp = Vector2(1280.0, 800.0)
	var total = MENU_TITLE_H + MENU_PAD * 2.0
	for item in _menu_items:
		total += _row_height(item)
	var x = clamp(_menu_open_pos.x, 0.0, max(0.0, vp.x - MENU_W))
	var y = clamp(_menu_open_pos.y, 0.0, max(0.0, vp.y - total))
	_menu_rect = Rect2(Vector2(x, y), Vector2(MENU_W, total))
	var ry = y + MENU_TITLE_H + MENU_PAD
	for item in _menu_items:
		var rh = _row_height(item)
		if String(item.get("kind", "")) == "separator":
			_menu_rows.append({"rect": Rect2(Vector2(x, ry), Vector2(MENU_W, rh)), "item": null})
		else:
			_menu_rows.append({"rect": Rect2(Vector2(x, ry), Vector2(MENU_W, MENU_ROW_H)), "item": item})
			if String(item.get("reason", "")) != "":
				_menu_rows.append({"rect": Rect2(Vector2(x, ry + MENU_ROW_H), Vector2(MENU_W, MENU_REASON_H)),
					"item": null, "reason": String(item.get("reason", ""))})
		ry += rh


func _menu_row_at(pos):
	for row in _menu_rows:
		var item = row.get("item", null)
		if item != null and Rect2(row.rect).has_point(pos):
			return row
	return null


func _activate_row(row):
	var item = row.get("item", null)
	if item == null or not bool(item.get("enabled", false)):
		return
	var kind = String(item.get("kind", ""))
	if _menu_is_bt:
		var addr = String(item.get("address", ""))
		if kind == "bt_connect" and shell != null and shell.has_method("_bt_connect"):
			shell._bt_connect(addr)
		elif kind == "bt_disconnect" and shell != null and shell.has_method("_bt_disconnect"):
			shell._bt_disconnect(addr)
		elif kind == "bt_pair" and shell != null and shell.has_method("_bt_pair"):
			shell._bt_pair(addr)
		elif kind == "bt_forget" and shell != null and shell.has_method("_bt_forget"):
			shell._bt_forget(addr)
		elif kind == "bt_scan" and shell != null and shell.has_method("_bt_scan"):
			shell._bt_scan()
		_close_menu()
		update()
		return
	if _menu_is_wifi:
		if kind == "wifi_connect":
			if shell != null and shell.has_method("_wifi_connect"):
				shell._wifi_connect(String(item.get("ssid", "")), String(item.get("security", "")))
		elif kind == "wifi_disconnect":
			if shell != null and shell.has_method("_wifi_disconnect"):
				shell._wifi_disconnect(String(item.get("ssid", "")))
		elif kind == "wifi_radio":
			if shell != null and shell.has_method("_wifi_radio_on"):
				shell._wifi_radio_on()
		_close_menu()
		update()
		return
	var host_id = String(_menu_host.get("id", ""))
	if kind == "action":
		_run_host_action(host_id, item.action)
	elif kind == "direction":
		_apply_direction(host_id, String(item.get("direction", "none")))
	_close_menu()
	update()


# --- Acciones (delegadas al shell; nunca ejecutan nada acá) ------------------

func _run_host_action(host_id, action):
	var label = String(action.get("label", ""))
	if not bool(action.get("enabled", false)):
		print("vecindario: ", host_id, " · ", label, " no disponible: ", String(action.get("reason", "")))
		return
	if shell != null and shell.has_method("_run_host_plan"):
		shell._run_host_plan(String(host_id), action)
		return
	var plan = action.get("plan", null)
	var cmd = ""
	if plan != null and _actions_script() != null:
		cmd = _actions_script().format_command(plan)
	if cmd == "":
		print("vecindario: ", host_id, " · ", label, " (acción sin comando)")
		return
	print("vecindario: ", host_id, " · ", label, " (sólo plan, no se ejecuta): ", cmd)


# --- Contexto y acciones puras (API conservada) ------------------------------

func _host_actions(host):
	var script = _actions_script()
	if script == null:
		return []
	var ctx = _local_context()
	var id = String(host.get("id", ""))
	var entry = directions.get(id, null)
	if typeof(entry) == TYPE_DICTIONARY:
		var d = compass_direction(id)
		if d != "none":
			ctx.direction = d
			ctx.direction_confirm = String(entry.get("confirm", "unconfirmed"))
	if _in_conflict(id):
		ctx.direction_conflict = true
	# Emisor gdtk habilitado (GVD_SESSION.EMITTER_ENABLED): con gvd local resuelto y
	# un host confiable se ofrece también "Extender mi escritorio a él".
	if String(ctx.get("gvd_path", "")) != "" and not bool(host.get("degraded", false)):
		ctx.gvd_sender = true
	# Canal autorizado (ssh/buzón) hacia este host: habilita las acciones de
	# pantalla cuando el peer anuncia state=capable (abre su receptor on-demand).
	# Se resuelve del propio host (misma dirección que usará el emisor por ssh).
	ctx.provision_channel = bool(INBOX.ssh_target(host).get("ok", false))
	# Servidor local disponible resuelto una vez por el shell (cached, sin escanear
	# PATH por frame). Sin shell (headless) no se toca el contexto.
	if shell != null and shell.has_method("deskflow_server_available"):
		ctx.deskflow_server = shell.deskflow_server_available()
	return script.host_actions(host, ctx)


func _actions_script():
	if _actions == null:
		_actions = load("res://neighborhood_actions.gd").new()
	return _actions


# Contexto local mínimo: HOME y la ruta del receptor de pantalla resuelta por
# candidatos sólo si el archivo existe. Sin nada ejecutable, las acciones quedan
# deshabilitadas. La lectura ocurre en el clic, nunca en refresh()/_draw().
func _local_context():
	var home = OS.get_environment("HOME")
	var ctx = {"home": home, "local_name": local_name()}
	var script = _actions_script()
	if script == null:
		return ctx
	var candidates = script.gvd_path_candidates(home, OS.get_environment("GDTK_HOME"))
	var exists = {}
	var f = File.new()
	for c in candidates:
		var p = String(c)
		if p.begins_with("/") and f.file_exists(p):
			exists[p] = true
	var resolved = script.resolve_gvd_path(candidates, exists)
	if resolved != "":
		ctx.gvd_path = resolved
	return ctx


func local_name():
	if shell != null and shell.has_method("_local_hostname"):
		var h = String(shell._local_hostname()).strip_edges()
		if h != "":
			return h
	var env = OS.get_environment("HOSTNAME").strip_edges()
	return env if env != "" else "gdtk-local"


func _host_by_id(hosts, id):
	if id == "":
		return null
	for h in hosts:
		if String(h.get("id", "")) == id:
			return h
	return null


func _node_by_id(id):
	for node in host_nodes:
		if String(node.id) == String(id):
			return node
	return null


# --- Compás de dirección por host (SPEC-screen-share-compass) ----------------
# Estado puro sobre `directions`/`direction_conflicts`; el shell (worker) los
# puebla. Ningún helper consulta red, procesos ni disco.

func _directions():
	if _directions_model == null:
		_directions_model = load("res://neighborhood_directions.gd").new()
	return _directions_model


func compass_direction(host_id):
	var id = String(host_id)
	if not directions.has(id):
		return "none"
	var entry = directions[id]
	if typeof(entry) != TYPE_DICTIONARY:
		return "none"
	var d = String(entry.get("direction", "none")).strip_edges()
	if not _directions().valid_direction(d) or d == "none":
		return "none"
	return d


func _in_conflict(host_id):
	if typeof(direction_conflicts) != TYPE_ARRAY:
		return false
	for c in direction_conflicts:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var hids = c.get("hids", [])
		if typeof(hids) == TYPE_ARRAY and hids.has(host_id):
			return true
	return false


func compass_state(host_id):
	var id = String(host_id)
	if _in_conflict(id):
		return "conflicto"
	if compass_direction(id) == "none":
		return "sin_direccion"
	if String(directions[id].get("confirm", "unconfirmed")).strip_edges() == "confirmed":
		return "confirmada"
	return "propuesta"


# Badge corto (API conservada; la UI usa direction_status_text para español).
func compass_badge(host_id):
	match compass_state(host_id):
		"conflicto":
			return "conflicto"
		"sin_direccion":
			return "sin dirección"
		"confirmada":
			return "confirmada: " + compass_direction(host_id)
		_:
			return "propuesta: " + compass_direction(host_id)


func host_session_state(host_id):
	if shell != null and shell.has_method("_host_session_state"):
		return String(shell._host_session_state(String(host_id)))
	return "idle"


func _session_badge(host_id):
	match host_session_state(host_id):
		"active":
			return "sesión: activa"
		"starting":
			return "sesión: iniciando"
		_:
			return ""


# Propuesta de dirección (sin confirmar): conserva la API usada por el modelo de
# direcciones. El menú del mapa usa _apply_direction (confirmada) para colocar.
func _select_direction(host_id, dir):
	var id = String(host_id)
	var d = String(dir)
	if d == "none":
		directions.erase(id)
	else:
		directions[id] = {"direction": d, "confirm": "unconfirmed"}
	if shell != null and shell.has_method("_set_host_direction"):
		shell._set_host_direction(id, dir)
	call_deferred("refresh", true)


# --- Tooltip / nombre / ícono (helpers de UI) --------------------------------

func _host_tooltip(host):
	var lines = [host_label(host)]
	var state = String(host.get("state", "")).strip_edges()
	var human = _human_state(state)
	if human != "":
		lines.append("estado: " + human)
	var badge = _session_badge(String(host.get("id", "")))
	if badge != "":
		lines.append(badge)
	if MAP.debug_enabled(OS.get_environment("GDTK_DEBUG")):
		lines.append("tipo: " + String(host.get("kind", "")))
		lines.append("id: " + String(host.get("id", "")))
	return PoolStringArray(lines).join("\n")


func _human_state(state):
	match String(state):
		"visto":
			return "a la vista"
		"perdido":
			return "fuera de alcance"
		"guardado":
			return "conocido"
	return String(state)


# Icono de un host: primero el ícono nuevo por `kind` (desktop/laptop/tablet/
# mobile/tv), que es lo que distingue a un par de otro; si no, el `icon` publicado
# y, por último, el ícono de red del repo. Cachea por nombre para no repetir I/O.
func _host_icon(host):
	var d = host if typeof(host) == TYPE_DICTIONARY else {}
	var kind = String(d.get("kind", ""))
	var name = String(d.get("icon", ""))
	var cache_key = "kind:" + kind + "|icon:" + name
	if _icon_cache.has(cache_key):
		return String(_icon_cache[cache_key])
	var f = File.new()
	var candidates = []
	if DEVICE_ICONS.has(kind):
		candidates.append("np/" + DEVICE_ICONS[kind])
	if name != "":
		candidates.append(name)
		candidates.append("sugar/" + name)
	candidates.append_array(HOST_FALLBACK_ICONS)
	var resolved = "sugar/computer-xo"
	for n in candidates:
		if f.file_exists("res://icons/" + n + ".svg") or f.file_exists("res://icons/" + n + ".png"):
			resolved = n
			break
	_icon_cache[cache_key] = resolved
	return resolved


# Tipo del equipo local: lo resuelve el shell (mismo que publica el Vecindario);
# sin shell (tests) cae a "unknown". El centro del mapa muestra este dispositivo.
func _local_device_kind():
	if shell != null and shell.has_method("local_device_kind"):
		return String(shell.local_device_kind())
	return "unknown"


# Nombre corto del host: prefiere el `name` del servicio (lo que el vecino se
# llama a sí mismo) antes que el label o el id opaco. Puro.
func host_label(host):
	if typeof(host) != TYPE_DICTIONARY:
		return ""
	var caps = host.get("capabilities", {})
	if typeof(caps) == TYPE_DICTIONARY:
		for cap in caps.values():
			if typeof(cap) != TYPE_DICTIONARY:
				continue
			var txt = cap.get("txt", {})
			if typeof(txt) != TYPE_DICTIONARY:
				continue
			var name = String(txt.get("name", "")).strip_edges()
			if name != "":
				return name
	var label = String(host.get("label", "")).strip_edges()
	if label != "":
		return label
	return String(host.get("id", ""))


func _host_initial(label):
	var s = String(label).strip_edges()
	if s == "":
		return "?"
	return s.substr(0, 1).to_upper()


# --- Dibujo ------------------------------------------------------------------

func _draw():
	draw_rect(Rect2(Vector2.ZERO, rect_size), BG)
	var bar = _bar()
	var radii = MAP.map_radii(rect_size, bar)
	for r in [radii.inner, radii.mid, radii.outer]:
		draw_arc(center, float(r), 0.0, TAU, 96, RING_MID if r == radii.mid else RING, 1.0)
	for dot in wifi_points:
		var active = bool(dot.in_use)
		# AP con la antena clásica de Sugar (no el router genérico): mástil, bola y
		# ondas. Sigue siendo infraestructura, no presencia social.
		_draw_ap(Vector2(dot.pos), MAP.WIFI_ICON_SIZE * 0.5 + (2.0 if active else 0.0), active)
	_draw_center_plate()
	for node in host_nodes:
		if _dragging and String(node.id) == _drag_id:
			continue
		_draw_node(node, Vector2(node.center), float(node.size))
	# Bluetooth: se dibuja al final para quedar por encima del equipo central.
	for d in bt_points:
		_draw_bt_icon(Vector2(d.pos), MAP.BT_ICON_SIZE * 0.5, d)
	if _dragging:
		var drag_node = _node_by_id(_drag_id)
		if drag_node != null:
			var dir = MAP.drag_direction(_drag_from, _drag_now)
			if dir != "":
				var target = MAP.directional_center(dir, 0, 1, center, float(radii.mid))
				draw_arc(target, 22.0, 0.0, TAU, 32, NODE_SEL, 2.0)
			_draw_node(drag_node, _drag_now, float(drag_node.size))
	# El menú lo dibuja _menu_layer (nodo propio, por encima); acá sólo se sincroniza.
	_sync_menu()


# Antena clásica de Sugar para el AP de Wi-Fi: base, mástil, bola y ondas. Se
# dibuja vectorial (sin PNG) para que escale y siga el color de estado.
func _draw_ap(c, r, active):
	var col = WIFI_DOT_ACTIVE if active else WIFI_DOT
	var thick = max(1.5, r * 0.16)
	var top = Vector2(c.x, c.y)
	var base_y = c.y + r * 0.80
	draw_line(Vector2(c.x - r * 0.55, base_y), Vector2(c.x + r * 0.55, base_y), col, thick, true)
	draw_line(Vector2(c.x, base_y), top, col, thick, true)
	draw_circle(top, thick * 1.35, col)
	for i in range(3):
		var ar = r * (0.42 + 0.30 * float(i))
		draw_arc(top, ar, -PI * 0.78, -PI * 0.22, 18, col, thick, true)


# Color por estado del dispositivo Bluetooth.
func _bt_color(d):
	if bool(d.get("connected", false)):
		return BT_DOT_CONNECTED
	if bool(d.get("paired", false)):
		return BT_DOT_PAIRED
	return BT_DOT_KNOWN


func _bt_label(d):
	var n = String(d.get("name", "")).strip_edges()
	return n if n != "" else String(d.get("address", ""))


# Dispositivo Bluetooth: placa chica con el runa de Bluetooth; verde si está
# conectado (con halo), claro si está vinculado, tenue si sólo es conocido.
func _draw_bt_icon(c, r, d):
	var col = _bt_color(d)
	if bool(d.get("connected", false)):
		draw_circle(c, r * 1.28, Color(col.r, col.g, col.b, 0.18))
	draw_circle(c, r, NODE_BG)
	draw_arc(c, r, 0.0, TAU, 32, col, 1.5)
	_draw_bt_glyph(c, r * 0.62, col, max(1.4, r * 0.16))


# Runa de Bluetooth: mástil vertical y dos diagonales (triángulos espejados).
func _draw_bt_glyph(c, r, col, w):
	var top = c + Vector2(0.0, -r)
	var bot = c + Vector2(0.0, r)
	draw_line(top, bot, col, w, true)
	var a = PoolVector2Array([top, c + Vector2(0.62 * r, -0.36 * r),
		c + Vector2(-0.62 * r, 0.36 * r), bot])
	var b = PoolVector2Array([bot, c + Vector2(0.62 * r, 0.36 * r),
		c + Vector2(-0.62 * r, -0.36 * r), top])
	draw_polyline(a, col, w, true)
	draw_polyline(b, col, w, true)


func _draw_center_plate():
	# Placa del equipo local: el ícono del dispositivo lo dibuja refresh() encima.
	draw_circle(center, 28.0, CENTER_PLATE)
	draw_arc(center, 28.0, 0.0, TAU, 48, NODE_RING, 2.0)


func _draw_node(node, c, size):
	var r = size * 0.5
	var bg = NODE_BG
	var ring = NODE_RING
	if bool(node.dimmed):
		bg = Color(bg.r, bg.g, bg.b, NODE_DIM_ALPHA)
		ring = Color(ring.r, ring.g, ring.b, NODE_DIM_ALPHA)
	if String(node.id) == selected_host:
		ring = NODE_SEL
	draw_circle(c, r, bg)
	draw_arc(c, r, 0.0, TAU, 48, ring, 2.0)
	if String(node.id) == selected_host:
		draw_arc(c, r + 4.0, 0.0, TAU, 48, NODE_SEL, 2.0)


func _bevel(rect, face, light, dark, b):
	draw_rect(rect, face)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, b)), light)
	draw_rect(Rect2(rect.position, Vector2(b, rect.size.y)), light)
	draw_rect(Rect2(Vector2(rect.position.x, rect.end.y - b), Vector2(rect.size.x, b)), dark)
	draw_rect(Rect2(Vector2(rect.end.x - b, rect.position.y), Vector2(b, rect.size.y)), dark)


# --- Nodos nativos auxiliares ------------------------------------------------

func _label(caption, pos, width, align = Label.ALIGN_LEFT, color = TEXT):
	var label = Label.new()
	label.text = caption
	label.rect_position = pos
	label.rect_size = Vector2(width, 22)
	label.clip_text = true
	label.align = align
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_color_override("font_color", color)
	add_child(label)


# Carga (y cachea) un PNG o SVG de res://icons/ como ImageTexture. Devuelve null si
# no existe. Soporta los íconos nuevos (np/*.png) además de los SVG del repo.
func _icon_texture(name):
	var key = String(name)
	if _tex_cache.has(key):
		return _tex_cache[key]
	var f = File.new()
	var path = ""
	if f.file_exists("res://icons/" + key + ".png"):
		path = "res://icons/" + key + ".png"
	elif f.file_exists("res://icons/" + key + ".svg"):
		path = "res://icons/" + key + ".svg"
	else:
		_tex_cache[key] = null
		return null
	var image = Image.new()
	if image.load(path) != OK or image.get_width() == 0:
		_tex_cache[key] = null
		return null
	var texture = ImageTexture.new()
	texture.create_from_image(image, Texture.FLAG_FILTER)
	_tex_cache[key] = texture
	return texture


func _make_icon(parent, name, pos, size):
	var png = "res://icons/" + String(name) + ".png"
	if File.new().file_exists(png):
		var texture = _icon_texture(String(name))
		if texture == null:
			return
		var tex_rect = TextureRect.new()
		tex_rect.texture = texture
		tex_rect.expand = true
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex_rect.rect_position = pos
		tex_rect.rect_size = Vector2(size, size)
		parent.add_child(tex_rect)
		return
	var path = "res://icons/" + name + ".svg"
	if ClassDB.class_exists("SlugVector2D") and ClassDB.class_exists("SlugVector"):
		var vector = ClassDB.instance("SlugVector")
		vector.set_svg_path(path)
		if vector.is_valid():
			var icon = ClassDB.instance("SlugVector2D")
			icon.set_vector(vector)
			icon.set_size(size)
			icon.set_centered(false)
			parent.add_child(icon)
			icon.position = pos
			if icon is Control:
				icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return
	var image = Image.new()
	if image.load(path) != OK:
		return
	var texture = ImageTexture.new()
	texture.create_from_image(image, Texture.FLAG_FILTER)
	var icon = TextureRect.new()
	icon.texture = texture
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.rect_position = pos
	icon.rect_size = Vector2(size, size)
	parent.add_child(icon)
