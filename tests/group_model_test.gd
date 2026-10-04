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
			"connected": false, "icon": "phone"},
	]
	var ms3 = GM.members({}, {}, [], [], bt)
	check("BT no pareado no aparece", ms3.size() == 2)
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
		"connected": false, "icon": "input-mouse"}]
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
			"icon": "audio-card"},
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

	OS.exit_code = 1 if failed > 0 else 0
	quit()
