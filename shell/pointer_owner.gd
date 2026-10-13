extends Reference

# Resolutor PURO del dueño del puntero (SPEC-multiview-portal.md §8, "seguir el
# puntero"). Cuando InputCapture de Deskflow se activa, el puntero local quedó
# pegado al borde por el que cruzó; mapear esa última posición local a (borde más
# cercano + fracción a lo largo del borde) y cruzarla con los rangos [lo,hi] del
# layout de Pantallas dice QUÉ vecino se está controlando.
#
# Sin I/O, sin procesos, sin nodos ni estado global: el Frame lo consulta con
# valores ya cacheados y nunca bloquea el hilo de render.
#
#   `links`:    [{direction, peer, local_range:[lo,hi]}] — los mismos que arma
#               shell._settings_deskflow_links() desde SCREEN_LAYOUT.link_ranges().
#               `direction` en north/south/east/west; `local_range` en porcentajes
#               0..100 a lo largo del borde.
#   `disabled`: direcciones que NO capturan (gvd extendido / vecino ausente), con
#               la misma semántica que GVD_LAUNCH.capture_ranges().

# Orden fijo de bordes para desempatar el "borde más cercano" de forma
# determinista (mismo orden de borde que usa `capture_ranges`: west, east, north,
# south). En un empate exacto gana el primero de la lista.
const EDGE_ORDER = ["west", "east", "north", "south"]
const _EPS = 0.0001


# Devuelve {"peer": <peer>, "direction": <direction>} o {} si el puntero no está
# sobre un borde con vecino que capture. `pos` y `viewport` son Vector2 en
# coordenadas de ventana.
static func owner_at(pos, viewport, links, disabled = []):
	if typeof(pos) != TYPE_VECTOR2 or typeof(viewport) != TYPE_VECTOR2:
		return {}
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return {}
	if typeof(links) != TYPE_ARRAY:
		return {}
	var off = _disabled_set(disabled)
	var edge = _nearest_edge(pos, viewport)
	if edge == "" or off.has(edge):
		return {}
	var cands = _candidates(links, edge)
	if cands.empty():
		return {}
	var frac = _along_edge_fraction(pos, viewport, edge)
	var hit = _first_containing(cands, frac)
	var chosen = hit if hit != null else _nearest(cands, frac)
	if chosen == null:
		return {}
	return {"peer": String(chosen.peer), "direction": edge}


# Borde más cercano a `pos`. Distancias euclídeas por eje: west = pos.x,
# east = viewport.x - pos.x, north = pos.y, south = viewport.y - pos.y. Empate
# exacto -> primer borde de EDGE_ORDER.
static func _nearest_edge(pos, viewport):
	var dist = {
		"west": pos.x,
		"east": viewport.x - pos.x,
		"north": pos.y,
		"south": viewport.y - pos.y,
	}
	var best = ""
	var best_d = 0.0
	for e in EDGE_ORDER:
		var d = float(dist[e])
		if best == "" or d < best_d:
			best = e
			best_d = d
	return best


# Fracción 0..100 a lo largo del borde: west/east -> pos.y/viewport.y; north/south
# -> pos.x/viewport.x (clamp a 0..100 para calzar con `local_range`).
static func _along_edge_fraction(pos, viewport, edge):
	var f = 0.0
	if edge == "west" or edge == "east":
		f = pos.y / viewport.y * 100.0
	else:
		f = pos.x / viewport.x * 100.0
	return clamp(f, 0.0, 100.0)


# Links que pertenecen a `edge`, con peer no vacío. El rango se normaliza a [lo,hi]
# con lo <= hi. Un link sin `local_range` (o inválido) cubre todo el borde, igual
# que el default 0..100 de capture_ranges.
static func _candidates(links, edge):
	var out = []
	for l in links:
		if typeof(l) != TYPE_DICTIONARY:
			continue
		var d = String(l.get("direction", "")).strip_edges().to_lower()
		if d != edge:
			continue
		var p = String(l.get("peer", "")).strip_edges()
		if p == "":
			continue
		out.append({"peer": p, "rng": _range_of(l)})
	return out


static func _range_of(l):
	var lr = l.get("local_range")
	if typeof(lr) == TYPE_ARRAY and lr.size() >= 2:
		var lo = clamp(float(lr[0]), 0.0, 100.0)
		var hi = clamp(float(lr[1]), 0.0, 100.0)
		if lo > hi:
			var t = lo
			lo = hi
			hi = t
		return [lo, hi]
	return [0.0, 100.0]


# Primer candidato cuyo rango contiene `frac` (inclusive en ambos extremos: en el
# borde exacto varios pueden contenerlo). Empate -> peer ascendente.
static func _first_containing(cands, frac):
	var best = null
	for c in cands:
		var r = c.rng
		if frac >= float(r[0]) - _EPS and frac <= float(r[1]) + _EPS:
			if best == null or String(c.peer) < String(best.peer):
				best = c
	return best


