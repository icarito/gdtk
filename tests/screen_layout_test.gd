extends SceneTree

# Autoprueba del modelo puro de diseno de pantallas (K11b). Sin render, sin I/O,
# sin procesos. Correr:
#   godot --no-window --path shell -s $PWD/tests/screen_layout_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _find(outs, id):
	for e in outs:
		if String(e.id) == String(id):
			return e
	return null


func _init():
	var SL = load("res://screen_layout.gd").new()
	check("selftest() del modelo", SL.run_selftest())

	# Normalizacion y defaults.
	var empty = SL.normalize_layout({})
	check("local por defecto", empty.local.id == SL.LOCAL_ID and empty.local.local)
	check("sin vecinos por defecto", empty.screens.empty())
	var bad = SL.sanitize_screen({"id": "h", "w": 0, "h": -1, "x": "nope"})
	check("tamano/coordenada invalidos caen a defaults",
		bad.w == SL.DEFAULT_W and bad.h == SL.DEFAULT_H and bad.x == 0.0)
	check("resolución separada de geometría física",
		bad.px_w == SL.DEFAULT_PX_W and bad.px_h == SL.DEFAULT_PX_H)
	var old = SL.normalize_layout({"version": 1, "local": {"id": "local", "local": true,
		"x": 0, "y": 0, "w": 1920, "h": 1080}, "screens": [{"id": "cupid",
		"x": -1440, "y": 0, "w": 1440, "h": 2160}]})
	check("v1 migra px a resolución y plano físico", old.version == 2
		and old.local.px_w == 1920 and old.screens[0].px_h == 2160
		and abs(old.local.w - 1920.0 * SL.LEGACY_MM_PER_PX) < 0.01)
	var shared = SL.set_share(old, "cupid", "input", true)
	check("preferencia de compartir vive en pantalla", shared.screens[0].share.input
		and not shared.screens[0].share.screen)
	shared.screens.append(SL.sanitize_screen({"id": "tengu"}))
	shared = SL.set_share(shared, "cupid", "audio", true)
	shared = SL.set_share(shared, "tengu", "audio", true)
	check("audio persistente conserva un solo destino", not shared.screens[0].share.audio
		and shared.screens[1].share.audio)
	check("pantalla no-diccionario -> null", SL.sanitize_screen(42) == null)
	check("screens duplicadas descartadas",
		SL.sanitize_screens([{"id": "a"}, {"id": "a"}, {"id": "b"}]).size() == 2)

	# Geometria: contacto y direccion.
	var a = {"id": "a", "x": 0.0, "y": 0.0, "w": 1000.0, "h": 600.0}
	var b_east = {"id": "b", "x": 1000.0, "y": 50.0, "w": 800.0, "h": 500.0}
	var b_south = {"id": "c", "x": 100.0, "y": 600.0, "w": 500.0, "h": 400.0}
	var far = {"id": "d", "x": 5000.0, "y": 5000.0, "w": 800.0, "h": 500.0}
	var ce = SL.contact(a, b_east)
	check("contacto este detectado", not ce.empty() and String(ce.direction) == "east")
	check("offset en px y porcentaje", float(ce.offset) == 50.0
		and abs(float(ce.percent) - 50.0 / 600.0) < 0.0001)
	check("contacto sur detectado", String(SL.contact(a, b_south).direction) == "south")
	check("sin contacto si hay hueco", SL.contact(a, far).empty())
	check("direction_of devuelve cardinal o vacio",
		SL.direction_of(a, b_east) == "east" and SL.direction_of(a, far) == "")
	var physical_a = {"id": "pa", "x": 0.0, "y": 0.0, "w": 340.0, "h": 190.0,
		"px_w": 3840, "px_h": 2160}
	var physical_b = {"id": "pb", "x": 340.0, "y": 0.0, "w": 340.0, "h": 190.0,
		"px_w": 1920, "px_h": 1080}
	var physical_ranges = SL.link_ranges(physical_a, physical_b)
	check("rangos usan tamaño físico aunque cambie DPI/resolución",
		physical_ranges.local_range == [0.0, 100.0]
		and physical_ranges.peer_range == [0.0, 100.0])

	# Imantado: siempre pegado, sin solape y con contacto minimo.
	var lay = {
		"local": {"id": "local", "label": "Este equipo", "local": true,
			"x": 0.0, "y": 0.0, "w": 1000.0, "h": 600.0},
		"screens": [{"id": "h1", "label": "Tengu", "peer": "tengu", "w": 800.0, "h": 500.0}],
	}
	var sn = SL.snap(SL.all_screens(lay), "h1", 970.0, 120.0)
	check("imanta al borde de la local", sn.snapped and String(sn.target) == "local"
		and String(sn.side) == "east")
	var h1 = SL.screen_by_id(lay, "h1")
	h1.x = sn.x
	h1.y = sn.y
	check("pegado sin solape", not SL.overlaps(h1, SL.screen_by_id(lay, "local")))
	check("contacto >= minimo",
		float(SL.contact(SL.screen_by_id(lay, "local"), h1).span) >= SL.MIN_CONTACT)
	check("borde exacto a 1000", h1.x == 1000.0)

	# Desplazamiento libre a lo largo del borde (alineacion arbitraria).
	var sn_low = SL.snap(SL.all_screens(lay), "h1", 1000.0, 20.0)
	check("se desliza por el borde sin recentrar",
		sn_low.snapped and abs(sn_low.y - 20.0) < 0.001)

	# El iman no solapa a una tercera pantalla que ocupe el hueco.
	var crowded = {
		"local": {"id": "local", "local": true, "x": 0.0, "y": 0.0, "w": 1000.0, "h": 600.0},
		"screens": [
			{"id": "a", "peer": "a", "x": 1000.0, "y": 0.0, "w": 800.0, "h": 600.0},
			{"id": "b", "peer": "b", "x": 1000.0, "y": 100.0, "w": 200.0, "h": 200.0},
		],
	}
	var sn2 = SL.snap(SL.all_screens(crowded), "b", 1010.0, 100.0)
	var bb = SL.screen_by_id(crowded, "b")
	bb.x = sn2.x
	bb.y = sn2.y
	check("imanta sin solapar a las otras",
		sn2.snapped and not SL.overlaps(bb, SL.screen_by_id(crowded, "a"))
		and not SL.overlaps(bb, SL.screen_by_id(crowded, "local")))

	# Salida por vecino: direccion local y por cadena, offset y via.
	var chain = {
		"local": {"id": "local", "label": "Este equipo", "local": true,
			"x": 0.0, "y": 0.0, "w": 1000.0, "h": 600.0},
		"screens": [
			{"id": "h1", "label": "Tengu", "peer": "tengu", "x": 1000.0, "y": 50.0,
				"w": 800.0, "h": 500.0},
			{"id": "h2", "label": "Cupido", "peer": "cupid", "x": 1800.0, "y": 80.0,
				"w": 800.0, "h": 500.0},
			{"id": "h3", "label": "Suelto", "peer": "solo", "x": 9000.0, "y": 9000.0,
				"w": 800.0, "h": 500.0},
		],
	}
	var outs = SL.output(chain)
	var o1 = _find(outs, "h1")
	var o2 = _find(outs, "h2")
	check("un vecino por contacto alcanzable", outs.size() == 2)
	check("vecino directo: este desde la local",
		String(o1.direction) == "east" and String(o1.via) == "local")
	check("vecino en cadena: este via h1",
		String(o2.direction) == "east" and String(o2.via) == "h1")
	check("offset en px y porcentaje del borde", float(o1.offset_px) == 50.0
		and abs(float(o1.offset_percent) - 50.0 / 600.0) < 0.0001)
	check("el vecino sin posicion queda fuera", SL.unplaced(chain) == ["h3"])
	check("aristas completas", SL.edges(chain).size() == 2)

	# Salida persistible en host_directions (fuente unica).
	var dirs = SL.to_host_directions(chain)
	check("host_directions con direccion confirmada", dirs.size() == 2
		and String(dirs.h1.direction) == "east" and String(dirs.h1.confirm) == "confirmed"
		and not dirs.has("h3"))
	check("radial se deriva de la misma geometría física",
		abs(float(dirs.h1.along) - 0.5) < 0.0001)
	check("links locales para teclado/mouse", SL.local_links(chain).size() == 1
		and String(SL.local_links(chain)[0].peer) == "tengu")
	check("sin conflictos si cada borde tiene un vecino", SL.conflicts(chain).empty())

	# Colocacion por direccion: precisa, sin solape y determinista.
	var w = SL.place_direction({"local": chain.local, "screens": []}, "h1", "west")
	var wh = SL.screen_by_id(w, "h1")
	check("colocar al oeste pega el borde al local", wh.x + wh.w == 0.0
		and not SL.overlaps(wh, w.local))
	check("colocar al oeste sale como direccion oeste",
		String(SL.output(w)[0].direction) == "west")
	var n = SL.place_direction({"local": chain.local, "screens": []}, "h1", "north")
	var nh = SL.screen_by_id(n, "h1")
	check("colocar al norte pega el borde inferior al local", nh.y + nh.h == 0.0)
	check("misma entrada -> misma salida",
		SL.to_json(SL.place_direction({"local": chain.local, "screens": []}, "h1", "west"))
		== SL.to_json(w))

	# Dos vecinos al mismo borde: el segundo se encadena, sin solape.
	var two = SL.place_direction({"local": chain.local, "screens": []}, "h1", "east")
	two = SL.place_direction(two, "h2", "east")
	var t1 = SL.screen_by_id(two, "h1")
	var t2 = SL.screen_by_id(two, "h2")
	check("cadena sin solape", not SL.overlaps(t1, t2) and not SL.overlaps(t1, two.local)
		and not SL.overlaps(t2, two.local))
	check("el segundo queda mas al este", t2.x >= t1.x + t1.w - 0.001)
	check("sin conflictos de borde tras encadenar", SL.conflicts(two).empty())

	# Quitar de la disposicion: sin contacto (queda sin posicion).
	var removed = SL.place_direction(two, "h2", "none")
	check("quitar libera la pantalla",
		SL.unplaced(removed).has("h2") and not SL.overlaps(SL.screen_by_id(removed, "h2"),
			SL.screen_by_id(removed, "h1")))

	# Serializacion ida y vuelta y determinismo.
	var rt = SL.parse(SL.to_json(two))
	check("json ida y vuelta", SL.to_json(rt) == SL.to_json(two))

	# Vocabulario: nada visible con nombres internos.
	var visible = [SL.LOCAL_LABEL, String(empty.local.label)]
	for e in outs:
		visible.append(String(e.label))
	var forbidden = ["gvd", "deskflow", "mdns", "dns-sd", "recv", "server", "client", "hid"]
	var clean = true
	for s in visible:
		var low = String(s).to_lower()
		for t in forbidden:
			if low.find(t) >= 0:
				clean = false
	check("sin vocabulario interno en cadenas visibles", clean)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
