extends SceneTree

# Autoprueba del modelo puro del Grupo (shell/group_model.gd). Correr:
#   godot --no-window --path shell -s $PWD/tests/group_model_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _find(arr, id):
	for m in arr:
		if String(m.get("id", "")) == String(id):
			return m
	return null


func _ids(arr):
	var out = []
	for m in arr:
		out.append(String(m.get("id", "")))
	return out


func _init():
	var GM = load("res://group_model.gd")

	# 1) Conocido por dirección y apagado: aparece con online=false y su dirección.
	var dirs = {"h1": {"direction": "east", "confirm": "confirmed", "mode": "extend",
		"link": "", "updated": 0}}
	var ms = GM.members(dirs, {}, [], [], [])
	check("conocido offline aparece", ms.size() == 1)
	var m1 = ms[0] if ms.size() == 1 else {}
	check("offline => online=false", not bool(m1.get("online", true)))
	check("dirección conservada", String(m1.get("direction", "")) == "east")
	check("kind host", String(m1.get("kind", "")) == "host")
	check("host vacío si offline", typeof(m1.get("host", null)) == TYPE_DICTIONARY
		and m1.get("host", {}).empty())
	check("nombre humano cae al id", String(m1.get("name", "")) == "h1")

	# 2) Vivo NO conocido: no entra al Grupo.
	var live = [{"id": "h9", "hid": "h9", "label": "Tengu", "state": "visto"}]
	check("vivo no conocido NO aparece", GM.members({}, {}, [], live, []).empty())

	# 3) BT: no pareado no aparece; pareado sí, con tipo y estado de conexión.
	var bt = [
		{"address": "AA:BB:CC:DD:EE:01", "name": "Parlante", "paired": false,
			"connected": false, "icon": "audio-card"},
		{"address": "11:22:33:44:55:66", "name": "Teclado", "paired": true,
			"connected": true, "icon": "input-keyboard"},
		{"address": "77:88:99:AA:BB:CC", "name": "Teléfono", "paired": true,
			"connected": false, "rssi": -70, "icon": "phone"},
		{"address": "DD:DD:DD:DD:DD:DD", "name": "Radio lejana", "paired": true,
			"connected": false, "rssi": 0, "icon": "audio-card"},
	]
	var ms3 = GM.members({}, {}, [], [], bt)
	check("BT no pareado ni fuera de alcance no aparecen", ms3.size() == 2
		and _find(ms3, "DD:DD:DD:DD:DD:DD") == null)
	check("bt_in_range: conectado, con señal o visto", GM.bt_in_range({"connected": true})
		and GM.bt_in_range({"rssi": -80}) and GM.bt_in_range({"seen": true})
		and not GM.bt_in_range({"paired": true}) and not GM.bt_in_range(null))
	var k = _find(ms3, "11:22:33:44:55:66")
	check("BT pareado conectado", k != null and bool(k.get("connected", false))
		and bool(k.get("online", false)) and String(k.get("kind", "")) == "bt")
	check("bt_kind input", k != null and String(k.get("bt_kind", "")) == "input")
	var ph = _find(ms3, "77:88:99:AA:BB:CC")
	check("bt_kind phone y offline", ph != null and String(ph.get("bt_kind", "")) == "phone"
		and not bool(ph.get("online", true)))
	check("bt_kind audio/other", GM.bt_kind("audio-headset") == "audio"
		and GM.bt_kind("computer") == "computer" and GM.bt_kind("") == "other")

	# 4) Dedup directions + tokens + pantallas + host vivo => una sola ficha.
	var secret = "SECRET-TOKEN-9999"
	var dirs4 = {"h1": {"direction": "west", "confirm": "confirmed", "mode": "extend",
		"link": "", "updated": 3}}
	var toks4 = {"cli:h1": secret}
	var scrs4 = [{"id": "h1", "label": "ThinkPad", "peer": "ThinkPad", "local": false}]
	var live4 = [{"id": "h1", "hid": "h1", "label": "ThinkPad", "state": "visto"}]
	var ms4 = GM.members(dirs4, toks4, scrs4, live4, [])
	check("dedup por hid/nombre", ms4.size() == 1)
	var m4 = ms4[0] if ms4.size() == 1 else {}
	check("online true y nombre del host", bool(m4.get("online", false))
		and String(m4.get("name", "")) == "ThinkPad")
	check("dirección merge", String(m4.get("direction", "")) == "west")
	check("host vivo adjunto", not m4.get("host", {}).empty())
	check("tokens no se filtran", String(JSON.print(ms4)).find(secret) < 0)
	var legacy_dupe = GM.members({
		"61950c8964e60e15": {"direction": "east"},
		"cupid": {"direction": "east"}}, {"cli:61950c8964e60e15": secret},
		[{"id": "cupid", "label": "cupid", "peer": "cupid", "local": false}], [], [])
	check("nombre histórico y HID forman una sola ficha", legacy_dupe.size() == 1
		and String(legacy_dupe[0].id) == "61950c8964e60e15")

	# 5) Pantalla sin host vivo: miembro por pantalla, offline, con su nombre.
	var scrs5 = [{"id": "h7", "label": "Cupido", "peer": "cupido", "local": false}]
	var ms5 = GM.members({}, {}, scrs5, [], [])
	check("pantalla sola es miembro", ms5.size() == 1 and String(ms5[0].id) == "h7"
		and String(ms5[0].name) == "Cupido" and not bool(ms5[0].online))
	# La pantalla local no es miembro.
	check("pantalla local no es miembro",
		GM.members({}, {}, [{"id": "local", "label": "Este equipo", "local": true}], [], []).empty())

	# 6) Orden estable: N, E, S, O, luego sin ubicar, luego BT.
	var dirs6 = {
		"hs": {"direction": "south"}, "hn": {"direction": "north"},
		"hw": {"direction": "west"}, "he": {"direction": "east"},
	}
	var toks6 = {"cli:hu": "x"}
	var bt6 = [{"address": "AA:11", "name": "Mouse", "paired": true,
		"connected": false, "rssi": -60, "icon": "input-mouse"}]
	var ms6 = GM.members(dirs6, toks6, [], [], bt6)
	check("orden N,E,S,O, sin ubicar, BT",
		_ids(ms6) == ["hn", "he", "hs", "hw", "hu", "AA:11"])

	# 7) add_member / remove_member / removal_plan, sin mutar la entrada.
	var base = {"h1": {"direction": "east", "confirm": "confirmed"}}
	var added = GM.add_member(base, "h2")
	check("add_member agrega propuesto", added.has("h2")
		and String(added.h2.confirm) == "proposed"
		and String(added.h2.direction) == "" and String(added.h2.mode) == ""
		and String(added.h2.link) == "" and int(added.h2.updated) == 0)
	check("add_member no muta el original", not base.has("h2") and added.has("h1"))
	check("add_member no pisa existente",
		String(GM.add_member(base, "h1").h1.confirm) == "confirmed")
	var removed = GM.remove_member(added, "h1")
	check("remove_member quita y es puro",
		not removed.has("h1") and removed.has("h2") and added.has("h1"))
	var plan = GM.removal_plan("h1", "ThinkPad")
	check("removal_plan", String(plan.directions) == "h1"
		and String(plan.token) == "cli:h1" and String(plan.screen) == "ThinkPad")

	# 8) group_layout: cada dirección queda de su lado, sin solapes y dentro de la
	#    vista (1280x720 y 800x1280); los apagados se atenúan y BT va a la banda.
	var dirs8 = {"hn": {"direction": "north"}, "he": {"direction": "east"},
		"hs": {"direction": "south"}, "hw": {"direction": "west"}}
	var toks8 = {"cli:hu": "x", "cli:hv": "y"}
	var bt8 = [
		{"address": "AA:01", "name": "Teclado", "paired": true, "connected": true,
			"icon": "input-keyboard"},
		{"address": "AA:02", "name": "Parlante", "paired": true, "connected": false,
			"rssi": -55, "icon": "audio-card"},
	]
	var members8 = GM.members(dirs8, toks8, [], [], bt8)
	check("group_layout: 8 fichas (4 dir + 2 sin ubicar + 2 BT)", members8.size() == 8)

	for view in [{"tag": "1280x720", "vp": Vector2(1280, 720), "bar": 64.0},
			{"tag": "800x1280", "vp": Vector2(800, 1280), "bar": 64.0}]:
		var vp8 = view.vp
		var bar8 = view.bar
		var lay = GM.group_layout(members8, vp8, bar8)
		var tag = view.tag
		check(tag + ": centro en vp/2", Vector2(lay.center) == vp8 * 0.5)
		var by = {}
		for n in lay.nodes:
			by[String(n.id)] = n
		check(tag + ": norte arriba", by.hn.center.y < lay.center.y
			and abs(by.hn.center.x - lay.center.x) < 1.0)
		check(tag + ": sur abajo", by.hs.center.y > lay.center.y
			and abs(by.hs.center.x - lay.center.x) < 1.0)
		check(tag + ": este derecha", by.he.center.x > lay.center.x
			and abs(by.he.center.y - lay.center.y) < 1.0)
		check(tag + ": oeste izquierda", by.hw.center.x < lay.center.x
			and abs(by.hw.center.y - lay.center.y) < 1.0)
		check(tag + ": sin ubicar en arco inferior",
			by.hu.center.y > lay.center.y and by.hv.center.y > lay.center.y)
		check(tag + ": fichas offline atenuadas", bool(by.hn.dimmed)
			and bool(by.hu.dimmed))
		check(tag + ": rótulo Sin ubicar presente",
			Vector2(lay.unplaced_label) != Vector2.ZERO)

		# Sin solape entre todas las cápsulas (nodo + rótulo; BT sin rótulo).
		var entries = []
		for n in lay.nodes:
			entries.append({"c": Vector2(n.center), "hw": GM.NODE_SIZE * 0.5,
				"hh": GM.NODE_SIZE * 0.5 + GM.LABEL_TAIL})
		for b in lay.bt:
			entries.append({"c": Vector2(b.center), "hw": GM.BT_SIZE * 0.5,
				"hh": GM.BT_SIZE * 0.5})
		var overlap = false
		for i in range(entries.size()):
			for j in range(i + 1, entries.size()):
				var dx = abs(entries[j].c.x - entries[i].c.x)
				var dy = abs(entries[j].c.y - entries[i].c.y)
				if dx < entries[i].hw + entries[j].hw + 2.0 \
						and dy < entries[i].hh + entries[j].hh + 2.0:
					overlap = true
		check(tag + ": sin solape", not overlap)

		var inside = true
		for e in entries:
			if e.c.x - e.hw < -0.5 or e.c.x + e.hw > vp8.x + 0.5 \
					or e.c.y - e.hh < bar8 - 0.5 or e.c.y + e.hh > vp8.y - bar8 + 0.5:
				inside = false
		check(tag + ": todo dentro de la vista", inside)

	# BT conectado se ve encendido y el no conectado atenuado.
	var lay_bt = GM.group_layout(members8, Vector2(1280, 720), 64.0)
	var bt_on = null
	var bt_off = null
	for b in lay_bt.bt:
		if String(b.id) == "AA:01":
			bt_on = b
		elif String(b.id) == "AA:02":
			bt_off = b
	check("BT conectado no atenuado", bt_on != null and not bool(bt_on.dimmed))
	check("BT no conectado atenuado", bt_off != null and bool(bt_off.dimmed))

	_placement_tests(GM)
	OS.exit_code = 1 if failed > 0 else 0
	quit()


