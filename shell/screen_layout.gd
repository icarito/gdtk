extends Reference

# Modelo puro (K11b) del diseno de pantallas de Configuracion > Pantallas.
#
# Reemplaza el panel "Distribucion": las pantallas son rectangulos con tamano
# fisico y posicion (x, y) en un plano de milimetros. La resolucion en pixeles es
# metadata: no decide cuanto borde fisico comparte una pantalla. Al soltar se
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

const VERSION = 2

const DEFAULT_W = 340.0       # mm, ~15.4" 16:10
const DEFAULT_H = 212.5
const DEFAULT_PX_W = 1280
const DEFAULT_PX_H = 800
const LEGACY_MM_PER_PX = 25.4 / 96.0
# Contacto minimo fisico para que el puntero cruce de una pantalla a otra.
const MIN_CONTACT = 8.0
const MAGNET_TOL = 24.0      # mm: alcance del imán mientras se arrastra
const TOUCH_TOL = 0.5

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
		"px_w": DEFAULT_PX_W,
		"px_h": DEFAULT_PX_H,
		"offset": 0.0,
		"share": {"screen": false, "input": false, "audio": false},
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
	out.px_w = int(clamp(_num(s.get("px_w", DEFAULT_PX_W), DEFAULT_PX_W), 100.0, 16384.0))
	out.px_h = int(clamp(_num(s.get("px_h", DEFAULT_PX_H), DEFAULT_PX_H), 100.0, 16384.0))
	var sh = s.get("share", {})
	out.share = {
		"screen": bool(sh.get("screen", false)) if typeof(sh) == TYPE_DICTIONARY else false,
		"input": bool(sh.get("input", false)) if typeof(sh) == TYPE_DICTIONARY else false,
		"audio": bool(sh.get("audio", false)) if typeof(sh) == TYPE_DICTIONARY else false,
	}
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
	# Sólo migra persistencia que declara v1. Diccionarios sin versión son fixtures o
	# llamadas internas y ya usan las unidades actuales.
	var legacy = data.has("version") and int(data.get("version", VERSION)) < VERSION
	var out = {"version": VERSION, "unit": "mm", "local": null, "screens": []}
	var raw_local = data.get("local", null)
	if legacy and typeof(raw_local) == TYPE_DICTIONARY:
		raw_local = _migrate_legacy(raw_local)
	var local = sanitize_screen(raw_local) if raw_local != null else null
	if local == null or (local.id == "" and local.label == ""):
		local = default_screen(LOCAL_ID, LOCAL_LABEL, true)
	local.local = true
	if local.id == "":
		local.id = LOCAL_ID
	out.local = local
	var seen = {local.id: true}
	var raw_screens = data.get("screens", [])
	if legacy and typeof(raw_screens) == TYPE_ARRAY:
		var migrated = []
		for raw in raw_screens:
			migrated.append(_migrate_legacy(raw))
		raw_screens = migrated
	for s in sanitize_screens(raw_screens):
		s.local = false
		if seen.has(s.id):
			continue
		seen[s.id] = true
		out.screens.append(s)
	out.version = VERSION
	return out


static func _migrate_legacy(s):
	if typeof(s) != TYPE_DICTIONARY:
		return s
	var out = s.duplicate(true)
	var pw = _num(s.get("w", DEFAULT_PX_W), DEFAULT_PX_W)
	var ph = _num(s.get("h", DEFAULT_PX_H), DEFAULT_PX_H)
	out["px_w"] = int(pw)
	out["px_h"] = int(ph)
	out["x"] = _num(s.get("x", 0.0), 0.0) * LEGACY_MM_PER_PX
	out["y"] = _num(s.get("y", 0.0), 0.0) * LEGACY_MM_PER_PX
	out["w"] = pw * LEGACY_MM_PER_PX
	out["h"] = ph * LEGACY_MM_PER_PX
	return out


