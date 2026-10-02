extends Reference

# Modelo puro (K11b) del diseno de pantallas de Configuracion > Pantallas.
#
# Reemplaza el panel "Distribucion": las pantallas son rectangulos con tamano
# real/virtual y posicion (x, y) en un plano. Al soltar una pantalla arrastrada se
# imanta para quedar SIEMPRE pegada por un borde a otra, sin solaparse, con un
# contacto minimo > 0 (para que el mouse pase) y permitiendo desplazamiento libre
# a lo largo del borde (alineacion arbitraria, no solo centrada).
#
# Es puro: sin I/O, sin procesos, sin red y sin estado global. Solo normaliza,
# valida, calcula geometria y produce la salida que consume el resto del shell:
#   - output(): por cada vecino {direction, offset_px, offset_percent, via};
#   - to_host_directions(): mismas direcciones en el formato de host_directions
#     (misma fuente unica que Pantalla y Teclado y mouse);
#   - local_links(): aristas locales para la config del compartir teclado/mouse;
#   - edges(): adyacencias completas, para generalizar a multimonitor/cadenas.
#
# Vocabulario: este modelo no produce texto visible salvo las etiquetas que le
# pasa el llamador. El default de la pantalla local es "Este equipo".

const VERSION = 1

const DEFAULT_W = 1280.0
const DEFAULT_H = 800.0
# Contacto minimo de borde (px) para que el puntero cruce de una pantalla a otra.
const MIN_CONTACT = 24.0
# Tolerancia de "pegado" al buscar aristas (px).
const TOUCH_TOL = 1.0

const DIRECTIONS = ["north", "south", "east", "west"]
const SIDE_ORDER = ["east", "west", "south", "north"]
const EDGE_BY_DIRECTION = {"north": "up", "south": "down", "east": "right", "west": "left"}

const LOCAL_ID = "local"
const LOCAL_LABEL = "Este equipo"


# --- Normalizacion ------------------------------------------------------------

static func _num(v, fallback):
	var t = typeof(v)
	if t == TYPE_INT or t == TYPE_REAL:
		return float(v)
	if t == TYPE_STRING and String(v).is_valid_float():
		return float(v)
	return float(fallback)


static func default_screen(id = "", label = "", is_local = false):
	return {
		"id": String(id),
		"label": String(label) if String(label) != "" else String(id),
		"peer": "",
		"local": bool(is_local),
		"x": 0.0,
		"y": 0.0,
		"w": DEFAULT_W,
		"h": DEFAULT_H,
		"offset": 0.0,
	}


# Pantalla canonica. Devuelve null si no es un diccionario. w/h siempre > 0.
static func sanitize_screen(s):
	if typeof(s) != TYPE_DICTIONARY:
		return null
	var id = String(s.get("id", "")).strip_edges()
	var out = default_screen(id, String(s.get("label", "")), bool(s.get("local", false)))
	out.peer = String(s.get("peer", "")).strip_edges()
	out.x = _num(s.get("x", 0.0), 0.0)
	out.y = _num(s.get("y", 0.0), 0.0)
	out.w = _num(s.get("w", DEFAULT_W), DEFAULT_W)
	out.h = _num(s.get("h", DEFAULT_H), DEFAULT_H)
	if out.w <= 0.0:
		out.w = DEFAULT_W
	if out.h <= 0.0:
		out.h = DEFAULT_H
	out.offset = _num(s.get("offset", 0.0), 0.0)
	return out


static func sanitize_screens(arr):
	var out = []
	if typeof(arr) != TYPE_ARRAY:
		return out
	var seen = {}
	for s in arr:
		var clean = sanitize_screen(s)
		if clean == null or clean.id == "" or seen.has(clean.id):
			continue
		seen[clean.id] = true
		out.append(clean)
	return out


