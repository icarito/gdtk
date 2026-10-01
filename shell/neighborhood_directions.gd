extends Reference

# Modelo puro de la brujula de pantalla compartida del Vecindario
# (SPEC-screen-share-compass.md §1, §12; tarea "Kilo A - modelo de compas (puro)").
# Dado un hid, guarda la direccion N/S/E/O (o "none"), el estado de confirmacion y
# el modo extend. Es puro: sin red, procesos, filesystem ni estado global; solo
# normaliza, serializa y detecta conflictos de borde. La direccion se guarda tal
# como la ve este equipo; el inverso se deriva con inverse() y no se persiste dos
# veces. `mirror` esta reservado y no es persistible en este corte.

const DIRECTIONS = ["north", "south", "east", "west"]
const ALL_DIRECTIONS = ["north", "south", "east", "west", "none"]
const CONFIRM_STATES = ["unconfirmed", "proposed", "confirmed"]

const _GVD_POSITIONS = {
	"north": "above",
	"south": "below",
	"east": "right",
	"west": "left",
}

const _GVD_TO_DIRECTION = {
	"above": "north",
	"below": "south",
	"right": "east",
	"left": "west",
}


static func valid_direction(d):
	return ALL_DIRECTIONS.has(String(d))


# Inverso segun la perspectiva unica: north<->south, east<->west, none->none.
static func inverse(d):
	match String(d):
		"north":
			return "south"
		"south":
			return "north"
		"east":
			return "west"
		"west":
			return "east"
		"none":
			return "none"
	return ""


# Direccion del compas -> `gvd --position`. none/desconocida -> "".
static func to_gvd_position(d):
	var k = String(d)
	return _GVD_POSITIONS[k] if _GVD_POSITIONS.has(k) else ""


# `gvd --position` -> direccion del compas. Desconocida -> "".
static func from_gvd_position(pos):
	var k = String(pos)
	return _GVD_TO_DIRECTION[k] if _GVD_TO_DIRECTION.has(k) else ""


# Normaliza una entrada de direccion a {direction, confirm, mode, link, updated}.
# Defaults: direction "none", confirm "unconfirmed", mode "extend", link "",
# updated 0. Valida los enums; mode sólo "extend" (mirror no es persistible).
static func sanitize_entry(entry):
	var out = {
		"direction": "none",
		"confirm": "unconfirmed",
		"mode": "extend",
		"link": "",
		"updated": 0,
	}
	if typeof(entry) != TYPE_DICTIONARY:
		return out
	var d = String(entry.get("direction", "none")).strip_edges()
	if ALL_DIRECTIONS.has(d):
		out.direction = d
	var c = String(entry.get("confirm", "unconfirmed")).strip_edges()
	if CONFIRM_STATES.has(c):
		out.confirm = c
	var m = String(entry.get("mode", "extend")).strip_edges()
	if m == "extend":
		out.mode = "extend"
	out.link = String(entry.get("link", "")).strip_edges()
	var raw = entry.get("updated", 0)
	var t = typeof(raw)
	var updated = 0
	if t == TYPE_INT or t == TYPE_REAL:
		updated = int(raw)
	elif t == TYPE_STRING and String(raw).is_valid_integer():
		updated = int(raw)
	out.updated = updated if updated >= 0 else 0
	return out


# Parsea JSON {"<hid>": {direction, confirm, mode, link, updated}}. Texto vacio,
# JSON invalido o raiz no-diccionario -> {}. Cada entrada pasa por sanitize_entry.
# No lanza excepciones.
static func parse(text):
	var out = {}
	var s = String(text).strip_edges()
	if s == "":
		return out
	var data = parse_json(s)
	if typeof(data) != TYPE_DICTIONARY:
		return out
	for k in data.keys():
		out[String(k)] = sanitize_entry(data[k])
	return out


# Serializa de forma DETERMINISTA: claves hid ordenadas y campos fijos por
# entrada. Cumple parse(to_json(x)) == x normalizado.
static func to_json(dict):
	if typeof(dict) != TYPE_DICTIONARY:
		return "{}"
	var keys = dict.keys()
	keys.sort()
	var parts = PoolStringArray()
	for k in keys:
		parts.append(to_json(String(k)) + ":" + _entry_json(sanitize_entry(dict[k])))
	return "{" + parts.join(",") + "}"


