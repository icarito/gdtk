extends Reference

# Modelo PURO del servidor multiview del Vecindario
# (SPEC-multiview-portal.md §6). Es puro y sin efectos: NO lanza procesos, NO toca
# red, NO toca filesystem y no guarda estado global. La orquestacion real (workers +
# snapshot, §10) vive en el shell; este modulo solo decide y describe:
#
#   - reparto determinista de slots/puertos por hid (assign_slots),
#   - grilla de tiles sin solapes dentro de un viewport (tile_rects),
#   - disposicion cardinal desde el compas/Grupo (place_by_direction),
#   - tile dueño del puntero (active_slot),
#   - maquina de estados por ruta de recepcion (transition).
#
# base + 2*i evita que el cursor (port + 1) choque con el video del slot siguiente.

const DIRECTIONS = preload("res://neighborhood_directions.gd")

const STATES = ["idle", "joining", "live", "degraded", "leaving", "stopped", "failed"]
const EVENTS = ["join", "ready", "drop", "resume", "leave", "stopped", "fail", "reset"]

# Estados terminales: de ellos solo se sale con `reset`.
const _TERMINAL = ["stopped", "failed"]

# Caracteres seguros para los atomos de un hid (mismos que el resto del repo).
const _SAFE_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
const _MAX_HID_LEN = 64
const _MIN_BASE = 1024
const _MAX_BASE = 65000
const _MIN_SLOTS = 1
const _MAX_SLOTS = 16
const _DEFAULT_BASE = 5700
const _DEFAULT_SLOTS = 4
const _MAX_TILES = 16
const _EPS = 0.01

# Prefijo del título de ventana de los receptores del multiview (SPEC-multiview-portal
# §7/§8). La UI lo usa para asociar una ventana a su equipo sin exponer ids internos.
# El guion es U+2014 (—), no un guion simple.
const TITLE_PREFIX = "Vista del grupo — "
# Token estable cuando el nombre visible del equipo no se conoce (nunca el hid opaco).
const UNKNOWN_LABEL_PREFIX = "equipo "


# Reparto determinista de slots/puertos por hid. Preserva el orden de entrada, omite
# duplicados y hids invalidos (solo atomos seguros, no vacios, <= 64), y capa en
# `max_slots`. `base` (1024..65000) y `max_slots` (1..16) se validan: fuera de rango
# vuelven a sus defaults. Devuelve
#   { "<hid>": {"slot": i, "port": base + 2*i, "cursor_port": base + 2*i + 1} }.
static func assign_slots(peers, base = 5700, max_slots = 4):
	var out = {}
	if typeof(peers) != TYPE_ARRAY:
		return out
	var b = int(base)
	if b < _MIN_BASE or b > _MAX_BASE:
		b = _DEFAULT_BASE
	var m = int(max_slots)
	if m < _MIN_SLOTS or m > _MAX_SLOTS:
		m = _DEFAULT_SLOTS
	var seen = {}
	var slot = 0
	for p in peers:
		if slot >= m:
			break
		var h = _valid_hid(p)
		if h == "" or seen.has(h):
			continue
		seen[h] = true
		out[h] = {"slot": slot, "port": b + 2 * slot, "cursor_port": b + 2 * slot + 1}
		slot += 1
	return out


