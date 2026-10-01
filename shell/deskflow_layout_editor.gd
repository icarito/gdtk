extends Reference

# Editor PURO del layout de Deskflow (SPEC-screen-share-compass §3/§6/§10, K5).
#
# Fuente unica de layout: la direccion N/S/E/O por host (`host_directions`,
# persistida por el shell en neighborhood-directions.json via
# neighborhood_directions.merge/to_json). De ESA MISMA asignacion se derivan los
# dos mecanismos:
#   - gvd pantalla:  direction -> `gvd --position` (north=above, south=below,
#                    east=right, west=left);
#   - Deskflow:      direction -> arista (north=up, south=down, east=right,
#                    west=left), y `to_links()` alimenta build_server_conf.
#
# Puro: no ejecuta procesos, no toca el filesystem y no consulta red. La UI solo
# le pasa snapshots (hosts del modelo, `directions` ya leido) y lee el estado; el
# shell es el unico que escribe/persiste (apply_deskflow_layout).
#
# Modelo: una asignacion por host (host_id -> direccion cardinal), de modo que un
# host nunca ocupa dos slots. La cuadricula 3x3 reserva el centro para la pantalla
# local (fija) y las cuatro celdas N/S/E/O para los vecinos. Un slot con mas de un
# owner (semilla inconsistente) es un CONFLICTO de borde: la UI lo pinta rojo y
# bloquea "Aplicar".

const DIRECTIONS = preload("res://neighborhood_directions.gd")
const LAYOUT = preload("res://deskflow_layout.gd")
const CONF = preload("res://deskflow_conf.gd")

const SLOTS = ["north", "south", "east", "west"]
const SLOT_LABELS = {"north": "N", "south": "S", "east": "E", "west": "O"}
# Estado que "Aplicar" persiste en host_directions: confirmada, extend y vinculo
# por ambos mecanismos (misma asignacion para gvd y Deskflow).
const APPLY_CONFIRM = "confirmed"
const APPLY_MODE = "extend"
const APPLY_LINK = "deskflow+gvd"
# Mismos caracteres seguros que neighborhood_actions para nombres de pantalla.
const _SAFE_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"

var local_name = "gdtk-local"   # pantalla central (esta equipo), fija
var selected = ""               # host_id elegido por la UI (ficha)
var _hosts = []                 # [{id,label,kind,deskflow,gvd,degraded}]
var _labels = {}                # host_id -> label
var _assign = {}                # host_id -> direccion cardinal
var _original = {}              # host_id -> entry original de host_directions


# --- setup -------------------------------------------------------------------

# Nombre local seguro para la pantalla central. Invalido -> "gdtk-local".
func set_local_name(name):
	var n = String(name).strip_edges()
	local_name = n if LAYOUT.valid_peer(n) else "gdtk-local"


# Normaliza un host del modelo (neighborhood_hosts) a lo que la UI necesita.
static func normalize_host(host):
	if typeof(host) != TYPE_DICTIONARY:
		return null
	var id = String(host.get("id", host.get("hid", ""))).strip_edges()
	if id == "":
		return null
	var caps = host.get("capabilities", {})
	if typeof(caps) != TYPE_DICTIONARY:
		caps = {}
	return {
		"id": id,
		"label": String(host.get("label", id)).strip_edges(),
		"kind": String(host.get("kind", "")).strip_edges(),
		"deskflow": caps.has("deskflow"),
		"gvd": caps.has("gvd"),
		"degraded": bool(host.get("degraded", false)),
	}


func set_hosts(hosts):
	_hosts = []
	_labels = {}
	if typeof(hosts) != TYPE_ARRAY:
		return
	for h in hosts:
		var n = normalize_host(h)
		if n == null or _labels.has(String(n.id)):
			continue
		_hosts.append(n)
		_labels[String(n.id)] = String(n.label)
	# Orden determinista de las fichas: no depende del orden de discovery.
	_hosts = _sorted(_hosts)


# Nombre ascendente (sin distinguir mayúsculas) y, a igual nombre, id ascendente.
static func _sorted(hosts):
	var arr = []
	for h in hosts:
		arr.append(h)
	var n = arr.size()
	for i in range(n):
		for j in range(i + 1, n):
			var la = String(arr[j].get("label", "")).strip_edges().to_lower()
			var lb = String(arr[i].get("label", "")).strip_edges().to_lower()
			var before = la < lb if la != lb else String(arr[j].get("id", "")) < String(arr[i].get("id", ""))
			if before:
				var tmp = arr[i]
				arr[i] = arr[j]
				arr[j] = tmp
	return arr


func hosts():
	return _hosts


func host_ids():
	var out = []
	for h in _hosts:
		out.append(String(h.id))
	return out


func host(id):
	var s = String(id)
	for h in _hosts:
		if String(h.id) == s:
			return h
	return null


func has_host(id):
	return _labels.has(String(id))


func host_label(id):
	return String(_labels.get(String(id), String(id)))


