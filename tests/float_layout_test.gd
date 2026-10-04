extends SceneTree

# K13c — Autoprueba de la colocación pura del modo flotante (cascada, z-order,
# encaje en el hueco central). Instancia el modelo; sin I/O ni shell.gd.
#   godot --no-window --path shell -s $PWD/tests/float_layout_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _eq(a, b):
	return abs(a.position.x - b.position.x) < 0.001 and abs(a.position.y - b.position.y) < 0.001 \
		and abs(a.size.x - b.size.x) < 0.001 and abs(a.size.y - b.size.y) < 0.001


func _init():
	var F = load("res://float_layout.gd")
	check("float_layout.gd carga", F != null)
	var m = F.new()
	check("run_selftest() del modelo", m.run_selftest())

	# Constantes de producto.
	check("mínimo exterior 320x240", m.MIN_W == 320.0 and m.MIN_H == 240.0)

	var box = Rect2(0, 80, 1280, 640)
	m.reset()
	var a = m.place_new(1, box)
	var b = m.place_new(2, box)
	check("place_new devuelve rect no vacío", a.size.x > 0.0 and a.size.y > 0.0)
	check("inteligente: la segunda no cae exactamente encima", b.position != a.position)
	check("ambas dentro de la caja", box.encloses(a) and box.encloses(b))
	check("z-order: la última arriba", m.ids_z() == [1, 2] and m.top_id() == 2)
	check("place_new enfoca", m.focused() == 2)
	# Con obstáculos concentrados a la izquierda, elige una posición con menos
	# solapamiento que la cascada histórica inmediata.
	var smart = F.new()
	smart.set_rect(10, Rect2(box.position + Vector2(8, 8), Vector2(600, 500)))
	smart.order = [10]
	var placed = smart.place_new(11, box)
	var legacy = smart._cascade_rect(box, 1)
	check("place_new minimiza solapamiento",
		smart._overlap_area(placed, smart.rect(10)) <= smart._overlap_area(legacy, smart.rect(10)))
	check("place_new sigue dentro de la caja", box.encloses(placed))

	# Foco reordena sin mover la geometría.
	var a_rect = m.rect(1)
	m.set_focus(1)
	check("set_focus sube al tope", m.top_id() == 1 and m.focused() == 1)
	check("foco no mueve la ventana", _eq(m.rect(1), a_rect))

	# Mover y redimensionar: encajan en la caja y respetan mínimos.
	var mv = m.move_to(1, Vector2(-9999, -9999), box)
	check("move encaja arriba-izquierda", _eq(mv, Rect2(box.position, mv.size)))
	var mv2 = m.move_to(1, Vector2(9999, 9999), box)
	check("move encaja abajo-derecha", mv2.position == box.end - mv2.size)
	var rz = m.resize_to(1, Rect2(Vector2(200, 300), Vector2(10, 10)), box)
	check("resize respeta tamaño mínimo", rz.size.x == 320.0 and rz.size.y == 240.0)
	var big = m.resize_to(1, Rect2(Vector2(0, 0), Vector2(9999, 9999)), box)
	check("resize enorme encaja en la caja", big.size.x <= box.size.x and big.size.y <= box.size.y)

	# from_units materializa tiled -> cascada y enfoca la indicada.
	var m2 = F.new()
	m2.from_units([[10], [20, 30]], box, 30)
	check("from_units materializa todas", m2.ids_z() == [10, 20, 30])
	check("from_units enfoca la pedida", m2.focused() == 30 and m2.top_id() == 30)

	# to_row ordena por centro (y, x).
	var m3 = F.new()
	m3.set_rect(1, Rect2(0, 500, 100, 100))
	m3.set_rect(2, Rect2(0, 100, 100, 100))
	m3.order = [1, 2]
	check("to_row por centro vertical", m3.to_row(box) == [2, 1])

	# remove: la minimizada sale y el foco cae al tope.
	var m4 = F.new()
	m4.from_units([[1], [2], [3]], box, 3)
	m4.remove(3)
	check("remove saca la minimizada", not m4.has(3) and m4.ids_z() == [1, 2])
	check("remove reubica el foco", m4.focused() == 2)

	# Determinismo.
	var d1 = F.new()
	d1.from_units([[1], [2], [3]], box, 1)
	var d2 = F.new()
	d2.from_units([[1], [2], [3]], box, 1)
	var same = d1.ids_z() == d2.ids_z()
	for id in d1.rects.keys():
		if d1.rects[id] != d2.rects[id]:
			same = false
	check("determinista", same)

	# Caja degenerada: no rompe ni devuelve tamaños negativos.
	var z = F.new().place_new(1, Rect2(0, 0, 0, 0))
	check("caja vacía no rompe", z.size.x >= 0.0 and z.size.y >= 0.0)

	# clamp_rect (overlay de resize diferido): encaja posición y tamaño en la caja.
	var cr1 = F.new().clamp_rect(box, Rect2(-50, 60, 400, 300))
	check("clamp_rect encaja posición", cr1.position.x == box.position.x and cr1.position.y >= box.position.y)
	var cr2 = F.new().clamp_rect(box, Rect2(200, 300, 9999, 9999))
	check("clamp_rect cap de tamaño", cr2.size.x <= box.size.x and cr2.size.y <= box.size.y and box.encloses(cr2))
	var cr3 = F.new().clamp_rect(box, Rect2(100, 200, 400, 300))
	check("clamp_rect no cambia un rect que ya entra", cr3 == Rect2(100, 200, 400, 300))

	# Memoria de geometría (K13 punto 4): restore_units conserva el lugar previo y
	# sólo las ventanas nuevas caen a cascada; siempre encaja en la caja.
	var mem = {1: Rect2(300, 200, 500, 400)}
	var m5 = F.new()
	m5.restore_units([[1], [2]], box, mem, 2)
	check("restore_units conserva el rect recordado", m5.rect(1) == Rect2(300, 200, 500, 400))
	check("restore_units cascada para la nueva", m5.rect(2).size.x > 0.0 and box.encloses(m5.rect(2)))
	check("restore_units enfoca la pedida", m5.focused() == 2 and m5.top_id() == 2)
	var m6 = F.new()
	m6.restore_units([[1]], box, {1: Rect2(-999, -999, 500, 400)}, -1)
	check("restore_units encaja en la caja", box.encloses(m6.rect(1)))
	var m7 = F.new()
	m7.restore_one(9, Rect2(100, 200, 400, 300), box)
	check("restore_one coloca y encaja", m7.rect(9) == Rect2(100, 200, 400, 300))
	var m8 = F.new()
	m8.restore_units([[1]], box, {}, -1)
	check("restore_units sin memoria usa cascada", m8.rect(1).size.x > 0.0 and box.encloses(m8.rect(1)))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
