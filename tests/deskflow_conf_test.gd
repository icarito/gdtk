extends SceneTree

# Autoprueba del convertidor puro al formato REAL de servidor Deskflow (K4).
# No hace I/O, no arranca procesos ni toca ~/.config.
#   "$BIN" --no-window --path shell -s $PWD/tests/deskflow_conf_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var C = load("res://deskflow_conf.gd").new()
	C.run_selftest()
	check("selftest() del convertidor", true)

	# Ejemplo real: local bastion, cupid al oeste, tengu al sur.
	var links = [
		{"direction": "west", "peer": "cupid"},
		{"direction": "south", "peer": "tengu"},
	]
	var text = C.build_server_conf("bastion", links)
	check("build no vacio", text != "")
	check("seccion screens", text.find("section: screens") >= 0)
	check("seccion aliases", text.find("section: aliases") >= 0)
	check("seccion links", text.find("section: links") >= 0)
	check("seccion options", text.find("section: options") >= 0)

	# Pantallas: local primero, luego peers ordenados.
	check("screens local bastion", text.find("\tbastion:") >= 0)
	check("screens peer cupid", text.find("\tcupid:") >= 0)
	check("screens peer tengu", text.find("\ttengu:") >= 0)
	check("claves halfDuplex por pantalla", text.find("halfDuplexCapsLock = false") >= 0
		and text.find("halfDuplexNumLock = false") >= 0
		and text.find("halfDuplexScrollLock = false") >= 0)
	check("claves switchCorners por pantalla", text.find("switchCorners = none") >= 0
		and text.find("switchCornerSize = 0") >= 0)

	# Links del local segun arista (west->left, south->down) con tabs.
	check("local west -> left = cupid", text.find("\t\tleft = cupid") >= 0)
	check("local south -> down = tengu", text.find("\t\tdown = tengu") >= 0)

	# Inversos de cada peer (arista opuesta hacia el local).
	check("inverso cupid -> right = bastion", text.find("\t\tright = bastion") >= 0)
	check("inverso tengu -> up = bastion", text.find("\t\tup = bastion") >= 0)

	# Options por defecto del ejemplo real.
	check("options protocol = barrier", text.find("protocol = barrier") >= 0)
	check("options con tabs", text.find("\tprotocol = barrier") >= 0)
	check("portapapeles siempre compartido", text.find("clipboardSharing = true") >= 0)

	# Round-trip: parse recupera local_links y screens.
	var parsed = C.parse_server_conf(text)
	check("parse screens [bastion, cupid, tengu]",
		parsed.screens.size() == 3 and String(parsed.screens[0]) == "bastion"
		and parsed.screens.has("cupid") and parsed.screens.has("tengu"))
	check("parse recupera west/cupid", _has_link(parsed.local_links, "west", "cupid"))
	check("parse recupera south/tengu", _has_link(parsed.local_links, "south", "tengu"))
	check("parse recupera 2 links", parsed.local_links.size() == 2)
	check("round_trips('bastion', links)", C.round_trips("bastion", links))

	# Determinista e independiente del orden de entrada.
	var reversed = [links[1], links[0]]
	check("build determinista", C.build_server_conf("bastion", links) == text)
	check("build independiente del orden",
		C.build_server_conf("bastion", reversed) == text)
	check("parse determinista",
		C.parse_server_conf(text).local_links.size() == 2
		and _has_link(C.parse_server_conf(text).local_links, "west", "cupid"))

	# Template: conserva section: options, fuerza portapapeles compartido y no
	# mezcla defaults (el portapapeles ya no es una opción de producto).
	var tpl = "section: aliases\nend\n\nsection: options\n\tprotocol = barrier\n\tclipboardSharing = false\nend\n"
	var custom = C.build_server_conf("bastion", links, tpl)
	check("template fuerza clipboardSharing = true", custom.find("clipboardSharing = true") >= 0
		and custom.find("clipboardSharing = false") < 0)
	check("template no mezcla defaults", custom.find("heartbeat = 5000") < 0)
	check("template sigue teniendo links", custom.find("\t\tleft = cupid") >= 0
		and custom.find("\t\tright = bastion") >= 0)

	# Peer / local / direccion invalidos.
	check("peer invalido rechazado",
		C.build_server_conf("bastion", [{"direction": "west", "peer": "bad host"}]) == "")
	check("peer con ruta rechazado",
		C.build_server_conf("bastion", [{"direction": "west", "peer": "a/b"}]) == "")
	check("local invalido rechazado", C.build_server_conf("bad host", links) == "")
	check("direccion invalida rechazada",
		C.build_server_conf("bastion", [{"direction": "diagonal", "peer": "cupid"}]) == "")
	check("self-link rechazado",
		C.build_server_conf("bastion", [{"direction": "west", "peer": "bastion"}]) == "")

	# Sin links sigue valido (solo local).
	var solo = C.build_server_conf("bastion", [])
	check("sin links valido con solo local",
		solo != "" and C.parse_server_conf(solo).screens.size() == 1
		and C.parse_server_conf(solo).local_links.size() == 0)

	# Texto invalido.
	check("parse vacio", C.parse_server_conf("").screens.size() == 0
		and C.parse_server_conf("").local_links.size() == 0)
	check("parse basura", C.parse_server_conf("hola mundo").screens.size() == 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _has_link(links, direction, peer):
	for l in links:
		if String(l.direction) == direction and String(l.peer) == peer:
			return true
	return false
