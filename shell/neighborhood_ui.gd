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
const HOTSPOT = preload("res://neighborhood_hotspot.gd")  # modelo puro de la señal Wi-Fi
# group_model cambia junto con esta vista durante el pulido. Cargarlo desde texto
# evita que una recarga transaccional conserve la versión cacheada por preload.
var GROUP = Host.sc("res://group_model.gd") if Host != null else load("res://group_model.gd")   # sin autoload (tests)
const MENU = preload("res://menu_style.gd")
const SHARED = preload("res://shared_block.gd")
const SL = preload("res://screen_layout.gd")
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

const HOST_FALLBACK_ICONS = ["np/device-desktop", "sugar/network-wired", "network-connected"]

var shell = null
var model = null
# G3: interfaz para que otro agente traiga la vista Grupo en esta misma Control.
# mode = "neighborhood" | "group"; draw_center controla la placa central.
var mode = "neighborhood"
var draw_center = true
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
var _menu_title = ""         # título propio del menú (Grupo); "" = según el tipo
var _menu_is_group = false   # true = popup de un miembro del Grupo
var _menu_group_member = null
var _menu_is_self = false    # true = menú de «Este equipo» (señal Wi-Fi)

# Vista Grupo (mode == "group"): fichas y layout puros de group_model.gd.
var _group_members = []
var _group_layout = {}
var _since_ms = -1


# G3: cambia el modo de la vista ("neighborhood" | "group") y refresca. La vista
# Grupo la implementa otro agente sobre esta misma Control.
func set_mode(m):
	mode = String(m)
	refresh(true)


func refresh(force = false):
	if model == null:
		return
	var vp = shell._screen_size() if shell != null else get_viewport_rect().size
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
	bt_points = []
	var bar = _bar()
	if mode == "group":
		_refresh_group(vp, bar)
	else:
		_refresh_neighborhood(vp, bar)
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


func _refresh_neighborhood(vp, bar):
	var networks = model.networks if model.get("networks") != null else []
	var hosts = model.hosts if model.get("hosts") != null else []
	var radii = MAP.map_radii(vp, bar)
	center = vp * 0.5
	radius = radii.outer
	wifi_points = MAP.wifi_dots(networks, vp, bar)
	# El Bluetooth es cosa del Grupo (sólo lo que está al alcance): el Vecindario no lo muestra.
	bt_points = []
	host_nodes = MAP.map_layout(hosts, directions, vp, bar)
	_spread_map(vp, bar)

	_label("Vecindario", Vector2(16, bar + 10), 220)
	_label(MAP.CENTER_TITLE, center + Vector2(-90, 34), 180, Label.ALIGN_CENTER)
	_label(local_name(), center + Vector2(-90, 54), 180, Label.ALIGN_CENTER, TEXT_DIM)
	# "Este equipo" lleva el ícono del dispositivo local (mismo kind que publica).
	_make_icon(self, "np/" + DEVICE_ICONS.get(_local_device_kind(), "device-desktop"),
		center - Vector2(26, 26), 52.0)
	var wifi_text = MAP.wifi_label(networks)
	if wifi_text != "":
		_label(wifi_text, Vector2(16, bar + 34), 360, Label.ALIGN_LEFT, TEXT_DIM)

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


# --- Vista Grupo ------------------------------------------------------------
# Sólo los miembros del Grupo (equipos conocidos/pareados + Bluetooth pareados):
# el centro es el ancla y cada equipo se pega a su lado; los sin ubicar van en un
# arco inferior y los BT pareados en una banda al pie. Las posiciones salen del
# modelo puro group_model.group_layout; acá sólo se dibuja y se delega al shell.

