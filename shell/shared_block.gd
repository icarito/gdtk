extends Reference

# K10b — Bloques "Compartido" del Frame (SPEC-ui-rework-2026-10).
#
# Lógica PURA de las sesiones compartidas con vecinos: a partir de snapshots ya
# cacheados por el shell decide qué bloques de control mostrar (uno por equipo y
# tipo), su tipo (pantalla / teclado y mouse / portapapeles), su estado
# (conectando / activo / error) y el menú contextual ("Detener", "Ver detalles").
#
# Sin procesos, sin red, sin filesystem y sin estado global: el Frame sólo dibuja
# lo que devuelve este módulo y delega la ejecución al shell. El estado se lee de
# caches (host_session_state y el snapshot de servicios) para no bloquear el hilo
# de render.
#
# Vocabulario obligatorio (SPEC-ui-rework-2026-10): nunca se muestran los nombres
# internos (gvd, deskflow, role, hid, kind, mDNS, DNS-SD, recv, server/client,
# puertos); para eso está neighborhood_map.has_internal_terms.

# Mapa de vocabulario puro compartido con el Vecindario (no se modifica).
const MAP = preload("res://neighborhood_map.gd")

const TYPES = ["screen", "input", "clipboard"]
const TYPE_LABELS = {
	"screen": "pantalla",
	"input": "teclado y mouse",
	"clipboard": "portapapeles",
}
# Estados visibles: "idle" no llega a bloque; sólo los tres que se muestran.
const STATES = ["starting", "active", "error"]
const STATE_LABELS = {
	"starting": "conectando",
	"active": "activo",
	"error": "error",
}
# Menú contextual del bloque, en lenguaje humano.
const MENU = [
	{"id": "stop", "label": "Detener"},
	{"id": "details", "label": "Ver detalles"},
]
# Glifo corto por tipo (la insignia dibujada; no es texto visible obligatorio).
const TYPE_GLYPHS = {"screen": "monitor", "input": "keyboard", "clipboard": "clipboard"}

# --- Dockapp "Compartiendo" (G5): bloque-resumen con mini-diagrama ----------
# Lados del diagrama, en orden de lectura N/S/E/O.
const DIAGRAM_SIDES = ["north", "south", "east", "west"]
# El diagrama sólo distingue pantalla y control compartido: el portapapeles
# dejó de ser una opción visible (se asume compartido con "Controlar").
const DIAGRAM_TYPES = ["screen", "input"]


static func valid_type(t):
	return TYPES.has(String(t).strip_edges())


static func valid_state(s):
	return STATES.has(String(s).strip_edges())


static func type_label(t):
	var k = String(t).strip_edges()
	return String(TYPE_LABELS[k]) if TYPE_LABELS.has(k) else ""


static func state_text(s):
	var k = String(s).strip_edges()
	return String(STATE_LABELS[k]) if STATE_LABELS.has(k) else ""


# Identificador estable del bloque: equipo + tipo. El Frame lo usa para el hit
# test y para recordar qué menú está abierto.
static func block_id(host, type):
	return String(host).strip_edges() + ":" + String(type).strip_edges()


# Título visible del bloque: nombre del equipo + tipo, sin jerga.
static func title_for(label, type):
	var l = String(label).strip_edges()
	var t = type_label(type)
	if t == "":
		return l
	return (l + " · " + t) if l != "" else t


# Detalle humano del bloque (tooltip / "Ver detalles").
static func detail_for(label, type, state, reason = ""):
	var parts = []
	if String(label).strip_edges() != "":
		parts.append(String(label).strip_edges())
	if type_label(type) != "":
		parts.append(type_label(type))
	if state_text(state) != "":
		parts.append(state_text(state))
	var text = PoolStringArray(parts).join(" · ")
	var r = String(reason).strip_edges()
	if r != "":
		text += " — " + r
	return text


# Motivo en español sin nombres internos: si el original trae jerga, se sustituye
# por un texto genérico. Puro.
static func safe_reason(raw):
	var t = String(raw).strip_edges()
	if t == "":
		return ""
	if MAP.has_internal_terms(t):
		return "error de conexión"
	return t


