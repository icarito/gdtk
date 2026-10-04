extends Reference

# Fase B (SPEC-embedded-multi-output.md §4): modelo PURO del layout de salidas del
# compositor embebido. Sin I/O, sin procesos, sin nodos ni estado global.
#
# Es la fuente unica de descriptores de salida y de la asignacion ventana ->
# salida. Host/shell lo cablea; aqui solo se normaliza, valida, ancla N/S/E/O,
# convierte coordenadas globales/locales, resuelve el cruce de borde y retira
# salidas devolviendo sus ventanas a la principal.
#
# Reglas (spec §4):
#   - siempre existe exactamente una salida primary;
#   - `rect` usa coordenadas logicas globales del compositor embebido;
#   - las secundarias se anclan N/S/E/O a la principal y no se solapan;
#   - cada ventana pertenece a una salida; no se duplica entre salidas;
#   - al retirar una salida sus ventanas vuelven a la principal.
#
# Vocabulario: el modelo no produce texto visible; los ids son internos.

const VERSION = 1

const PRIMARY_ID = "primary"
const KIND_PHYSICAL = "physical"
const KIND_REMOTE = "remote"
const TARGET_MAIN = "main_viewport"
const TARGET_OFFSCREEN = "offscreen"

const DIRECTIONS = ["north", "south", "east", "west"]

const DEFAULT_W = 1920.0
const DEFAULT_H = 1080.0


# --- Numeros y rects -----------------------------------------------------------

static func _num(v, fallback):
	var t = typeof(v)
	if t == TYPE_INT or t == TYPE_REAL:
		return float(v)
	if t == TYPE_STRING and String(v).is_valid_float():
		return float(v)
	return float(fallback)


# Rect2 | {x,y,w,h} | {x,y,width,height} | [x,y,w,h] -> Rect2; null si no se puede.
static func _to_rect(v):
	if typeof(v) == TYPE_RECT2:
		return Rect2(v)
	if typeof(v) == TYPE_DICTIONARY:
		return Rect2(
			_num(v.get("x", 0.0), 0.0),
			_num(v.get("y", 0.0), 0.0),
			_num(v.get("w", v.get("width", 0.0)), 0.0),
			_num(v.get("h", v.get("height", 0.0)), 0.0))
	if typeof(v) == TYPE_ARRAY and v.size() == 4:
		return Rect2(_num(v[0], 0.0), _num(v[1], 0.0), _num(v[2], 0.0), _num(v[3], 0.0))
	return null


static func rect_of(output):
	if typeof(output) == TYPE_DICTIONARY and output.has("rect"):
		return _to_rect(output.rect)
	return _to_rect(output)


# --- Validacion de vocabulario -------------------------------------------------

# "primary" o "<kind>:<hid>" con hid no vacio, sin espacios ni '/'.
static func valid_output_id(id):
	var s = String(id)
	if s != s.strip_edges() or s == "":
		return false
	if s == PRIMARY_ID:
		return true
	for kind in [KIND_REMOTE, KIND_PHYSICAL]:
		var pre = kind + ":"
		if s.begins_with(pre):
			var hid = s.substr(pre.length(), s.length())
			return hid != "" and hid.find(" ") < 0 and hid.find("/") < 0
	return false


static func valid_direction(direction):
	return DIRECTIONS.has(String(direction))


# --- Descriptor ----------------------------------------------------------------

static func default_primary(rect = null):
	var r = Rect2(0.0, 0.0, DEFAULT_W, DEFAULT_H)
	if rect != null:
		var rr = _to_rect(rect)
		if rr != null and rr.size.x > 0.0 and rr.size.y > 0.0:
			r = rr
	return {
		"id": PRIMARY_ID,
		"kind": KIND_PHYSICAL,
		"rect": r,
		"scale": 1.0,
		"primary": true,
		"enabled": true,
		"target": TARGET_MAIN,
		"peer": "",
		"direction": "",
	}


