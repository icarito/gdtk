extends SceneTree

# K13d — Autoprueba de las decisiones puras de arrastre/soltar entre mosaico y
# flotante. Sin input real ni shell.gd.
#   godot --no-window --path shell -s $PWD/tests/wm_drag_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var D = load("res://wm_drag.gd")
	check("wm_drag.gd carga", D != null)
	check("selftest() del modelo", D.selftest())

	var cr = Rect2(0, 80, 1280, 640)
	# Soltar dentro del hueco: queda flotante.
	check("drop dentro -> flotante", D.drop_zone(Vector2(400, 300), cr, {}, false, "floating").kind == "float")
	# Soltar fuera del hueco: reincorporar al mosaico en ese lado.
	check("drop arriba -> reincorporar top",
		D.drop_zone(Vector2(400, 40), cr, {}, false, "floating").target == "top")
	check("drop abajo -> reincorporar bottom",
		D.drop_zone(Vector2(400, 790), cr, {}, false, "floating").target == "bottom")
	check("drop izquierda -> reincorporar left",
		D.drop_zone(Vector2(-5, 300), cr, {}, false, "floating").target == "left")
	check("drop derecha -> reincorporar right",
		D.drop_zone(Vector2(1400, 300), cr, {}, false, "floating").target == "right")
	# Sobre un bloque del Frame: reincorporar.
	check("drop sobre bloque -> reincorporar",
		D.drop_zone(Vector2(400, 300), cr, {}, true, "floating").kind == "reincorporate")

	# Desprender de la celda al arrastrar fuera.
	check("dentro de la celda no desprende", not D.drag_out(Rect2(100, 100, 400, 300), Vector2(300, 250)))
	check("fuera de la celda desprende", D.drag_out(Rect2(100, 100, 400, 300), Vector2(700, 250)))
	check("rect nulo desprende", D.drag_out(null, Vector2(0, 0)))

	# Barra del Frame y tamaño recordado.
	check("sobre barra superior", D.over_frame_bar(Vector2(10, 10), Vector2(1280, 800), 80.0))
	check("sobre barra inferior", D.over_frame_bar(Vector2(10, 795), Vector2(1280, 800), 80.0))
	check("centro no es barra", not D.over_frame_bar(Vector2(10, 400), Vector2(1280, 800), 80.0))
	check("restore_size recuerda", D.restore_size(Vector2(500, 400), Vector2(800, 600)) == Vector2(500, 400))
	check("restore_size fallback", D.restore_size(null, Vector2(800, 600)) == Vector2(800, 600))
	check("restore_size inválido -> fallback", D.restore_size(Vector2(0, 0), Vector2(800, 600)) == Vector2(800, 600))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