func _refresh_group(vp, bar):
	var hosts = model.hosts if model.get("hosts") != null else []
	var bts = model.bt_devices if model.get("bt_devices") != null else []
	_group_members = GROUP.members(directions, _group_token_keys(), _group_screens(), hosts, bts)
	_group_layout = GROUP.group_layout(_group_members, vp, bar)
	center = Vector2(_group_layout.get("center", vp * 0.5))
	radius = 0.0
	var nodes = []
	var idx = 0
	for n in _group_layout.get("nodes", []):
		var host = n.get("member", {}).get("host", {})
		nodes.append({
			"id": String(n.get("id", "")), "host": host if typeof(host) == TYPE_DICTIONARY else {},
			"member": n.get("member", {}), "center": Vector2(n.get("center", Vector2.ZERO)),
			"pos": Vector2(n.get("pos", Vector2.ZERO)), "size": float(n.get("size", GROUP.NODE_SIZE)),
			"direction": String(n.get("direction", "")), "angle": float(n.get("angle", -1.0)), "dimmed": bool(n.get("dimmed", false)),
			"index": idx,
		})
		idx += 1
	host_nodes = nodes
	bt_points = []
	for b in _group_layout.get("bt", []):
		bt_points.append({
			"pos": Vector2(b.get("center", Vector2.ZERO)), "address": String(b.get("id", "")),
			"name": String(b.get("name", "")), "connected": bool(b.get("connected", false)),
			"paired": true, "rssi": int(b.get("rssi", 0)), "size": float(b.get("size", GROUP.BT_SIZE)),
		})

	_label("Grupo", Vector2(16, bar + 10), 220)
	var mesh_status = _mesh_status_text()
	if mesh_status != "":
		_label(mesh_status, Vector2(16, bar + 30), 460, Label.ALIGN_LEFT, TEXT_DIM)
	var ch = float(_group_layout.get("center_size", GROUP.CENTER_SIZE)) * 0.5
	_label(MAP.CENTER_TITLE, center + Vector2(-90, ch + 8), 180, Label.ALIGN_CENTER)
	_label(local_name(), center + Vector2(-90, ch + 28), 180, Label.ALIGN_CENTER, TEXT_DIM)

	for node in nodes:
		var m = node.member
		var c = Vector2(node.center)
		var size = float(node.size)
		var col = TEXT_DIM if bool(node.dimmed) else TEXT
		_label(String(m.get("name", "")), Vector2(c.x - 80, c.y + size * 0.5 + 4), 160,
			Label.ALIGN_CENTER, col)
		if bool(node.dimmed):
			_label("apagado", Vector2(c.x - 80, c.y + size * 0.5 + 24), 160,
				Label.ALIGN_CENTER, TEXT_DIM)
		elif String(node.host.get("mesh", "")).strip_edges() != "":
			_label("red propia", Vector2(c.x - 80, c.y + size * 0.5 + 24), 160,
				Label.ALIGN_CENTER, LINK_OK)
		_make_icon(self, _host_icon(node.host), Vector2(node.pos) + Vector2(4, 4), size - 8.0)

	if not _group_layout.get("unplaced", []).empty():
		_label("Sin ubicar", Vector2(_group_layout.get("unplaced_label", Vector2.ZERO)),
			200, Label.ALIGN_LEFT, TEXT_DIM)

	for d in bt_points:
		var bc = Vector2(d.pos)
		_label(_bt_label(d), Vector2(bc.x - 70, bc.y + float(d.size) * 0.5 + 3), 140,
			Label.ALIGN_CENTER, _bt_color(d))


# Estado del mesh para la vista Grupo: "hospedando" si este equipo es el servidor
# Deskflow del Grupo; si no, avisa si un vecino ofrece "red propia". "" si nada.
func _mesh_status_text():
	if shell != null and shell.has_method("_mesh_is_host") and bool(shell._mesh_is_host()):
		return "Red propia del Grupo (mesh): activa"
	var hosts = model.hosts if model.get("hosts") != null else []
	for h in hosts:
		if typeof(h) != TYPE_DICTIONARY:
			continue
		var m = String(h.get("mesh", "")).strip_edges()
		if m != "":
			return "Red propia disponible en " + String(h.get("label", m))
	return ""


# Claves de los tokens por-par, sin leer jamás el valor del token: el shell lista
# sólo los hid con token; sin ese getter no se inventa pertenencia.
func _group_token_keys():
	var out = {}
	if shell == null or not shell.has_method("_peer_token_hids"):
		return out
	var hids = shell._peer_token_hids()
	if typeof(hids) == TYPE_ARRAY:
		for h in hids:
			var hid = String(h).strip_edges()
			if hid != "":
				out["cli:" + hid] = ""
	elif typeof(hids) == TYPE_DICTIONARY:
		for k in hids.keys():
			out[String(k)] = ""
	return out


# Pantallas configuradas (settings["screens"]["screens"]), ya leídas por el shell.
func _group_screens():
	if shell == null:
		return []
	var bridge = shell.get("settings_bridge")
	if bridge == null:
		return []
	var settings = bridge.get("settings")
	if typeof(settings) != TYPE_DICTIONARY:
		return []
	var stored = settings.get("screens", {})
	if typeof(stored) == TYPE_DICTIONARY:
		var arr = stored.get("screens", [])
		return arr if typeof(arr) == TYPE_ARRAY else []
	return stored if typeof(stored) == TYPE_ARRAY else []


# Conjunto de ids/hid/nombres de los miembros actuales (sin secretos).
func _group_member_set():
	var out = {}
	if typeof(_group_members) != TYPE_ARRAY:
		return out
	for m in _group_members:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var id = String(m.get("id", "")).strip_edges()
		if id != "":
			out[id] = true
		var nm = String(m.get("name", "")).strip_edges()
		if nm != "":
			out[nm.to_lower()] = true
	return out


