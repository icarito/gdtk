extends SceneTree

# Autoprueba del modelo puro de la brujula del Vecindario. Correr:
#   godot --no-window --path shell -s $PWD/tests/neighborhood_directions_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var nd = load("res://neighborhood_directions.gd").new()
	check("selftest() del modelo direcciones", nd.run_selftest())

	check("valid_direction acepta cardinales y none", nd.valid_direction("north")
		and nd.valid_direction("south") and nd.valid_direction("east")
		and nd.valid_direction("west") and nd.valid_direction("none"))
	check("valid_direction rechaza basura", not nd.valid_direction("up")
		and not nd.valid_direction("") and not nd.valid_direction("North"))

	# inverse en los 4 cardinales y none.
	check("inverse north<->south", nd.inverse("north") == "south"
		and nd.inverse("south") == "north")
	check("inverse east<->west", nd.inverse("east") == "west"
		and nd.inverse("west") == "east")
	check("inverse none->none y basura->''", nd.inverse("none") == "none"
		and nd.inverse("up") == "")

	# to_gvd_position / from_gvd_position inversas en los 4 cardinales.
	var round_trip = true
	for d in nd.DIRECTIONS:
		var pos = nd.to_gvd_position(d)
		if pos == "" or nd.from_gvd_position(pos) != d:
			round_trip = false
	check("to_gvd_position mapea N/S/E/O", nd.to_gvd_position("north") == "above"
		and nd.to_gvd_position("south") == "below" and nd.to_gvd_position("east") == "right"
		and nd.to_gvd_position("west") == "left")
	check("to/from_gvd_position inversas en cardinales", round_trip)
	check("posiciones invalidas -> ''", nd.to_gvd_position("none") == ""
		and nd.to_gvd_position("up") == "" and nd.from_gvd_position("center") == "")

	# parse tolera JSON invalido -> {}.
	check("parse tolera JSON invalido", nd.parse("{no json").empty()
		and nd.parse("").empty() and nd.parse("[1,2,3]").empty()
		and nd.parse("null").empty())

	# parse(to_json(dict)) round-trip con 2 hosts.
	var dict = {
		"hid-b": {"direction": "east", "confirm": "confirmed", "mode": "extend",
			"link": "gvd", "updated": 1759270000},
		"hid-a": {"direction": "none", "confirm": "unconfirmed", "mode": "extend",
			"link": "", "updated": 0},
	}
	# parse(to_json(dict)) round-trip con 2 hosts. Dictionary == no es comparacion
	# profunda en Godot 3; se compara por la serializacion determinista.
	var parsed_round = nd.parse(nd.to_json(dict))
	check("parse(to_json(dict)) round-trip con 2 hosts",
		nd.to_json(parsed_round) == nd.to_json(dict) and parsed_round.size() == 2)

	# to_json es determinista: mismo resultado con distinto orden de insercion.
	var reordered = {
		"hid-a": {"direction": "none", "confirm": "unconfirmed", "mode": "extend",
			"link": "", "updated": 0},
		"hid-b": {"direction": "east", "confirm": "confirmed", "mode": "extend",
			"link": "gvd", "updated": 1759270000},
	}
	check("to_json determinista sin importar orden", nd.to_json(dict) == nd.to_json(reordered))

	# sanitize_entry corrige basura y no persiste mirror.
	var dirty = nd.sanitize_entry({"direction": "up", "confirm": "maybe",
		"mode": "mirror", "link": 42, "updated": -5})
	check("sanitize_entry direccion basura -> none", dirty.direction == "none")
	check("sanitize_entry mode mirror -> extend", dirty.mode == "extend")
	check("sanitize_entry confirm/updated/link normalizados", dirty.confirm == "unconfirmed"
		and dirty.updated == 0 and dirty.link == "42")
	var clean = nd.sanitize_entry({"direction": "west", "confirm": "proposed",
		"mode": "extend", "link": "ssh", "updated": 7})
	check("sanitize_entry respeta valores validos", clean.direction == "west"
		and clean.confirm == "proposed" and clean.mode == "extend"
		and clean.link == "ssh" and clean.updated == 7)

	# edge_conflicts: dos hosts en east; sin conflicto si difieren o son none.
	var two_east = {"h1": {"direction": "east"}, "h2": {"direction": "east"}}
	var conflicts = nd.edge_conflicts(two_east)
	check("edge_conflicts detecta dos hosts en east", conflicts.size() == 1
		and conflicts[0].direction == "east" and conflicts[0].hids == ["h1", "h2"])
	check("edge_conflicts no reporta si difieren o son none",
		nd.edge_conflicts({"h1": {"direction": "east"}, "h2": {"direction": "west"}}).empty()
		and nd.edge_conflicts({"h1": {"direction": "none"}, "h2": {"direction": "none"}}).empty())

	# merge aplica overrides entrada por entrada (reemplaza el hid) y agrega claves.
	var base = {"h1": {"direction": "east", "confirm": "confirmed", "mode": "extend",
		"link": "gvd", "updated": 10}}
	var merged = nd.merge(base, {"h1": {"direction": "west"}, "h2": {"direction": "north"}})
	check("merge aplica overrides", merged.h1.direction == "west"
		and merged.h1.mode == "extend")
	check("merge agrega claves ausentes y sanitiza", merged.size() == 2
		and merged.h2.direction == "north" and merged.h2.confirm == "unconfirmed"
		and merged.h2.mode == "extend")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
