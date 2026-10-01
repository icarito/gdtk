extends SceneTree

# Autoprueba del editor PURO de layout Deskflow (K5). Sin I/O, sin procesos, sin
# tocar ~/.config. Verifica que la MISMA asignacion N/S/E/O derive gvd y Deskflow.
#   "$BIN" --no-window --path shell -s $PWD/tests/deskflow_layout_editor_test.gd

const DIRECTIONS = preload("res://neighborhood_directions.gd")
const LAYOUT = preload("res://deskflow_layout.gd")
const CONF = preload("res://deskflow_conf.gd")

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var Editor = load("res://deskflow_layout_editor.gd")
	var selftest_ed = Editor.new()
	selftest_ed.run_selftest()
	selftest_ed = null
	check("selftest() del editor", true)

	var ed = Editor.new()
	ed.set_local_name("bastion")
	ed.set_hosts([
		{"id": "h1", "hid": "h1", "label": "Tengu", "kind": "laptop", "degraded": false,
			"capabilities": {"deskflow": {"txt": {"role": "client"}},
				"gvd": {"txt": {"role": "recv", "state": "ready"}}}},
		{"id": "h2", "hid": "h2", "label": "Cupid", "kind": "desktop", "degraded": false,
			"capabilities": {"deskflow": {"txt": {"role": "client"}}}},
	])
	check("nombre local central", ed.local_name == "bastion")
	check("hosts candidatos", ed.host_ids().size() == 2 and ed.has_host("h1"))
	check("fichas en orden determinista", ed.host_ids() == ["h2", "h1"])

	# Fuente unica: se siembra desde host_directions.
	ed.seed_from_directions({
		"h1": {"direction": "east", "confirm": "proposed"},
		"h2": {"direction": "none"},
	})
	check("semilla east en h1", ed.direction_of("h1") == "east")
	check("none no asigna", ed.direction_of("h2") == "")
	check("slot_owner east", ed.slot_owner("east") == "h1")
	check("sin cambios al abrir no esta dirty", not ed.is_dirty())

	# Misma asignacion: east -> gvd right y deskflow right (ambos mecanismos).
	check("east -> gvd position right", ed.gvd_position("h1") == "right")
	check("east -> deskflow edge right", ed.deskflow_edge("h1") == "right")
	check("DIRECTIONS.to_gvd_position coincide",
		DIRECTIONS.to_gvd_position(ed.direction_of("h1")) == "right")
	check("LAYOUT.edge_of coincide", LAYOUT.edge_of(ed.direction_of("h1")) == "right")

	# to_links alimenta build_server_conf.
	var links = ed.to_links()
	check("to_links una entrada", links.size() == 1)
	check("to_links direction/host/peer", links[0].direction == "east"
		and links[0].host == "h1" and links[0].peer == "Tengu")
	var conf = CONF.build_server_conf("bastion", links)
	check("conf con arista local right = Tengu", conf.find("\t\tright = Tengu") >= 0)
	check("conf roundtrip", CONF.round_trips("bastion", links))

	# to_directions_dict compatible con merge/to_json y estado confirmed.
	var dirs = ed.to_directions_dict()
	check("to_directions_dict confirmed", dirs.h1.direction == "east"
		and dirs.h1.confirm == "confirmed" and dirs.h1.mode == "extend"
		and dirs.h1.link == "deskflow+gvd")
	check("to_directions_dict none en h2", dirs.h2.direction == "none")
	check("to_directions_dict JSON roundtrip",
		DIRECTIONS.to_json(DIRECTIONS.parse(DIRECTIONS.to_json(dirs))) == DIRECTIONS.to_json(dirs))
	var merged = DIRECTIONS.merge({"h1": {"direction": "west"}}, dirs)
	check("merge conserva confirmed", merged.h1.direction == "east"
		and merged.h1.confirm == "confirmed")

	# Un host un slot / un host por slot.
	ed.assign("h1", "north")
	check("mover h1 a north", ed.direction_of("h1") == "north" and ed.slot_owners("east").empty())
	ed.assign("h2", "north")
	check("reemplazo de slot", ed.slot_owner("north") == "h2" and ed.direction_of("h1") == "")
	ed.assign("h2", "south")
	check("mover h2", ed.slot_owner("south") == "h2" and ed.slot_owners("north").empty())
	check("assign invalido", not ed.assign("nope", "east") and not ed.assign("h2", "diagonal"))

	# clear + payload de apply con "none".
	ed.clear_slot("south")
	check("clear_slot", ed.slot_owners("south").empty())
	check("is_dirty tras tocar", ed.is_dirty())

	# Conflicto por semilla: dos hosts en el mismo borde.
	var ed2 = Editor.new()
	ed2.set_hosts(ed.hosts())
	ed2.seed_from_directions({"h1": {"direction": "east"}, "h2": {"direction": "east"}})
	check("conflicto detectado", ed2.has_conflict())
	check("conflicto east con 2 hids", ed2.conflicts().size() == 1
		and ed2.conflicts()[0].direction == "east" and ed2.conflicts()[0].hids.size() == 2)
	check("conflicto conserva ambos links", ed2.to_links().size() == 2)

	# Semilla desde conf: no pisa host_directions, siembra hosts sin direccion.
	var ed3 = Editor.new()
	ed3.set_hosts(ed.hosts())
	ed3.seed_from_directions({"h1": {"direction": "west"}})
	ed3.seed_from_conf(CONF.build_server_conf("bastion",
		[{"direction": "south", "peer": "Tengu"}, {"direction": "east", "peer": "Cupid"}]))
	check("conf no pisa h1", ed3.direction_of("h1") == "west")
	check("conf siembra h2", ed3.direction_of("h2") == "east")

	# Reset vuelve al estado inicial.
	ed3.reset()
	check("reset restaura h1 west", ed3.direction_of("h1") == "west")
	check("reset limpia h2", ed3.direction_of("h2") == "")

	# apply: original sin asignar viaja como none.
	ed3.clear_slot("west")
	var apply = ed3.to_apply()
	var has_none = false
	for l in apply:
		if String(l.direction) == "none" and String(l.host) == "h1":
			has_none = true
	check("to_apply marca none al quitado", has_none)
	check("to_apply JSON-safe", typeof(apply) == TYPE_ARRAY)

	ed = null
	ed2 = null
	ed3 = null
	OS.exit_code = 1 if failed > 0 else 0
	quit()