static func set_share(layout, id, kind, enabled):
	var lay = normalize_layout(layout)
	if not ["screen", "input", "audio"].has(String(kind)):
		return lay
	# El transporte de audio admite un solo destino. Mantener esa restriccion en
	# la preferencia evita que la reconciliacion oscile entre dos equipos.
	if String(kind) == "audio" and bool(enabled):
		for other in lay.screens:
			other.share.audio = false
	var sc = screen_by_id(lay, id)
	if sc == null or bool(sc.local):
		return lay
	sc.share[String(kind)] = bool(enabled)
	_store_screen(lay, sc)
	return lay


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
	var probe = {"x": float(px), "y": float(py), "w": moving.w, "h": moving.h}
	var best = null
	# Primera pasada: sólo las pantallas que el rect soltado SOLAPA. Soltar
	# encima de una pantalla significa pegar contra ESA (y por su lado solapado);
	# sin esto, el candidato más barato podía ser otra pantalla y la movida
	# terminaba lejos ("se la llevaba para abajo"). Segunda pasada: todo.
	for pass_i in range(2):
		for oi in range(clean.size()):
			var o = clean[oi]
			if o.id == moving.id:
				continue
			if pass_i == 0 and not overlaps(probe, o):
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
		if best != null:
			break
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


# --- Imantado en vivo (mientras se arrastra) -----------------------------------

# Candidatos por eje contra otra pantalla: bordes propios y opuestos (pegado
# de lado) y centros alineados.
static func _axis_candidates(moving, o, vertical):
	var mw = float(moving.w)
	var mh = float(moving.h)
	var out = []
	var bx = float(o.x)
	var by = float(o.y)
	var bw = float(o.w)
	var bh = float(o.h)
	if vertical:
		# x: mi borde izquierdo en o.x, mi borde izquierdo en el derecho de o
		# (pegado al este o columna derecha), mi borde derecho en el izquierdo
		# de o (pegado al oeste o columna izquierda), bordes derechos juntos
		# (esquina compartida) y centro con centro.
		out.append({"kind": "left_at", "value": bx})
		out.append({"kind": "left_at_right", "value": bx + bw})
		out.append({"kind": "right_at_left", "value": bx - mw})
		out.append({"kind": "right_at", "value": bx + bw - mw})
		out.append({"kind": "center", "value": bx + bw * 0.5 - mw * 0.5})
	else:
		out.append({"kind": "top_at", "value": by})
		out.append({"kind": "top_at_bottom", "value": by + bh})
		out.append({"kind": "bottom_at_top", "value": by - mh})
		out.append({"kind": "bottom_at", "value": by + bh - mh})
		out.append({"kind": "center", "value": by + bh * 0.5 - mh * 0.5})
	return out


# Devuelve {x, y, snap_x, snap_y, guides: [{axis, kind, value, target}]}.
# Cada eje toma su mejor candidato dentro de `tol` (mm); el resultado no debe
# solapar a otra pantalla. Si la composicion de ambos ejes solapa, se conserva
# solo el eje mas cercano (el otro vuelve libre).
static func live_snap(screens, id, px, py, tol = -1.0):
	var t = MAGNET_TOL if tol < 0.0 else float(tol)
	var clean = sanitize_screens(screens)
	var probe = null
	for s in clean:
		if s.id == String(id):
			probe = s
	if probe == null:
		return {"x": float(px), "y": float(py), "snap_x": false, "snap_y": false,
			"guides": []}
	var xc = []
	var yc = []
	for o in clean:
		if o.id == probe.id:
			continue
		for c in _axis_candidates(probe, o, true):
			var d = abs(c.value - float(px))
			if d <= t:
				xc.append({"axis": "x", "kind": c.kind, "value": c.value, "target": o.id, "d": d})
		for c in _axis_candidates(probe, o, false):
			var d2 = abs(c.value - float(py))
			if d2 <= t:
				yc.append({"axis": "y", "kind": c.kind, "value": c.value, "target": o.id, "d": d2})
	# Opciones validas (sin solape): un eje, el otro, o ambos compuestos.
	var best = {}
	for a in xc:
		_consider(best, probe, clean, float(a.value), float(py), [a], [])
	for b in yc:
		_consider(best, probe, clean, float(px), float(b.value), [], [b])
	for a in xc:
		for b in yc:
			_consider(best, probe, clean, float(a.value), float(b.value), [a], [b])
	if best.empty():
		return {"x": float(px), "y": float(py), "snap_x": false, "snap_y": false,
			"guides": []}
	var guides = []
	guides.append_array(best.get("gx", []))
	guides.append_array(best.get("gy", []))
	return {"x": float(best.x), "y": float(best.y),
		"snap_x": not best.get("gx", []).empty(), "snap_y": not best.get("gy", []).empty(),
		"guides": guides}


