extends SceneTree

# Autoprueba del popup de revisión del layout de Grupo (SPEC-sugar-group-2026-10):
# modelo puro shell/layout_confirm.gd (countdown/aceptar/revertir/dismiss) y la
# vista mini shell/screen_layout.gd::mini_map (mapeo de pantallas al rect destino).

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func approx(a, b, eps = 0.51):
	return abs(a - b) <= eps


func _init():
	var LC = load("res://layout_confirm.gd")
	var SL = load("res://screen_layout.gd")
	check("modelos cargan", LC != null and SL != null)
	check("timeout default", LC.DEFAULT_TIMEOUT_MS == 10000.0)

	# --- layout_confirm: propuesta, countdown y default aceptar ---------------
	var m = LC.new()
	check("cerrado: tick no hace nada", m.tick(0) == "" and not m.open)
	check("cerrado: seconds_left 0", m.seconds_left(500) == 0)

	var base = SL.normalize_layout({})
	var prop = SL.normalize_layout({
		"version": 2, "unit": "mm", "local": {"id": "local", "x": 0.0, "y": 0.0},
		"screens": [{"id": "h1", "x": -270.0, "y": 100.0, "w": 270.0, "h": 400.0}],
	})
	m.propose(base, 1000)
	check("abre con baseline", m.open and m.baseline == base)
	check("segundos restantes 10", m.seconds_left(1000) == 10)
	check("antes del vencimiento: ''", m.tick(10999.0) == "" and m.open)
	check("vencido: accept y cierra", m.tick(11000.0) == "accept" and not m.open)

	# Re-propuesta dentro de la ventana viva: la base SIEMPRE es la primera.
	var base2 = SL.normalize_layout({
		"version": 2, "unit": "mm", "local": {"id": "local", "x": 0.0, "y": 0.0},
		"screens": [{"id": "x1", "x": -3.0, "y": -3.0, "w": 3.0, "h": 3.0}],
	})
	m.propose(base2, 20000)
	check("re-propuesta abre", m.open)
	var base3 = SL.normalize_layout({
		"version": 2, "unit": "mm", "local": {"id": "local", "x": 0.0, "y": 0.0},
		"screens": [{"id": "otro", "x": -1.0, "y": -1.0, "w": 2.0, "h": 2.0}],
	})
	m.propose(base3, 20500)
	check("baseline de la racha se conserva",
		int(m.baseline.screens[0].w) == 3 and String(m.baseline.screens[0].id) == "x1")
	check("countdown rearma", m.seconds_left(20500) == 10)
	check("vencido de nuevo: accept", m.tick(30500.5) == "accept" and not m.open)

	# Revert y dismiss: sólo cuentan con la ventana abierta.
	m = LC.new()
	m.propose(base, 0)
	check("revert con ventana abierta", m.revert() == "revert" and not m.open)
	check("revert sin ventana: ''", m.revert() == "")
	m.propose(base, 0)
	check("dismiss cuenta como accept", m.dismissed() == "accept" and not m.open)
	m.propose(base, 0, 5000)
	check("timeout custom", m.seconds_left(0) == 5 and m.tick(4999.9) == "" and m.tick(5000.0) == "accept")

	# --- mini_map: mapeo proporcional, centrado y marcas ----------------------
	# El acomodo del incidente (cadena): local abajo-tengu derecha... el mismo de
	# bastion antes del fix: cupid al oeste y tengu encadenado al sur de cupid.
	var lay = {
		"version": 2, "unit": "mm",
		"local": {"id": "local", "label": "bastion", "x": 0.0, "y": 0.0, "w": 508.0, "h": 285.75},
		"screens": [
			{"id": "tengu", "label": "tengu", "x": 0.0, "y": 285.75, "w": 508.0, "h": 250.0},
			{"id": "cupid", "label": "cupid", "x": -270.0, "y": 127.721954, "w": 270.0, "h": 400.0},
		],
	}
	var target = Rect2(0.0, 0.0, 252.0, 120.0)
	var marks = SL.mini_map(lay, target, "tengu")
	check("mini_map: 3 pantallas", marks.size() == 3)
	var by_id = {}
	for mk in marks:
		by_id[String(mk.id)] = mk
	check("mini_map: local marcado", String(by_id["local"].label) == "bastion" and bool(by_id["local"].is_local))
	check("mini_map: pares no locales", not bool(by_id["tengu"].is_local) and not bool(by_id["cupid"].is_local))
	check("mini_map: moved solo el acomodado",
		bool(by_id["tengu"].moved) and not bool(by_id["local"].moved) and not bool(by_id["cupid"].moved))
	# Dentro del destino y proporción del bbox preservada.
	var all_inside = true
	var map_bbox = Rect2(by_id["local"].rect.position, by_id["local"].rect.size)
	for mk in marks:
		var r = mk.rect
		all_inside = all_inside and r.position.x >= -0.6 and r.position.y >= -0.6 \
			and r.end.x <= target.size.x + 0.6 and r.end.y <= target.size.y + 0.6
		map_bbox = map_bbox.merge(r)
	check("mini_map: dentro del rect destino", all_inside)
	var src_ratio = 778.0 / 535.75          # bbox: x -270..508, y 0..535.75
	var got_ratio = map_bbox.size.x / map_bbox.size.y
	check("mini_map: proporción del bbox", approx(got_ratio, src_ratio, 0.05))

	# Layout vacío: la local default cubre todo (no revienta).
	var empty = SL.mini_map({}, Rect2(0.0, 0.0, 100.0, 50.0))
	check("mini_map: layout vacío -> 1 pantalla", empty.size() == 1)
	check("mini_map: vacío es local con Este equipo",
		String(empty[0].id) == "local" and String(empty[0].label) == "Este equipo")

	# --- transform + mm/mm_rect + edge + resize (drag en el popup) -------------
	var t = SL.mini_map_transform(lay, target)
	var bsrc = Rect2(-270.0, 0.0, 778.0, 535.75)
	check("transform: k", approx(float(t.k), min(target.size.x / 778.0, target.size.y / 535.75), 0.002))
	check("transform: bbox y off", approx(float(t.bbox.position.x), -270.0, 0.01)
		and approx(t.off.x, (252.0 - 778.0 * float(t.k)) * 0.5, 0.01)
		and approx(t.off.y, (120.0 - 535.75 * float(t.k)) * 0.5, 0.01))

	# roundtrip: centro del rect en px vuelve al centro en mm de la pantalla.
	var scr = {"id": "tengu", "label": "tengu", "x": 100.0, "y": 300.0, "w": 404.0, "h": 200.0, "local": false}
	var rr = SL.mm_rect(t, scr)
	var cmm = SL.mm_pos(t, rr.position + rr.size * 0.5)
	check("mm/mm_rect: roundtrip del centro",
		approx(cmm.x, 302.0, 0.5) and approx(cmm.y, 400.0, 0.5))
	check("mm_rect: nunca degenera", rr.size.x >= 1.0 and rr.size.y >= 1.0)

	# mini_map_edge: borde dentro de la tolerancia -> side; interior -> "".
	var marks2 = SL.mini_map(lay, target, "")
	var tmark = {}
	for mk in marks2:
		if String(mk.id) == "tengu":
			tmark = mk
	var tr = tmark.rect
	check("edge: este a 2 px -> east",
		String(SL.mini_map_edge(marks2, Vector2(tr.end.x - 2.0, tr.position.y + tr.size.y * 0.5)).get("edge", ""))
		== "east")
	check("edge: sur a 1 px -> south",
		String(SL.mini_map_edge(marks2, Vector2(tr.position.x + tr.size.x * 0.5, tr.end.y - 1.0)).get("edge", ""))
		== "south")
	check("edge: centro -> sin lado (mover)",
		SL.mini_map_edge(marks2, tr.position + tr.size * 0.5).get("edge", "") == "")
	check("edge: fuera -> sin pantalla",
		SL.mini_map_edge(marks2, Vector2.ZERO).get("id", "") == "")
	check("pick: centro de tengu", String(SL.mini_map_pick(marks2, tr.position + tr.size * 0.5).get("id", "")) == "tengu")
	check("pick: fuera -> {}", SL.mini_map_pick(marks2, Vector2.ZERO).empty())
	check("pick_near: margen agarra tengu",
		String(SL.mini_map_pick_near(marks2, tr.end + Vector2(6.0, 0.0), 12.0).get("id", "")) == "tengu")
	check("pick_near: lejos -> {}",
		SL.mini_map_pick_near(marks2, Vector2(2000.0, 2000.0), 12.0).empty())

	# resize_edge: aspecto fijo y ancla en el borde opuesto / centro del eje libre.
	var rs = {"x": 100.0, "y": 100.0, "w": 508.0, "h": 250.0}
	var e1 = SL.resize_edge(rs, "east", {"x": 354.0, "y": 0.0})
	check("resize east: x y w", approx(e1.x, 100.0) and approx(e1.w, 254.0, 0.01))
	check("resize east: aspecto", approx(e1.h, 254.0 * (250.0 / 508.0), 0.01))
	check("resize east: centro-y clavado", approx(e1.y + e1.h * 0.5, 225.0, 0.01))
	var w1 = SL.resize_edge(rs, "west", {"x": 20.0, "y": 0.0})
	check("resize west: borde este clavado", approx(w1.x + w1.w, 608.0, 0.01))
	check("resize west: aspecto", approx(w1.w / w1.h, 508.0 / 250.0, 0.01))
	var n1 = SL.resize_edge(rs, "north", {"x": 0.0, "y": 40.0})
	check("resize north: borde sur clavado", approx(n1.y + n1.h, 350.0, 0.01))
	check("resize north: centro-x clavado", approx(n1.x + n1.w * 0.5, 354.0, 0.01))
	var s1 = SL.resize_edge(rs, "south", {"x": 0.0, "y": 375.0})
	check("resize south: y clavado y aspecto", approx(s1.y, 100.0) and approx(s1.w / s1.h, 508.0 / 250.0, 0.01))
	var big = SL.resize_edge(rs, "east", {"x": 99999.0, "y": 0.0}, 50.0, 3000.0)
	check("resize: tope del máximo", approx(big.w, 3000.0) and approx(big.h, 3000.0 * (250.0 / 508.0), 0.01))
	var tiny = SL.resize_edge(rs, "west", {"x": 99999.0, "y": 0.0})
	check("resize: mínimo por debajo", approx(tiny.w, 50.0) and approx(tiny.x + tiny.w, 608.0, 0.01))

	# --- snap: soltar solapando pega contra ESA pantalla (no se va lejos) ------
	var snap_lay = {
		"version": 2, "unit": "mm",
		"local": {"id": "local", "x": 0.0, "y": 0.0, "w": 508.0, "h": 285.75},
		"screens": [
			{"id": "cupid", "x": -270.0, "y": 127.72, "w": 270.0, "h": 400.0},
			{"id": "x1", "x": -210.0, "y": 200.0, "w": 270.0, "h": 400.0},
		],
	}
	var sn = SL.snap(SL.all_screens(snap_lay), "x1", -210.0, 200.0)
	check("snap: solape pega contra la solapada",
		String(sn.get("target", "")) == "cupid" and bool(sn.get("snapped", false)))
	var far_lay = {
		"version": 2, "unit": "mm",
		"local": {"id": "local", "x": 0.0, "y": 0.0, "w": 508.0, "h": 285.75},
		"screens": [
			{"id": "cupid", "x": -270.0, "y": 127.72, "w": 270.0, "h": 400.0},
			{"id": "x1", "x": 900.0, "y": 0.0, "w": 270.0, "h": 400.0},
		],
	}
	var sn2 = SL.snap(SL.all_screens(far_lay), "x1", 900.0, 0.0)
	check("snap: lejos elige por costo", String(sn2.get("target", "")) == "local")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