func _group_member_by_id(id):
	for m in _group_members:
		if typeof(m) == TYPE_DICTIONARY and String(m.get("id", "")) == String(id):
			return m
	return null


# Ficha de miembro para el submenú de un nodo: en el Grupo viene del modelo; en el
# Vecindario sólo si el host es un par (ubicado y confirmado, o con token de pareo).
# null => no es par (sólo se selecciona). La lectura de tokens ocurre en el clic.
func _peer_member(node):
	var id = String(node.id)
	if mode == "group" and node.get("member", null) != null:
		return node.member
	var host = node.host if typeof(node.host) == TYPE_DICTIONARY else {}
	var hid = String(host.get("hid", id))
	var entry = directions.get(id, directions.get(hid, null))
	var d = compass_direction(id)
	var paired = mode == "group" or (typeof(entry) == TYPE_DICTIONARY \
		and String(entry.get("confirm", "")) == "confirmed")
	if not paired:
		var keys = _group_token_keys()
		paired = keys.has("cli:" + hid) or keys.has("srv:" + hid) \
			or keys.has("cli:" + id) or keys.has("srv:" + id)
	if not paired:
		return null
	return {"id": id, "name": host_label(host), "online": true, "kind": "host",
		"direction": "" if d == "none" else d, "host": host}


func _group_title(member):
	if typeof(member) != TYPE_DICTIONARY:
		return "Equipo"
	var nm = String(member.get("name", "")).strip_edges()
	if nm == "":
		nm = String(member.get("id", ""))
	var d = String(member.get("direction", ""))
	if MAP.valid_direction(d):
		return nm + " — al " + MAP.direction_label(d).to_lower()
	return nm


# Punto del anillo del Grupo en el ángulo de `pos` respecto del ícono local: el ángulo
# manda, la distancia no (marca de destino mientras se arrastra).
func _group_ring_point(pos):
	var half = Vector2(_group_layout.get("ring", GROUP.ring_half(rect_size, _bar())))
	var d = Vector2(pos) - center
	if d.length() < 1.0:
		return center
	return center + SL.edge_point(rad2deg(d.angle()), half)


# Posición soltada -> {side, offset} con el anillo de esta vista como rectángulo de
# referencia; {} si cae sobre el equipo local (no hay ángulo).
func _group_placement_at(pos):
	var half = Vector2(_group_layout.get("ring", GROUP.ring_half(rect_size, _bar())))
	var d = Vector2(pos) - center
	if d.length() < float(_group_layout.get("center_size", GROUP.CENTER_SIZE)) * 0.5:
		return {}
	return SL.placement_from_angle(rad2deg(d.angle()), half)


# Menú del Grupo: dos interruptores (extender pantalla, compartir teclado y
# mouse) con su estado; el clic derecho agrega "Quitar del grupo". Offline o sin
# ubicar => filas deshabilitadas con la razón.
func _open_group_menu(member, at, include_remove):
	if typeof(member) != TYPE_DICTIONARY:
		return
	_menu_is_wifi = false
	_menu_wifi = null
	_menu_is_bt = false
	_menu_bt = null
	_menu_is_group = true
	_menu_group_member = member
	_menu_is_self = false
	var host = member.get("host", {})
	if typeof(host) != TYPE_DICTIONARY or host.empty():
		host = {"id": String(member.get("id", "")), "label": String(member.get("name", ""))}
	_menu_host = host
	selected_host = String(member.get("id", ""))
	_menu_items = _group_toggle_items(member, include_remove)
	_menu_title = _group_title(member)
	_menu_open_pos = Vector2(at)
	_menu_hover = -1
	_build_menu_rows()
	update()


func _group_toggle_items(member, include_remove):
	var id = String(member.get("id", ""))
	var online = bool(member.get("online", false))
	var direction = String(member.get("direction", ""))
	var host = member.get("host", {})
	if typeof(host) != TYPE_DICTIONARY or host.empty():
		host = {"id": id, "label": String(member.get("name", ""))}
	var extend = _group_action(host, "share_my_screen")
	var keyboard = _group_action(host, "serve_input_here")
	var rows = []
	rows.append(_group_toggle_row("group_extend", "Extender mi pantalla", id, extend,
		online, direction, _shell_bool("_group_screen_on", id)))
	rows.append(_group_toggle_row("group_keyboard", "Compartir teclado y mouse", id, keyboard,
		online, direction, _shell_bool("_group_input_on", id)))
	# Audio: como extender, pero sin lado (no es espacial); basta con que esté encendido.
	var audio_on = _shell_bool("_group_audio_on", id)
	rows.append({"kind": "group_audio", "id": "group_audio", "member_id": id,
		"label": "Enviar audio — " + ("Encendido" if audio_on else "Apagado"),
		"enabled": online or audio_on, "reason": "" if online or audio_on else "está apagado",
		"is_on": audio_on})
	if include_remove:
		rows.append({"kind": "separator"})
		if _group_member_by_id(id) != null:
			rows.append({"kind": "group_remove", "id": "group_remove", "label": "Quitar del grupo",
				"enabled": true, "reason": "", "member_id": id})
		else:
			rows.append({"kind": "group_add", "id": "group_add", "label": "Añadir a mi grupo",
				"enabled": true, "reason": "", "member_id": id})
	return rows


