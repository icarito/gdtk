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