# N4/N5/N9: BT repartidos en 360°, ubicación libre por ángulo, conectores.
func _placement_tests(GM):
	var SL = load("res://screen_layout.gd")
	var vp = Vector2(1280, 720)
	var bar = 64.0

	# N4: 6 BT al alcance + 3 pares: sin solape con nadie y repartidos arriba y abajo,
	# izquierda y derecha del centro (no una banda al pie).
	var bts = []
	for i in range(6):
		bts.append({"address": "BT:0" + str(i), "name": "Disp " + str(i), "paired": true,
			"connected": i % 2 == 0, "rssi": -40 - i, "icon": "input-mouse"})
	var dirs = {"hn": {"direction": "north"}, "he": {"direction": "east", "along": 0.2},
		"hs": {"direction": "south", "along": 0.8}}
	var ms = GM.members(dirs, {}, [], [], bts)
	check("6 BT + 3 pares", ms.size() == 9)
	var lay = GM.group_layout(ms, vp, bar)
	var up = 0
	var down = 0
	var left = 0
	var right = 0
	for b in lay.bt:
		if b.center.y < lay.center.y - 20.0: up += 1
		if b.center.y > lay.center.y + 20.0: down += 1
		if b.center.x < lay.center.x - 20.0: left += 1
		if b.center.x > lay.center.x + 20.0: right += 1
	check("BT repartidos alrededor del centro", up >= 2 and down >= 2 and left >= 2 and right >= 2)
	check("layout con BT: sin solape", not _overlaps(lay))
	check("BT no pisan al equipo local", _clear_of_center(lay))

	# N5: ángulo <-> {side, offset}: las esquinas y el centro de cada lado.
	var half = Vector2(640, 400)
	var p0 = SL.placement_from_angle(0.0, half)
	var p90 = SL.placement_from_angle(90.0, half)
	var p180 = SL.placement_from_angle(180.0, half)
	var p270 = SL.placement_from_angle(270.0, half)
	check("0 grados = este centrado", p0.side == "east" and abs(p0.offset - 0.5) < 0.001)
	check("90 grados = sur centrado", p90.side == "south" and abs(p90.offset - 0.5) < 0.001)
	check("180 grados = oeste centrado", p180.side == "west" and abs(p180.offset - 0.5) < 0.001)
	check("270 grados = norte centrado", p270.side == "north" and abs(p270.offset - 0.5) < 0.001)
	var p45 = SL.placement_from_angle(atan2(400.0, 640.0) * 180.0 / PI, half)
	check("esquina SE cae en un extremo", p45.side == "south" and p45.offset > 0.99)
	var p20 = SL.placement_from_angle(20.0, half)
	check("20 grados: este, algo por debajo del centro", p20.side == "east"
		and p20.offset > 0.5 and p20.offset < 1.0)
	var round_ok = true
	for a in range(0, 360, 7):
		var pl = SL.placement_from_angle(float(a), half)
		var back = SL.angle_from_placement(pl.side, pl.offset, half)
		if abs(fposmod(back - float(a) + 180.0, 360.0) - 180.0) > 0.01:
			round_ok = false
	check("angulo -> lado/offset -> angulo es identidad", round_ok)
	check("lado invalido => -1", SL.angle_from_placement("none", 0.5, half) < 0.0)

	# offset_px: centra al par sobre la posición pedida y deja contacto mínimo.
	var anchor = {"id": "local", "local": true, "x": 0.0, "y": 0.0,
		"w": 1000.0, "h": 600.0}
	var mover = {"x": 0.0, "y": 0.0, "w": 400.0, "h": 300.0}
	check("offset_px centrado en N/S", abs(SL.offset_px("north", 0.5, anchor, mover) - 300.0) < 0.01)
	check("offset_px centrado en E/O", abs(SL.offset_px("east", 0.5, anchor, mover) - 150.0) < 0.01)
	check("offset_px extremo conserva contacto", SL.offset_px("south", 1.0, anchor, mover)
		<= 1000.0 - SL.MIN_CONTACT and SL.offset_px("south", 0.0, anchor, mover)
		>= SL.MIN_CONTACT - 400.0)
	var lay_sc = SL.place_direction({"local": anchor,
		"screens": [{"id": "h1", "w": 400.0, "h": 300.0}]}, "h1",
		"east", SL.offset_px("east", 0.9, anchor, mover))
	check("place_direction con offset deja contacto", not SL.link_ranges(lay_sc.local,
		SL.screen_by_id(lay_sc, "h1")).empty())

	# El layout respeta el ángulo guardado: este en 0.2 queda sobre el anillo, arriba del centro.
	var by = {}
	for n in lay.nodes:
		by[String(n.id)] = n
	check("este con along 0.2 queda arriba del eje", by.he.center.x > lay.center.x
		and by.he.center.y < lay.center.y - 5.0)
	check("sur con along 0.8 queda a la derecha", by.hs.center.y > lay.center.y
		and by.hs.center.x > lay.center.x + 5.0)
	check("placements() coincide con el lado", abs(GM.placements(dirs).he - SL.angle_from_placement(
		"east", 0.2, GM._default_ring())) < 0.01 and GM.placements(dirs).hn == 270.0)

	# Dos pares en el mismo ángulo se separan sin solaparse.
	var same = GM.members({"a": {"direction": "east", "along": 0.5},
		"b": {"direction": "east", "along": 0.5}, "c": {"direction": "east", "along": 0.5}},
		{}, [], [], [])
	var lay2 = GM.group_layout(same, vp, bar)
	check("pares en el mismo ángulo: sin solape", lay2.nodes.size() == 3 and not _overlaps(lay2))

	# along sobrevive al merge de fuentes y se ignora fuera de rango.
	var m1 = GM.members({"x": {"direction": "west", "along": 0.3}}, {}, [], [], [])
	var m2 = GM.members({"x": {"direction": "west", "along": 7.0}}, {}, [], [], [])
	check("along conservado y validado", abs(float(m1[0].along) - 0.3) < 0.001
		and float(m2[0].along) < 0.0)

	# N9: conectores entre el centro y los pares con relación activa.
	var peers = [
		{"key": "he", "peer_name": "he", "kind": "both", "direction": "out", "state": "active",
			"screen": true, "input": true},
		{"key": "hs", "peer_name": "hs", "kind": "input", "direction": "in", "state": "starting",
			"screen": false, "input": true},
		{"key": "zz", "peer_name": "zz", "kind": "screen", "direction": "out", "state": "active",
			"screen": true, "input": false},
	]
	var links = GM.links(lay, peers)
	check("un conector por par con relación (el ajeno no)", links.size() == 2)
	var le = null
	for l in links:
		if String(l.id) == "he":
			le = l
	check("conector: pantalla+teclado, sale del local, activo", le != null and le.screen
		and le.input and le.direction == "out" and le.state == "active")
	check("conector va del borde del centro al borde del par", le != null
		and Vector2(le.a).distance_to(lay.center) < GM.CENTER_SIZE * 0.5 + 1.0
		and Vector2(le.b).distance_to(by.he.center) < GM.NODE_SIZE * 0.5 + 1.0)
	check("sin pares => sin conectores", GM.links(lay, []).empty() and GM.links({}, peers).empty())


func _boxes(lay):
	var out = []
	for n in lay.nodes:
		out.append([Vector2(n.center), GM_NODE * 0.5, GM_NODE * 0.5 + 16.0])
	for b in lay.bt:
		out.append([Vector2(b.center), 12.0, 12.0])
	return out


const GM_NODE = 64.0


func _overlaps(lay):
	var e = _boxes(lay)
	for i in range(e.size()):
		for j in range(i + 1, e.size()):
			if abs(e[j][0].x - e[i][0].x) < e[i][1] + e[j][1] + 2.0 \
					and abs(e[j][0].y - e[i][0].y) < e[i][2] + e[j][2] + 2.0:
				return true
	return false


func _clear_of_center(lay):
	for e in _boxes(lay):
		if abs(e[0].x - lay.center.x) < e[1] + 50.0 and abs(e[0].y - lay.center.y) < e[2] + 50.0:
			return false
	return true
