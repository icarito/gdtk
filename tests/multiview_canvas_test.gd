extends SceneTree

# Autoprueba PURA de la composición offscreen del multiview (F4/§9 N1): sólo la
# geometría (letterbox dentro del tile) y el contrato del archivo shm. Sin I/O.
#   godot --no-window --path shell -s $PWD/tests/multiview_canvas_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var S = load("res://multiview_canvas.gd")
	check("header 64 y magic GVDSHM1",
		int(S.HEADER) == 64 and int(S.MAGIC.size()) == 8
		and int(S.MAGIC[0]) == 0x47 and int(S.MAGIC[7]) == 0x00)

	# fit_rect: letterbox con aspecto preservado dentro del tile, sin salirse.
	var r = S.fit_rect(Vector2(1600, 900), Rect2(Vector2(10, 20), Vector2(400, 400)))
	check("fit dentro del rect",
		r.position.x >= 10.0 - 0.01 and r.position.y >= 20.0 - 0.01
		and r.position.x + r.size.x <= 410.0 + 0.01
		and r.position.y + r.size.y <= 420.0 + 0.01)
	check("fit conserva aspecto", abs(r.size.x / r.size.y - 1600.0 / 900.0) < 0.001)
	check("fit llena el lado corto", abs(r.size.x - 400.0) < 0.01)

	# Cuadrado en tile ancho: se centra horizontalmente.
	var r2 = S.fit_rect(Vector2(100, 100), Rect2(Vector2(0, 0), Vector2(400, 200)))
	check("cuadrado en tile ancho conserva aspecto",
		abs(r2.size.x / r2.size.y - 1.0) < 0.001 and abs(r2.size.y - 200.0) < 0.01)
	check("cuadrado centrado", abs(r2.position.x - 100.0) < 0.01)

	# Degenerados: texture o rect nulos -> rect tal cual.
	check("tex nulo -> rect original",
		S.fit_rect(Vector2(), Rect2(Vector2(5, 5), Vector2(10, 10))).size == Vector2(10, 10))

	# Enteros little-endian a mano (el contrato del archivo shm). OJO: resize() no
	# pone a cero la memoria en este fork, hay que inicializar explícitamente.
	var b4 = PoolByteArray()
	b4.resize(4)
	for k in range(4):
		b4[k] = 0
	b4[0] = 0x01; b4[1] = 0x02; b4[2] = 0x03; b4[3] = 0x04
	check("u32 little-endian", int(S._u32(b4, 0)) == 0x04030201)
	var b8 = PoolByteArray()
	b8.resize(8)
	for k in range(8):
		b8[k] = 0
	b8[0] = 0x02; b8[1] = 0x01
	check("u64 little-endian", int(S._u64(b8, 0)) == 258)
	b8[7] = 0x01
	check("u64 byte alto", int(S._u64(b8, 0)) == 258 + (1 << 56))

	print("fallos=" + str(failed))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
