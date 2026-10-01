extends Reference

# K10a — Geometría y vocabulario PUROS del mapa 2D del Vecindario.
#
# Un solo mapa: "Este equipo" al centro, los vecinos en nodos circulares
# ubicados por su dirección (norte arriba, sur abajo, este derecha, oeste
# izquierda, pegados al anillo medio) y el Wi-Fi como puntos chicos en los
# anillos (infraestructura, no presencia social).
#
# Sin red, procesos, filesystem ni estado global: sólo calcula posiciones,
# traduce a lenguaje humano y arma las filas del menú contextual. La UI
# (neighborhood_ui.gd) sólo dibuja snapshots y delega la ejecución al shell.
#
# Vocabulario obligatorio (SPEC-ui-rework-2026-10): nunca se muestran los
# nombres internos (gvd, deskflow, role, hid, kind, mDNS, DNS-SD, recv,
# server/client, puertos). Esos viven sólo en código/logs y, si acaso, en los
# ítems de depuración que la UI agrega únicamente con GDTK_DEBUG=1.

const DIRECTIONS = ["north", "south", "east", "west"]
const DIRECTION_LABELS = {
	"north": "Norte",
	"south": "Sur",
	"east": "Este",
	"west": "Oeste",
}
# Ángulo de pantalla por cardinal: norte arriba (-PI/2), este derecha (0),
# sur abajo (PI/2), oeste izquierda (PI).
const DIRECTION_ANGLES = {
	"north": -PI * 0.5,
	"south": PI * 0.5,
	"east": 0.0,
	"west": PI,
}

const INNER_FRACTION = 0.42
const MID_FRACTION = 0.62
const OUTER_FRACTION = 1.0
# Puntos de Wi-Fi: no son nodos; van entre el anillo interior y el exterior.
const WIFI_DOT_RADIUS = 2.5
const WIFI_FRACTION_MIN = 0.32
const WIFI_FRACTION_MAX = 0.95

const NODE_SIZE = 56.0
const NODE_MARGIN = 12.0
# Separación angular entre vecinos que comparten la misma dirección.
const SPREAD_STEP = 0.30
# Radio (px) bajo el cual un arrastre no imanta a ningún lado.
const MAGNET_DEADZONE = 44.0

const EMPTY_SEARCHING = "Buscando equipos cercanos…"
const EMPTY_NONE = "No hay otros equipos"
const EMPTY_GRACE_MS = 6000

const CENTER_TITLE = "Este equipo"

# Términos internos prohibidos en cualquier cadena visible.
const _FORBIDDEN = ["gvd", "deskflow", "role", "hid", "kind", "mdns", "dns-sd",
	"recv", "server", "client", "puerto"]
const _PEER_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"


static func valid_direction(d):
	return DIRECTIONS.has(String(d).strip_edges())


static func direction_label(d):
	var k = String(d).strip_edges()
	return String(DIRECTION_LABELS[k]) if DIRECTION_LABELS.has(k) else ""


static func direction_angle(d):
	var k = String(d).strip_edges()
	return float(DIRECTION_ANGLES[k]) if DIRECTION_ANGLES.has(k) else 0.0


# Radios del anillo medio (donde se pegan los vecinos con dirección) y exterior
# (donde van los vecinos sin dirección). Puro respecto de viewport y barra.
static func map_radii(vp, bar):
	var max_r = max(60.0, min(vp.x * 0.36, (vp.y - 2.0 * bar - 130.0) * 0.5))
	return {"inner": max_r * INNER_FRACTION, "mid": max_r * MID_FRACTION, "outer": max_r * OUTER_FRACTION}


# Dirección declarada en host_directions para un host, o "" si no hay/no es válida.
static func direction_of(directions, hid):
	if typeof(directions) != TYPE_DICTIONARY:
		return ""
	var entry = directions.get(String(hid), null)
	if typeof(entry) != TYPE_DICTIONARY:
		return ""
	var d = String(entry.get("direction", "none")).strip_edges()
	return d if valid_direction(d) else ""


# Centro de un nodo con dirección sobre el anillo medio; los que comparten
# dirección se reparten en un arco corto alrededor de ella.
static func directional_center(direction, ordinal, count, center, radius):
	var base = direction_angle(direction)
	var span = (float(ordinal) - float(count - 1) * 0.5) * SPREAD_STEP
	var ang = base + span
	return Vector2(center.x + cos(ang) * radius, center.y + sin(ang) * radius)


# Centro de un vecino sin dirección: anillo exterior, repartido uniformemente.
static func free_center(index, count, center, radius):
	var n = max(1, int(count))
	var ang = -PI * 0.5 + TAU * float(index) / float(n)
	return Vector2(center.x + cos(ang) * radius, center.y + sin(ang) * radius)


static func _clamp_center(c, vp, bar, margin):
	var min_x = margin
	var max_x = max(margin, vp.x - margin)
	var min_y = bar + margin
	var max_y = max(bar + margin, vp.y - bar - margin)
	return Vector2(clamp(c.x, min_x, max_x), clamp(c.y, min_y, max_y))


