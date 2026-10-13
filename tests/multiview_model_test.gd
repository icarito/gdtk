extends SceneTree

# Autoprueba del modelo puro del multiview. Correr:
#   godot --no-window --path shell -s $PWD/tests/multiview_model_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _overlaps(a, b):
	var eps = 0.01
	return a.position.x + eps < b.position.x + b.size.x \
		and b.position.x + eps < a.position.x + a.size.x \
		and a.position.y + eps < b.position.y + b.size.y \
		and b.position.y + eps < a.position.y + a.size.y


func _no_overlaps(rects):
	for i in range(rects.size()):
		for j in range(i + 1, rects.size()):
			if _overlaps(rects[i], rects[j]):
				return false
	return true


func _within(rects, viewport):
	var eps = 0.01
	for r in rects:
		if r.position.x < -eps or r.position.y < -eps:
			return false
		if r.position.x + r.size.x > viewport.x + eps:
			return false
		if r.position.y + r.size.y > viewport.y + eps:
			return false
	return true


func _bbox_ratio(rects, viewport):
	if rects.empty():
		return 0.0
	var minx = 1e20
	var miny = 1e20
	var maxx = -1e20
	var maxy = -1e20
	for r in rects:
		minx = min(minx, r.position.x)
		miny = min(miny, r.position.y)
		maxx = max(maxx, r.position.x + r.size.x)
		maxy = max(maxy, r.position.y + r.size.y)
	return ((maxx - minx) * (maxy - miny)) / (viewport.x * viewport.y)


