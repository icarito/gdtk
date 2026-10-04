extends Reference

# K13h — Modelo PURO de las unidades tiled ("pantallas" del mosaico).
#
# Reemplaza el par `groups` (Array de Array de ids) + `split_weight` (id -> peso)
# por una lista de registros de unidad con eje. Única fuente de verdad del reparto:
#
#   units = [ {"id": leader_id, "members": [ids], "axis": "x"|"y",
#              "weights": {id: float}} ]
#
# - axis "x": los miembros se reparten a lo ancho (columnas).
# - axis "y": se reparten a lo alto (filas). El eje por default lo fija la
#   orientación del área útil (`default_axis`).
#
# Sin I/O ni procesos; todo entra y sale por parámetros. Lo usa shell.gd (con
# accessors de compatibilidad) y lo cubre tests/wm_units_test.gd.

const AXIS_X = "x"
const AXIS_Y = "y"


# Eje por orientación del área útil: portrait (alto > ancho) apila filas (Y);
# landscape reparte columnas (X).
static func default_axis(area):
	if area == null:
		return AXIS_X
	var r = Rect2(area)
	return AXIS_Y if r.size.y > r.size.x else AXIS_X


# Eje que impone el borde elegido: arriba/abajo -> Y; izquierda/derecha -> X.
static func axis_for_side(side):
	var s = String(side)
	if s == "top" or s == "bottom" or s == "above" or s == "below":
		return AXIS_Y
	return AXIS_X


static func _before_side(side):
	var s = String(side)
	return s == "left" or s == "top" or s == "above"


static func leader(unit):
	if unit == null or not unit.has("members") or unit["members"].empty():
		return -1
	return unit["members"][0]


# Índice de la unidad que contiene `id` (-1 si está suelta / no existe).
static func find(units, id):
	for i in range(units.size()):
		if units[i]["members"].has(id):
			return i
	return -1


static func has(units, id):
	return find(units, id) >= 0


static func unit_of(units, id):
	var i = find(units, id)
	return units[i] if i >= 0 else null


static func members_of(units, id):
	var u = unit_of(units, id)
	return u["members"] if u != null else []


static func axis_of(units, id, fallback = AXIS_X):
	var u = unit_of(units, id)
	return String(u["axis"]) if u != null else String(fallback)


static func weight_of(units, id, fallback = 1.0):
	var u = unit_of(units, id)
	if u == null:
		return fallback
	return float(u["weights"].get(id, 1.0))


static func set_weight(units, id, w):
	var u = unit_of(units, id)
	if u != null:
		u["weights"][id] = max(float(w), 0.001)
	return units


# Aplana las unidades al orden de la fila (`tiles`).
static func flatten(units):
	var out = []
	for u in units:
		out.append_array(u["members"])
	return out


# Saca `id` de su unidad. Si la unidad queda con un solo miembro, ese miembro
# vuelve a ser una unidad suelta (preservando su posición).
static func remove(units, id):
	for i in range(units.size() - 1, -1, -1):
		var u = units[i]
		var k = u["members"].find(id)
		if k >= 0:
			u["members"].remove(k)
			u["weights"].erase(id)
			if u["members"].size() < 2:
				units.remove(i)
				if u["members"].size() == 1:
					var m = u["members"][0]
					units.insert(i, {"id": m, "members": [m], "axis": AXIS_X, "weights": {m: 1.0}})
			break
	return units


# Deja `id` como unidad suelta en la posición `at` (al final si at < 0).
static func solo(units, id, at = -1, axis = AXIS_X):
	remove(units, id)
	var u = {"id": id, "members": [id], "axis": String(axis), "weights": {id: 1.0}}
	if at < 0 or at > units.size():
		units.append(u)
	else:
		units.insert(at, u)
	return units


# Extrae `id` de su unidad y la reinserta como unidad SOLA justo ANTES de la unidad de
# `anchor`. Si `anchor` no existe, la agrega al final; si `anchor` es el propio `id`,
# la deja donde estaba. Es la inserción en índice que usa el exposé al soltar una
# miniatura en un hueco: recalcula el índice DESPUÉS de extraer `id`, así insertar antes
# de una unidad posterior no se corre por el hueco que queda.
static func solo_before(units, id, anchor, axis = AXIS_X):
	var at = find(units, id)
	remove(units, id)
	var u = {"id": id, "members": [id], "axis": String(axis), "weights": {id: 1.0}}
	if anchor == id:
		units.insert(int(clamp(at, 0, units.size())), u)
		return units
	var ai = find(units, anchor)
	if ai < 0:
		units.append(u)
	else:
		units.insert(ai, u)
	return units


