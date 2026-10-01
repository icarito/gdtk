extends SceneTree

# Autoprueba del generador puro de layout Deskflow (Kilo D, SPEC-screen-share-compass).
# Correr:
#   "$BIN" --no-window --path shell -s $PWD/tests/deskflow_layout_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var L = load("res://deskflow_layout.gd").new()
	L.run_selftest()
	check("selftest() del generador", true)

	# edge_of de los cuatro cardinales (y rechazo de invalidas).
	check("edge_of north -> up", L.edge_of("north") == "up")
	check("edge_of south -> down", L.edge_of("south") == "down")
	check("edge_of east -> right", L.edge_of("east") == "right")
	check("edge_of west -> left", L.edge_of("west") == "left")
	check("edge_of invalida -> vacio", L.edge_of("up") == "" and L.edge_of("") == "")

	# Seguridad de peer.
	check("peer valido", L.valid_peer("tengu.local") and L.valid_peer("host-1")
		and L.valid_peer("a_b.c"))
	check("peer con espacio rechazado", not L.valid_peer("bad host"))
	check("peer con ';' rechazado", not L.valid_peer("a;b"))
	check("peer con '=' rechazado", not L.valid_peer("a=b"))
	check("peer con salto de linea rechazado", not L.valid_peer("a\nb"))
	check("peer con ruta rechazado", not L.valid_peer("a/b") and not L.valid_peer(".."))
	check("peer vacio rechazado", not L.valid_peer(""))

	# sanitize_links: descarta direction invalida y peer con espacio; ordena.
	var dirty = [
		{"direction": "west", "peer": "zulu"},
		{"direction": "north", "peer": "beta"},
		{"direction": "east", "peer": "alfa"},
		{"direction": "north", "peer": "alfa"},
		{"direction": "diagonal", "peer": "x"},
		{"direction": "south", "peer": "bad host"},
		42,
	]
	var clean = L.sanitize_links(dirty)
	check("sanitize descarta invalidos", clean.size() == 4)
	check("sanitize ordena north,east,south,west luego peer",
		clean[0].direction == "north" and clean[0].peer == "alfa"
		and clean[1].direction == "north" and clean[1].peer == "beta"
		and clean[2].direction == "east" and clean[2].peer == "alfa"
		and clean[3].direction == "west" and clean[3].peer == "zulu")
	check("sanitize es determinista e idempotente",
		_eq_links(L.sanitize_links(clean), clean)
		and _eq_links(L.sanitize_links(dirty), L.sanitize_links(dirty)))

	# build: server no vacio; client sin links valido con cero links.
	var links = [{"direction": "east", "peer": "tengu"}, {"direction": "north", "peer": "testudo"}]
	var srv = L.build("server", links)
	var cli = L.build("client", links)
	check("build('server', links) no vacio", srv != "" and srv.find("mode=server") >= 0
		and srv.find("link=") >= 0)
	var parsed_empty = L.parse(L.build("client", []))
	check("build('client', []) valido con cero links",
		L.build("client", []) != "" and parsed_empty.mode == "client"
		and parsed_empty.links.size() == 0)

	# build determinista e independiente del orden de entrada.
	var reversed = [links[1], links[0]]
	check("build determinista", L.build("server", links) == L.build("server", links))
	check("build independiente del orden de entrada",
		L.build("server", links) == L.build("server", reversed))

	# Round-trip server y cliente con 2-3 links.
	check("round_trips('server', links)", L.round_trips("server", links))
	check("round_trips('client', links)", L.round_trips("client", links))
	var three = links + [{"direction": "west", "peer": "zulu"}]
	check("round_trips con 3 links", L.round_trips("server", three)
		and L.round_trips("client", three))

	# Reversibilidad del cliente: el edge es el opuesto del server.
	check("server: este -> right y norte -> up",
		srv.find("link=right tengu") >= 0 and srv.find("link=up testudo") >= 0)
	check("client: este -> left (opuesta) y norte -> down (opuesta)",
		cli.find("link=left tengu") >= 0 and cli.find("link=down testudo") >= 0)
	check("parse(server) recupera la direccion original",
		L.parse(srv).mode == "server" and L.parse(srv).links.size() == 2
		and _has_link(L.parse(srv).links, "east", "tengu")
		and _has_link(L.parse(srv).links, "north", "testudo"))
	check("parse(client) recupera la direccion original",
		L.parse(cli).mode == "client" and _has_link(L.parse(cli).links, "east", "tengu")
		and _has_link(L.parse(cli).links, "north", "testudo"))

	# Invalidos.
	check("build('nope', links) == \"\"", L.build("nope", links) == "")
	check("build con link invalido == \"\"",
		L.build("server", [{"direction": "diagonal", "peer": "x"}]) == ""
		and L.build("server", [{"direction": "east", "peer": "bad host"}]) == "")
	check("parse(\"\") -> {mode:'', links:[]}",
		L.parse("").mode == "" and L.parse("").links.size() == 0)
	check("parse de basura -> {mode:'', links:[]}",
		L.parse("hello world").mode == "" and L.parse("hello world").links.size() == 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _eq_links(a, b):
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if String(a[i].direction) != String(b[i].direction) \
				or String(a[i].peer) != String(b[i].peer):
			return false
	return true


func _has_link(links, direction, peer):
	for l in links:
		if String(l.direction) == direction and String(l.peer) == peer:
			return true
	return false
