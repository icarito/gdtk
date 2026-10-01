extends Reference

# Generador PURO de layout Deskflow desde la brujula del Vecindario.
# (SPEC-screen-share-compass.md: §3 compas N/S/E/O, §6 como Deskflow usa la
#  direccion, §14 tarea "Kilo D — generador de links Deskflow".)
#
# Puro: no ejecuta Deskflow, no toca el filesystem y no abre red. Solo produce
# texto de configuracion determinista y reversible; el caller (worker) lo mapea
# al formato real de Deskflow y lo escribe antes del toggle del servicio,
# reutilizando _toggle_service()/_service_running() del shell.
#
# Mapeo direccion -> arista Deskflow (mi vista, yo servidor):
#   north -> up      (peer arriba de mi pantalla)
#   south -> down    (peer abajo)
#   east  -> right   (peer a la derecha)
#   west  -> left    (peer a la izquierda)
#
# Formato asumido (v1), una clave por linea, comentarios con "#":
#   mode=server|client
#   screen=local          # mi pantalla
#   screen=<peer>         # pantalla de cada vecino (unica, ordenada)
#   link=<edge> <peer>    # vinculo de una arista hacia un peer
# "screen" es la seccion de pantallas; "link", la de vinculos.
#
# Determinismo y reversibilidad:
#   - los links se ordenan por direccion (north, east, south, west) y luego peer;
#   - en modo "server" el borde emitido es edge_of(direction);
#   - en modo "client" se emite el borde OPUESTO, de modo que parse() con el
#     mismo "mode" recupera la direccion original: es el inverso exacto;
#   - build() devuelve "" si "mode" o algun link es invalido;
#   - parse() de texto invalido devuelve {"mode": "", "links": []}.
#
# Seguridad: peer es un nombre seguro (letras, digitos, '.', '_', '-'), sin
# espacios, ';', '=', saltos de linea ni rutas. Nunca viajan secretos aqui.

const DIRECTIONS = ["north", "south", "east", "west"]
const MODES = ["server", "client"]
const HEADER = "# gdtk-deskflow-layout v1"
# Orden de emision/ordenamiento por direccion (distinto de DIRECTIONS).
const _RANK = ["north", "east", "south", "west"]
# Caracteres permitidos en un nombre de peer: sin '/', ';', '=', espacios ni
# control, de modo que rutas y separadores quedan rechazados.
const _PEER_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
const _EDGE_BY_DIRECTION = {"north": "up", "south": "down", "east": "right", "west": "left"}


# Arista Deskflow de una direccion, o "" si la direccion es invalida.
static func edge_of(direction):
	return String(_EDGE_BY_DIRECTION.get(String(direction), ""))


# Arista opuesta (up<->down, left<->right); "" si no es una arista valida.
static func _opposite_edge(edge):
	match String(edge):
		"up":
			return "down"
		"down":
			return "up"
		"left":
			return "right"
		"right":
			return "left"
	return ""


# Direccion del borde tal como la ve el servidor (inverso de edge_of).
static func _direction_of_edge(edge):
	match String(edge):
		"up":
			return "north"
		"down":
			return "south"
		"right":
			return "east"
		"left":
			return "west"
	return ""


static func valid_direction(direction):
	return DIRECTIONS.has(String(direction))


# Nombre de peer seguro: no vacio, sin espacios ni ';', '=', salto de linea ni
# '/', y sin '.'/'-' al inicio o al final (evita ".." y rutas disfrazadas).
static func valid_peer(peer):
	var p = String(peer)
	if p == "" or p != p.strip_edges():
		return false
	if not _only_chars(p, _PEER_CHARS):
		return false
	if p.begins_with(".") or p.begins_with("-") or p.ends_with(".") or p.ends_with("-"):
		return false
	return true


# Filtra/valida links y los ordena de forma determinista por direccion
# (north, east, south, west) y luego por peer. Descarta los invalidos.
static func sanitize_links(links):
	var out = []
	if typeof(links) != TYPE_ARRAY:
		return out
	for l in links:
		if typeof(l) != TYPE_DICTIONARY:
			continue
		var d = String(l.get("direction", ""))
		var p = String(l.get("peer", ""))
		if not valid_direction(d) or not valid_peer(p):
			continue
		out.append({"direction": d, "peer": p})
	# Insercion estable y determinista (sin depender de sort_custom en static).
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


# Forma canonica de una lista de links: validada y ordenada.
static func normalize(links):
	return sanitize_links(links)


# Genera el texto de layout. mode: "server"|"client". Devuelve "" si mode o
# algun link es invalido; con links vacios produce un texto valido sin vinculos.
static func build(mode, links, opts = {}):
	var m = String(mode)
	if not MODES.has(m):
		return ""
	if typeof(links) != TYPE_ARRAY:
		return ""
	var local_name = String(opts.get("local", "local")).strip_edges()
	if not valid_peer(local_name):
		return ""
	var clean = []
	for l in links:
		if typeof(l) != TYPE_DICTIONARY:
			return ""
		var d = String(l.get("direction", ""))
		var p = String(l.get("peer", ""))
		if not valid_direction(d) or not valid_peer(p):
			return ""
		clean.append({"direction": d, "peer": p})
	clean = sanitize_links(clean)

	var peers = {}
	for l in clean:
		peers[l.peer] = true
	var names = peers.keys()
	names.sort()

	var lines = PoolStringArray()
	lines.append(HEADER)
	lines.append("# direction->edge: north=up south=down east=right west=left")
	lines.append("# client mode emits the opposite edge; parse(mode) inverts it")
	lines.append("mode=" + m)
	lines.append("screen=" + local_name)
	for n in names:
		lines.append("screen=" + String(n))
	for l in clean:
		var edge = edge_of(l.direction)
		if m == "client":
			edge = _opposite_edge(edge)
		lines.append("link=" + edge + " " + String(l.peer))
	return lines.join("\n") + "\n"


