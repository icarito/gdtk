extends SceneTree

# W3 — Contrato de la tira de ventanas del Frame (funciones puras de frame.gd).
# Las claves de unidad que devuelve `shell.frame_strip_unit` se comparan con != en
# `strip_drop_target`, y `strip_unit_at` devuelve la unidad que queda a la DERECHA
# del nuevo escritorio (o null = al final). El Escritorio virtual es la clave 0.
# Correr:
#   <binario dev> --no-window --path shell -s $PWD/tests/frame_strip_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var F = load("res://frame.gd")
	check("frame.gd carga", F != null)

	# Claves de unidad: 0 = Escritorio, id > 0 = líder de la unidad.
	var units = [0, 10, 10, 20, 10, 0]
	check("strip_groups dedupe", F.strip_groups(units) == [0, 10, 20, 10, 0])
	check("strip_groups_before 0", F.strip_groups_before(units, 0) == 0)
	check("strip_groups_before 1", F.strip_groups_before(units, 1) == 1)
	check("strip_groups_before 3", F.strip_groups_before(units, 3) == 2)
	check("strip_groups_before n", F.strip_groups_before(units, units.size()) == 5)

	check("strip_unit_at 0 = Escritorio", F.strip_unit_at(units, 0) == 0)
	check("strip_unit_at 1 = unidad 10", F.strip_unit_at(units, 1) == 10)
	check("strip_unit_at 2 = unidad 20", F.strip_unit_at(units, 2) == 20)
	check("strip_unit_at 3 = unidad 10 otra vez", F.strip_unit_at(units, 3) == 10)
	check("strip_unit_at fin = null (al final)", F.strip_unit_at(units, 5) == null)

	# Drop dentro del strip. Rects en fila, unidades [10, 10, 20, 0].
	var R = [Rect2(0, 0, 40, 40), Rect2(44, 0, 40, 40),
		Rect2(88, 0, 40, 40), Rect2(132, 0, 40, 40)]
	var U = [10, 10, 20, 0]

	var t0 = F.strip_drop_target(R, U, -5)
	check("antes del primero: nuevo al inicio", t0.kind == "new" and int(t0.index) == 0)
	check("derecha del inicio = unidad 10", F.strip_unit_at(U, int(t0.index)) == 10)

	var t1 = F.strip_drop_target(R, U, 42)
	check("borde misma unidad: onto", t1.kind == "onto")
	check("borde misma unidad: lado right", int(t1.tile) == 0 and String(t1.side) == "right")

	var t2 = F.strip_drop_target(R, U, 86)
	check("borde distinta unidad: nuevo", t2.kind == "new" and int(t2.index) == 1)
	check("derecha del nuevo = unidad 20", F.strip_unit_at(U, int(t2.index)) == 20)

	var t3 = F.strip_drop_target(R, U, 500)
	check("despues del ultimo: nuevo al final", t3.kind == "new" and F.strip_unit_at(U, int(t3.index)) == null)

	var t4 = F.strip_drop_target(R, U, 10)
	check("sobre tesela: onto left", t4.kind == "onto" and int(t4.tile) == 0 and String(t4.side) == "left")
	var t5 = F.strip_drop_target(R, U, 35)
	check("sobre tesela: onto right", t5.kind == "onto" and int(t5.tile) == 0 and String(t5.side) == "right")

	check("sin teselas: null", F.strip_drop_target([], [], 10) == null)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
