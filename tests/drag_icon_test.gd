extends SceneTree

# Test puro de la matemática del icono de drag (shell/drag_icon.gd). Alcance
# headless: sólo rect/hotspot y clamp de tamaño; el camino real wlroots->textura
# se cubre por wiring en dnd_wiring_test.gd.
#   godot --no-window --path shell -s $PWD/tests/drag_icon_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var D = load("res://drag_icon.gd")
	check("drag_icon.gd carga", D != null)

	# 1. Sin hotspot: el top-left queda en el puntero.
	var r0 = D.icon_rect(Vector2(100, 50), Vector2(32, 24))
	check("rect sin hotspot: pos = puntero", r0.position == Vector2(100, 50))
	check("rect sin hotspot: size", r0.size == Vector2(32, 24))

	# 2. Hotspot negativo (el cliente corre el buffer para centrar el punto de agarre).
	var r1 = D.icon_rect(Vector2(100, 50), Vector2(32, 24), Vector2(-16, -12))
	check("rect con hotspot: pos = puntero + offset", r1.position == Vector2(84, 38))
	check("rect con hotspot: size intacto", r1.size == Vector2(32, 24))

	# 3. Clamp: conserva aspecto y no crece si ya entra.
	var c0 = D.clamp_size(Vector2(32, 24), 160.0)
	check("clamp: tamaño chico intacto", c0 == Vector2(32, 24))
	var c1 = D.clamp_size(Vector2(320, 160), 160.0)
	check("clamp: reduce al máximo", abs(c1.x - 160.0) < 0.001 and abs(c1.y - 80.0) < 0.001)
	var c2 = D.clamp_size(Vector2(50, 400), 160.0)
	check("clamp: conserva aspecto", abs(c2.x - 20.0) < 0.001 and abs(c2.y - 160.0) < 0.001)
	check("clamp: max_side<=0 no limita", D.clamp_size(Vector2(5000, 5000), 0.0) == Vector2(5000, 5000))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