# Compara una opcion contra la mejor hasta ahora: primero gana MAS EJES
# imantados (pegado + alineado vale mas que el contacto suelto que da el
# snap() al soltar); a igualdad de ejes, menos distancia total. Una opcion
# nunca solapa a otra pantalla.
static func _consider(best, probe, clean, x, y, ax, ay):
	var opt = {"x": float(x), "y": float(y)}
	if _overlaps_any(
			{"x": float(x), "y": float(y), "w": float(probe.w), "h": float(probe.h)},
			clean, probe.id):
		return
	var cost = 0.0
	for a in ax:
		cost += float(a.d)
	for b in ay:
		cost += float(b.d)
	var axes = ax.size() + ay.size()
	opt["cost"] = cost
	opt["axes"] = axes
	opt["gx"] = ax
	opt["gy"] = ay
	var better = false
	if best.empty():
		better = true
	elif axes > int(best.axes) or (axes == int(best.axes) and cost < float(best.cost) - 0.0001):
		better = true
	if not better:
		return
	for k in ["x", "y", "cost", "axes", "gx", "gy"]:
		best[k] = opt[k]


# ¿El rect (x,y,w,h) cabe sin solapar a las otras pantallas (de id distinta)?
static func fits(screens, id, x, y, w, h):
	var clean = sanitize_screens(screens)
	return not _overlaps_any(
		{"x": float(x), "y": float(y), "w": float(w), "h": float(h)},
		clean, String(id))


static func has_contact(screens, id, tol = TOUCH_TOL):
	var clean = sanitize_screens(screens)
	for s in clean:
		if s.id == String(id):
			for o in clean:
				if o.id == s.id:
					continue
				if not contact(s, o, tol).empty():
					return true
	return false


# --- Redimension por borde/esquina (aspect ratio fijo) -------------------------

# Ajusta la pantalla `id` desde `handle` (n,s,e,w,ne,nw,se,sw) al punto de
# cursor (px,py en el plano mm) con el aspect ratio de su RESOLUCION fijo
# (px_w/px_h; si falta, el w/h actual). El iman evita contactos al 1%/99%:
#  - el extremo arrastrado se imanta ajustando el tamano a una linea de borde
#    o centro de otra pantalla a <= MAGNET_TOL del cursor;
#  - en esquinas ambas lineas se imantan juntas solo si el par queda
#    compatible con el ratio (<= 2 mm); si no, manda la linea mas cercana;
#  - bordes: el rect se desplaza en el eje PERPENDICULAR para alinear los
#    extremos del contacto (evita pedacitos de borde) sin mover el extremo
#    ya imantado;
#  - nunca solapa: opciones solapantes se descartan; si el cursor mismo
#    solapa, ok=false y al soltar la vista revierte al rect previo.
# Devuelve {x, y, w, h, ok, guides: [{axis, value}]}.
const SIZE_MIN_MM = 50.0
const SIZE_MAX_MM = 1000.0