# Destino de un bloque del Frame (ventana, Audio) soltado sobre el Grupo, en coords
# globales: {kind: "self"} sobre el ícono central, {kind: "member", id, online, name}
# sobre un equipo del Grupo, {} en otro lado o fuera de la vista Grupo.
func group_drop_target(global_pos):
	if mode != "group" or not is_visible_in_tree():
		return {}
	var pos = Vector2(global_pos) - rect_global_position
	if (pos - center).length() < float(_group_layout.get("center_size", GROUP.CENTER_SIZE)) * 0.5:
		return {"kind": "self"}
	var node = MAP.hit_node(pos, host_nodes)
	var gm = _peer_member(node) if node != null else null
	if gm == null:
		return {}
	return {"kind": "member", "id": String(gm.get("id", "")), "online": bool(gm.get("online", false)),
		"name": String(gm.get("name", ""))}


func _shell_bool(method, arg):
	return shell != null and shell.has_method(method) and bool(shell.call(method, String(arg)))


func _group_toggle_row(kind, label, member_id, action, online, direction, on):
	var enabled = false
	var reason = ""
	if not bool(online):
		reason = "está apagado"
	elif String(direction) == "":
		reason = "falta ubicarlo"
	elif on:
		enabled = true
	elif action == null:
		reason = "no disponible en este equipo"
	elif not bool(action.get("enabled", false)):
		reason = MAP.human_reason(action)
		if reason == "":
			reason = "no disponible en este equipo"
	else:
		enabled = true
	var text = String(label) + " — " + ("Encendido" if on else "Apagado")
	return {"kind": kind, "id": kind, "label": text, "enabled": enabled, "reason": reason,
		"action": action, "member_id": String(member_id), "is_on": bool(on)}


# Acción del módulo puro para este host, forzando la dirección recién puesta como
# confirmada (el arrastre ES la confirmación en el Grupo).
func _group_action(host, action_id):
	var actions = _host_actions(host, "confirmed")
	for a in actions:
		if String(a.get("id", "")) == String(action_id):
			return a
	return null


func _activate_group_row(item):
	var kind = String(item.get("kind", ""))
	var id = String(item.get("member_id", ""))
	if kind == "group_remove":
		_group_remove(id)
		return
	if kind == "group_add":
		_group_add(id)
		return
	if kind == "group_audio":
		if shell != null and shell.has_method("_group_audio_set"):
			shell._group_audio_set(id, not bool(item.get("is_on", false)))
		call_deferred("refresh", true)
		return
	var action = item.get("action", null)
	if kind == "group_extend":
		if shell != null and shell.has_method("_group_screen_set"):
			shell._group_screen_set(id, not bool(item.get("is_on", false)), action)
		call_deferred("refresh", true)
		return
	if kind == "group_keyboard" and not bool(item.get("is_on", false)):
		_group_keyboard(id, true)
		return
	if not bool(item.get("is_on", false)):
		if action != null:
			_run_host_action(id, action)
		return
	if kind == "group_keyboard":
		_group_keyboard(id, false)


# Soltar en cualquier ángulo SÓLO acomoda: el lado y la posición sobre el borde se
# guardan (host_directions + "along") y alimentan Configuración > Pantallas.
func _apply_group_placement(host_id, side, along):
	var id = String(host_id)
	var d = String(side)
	if id == "" or not MAP.valid_direction(d) or d == "none":
		return
	directions[id] = _directions().sanitize_entry({"direction": d, "along": along,
		"confirm": "confirmed", "mode": "extend"})
	if shell != null and shell.has_method("_set_host_placement"):
		shell._set_host_placement(id, d, float(along))
	elif shell != null and shell.has_method("_set_host_direction"):
		shell._set_host_direction(id, d)
	call_deferred("refresh", true)
	update()


func _group_add(host_id):
	var id = String(host_id)
	if id == "":
		return
	if shell != null and shell.has_method("_group_add"):
		shell._group_add(id)
	else:
		directions = GROUP.add_member(directions, id)
	call_deferred("refresh", true)


