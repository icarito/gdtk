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
# Tamaño visible del ícono de AP (era un punto de 5 px: ilegible). El AP es
# infraestructura, así que es tenue, pero seleccionable.
const WIFI_ICON_SIZE = 30.0
const WIFI_HIT_EXTRA = 6.0
const WIFI_FRACTION_MIN = 0.32
const WIFI_FRACTION_MAX = 0.95

# Dispositivos Bluetooth: ícono algo menor que el AP; se ubican en anillos
# simbólicos (conectado cerca, vinculado al medio, conocido lejos).
const BT_ICON_SIZE = 26.0
const BT_HIT_EXTRA = 6.0
const BT_FRACTION_MIN = 0.26
const BT_FRACTION_MAX = 0.98

const NODE_SIZE = 56.0
const NODE_MARGIN = 12.0
# Separación angular entre vecinos que comparten la misma dirección.
const SPREAD_STEP = 0.30
# Radio (px) bajo el cual un arrastre no imanta a ningún lado.
const MAGNET_DEADZONE = 44.0

# Margen (px) que se descuenta en cada borde de la vista al calcular los radios de
# la elipse: deja lugar para las barras (arriba/abajo, se pasa aparte) y para los
# íconos/rótulos pegados al borde.
const EDGE_MARGIN = 40.0
# Alto extra bajo el disco ocupado por el rótulo (misma definición que la vista).
const LABEL_TAIL = 18.0
# La cápsula anti-solape usa el rótulo truncado a ~14 caracteres y un ancho medio
# por carácter para estimar cuánto ocupa.
const SPREAD_LABEL_CHARS = 14
const SPREAD_CHAR_W = 7.0
const SPREAD_GAP = 2.0

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


# Radios del mapa. Ahora son ELÍPTICOS: `rx` (ancho) y `ry` (alto) por separado,
# de modo que el mapa usa casi toda la vista (se descuentan las barras arriba/
# abajo y un margen para íconos/rótulos). Se conservan las claves escalares
# históricas (inner/mid/outer = min(rx,ry) de cada anillo) para compatibilidad; el
# layout y la UI usan rx_*/ry_* para dibujar/ubicar sobre la elipse.
static func map_radii(vp, bar):
	var w = max(1.0, float(vp.x))
	var h = max(1.0, float(vp.y))
	var usable_w = max(1.0, w - 2.0 * EDGE_MARGIN)
	var usable_h = max(1.0, h - 2.0 * float(bar) - 2.0 * EDGE_MARGIN)
	var rx = usable_w * 0.5
	var ry = usable_h * 0.5
	var rx_inner = rx * INNER_FRACTION
	var ry_inner = ry * INNER_FRACTION
	var rx_mid = rx * MID_FRACTION
	var ry_mid = ry * MID_FRACTION
	var rx_outer = rx * OUTER_FRACTION
	var ry_outer = ry * OUTER_FRACTION
	return {
		"rx": rx, "ry": ry,
		"rx_inner": rx_inner, "ry_inner": ry_inner,
		"rx_mid": rx_mid, "ry_mid": ry_mid,
		"rx_outer": rx_outer, "ry_outer": ry_outer,
		"inner": min(rx_inner, ry_inner),
		"mid": min(rx_mid, ry_mid),
		"outer": min(rx_outer, ry_outer),
	}


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


# Variante elíptica de directional_center: `rx`/`ry` son los radios horizontal y
# vertical del anillo. Puro y determinista.
static func directional_center_ellipse(direction, ordinal, count, center, rx, ry):
	var base = direction_angle(direction)
	var span = (float(ordinal) - float(count - 1) * 0.5) * SPREAD_STEP
	var ang = base + span
	return Vector2(center.x + cos(ang) * float(rx), center.y + sin(ang) * float(ry))


# Variante elíptica de free_center.
static func free_center_ellipse(index, count, center, rx, ry):
	var n = max(1, int(count))
	var ang = -PI * 0.5 + TAU * float(index) / float(n)
	return Vector2(center.x + cos(ang) * float(rx), center.y + sin(ang) * float(ry))


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
			var c = directional_center_ellipse(d, i, list.size(), center, radii.rx_mid, radii.ry_mid)
			out.append(_node(list[i], _clamp_center(c, vp, bar, margin), s, d, false, i))
	for i in range(free.size()):
		var c2 = free_center_ellipse(i, free.size(), center, radii.rx_outer, radii.ry_outer)
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
		var s = lerp(MID_FRACTION * WIFI_FRACTION_MIN, OUTER_FRACTION * WIFI_FRACTION_MAX, frac)
		var a = float(n.get("angle", 0.0))
		out.append({
			"pos": Vector2(center.x + cos(a) * radii.rx_outer * s,
				center.y + sin(a) * radii.ry_outer * s),
			"in_use": bool(n.get("in_use", false)),
			"ssid": String(n.get("ssid", "")),
			"security": String(n.get("security", "")),
			"signal": int(n.get("signal", 0)),
		})
	return out