static func resize_live(screens, id, handle, px, py, tol = -1.0):
	var t = MAGNET_TOL if tol < 0.0 else float(tol)
	var clean = sanitize_screens(screens)
	var probe = null
	for s in clean:
		if s.id == String(id):
			probe = s
	if probe == null:
		return {"ok": false}
	var r = rect(probe)
	var x0 = float(r.position.x)
	var y0 = float(r.position.y)
	var w0 = float(r.size.x)
	var h0 = float(r.size.y)
	var aspect = float(probe.px_w) / float(probe.px_h) \
		if int(probe.px_w) > 0 and int(probe.px_h) > 0 else w0 / h0
	var lines_x = []
	var lines_y = []
	for o in clean:
		if o.id == probe.id:
			continue
		var ro = rect(o)
		lines_x.append(float(ro.position.x))
		lines_x.append(float(ro.position.x + ro.size.x))
		lines_x.append(float(ro.position.x + ro.size.x * 0.5))
		lines_y.append(float(ro.position.y))
		lines_y.append(float(ro.position.y + ro.size.y))
		lines_y.append(float(ro.position.y + ro.size.y * 0.5))
	var kind = String(handle)
	var gx = []
	var gy = []
	var out = {}
	if kind == "e" or kind == "w":
		var pivot_x = x0 if kind == "e" else x0 + w0
		var dw = _snap_size_at(lines_x, float(px), pivot_x, t)
		var w = clamp(abs(px - pivot_x), SIZE_MIN_MM, SIZE_MAX_MM) if dw < 0.0 else dw
		if dw >= 0.0:
			gx.append({"axis": "x", "value": (x0 + w) if kind == "e" else (pivot_x - w)})
		var h = w / aspect
		var x = x0 if kind == "e" else x0 + w0 - w
		var y = y0 + h0 * 0.5 - h * 0.5
		out = {"x": x, "y": y, "w": w, "h": h}
		# Solo el eje perpendicular: alinear el reparto del contacto con una
		# fila (el shift se prueba primero: rescata solapes leves del spread).
		var sy = _best_shift(lines_y, y, h, t)
		var c2 = {"x": x, "y": y + sy, "w": w, "h": h}
		if not _overlaps_any(c2, clean, probe.id):
			if sy != 0.0:
				gy.append({"axis": "y", "value": y + sy})
			out = c2
	elif kind == "n" or kind == "s":
		var pivot_y = y0 if kind == "s" else y0 + h0
		var dh = _snap_size_at(lines_y, float(py), pivot_y, t)
		var h2 = clamp(abs(py - pivot_y), SIZE_MIN_MM, SIZE_MAX_MM) if dh < 0.0 else dh
		if dh >= 0.0:
			gy.append({"axis": "y", "value": (y0 + h2) if kind == "s" else (pivot_y - h2)})
		var w2 = h2 * aspect
		var y2 = y0 if kind == "s" else y0 + h0 - h2
		var x2 = x0 + w0 * 0.5 - w2 * 0.5
		out = {"x": x2, "y": y2, "w": w2, "h": h2}
		var sx1 = _best_shift(lines_x, x2, w2, t)
		var c3 = {"x": x2 + sx1, "y": y2, "w": w2, "h": h2}
		if not _overlaps_any(c3, clean, probe.id):
			if sx1 != 0.0:
				gx.append({"axis": "x", "value": x2 + sx1})
			out = c3
	else:
		var left = kind.find("w") >= 0
		var top = kind.find("n") >= 0
		var pivot_x = (x0 + w0) if left else x0
		var pivot_y = (y0 + h0) if top else y0
		var w_r = abs(px - pivot_x)
		var h_r = abs(py - pivot_y)
		var w_r2 = max(w_r, h_r * aspect)
		var w = clamp(w_r2, SIZE_MIN_MM, SIZE_MAX_MM)
		var h = w / aspect
		var x = x0 if not left else pivot_x - w
		var y = pivot_y if not top else pivot_y - h
		# Par de lineas ratio-compatible: ambos extremos imantados.
		var best_d = -1.0
		for lx in lines_x:
			var w_l = abs(lx - pivot_x)
			var dx_l = abs(lx - px)
			if dx_l > t or w_l < SIZE_MIN_MM or w_l > SIZE_MAX_MM:
				continue
			var h_l = w_l / aspect
			for ly in lines_y:
				var h_l2 = abs(ly - pivot_y)
				var dy_l = abs(ly - py)
				if dy_l > t or h_l2 < SIZE_MIN_MM or h_l2 > SIZE_MAX_MM:
					continue
				if abs(h_l2 - h_l) > 2.0:
					continue
				var d_tot = dx_l + dy_l
				if best_d < 0.0 or d_tot < best_d:
					best_d = d_tot
					w = w_l
					h = h_l2
					x = x0 if not left else pivot_x - w
					y = pivot_y if not top else pivot_y - h
					gx = [{"axis": "x", "value": lx}]
					gy = [{"axis": "y", "value": ly}]
		if best_d < 0.0:
			# Una sola linea: la mas cercana del cursor entre ambos ejes.
			var nx = _nearest_line(lines_x, px, pivot_x, t)
			var ny = _nearest_line(lines_y, py, pivot_y, t)
			if nx.size() == 3 and (ny.size() != 3 or float(nx[0]) <= float(ny[0])):
				w = float(nx[1])
				h = w / aspect
				x = x0 if not left else pivot_x - w
				y = pivot_y if not top else pivot_y - h
				gx = [{"axis": "x", "value": float(nx[2])}]
			elif ny.size() == 3:
				h = float(ny[1])
				w = h * aspect
				y = pivot_y if not top else pivot_y - h
				x = x0 if not left else pivot_x - w
				gy = [{"axis": "y", "value": float(ny[2])}]
		out = {"x": x, "y": y, "w": w, "h": h}
	var ok = not _overlaps_any(out, clean, probe.id)
	var guides = []
	guides.append_array(gx)
	guides.append_array(gy)
	out["ok"] = ok
	out["guides"] = guides
	return out