# Normaliza una sesión cruda a bloque. Devuelve {} si no es válida.
static func make_block(session):
	if typeof(session) != TYPE_DICTIONARY:
		return {}
	var host = String(session.get("host", session.get("hid", ""))).strip_edges()
	var type = String(session.get("type", "")).strip_edges()
	if host == "" or not valid_type(type):
		return {}
	var state = String(session.get("state", "active")).strip_edges()
	if not valid_state(state):
		state = "active"
	var reason = safe_reason(session.get("reason", ""))
	if state == "error" and reason == "":
		# Sin motivo real no se finge un error.
		state = "active"
	var label = String(session.get("label", host)).strip_edges()
	if label == "":
		label = host
	return {
		"id": block_id(host, type),
		"host": host,
		"type": type,
		"type_label": type_label(type),
		"state": state,
		"state_text": state_text(state),
		"label": label,
		"reason": reason,
		"title": title_for(label, type),
		"detail": detail_for(label, type, state, reason),
		"glyph": String(TYPE_GLYPHS.get(type, "")),
	}


# Lista normalizada y determinista (host ordenado; por host: pantalla, teclado y
# mouse, portapapeles). `sessions` es [{host, type, state, label, reason}].
static func build(sessions):
	var out = []
	if typeof(sessions) != TYPE_ARRAY:
		return out
	var seen = {}
	for s in sessions:
		var b = make_block(s)
		if b.empty():
			continue
		if seen.has(b.id):
			continue
		seen[b.id] = true
		out.append(b)
	return out


# Construye los bloques a partir de los snapshots cacheados del shell. PURA: no
# consulta procesos ni disco; recibe valores ya leídos.
#   host_session:    {hid: "idle"|"starting"|"active"}  (shell._host_session_state)
#   screen:          {hid: bool}  sesión de pantalla viva (gvd_session_pids por hid)
#   input:           {hid: bool}  intención de compartir teclado/mouse (host_deskflow)
#   clipboard:       {hid: bool}  portapapeles compartido (host_clipboard)
#   service_running: bool         servicio de control vivo (snapshot de service_pids)
#   labels:          {hid: nombre visible}
#   errors:          {hid: motivo}  orden fallida para ese equipo
static func from_cache(host_session, screen, input, clipboard, service_running,
		labels = {}, errors = {}):
	var hs = host_session if typeof(host_session) == TYPE_DICTIONARY else {}
	var sc = screen if typeof(screen) == TYPE_DICTIONARY else {}
	var inp = input if typeof(input) == TYPE_DICTIONARY else {}
	var clip = clipboard if typeof(clipboard) == TYPE_DICTIONARY else {}
	var lb = labels if typeof(labels) == TYPE_DICTIONARY else {}
	var er = errors if typeof(errors) == TYPE_DICTIONARY else {}
	var hids = []
	for k in hs.keys():
		_add_unique(hids, String(k))
	for k in sc.keys():
		_add_unique(hids, String(k))
	for k in inp.keys():
		_add_unique(hids, String(k))
	for k in clip.keys():
		_add_unique(hids, String(k))
	hids.sort()
	var sessions = []
	for hid in hids:
		var agg = String(hs.get(hid, "idle")).strip_edges()
		var name = String(lb.get(hid, hid)).strip_edges()
		if name == "":
			name = hid
		var reason = String(er.get(hid, "")).strip_edges()
		# Un motivo de fallo convierte todos los bloques del equipo en error.
		var explicit = false
		if bool(sc.get(hid, false)):
			explicit = true
			var st = "starting" if agg == "starting" else "active"
			sessions.append({"host": hid, "type": "screen", "state": _state(st, reason),
				"label": name, "reason": reason})
		# El control compartido sólo es real si el servicio está vivo o el equipo
		# está arrancando: una intención vieja sin servicio no finge sesión.
		if bool(inp.get(hid, false)) and (bool(service_running) or agg != "idle"):
			explicit = true
			var ist = "active" if bool(service_running) else "starting"
			sessions.append({"host": hid, "type": "input", "state": _state(ist, reason),
				"label": name, "reason": reason})
		if bool(clip.get(hid, false)):
			explicit = true
			sessions.append({"host": hid, "type": "clipboard",
				"state": _state("active", reason), "label": name, "reason": reason})
		# Lanzamiento en curso sin tipo explícito: es la pantalla (el control
		# compartido sí se anuncia por host_deskflow). No se inventa el tipo.
		if not explicit and agg == "starting":
			sessions.append({"host": hid, "type": "screen", "state": _state("starting", reason),
				"label": name, "reason": reason})
	return build(sessions)