# Grilla casi-cuadrada de `count` tiles dentro de `viewport` (Vector2), con `gutter`
# entre tiles (>= 0). Sin solapes, cada tile dentro del viewport y bounding box de la
# grilla >= 80% del area del viewport. count <= 0 -> []. count se capa en 16.
static func tile_rects(count, viewport, gutter = 8):
	var out = []
	var c = int(count)
	if c <= 0:
		return out
	if c > _MAX_TILES:
		c = _MAX_TILES
	if typeof(viewport) != TYPE_VECTOR2:
		return out
	var w = viewport.x
	var h = viewport.y
	if w <= 0.0 or h <= 0.0:
		return out
	var g = float(gutter)
	if g < 0.0:
		g = 0.0
	var dims = _grid_dims(c)
	var cols = int(dims[0])
	var rows = int(dims[1])
	var tw = (w - g * float(cols - 1)) / float(cols)
	var th = (h - g * float(rows - 1)) / float(rows)
	if tw <= 0.0 or th <= 0.0:
		g = 0.0
		tw = w / float(cols)
		th = h / float(rows)
	for i in range(c):
		var col = i % cols
		var row = int(floor(float(i) / float(cols)))
		out.append(Rect2(Vector2(float(col) * (tw + g), float(row) * (th + g)),
			Vector2(tw, th)))
	return out


# Disposicion cardinal desde el compas/Grupo. `slots` es el dict de assign_slots y
# `directions` mapea hid -> direccion (north/south/east/west/none). Normaliza cada
# direccion via DIRECTIONS; desconocida o none -> "none". Devuelve
#   { "<hid>": {"slot": i, "dir": d} }.
static func place_by_direction(slots, directions):
	var out = {}
	if typeof(slots) != TYPE_DICTIONARY:
		return out
	var dirs = directions if typeof(directions) == TYPE_DICTIONARY else {}
	for hid in slots.keys():
		var slot = -1
		var e = slots[hid]
		if typeof(e) == TYPE_DICTIONARY and e.has("slot"):
			slot = int(e.slot)
		var d = String(dirs.get(hid, "none")).strip_edges().to_lower()
		if not DIRECTIONS.valid_direction(d):
			d = "none"
		out[String(hid)] = {"slot": slot, "dir": d}
	return out


# Tile "activo" (indice de slot) de la maquina dueña del puntero. pointer_hid vacio
# o ausente en `slots` -> -1.
static func active_slot(pointer_hid, slots):
	var p = String(pointer_hid)
	if p == "" or typeof(slots) != TYPE_DICTIONARY:
		return -1
	if slots.has(p):
		var e = slots[p]
		if typeof(e) == TYPE_DICTIONARY and e.has("slot"):
			return int(e.slot)
	return -1


# Transicion determinista de la maquina de estados por ruta de recepcion. Devuelve el
# estado destino, o el mismo `state` si el par (state, event) no esta previsto (no-op).
#   idle+join -> joining; joining+ready -> live; joining+fail -> failed;
#   live+drop -> degraded; degraded+resume -> live; live+leave -> leaving;
#   degraded+leave -> leaving; leaving+stopped -> stopped; failed+reset -> idle;
#   stopped+reset -> idle; y `fail` desde cualquier estado NO terminal -> failed.
# Token de "equipo desconocido" para el slot i (0-based): "equipo <n>" con n = slot+1.
# Estable y sin filtrar el hid opaco a la UI. Puro.
static func unknown_label(slot):
	return UNKNOWN_LABEL_PREFIX + str(int(slot) + 1)


# Etiqueta visible dentro de un titulo "Vista del grupo — <label>"; "" si no lleva el
# prefijo. Puro.
static func title_label(title):
	var t = String(title)
	if not t.begins_with(TITLE_PREFIX):
		return ""
	return t.substr(TITLE_PREFIX.length()).strip_edges()


# Indice de slot de una etiqueta "equipo <n>" (n = slot+1); -1 si no es ese formato.
# Puro.
static func slot_from_label(label):
	var l = String(label).strip_edges()
	if not l.begins_with(UNKNOWN_LABEL_PREFIX):
		return -1
	var n = l.substr(UNKNOWN_LABEL_PREFIX.length()).strip_edges()
	if not n.is_valid_integer():
		return -1
	var i = int(n) - 1
	return i if i >= 0 else -1