# La linea cuya coordenada esta a <= tol del cursor y cuyo size implicito
# |line - pivot| cae en [SIZE_MIN_MM..SIZE_MAX_MM]. Devuelve ese size o -1.
static func _snap_size_at(lines, cursor, pivot, tol):
	var best = -1.0
	var out = -1.0
	for line in lines:
		var d = abs(line - float(cursor))
		if d > tol:
			continue
		var implied = abs(line - float(pivot))
		if implied < SIZE_MIN_MM or implied > SIZE_MAX_MM:
			continue
		if best < 0.0 or d < best:
			best = d
			out = implied
	return out


# La linea mas cercana: [dist, size_implicito, coord]; [] si ninguna entra.
static func _nearest_line(lines, cursor, pivot, tol):
	var best = -1.0
	var found = []
	for line in lines:
		var d = abs(line - float(cursor))
		if d > tol:
			continue
		var implied = abs(line - float(pivot))
		if implied < SIZE_MIN_MM or implied > SIZE_MAX_MM:
			continue
		if best < 0.0 or d < best:
			best = d
			found = [d, implied, line]
	return found


# Desplazamiento que alinea un extremo del rect (pos..pos+size) a una linea
# dentro de tol; 0.0 si ninguna.
static func _best_shift(lines, pos, size, tol):
	var best = -1.0
	var shift = 0.0
	for line in lines:
		for v in [line, line - size]:
			var d = abs(v - float(pos))
			if d <= tol and (best < 0.0 or d < best):
				best = d
				shift = v - float(pos)
	return shift


static func _finish(probe, rect, clean, gx, gy):
	var fits = not _overlaps_any(rect, clean, probe.id)
	var guides = []
	guides.append_array(gx)
	guides.append_array(gy)
	return {"x": float(rect.x), "y": float(rect.y), "w": float(rect.w), "h": float(rect.h),
		"ok": fits, "guides": guides}


# --- Colocacion por direccion y cadenas ---------------------------------------

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


# --- Vista mini ----------------------------------------------------------------

# Transform fija de la vista mini (mismo criterio que el canvas de Configuración
# > Pantallas: preservar proporción y centrar). Mientras se arrastra una
# pantalla el bbox cambia; con la transform CONGELADA en el inicio del arrastre
# el resto no se reacomoda y va a parar al mouse. {} si no se puede mapear.
static func mini_map_transform(layout, target):
	var lay = normalize_layout(layout)
	var items = all_screens(lay)
	if items.empty() or target.size.x <= 0.0 or target.size.y <= 0.0:
		return {}
	var bbox = Rect2(items[0].x, items[0].y, items[0].w, items[0].h)
	for i in range(1, items.size()):
		bbox = bbox.merge(Rect2(items[i].x, items[i].y, items[i].w, items[i].h))
	if bbox.size.x <= 0.0 or bbox.size.y <= 0.0:
		return {}
	var k = min(target.size.x / bbox.size.x, target.size.y / bbox.size.y)
	return {"k": k,
		"off": target.position + (target.size - bbox.size * k) * 0.5,
		"bbox": bbox}


# Plano (px local del rect destino) -> posición en mm.
static func mm_pos(transform, local_pos):
	if typeof(transform) != TYPE_DICTIONARY or transform.empty():
		return Vector2.ZERO
	return (Vector2(local_pos) - Vector2(transform.off)) / float(transform.k) \
		+ Vector2(transform.bbox.position)