# Inverso de build(): {"mode": "server"|"client", "links": [{direction, peer}]}.
# Texto invalido (sin mode valido) -> {"mode": "", "links": []}.
static func parse(text):
	var t = String(text)
	if t.strip_edges() == "":
		return {"mode": "", "links": []}
	var mode = ""
	var raw_links = []
	for raw in t.split("\n"):
		var line = String(raw).strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var eq = line.find("=")
		if eq <= 0:
			continue
		var key = line.substr(0, eq).strip_edges()
		var val = line.substr(eq + 1).strip_edges()
		if key == "mode":
			mode = val
		elif key == "link":
			var sp = val.find(" ")
			if sp <= 0:
				continue
			var edge = val.substr(0, sp).strip_edges()
			var peer = val.substr(sp + 1).strip_edges()
			raw_links.append({"edge": edge, "peer": peer})
	if not MODES.has(mode):
		return {"mode": "", "links": []}
	var out = []
	for l in raw_links:
		var direction = ""
		if mode == "server":
			direction = _direction_of_edge(l.edge)
		else:
			direction = _direction_of_edge(_opposite_edge(l.edge))
		if direction == "" or not valid_peer(l.peer):
			continue
		out.append({"direction": direction, "peer": l.peer})
	out = sanitize_links(out)
	return {"mode": mode, "links": out}


# normalize(parse(build(mode, links))) == normalize(links).
static func round_trips(mode, links):
	if not MODES.has(String(mode)):
		return false
	var text = build(mode, links)
	if text == "":
		return false
	var parsed = parse(text)
	if String(parsed.mode) != String(mode):
		return false
	return _links_equal(normalize(parsed.links), normalize(links))


static func _link_less(a, b):
	var ra = _RANK.find(a.direction)
	var rb = _RANK.find(b.direction)
	if ra != rb:
		return ra < rb
	return String(a.peer) < String(b.peer)


static func _links_equal(a, b):
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if String(a[i].direction) != String(b[i].direction) \
				or String(a[i].peer) != String(b[i].peer):
			return false
	return true


static func _only_chars(s, allowed):
	for i in range(s.length()):
		if allowed.find(s.substr(i, 1)) < 0:
			return false
	return true


static func selftest():
	# Mapeo direccion -> arista.
	assert(edge_of("north") == "up" and edge_of("south") == "down"
		and edge_of("east") == "right" and edge_of("west") == "left", "cardinales")
	assert(edge_of("up") == "" and edge_of("") == "", "direccion invalida")

	# Seguridad de peer.
	assert(valid_peer("tengu.local") and valid_peer("host-1") and valid_peer("a_b.c"), "peers validos")
	assert(not valid_peer("") and not valid_peer("bad host") and not valid_peer("a;b")
		and not valid_peer("a=b") and not valid_peer("a\nb") and not valid_peer("a/b")
		and not valid_peer("..") and not valid_peer(".hidden"), "peers invalidos")

	# sanitize: descarta invalidos y ordena north,east,south,west y peer.
	var dirty = [
		{"direction": "west", "peer": "zulu"},
		{"direction": "north", "peer": "beta"},
		{"direction": "east", "peer": "alfa"},
		{"direction": "north", "peer": "alfa"},
		{"direction": "diagonal", "peer": "x"},
		{"direction": "south", "peer": "bad host"},
		"no-dict",
	]
	var clean = sanitize_links(dirty)
	assert(clean.size() == 4, "sanitize descarta invalidos")
	assert(clean[0].direction == "north" and clean[0].peer == "alfa", "orden 0")
	assert(clean[1].direction == "north" and clean[1].peer == "beta", "orden 1")
	assert(clean[2].direction == "east" and clean[2].peer == "alfa", "orden 2")
	assert(clean[3].direction == "west" and clean[3].peer == "zulu", "orden 3")
	assert(_links_equal(sanitize_links(clean), clean), "sanitize estable")

	var links = [{"direction": "east", "peer": "tengu"}, {"direction": "north", "peer": "testudo"}]

	# build no vacio; client sin links sigue siendo valido.
	assert(build("server", links).find("mode=server") >= 0, "server no vacio")
	var empty_client = build("client", [])
	assert(empty_client != "" and parse(empty_client).links.size() == 0, "client sin links")
	assert(empty_client.find("screen=local") >= 0, "pantalla local presente")

	# Reversibilidad server/cliente.
	assert(round_trips("server", links), "round trip server")
	assert(round_trips("client", links), "round trip client")

	# Cliente emite la arista opuesta.
	var srv = build("server", links)
	var cli = build("client", links)
	assert(srv.find("link=up testudo") >= 0 and srv.find("link=right tengu") >= 0, "server edges")
	assert(cli.find("link=down testudo") >= 0 and cli.find("link=left tengu") >= 0, "client edges opuestos")

	# Entradas invalidas.
	assert(build("nope", links) == "", "mode invalido")
	assert(build("server", [{"direction": "diagonal", "peer": "x"}]) == "", "link invalido")
	assert(parse("").mode == "" and parse("").links.size() == 0, "parse vacio")
	assert(parse("basura sin modo").mode == "", "parse sin mode")
	return true


func run_selftest():
	return selftest()
