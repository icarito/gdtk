extends Reference

# K13g — Estado PURO del modo por VENTANA (híbrido flotante + mosaico).
#
# Cada ventana (id entero de toplevel) tiene:
#   - mode:   "floating" | "tiled"  (default: floating)
#   - anchor: índice de la unidad/pantalla a la que pertenece (ESCRITORIO = 0)
#   - float_rect: último rect flotante recordado (Rect2 o null)
#
# El Escritorio (ESCRITORIO = 0) es una ranura reservada: no tiene miembros tiled y
# aloja a los flotantes que no están anclados a una pantalla con mosaico. Los ids
# reales de toplevel son > 0.
#
# Sin I/O: sólo normaliza, guarda y serializa. Vocabulario visible: "Flotante" y
# "Mosaico" (nunca tiling/container). Lo cubre tests/wm_hybrid_test.gd.

const FLOATING = "floating"
const TILED = "tiled"
const ESCRITORIO = 0

# id (int de toplevel) -> {"mode": String, "anchor": int, "float_rect": Rect2|null}
var windows = {}


static func normalize_mode(value):
	var m = String(value).strip_edges().to_lower()
	if m == TILED or m == "tile" or m == "mosaico" or m == "mosaic":
		return TILED
	return FLOATING


# Crea el registro de la ventana si no existe (default: flotante en el Escritorio).
func ensure(id):
	if not windows.has(id):
		windows[id] = {"mode": FLOATING, "anchor": ESCRITORIO, "float_rect": null}
	return windows[id]


func forget(id):
	windows.erase(id)


func mode(id, fallback = FLOATING):
	var w = windows.get(id, null)
	if w == null:
		return normalize_mode(fallback)
	return normalize_mode(w.get("mode", fallback))


func is_floating(id):
	return mode(id) == FLOATING


func is_tiled(id):
	return mode(id) == TILED


func anchor(id, fallback = ESCRITORIO):
	var w = windows.get(id, null)
	if w == null:
		return int(fallback)
	return int(w.get("anchor", fallback))


func float_rect(id, fallback = null):
	var w = windows.get(id, null)
	if w != null and w.get("float_rect", null) != null:
		return Rect2(w["float_rect"])
	return fallback


func set_floating(id, anchor = ESCRITORIO, rect = null):
	var w = ensure(id)
	w["mode"] = FLOATING
	w["anchor"] = int(anchor)
	if rect != null:
		w["float_rect"] = Rect2(rect)
	return w


func set_tiled(id, anchor = ESCRITORIO):
	var w = ensure(id)
	w["mode"] = TILED
	w["anchor"] = int(anchor)
	return w


func set_mode(id, value, anchor = null):
	var w = ensure(id)
	w["mode"] = normalize_mode(value)
	if anchor != null:
		w["anchor"] = int(anchor)
	return w


func reanchor(id, anchor):
	var w = ensure(id)
	w["anchor"] = int(anchor)
	return w


func set_float_rect(id, rect):
	var w = ensure(id)
	w["float_rect"] = Rect2(rect) if rect != null else null
	return w


func ids():
	return windows.keys()


func ids_mode(m):
	var out = []
	var want = normalize_mode(m)
	for id in windows.keys():
		if normalize_mode(windows[id].get("mode", FLOATING)) == want:
			out.append(id)
	return out


func serialize():
	var out = {}
	for id in windows.keys():
		var w = windows[id]
		var rr = w.get("float_rect", null)
		out[str(id)] = {"mode": normalize_mode(w.get("mode", FLOATING)),
			"anchor": int(w.get("anchor", ESCRITORIO)),
			"rect": [rr.position.x, rr.position.y, rr.size.x, rr.size.y] if rr != null else null}
	return out


func parse(data):
	windows = {}
	if typeof(data) != TYPE_DICTIONARY:
		return windows
	for k in data.keys():
		var row = data[k]
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var rr = row.get("rect", null)
		var rect = null
		if typeof(rr) == TYPE_ARRAY and rr.size() >= 4:
			rect = Rect2(float(rr[0]), float(rr[1]), float(rr[2]), float(rr[3]))
		windows[int(k)] = {"mode": normalize_mode(row.get("mode", FLOATING)),
			"anchor": int(row.get("anchor", ESCRITORIO)), "float_rect": rect}
	return windows


func run_selftest():
	var m = get_script().new()
	assert(m.mode(1) == FLOATING, "default flotante")
	assert(m.is_floating(1) and not m.is_tiled(1), "is_floating default")
	assert(m.anchor(1) == ESCRITORIO, "default ancla Escritorio")
	assert(m.float_rect(1) == null, "default sin rect")
	m.set_tiled(7, 2)
	assert(m.is_tiled(7) and m.anchor(7) == 2, "set_tiled con ancla")
	m.set_floating(7, 1, Rect2(10, 20, 300, 200))
	assert(m.is_floating(7) and m.anchor(7) == 1, "vuelve a flotante con ancla")
	assert(m.float_rect(7) == Rect2(10, 20, 300, 200), "rect recordado")
	m.set_float_rect(7, Rect2(1, 2, 3, 4))
	assert(m.float_rect(7) == Rect2(1, 2, 3, 4), "set_float_rect")
	m.reanchor(7, 0)
	assert(m.anchor(7) == 0, "reanchor")
	m.set_mode(7, "mosaico")
	assert(m.mode(7) == TILED, "set_mode tolerante")
	m.set_mode(7, "floating")
	m.set_floating(9)
	assert(m.ids_mode(FLOATING).has(7) and m.ids_mode(FLOATING).has(9), "ids_mode flotante")
	assert(m.ids_mode(TILED).empty(), "sin tiled")
	m.forget(9)
	assert(not m.ids().has(9), "forget")
	# Roundtrip de serialización.
	m.set_tiled(5, 3)
	m.set_floating(6, 0, Rect2(7, 8, 9, 10))
	var blob = m.serialize()
	var m2 = get_script().new()
	m2.parse(blob)
	assert(m2.mode(5) == TILED and m2.anchor(5) == 3, "roundtrip tiled")
	assert(m2.float_rect(6) == Rect2(7, 8, 9, 10), "roundtrip rect")
	assert(m2.anchor(6) == 0, "roundtrip ancla")
	# Parse tolerante.
	var m3 = get_script().new()
	m3.parse({"x": "basura"})
	assert(m3.ids().empty(), "parse basura")
	assert(normalize_mode("Tiled") == TILED, "normalize")
	assert(normalize_mode("") == FLOATING, "normalize vacio")
	return true