# Suma `id` a la unidad de `target`. `side` fija eje y orden:
#   left/right  -> eje X, antes/después de los miembros de target
#   top/bottom  -> eje Y, antes/después
# Si target no tiene unidad, se crea la unidad con ambos.
static func join(units, id, target, side):
	if id == target:
		return units
	var axis = axis_for_side(side)
	var before = _before_side(side)
	remove(units, id)
	var u = unit_of(units, target)
	if u == null:
		var members = [id, target] if before else [target, id]
		units.append({"id": members[0], "members": members, "axis": axis,
			"weights": {id: 1.0, target: 1.0}})
		return units
	u["axis"] = axis
	if not u["weights"].has(id):
		u["weights"][id] = 1.0
	if before:
		u["members"].insert(0, id)
	else:
		u["members"].append(id)
	u["id"] = u["members"][0]
	return units


# Mueve la unidad de `id` antes/después de la unidad de `anchor` (mismo orden de fila).
static func move_unit(units, id, anchor, before):
	var di = find(units, id)
	var ai = find(units, anchor)
	if di < 0 or ai < 0 or di == ai:
		return units
	var moved = units[di]
	units.remove(di)
	ai = find(units, anchor)
	if ai < 0:
		units.append(moved)
		return units
	if not before:
		ai += 1
	units.insert(int(clamp(ai, 0, units.size())), moved)
	return units


static func swap(units, a, b):
	if a >= 0 and b >= 0 and a < units.size() and b < units.size() and a != b:
		var t = units[a]
		units[a] = units[b]
		units[b] = t
	return units


# Rects locales de los miembros de UNA unidad, repartidos según su eje.
static func member_rects(unit, area, gap):
	var out = {}
	if unit == null:
		return out
	var members = unit["members"]
	var n = members.size()
	if n == 0:
		return out
	var a = Rect2(area)
	if n == 1:
		out[members[0]] = a
		return out
	var axis = String(unit.get("axis", AXIS_X))
	var weights = unit.get("weights", {})
	var total = 0.0
	for m in members:
		total += max(float(weights.get(m, 1.0)), 0.001)
	if total <= 0.0:
		total = float(n)
	var g = max(float(gap), 0.0)
	if axis == AXIS_Y:
		var avail_y = a.size.y - g * float(n + 1)
		var y = a.position.y + g
		for m in members:
			var h = avail_y * max(float(weights.get(m, 1.0)), 0.001) / total
			out[m] = Rect2(a.position.x, y, a.size.x, h)
			y += h + g
	else:
		var avail_x = a.size.x - g * float(n + 1)
		var x = a.position.x + g
		for m in members:
			var w = avail_x * max(float(weights.get(m, 1.0)), 0.001) / total
			out[m] = Rect2(x, a.position.y, w, a.size.y)
			x += w + g
	return out


static func serialize(units):
	var out = []
	for u in units:
		out.append({"members": u["members"].duplicate(), "axis": String(u["axis"]),
			"weights": u["weights"].duplicate()})
	return out


# Parseo tolerante del formato serializado. `area` fija el eje de las unidades
# que no lo traen (layouts viejos).
static func parse(data, area = null):
	var out = []
	if typeof(data) != TYPE_ARRAY:
		return out
	var def_axis = default_axis(area)
	for row in data:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var members = []
		for m in row.get("members", []):
			members.append(int(m))
		if members.empty():
			continue
		var axis = String(row.get("axis", def_axis))
		if axis != AXIS_Y:
			axis = AXIS_X
		var weights = {}
		var wraw = row.get("weights", {})
		if typeof(wraw) == TYPE_DICTIONARY:
			for k in wraw.keys():
				weights[int(k)] = float(wraw[k])
		for m in members:
			if not weights.has(m):
				weights[m] = 1.0
		out.append({"id": members[0], "members": members, "axis": axis, "weights": weights})
	return out


# Migración desde el layout clásico {tiles, groups, weights}. El eje por default
# lo fija la orientación del área.
static func from_legacy(tiles, groups, weights, area = null):
	var out = []
	var seen = {}
	var def_axis = default_axis(area)
	for id in tiles:
		if seen.has(id):
			continue
		var g = null
		for cand in groups:
			if cand.has(id):
				g = cand
				break
		if g != null:
			var members = []
			for m in g:
				if tiles.has(m) and not seen.has(m):
					members.append(m)
					seen[m] = true
			if members.size() >= 2:
				var w = {}
				for m in members:
					w[m] = float(weights.get(m, 1.0))
				out.append({"id": members[0], "members": members, "axis": def_axis, "weights": w})
			elif members.size() == 1:
				out.append({"id": members[0], "members": members, "axis": def_axis,
					"weights": {members[0]: 1.0}})
		else:
			out.append({"id": id, "members": [id], "axis": def_axis, "weights": {id: 1.0}})
			seen[id] = true
	return out


