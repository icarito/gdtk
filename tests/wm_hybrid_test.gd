extends SceneTree

# K13g — Autoprueba del estado puro del modo por ventana (wm_hybrid.gd).
#   godot --no-window --path shell -s $PWD/tests/wm_hybrid_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var H = load("res://wm_hybrid.gd")
	check("wm_hybrid.gd carga", H != null)
	var m = H.new()
	check("run_selftest() del modelo", m.run_selftest())

	# Defaults.
	check("default flotante", m.mode(1) == "floating")
	check("default ancla Escritorio", m.anchor(1) == H.ESCRITORIO)
	check("default sin rect", m.float_rect(1) == null)

	# Transiciones tiled <-> floating.
	m.set_tiled(7, 2)
	check("set_tiled con ancla", m.is_tiled(7) and m.anchor(7) == 2)
	m.set_floating(7, 1, Rect2(10, 20, 300, 200))
	check("vuelve a flotante", m.is_floating(7) and m.anchor(7) == 1)
	check("rect recordado", m.float_rect(7) == Rect2(10, 20, 300, 200))

	# set_float_rect / reanchor / set_mode tolerante.
	m.set_float_rect(7, Rect2(1, 2, 3, 4))
	check("set_float_rect", m.float_rect(7) == Rect2(1, 2, 3, 4))
	m.reanchor(7, 0)
	check("reanchor", m.anchor(7) == 0)
	m.set_mode(7, "mosaico")
	check("set_mode tolerante", m.mode(7) == "tiled")

	# ids_mode / forget.
	m.set_mode(9, "floating")
	check("ids_mode flotante", m.ids_mode(H.FLOATING).has(9))
	check("ids_mode tiled", m.ids_mode(H.TILED).has(7))
	m.forget(9)
	check("forget", not m.ids().has(9))

	# Roundtrip.
	m.set_tiled(5, 3)
	m.set_floating(6, 0, Rect2(7, 8, 9, 10))
	var m2 = H.new()
	m2.parse(m.serialize())
	check("roundtrip tiled", m2.mode(5) == "tiled" and m2.anchor(5) == 3)
	check("roundtrip rect", m2.float_rect(6) == Rect2(7, 8, 9, 10))
	check("parse tolerante a basura", H.new().parse({"x": "basura"}).empty())
	check("normalize", H.normalize_mode("Tiled") == "tiled")

	# heal_anchors: ancla muerta -> sobreviviente / índice / Escritorio.
	var h = H.new()
	h.set_tiled(10, 10)
	h.set_tiled(11, 10)
	h.set_floating(5, 10)
	h.heal_anchors([[], [10, 11], [20]], [[], [11], [20]])
	check("heal: miembro sobreviviente", h.anchor(5) == 11)
	h.heal_anchors([[], [11], [20]], [[], [20]])
	check("heal: unidad en su índice", h.anchor(5) == 20)
	h.heal_anchors([[], [20]], [[]])
	check("heal: sin unidades -> Escritorio", h.anchor(5) == H.ESCRITORIO)
	h.set_floating(6, 0)
	check("heal: estable", h.heal_anchors([[], [20]], [[], [20]]) == 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