# Snapshot de nodos del mapa. Devuelve [{id, host, center, pos, size,
# direction, dimmed, index}]. `pos` es la esquina (para íconos), `center` el
# centro (para dibujo e impacto). No toca nodos ni estado global.
static func map_layout(hosts, directions, vp, bar, size = 0.0):
	var out = []
	if typeof(hosts) != TYPE_ARRAY:
		return out
	var s = NODE_SIZE if float(size) <= 0.0 else float(size)
	var margin = s * 0.5 + NODE_MARGIN
	var center = Vector2(vp.x * 0.5, vp.y * 0.5)
	var radii = map_radii(vp, bar)
	var by_dir = {}
	var free = []
	for h in hosts:
		if typeof(h) != TYPE_DICTIONARY:
			continue
		var d = direction_of(directions, String(h.get("id", "")))
		if d == "":
			free.append(h)
		else:
			if not by_dir.has(d):
				by_dir[d] = []
			by_dir[d].append(h)
	for d in DIRECTIONS:
		if not by_dir.has(d):
			continue
		var list = by_dir[d]
		for i in range(list.size()):
			var c = directional_center(d, i, list.size(), center, radii.mid)
			out.append(_node(list[i], _clamp_center(c, vp, bar, margin), s, d, false, i))
	for i in range(free.size()):
		var c2 = free_center(i, free.size(), center, radii.outer)
		out.append(_node(free[i], _clamp_center(c2, vp, bar, margin), s, "", true, i))
	return out


static func _node(host, c, s, direction, dimmed, index):
	return {
		"id": String(host.get("id", "")),
		"host": host,
		"center": c,
		"pos": c - Vector2(s, s) * 0.5,
		"size": s,
		"direction": direction,
		"dimmed": dimmed,
		"index": index,
	}


# Puntos discretos de Wi-Fi sobre los anillos. No compiten con los equipos.
static func wifi_dots(networks, vp, bar):
	var out = []
	if typeof(networks) != TYPE_ARRAY:
		return out
	var center = Vector2(vp.x * 0.5, vp.y * 0.5)
	var radii = map_radii(vp, bar)
	for n in networks:
		if typeof(n) != TYPE_DICTIONARY:
			continue
		var frac = clamp(float(n.get("r_frac", 0.0)), 0.0, 1.0)
		var r = lerp(radii.mid * WIFI_FRACTION_MIN, radii.outer * WIFI_FRACTION_MAX, frac)
		var a = float(n.get("angle", 0.0))
		out.append({
			"pos": Vector2(center.x + cos(a) * r, center.y + sin(a) * r),
			"in_use": bool(n.get("in_use", false)),
			"ssid": String(n.get("ssid", "")),
		})
	return out


# "Red: <SSID>" de la red en uso, o "" si no hay. Texto humano para la UI.
static func wifi_label(networks):
	if typeof(networks) != TYPE_ARRAY:
		return ""
	for n in networks:
		if typeof(n) == TYPE_DICTIONARY and bool(n.get("in_use", false)):
			var ssid = String(n.get("ssid", "")).strip_edges()
			return "" if ssid == "" else "Red: " + ssid
	return ""


# Imán de arrastre: dirección cardinal más cercana al vector `delta`, o "" si el
# desplazamiento es menor que `deadzone` (no se imanta). Puro y determinista.
static func magnet_direction(delta, deadzone = MAGNET_DEADZONE):
	var d = Vector2(delta)
	if d.length() < float(deadzone):
		return ""
	if abs(d.x) >= abs(d.y):
		return "east" if d.x >= 0.0 else "west"
	return "south" if d.y >= 0.0 else "north"


# Dirección imantada al soltar en `release_pos` un nodo centrado en `host_center`.
static func drag_direction(host_center, release_pos, deadzone = MAGNET_DEADZONE):
	return magnet_direction(Vector2(release_pos) - Vector2(host_center), deadzone)


# Nodo bajo `point` (con pequeño margen de impacto), o null.
static func hit_node(point, nodes):
	if typeof(nodes) != TYPE_ARRAY:
		return null
	var p = Vector2(point)
	for n in nodes:
		if typeof(n) != TYPE_DICTIONARY:
			continue
		var c = Vector2(n.get("center", Vector2.ZERO))
		var r = float(n.get("size", NODE_SIZE)) * 0.5 + 4.0
		if (p - c).length() <= r:
			return n
	return null


# Estado vacío claro y sin jerga: buscando durante `grace_ms`, luego sin equipos.
static func empty_message(host_count, elapsed_ms, grace_ms = EMPTY_GRACE_MS):
	if int(host_count) > 0:
		return ""
	return EMPTY_SEARCHING if int(elapsed_ms) < int(grace_ms) else EMPTY_NONE