# Copia base y aplica overrides entrada por entrada; las claves ausentes en base
# se agregan. Todo pasa por sanitize_entry.
static func merge(base, overrides):
	var out = {}
	if typeof(base) == TYPE_DICTIONARY:
		for k in base.keys():
			out[String(k)] = sanitize_entry(base[k])
	if typeof(overrides) == TYPE_DICTIONARY:
		for k in overrides.keys():
			out[String(k)] = sanitize_entry(overrides[k])
	return out


# Conflictos de borde: direcciones != "none" reclamadas por mas de un hid.
# Cada elemento {"direction": <dir>, "hids": [<hid ordenado>]}. Sin conflictos -> [].
static func edge_conflicts(dict):
	var out = []
	if typeof(dict) != TYPE_DICTIONARY:
		return out
	var by_dir = {}
	for k in dict.keys():
		var e = sanitize_entry(dict[k])
		if e.direction == "none":
			continue
		if not by_dir.has(e.direction):
			by_dir[e.direction] = []
		by_dir[e.direction].append(String(k))
	for d in DIRECTIONS:
		if by_dir.has(d) and by_dir[d].size() > 1:
			var hids = by_dir[d]
			hids.sort()
			out.append({"direction": d, "hids": hids})
	return out


static func _entry_json(e):
	return "{" \
		+ "\"direction\":" + to_json(e.direction) + "," \
		+ "\"confirm\":" + to_json(e.confirm) + "," \
		+ "\"mode\":" + to_json(e.mode) + "," \
		+ "\"link\":" + to_json(e.link) + "," \
		+ "\"updated\":" + str(int(e.updated)) + "}"


static func selftest():
	var ok = true
	ok = ok and valid_direction("north") and valid_direction("none") and not valid_direction("up")
	ok = ok and inverse("north") == "south" and inverse("south") == "north"
	ok = ok and inverse("east") == "west" and inverse("west") == "east"
	ok = ok and inverse("none") == "none" and inverse("up") == ""
	ok = ok and to_gvd_position("north") == "above" and to_gvd_position("east") == "right"
	ok = ok and to_gvd_position("none") == "" and to_gvd_position("up") == ""
	ok = ok and from_gvd_position("above") == "north" and from_gvd_position("left") == "west"
	ok = ok and from_gvd_position("center") == ""
	ok = ok and parse("no-json").empty() and parse("").empty() and parse("[]").empty()

	var dirty = sanitize_entry({"direction": "up", "confirm": "maybe", "mode": "mirror",
		"link": 42, "updated": -5})
	ok = ok and dirty.direction == "none" and dirty.confirm == "unconfirmed"
	ok = ok and dirty.mode == "extend" and dirty.link == "42" and dirty.updated == 0

	var base = {"h1": {"direction": "east", "confirm": "confirmed", "mode": "extend",
		"link": "gvd", "updated": 10}}
	var merged = merge(base, {"h1": {"direction": "west"}, "h2": {"direction": "north"}})
	ok = ok and merged.h1.direction == "west" and merged.h1.mode == "extend"
	ok = ok and merged.h2.direction == "north" and merged.h2.confirm == "unconfirmed"

	# Dictionary == no es comparacion profunda en Godot 3: se compara por JSON.
	var rt = parse(to_json(base))
	ok = ok and to_json(rt) == to_json(base)
	var conflicts = edge_conflicts({"h1": {"direction": "east"}, "h2": {"direction": "east"}})
	ok = ok and conflicts.size() == 1 and conflicts[0].direction == "east"
	ok = ok and conflicts[0].hids == ["h1", "h2"]
	ok = ok and edge_conflicts({"h1": {"direction": "east"}, "h2": {"direction": "none"}}).empty()

	assert(ok, "selftest de neighborhood_directions")
	return ok


func run_selftest():
	return selftest()