# Descriptor canonico o null si es invalido (id, rect, escala, kind o direction).
# Una no-principal puede omitir `direction` (se permite "" para layouts guardados);
# una direccion presente que no sea N/S/E/O se rechaza.
static func sanitize_output(o):
	if typeof(o) != TYPE_DICTIONARY:
		return null
	var id = String(o.get("id", "")).strip_edges()
	if not valid_output_id(id):
		return null
	var is_primary = bool(o.get("primary", false)) or id == PRIMARY_ID
	var r = _to_rect(o.get("rect", null))
	if r == null or r.size.x <= 0.0 or r.size.y <= 0.0:
		return null
	var dir = String(o.get("direction", "")).strip_edges()
	if dir != "" and not valid_direction(dir):
		return null
	var sc = _num(o.get("scale", 1.0), 1.0)
	if sc <= 0.0:
		return null
	var kind = String(o.get("kind", ""))
	if kind == "":
		kind = KIND_PHYSICAL if is_primary else KIND_REMOTE
	if kind != KIND_PHYSICAL and kind != KIND_REMOTE:
		return null
	var target = String(o.get("target", ""))
	if target == "":
		target = TARGET_MAIN if is_primary else TARGET_OFFSCREEN
	return {
		"id": id,
		"kind": kind,
		"rect": r,
		"scale": sc,
		"primary": is_primary,
		"enabled": bool(o.get("enabled", true)),
		"target": target,
		"peer": String(o.get("peer", "")).strip_edges(),
		"direction": dir,
	}


# --- Layout --------------------------------------------------------------------

static func _has_id(outputs, id):
	for o in outputs:
		if String(o.id) == String(id):
			return true
	return false


# Layout canonico {version, outputs:[descriptor...], windows:{id -> output_id}}.
# Garantiza exactamente una primary (la primera marcada; si no hay, crea la
# default). Los ids repetidos se descartan y las ventanas huerfanas vuelven a la
# principal.
static func normalize_layout(data):
	if typeof(data) != TYPE_DICTIONARY:
		data = {}
	var outs = []
	var seen = {}
	var prim = null
	var raw = data.get("outputs", [])
	if typeof(raw) == TYPE_ARRAY:
		for e in raw:
			var o = sanitize_output(e)
			if o == null or seen.has(o.id):
				continue
			seen[o.id] = true
			if o.primary:
				if prim == null:
					prim = o
					outs.append(o)
					continue
				# Primary extra: se degrada si puede ubicarse, si no se descarta.
				if o.direction == "" or not valid_direction(o.direction):
					seen.erase(o.id)
					continue
				o.primary = false
				if String(o.id).begins_with(KIND_REMOTE + ":"):
					o.kind = KIND_REMOTE
					o.target = TARGET_OFFSCREEN
				outs.append(o)
				continue
			outs.append(o)
	if prim == null:
		prim = default_primary()
		outs.push_front(prim)
		seen[prim.id] = true
	for o in outs:
		o.primary = String(o.id) == String(prim.id)
		if o.primary:
			o.kind = KIND_PHYSICAL
			o.target = TARGET_MAIN
			o.direction = ""
	var ordered = [prim]
	for o in outs:
		if String(o.id) != String(prim.id):
			ordered.append(o)
	var win = {}
	var raw_w = data.get("windows", {})
	if typeof(raw_w) == TYPE_DICTIONARY:
		for k in raw_w.keys():
			var wid = String(k).strip_edges()
			if wid == "":
				continue
			var oid = String(raw_w[k]).strip_edges()
			if not _has_id(ordered, oid):
				oid = String(prim.id)
			win[wid] = oid
	return {"version": VERSION, "outputs": ordered, "windows": win}


static func primary_id(layout):
	return String(normalize_layout(layout).outputs[0].id)


static func primary_output(layout):
	return normalize_layout(layout).outputs[0]


static func output_by_id(layout, id):
	var lay = normalize_layout(layout)
	var key = String(id)
	for o in lay.outputs:
		if String(o.id) == key:
			return o
	return null


static func has_output(layout, id):
	return output_by_id(layout, id) != null


static func output_count(layout):
	return normalize_layout(layout).outputs.size()


static func primary_count(layout):
	var n = 0
	for o in normalize_layout(layout).outputs:
		if o.primary:
			n += 1
	return n


static func enabled_outputs(layout):
	var out = []
	for o in normalize_layout(layout).outputs:
		if o.enabled:
			out.append(o)
	return out


# --- Geometria -----------------------------------------------------------------

static func overlaps(a, b):
	var ra = rect_of(a)
	var rb = rect_of(b)
	if ra == null or rb == null:
		return false
	return ra.intersects(rb, false)


