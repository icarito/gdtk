extends Reference

# Convertidor PURO al formato REAL de servidor Deskflow (secciones INI-like).
# (K4: emitir lo que lee `deskflow-core server -c`, no el v1 de deskflow_layout.gd.)
#
# Puro: no ejecuta Deskflow, no toca el filesystem (ni ~/.config) y no abre red.
# Solo produce/lee texto determinista y reversible.
#
# Entrada: links = [{direction, peer}] con cardinales desde MI vista (como en
# deskflow_layout.gd): north/south/east/west. Mapeo a arista Deskflow:
#   north -> up      (peer arriba de mi pantalla)
#   south -> down    (peer abajo)
#   east  -> right   (peer a la derecha)
#   west  -> left    (peer a la izquierda)
#
# build_server_conf(local, links, template = ""):
#   - section: screens  = local + peers (local primero), cada pantalla con sus
#     claves halfDuplex*/xtestIsXineramaUnaware/switchCorners/switchCornerSize;
#   - section: aliases  = vacia;
#   - section: links    = aristas del local segun su direccion Y los inversos de
#     cada peer (peer.arista_opuesta = local), indentadas con tabs;
#   - section: options  = conservada del template si se pasa (si no, defaults del
#     ejemplo real: protocol = barrier, etc.).
#   Devuelve "" si local/alguna direccion/algun peer es invalido.
#
# parse_server_conf(text) -> {local_links:[{direction,peer}], screens:[...]}.
# Convencion de local: la config real no marca cual pantalla es el servidor, asi
# que se toma la PRIMERA de `section: screens` (build emite local primero). Esto
# garantiza el round-trip. Texto sin pantallas -> {local_links:[], screens:[]}.
#
# Seguridad: nombres de pantalla validados como los peers de deskflow_layout.gd;
# sin espacios, ';', '=', saltos de linea ni rutas. Nunca viajan secretos aqui.

const LAYOUT = preload("res://deskflow_layout.gd")

const DIRECTIONS = ["north", "south", "east", "west"]
const EDGE_BY_DIRECTION = {"north": "up", "south": "down", "east": "right", "west": "left"}
const DIRECTION_BY_EDGE = {"up": "north", "down": "south", "right": "east", "left": "west"}
const OPPOSITE_EDGE = {"up": "down", "down": "up", "left": "right", "right": "left"}
# Orden canonico de emision de aristas (determinista).
const EDGE_ORDER = ["up", "down", "left", "right"]
# Orden canonico de links por direccion (igual que deskflow_layout.sanitize_links).
const LINK_RANK = ["north", "east", "south", "west"]

# Claves por pantalla del ejemplo real (cupid/tengu/bastion en bastion).
const SCREEN_KEYS = [
	["halfDuplexCapsLock", "false"],
	["halfDuplexNumLock", "false"],
	["halfDuplexScrollLock", "false"],
	["xtestIsXineramaUnaware", "false"],
	["switchCorners", "none"],
	["switchCornerSize", "0"],
]
# Defaults de section: options tomados del ejemplo real.
const OPTIONS_DEFAULT = [
	["protocol", "barrier"],
	["relativeMouseMoves", "false"],
	["win32KeepForeground", "false"],
	["defaultLockToScreenState", "false"],
	["disableLockToScreen", "false"],
	["clipboardSharing", "true"],
	["clipboardSharingSize", "10240"],
	["switchCorners", "none"],
	["switchCornerSize", "0"],
]


static func edge_of(direction):
	return String(EDGE_BY_DIRECTION.get(String(direction), ""))


static func _opposite_edge(edge):
	return String(OPPOSITE_EDGE.get(String(edge), ""))


static func _links_equal(a, b):
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if String(a[i].direction) != String(b[i].direction) \
				or String(a[i].peer) != String(b[i].peer):
			return false
	return true


static func _link_less(a, b):
	var ra = LINK_RANK.find(String(a.direction))
	var rb = LINK_RANK.find(String(b.direction))
	if ra != rb:
		return ra < rb
	return String(a.peer) < String(b.peer)