static func selftest():
	# Eje por orientación.
	assert(default_axis(Rect2(0, 0, 1280, 720)) == AXIS_X, "landscape -> X")
	assert(default_axis(Rect2(0, 0, 720, 1280)) == AXIS_Y, "portrait -> Y")
	assert(axis_for_side("left") == AXIS_X, "left -> X")
	assert(axis_for_side("right") == AXIS_X, "right -> X")
	assert(axis_for_side("top") == AXIS_Y, "top -> Y")
	assert(axis_for_side("bottom") == AXIS_Y, "bottom -> Y")

	# Solo + join por lado.
	var u = []
	solo(u, 1)
	solo(u, 2)
	assert(u.size() == 2 and leader(u[0]) == 1 and leader(u[1]) == 2, "dos solas")
	join(u, 2, 1, "right")
	assert(u.size() == 1, "join fusiona")
	assert(members_of(u, 1) == [1, 2], "right: target primero")
	assert(axis_of(u, 1) == AXIS_X, "right -> X")
	join(u, 3, 2, "left")
	assert(members_of(u, 1) == [3, 1, 2], "left inserta al inicio")
	join(u, 4, 3, "bottom")
	assert(axis_of(u, 1) == AXIS_Y, "bottom cambia eje a Y")
	assert(members_of(u, 1) == [3, 1, 2, 4], "bottom inserta al final")

	# Remove deja solas a las que quedan < 2.
	u = []
	join(u, 1, 2, "right")
	remove(u, 1)
	assert(u.size() == 1 and members_of(u, 2) == [2] and axis_of(u, 2) == AXIS_X, "remove deja sola")
	remove(u, 99)
	assert(u.size() == 1, "remove inexistente no rompe")

	# Move de unidades.
	u = []
	solo(u, 1)
	solo(u, 2)
	solo(u, 3)
	move_unit(u, 3, 1, true)
	assert(flatten(u) == [3, 1, 2], "mover antes")
	move_unit(u, 3, 2, false)
	assert(flatten(u) == [1, 2, 3], "mover despues")

	# Inserción como unidad sola antes de un ancla (lo que usa el exposé en un hueco).
	solo_before(u, 1, 3)
	assert(flatten(u) == [2, 1, 3], "solo_before antes del ancla")
	solo_before(u, 1, 1)
	assert(flatten(u) == [2, 1, 3], "solo_before con ancla propia deja igual")
	solo_before(u, 9, 99)
	assert(flatten(u) == [2, 1, 3, 9], "solo_before sin ancla al final")

	# Reparto por eje (misma partición que el layout del shell).
	var area = Rect2(10, 20, 100, 200)
	var unit = {"id": 1, "members": [1, 2], "axis": AXIS_X, "weights": {1: 1.0, 2: 1.0}}
	var r = member_rects(unit, area, 0.0)
	assert(r.size() == 2, "dos rects")
	assert(r[1].size.x == 50.0 and r[2].position.x == 60.0, "X mitades")
	assert(r[1].size.y == 200.0, "X alto completo")
	unit["axis"] = AXIS_Y
	r = member_rects(unit, area, 0.0)
	assert(r[1].size.y == 100.0 and r[2].position.y == 120.0, "Y mitades")
	assert(r[1].size.x == 100.0, "Y ancho completo")
	# Pesos.
	unit["axis"] = AXIS_X
	unit["weights"] = {1: 3.0, 2: 1.0}
	r = member_rects(unit, area, 0.0)
	assert(abs(r[1].size.x - 75.0) < 0.001 and abs(r[2].size.x - 25.0) < 0.001, "pesos 3:1")
	# Suelta = el área completa.
	r = member_rects({"members": [9], "axis": AXIS_X, "weights": {9: 1.0}}, area, 4.0)
	assert(r[9] == area, "sola ocupa el area")

	# Serialize / parse roundtrip.
	u = []
	join(u, 2, 1, "right")
	set_weight(u, 1, 2.5)
	var blob = serialize(u)
	var back = parse(blob, area)
	assert(back.size() == 1 and members_of(back, 1) == [1, 2], "roundtrip miembros")
	assert(abs(weight_of(back, 1) - 2.5) < 0.001, "roundtrip pesos")
	assert(parse([], area) == [], "parse vacio")
	assert(parse("x", area) == [], "parse no-array")
	# Layout viejo (sin axis) migra al eje de la orientación.
	var legacy = from_legacy([5, 6, 7], [[6, 7]], {6: 2.0, 7: 1.0}, Rect2(0, 0, 720, 1280))
	assert(legacy.size() == 2, "legacy dos unidades")
	assert(legacy[0]["members"] == [5], "legacy sola")
	assert(legacy[1]["members"] == [6, 7], "legacy grupo")
	assert(legacy[1]["axis"] == AXIS_Y, "legacy portrait -> Y")
	assert(abs(legacy[1]["weights"][6] - 2.0) < 0.001, "legacy pesos")
	assert(from_legacy([], [], {}, area) == [], "legacy vacio")
	return true


func run_selftest():
	return selftest()