static func any_overlap(outputs):
	if typeof(outputs) != TYPE_ARRAY:
		return false
	for i in range(outputs.size()):
		for j in range(i + 1, outputs.size()):
			if overlaps(outputs[i], outputs[j]):
				return true
	return false


# Punto global -> salida que lo contiene (semiabierto: borde inf. incluido, sup.
# excluido). "" si cae en un hueco o en una salida deshabilitada.
static func output_at(layout, point):
	for o in normalize_layout(layout).outputs:
		if o.enabled and contains(o, point):
			return String(o.id)
	return ""


static func contains(output, point):
	var o = sanitize_output(output)
	if o == null:
		return false
	var r = o.rect
	var p = Vector2(point)
	return p.x >= r.position.x and p.x < r.end.x and p.y >= r.position.y and p.y < r.end.y


static func global_to_local(output, point):
	var o = sanitize_output(output)
	if o == null:
		return null
	return Vector2(point) - o.rect.position


static func local_to_global(output, point):
	var o = sanitize_output(output)
	if o == null:
		return null
	return Vector2(point) + o.rect.position


# Cruce de borde: mueve el punto global por `motion` y decide si entro en otra
# salida. Devuelve {crossed, from, to, global, local}. `local` es la posicion en
# la salida de destino (o en `from` si no cruzo).
static func cross(layout, output_id, point, motion):
	var lay = normalize_layout(layout)
	var from = output_by_id(lay, output_id)
	if from == null:
		return {"crossed": false, "from": String(output_id), "to": "",
			"global": Vector2(point), "local": null}
	var g = Vector2(point) + Vector2(motion)
	var target = output_at(lay, g)
	if target == "" or target == String(from.id):
		return {"crossed": false, "from": String(from.id), "to": "",
			"global": g, "local": global_to_local(from, g)}
	return {"crossed": true, "from": String(from.id), "to": target,
		"global": g, "local": global_to_local(output_by_id(lay, target), g)}


# --- Anclaje N/S/E/O -----------------------------------------------------------

static func _adjacent_rect(anchor_rect, size, direction):
	match String(direction):
		"east":
			return Rect2(anchor_rect.position.x + anchor_rect.size.x,
				anchor_rect.position.y, size.x, size.y)
		"west":
			return Rect2(anchor_rect.position.x - size.x,
				anchor_rect.position.y, size.x, size.y)
		"south":
			return Rect2(anchor_rect.position.x,
				anchor_rect.position.y + anchor_rect.size.y, size.x, size.y)
		"north":
			return Rect2(anchor_rect.position.x,
				anchor_rect.position.y - size.y, size.x, size.y)
	return null


# Coloca `cand` pegado a la principal por `dir`; si el hueco esta ocupado, sigue
# la cadena hacia afuera hasta no solapar. null si no logra un lugar valido.
static func _place_adjacent(lay, cand, dir):
	var anchor = null
	for o in lay.outputs:
		if o.primary:
			anchor = o
			break
	if anchor == null:
		return null
	var size = cand.rect.size
	var r = _adjacent_rect(anchor.rect, size, dir)
	var guard = 0
	while guard <= lay.outputs.size() + 2:
		guard += 1
		var hit = null
		var probe = {"rect": Rect2(r.position, size)}
		for o in lay.outputs:
			if overlaps(probe, o):
				hit = o
				break
		if hit == null:
			break
		r = _adjacent_rect(hit.rect, size, dir)
	if guard > lay.outputs.size() + 2:
		return null
	cand.rect = r
	return cand


# --- Operaciones ---------------------------------------------------------------

static func _ok(lay):
	return {"ok": true, "layout": lay, "error": ""}


static func _fail(lay, msg):
	return {"ok": false, "layout": lay, "error": String(msg)}


# Agrega una salida secundaria anclada por `direction` (o desc.direction).
# Rechaza id invalido/duplicado, rect invalido y direccion invalida.
static func add_output(layout, desc, direction = ""):
	var lay = normalize_layout(layout)
	var raw = {}
	if typeof(desc) == TYPE_DICTIONARY:
		raw = desc.duplicate()
	elif typeof(desc) == TYPE_STRING:
		raw = {"id": String(desc)}
	else:
		return _fail(lay, "descriptor invalido")
	var id = String(raw.get("id", "")).strip_edges()
	if id == "" or id == PRIMARY_ID or not valid_output_id(id) or _has_id(lay.outputs, id):
		return _fail(lay, "id invalido o ya existe")
	var dir = String(direction).strip_edges()
	if dir == "":
		dir = String(raw.get("direction", "")).strip_edges()
	if not valid_direction(dir):
		return _fail(lay, "direccion invalida")
	raw["id"] = id
	raw["primary"] = false
	raw["direction"] = dir
	var cand = sanitize_output(raw)
	if cand == null:
		return _fail(lay, "descriptor invalido")
	var placed = _place_adjacent(lay, cand, dir)
	if placed == null:
		return _fail(lay, "no se pudo ubicar sin solape")
	lay.outputs.append(placed)
	return _ok(lay)