# Layout canonico {version, local, screens}. La local siempre existe (default
# "Este equipo"); las pantallas locales duplicadas se descartan de la lista.
static func normalize_layout(data):
	if typeof(data) != TYPE_DICTIONARY:
		data = {}
	var out = {"version": VERSION, "local": null, "screens": []}
	var raw_local = data.get("local", null)
	var local = sanitize_screen(raw_local) if raw_local != null else null
	if local == null or (local.id == "" and local.label == ""):
		local = default_screen(LOCAL_ID, LOCAL_LABEL, true)
	local.local = true
	if local.id == "":
		local.id = LOCAL_ID
	out.local = local
	var seen = {local.id: true}
	for s in sanitize_screens(data.get("screens", [])):
		s.local = false
		if seen.has(s.id):
			continue
		seen[s.id] = true
		out.screens.append(s)
	out.version = VERSION
	return out


# --- Geometria -----------------------------------------------------------------

static func rect(s):
	var sc = sanitize_screen(s)
	if sc == null:
		return Rect2()
	return Rect2(sc.x, sc.y, sc.w, sc.h)


static func screen_by_id(layout, id):
	var lay = normalize_layout(layout)
	var key = String(id)
	if lay.local.id == key:
		return lay.local
	for s in lay.screens:
		if s.id == key:
			return s
	return null


static func all_screens(layout):
	var lay = normalize_layout(layout)
	var out = [lay.local]
	for s in lay.screens:
		out.append(s)
	return out


static func overlaps(a, b, tol = 0.0):
	var ra = rect(a)
	var rb = rect(b)
	var ox = min(ra.position.x + ra.size.x, rb.position.x + rb.size.x) - max(ra.position.x, rb.position.x)
	var oy = min(ra.position.y + ra.size.y, rb.position.y + rb.size.y) - max(ra.position.y, rb.position.y)
	return ox > tol and oy > tol


static func _overlaps_any(cand, screens, ignore_id):
	for s in screens:
		if String(s.id) == String(ignore_id):
			continue
		if overlaps(cand, s):
			return true
	return false


# Direccion de a hacia b si estan pegadas por un borde con solape > 0; "" si no.
# El offset se mide desde el inicio de la arista de a (arriba en E/O, izquierda
# en N/S) y puede ser negativo si b empieza antes.
static func contact(a, b, tol = TOUCH_TOL):
	var ra = rect(a)
	var rb = rect(b)
	var overlap_y = min(ra.position.y + ra.size.y, rb.position.y + rb.size.y) - max(ra.position.y, rb.position.y)
	var overlap_x = min(ra.position.x + ra.size.x, rb.position.x + rb.size.x) - max(ra.position.x, rb.position.x)
	if overlap_y > 0.0 and abs(rb.position.x - (ra.position.x + ra.size.x)) <= tol:
		return _contact_desc("east", max(ra.position.y, rb.position.y) - ra.position.y, overlap_y, ra.size.y)
	if overlap_y > 0.0 and abs((rb.position.x + rb.size.x) - ra.position.x) <= tol:
		return _contact_desc("west", max(ra.position.y, rb.position.y) - ra.position.y, overlap_y, ra.size.y)
	if overlap_x > 0.0 and abs(rb.position.y - (ra.position.y + ra.size.y)) <= tol:
		return _contact_desc("south", max(ra.position.x, rb.position.x) - ra.position.x, overlap_x, ra.size.x)
	if overlap_x > 0.0 and abs((rb.position.y + rb.size.y) - ra.position.y) <= tol:
		return _contact_desc("north", max(ra.position.x, rb.position.x) - ra.position.x, overlap_x, ra.size.x)
	return {}


static func _contact_desc(direction, offset, span, edge_len):
	return {
		"direction": direction,
		"offset": offset,
		"span": span,
		"overlap": span,
		"percent": offset / edge_len if edge_len > 0.0 else 0.0,
	}


static func _pct(v, length):
	if length <= 0.0:
		return 0.0
	return clamp(100.0 * float(v) / float(length), 0.0, 100.0)


