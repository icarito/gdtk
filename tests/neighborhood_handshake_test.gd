extends SceneTree

# Autoprueba del handshake de dirección del Vecindario (Kilo G). Correr:
#   godot --no-window --path shell -s $PWD/tests/neighborhood_handshake_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var hs = load("res://neighborhood_handshake.gd").new()
	check("selftest() del módulo", hs.run_selftest())

	# Round-trip de proposal.
	var p = hs.proposal("hidA", "hidB", "east")
	var pd = hs.decode(hs.encode(p))
	check("round-trip proposal", pd.ok and pd.kind == "direction_proposal"
		and pd.from == "hidA" and pd.to == "hidB" and pd.direction == "east")
	check("encode determinista", hs.encode(p) == hs.encode(hs.proposal("hidA", "hidB", "east")))
	check("proposal dirección inválida -> none",
		hs.proposal("a", "b", "diagonal").direction == "none")

	# Round-trip de response.
	var r = hs.response("hidB", "hidA", "west", true)
	var rd = hs.decode(hs.encode(r))
	check("round-trip response", rd.ok and rd.kind == "direction_response"
		and rd.accepted == true and rd.direction == "west")
	check("response rechazada lleva accepted=false",
		hs.decode(hs.encode(hs.response("a", "b", "north", false))).accepted == false)

	# Decode de basura.
	var junk = hs.decode("esto no es json {")
	check("decode de basura -> ok=false", not junk.ok and junk.error != "")
	var unknown = hs.decode("{\"kind\":\"saludo\"}")
	check("decode de kind desconocido -> ok=false", not unknown.ok and unknown.error != "")

	# apply: proposal -> proposed con la dirección propuesta.
	var base = {"direction": "none", "confirm": "unconfirmed", "mode": "extend"}
	var proposed = hs.apply(base, hs.decode(hs.encode(hs.proposal("hidB", "hidA", "south"))))
	check("apply proposal -> proposed", proposed.confirm == "proposed"
		and proposed.direction == "south")
	check("apply no muta el entry", base.confirm == "unconfirmed" and base.direction == "none")
	check("apply conserva campos ajenos", proposed.mode == "extend")

	# apply: response accepted -> confirmed; rechazada -> unconfirmed.
	var confirmed = hs.apply(proposed, hs.decode(hs.encode(hs.response("hidA", "hidB", "south", true))))
	check("apply response accepted -> confirmed", confirmed.confirm == "confirmed"
		and confirmed.direction == "south")
	var rejected = hs.apply(proposed, hs.decode(hs.encode(hs.response("hidA", "hidB", "south", false))))
	check("apply response rejected -> unconfirmed", rejected.confirm == "unconfirmed")

	# Handshake completo: unconfirmed --proposal--> proposed --response(accept)--> confirmed.
	var s0 = {"direction": "none", "confirm": "unconfirmed"}
	var s1 = hs.apply(s0, hs.decode(hs.encode(hs.proposal("hidB", "hidA", "east"))))
	var s2 = hs.apply(s1, hs.decode(hs.encode(hs.response("hidA", "hidB", "east", true))))
	check("handshake completo", s0.confirm == "unconfirmed" and s1.confirm == "proposed"
		and s2.confirm == "confirmed" and s2.direction == "east")

	# Un mensaje de otra dirección no pisa direction salvo proposal.
	var local = {"direction": "north", "confirm": "proposed"}
	var other = hs.apply(local, hs.decode(hs.encode(hs.response("hidA", "hidB", "west", true))))
	check("response no pisa dirección", other.direction == "north" and other.confirm == "confirmed")
	var prop2 = hs.apply(local, hs.decode(hs.encode(hs.proposal("hidB", "hidA", "east"))))
	check("proposal sí reemplaza dirección", prop2.direction == "east" and prop2.confirm == "proposed")

	# Mensaje inválido: entry normalizado sin cambios.
	var bad = hs.apply({"direction": "oops", "confirm": "raro"}, {"ok": false, "error": "x"})
	check("mensaje inválido normaliza sin cambios", bad.direction == "none"
		and bad.confirm == "unconfirmed")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