# Asociacion pura ventana -> hid por el titulo del receptor (§7/§8). Preferencias:
#   1) token "equipo N" -> hid cuyo slot == N-1;
#   2) etiqueta visible unica -> ese hid;
#   3) etiqueta duplicada (ambigua) -> desempate por slot (menor slot sin reclamar).
# `claimed` son hids ya asociados (se excluyen). Etiqueta desconocida -> "" (no se
# inventa). `slots` es el dict de assign_slots; `labels` mapea hid -> nombre visible.
static func match_hid(title, slots, labels = {}, claimed = []):
	var label = title_label(title)
	if label == "" or typeof(slots) != TYPE_DICTIONARY:
		return ""
	var taken = {}
	if typeof(claimed) == TYPE_ARRAY:
		for c in claimed:
			taken[String(c)] = true
	var slot = slot_from_label(label)
	if slot >= 0:
		for h in slots.keys():
			var hid = String(h)
			if taken.has(hid):
				continue
			if _slot_of(slots[hid]) == slot:
				return hid
		return ""
	var hits = []
	if typeof(labels) == TYPE_DICTIONARY:
		for h in slots.keys():
			var hid = String(h)
			if taken.has(hid):
				continue
			if String(labels.get(hid, "")).strip_edges() == label:
				hits.append(hid)
	if hits.size() == 1:
		return hits[0]
	if hits.size() > 1:
		var best = ""
		var best_slot = 1 << 30
		for hid in hits:
			var s = _slot_of(slots[hid])
			if s < best_slot:
				best_slot = s
				best = hid
		return best
	return ""


static func _slot_of(entry):
	if typeof(entry) == TYPE_DICTIONARY and entry.has("slot"):
		return int(entry.slot)
	return 1 << 30


static func transition(state, event):
	var s = String(state)
	if not STATES.has(s):
		return s
	match String(event):
		"join":
			if s == "idle":
				return "joining"
		"ready":
			if s == "joining":
				return "live"
		"drop":
			if s == "live":
				return "degraded"
		"resume":
			if s == "degraded":
				return "live"
		"leave":
			if s == "live" or s == "degraded":
				return "leaving"
		"stopped":
			if s == "leaving":
				return "stopped"
		"reset":
			if _is_terminal(s):
				return "idle"
		"fail":
			if not _is_terminal(s):
				return "failed"
	return s


static func _valid_hid(h):
	var s = String(h).strip_edges()
	if s == "" or s.length() > _MAX_HID_LEN:
		return ""
	for i in range(s.length()):
		if _SAFE_CHARS.find(s.substr(i, 1)) < 0:
			return ""
	return s


static func _grid_dims(count):
	var cols = int(ceil(sqrt(float(count))))
	if cols < 1:
		cols = 1
	var rows = int(ceil(float(count) / float(cols)))
	if rows < 1:
		rows = 1
	return [cols, rows]


static func _is_terminal(state):
	return _TERMINAL.has(String(state))


