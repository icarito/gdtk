extends SceneTree

# K13h — Autoprueba del modelo puro de unidades tiled con eje (wm_units.gd).
#   godot --no-window --path shell -s $PWD/tests/wm_units_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var U = load("res://wm_units.gd")
	check("wm_units.gd carga", U != null)
	check("selftest() del modelo", U.selftest())

	var area = Rect2(0, 0, 1280, 720)
	var portrait = Rect2(0, 0, 720, 1280)

	# Eje por orientación.
	check("landscape -> X", U.default_axis(area) == "x")
	check("portrait -> Y", U.default_axis(portrait) == "y")
	check("left -> X", U.axis_for_side("left") == "x")
	check("top -> Y", U.axis_for_side("top") == "y")

	# Solo + join.
	var u = []
	U.solo(u, 1)
	U.solo(u, 2)
	check("dos unidades solas", u.size() == 2)
	U.join(u, 2, 1, "right")
	check("join right fusiona", u.size() == 1)
	check("right: target primero", U.members_of(u, 1) == [1, 2])
	check("right -> eje X", U.axis_of(u, 1) == "x")
	U.join(u, 3, 2, "left")
	check("left inserta al inicio", U.members_of(u, 1) == [3, 1, 2])
	U.join(u, 4, 2, "bottom")
	check("bottom -> eje Y", U.axis_of(u, 1) == "y")
	check("bottom inserta al final", U.members_of(u, 1) == [3, 1, 2, 4])
	check("flatten respeta orden", U.flatten(u) == [3, 1, 2, 4])

	# Remove.
	u = []
	U.join(u, 1, 2, "right")
	U.remove(u, 1)
	check("remove deja sola", U.members_of(u, 2) == [2])
	check("remove no rompe con inexistente", U.remove(u, 99).size() == 1)

	# Move de unidades.
	u = []
	U.solo(u, 1)
	U.solo(u, 2)
	U.solo(u, 3)
	U.move_unit(u, 3, 1, true)
	check("mover unidad antes", U.flatten(u) == [3, 1, 2])
	U.move_unit(u, 3, 2, false)
	check("mover unidad despues", U.flatten(u) == [1, 2, 3])
	U.swap(u, 0, 2)
	check("swap unidades", U.flatten(u) == [3, 2, 1])

	# Inserción de una unidad sola en un índice (lo que usa el exposé al soltar una
	# miniatura en un hueco). `solo` saca y reinserta en el índice pedido.
	u = []
	U.solo(u, 1)
	U.solo(u, 2)
	U.solo(u, 3)
	U.solo(u, 2, 0)
	check("solo en índice 0", U.flatten(u) == [2, 1, 3])
	U.solo(u, 2, u.size())
	check("solo en índice final", U.flatten(u) == [1, 3, 2])
	U.solo(u, 1, 1)
	check("solo en índice medio", U.flatten(u) == [3, 1, 2])
	# `solo_before` inserta antes del ancla recalculando el índice tras extraer.
	u = []
	U.solo(u, 1)
	U.solo(u, 2)
	U.solo(u, 3)
	U.solo_before(u, 1, 3)
	check("solo_before antes del ancla", U.flatten(u) == [2, 1, 3])
	U.solo_before(u, 1, 1)
	check("solo_before ancla propia deja igual", U.flatten(u) == [2, 1, 3])
	# Extraer de una unidad con varios miembros.
	u = []
	U.join(u, 2, 1, "right")   # [1, 2]
	U.solo(u, 3)
	U.solo_before(u, 1, 3)     # 1 sale de [1,2] y queda sola antes de 3
	check("solo_before extrae de grupo", U.flatten(u) == [2, 1, 3])

	# Reparto por eje.
	var unit = {"id": 1, "members": [1, 2], "axis": "x", "weights": {1: 1.0, 2: 1.0}}
	var r = U.member_rects(unit, Rect2(10, 20, 100, 200), 0.0)
	check("X: mitades horizontales", r[1].size.x == 50.0 and r[2].position.x == 60.0)
	check("X: alto completo", r[1].size.y == 200.0)
	unit["axis"] = "y"
	r = U.member_rects(unit, Rect2(10, 20, 100, 200), 0.0)
	check("Y: mitades verticales", r[1].size.y == 100.0 and r[2].position.y == 120.0)
	check("Y: ancho completo", r[1].size.x == 100.0)
	unit["axis"] = "x"
	unit["weights"] = {1: 3.0, 2: 1.0}
	r = U.member_rects(unit, Rect2(10, 20, 100, 200), 0.0)
	check("pesos 3:1", abs(r[1].size.x - 75.0) < 0.001 and abs(r[2].size.x - 25.0) < 0.001)
	var solo = {"members": [9], "axis": "x", "weights": {9: 1.0}}
	check("sola ocupa el area", U.member_rects(solo, area, 4.0)[9] == area)

	# Serialize / parse / migración.
	u = []
	U.join(u, 2, 1, "right")
	U.set_weight(u, 1, 2.5)
	var back = U.parse(U.serialize(u), area)
	check("roundtrip miembros", U.members_of(back, 1) == [1, 2])
	check("roundtrip pesos", abs(U.weight_of(back, 1) - 2.5) < 0.001)
	check("parse tolerante a no-array", U.parse("x", area) == [])
	var legacy = U.from_legacy([5, 6, 7], [[6, 7]], {6: 2.0, 7: 1.0}, portrait)
	check("legacy dos unidades", legacy.size() == 2)
	check("legacy grupo", legacy[1]["members"] == [6, 7])
	check("legacy portrait -> Y", legacy[1]["axis"] == "y")
	check("legacy pesos", abs(legacy[1]["weights"][6] - 2.0) < 0.001)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