# ¿El host participa de la cuadricula? (tiene Deskflow o gvd, o ya tiene
# direccion). La UI lo usa para dibujar fichas sin inventar participantes.
func is_candidate(id):
	var s = String(id)
	if _labels.has(s):
		for h in _hosts:
			if String(h.id) == s:
				return bool(h.deskflow) or bool(h.gvd) or direction_of(s) != ""
	if _original.has(s):
		return true
	return false


# --- seeding -----------------------------------------------------------------

# Semilla desde host_directions (fuente unica). Guarda TODO lo original (aunque
# el host no este en el modelo) para no perder direcciones al aplicar. Reinicia
# la asignacion (reabrir el editor parte del estado persistido).
func seed_from_directions(dirs):
	_original = {}
	_assign = {}
	if typeof(dirs) != TYPE_DICTIONARY:
		return
	for k in dirs.keys():
		var entry = DIRECTIONS.sanitize_entry(dirs[k])
		_original[String(k)] = entry
		if SLOTS.has(entry.direction):
			_assign[String(k)] = entry.direction


# Semilla desde el conf real (K4), SOLO para hosts que aun no tienen direccion
# en host_directions. `links` = [{direction, peer}] de parse_server_conf; el peer
# se empareja con host_id, nombre seguro o label.
func seed_from_links(links):
	if typeof(links) != TYPE_ARRAY:
		return
	for l in links:
		if typeof(l) != TYPE_DICTIONARY:
			continue
		var d = String(l.get("direction", ""))
		if not SLOTS.has(d):
			continue
		var id = _host_by_name(String(l.get("peer", "")))
		if id == "" or _assign.has(id):
			continue
		_assign[id] = d


func seed_from_conf(text):
	var parsed = CONF.parse_server_conf(String(text))
	seed_from_links(parsed.get("local_links", []))


# Vuelve al estado inicial (lo leido al abrir el editor).
func reset():
	_assign = {}
	selected = ""
	for k in _original.keys():
		var e = _original[k]
		if SLOTS.has(e.direction):
			_assign[String(k)] = e.direction


func _host_by_name(name):
	var n = String(name).strip_edges()
	if n == "":
		return ""
	for h in _hosts:
		if String(h.id) == n:
			return String(h.id)
	for h in _hosts:
		if peer_name(String(h.id)) == n or String(h.label) == n:
			return String(h.id)
	return ""


# --- edicion -----------------------------------------------------------------

# Clic en ficha: selecciona o deselecciona.
func select(id):
	var s = String(id)
	selected = "" if selected == s else s


func direction_of(id):
	return String(_assign.get(String(id), ""))


# Hosts asignados a una celda, ordenados. >1 => conflicto.
func slot_owners(direction):
	var d = String(direction)
	var out = []
	for id in _assign.keys():
		if String(_assign[id]) == d:
			out.append(String(id))
	out.sort()
	return out


# Un host por slot: devuelve el host si la celda esta vacia o unica; en conflicto
# (mas de uno) devuelve "" y la UI usa slot_owners().
func slot_owner(direction):
	var owners = slot_owners(direction)
	return owners[0] if owners.size() == 1 else ""


# Asigna un host a una celda. Un host un slot (se mueve de la celda anterior) y
# un host por slot (reemplaza al ocupante previo). Devuelve false si no aplica.
func assign(id, direction):
	var s = String(id)
	var d = String(direction)
	if s == "" or not SLOTS.has(d) or not has_host(s):
		return false
	for other in _assign.keys():
		if String(other) != s and String(_assign[other]) == d:
			_assign.erase(other)
	_assign[s] = d
	return true


func clear_slot(direction):
	var d = String(direction)
	for id in _assign.keys():
		if String(_assign[id]) == d:
			_assign.erase(id)


func remove_host(id):
	_assign.erase(String(id))


# --- consultas ---------------------------------------------------------------

# Conflictos de borde (dos hosts en la misma direccion): [{direction, hids}].
func conflicts():
	return DIRECTIONS.edge_conflicts(to_directions_dict())


func has_conflict():
	return not conflicts().empty()


# ¿Hay cambios sin aplicar respecto a lo leido al abrir?
func is_dirty():
	for k in _original.keys():
		var e = _original[k]
		var before = e.direction if SLOTS.has(e.direction) else ""
		if direction_of(k) != before:
			return true
	for id in _assign.keys():
		if not _original.has(id):
			return true
	return false


# Nombre seguro de pantalla (para conf/links), derivado del label o del id.
func peer_name(id):
	return _safe_peer_name(host_label(id), String(id))


# Links de control Deskflow: [{direction, host, peer}], orden deterministico por
# cuadricula. Solo hosts asignados (un owner por slot; en conflicto van todos y
# "Aplicar" queda bloqueado).
func to_links():
	var out = []
	for d in SLOTS:
		for id in slot_owners(d):
			out.append({"direction": d, "host": id, "peer": peer_name(id)})
	return out


# Payload de "Aplicar": links validos + entradas "none" para direcciones que el
# editor tenia y ya no (para que el shell las borre). La firma sigue siendo una
# lista de links; el shell ignora "none" para el conf y la usa para host_directions.
func to_apply():
	var out = to_links()
	for id in _original.keys():
		var before = String(_original[id].direction)
		if SLOTS.has(before) and direction_of(id) == "":
			out.append({"direction": "none", "host": String(id), "peer": ""})
	return out