# Tramo COMPARTIDO entre a y b en porcentajes (0..100) de cada borde, en el formato
# de los `links` de Deskflow: left(80,100) = cupid(0,20). `local` es el rango sobre el
# borde de a y `peer` sobre el borde opuesto de b. {} si no hay contacto.
static func link_ranges(a, b):
	var c = contact(a, b)
	if c.empty():
		return {}
	var ra = rect(a)
	var rb = rect(b)
	var vertical = String(c.direction) == "east" or String(c.direction) == "west"
	var a_len = ra.size.y if vertical else ra.size.x
	var b_len = rb.size.y if vertical else rb.size.x
	var span = float(c.span)
	var a0 = float(c.offset)
	var b0 = (max(ra.position.y, rb.position.y) - rb.position.y) if vertical \
		else (max(ra.position.x, rb.position.x) - rb.position.x)
	return {
		"direction": String(c.direction),
		"local_range": [_pct(a0, a_len), _pct(a0 + span, a_len)],
		"peer_range": [_pct(b0, b_len), _pct(b0 + span, b_len)],
		"overlap_pct": _pct(span, a_len),
	}


static func direction_of(a, b):
	var c = contact(a, b)
	return String(c.get("direction", "")) if not c.empty() else ""


# --- Imantado al soltar --------------------------------------------------------

# Devuelve {x, y, snapped, target, side}. Si no hay candidato valido (sin
# solaparse con ninguna otra pantalla) devuelve la posicion propuesta sin imantar.
static func snap(screens, id, px, py, min_contact = -1.0):
	var mc = MIN_CONTACT if min_contact < 0.0 else float(min_contact)
	var clean = sanitize_screens(screens)
	var moving = null
	for s in clean:
		if s.id == String(id):
			moving = s
	if moving == null:
		return {"x": float(px), "y": float(py), "snapped": false, "target": "", "side": ""}
	var best = null
	for oi in range(clean.size()):
		var o = clean[oi]
		if o.id == moving.id:
			continue
		for si in range(SIDE_ORDER.size()):
			var cand = _candidate(moving, o, SIDE_ORDER[si], float(px), float(py), mc)
			if cand == null:
				continue
			if _overlaps_any(cand, clean, moving.id):
				continue
			var cost = abs(cand.x - float(px)) + abs(cand.y - float(py))
			var better = best == null or cost < best.cost - 0.0001
			if not better and best != null and abs(cost - best.cost) <= 0.0001:
				better = oi < best.oi or (oi == best.oi and si < best.si)
			if better:
				best = {"x": cand.x, "y": cand.y, "cost": cost, "oi": oi, "si": si,
					"target": o.id, "side": SIDE_ORDER[si]}
	if best == null:
		return {"x": float(px), "y": float(py), "snapped": false, "target": "", "side": ""}
	return {"x": best.x, "y": best.y, "snapped": true, "target": best.target, "side": best.side}


# Posicion candidata pegando `moving` a `o` por `side`, con la coordenada libre
# recortada para conservar un contacto >= mc y lo mas cerca posible de (px, py).
# null si el contacto minimo no cabe.
static func _candidate(moving, o, side, px, py, mc):
	var mw = moving.w
	var mh = moving.h
	var ox = o.x
	var oy = o.y
	var ow = o.w
	var oh = o.h
	if side == "east" or side == "west":
		if mh < mc or oh < mc:
			return null
		var lo = oy + mc - mh
		var hi = oy + oh - mc
		if lo > hi:
			return null
		var y = clamp(py, lo, hi)
		var x = ox + ow if side == "east" else ox - mw
		return {"x": x, "y": y, "w": mw, "h": mh}
	# south / north
	if mw < mc or ow < mc:
		return null
	var lo2 = ox + mc - mw
	var hi2 = ox + ow - mc
	if lo2 > hi2:
		return null
	var x2 = clamp(px, lo2, hi2)
	var y2 = oy + oh if side == "south" else oy - mh
	return {"x": x2, "y": y2, "w": mw, "h": mh}