func _init():
	var mod = load("res://multiview_model.gd").new()
	check("selftest() de multiview_model", mod.run_selftest())

	var S = mod.STATES
	var E = mod.EVENTS
	check("STATES y EVENTS declarados", S.size() == 7 and E.size() == 8
		and S.has("idle") and S.has("joining") and S.has("live")
		and S.has("degraded") and S.has("leaving") and S.has("stopped") and S.has("failed")
		and E.has("join") and E.has("ready") and E.has("drop") and E.has("resume")
		and E.has("leave") and E.has("stopped") and E.has("fail") and E.has("reset"))

	# assign_slots: contrato de slots/puertos y determinismo.
	var asg = mod.assign_slots(["peer-a", "peer.b", "peer_c"])
	check("assign_slots 3 slots en orden", asg.size() == 3
		and asg["peer-a"].slot == 0 and asg["peer.b"].slot == 1 and asg["peer_c"].slot == 2)
	check("assign_slots puertos base + 2*i", asg["peer-a"].port == 5700
		and asg["peer-a"].cursor_port == 5701
		and asg["peer.b"].port == 5702 and asg["peer.b"].cursor_port == 5703
		and asg["peer_c"].port == 5704 and asg["peer_c"].cursor_port == 5705)
	var asg2 = mod.assign_slots(["peer-a", "peer.b", "peer_c"])
	check("assign_slots determinista", to_json(asg) == to_json(asg2))
	check("assign_slots cap max_slots",
		mod.assign_slots(["a", "b", "c", "d", "e"], 5700, 2).size() == 2)
	check("assign_slots omite duplicados",
		mod.assign_slots(["a", "a", "b"]).size() == 2)
	check("assign_slots omite hids invalidos",
		mod.assign_slots(["ok.hid-x", "bad hid", "", "bad!", "x".repeat(65), "ok2"]).size() == 2)
	check("assign_slots base invalida -> default", mod.assign_slots(["a"], 500)["a"].port == 5700)
	check("assign_slots max_slots invalido -> default",
		mod.assign_slots(["a", "b", "c", "d", "e"], 5700, 0).size() == 4)
	check("assign_slots no-array -> {}", mod.assign_slots("nope").empty())

	# Sin colision entre el video de un slot y el cursor de otro.
	var ports = {}
	var collision = false
	for hid in asg.keys():
		for k in ["port", "cursor_port"]:
			var p = int(asg[hid][k])
			if ports.has(p):
				collision = true
			ports[p] = true
	check("assign_slots puertos sin colision", not collision)

	# tile_rects: grilla valida.
	var vp = Vector2(800, 600)
	var rects = mod.tile_rects(4, vp, 8)
	check("tile_rects 4 tiles", rects.size() == 4)
	check("tile_rects sin solapes", _no_overlaps(rects))
	check("tile_rects dentro del viewport", _within(rects, vp))
	check("tile_rects bbox >= 80%", _bbox_ratio(rects, vp) >= 0.8)
	check("tile_rects count<=0 -> []",
		mod.tile_rects(0, vp, 8).empty() and mod.tile_rects(-2, vp, 8).empty())
	check("tile_rects cap en 16", mod.tile_rects(100, vp, 8).size() == 16)
	var rects_clamped = mod.tile_rects(100, vp, 8)
	check("tile_rects 16 sin solapes y dentro",
		_no_overlaps(rects_clamped) and _within(rects_clamped, vp))
	var single = mod.tile_rects(1, vp, 8)
	check("tile_rects 1 llena el viewport",
		single.size() == 1 and single[0].size == vp)

	# place_by_direction: normaliza via DIRECTIONS.
	var placed = mod.place_by_direction(asg, {"peer-a": "NORTH", "peer.b": "up", "peer_c": "none"})
	check("place_by_direction normaliza", placed["peer-a"].dir == "north"
		and placed["peer-a"].slot == 0)
	check("place_by_direction desconocida -> none", placed["peer.b"].dir == "none"
		and placed["peer_c"].dir == "none")
	check("place_by_direction sin direcciones -> none",
		mod.place_by_direction(asg, {})["peer-a"].dir == "none")

	# active_slot.
	check("active_slot dueño del puntero", mod.active_slot("peer.b", asg) == 1)
	check("active_slot vacio -> -1", mod.active_slot("", asg) == -1)
	check("active_slot ausente -> -1", mod.active_slot("nadie", asg) == -1)

	# Título -> hid (F4/§7/§8): prefijo, token "equipo N", etiqueta única, ambigüedad
	# por slot y exclusión de los ya reclamados. Nunca asocia una etiqueta desconocida.
	check("TITLE_PREFIX de producto", mod.TITLE_PREFIX == "Vista del grupo — ")
	check("unknown_label es 1-based", mod.unknown_label(0) == "equipo 1"
		and mod.unknown_label(2) == "equipo 3")
	check("title_label quita el prefijo", mod.title_label("Vista del grupo — Sala") == "Sala"
		and mod.title_label("Pantalla compartida") == "")
	check("slot_from_label", mod.slot_from_label("equipo 2") == 1
		and mod.slot_from_label("equipo 1") == 0 and mod.slot_from_label("Sala") == -1)
	check("match_hid por token equipo", mod.match_hid("Vista del grupo — equipo 2", asg) == "peer.b")
	check("match_hid por etiqueta única",
		mod.match_hid("Vista del grupo — Sala", asg, {"peer.b": "Sala"}) == "peer.b")
	check("match_hid etiqueta desconocida -> \"\"",
		mod.match_hid("Vista del grupo — Nadie", asg, {"peer.b": "Sala"}) == "")
	check("match_hid ambigua -> menor slot",
		mod.match_hid("Vista del grupo — Repetido", asg,
			{"peer-a": "Repetido", "peer.b": "Repetido"}) == "peer-a")
	check("match_hid respeta los reclamados",
		mod.match_hid("Vista del grupo — Repetido", asg,
			{"peer-a": "Repetido", "peer.b": "Repetido"}, ["peer-a"]) == "peer.b")
	check("match_hid sin prefijo -> \"\"", mod.match_hid("otra", asg) == "")

	# transition.
	check("transition idle+join", mod.transition("idle", "join") == "joining")
	check("transition joining+ready", mod.transition("joining", "ready") == "live")
	check("transition joining+fail", mod.transition("joining", "fail") == "failed")
	check("transition live+drop", mod.transition("live", "drop") == "degraded")
	check("transition degraded+resume", mod.transition("degraded", "resume") == "live")
	check("transition live/degraded+leave",
		mod.transition("live", "leave") == "leaving"
		and mod.transition("degraded", "leave") == "leaving")
	check("transition leaving+stopped", mod.transition("leaving", "stopped") == "stopped")
	check("transition terminal+reset",
		mod.transition("stopped", "reset") == "idle"
		and mod.transition("failed", "reset") == "idle")
	check("transition fail no terminal -> failed",
		mod.transition("idle", "fail") == "failed"
		and mod.transition("live", "fail") == "failed"
		and mod.transition("degraded", "fail") == "failed"
		and mod.transition("leaving", "fail") == "failed")
	check("transition fail terminal no cambia",
		mod.transition("stopped", "fail") == "stopped"
		and mod.transition("failed", "fail") == "failed")
	check("transition no-op", mod.transition("idle", "ready") == "idle"
		and mod.transition("live", "join") == "live"
		and mod.transition("stopped", "join") == "stopped"
		and mod.transition("live", "reset") == "live"
		and mod.transition("joining", "leave") == "joining")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