func _group_remove(host_id):
	var id = String(host_id)
	if id == "":
		return
	if shell != null and shell.has_method("_group_remove"):
		shell._group_remove(id)
	else:
		directions = GROUP.remove_member(directions, id)
		if shell != null and shell.has_method("_set_host_direction"):
			shell._set_host_direction(id, "none")
	selected_host = ""
	call_deferred("refresh", true)


func _stop_group_extend(host_id):
	if shell != null and shell.has_method("_stop_gvd_screen"):
		shell._stop_gvd_screen(String(host_id))


func _group_keyboard(host_id, on):
	if shell != null and shell.has_method("_group_input_set"):
		shell._group_input_set(String(host_id), bool(on))
	call_deferred("refresh", true)


# G3: pasada final anti-solape. Reúne hosts, Wi-Fi y Bluetooth como cápsulas
# (centro + tamaño de ícono + rótulo truncado) y reescribe sus centros con
# spread_all, de modo que ningún par se pise y todos queden dentro de la vista.
func _spread_map(vp, bar):
	var items = []
	for node in host_nodes:
		items.append({"kind": "host", "id": String(node.id), "center": Vector2(node.center),
			"size": float(node.size), "label": host_label(node.host)})
	for w in wifi_points:
		items.append({"kind": "wifi", "id": String(w.ssid), "center": Vector2(w.pos),
			"size": MAP.WIFI_ICON_SIZE, "label": String(w.ssid)})
	for d in bt_points:
		items.append({"kind": "bt", "id": String(d.address), "center": Vector2(d.pos),
			"size": MAP.BT_ICON_SIZE, "label": _bt_label(d)})
	var spread = MAP.spread_all(items, vp, bar)
	var wi = host_nodes.size()
	var bi = wi + wifi_points.size()
	for i in range(spread.size()):
		var c = Vector2(spread[i].center)
		if i < wi:
			var node = host_nodes[i]
			node.center = c
			node.pos = c - Vector2(node.size, node.size) * 0.5
		elif i < bi:
			wifi_points[i - wi].pos = c
		else:
			bt_points[i - bi].pos = c


# Vuelca el estado del menú (filas, rect, hover) a la capa que lo dibuja.
func _sync_menu():
	if _menu_layer == null or not is_instance_valid(_menu_layer):
		return
	_menu_layer.visible = _menu_host != null
	if String(_menu_title) != "":
		_menu_layer.title = _menu_title
	else:
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
		return float(shell.frame_bar_h(shell._screen_size()))
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
		# Placa central («Este equipo»): menú de la señal Wi-Fi. Sólo en Vecindario;
		# en Grupo el centro es propio y no ofrece este menú.
		if mode == "neighborhood" and draw_center and MAP.hit_center(pos, center):
			_open_self_menu(pos)
			accept_event()
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
			var gm = _peer_member(node) if mode == "group" else null
			if gm != null:
				_open_group_menu(gm, pos, true)
			else:
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
		if mode == "neighborhood" and draw_center and MAP.hit_center(pos, center):
			_open_self_menu(pos)
			accept_event()
			update()
			return
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
			_drag_id = String(hit.id)
			_drag_from = pos
			_drag_now = pos
			_dragging = false
		else:
			selected_host = ""
			_drag_id = ""
		update()
	else:
		if _drag_id != "":
			var node = _node_by_id(_drag_id)
			if _dragging:
				# Grupo: se acomoda en cualquier ángulo de los 360°. Vecindario:
				# imanta a una de las cuatro direcciones.
				if mode == "group":
					var pl = _group_placement_at(pos)
					if not pl.empty():
						_apply_group_placement(_drag_id, pl.side, pl.offset)
				elif node != null:
					var dir = MAP.drag_direction(Vector2(node.center), pos)
					if dir != "":
						_apply_direction(_drag_id, dir)
			elif node != null:
				# Clic sin arrastre sobre un par: submenú de pantalla / teclado y mouse.
				var member = _peer_member(node)
				if member != null:
					_open_group_menu(member, pos, true)
		_drag_id = ""
		_dragging = false
		update()
		call_deferred("refresh", true)


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
		if not _dragging and (_drag_now - _drag_from).length() > 6.0:
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
			var km = _peer_member(node) if mode == "group" else null
			if km != null:
				_open_group_menu(km, Vector2(node.center) + Vector2(float(node.size) * 0.5, 0.0), true)
			else:
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
	_menu_is_group = false
	_menu_group_member = null
	_menu_is_self = false
	_menu_title = ""
	var acts = []
	for a in _host_actions(host):
		if not ["use_remote_input", "serve_input_here"].has(String(a.get("id", ""))):
			acts.append(a)   # teclado y mouse: sólo desde el Grupo
	_menu_items = MAP.neighbor_menu(host, acts, compass_direction(selected_host),
		MAP.debug_enabled(OS.get_environment("GDTK_DEBUG")))
	_menu_open_pos = Vector2(at)
	_menu_hover = -1
	_build_menu_rows()
	update()