# Direcciones compatibles con neighborhood_directions.merge/to_json: {hid: entry}.
# Incluye los originales sin asignar como direction "none" para que merge los
# borre; los asignados quedan "confirmed"/"extend"/"deskflow+gvd".
func to_directions_dict():
	var out = {}
	for id in _original.keys():
		out[String(id)] = _entry("none")
	for d in SLOTS:
		for id in slot_owners(d):
			out[String(id)] = _entry(d)
	return out


func _entry(direction):
	return DIRECTIONS.sanitize_entry({
		"direction": String(direction),
		"confirm": APPLY_CONFIRM,
		"mode": APPLY_MODE,
		"link": APPLY_LINK,
	})


# Posicion gvd derivada de la asignacion del host ("" si no hay direccion).
func gvd_position(id):
	return DIRECTIONS.to_gvd_position(direction_of(id))


# Arista Deskflow derivada de la asignacion del host ("" si no hay direccion).
func deskflow_edge(id):
	return LAYOUT.edge_of(direction_of(id))


func _safe_peer_name(label, fallback = ""):
	var raw = String(label)
	var cleaned = ""
	for i in range(raw.length()):
		var ch = raw.substr(i, 1)
		if _SAFE_CHARS.find(ch) >= 0:
			cleaned += ch
	cleaned = cleaned.strip_edges().lstrip(".-").rstrip(".-")
	if cleaned != "" and LAYOUT.valid_peer(cleaned):
		return cleaned
	var fb = String(fallback)
	if fb != "" and LAYOUT.valid_peer(fb):
		return fb
	return "peer"


# --- autoprueba --------------------------------------------------------------

static func selftest():
	var ed = load("res://deskflow_layout_editor.gd").new()
	var hosts = [
		{"id": "h1", "hid": "h1", "label": "Tengu", "kind": "laptop", "degraded": false,
			"capabilities": {"deskflow": {"txt": {"role": "client"}}, "gvd": {"txt": {"role": "recv"}}}},
		{"id": "h2", "hid": "h2", "label": "Cupid", "kind": "desktop", "degraded": false,
			"capabilities": {"deskflow": {"txt": {"role": "client"}}}},
	]
	ed.set_local_name("bastion")
	ed.set_hosts(hosts)

	ed.seed_from_directions({"h1": {"direction": "east", "confirm": "proposed"}})
	assert(ed.direction_of("h1") == "east", "semilla desde host_directions")
	assert(ed.slot_owner("east") == "h1", "slot east con h1")

	# Misma asignacion -> gvd position y arista Deskflow.
	assert(ed.gvd_position("h1") == "right", "east -> gvd right")
	assert(ed.deskflow_edge("h1") == "right", "east -> deskflow right")

	var links = ed.to_links()
	assert(links.size() == 1 and links[0].direction == "east" and links[0].host == "h1",
		"to_links derivado")
	var text = CONF.build_server_conf("bastion", links)
	assert(text.find("\t\tright = Tengu") >= 0, "conf con arista este")

	var dirs = ed.to_directions_dict()
	assert(dirs.h1.direction == "east" and dirs.h1.confirm == "confirmed"
		and dirs.h1.link == "deskflow+gvd", "to_directions_dict confirmada")

	# Un host un slot: mover h1 y reasignar el slot.
	ed.assign("h1", "north")
	assert(ed.direction_of("h1") == "north" and ed.slot_owners("east").empty(), "mover host")
	ed.assign("h2", "north")
	assert(ed.slot_owner("north") == "h2" and ed.direction_of("h1") == "", "un host por slot")

	# Conflicto por semilla: dos hosts en el mismo borde.
	var ed2 = load("res://deskflow_layout_editor.gd").new()
	ed2.set_hosts(hosts)
	ed2.seed_from_directions({"h1": {"direction": "east"}, "h2": {"direction": "east"}})
	assert(ed2.has_conflict(), "dos hosts mismo borde = conflicto")
	assert(ed2.conflicts()[0].direction == "east", "conflicto east")

	# Semilla desde conf: no pisa direcciones existentes.
	var ed3 = load("res://deskflow_layout_editor.gd").new()
	ed3.set_hosts(hosts)
	ed3.seed_from_directions({"h1": {"direction": "west"}})
	ed3.seed_from_conf(CONF.build_server_conf("bastion",
		[{"direction": "south", "peer": "Tengu"}, {"direction": "east", "peer": "Cupid"}]))
	assert(ed3.direction_of("h1") == "west", "conf no pisa host_directions")
	assert(ed3.direction_of("h2") == "east", "conf siembra host sin direccion")

	# Baja: clear_slot y payload de apply con "none".
	ed3.clear_slot("west")
	var apply = ed3.to_apply()
	assert(apply.size() == 2, "apply incluye link y none")
	var cleared = ed3.to_directions_dict()
	assert(cleared.h1.direction == "none", "original sin asignar -> none")
	return true


func run_selftest():
	return selftest()