# Retira una salida y devuelve TODAS sus ventanas a la principal. Nunca se retira
# la principal. Reporta `moved` con los ids reasignados.
static func remove_output(layout, id):
	var lay = normalize_layout(layout)
	var key = String(id)
	if key == primary_id(lay):
		return _fail(lay, "no se puede retirar la principal")
	if not _has_id(lay.outputs, key):
		return _fail(lay, "output inexistente")
	var moved = []
	var prim = primary_id(lay)
	for wid in lay.windows.keys():
		if String(lay.windows[wid]) == key:
			lay.windows[wid] = prim
			moved.append(wid)
	var outs = []
	for o in lay.outputs:
		if String(o.id) != key:
			outs.append(o)
	lay.outputs = outs
	var res = _ok(lay)
	res["moved"] = moved
	return res


# Asignacion de ventana NUEVA: destino explicito valido/habilitado o, si falta o
# es invalido, la principal (spec §7: fallback principal).
static func assign_window(layout, window_id, output_id = ""):
	var lay = normalize_layout(layout)
	var wid = String(window_id).strip_edges()
	if wid == "":
		return _fail(lay, "ventana invalida")
	lay.windows[wid] = _resolve_target(lay, output_id)
	return _ok(lay)


# Mover una ventana EXISTENTE a una salida explicita: rechaza ventana inexistente,
# output inexistente y output deshabilitado.
static func move_window(layout, window_id, output_id):
	var lay = normalize_layout(layout)
	var wid = String(window_id).strip_edges()
	if wid == "":
		return _fail(lay, "ventana invalida")
	if not lay.windows.has(wid):
		return _fail(lay, "ventana inexistente")
	var o = output_by_id(lay, output_id)
	if o == null:
		return _fail(lay, "output inexistente")
	if not o.enabled:
		return _fail(lay, "output deshabilitado")
	lay.windows[wid] = String(o.id)
	return _ok(lay)


static func _resolve_target(lay, output_id):
	var s = String(output_id).strip_edges()
	if s == "":
		return primary_id(lay)
	var o = output_by_id(lay, s)
	if o == null or not o.enabled:
		return primary_id(lay)
	return String(o.id)


static func window_output(layout, window_id):
	var lay = normalize_layout(layout)
	return String(lay.windows.get(String(window_id), ""))


static func windows_of(layout, output_id):
	var lay = normalize_layout(layout)
	var out = []
	var key = String(output_id)
	for wid in lay.windows.keys():
		if String(lay.windows[wid]) == key:
			out.append(wid)
	return out


# --- Validacion -----------------------------------------------------------------

# Lista de problemas del layout CRUDO: descriptores invalidos, ids duplicados,
# cantidad de primary distinta de 1 y solapes. Vacia = layout sano.
static func validate_layout(layout):
	var errs = []
	if typeof(layout) != TYPE_DICTIONARY:
		return ["layout invalido"]
	var raw = layout.get("outputs", null)
	if typeof(raw) != TYPE_ARRAY:
		return ["outputs invalido"]
	var prim = 0
	var outs = []
	var seen = {}
	for e in raw:
		var o = sanitize_output(e)
		if o == null:
			errs.append("descriptor invalido")
			continue
		if seen.has(o.id):
			errs.append("id duplicado: " + String(o.id))
			continue
		seen[o.id] = true
		if o.primary:
			prim += 1
		outs.append(o)
	if prim != 1:
		errs.append("se esperaba exactamente una primary, hay %d" % prim)
	for i in range(outs.size()):
		for j in range(i + 1, outs.size()):
			if overlaps(outs[i], outs[j]):
				errs.append("solape: %s/%s" % [String(outs[i].id), String(outs[j].id)])
	return errs