# Menú de «Este equipo» (esta placa central): crear/apagar la señal Wi-Fi que
# comparte Internet. La ejecución la hace el shell (nmcli); acá sólo se arman
# filas honestas según el estado que publica el worker del Vecindario.
func _open_self_menu(at):
	_menu_is_wifi = false
	_menu_wifi = null
	_menu_is_bt = false
	_menu_bt = null
	_menu_is_group = false
	_menu_group_member = null
	_menu_is_self = true
	_menu_title = MAP.CENTER_TITLE
	_menu_host = {}
	_menu_items = _self_menu_items()
	_menu_open_pos = Vector2(at)
	_menu_hover = -1
	_build_menu_rows()
	update()


func _self_menu_items():
	var st = String(model.status) if model != null and model.get("status") != null else ""
	var hs = model.hotspot if model != null and model.get("hotspot") != null else {}
	if typeof(hs) != TYPE_DICTIONARY:
		hs = {}
	var active = bool(hs.get("active", false))
	var rows = []
	var reason = ""
	if st == "no_nmcli":
		reason = "nmcli no disponible"
	elif st == "off":
		reason = "Wi-Fi apagado"
	elif active:
		reason = "ya está encendida"
	rows.append({"kind": "hotspot_up", "id": "hotspot_up",
		"label": "Crear señal Wi-Fi (comparte Internet)",
		"enabled": reason == "", "reason": reason})
	if active:
		rows.append({"kind": "hotspot_down", "id": "hotspot_down",
			"label": "Apagar señal", "enabled": true, "reason": ""})
	# Fila informativa (sin acción): nombre visible + estado de Internet honesto.
	var info = "Señal apagada"
	if active:
		info = "Señal de " + local_name() + " · Internet: " \
			+ HOTSPOT.internet_state(String(hs.get("connectivity", "sin_dato")))
	rows.append({"kind": "info", "id": "hotspot_info", "label": info,
		"enabled": false, "reason": ""})
	return rows


# Menú de una red Wi-Fi (infraestructura, no presencia social): conectar /
# desconectar / encender la radio. La ejecución la hace el shell (nmcli/nmtui).
func _open_wifi_menu(w, at):
	if typeof(w) != TYPE_DICTIONARY:
		return
	_menu_is_wifi = true
	_menu_wifi = w
	_menu_is_bt = false
	_menu_bt = null
	_menu_is_group = false
	_menu_group_member = null
	_menu_is_self = false
	_menu_title = ""
	_menu_host = {}  # no-null: hay menú abierto (los huéspedes del menú son de host)
	_menu_items = _wifi_menu_items(w)
	_menu_open_pos = Vector2(at)
	_menu_hover = -1
	_build_menu_rows()
	update()


func _wifi_menu_items(w):
	var ssid = String(w.get("ssid", "")).strip_edges()
	var in_use = bool(w.get("in_use", false))
	var sec = String(w.get("security", "")).strip_edges()
	var secured = not (sec == "" or sec == "--")
	var out = []
	if ssid == "":
		return out
	out.append({"kind": ("wifi_connect_psk" if secured else "wifi_connect"),
		"id": ("wifi_connect_psk" if secured else "wifi_connect"),
		"label": "Conectar a " + ssid, "enabled": not in_use,
		"reason": "ya está conectada" if in_use else "",
		"ssid": ssid, "security": sec})
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
	_menu_is_group = false
	_menu_group_member = null
	_menu_is_self = false
	_menu_title = ""
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
	_menu_is_group = false
	_menu_group_member = null
	_menu_is_self = false
	_menu_title = ""
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
	if kind.begins_with("group_"):
		_activate_group_row(item)
		_close_menu()
		update()
		return
	if _menu_is_self:
		if kind == "hotspot_up" and shell != null and shell.has_method("_wifi_share_create"):
			shell._wifi_share_create()
		elif kind == "hotspot_down" and shell != null and shell.has_method("_wifi_share_stop"):
			shell._wifi_share_stop()
		_close_menu()
		update()
		return
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
		elif kind == "wifi_connect_psk":
			if shell != null and shell.has_method("_wifi_psk_request"):
				shell._wifi_psk_request(String(item.get("ssid", "")))
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
	var aid = String(action.get("id", ""))
	if aid == "add_to_group":
		_group_add(String(host_id))
		return
	if aid == "remove_from_group":
		_group_remove(String(host_id))
		return
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