# Pantalla en mm -> rect px dentro del rect destino de la vista mini.
static func mm_rect(transform, screen):
	if typeof(transform) != TYPE_DICTIONARY or transform.empty():
		return Rect2()
	var k = float(transform.k)
	var off = Vector2(transform.off)
	var bp = Vector2(transform.bbox.position)
	return Rect2(
		off.x + (float(screen.x) - bp.x) * k,
		off.y + (float(screen.y) - bp.y) * k,
		max(1.0, float(screen.w) * k), max(1.0, float(screen.h) * k))


# Punto en mm -> px del rect destino (guías del imán en la vista mini).
static func mm_pt(transform, mm):
	if typeof(transform) != TYPE_DICTIONARY or transform.empty():
		return Vector2.ZERO
	var k = float(transform.k)
	var off = Vector2(transform.off)
	var bp = Vector2(transform.bbox.position)
	return Vector2(
		off.x + (float(mm.x) - bp.x) * k,
		off.y + (float(mm.y) - bp.y) * k)


# Vista mini de la distribución (SPEC-sugar-group-2026-10, popup de Grupo): mapea
# cada pantalla al rect destino preservando proporción y centrando. Devuelve
# [{id, label, is_local, rect, moved}] con `rect` local al rect destino, en px,
# orden local -> resto.
static func mini_map(layout, target, moved_id = ""):
	var t = mini_map_transform(layout, target)
	if t.empty():
		return []
	var out = []
	for s in all_screens(layout):
		out.append({
			"id": String(s.id),
			"label": String(s.label),
			"is_local": bool(s.local),
			"rect": mm_rect(t, s),
			"moved": String(s.id) == String(moved_id),
		})
	return out


# Elegir la pantalla mini bajo `local_pos` (px del rect destino): la última
# dibujada que la contenga (el orden local->resto dibuja los pares encima).
# Sin hit: {}.
static func mini_map_pick(marks, local_pos):
	var p = Vector2(local_pos)
	for i in range(marks.size() - 1, -1, -1):
		if marks[i].rect.has_point(p):
			return marks[i]
	return {}


# Igual que mini_map_pick pero con margen: la más cercana cuyo rect crecido
# `margin` px contenga al punto (las pantallas quedan chicas en el canvas del
# popup; un agarrón imperfecto tiene que pegar igual). Sin hit: {}.
static func mini_map_pick_near(marks, local_pos, margin = 12.0):
	var p = Vector2(local_pos)
	var best = {}
	var best_d = -1.0
	for i in range(marks.size() - 1, -1, -1):
		var r = marks[i].rect
		if not r.grow(float(margin)).has_point(p):
			continue
		var cp = Vector2(
			clamp(p.x, r.position.x, r.end.x),
			clamp(p.y, r.position.y, r.end.y))
		var d = p.distance_to(cp)
		if best_d < 0.0 or d < best_d:
			best_d = d
			best = marks[i]
	return best


# Zona de borde de una pantalla mini para el resize con drag (popup): la última
# dibujada que contenga al punto y cuyo borde quede a <= tol px. "edge" es
# este/west/north/south o "" (interior; muevo). Espejo de mini_map_pick.
static func mini_map_edge(marks, local_pos, tol_px = 6.0):
	var p = Vector2(local_pos)
	var tol = max(2.0, float(tol_px))
	for i in range(marks.size() - 1, -1, -1):
		var r = marks[i].rect
		if not r.has_point(p):
			continue
		var ds = {
			"east": abs(r.end.x - p.x),
			"west": abs(p.x - r.position.x),
			"south": abs(r.end.y - p.y),
			"north": abs(p.y - r.position.y),
		}
		var edge = ""
		var dist = tol
		for k in ["east", "west", "south", "north"]:
			if float(ds[k]) <= tol and (edge == "" or float(ds[k]) < dist):
				edge = k
				dist = float(ds[k])
		if edge != "":
			return {"id": String(marks[i].id), "edge": edge}
	return {}