# --- Colocacion por direccion y cadenas ---------------------------------------

# Coloca `id` pegado al ancla (local por defecto) por `direction`, centrado o con
# el offset pedido, y si el hueco esta ocupado sigue la cadena hacia afuera.
# Devuelve el layout actualizado. direction "none" deja la pantalla sin posicion
# (se corre fuera del conjunto actual). No solapa por construccion.
static func place_direction(layout, id, direction, offset = 0.0, anchor_id = ""):
	var lay = normalize_layout(layout)
	var key = String(id)
	var dir = String(direction)
	if key == lay.local.id or dir == "none":
		return _detach(lay, key)
	var moving = screen_by_id(lay, key)
	if moving == null:
		moving = default_screen(key, key, false)
		moving.peer = key
	var anchor = lay.local if String(anchor_id) == "" else screen_by_id(lay, anchor_id)
	if anchor == null:
		anchor = lay.local
	var cur = anchor
	var occupied = false
	var guard = 0
	while guard <= lay.screens.size() + 1:
		guard += 1
		var pos = _adjacent_pos(cur, moving, dir, offset)
		moving.x = pos.x
		moving.y = pos.y
		occupied = _overlaps_any(moving, _others(lay, key), key)
		if not occupied:
			break
		# Sigue la cadena hacia afuera: avanza al que ocupa ese hueco.
		var blocker = _blocker_after(cur, moving, _others(lay, key), dir)
		if blocker == null:
			break
		cur = blocker
	_store_screen(lay, moving)
	return lay


static func _others(lay, exclude_id):
	var out = []
	if lay.local.id != String(exclude_id):
		out.append(lay.local)
	for s in lay.screens:
		if s.id != String(exclude_id):
			out.append(s)
	return out


# Pantalla que ocupa el hueco hacia `direction` desde `cur` y por eso bloquea a
# `moving`; se usa para encadenar (colocar mas alla) en vez de solapar.
static func _blocker_after(cur, moving, screens, direction):
	var blocker = null
	for s in screens:
		if not overlaps(moving, s):
			continue
		match direction:
			"east":
				if s.x >= cur.x - TOUCH_TOL and (blocker == null or s.x < blocker.x):
					blocker = s
			"west":
				if s.x + s.w <= cur.x + cur.w + TOUCH_TOL and (blocker == null or s.x > blocker.x):
					blocker = s
			"south":
				if s.y >= cur.y - TOUCH_TOL and (blocker == null or s.y < blocker.y):
					blocker = s
			"north":
				if s.y + s.h <= cur.y + cur.h + TOUCH_TOL and (blocker == null or s.y > blocker.y):
					blocker = s
	return blocker


static func _adjacent_pos(anchor, moving, direction, offset):
	var ra = rect(anchor)
	var o = float(offset)
	match direction:
		"east":
			return Vector2(ra.position.x + ra.size.x, ra.position.y + o)
		"west":
			return Vector2(ra.position.x - moving.w, ra.position.y + o)
		"south":
			return Vector2(ra.position.x + o, ra.position.y + ra.size.y)
		"north":
			return Vector2(ra.position.x + o, ra.position.y - moving.h)
	return Vector2(anchor.x, anchor.y)


static func _store_screen(lay, screen):
	if screen.id == lay.local.id:
		lay.local = screen
		return
	for i in range(lay.screens.size()):
		if lay.screens[i].id == screen.id:
			lay.screens[i] = screen
			return
	lay.screens.append(screen)


# Suelta la pantalla del arreglo: la corre afuera del rectangulo que ocupan las
# demas, en fila, sin solaparse (queda "sin posicion" para la salida).
static func _detach(lay, id):
	if String(id) == lay.local.id:
		return lay
	var moving = screen_by_id(lay, id)
	if moving == null:
		return lay
	var others = _others(lay, id)
	var max_x = moving.x
	for s in others:
		max_x = max(max_x, s.x + s.w)
	moving.x = max_x + MIN_CONTACT
	_store_screen(lay, moving)
	return lay