# Ordena links por direccion (north,east,south,west) y luego peer. Determinista.
# Conserva los rangos porcentuales opcionales (local/peer) que usa el servidor.
static func sort_links(links):
	var out = []
	for l in links:
		var item = {"direction": String(l.direction), "peer": String(l.peer)}
		if l.has("local_range"):
			item["local_range"] = l.local_range
		if l.has("peer_range"):
			item["peer_range"] = l.peer_range
		out.append(item)
	var i = 1
	while i < out.size():
		var cur = out[i]
		var j = i - 1
		while j >= 0 and _link_less(cur, out[j]):
			out[j + 1] = out[j]
			j -= 1
		out[j + 1] = cur
		i += 1
	return out


static func _edge_less(a, b):
	var ra = EDGE_ORDER.find(String(a.edge))
	var rb = EDGE_ORDER.find(String(b.edge))
	if ra != rb:
		return ra < rb
	return String(a.peer) < String(b.peer)


static func _sort_edges(edges):
	var out = []
	for e in edges:
		var item = {"edge": String(e.edge), "peer": String(e.peer)}
		if e.has("lr"):
			item["lr"] = e.lr
		if e.has("pr"):
			item["pr"] = e.pr
		out.append(item)
	var i = 1
	while i < out.size():
		var cur = out[i]
		var j = i - 1
		while j >= 0 and _edge_less(cur, out[j]):
			out[j + 1] = out[j]
			j -= 1
		out[j + 1] = cur
		i += 1
	return out


static func _screens_block(names):
	var lines = PoolStringArray()
	lines.append("section: screens")
	for n in names:
		lines.append("\t" + String(n) + ":")
		for kv in SCREEN_KEYS:
			lines.append("\t\t" + String(kv[0]) + " = " + String(kv[1]))
	lines.append("end")
	return lines.join("\n")


# Rango Deskflow "(a,b)" en porcentajes 0..100; "" si no hay rango (borde completo).
static func _range_text(rng):
	if typeof(rng) != TYPE_ARRAY or rng.size() != 2:
		return ""
	return "(" + str(int(round(float(rng[0])))) + "," + str(int(round(float(rng[1])))) + ")"


static func _link_text(edge, peer, local_rng, peer_rng):
	return String(edge) + _range_text(local_rng) + " = " + String(peer) + _range_text(peer_rng)


static func _links_block(local, clean, peers):
	var lines = PoolStringArray()
	lines.append("section: links")
	var local_edges = []
	for l in clean:
		local_edges.append({"edge": edge_of(l.direction), "peer": l.peer,
			"lr": l.get("local_range"), "pr": l.get("peer_range")})
	local_edges = _sort_edges(local_edges)
	lines.append("\t" + String(local) + ":")
	for e in local_edges:
		lines.append("\t\t" + _link_text(e.edge, e.peer, e.lr, e.pr))
	for p in peers:
		var inv = []
		for l in clean:
			if String(l.peer) == String(p):
				inv.append({"edge": _opposite_edge(edge_of(l.direction)), "peer": local,
					"lr": l.get("peer_range"), "pr": l.get("local_range")})
		inv = _sort_edges(inv)
		lines.append("\t" + String(p) + ":")
		for e in inv:
			lines.append("\t\t" + _link_text(e.edge, e.peer, e.lr, e.pr))
	lines.append("end")
	return lines.join("\n")


static func _default_options_block():
	var lines = PoolStringArray()
	lines.append("section: options")
	for kv in OPTIONS_DEFAULT:
		lines.append("\t" + String(kv[0]) + " = " + String(kv[1]))
	lines.append("end")
	return lines.join("\n")


# Extrae verbatim la seccion "options" del template (incluido su "end"). "" si no
# hay template o no contiene esa seccion.
static func _options_from_template(template_text):
	var t = String(template_text)
	if t.strip_edges() == "":
		return ""
	var out = []
	var inside = false
	for raw in t.split("\n"):
		var line = String(raw).replace("\r", "")
		var s = line.strip_edges()
		if not inside:
			if s == "section: options":
				inside = true
				out.append("section: options")
			continue
		if s == "end":
			out.append("end")
			break
		if s == "":
			continue
		out.append(line)
	if out.size() >= 2 and String(out[0]).strip_edges() == "section: options" \
			and String(out[out.size() - 1]).strip_edges() == "end":
		var lines = PoolStringArray()
		for s in out:
			lines.append(String(s))
		return lines.join("\n")
	return ""