# Asa de una pantalla mini para el gesto del popup (idéntico a Configuración >
# Pantallas): interior -> "" (mover); un borde -> "e|w|n|s"; una esquina ->
# dos letras ("es","en","ws","wn"). En px del rect destino. Sin hit: {}.
static func mini_map_handle(marks, local_pos, tol_px = 7.0):
	var p = Vector2(local_pos)
	var tol = max(2.0, float(tol_px))
	for i in range(marks.size() - 1, -1, -1):
		var r = marks[i].rect
		# El asa nunca ocupa mas de un tercio del lado.
		var tl = min(tol, min(r.size.x, r.size.y) * 0.33)
		if not r.grow(tl).has_point(p):
			continue
		var x0 = r.position.x
		var y0 = r.position.y
		var x1 = r.end.x
		var y1 = r.end.y
		var at_l = abs(p.x - x0) <= tl
		var at_r = abs(p.x - x1) <= tl
		var at_t = abs(p.y - y0) <= tl
		var at_b = abs(p.y - y1) <= tl
		var handle = ""
		if at_r and p.y >= y0 - tol and p.y <= y1 + tol:
			handle += "e"
		elif at_l and p.y >= y0 - tol and p.y <= y1 + tol:
			handle += "w"
		if at_b and p.x >= x0 - tol and p.x <= x1 + tol:
			handle += "s"
		elif at_t and p.x >= x0 - tol and p.x <= x1 + tol:
			handle += "n"
		return {"id": String(marks[i].id), "handle": handle}
	return {}


# Redimensionar una pantalla arrastrando un borde, conservando el aspecto
# (relación w/h de la pantalla al agarrar). Devuelve {x, y, w, h}; el borde del
# lado contrario queda clavado y el centro del eje perpendicular no se mueve.
# Límites: MIN/MAX del panel de dimensiones (50..3000 mm).
static func resize_edge(screen, edge, mm, min_dim = 50.0, max_dim = 3000.0):
	var w = max(float(min_dim), float(screen.w))
	var h = max(float(min_dim), float(screen.h))
	var w0 = w
	var h0 = h
	var ratio = w / max(1.0, h)
	var x = float(screen.x)
	var y = float(screen.y)
	var d = String(edge)
	if d == "east" or d == "west":
		var nw = clamp(float(mm.x) - x, min_dim, max_dim) if d == "east" \
			else clamp(x + w - float(mm.x), min_dim, max_dim)
		var nh = nw / ratio
		var cy = y + h * 0.5
		w = nw
		h = nh
		y = cy - h * 0.5
		if d == "west":
			x = x + w0 - nw   # el borde este clavado
	elif d == "north" or d == "south":
		var nh2 = clamp(float(mm.y) - y, min_dim, max_dim) if d == "south" \
			else clamp(y + h - float(mm.y), min_dim, max_dim)
		var nw2 = nh2 * ratio
		var cx = x + w * 0.5
		h = nh2
		w = nw2
		x = cx - w * 0.5
		if d == "north":
			y = y + h0 - nh2  # el borde sur clavado
	return {"x": x, "y": y, "w": w, "h": h}


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


# Topología COMPLETA de adyacencias para el server de Deskflow: una entrada por
# cada par de pantallas que se tocan (no sólo desde la local), con el borde y los
# rangos porcentuales de cada lado. Los ids se traducen a nombres Deskflow: la
# pantalla local usa `local_name`; las demás su campo `peer`. Formato listo para
# deskflow_conf.build_topology_conf:
# [{screen, edge, peer, range, peer_range, direction}].
static func topology(layout, local_name = ""):
	var lay = normalize_layout(layout)
	var local_id = String(lay.local.id)
	if String(local_name).strip_edges() == "":
		local_name = String(lay.local.label) if String(lay.local.label) != "" else local_id
	var name_of = {}
	for s in all_screens(lay):
		if String(s.id) == local_id:
			name_of[String(s.id)] = String(local_name)
		else:
			var pn = String(s.peer)
			name_of[String(s.id)] = pn if pn != "" else String(s.id)
	var out = []
	for e in edges(lay):
		var a = screen_by_id(lay, String(e.get("from", "")))
		var b = screen_by_id(lay, String(e.get("to", "")))
		if a == null or b == null:
			continue
		var r = link_ranges(a, b)
		if r.empty():
			continue
		var an = String(name_of.get(String(e.get("from", "")), String(e.get("from", ""))))
		var bn = String(name_of.get(String(e.get("to", "")), String(e.get("to", ""))))
		if an == "" or bn == "" or an == bn:
			continue
		out.append({
			"screen": an,
			"edge": edge_of(String(r.get("direction", ""))),
			"peer": bn,
			"range": r.local_range,
			"peer_range": r.peer_range,
			"direction": String(r.get("direction", "")),
		})
	return out