# --- Salida --------------------------------------------------------------------

# Por cada vecino alcanzable desde la local: {id, label, direction, offset_px,
# offset_percent, span, via, peer}. `direction` es el borde de contacto con la
# pantalla local o con la cadena; `via` es el id del contacto inmediato.
static func output(layout):
	var lay = normalize_layout(layout)
	var out = []
	var visited = {lay.local.id: true}
	var queue = [lay.local]
	while not queue.empty():
		var cur = queue.pop_front()
		for s in lay.screens:
			if visited.has(s.id):
				continue
			var c = contact(cur, s)
			if c.empty():
				continue
			visited[s.id] = true
			out.append({
				"id": s.id,
				"label": s.label,
				"peer": s.peer,
				"direction": String(c.direction),
				"offset_px": float(c.offset),
				"offset_percent": float(c.percent),
				"span": float(c.span),
				"via": String(cur.id),
			})
			queue.append(s)
	_sort_output(out)
	return out


# Adyacencias completas {from, to, from_id, to_id, direction, offset_px, span}.
static func edges(layout):
	var lay = normalize_layout(layout)
	var screens = all_screens(lay)
	var out = []
	for i in range(screens.size()):
		for j in range(i + 1, screens.size()):
			var c = contact(screens[i], screens[j])
			if c.empty():
				continue
			out.append({
				"from": screens[i].id, "to": screens[j].id,
				"direction": String(c.direction),
				"offset_px": float(c.offset), "span": float(c.span),
			})
	return out


# Direcciones de todos los vecinos en el formato de host_directions (fuente unica
# de Pantalla y Teclado y mouse). Sólo las pantallas con contacto confirmado.
static func to_host_directions(layout):
	var out = {}
	for e in output(layout):
		out[String(e.id)] = {
			"direction": String(e.direction),
			"confirm": "confirmed",
			"mode": "extend",
			"link": "screen",
			"offset": float(e.offset_px),
		}
	return out


# Aristas locales {direction, peer} para regenerar la config del compartir
# teclado/mouse. Una por direccion (si dos vecinos reclaman el mismo borde, gana
# el id menor; el conflicto se reporta con conflicts()).
static func local_links(layout):
	var direct = []
	for e in output(layout):
		if String(e.via) != String(normalize_layout(layout).local.id):
			continue
		direct.append(e)
	_sort_ids(direct)
	var out = []
	var used = {}
	for e in direct:
		var d = String(e.direction)
		if used.has(d):
			continue
		used[d] = true
		out.append({"direction": d, "peer": String(e.peer)})
	return out


# Direcciones reclamadas por mas de un vecino DIRECTO de la local: [{direction,
# ids}]. Las cadenas legitimas (un vecino detras de otro) no son conflicto.
static func conflicts(layout):
	var local_id = String(normalize_layout(layout).local.id)
	var by_dir = {}
	for e in output(layout):
		if String(e.via) != local_id:
			continue
		var d = String(e.direction)
		if not by_dir.has(d):
			by_dir[d] = []
		by_dir[d].append(String(e.id))
	var out = []
	for d in DIRECTIONS:
		if by_dir.has(d) and by_dir[d].size() > 1:
			var ids = by_dir[d]
			ids.sort()
			out.append({"direction": d, "ids": ids})
	return out


# Vecinos sin posicion (sin contacto con la red de la local).
static func unplaced(layout):
	var lay = normalize_layout(layout)
	var placed = {}
	for e in output(lay):
		placed[String(e.id)] = true
	var out = []
	for s in lay.screens:
		if not placed.has(s.id):
			out.append(s.id)
	return out


# --- Serializacion -------------------------------------------------------------

static func to_json(layout):
	return JSON.print(normalize_layout(layout), "  ")