# Filas del menú contextual del bloque (siempre disponibles salvo que el bloque
# ya no exista). Puro para test.
static func menu(block):
	var rows = []
	if typeof(block) != TYPE_DICTIONARY or String(block.get("id", "")) == "":
		return rows
	for m in MENU:
		rows.append({"id": String(m.id), "label": String(m.label),
			"enabled": true, "reason": ""})
	return rows


# --- Dockapp "Compartiendo": bloque-resumen con mini-diagrama (G5) ----------
# `diagram(sessions, remote_shares, windows)` arma UN bloque para la dockapp:
#   sides: {north, south, east, west} -> [{type, peer_name, initial, state, origin}]
#   menu:  filas {kind: "action"|"separator", id, label, enabled, reason}
#   tooltip: texto humano de qué se comparte y con quién
#   sessions:      como lo devuelve from_cache() (bloques {host, type, state, label}),
#                  cada uno con `side`/`direction` (north/south/east/west) del lado
#                  hacia el que se comparte. Es local (origin "local").
#   remote_shares: [{peer_name, type, side, state}] recibido del otro equipo; el
#                  lado YA viene invertido por el emisor (no se invierte acá).
#   windows:       [{id, title, peer_name, maximized}] ventanas de pantalla extendida.
# Sin sesiones, remotos ni ventanas devuelve {} para que el Frame no dibuje nada.
# Puro: sin red, procesos ni disco.
static func diagram(sessions, remote_shares, windows, placements = {}, focus = {}):
	var entries = []
	for s in _as_array(sessions):
		var e = _diagram_entry(s, "local")
		if not e.empty():
			entries.append(e)
	for r in _as_array(remote_shares):
		var e2 = _diagram_entry(r, "remote")
		if not e2.empty():
			entries.append(e2)
	var wlist = _diagram_windows(windows)
	if entries.empty() and wlist.empty():
		return {}
	entries = _ordered_entries(entries)
	var sides = {"north": [], "south": [], "east": [], "west": []}
	for e in entries:
		sides[e.side].append(_public_entry(e))
	return {
		"sides": sides,
		"menu": _diagram_menu(entries, wlist),
		"tooltip": _diagram_tooltip(entries, wlist),
		"radial": radial(sessions, remote_shares, windows, placements, focus),
		"local_focus": not bool(_as_dict(focus).get("capturing", false)),
	}


# --- Vista radial (N10) ------------------------------------------------------
# Ángulos en grados, sentido horario en pantalla (y hacia abajo): este 0, sur 90,
# oeste 180, norte 270. El equipo local va al centro; cada par en su ángulo.
const SIDE_ANGLES = {"east": 0.0, "south": 90.0, "west": 180.0, "north": 270.0}
# Separación entre pares que caen en el mismo ángulo base.
const RADIAL_SPREAD = 28.0