# Candidato con el rango más cercano a `frac` (distancia 0 si lo contiene). Empate
# -> peer ascendente.
static func _nearest(cands, frac):
	var best = null
	var best_d = 0.0
	for c in cands:
		var d = _range_distance(c.rng, frac)
		if best == null or d < best_d - _EPS \
				or (abs(d - best_d) <= _EPS and String(c.peer) < String(best.peer)):
			best = c
			best_d = d
	return best


static func _range_distance(rng, frac):
	var lo = float(rng[0])
	var hi = float(rng[1])
	if frac < lo:
		return lo - frac
	if frac > hi:
		return frac - hi
	return 0.0


static func _disabled_set(disabled):
	var out = {}
	if typeof(disabled) == TYPE_ARRAY:
		for d in disabled:
			var s = String(d).strip_edges().to_lower()
			if s != "":
				out[s] = true
	return out


static func _matches(res, peer, direction):
	return typeof(res) == TYPE_DICTIONARY \
		and String(res.get("peer", "")) == peer \
		and String(res.get("direction", "")) == direction


static func selftest():
	var ok = true
	var vp = Vector2(1000, 800)

	# Un único link cubriendo todo el borde: cada dirección cardinal.
	var east = [{"direction": "east", "peer": "cupid", "local_range": [0, 100]}]
	ok = ok and _matches(owner_at(Vector2(999, 400), vp, east), "cupid", "east")
	var west = [{"direction": "west", "peer": "tengu", "local_range": [0, 100]}]
	ok = ok and _matches(owner_at(Vector2(1, 400), vp, west), "tengu", "west")
	var north = [{"direction": "north", "peer": "bastion", "local_range": [0, 100]}]
	ok = ok and _matches(owner_at(Vector2(500, 1), vp, north), "bastion", "north")
	var south = [{"direction": "south", "peer": "ana", "local_range": [0, 100]}]
	ok = ok and _matches(owner_at(Vector2(500, 799), vp, south), "ana", "south")

	# Dos pares en el MISMO borde por tramos: gana el tramo que contiene la
	# fracción (0..50 -> b, 50..100 -> a); en el borde exacto 50 ambos contienen y
	# gana el peer ascendente ("a").
	var split = [
		{"direction": "east", "peer": "b", "local_range": [0, 50]},
		{"direction": "east", "peer": "a", "local_range": [50, 100]},
	]
	ok = ok and _matches(owner_at(Vector2(999, 80), vp, split), "b", "east")
	ok = ok and _matches(owner_at(Vector2(999, 720), vp, split), "a", "east")
	ok = ok and _matches(owner_at(Vector2(999, 400), vp, split), "a", "east")

	# El borde más cercano manda aunque el link del borde lejano exista.
	var two = [
		{"direction": "east", "peer": "e", "local_range": [0, 100]},
		{"direction": "west", "peer": "w", "local_range": [0, 100]},
	]
	ok = ok and _matches(owner_at(Vector2(10, 400), vp, two), "w", "west")
	ok = ok and _matches(owner_at(Vector2(990, 400), vp, two), "e", "east")

	# Dirección deshabilitada (gvd extendido o vecino ausente): sin dueño. La
	# comparación normaliza mayúsculas.
	ok = ok and owner_at(Vector2(999, 400), vp, east, ["east"]).empty()
	ok = ok and owner_at(Vector2(999, 400), vp, east, ["EAST"]).empty()

	# Borde sin link: sin dueño.
	ok = ok and owner_at(Vector2(500, 1), vp, east).empty()

	# Si ningún tramo contiene la fracción, gana el más cercano.
	var far = [{"direction": "east", "peer": "z", "local_range": [60, 100]}]
	ok = ok and _matches(owner_at(Vector2(999, 80), vp, far), "z", "east")

	# Empate de distancia -> peer ascendente.
	var tie = [
		{"direction": "east", "peer": "z", "local_range": [60, 100]},
		{"direction": "east", "peer": "a", "local_range": [60, 100]},
	]
	ok = ok and _matches(owner_at(Vector2(999, 80), vp, tie), "a", "east")

	# Link sin local_range cubre todo el borde (igual que capture_ranges).
	var norange = [{"direction": "east", "peer": "full"}]
	ok = ok and _matches(owner_at(Vector2(999, 400), vp, norange), "full", "east")

	# Entradas inválidas / vacías -> {}.
	ok = ok and owner_at(Vector2(999, 400), Vector2(0, 0), east).empty()
	ok = ok and owner_at(Vector2(999, 400), Vector2(-1, 800), east).empty()
	ok = ok and owner_at("nope", vp, east).empty()
	ok = ok and owner_at(Vector2(999, 400), vp, "nope").empty()
	ok = ok and owner_at(Vector2(999, 400), vp, []).empty()
	ok = ok and owner_at(Vector2(999, 400), vp, [{"direction": "east", "peer": ""}]).empty()

	assert(ok, "selftest de pointer_owner")
	return ok


func run_selftest():
	return selftest()