# El portapapeles ya no es una opción de producto (SPEC-ui-rework, decisión
# 2026-10-01): "Controlar" asume compartido. Fuerza `clipboardSharing = true` en
# la sección options generada, aunque el template la traiga en false.
static func _force_clipboard_sharing(options_text):
	var t = String(options_text)
	if t.strip_edges() == "":
		return t
	var lines = []
	var inside = false
	var seen = false
	for raw in t.split("\n"):
		var line = String(raw).replace("\r", "")
		var s = line.strip_edges()
		if not inside:
			lines.append(line)
			if s == "section: options":
				inside = true
			continue
		if s == "end":
			if not seen:
				lines.append("\tclipboardSharing = true")
			lines.append("end")
			inside = false
			continue
		if s == "":
			continue
		var eq = s.find("=")
		if eq > 0 and s.substr(0, eq).strip_edges() == "clipboardSharing":
			lines.append("\tclipboardSharing = true")
			seen = true
		else:
			lines.append(line)
	return PoolStringArray(lines).join("\n")


# Genera el texto de configuracion real del servidor Deskflow. "" si invalido.
static func build_server_conf(local_name, links, template_text = ""):
	var local = String(local_name).strip_edges()
	if not LAYOUT.valid_peer(local):
		return ""
	if typeof(links) != TYPE_ARRAY:
		return ""
	var clean = []
	for l in links:
		if typeof(l) != TYPE_DICTIONARY:
			return ""
		var d = String(l.get("direction", ""))
		var p = String(l.get("peer", ""))
		if not LAYOUT.valid_direction(d) or not LAYOUT.valid_peer(p):
			return ""
		if p == local:
			return ""
		var item = {"direction": d, "peer": p}
		if l.has("local_range"):
			item["local_range"] = l.local_range
		if l.has("peer_range"):
			item["peer_range"] = l.peer_range
		clean.append(item)
	clean = sort_links(clean)

	var peers = []
	for l in clean:
		if not peers.has(l.peer):
			peers.append(l.peer)
	peers.sort()

	var names = [local]
	for p in peers:
		names.append(p)

	var opts = _options_from_template(template_text)
	if opts == "":
		opts = _default_options_block()
	# "Controlar" siempre comparte portapapeles: sin opción en el menú.
	opts = _force_clipboard_sharing(opts)

	var blocks = PoolStringArray()
	blocks.append(_screens_block(names))
	blocks.append("")
	blocks.append("section: aliases")
	blocks.append("end")
	blocks.append("")
	blocks.append(_links_block(local, clean, peers))
	blocks.append("")
	blocks.append(opts)
	return blocks.join("\n") + "\n"