# Un elemento por par (equipo vecino), fusionando pantalla/teclado/ventanas:
#   {key, peer_name, label, initial, angle, kind: "screen"|"input"|"both",
#    direction: "out" (controlas)|"in" (te controla)|"both"|"none",
#    state, focused, screen, input, viewing}
# `placements`: {clave o nombre: grados} guardado por la vista Grupo; sin él, el lado
# de la sesión. `focus`: {capturing: bool, peer: clave/nombre opcional}; con captura
# activa el foco está en el par que controlas (y no en este equipo). Puro.
static func radial(sessions, remote_shares, windows, placements = {}, focus = {}):
	var pl = _as_dict(placements)
	var fc = _as_dict(focus)
	var peers = {}
	var order = []
	var raw = []
	for s in _as_array(sessions):
		var e = _diagram_entry(s, "local")
		if not e.empty():
			raw.append(e)
	for r in _as_array(remote_shares):
		var e2 = _diagram_entry(r, "remote")
		if not e2.empty():
			raw.append(e2)
	for e in raw:
		var p = _radial_peer(peers, order, String(e.peer_name), String(e.key))
		if String(p.side) == "":
			p.side = String(e.side)
		var dir = "out" if String(e.origin) == "local" else "in"
		if String(e.type) == "input":
			p.input = true
			p.in_dirs[dir] = true
		else:
			p.screen = true
			p.scr_dirs[dir] = true
		p.state = _worse_state(String(p.state), String(e.state))
	for w in _diagram_windows(windows):
		var name = String(w.peer_name)
		if name == "":
			continue
		var pw = _radial_peer(peers, order, name, name)
		pw.screen = true
		pw.viewing = true
		pw.scr_dirs["in"] = true
	order.sort()
	var out = []
	var slot = {}
	for k in order:
		var p = peers[k]
		var angle = _placement_angle(pl, p)
		if angle < 0.0:
			var base = float(SIDE_ANGLES.get(String(p.side), 270.0))
			var n = int(slot.get(base, 0))
			slot[base] = n + 1
			# 0, +28, -28, +56... alrededor del ángulo base.
			angle = base + float((n + 1) / 2) * RADIAL_SPREAD * (1.0 if n % 2 == 1 else -1.0)
		angle = fposmod(angle, 360.0)
		var dirs = p.in_dirs if p.input else p.scr_dirs
		var direction = "none"
		if dirs.has("out") and dirs.has("in"):
			direction = "both"
		elif dirs.has("out"):
			direction = "out"
		elif dirs.has("in"):
			direction = "in"
		var fpeer = String(fc.get("peer", ""))
		var focused = bool(fc.get("capturing", false)) and p.input and dirs.has("out") \
			and (fpeer == "" or fpeer == String(p.key) or fpeer == String(p.name))
		out.append({"key": p.key, "peer_name": p.name, "label": p.name,
			"initial": peer_initial(p.name), "angle": angle,
			"kind": "both" if (p.input and p.screen) else ("input" if p.input else "screen"),
			"direction": direction, "state": p.state, "focused": focused,
			"screen": p.screen, "input": p.input, "viewing": p.viewing})
	return out


static func _radial_peer(peers, order, name, key):
	var id = name
	if not peers.has(id):
		peers[id] = {"name": name, "key": key, "side": "", "screen": false, "input": false,
			"viewing": false, "state": "active", "in_dirs": {}, "scr_dirs": {}}
		order.append(id)
	return peers[id]


static func _placement_angle(pl, p):
	for k in [String(p.key), String(p.name)]:
		if pl.has(k) and (typeof(pl[k]) == TYPE_REAL or typeof(pl[k]) == TYPE_INT):
			return fposmod(float(pl[k]), 360.0)
	return -1.0


# error > conectando > activo.
static func _worse_state(a, b):
	for s in ["error", "starting"]:
		if a == s or b == s:
			return s
	return "active"


static func _as_dict(v):
	return v if typeof(v) == TYPE_DICTIONARY else {}


static func valid_side(s):
	return DIAGRAM_SIDES.has(String(s).strip_edges())


# Inicial visible del equipo (una letra, sin exponer ids opacos).
static func peer_initial(peer):
	var s = String(peer).strip_edges()
	for i in range(s.length()):
		var c = s[i]
		var up = c.to_upper()
		if up != c.to_lower():
			return up
	return "#"


static func _as_array(v):
	return v if typeof(v) == TYPE_ARRAY else []


# Normaliza una sesión o un share remoto a una entrada del diagrama. Devuelve {}
# si no es ubicable (tipo/lado inválidos, estado "stopped" o sin equipo).
static func _diagram_entry(raw, origin):
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var t = String(raw.get("type", "")).strip_edges()
	if not DIAGRAM_TYPES.has(t):
		return {}
	var side = String(raw.get("side", raw.get("direction", ""))).strip_edges()
	if not DIAGRAM_SIDES.has(side):
		return {}
	var peer = String(raw.get("peer_name", raw.get("label", raw.get("host", "")))).strip_edges()
	if peer == "":
		return {}
	var state = String(raw.get("state", "active")).strip_edges()
	if state == "stopped":
		return {}
	if not valid_state(state):
		state = "active"
	# Clave estable para los ids del menú: host/id si están, si no el nombre.
	var key = String(raw.get("host", raw.get("id", peer))).strip_edges()
	if key == "":
		key = peer
	return {"type": t, "peer_name": peer, "initial": peer_initial(peer),
		"state": state, "origin": origin, "side": side, "key": key}


static func _public_entry(e):
	return {"type": e.type, "peer_name": e.peer_name, "initial": e.initial,
		"state": e.state, "origin": e.origin}