static func parse(text):
	var data = null
	if text is String and String(text).strip_edges() != "":
		data = JSON.parse(String(text)).result
	return normalize_layout(data)


# --- Utilidad ------------------------------------------------------------------

static func edge_of(direction):
	return String(EDGE_BY_DIRECTION.get(String(direction), ""))


static func valid_direction(direction):
	return DIRECTIONS.has(String(direction))


# Ordena por direccion cardinal (north,south,east,west) y luego id. Insercion
# manual: estable y sin depender de sort_custom desde una funcion static.
static func _sort_output(arr):
	var i = 1
	while i < arr.size():
		var cur = arr[i]
		var j = i - 1
		while j >= 0 and _output_less(cur, arr[j]):
			arr[j + 1] = arr[j]
			j -= 1
		arr[j + 1] = cur
		i += 1


static func _output_less(a, b):
	var da = String(a.direction)
	var db = String(b.direction)
	if da != db:
		return DIRECTIONS.find(da) < DIRECTIONS.find(db)
	return String(a.id) < String(b.id)


static func _sort_ids(arr):
	var i = 1
	while i < arr.size():
		var cur = arr[i]
		var j = i - 1
		while j >= 0 and String(cur.id) < String(arr[j].id):
			arr[j + 1] = arr[j]
			j -= 1
		arr[j + 1] = cur
		i += 1