static func selftest():
	var ok = true

	# assign_slots: reparto determinista y puertos como contrato.
	var asg = assign_slots(["peer-a", "peer.b", "peer_c"])
	ok = ok and asg.size() == 3
	ok = ok and asg["peer-a"].slot == 0 and asg["peer-a"].port == 5700 and asg["peer-a"].cursor_port == 5701
	ok = ok and asg["peer.b"].slot == 1 and asg["peer.b"].port == 5702 and asg["peer.b"].cursor_port == 5703
	ok = ok and asg["peer_c"].slot == 2 and asg["peer_c"].port == 5704 and asg["peer_c"].cursor_port == 5705
	# Determinismo: mismas entradas -> mismo dict.
	var asg2 = assign_slots(["peer-a", "peer.b", "peer_c"])
	ok = ok and to_json(asg) == to_json(asg2)
	# Duplicados se omiten (primera aparicion gana).
	var dup = assign_slots(["a", "a", "b"])
	ok = ok and dup.size() == 2 and dup["a"].slot == 0 and dup["b"].slot == 1
	# Cap por max_slots.
	var capped = assign_slots(["a", "b", "c", "d", "e"], 5700, 2)
	ok = ok and capped.size() == 2 and capped.has("a") and capped.has("b")
	# Hids invalidos se omiten; solo atomos seguros.
	var dirty = assign_slots(["ok.hid-x", "bad hid", "", "bad!", "x".repeat(65), "ok2"])
	ok = ok and dirty.size() == 2 and dirty.has("ok.hid-x") and dirty.has("ok2")
	# base fuera de rango vuelve al default.
	var defbase = assign_slots(["a"], 500, 4)
	ok = ok and defbase["a"].port == 5700
	# max_slots invalido vuelve al default (4).
	var defslots = assign_slots(["a", "b", "c", "d", "e"], 5700, 0)
	ok = ok and defslots.size() == 4
	# No-array -> {}.
	ok = ok and assign_slots("nope").empty()
	# Ningun puerto (video o cursor) colisiona entre slots.
	var ports = {}
	var collision = false
	for hid in asg.keys():
		for k in ["port", "cursor_port"]:
			var p = int(asg[hid][k])
			if ports.has(p):
				collision = true
			ports[p] = true
	ok = ok and not collision

	# tile_rects: grilla sin solapes dentro del viewport, bbox >= 80% del area.
	var vp = Vector2(800, 600)
	var rects4 = tile_rects(4, vp, 8)
	ok = ok and rects4.size() == 4
	ok = ok and _rects_within(rects4, vp)
	ok = ok and not _rects_overlap(rects4)
	ok = ok and _bbox_ratio(rects4, vp) >= 0.8
	var rects1 = tile_rects(1, vp, 8)
	ok = ok and rects1.size() == 1 and _rects_within(rects1, vp)
	ok = ok and rects1[0].size.x == vp.x and rects1[0].size.y == vp.y
	ok = ok and tile_rects(0, vp, 8).empty()
	ok = ok and tile_rects(-3, vp, 8).empty()
	var rects_clamped = tile_rects(100, vp, 8)
	ok = ok and rects_clamped.size() == 16
	ok = ok and not _rects_overlap(rects_clamped)
	ok = ok and _rects_within(rects_clamped, vp)
	var rects3 = tile_rects(3, vp, 8)
	ok = ok and not _rects_overlap(rects3) and _rects_within(rects3, vp)
	ok = ok and _bbox_ratio(rects3, vp) >= 0.8
	# Gutter absurdo cae a 0 sin producir tiles con tamano <= 0.
	var tinytight = tile_rects(4, Vector2(10, 10), 40)
	ok = ok and tinytight.size() == 4 and _rects_within(tinytight, Vector2(10, 10))

	# place_by_direction: normaliza via DIRECTIONS; desconocida -> none.
	var placed = place_by_direction(asg, {"peer-a": "north", "peer.b": "up", "peer_c": "none"})
	ok = ok and placed.size() == 3
	ok = ok and placed["peer-a"].dir == "north" and placed["peer-a"].slot == 0
	ok = ok and placed["peer.b"].dir == "none" and placed["peer.b"].slot == 1
	ok = ok and placed["peer_c"].dir == "none"
	# Sin direcciones -> todo none.
	var placed_empty = place_by_direction(asg, {})
	ok = ok and placed_empty["peer-a"].dir == "none"
	ok = ok and place_by_direction("nope", {}).empty()

	# active_slot: dueño del puntero y casos sin foco.
	ok = ok and active_slot("peer.b", asg) == 1
	ok = ok and active_slot("peer-a", asg) == 0
	ok = ok and active_slot("", asg) == -1
	ok = ok and active_slot("desconocido", asg) == -1
	ok = ok and active_slot("peer-a", {}) == -1

	# Titulo -> hid (F4/§7): prefijo, token "equipo N", etiqueta unica, ambiguedad por
	# slot y exclusion de los ya reclamados. Nunca devuelve el hid por accidente.
	ok = ok and TITLE_PREFIX == "Vista del grupo — "
	ok = ok and unknown_label(0) == "equipo 1" and unknown_label(2) == "equipo 3"
	ok = ok and title_label("Vista del grupo — Sala") == "Sala"
	ok = ok and title_label("Pantalla compartida") == ""
	ok = ok and slot_from_label("equipo 2") == 1
	ok = ok and slot_from_label("Sala") == -1
	ok = ok and match_hid("Vista del grupo — equipo 2", asg) == "peer.b"
	ok = ok and match_hid("Vista del grupo — Sala", asg, {"peer.b": "Sala"}) == "peer.b"
	ok = ok and match_hid("Vista del grupo — Nadie", asg, {"peer.b": "Sala"}) == ""
	ok = ok and match_hid("Vista del grupo — Repetido", asg,
		{"peer-a": "Repetido", "peer.b": "Repetido"}) == "peer-a"
	ok = ok and match_hid("Vista del grupo — Repetido", asg,
		{"peer-a": "Repetido", "peer.b": "Repetido"}, ["peer-a"]) == "peer.b"
	ok = ok and match_hid("Otra cosa", asg) == ""

	# transition: tabla completa.
	ok = ok and transition("idle", "join") == "joining"
	ok = ok and transition("joining", "ready") == "live"
	ok = ok and transition("joining", "fail") == "failed"
	ok = ok and transition("live", "drop") == "degraded"
	ok = ok and transition("degraded", "resume") == "live"
	ok = ok and transition("live", "leave") == "leaving"
	ok = ok and transition("degraded", "leave") == "leaving"
	ok = ok and transition("leaving", "stopped") == "stopped"
	ok = ok and transition("stopped", "reset") == "idle"
	ok = ok and transition("failed", "reset") == "idle"
	# fail desde cualquier estado no terminal -> failed.
	ok = ok and transition("idle", "fail") == "failed"
	ok = ok and transition("live", "fail") == "failed"
	ok = ok and transition("degraded", "fail") == "failed"
	ok = ok and transition("leaving", "fail") == "failed"
	# Terminales no cambian con fail.
	ok = ok and transition("stopped", "fail") == "stopped"
	ok = ok and transition("failed", "fail") == "failed"
	# Pares no previstos: no-op.
	ok = ok and transition("idle", "ready") == "idle"
	ok = ok and transition("live", "join") == "live"
	ok = ok and transition("stopped", "join") == "stopped"
	ok = ok and transition("live", "reset") == "live"
	ok = ok and transition("joining", "leave") == "joining"

	assert(ok, "selftest de multiview_model")
	return ok


func run_selftest():
	return selftest()


static func _rects_overlap(rects):
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			var a = rects[i]
			var b = rects[j]
			if a.position.x + _EPS < b.position.x + b.size.x \
					and b.position.x + _EPS < a.position.x + a.size.x \
					and a.position.y + _EPS < b.position.y + b.size.y \
					and b.position.y + _EPS < a.position.y + a.size.y:
				return true
	return false


static func _rects_within(rects, viewport):
	for r in rects:
		if r.position.x < -_EPS or r.position.y < -_EPS:
			return false
		if r.position.x + r.size.x > viewport.x + _EPS:
			return false
		if r.position.y + r.size.y > viewport.y + _EPS:
			return false
	return true


static func _bbox_ratio(rects, viewport):
	if rects.empty() or viewport.x <= 0.0 or viewport.y <= 0.0:
		return 0.0
	var minx = 1e20
	var miny = 1e20
	var maxx = -1e20
	var maxy = -1e20
	for r in rects:
		minx = min(minx, r.position.x)
		miny = min(miny, r.position.y)
		maxx = max(maxx, r.position.x + r.size.x)
		maxy = max(maxy, r.position.y + r.size.y)
	return ((maxx - minx) * (maxy - miny)) / (viewport.x * viewport.y)