static func _ordered_entries(entries):
	var keys = []
	var map = {}
	var i = 0
	for e in entries:
		var si = DIAGRAM_SIDES.find(String(e.side))
		if si < 0:
			si = DIAGRAM_SIDES.size()
		var k = String(int(si)).pad_zeros(2) + "\t" + String(e.peer_name) \
			+ "\t" + String(e.type) + "\t" + String(i).pad_zeros(4)
		keys.append(k)
		map[k] = e
		i += 1
	keys.sort()
	var out = []
	for k in keys:
		out.append(map[k])
	return out


static func _diagram_windows(windows):
	var out = []
	for w in _as_array(windows):
		if typeof(w) != TYPE_DICTIONARY:
			continue
		var id = String(w.get("id", "")).strip_edges()
		if id == "":
			continue
		var peer = String(w.get("peer_name", w.get("title", ""))).strip_edges()
		out.append({"id": id, "peer_name": peer, "maximized": bool(w.get("maximized", false))})
	var keys = []
	var map = {}
	for w in out:
		keys.append(String(w.id))
		map[String(w.id)] = w
	keys.sort()
	var sorted = []
	for k in keys:
		sorted.append(map[k])
	return sorted


static func _menu_action(id, label):
	return {"kind": "action", "id": id, "label": label, "enabled": true, "reason": ""}


static func _diagram_menu(entries, windows):
	var stops = []
	for e in entries:
		if String(e.type) == "screen":
			stops.append(_menu_action("stop:screen:" + String(e.key),
				"Dejar de extender a " + String(e.peer_name)))
		else:
			stops.append(_menu_action("stop:input:" + String(e.key),
				"Dejar de compartir teclado y mouse con " + String(e.peer_name)))
	var wins = []
	for w in windows:
		var id = String(w.id)
		var who = String(w.peer_name)
		var show = "Mostrar pantalla" if who == "" else "Mostrar pantalla de " + who
		wins.append(_menu_action("win_show:" + id, show))
		wins.append(_menu_action("win_max:" + id, "Restaurar" if bool(w.maximized) else "Maximizar"))
		wins.append(_menu_action("win_close:" + id, "Cerrar"))
	var rows = []
	if not stops.empty():
		rows += stops
	if not wins.empty():
		if not rows.empty():
			rows.append({"kind": "separator"})
		rows += wins
	if not rows.empty():
		rows.append({"kind": "separator"})
	rows.append(_menu_action("open_group", "Abrir Grupo"))
	return rows


static func _diagram_tooltip(entries, windows):
	var parts = []
	for e in entries:
		var dir = String(MAP.DIRECTION_LABELS.get(String(e.side), String(e.side)))
		var what = type_label(e.type)
		if String(e.origin) == "local":
			parts.append(what + " con " + String(e.peer_name) + " al " + dir)
		else:
			parts.append(String(e.peer_name) + " comparte " + what + " desde el " + dir)
	if not windows.empty():
		var n = windows.size()
		parts.append(String(n) + (" ventana compartida" if n == 1 else " ventanas compartidas"))
	return "Compartiendo: " + PoolStringArray(parts).join("; ")


# Frase de foco para el tooltip: dónde están ahora el puntero y el teclado.
static func focus_text(radial_list, local_focus):
	if local_focus:
		return "El teclado y el mouse están en este equipo"
	for p in _as_array(radial_list):
		if bool(p.get("focused", false)):
			return "Controlando a " + String(p.peer_name)
	return "El teclado y el mouse están en otro equipo"


# ¿El punto cae en algún bloque del snapshot de layout? Puro respecto de rects
# {id, x, y, w, h} (los produce el dibujo del Frame).
static func hit(pos, layout):
	if typeof(layout) != TYPE_ARRAY:
		return null
	var p = Vector2(pos)
	for it in layout:
		if typeof(it) != TYPE_DICTIONARY:
			continue
		var x = float(it.get("x", 0.0))
		var y = float(it.get("y", 0.0))
		var w = float(it.get("w", 0.0))
		var h = float(it.get("h", 0.0))
		if p.x >= x and p.x < x + w and p.y >= y and p.y < y + h:
			return it
	return null


static func block_by_id(blocks, id):
	if typeof(blocks) != TYPE_ARRAY:
		return null
	var k = String(id)
	for b in blocks:
		if typeof(b) == TYPE_DICTIONARY and String(b.get("id", "")) == k:
			return b
	return null


static func _add_unique(list, v):
	if not list.has(v):
		list.append(v)


static func _state(base, reason):
	return "error" if String(reason).strip_edges() != "" else base