static func selftest():
	var lay = normalize_layout({})
	assert(lay.local.id == LOCAL_ID and lay.local.local, "local por defecto")
	assert(lay.local.label == LOCAL_LABEL, "etiqueta local humana")
	assert(lay.screens.empty(), "sin vecinos por defecto")

	var s = sanitize_screen({"id": "h1", "label": "Tengu", "peer": "tengu",
		"x": "10", "y": "20", "w": 0, "h": -3})
	assert(s.w == DEFAULT_W and s.h == DEFAULT_H, "tamano invalido cae al default")
	assert(s.x == 10.0 and s.y == 20.0, "coordenadas numericas")
	assert(sanitize_screen("nope") == null, "pantalla no-diccionario")

	# Imantado: pega a la derecha de la local, sin solapar y con contacto.
	var base = {"local": {"id": "local", "label": "Este equipo", "local": true,
		"x": 0.0, "y": 0.0, "w": 1000.0, "h": 600.0},
		"screens": [{"id": "h1", "label": "Tengu", "peer": "tengu", "w": 800.0, "h": 500.0}]}
	var snapped = snap(all_screens(base), "h1", 980.0, 100.0)
	assert(snapped.snapped and snapped.target == "local" and snapped.side == "east", "imanta al borde local")
	var h1 = screen_by_id(base, "h1")
	h1.x = snapped.x
	h1.y = snapped.y
	assert(not overlaps(h1, screen_by_id(base, "local")), "sin solape")
	var c = contact(screen_by_id(base, "local"), h1)
	assert(not c.empty() and String(c.direction) == "east", "contacto este")
	assert(float(c.span) >= MIN_CONTACT, "contacto minimo")
	assert(h1.x == 1000.0, "borde pegado al local")

	# Desplazamiento libre a lo largo del borde (no solo centrado).
	var low = snap(all_screens(base), "h1", 1000.0, 40.0)
	assert(abs(low.y - 40.0) < 0.001 or low.y <= 600.0 - MIN_CONTACT + 0.001, "alineacion libre en el borde")

	# Rechaza candidato que solaparia a otra pantalla y busca el siguiente.
	var crowded = {
		"local": {"id": "local", "label": "Este equipo", "local": true, "x": 0.0, "y": 0.0, "w": 1000.0, "h": 600.0},
		"screens": [
			{"id": "a", "peer": "a", "x": 1000.0, "y": 0.0, "w": 800.0, "h": 600.0},
			{"id": "b", "peer": "b", "x": 1000.0, "y": 100.0, "w": 200.0, "h": 200.0},
		],
	}
	var sn2 = snap(all_screens(crowded), "b", 1010.0, 100.0)
	assert(sn2.snapped, "imanta incluso con otra pantalla cerca")
	var b = screen_by_id(crowded, "b")
	b.x = sn2.x
	b.y = sn2.y
	assert(not overlaps(b, screen_by_id(crowded, "a")), "no solapa a la otra pantalla")
	assert(not overlaps(b, screen_by_id(crowded, "local")), "no solapa al local")

	# Salida: direccion y offset por vecino (local + cadena).
	var chain = {
		"local": {"id": "local", "label": "Este equipo", "local": true, "x": 0.0, "y": 0.0, "w": 1000.0, "h": 600.0},
		"screens": [
			{"id": "h1", "label": "Tengu", "peer": "tengu", "x": 1000.0, "y": 50.0, "w": 800.0, "h": 500.0},
			{"id": "h2", "label": "Cupido", "peer": "cupid", "x": 1800.0, "y": 80.0, "w": 800.0, "h": 500.0},
			{"id": "h3", "label": "Suelto", "peer": "solo", "x": 9000.0, "y": 9000.0, "w": 800.0, "h": 500.0},
		],
	}
	var outs = output(chain)
	assert(outs.size() == 2, "dos vecinos alcanzables")
	var o1 = _find_out(outs, "h1")
	var o2 = _find_out(outs, "h2")
	assert(String(o1.direction) == "east" and String(o1.via) == "local", "h1 directo al este")
	assert(String(o2.direction) == "east" and String(o2.via) == "h1", "h2 por la cadena")
	assert(float(o1.offset_px) == 50.0, "offset en px desde el borde")
	assert(abs(float(o1.offset_percent) - 50.0 / 600.0) < 0.0001, "offset en porcentaje")
	assert(unplaced(chain) == ["h3"], "el suelto queda sin posicion")

	var dirs = to_host_directions(chain)
	assert(dirs.size() == 2 and String(dirs.h1.direction) == "east"
		and String(dirs.h2.confirm) == "confirmed" and not dirs.has("h3"), "host_directions de la cadena")
	assert(local_links(chain).size() == 1 and String(local_links(chain)[0].peer) == "tengu", "links locales")
	assert(edges(chain).size() == 2, "aristas de la cadena")

	# Colocar por direccion: sin solape y determinista.
	var placed = place_direction({"local": chain.local, "screens": []}, "h1", "west")
	var ph = screen_by_id(placed, "h1")
	assert(ph.x + ph.w == 0.0, "colocar al oeste pega el borde derecho al local")
	assert(not overlaps(ph, placed.local), "colocar sin solape")
	assert(String(output(placed)[0].direction) == "west", "salida oeste")
	var same = place_direction({"local": chain.local, "screens": []}, "h1", "west")
	assert(to_json(placed) == to_json(same), "colocar determinista")

	# Colocar dos al mismo borde: el segundo se encadena, sin solape.
	var two = place_direction({"local": chain.local, "screens": []}, "h1", "east")
	two = place_direction(two, "h2", "east")
	var a2 = screen_by_id(two, "h1")
	var b2 = screen_by_id(two, "h2")
	assert(not overlaps(a2, b2) and not overlaps(a2, two.local) and not overlaps(b2, two.local), "cadena sin solape")
	assert(b2.x >= a2.x + a2.w - 0.001, "el segundo queda mas al este")
	assert(conflicts(two).empty(), "sin conflictos de borde")

	# Serializacion ida y vuelta y determinismo.
	var rt = parse(to_json(two))
	assert(to_json(rt) == to_json(two), "json ida y vuelta")
	assert(valid_direction("north") and not valid_direction("up"), "direcciones validas")
	assert(edge_of("north") == "up" and edge_of("west") == "left", "bordes deskflow")
	return true


static func _find_out(outs, id):
	for e in outs:
		if String(e.id) == String(id):
			return e
	return null


func run_selftest():
	return selftest()