func _host_actions(host, confirm_override = ""):
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
	if String(confirm_override) != "" and String(ctx.get("direction", "")) != "":
		ctx.direction_confirm = String(confirm_override)
	# En Grupo los equipos se ubican por ángulo (sin solapes) y el layout reparte los
	# rangos del borde: compartir un lado no es conflicto, sólo lo es en el Vecindario.
	if mode != "group" and _in_conflict(id):
		ctx.direction_conflict = true
	# Grupo: sólo en la vista Grupo se ofrece sumar/quitar; el Vecindario conserva
	# su menú. El conjunto de miembros se pasa sin tokens ni secretos.
	ctx.group_menu = (mode == "group")
	ctx.group_members = _group_member_set()
	# Emisor gdtk habilitado (GVD_SESSION.EMITTER_ENABLED): con gvd local resuelto y
	# un host confiable se ofrece también "Extender mi escritorio a él".
	if String(ctx.get("gvd_path", "")) != "" and not bool(host.get("degraded", false)):
		ctx.gvd_sender = true
	# Canal autorizado hacia este host: sólo el canal peer gdtk (LAN) que el host
	# anuncia por mDNS (`ctl=`). Pantalla on-demand no debe caer a ssh.
	ctx.provision_channel = int(host.get("ctl", 0)) > 0
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
	var resolved = "np/device-desktop"
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
	if mode == "group":
		_draw_group()
		return
	var bar = _bar()
	var radii = MAP.map_radii(rect_size, bar)
	_draw_ring(radii.rx_inner, radii.ry_inner, RING, 1.0)
	_draw_ring(radii.rx_mid, radii.ry_mid, RING_MID, 1.0)
	_draw_ring(radii.rx_outer, radii.ry_outer, RING, 1.0)
	for dot in wifi_points:
		var active = bool(dot.in_use)
		# AP con la antena clásica de Sugar (no el router genérico): mástil, bola y
		# ondas. Sigue siendo infraestructura, no presencia social.
		_draw_ap(Vector2(dot.pos), MAP.WIFI_ICON_SIZE * 0.5 + (2.0 if active else 0.0), active)
	if draw_center:
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
				var target = MAP.directional_center_ellipse(dir, 0, 1, center,
					float(radii.rx_mid), float(radii.ry_mid))
				draw_arc(target, 22.0, 0.0, TAU, 32, NODE_SEL, 2.0)
			_draw_node(drag_node, _drag_now, float(drag_node.size))
	# El menú lo dibuja _menu_layer (nodo propio, por encima); acá sólo se sincroniza.
	_sync_menu()


# Vista Grupo: sin anillos; cada miembro es un nodo (atenuado si está apagado) y
# los BT pareados una placa chica al pie. Al arrastrar, se marca el lado imantado.
func _draw_group():
	_draw_group_links()
	for node in host_nodes:
		if _dragging and String(node.id) == _drag_id:
			continue
		_draw_node(node, Vector2(node.center), float(node.size))
	for d in bt_points:
		_draw_bt_icon(Vector2(d.pos), float(d.get("size", MAP.BT_ICON_SIZE)) * 0.5, d)
	if _dragging:
		var drag_node = _node_by_id(_drag_id)
		if drag_node != null:
			if not _group_placement_at(_drag_now).empty():
				draw_arc(_group_ring_point(_drag_now), 24.0, 0.0, TAU, 32, NODE_SEL, 2.0)
			_draw_node(drag_node, _drag_now, float(drag_node.size))
	_sync_menu()


# --- Conectores del Grupo (N9) ----------------------------------------------
# Del ícono central a cada par con relación activa: glifo de pantalla y/o teclado,
# color por estado y flechas hacia donde se controla. Sólo lee las cachés del shell
# (las mismas de "Compartiendo"); el ciclo de vida de los servicios es del shell.

const LINK_OK = Color(0.52, 0.90, 0.58, 1.0)
const LINK_WAIT = Color(1.0, 0.84, 0.43, 1.0)
const LINK_ERR = Color(0.95, 0.42, 0.42, 1.0)