# ¿La cadena contiene algún término interno prohibido en la UI?
static func has_internal_terms(s):
	var low = String(s).to_lower()
	for t in _FORBIDDEN:
		if low.find(String(t)) >= 0:
			return true
	return false


# "GDTK_DEBUG=1" habilita los ítems/datos de depuración en la UI. Puro: recibe
# el valor del entorno ya leído por el caller.
static func debug_enabled(env_value):
	var v = String(env_value).strip_edges().to_lower()
	return v == "1" or v == "true" or v == "yes"


# Traduce el id de acción del módulo puro (neighborhood_actions.gd) a lenguaje
# humano. El `fallback` es la etiqueta original del módulo, ya en español.
static func human_action_label(action_id, fallback = ""):
	match String(action_id):
		"use_as_screen":
			return "Ver su escritorio aquí"
		"share_my_screen":
			return "Extender mi escritorio a él"
		"use_remote_input":
			return "Usar su teclado y mouse aquí"
		"serve_input_here":
			return "Controlarlo con mi teclado y mouse"
	return String(fallback)


# Razón en español para una acción deshabilitada, sin nombres internos. Si el
# motivo original no se reconoce y trae jerga, se usa un texto genérico.
static func human_reason(action):
	if typeof(action) != TYPE_DICTIONARY:
		return ""
	if bool(action.get("enabled", false)):
		return ""
	var raw = String(action.get("reason", "")).strip_edges()
	if raw == "":
		raw = String(action.get("state", "")).strip_edges()
	var low = raw.to_lower()
	if low.find("receptor de pantalla") >= 0 or low.find("gvd") >= 0:
		return "no tiene el receptor de pantalla"
	if low.find("deskflow") >= 0:
		return "el control compartido no está disponible en este equipo"
	if low.find("hid") >= 0 or low.find("degradado") >= 0 or low.find("confiable") >= 0:
		return "sin identificar: no es confiable"
	if low.find("conflicto") >= 0:
		return "dos equipos en el mismo lado"
	if low.find("confirmar") >= 0:
		return "falta confirmar la posición"
	if low.find("canal") >= 0 or low.find("capable") >= 0:
		return "hay que habilitar el receptor en el otro equipo"
	if has_internal_terms(raw):
		return "no disponible"
	return raw


# Texto corto de estado de posición (compañero humano de compass_state).
static func direction_status_text(state, direction):
	match String(state):
		"conflicto":
			return "conflicto de posición"
		"sin_direccion":
			return "sin posición"
		"confirmada":
			return "posición confirmada: " + direction_label(direction)
		_:
			return "posición propuesta: " + direction_label(direction)


# Fila del menú contextual. `kind`: "action" | "direction" | "separator" | "debug".
# Los ítems deshabilitados llevan `reason` para mostrar en una línea aparte.
static func neighbor_menu(host, actions, direction, debug = false):
	var items = []
	if typeof(actions) == TYPE_ARRAY:
		for a in actions:
			if typeof(a) != TYPE_DICTIONARY:
				continue
			items.append({
				"kind": "action",
				"id": String(a.get("id", "")),
				"label": human_action_label(String(a.get("id", "")), String(a.get("label", ""))),
				"enabled": bool(a.get("enabled", false)),
				"reason": human_reason(a),
				"action": a,
			})
	items.append({"kind": "separator"})
	var cur = direction if valid_direction(direction) else "none"
	for d in DIRECTIONS:
		var already = (d == cur)
		items.append({
			"kind": "direction",
			"id": "direction:" + d,
			"label": "Colocar al " + direction_label(d),
			"enabled": not already,
			"reason": ("ya está al " + direction_label(d)) if already else "",
			"direction": d,
		})
	items.append({
		"kind": "direction",
		"id": "direction:none",
		"label": "Quitar de la disposición",
		"enabled": cur != "none",
		"reason": "" if cur != "none" else "sin posición asignada",
		"direction": "none",
	})
	if bool(debug):
		var h = host if typeof(host) == TYPE_DICTIONARY else {}
		items.append({"kind": "separator"})
		items.append({"kind": "debug", "id": "debug:id", "label": "id: " + String(h.get("id", "")),
			"enabled": false, "reason": ""})
		var caps = h.get("capabilities", {})
		if typeof(caps) == TYPE_DICTIONARY:
			for k in caps.keys():
				items.append({"kind": "debug", "id": "debug:" + String(k),
					"label": "servicio: " + String(k), "enabled": false, "reason": ""})
	return items


# Nombre seguro para el layout de Deskflow (mismo alfabeto que valid_peer):
# espacios -> "_", se descartan otros inválidos y se recortan "."/"-" extremos.
static func safe_peer(name, fallback = "peer"):
	var raw = String(name).strip_edges()
	var out = ""
	for i in range(raw.length()):
		var ch = raw.substr(i, 1)
		if _PEER_CHARS.find(ch) >= 0:
			out += ch
		elif ch == " " or ch == "\t":
			out += "_"
	out = out.lstrip(".-").rstrip(".-")
	if out == "":
		out = String(fallback)
	return out