# AP (red Wi-Fi) bajo `point`, o null. Radio de impacto = ícono + margen.
static func hit_wifi(point, points, radius = WIFI_ICON_SIZE * 0.5 + WIFI_HIT_EXTRA):
	if typeof(points) != TYPE_ARRAY:
		return null
	var p = Vector2(point)
	for w in points:
		if typeof(w) != TYPE_DICTIONARY:
			continue
		if p.distance_to(Vector2(w.get("pos", Vector2.ZERO))) <= float(radius):
			return w
	return null


# Dispositivos Bluetooth sobre anillos simbólicos (mismo esquema que el Wi-Fi).
static func bt_dots(devices, vp, bar):
	var out = []
	if typeof(devices) != TYPE_ARRAY:
		return out
	var center = Vector2(vp.x * 0.5, vp.y * 0.5)
	var radii = map_radii(vp, bar)
	for d in devices:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var frac = clamp(float(d.get("r_frac", 0.0)), 0.0, 1.0)
		var s = lerp(MID_FRACTION * BT_FRACTION_MIN, OUTER_FRACTION * BT_FRACTION_MAX, frac)
		var a = float(d.get("angle", 0.0))
		out.append({
			"pos": Vector2(center.x + cos(a) * radii.rx_outer * s,
				center.y + sin(a) * radii.ry_outer * s),
			"address": String(d.get("address", "")),
			"name": String(d.get("name", "")),
			"connected": bool(d.get("connected", false)),
			"paired": bool(d.get("paired", false)),
			"rssi": int(d.get("rssi", 0)),
		})
	return out


# Dispositivo Bluetooth bajo `point`, o null.
static func hit_bt(point, points, radius = BT_ICON_SIZE * 0.5 + BT_HIT_EXTRA):
	return hit_wifi(point, points, radius)


# --- Anti-solape por cápsulas (puro y determinista) --------------------------
# La lógica de relajación vive acá (geometría pura); neighborhood.gd delega en
# estas funciones para conservar su API histórica.

# Media altura de la cápsula de un nodo de radio `rad`: el disco más la etiqueta.
static func capsule_half_h(rad):
	return float(rad) + LABEL_TAIL


# Rótulo truncado a `max_chars` (sin puntos suspensivos): sólo mide el espacio que
# ocupa la cápsula; el texto que dibuja la vista no cambia.
static func truncate_label(s, max_chars = SPREAD_LABEL_CHARS):
	var t = String(s).strip_edges()
	var m = int(max_chars)
	if m > 0 and t.length() > m:
		return t.substr(0, m)
	return t


# Dimensiones medias de la cápsula de un ítem del mapa: centro + tamaño de ícono
# + rótulo truncado a ~14 caracteres. `hw` cubre el ícono o el rótulo (el mayor).
static func capsule_dims(item):
	if typeof(item) != TYPE_DICTIONARY:
		return {"hw": NODE_SIZE * 0.5, "hh": NODE_SIZE * 0.5 + LABEL_TAIL}
	var size = float(item.get("size", NODE_SIZE))
	if size <= 0.0:
		size = NODE_SIZE
	var label = truncate_label(String(item.get("label", "")))
	var label_w = float(label.length()) * SPREAD_CHAR_W
	return {"hw": max(size * 0.5, label_w * 0.5), "hh": size * 0.5 + LABEL_TAIL}


# Una pasada de repulsión por cápsulas. Empuja cada par a lo largo de la recta que
# une sus centros, hasta separarlos según la función soporte de la caja en esa
# dirección ((hw_i+hw_j)|dx| + (hh_i+hh_j)|dy|): es estable y determinista, y no se
# atasca como el empuje por eje mínimo en un caso denso.
static func _separate_once(p, half_w, half_h, gap):
	var n = p.size()
	for i in range(n):
		for j in range(i + 1, n):
			var d = p[j] - p[i]
			var dist = d.length()
			var dir
			if dist < 0.0001:
				# Coincidencia exacta: se rompe la simetría de forma determinista.
				dir = Vector2(1.0, 0.0).rotated(float(i * 7 + j) * 0.7)
				dist = 0.0
			else:
				dir = d / dist
			var need = (float(half_w[i]) + float(half_w[j]) + gap) * abs(dir.x) \
				+ (float(half_h[i]) + float(half_h[j]) + gap) * abs(dir.y)
			if dist >= need:
				continue  # ya separados (hay eje que los separa)
			var push = (need - dist) * 0.5
			p[i] -= dir * push
			p[j] += dir * push