# Pares con relación: sesiones locales por equipo del Grupo + avisos remotos, fusionados
# por shared_block.radial. Misma lógica que el snapshot de "Compartiendo" del Frame.
func _group_peers():
	if shell == null or not shell.has_method("_host_session_state"):
		return []
	var running = shell._service_running("Deskflow") if shell.has_method("_service_running") else false
	var deskflow = shell.get("host_deskflow")
	var sessions = []
	for m in _group_members:
		if typeof(m) != TYPE_DICTIONARY or String(m.get("kind", "host")) != "host":
			continue
		var hid = String(m.get("id", ""))
		var side = String(m.get("direction", ""))
		if hid == "" or side == "":
			continue
		var agg = String(shell._host_session_state(hid))
		var name = String(m.get("name", hid))
		var screen = shell._gvd_has_session(hid) if shell.has_method("_gvd_has_session") else false
		var input_on = typeof(deskflow) == TYPE_DICTIONARY and bool(deskflow.get(hid, false)) \
			and (bool(running) or agg != "idle")
		if screen:
			sessions.append({"host": hid, "peer_name": name, "type": "screen", "side": side,
				"state": "starting" if agg == "starting" else "active"})
		if input_on:
			sessions.append({"host": hid, "peer_name": name, "type": "input", "side": side,
				"state": "active" if bool(running) else "starting"})
		if not screen and not input_on and agg == "starting":
			sessions.append({"host": hid, "peer_name": name, "type": "screen", "side": side,
				"state": "starting"})
	var remote = shell.get("remote_shares")
	return SHARED.radial(sessions, remote if typeof(remote) == TYPE_ARRAY else [], [])


func _draw_group_links():
	for l in GROUP.links(_group_layout, _group_peers()):
		var col = LINK_OK
		if String(l.state) == "starting":
			col = LINK_WAIT
		elif String(l.state) == "error":
			col = LINK_ERR
		var a = Vector2(l.a)
		var b = Vector2(l.b)
		var dir = (b - a).normalized()
		draw_line(a, b, col, 2.0, true)
		# Flecha hacia el par = este equipo lo controla/extiende; hacia el centro = al revés.
		if String(l.direction) == "out" or String(l.direction) == "both":
			_draw_arrow(b, dir, col)
		if String(l.direction) == "in" or String(l.direction) == "both":
			_draw_arrow(a, -dir, col)
		var glyphs = []
		if bool(l.screen):
			glyphs.append("screen")
		if bool(l.input):
			glyphs.append("input")
		var step = dir * 26.0
		for i in range(glyphs.size()):
			var gc = Vector2(l.mid) + step * (float(i) - float(glyphs.size() - 1) * 0.5)
			draw_circle(gc, 12.0, NODE_BG)
			draw_arc(gc, 12.0, 0.0, TAU, 24, col, 1.5)
			if glyphs[i] == "screen":
				_draw_screen_glyph(gc, col)
			else:
				_draw_keyboard_glyph(gc, col)


func _draw_arrow(tip, dir, col):
	var n = Vector2(-dir.y, dir.x)
	draw_colored_polygon(PoolVector2Array([tip, tip - dir * 10.0 + n * 5.0, tip - dir * 10.0 - n * 5.0]), col)


func _draw_screen_glyph(c, col):
	draw_rect(Rect2(c + Vector2(-7, -7), Vector2(14, 9)), col, false, 1.5)
	draw_line(c + Vector2(0, 2), c + Vector2(0, 6), col, 1.5)
	draw_line(c + Vector2(-4, 6), c + Vector2(4, 6), col, 1.5)


func _draw_keyboard_glyph(c, col):
	draw_rect(Rect2(c + Vector2(-8, -4), Vector2(16, 9)), col, false, 1.5)
	for i in range(3):
		draw_circle(c + Vector2(-4 + 4 * i, -1), 0.9, col)
	draw_line(c + Vector2(-4, 2), c + Vector2(4, 2), col, 1.2)


# Elipse por muestreo (draw_arc sólo dibuja círculos en Godot 3).
func _draw_ring(rx, ry, color, width):
	var pts = PoolVector2Array()
	var steps = 96
	for i in range(steps + 1):
		var a = TAU * float(i) / float(steps)
		pts.append(center + Vector2(cos(a) * float(rx), sin(a) * float(ry)))
	draw_polyline(pts, color, width, true)


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


# Acento que anuncia el equipo (TXT `accent`), o null si no lo anuncia.
static func node_accent(node):
	var host = node.get("host", {}) if typeof(node) == TYPE_DICTIONARY else {}
	var a = String(host.get("accent", "")) if typeof(host) == TYPE_DICTIONARY else ""
	return Color(a) if a.begins_with("#") and a.length() == 7 and a.substr(1).is_valid_hex_number() else null


func _draw_node(node, c, size):
	var r = size * 0.5
	var bg = NODE_BG
	var ring = NODE_RING
	# Como el XO de Sugar: cada equipo con su color (relleno suave + anillo).
	var acc = node_accent(node)
	if acc != null:
		bg = NODE_BG.linear_interpolate(acc, 0.35)
		ring = acc
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