# Direcciones de todos los vecinos en el formato de host_directions (fuente unica
# de Pantalla y Teclado y mouse). Sólo las pantallas con contacto confirmado.
static func to_host_directions(layout):
	var lay = normalize_layout(layout)
	var out = {}
	for e in output(lay):
		var anchor = screen_by_id(lay, String(e.via))
		var moving = screen_by_id(lay, String(e.id))
		var along = 0.5
		if anchor != null and moving != null:
			if String(e.direction) == "east" or String(e.direction) == "west":
				along = (moving.y + moving.h * 0.5 - anchor.y) / max(anchor.h, 1.0)
			else:
				along = (moving.x + moving.w * 0.5 - anchor.x) / max(anchor.w, 1.0)
		out[String(e.id)] = {
			"direction": String(e.direction),
			"confirm": "confirmed",
			"mode": "extend",
			"link": "screen",
			"offset": float(e.offset_px),
			"along": clamp(along, 0.0, 1.0),
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


# --- Ubicación por ángulo (vista Grupo, 360°) ------------------------------------
# El equipo local es un rectángulo de semiejes `half`; un par soltado en cualquier
# ángulo cae en un punto de su borde: lado cardinal + posición `offset` (0..1) a lo
# largo de ese lado, medida como `contact()` (desde arriba en E/O, desde la izquierda
# en N/S). Ángulos en grados, horario en pantalla (y hacia abajo): este 0, sur 90,
# oeste 180, norte 270. La inversa devuelve el mismo ángulo (salvo el 0..360).

static func _half_ok(half):
	var h = Vector2(half)
	return Vector2(max(h.x, 1.0), max(h.y, 1.0))


# Punto del borde del rectángulo de semiejes `half` en el ángulo dado (relativo al centro).
static func edge_point(angle_deg, half = Vector2(DEFAULT_W, DEFAULT_H) * 0.5):
	var h = _half_ok(half)
	var a = deg2rad(float(angle_deg))
	var d = Vector2(cos(a), sin(a))
	var t = 1.0 / max(abs(d.x) / h.x, abs(d.y) / h.y)
	return d * t


# Ángulo -> {side, offset}. En las esquinas gana el lado horizontal (N/S).
static func placement_from_angle(angle_deg, half = Vector2(DEFAULT_W, DEFAULT_H) * 0.5):
	var h = _half_ok(half)
	var p = edge_point(angle_deg, h)
	if abs(p.y) * h.x >= abs(p.x) * h.y - 0.0001:
		return {"side": "south" if p.y > 0.0 else "north",
			"offset": clamp(0.5 + p.x / (2.0 * h.x), 0.0, 1.0)}
	return {"side": "east" if p.x > 0.0 else "west",
		"offset": clamp(0.5 + p.y / (2.0 * h.y), 0.0, 1.0)}


# {side, offset} -> ángulo 0..360. Lado inválido => -1.
static func angle_from_placement(side, offset, half = Vector2(DEFAULT_W, DEFAULT_H) * 0.5):
	var h = _half_ok(half)
	var o = clamp(float(offset), 0.0, 1.0)
	var p = Vector2.ZERO
	match String(side):
		"north":
			p = Vector2((o - 0.5) * 2.0 * h.x, -h.y)
		"south":
			p = Vector2((o - 0.5) * 2.0 * h.x, h.y)
		"east":
			p = Vector2(h.x, (o - 0.5) * 2.0 * h.y)
		"west":
			p = Vector2(-h.x, (o - 0.5) * 2.0 * h.y)
		_:
			return -1.0
	return fposmod(rad2deg(atan2(p.y, p.x)), 360.0)


# Offset en px para place_direction: centra al par sobre la posición `offset` (0..1) del
# borde del ancla, dejando siempre un contacto mínimo (el puntero tiene que poder pasar).
static func offset_px(direction, offset, anchor, moving):
	var vertical = String(direction) == "east" or String(direction) == "west"
	var ra = rect(anchor)
	var rm = rect(moving)
	var edge = ra.size.y if vertical else ra.size.x
	var mine = rm.size.y if vertical else rm.size.x
	var o = float(offset) * edge - mine * 0.5
	var lo = MIN_CONTACT - mine
	var hi = edge - MIN_CONTACT
	return clamp(o, min(lo, hi), max(lo, hi))


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