# Lee la config real. local = primera pantalla de section: screens (convencion
# de build). Devuelve {local_links, screens}; texto invalido -> listas vacias.
static func parse_server_conf(text):
	var result = {"local_links": [], "screens": []}
	var t = String(text)
	if t.strip_edges() == "":
		return result
	var section = ""
	var screens = []
	var links = {}
	var current_screen = ""
	for raw in t.split("\n"):
		var line = String(raw).replace("\r", "")
		var s = line.strip_edges()
		if s == "" or s.begins_with("#"):
			continue
		if s.begins_with("section:"):
			section = s.substr(8).strip_edges()
			current_screen = ""
			continue
		if s == "end":
			section = ""
			current_screen = ""
			continue
		if section == "screens":
			if s.ends_with(":"):
				var name = s.substr(0, s.length() - 1).strip_edges()
				if name != "" and not screens.has(name):
					screens.append(name)
		elif section == "links":
			if s.ends_with(":"):
				current_screen = s.substr(0, s.length() - 1).strip_edges()
				if not links.has(current_screen):
					links[current_screen] = []
			else:
				var eq = s.find("=")
				if eq > 0 and current_screen != "" and links.has(current_screen):
					var edge = s.substr(0, eq).strip_edges()
					# Los bordes pueden traer rango: "left(80,100)". Se guarda la arista.
					var paren = edge.find("(")
					if paren > 0:
						edge = edge.substr(0, paren).strip_edges()
					var peer = s.substr(eq + 1).strip_edges()
					var pparen = peer.find("(")
					if pparen > 0:
						peer = peer.substr(0, pparen).strip_edges()
					links[current_screen].append({"edge": edge, "peer": peer})
	if screens.size() == 0:
		return result
	var local = String(screens[0])
	var local_links = []
	if links.has(local):
		for raw_link in links[local]:
			var direction = String(DIRECTION_BY_EDGE.get(String(raw_link.edge), ""))
			if direction == "" or not LAYOUT.valid_peer(raw_link.peer):
				continue
			local_links.append({"direction": direction, "peer": String(raw_link.peer)})
	return {"local_links": LAYOUT.sanitize_links(local_links), "screens": screens}


# build_server_conf(local, links) -> parse -> mismos links normalizados y local.
static func round_trips(local_name, links, template_text = ""):
	if typeof(links) != TYPE_ARRAY:
		return false
	var text = build_server_conf(local_name, links, template_text)
	if text == "":
		return false
	var parsed = parse_server_conf(text)
	if parsed.screens.size() == 0 or String(parsed.screens[0]) != String(local_name):
		return false
	return _links_equal(LAYOUT.sanitize_links(links), parsed.local_links)


static func selftest():
	var links = [
		{"direction": "west", "peer": "cupid"},
		{"direction": "south", "peer": "tengu"},
	]
	var text = build_server_conf("bastion", links)
	assert(text != "", "build no vacio")
	assert(text.find("section: screens") >= 0, "screens")
	assert(text.find("section: aliases") >= 0, "aliases")
	assert(text.find("section: links") >= 0, "links")
	assert(text.find("section: options") >= 0, "options")
	assert(text.find("protocol = barrier") >= 0, "default protocol")
	assert(text.find("clipboardSharing = true") >= 0, "portapapeles siempre compartido")
	assert(text.find("\t\tleft = cupid") >= 0, "arista local oeste -> left")
	assert(text.find("\t\tdown = tengu") >= 0, "arista local sur -> down")
	assert(text.find("\t\tright = bastion") >= 0, "inverso cupid -> right")
	assert(text.find("\t\tup = bastion") >= 0, "inverso tengu -> up")

	var parsed = parse_server_conf(text)
	assert(parsed.screens.size() == 3 and String(parsed.screens[0]) == "bastion", "screens [bastion, cupid, tengu]")
	assert(_links_equal(parsed.local_links, sort_links(links)), "parse recupera links")

	assert(round_trips("bastion", links), "round trip")
	assert(build_server_conf("bastion", links) == build_server_conf("bastion", [links[1], links[0]]), "determinista")
	assert(build_server_conf("bastion", [{"direction": "west", "peer": "bad host"}]) == "", "peer invalido")
	assert(build_server_conf("bad host", links) == "", "local invalido")
	assert(build_server_conf("bastion", [{"direction": "diagonal", "peer": "x"}]) == "", "direccion invalida")

	var tpl = "section: aliases\nend\n\nsection: options\n\tprotocol = barrier\n\tclipboardSharing = false\nend\n"
	var custom = build_server_conf("bastion", links, tpl)
	assert(custom.find("clipboardSharing = true") >= 0, "template fuerza portapapeles compartido")
	assert(custom.find("clipboardSharing = false") < 0, "no se conserva el portapapeles apagado")
	assert(custom.find("heartbeat = 5000") < 0, "no mezcla defaults")

	assert(parse_server_conf("").screens.size() == 0, "parse vacio")
	assert(parse_server_conf("basura").screens.size() == 0, "parse basura")
	return true


func run_selftest():
	return selftest()