# Separación por cápsulas (pura y determinista). Cada nodo ocupa una caja
# [p - (hw, hh), p + (hw, hh)]; dos cajas nunca deben solaparse (con `gap` de margen),
# así la etiqueta debajo del disco también queda libre. Se aplica repulsión iterativa
# con un resorte decreciente hacia la posición original para conservar el anillo y el
# sector angular aproximados (el nodo puede salir del anillo si hace falta: la última
# pasada es repulsión pura). Los mismos nodos dan siempre la misma disposición.
static func relax_capsules(pts, half_w, half_h, gap = 2.0, iterations = 48, spring = 0.02):
	# Copia a Array: acepta igual Array que PoolVector2Array (este último no tiene
	# duplicate() en Godot 3).
	var p = []
	for v in pts:
		p.append(v)
	var n = p.size()
	for it in range(iterations):
		_separate_once(p, half_w, half_h, gap)
		# Resorte decreciente hacia la posición original.
		var s = spring * float(iterations - it - 1) / float(iterations)
		if s > 0.0:
			for i in range(n):
				p[i] = p[i].linear_interpolate(pts[i], s)
	# Pasadas finales sin resorte: en un caso denso una sola vuelta puede quedar a
	# medias. Se insiste sólo mientras quede algún par solapado (acotado y determinista).
	var guard = 0
	while guard < iterations and capsules_overlap(p, half_w, half_h, gap):
		guard += 1
		_separate_once(p, half_w, half_h, gap)
	return p


# Compatibilidad: la relajación circular histórica es el caso hw == hh == radio.
static func relax_positions(pts, radii, gap = 2.0, iterations = 16, spring = 0.03):
	return relax_capsules(pts, radii, radii, gap, iterations, spring)


# ¿Se solapa algún par de cápsulas? Prueba pura (misma definición que relax_capsules)
# para verificar que ninguna etiqueta pisa a otro nodo.
static func capsules_overlap(pts, half_w, half_h, gap = 0.0):
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			if abs(pts[j].x - pts[i].x) < float(half_w[i]) + float(half_w[j]) + gap \
					and abs(pts[j].y - pts[i].y) < float(half_h[i]) + float(half_h[j]) + gap:
				return true
	return false


# Mantiene las cápsulas dentro de la vista: x en [hw, vp.x-hw] e y en
# [bar+hh, vp.y-bar-hh]. Pura; respeta barras y rótulos.
static func _clamp_capsules(p, half_w, half_h, vp, bar):
	for i in range(p.size()):
		var min_x = float(half_w[i])
		var max_x = max(min_x, float(vp.x) - float(half_w[i]))
		var min_y = float(bar) + float(half_h[i])
		var max_y = max(min_y, float(vp.y) - float(bar) - float(half_h[i]))
		p[i] = Vector2(clamp(p[i].x, min_x, max_x), clamp(p[i].y, min_y, max_y))


# Pasada final anti-solape del Vecindario: reúne hosts, Wi-Fi y Bluetooth como
# cápsulas (centro + tamaño de ícono + rótulo truncado) y las reparte sin solapes
# y sin salir de la vista. `items` = [{kind, id, center, size, label}]; devuelve
# [{kind, id, center, size, label, hw, hh}] en el mismo orden. Pura y determinista.
static func spread_all(items, vp, bar):
	var out = []
	if typeof(items) != TYPE_ARRAY or items.empty():
		return out
	var pts = []
	var half_w = []
	var half_h = []
	for it in items:
		var d = it if typeof(it) == TYPE_DICTIONARY else {}
		pts.append(Vector2(d.get("center", Vector2.ZERO)))
		var dims = capsule_dims(d)
		half_w.append(float(dims.hw))
		half_h.append(float(dims.hh))
	var p = relax_capsules(pts, half_w, half_h, SPREAD_GAP, 48, 0.02)
	# La relajación no conoce los bordes: se alterna separación y recorte hasta que
	# no quede ningún par solapado (acotado y determinista).
	var guard = 0
	while guard < 96:
		_clamp_capsules(p, half_w, half_h, vp, bar)
		if not capsules_overlap(p, half_w, half_h, SPREAD_GAP):
			break
		_separate_once(p, half_w, half_h, SPREAD_GAP)
		guard += 1
	_clamp_capsules(p, half_w, half_h, vp, bar)
	for i in range(items.size()):
		var it = items[i] if typeof(items[i]) == TYPE_DICTIONARY else {}
		out.append({
			"kind": String(it.get("kind", "")),
			"id": String(it.get("id", "")),
			"center": p[i],
			"size": float(it.get("size", NODE_SIZE)),
			"label": String(it.get("label", "")),
			"hw": half_w[i],
			"hh": half_h[i],
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
	if low.find("canal de pantalla") >= 0 or low.find("canal peer") >= 0 \
			or low.find("capable") >= 0:
		return "no se puede contactar al otro equipo"
	if low.find("receptor de pantalla") >= 0 or low.find("gvd") >= 0:
		return "pantalla no disponible en este equipo"
	if low.find("deskflow") >= 0:
		return "el control compartido no está disponible en este equipo"
	if low.find("hid") >= 0 or low.find("degradado") >= 0 or low.find("confiable") >= 0:
		return "sin identificar: no es confiable"
	if low.find("conflicto") >= 0:
		return "dos equipos en el mismo lado"
	if low.find("confirmar") >= 0:
		return "falta confirmar la posición"
	if low.find("canal") >= 0:
		return "no se puede contactar al otro equipo"
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


# Fila del menú contextual. `kind`: "action" | "separator" | "debug".
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
	if bool(debug):
		if not items.empty():
			items.append({"kind": "separator"})
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
