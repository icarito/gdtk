extends SceneTree

# Autoprueba del modelo puro del selector de pantallazos (screenshot_model.gd):
# normalización de la selección, mapeo UI->píxeles de imagen (HiDPI), geometría de la
# barra y nombre del archivo.
#   godot --no-window --path shell -s $PWD/tests/screenshot_model_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var M = load("res://screenshot_model.gd")

	# Normalización: cualquier dirección, recortado a bounds, mínimo de lado.
	var b = Rect2(0, 0, 100, 80)
	check("arrastre invertido se normaliza", M.normalize_rect(Vector2(80, 60), Vector2(20, 10), b) == Rect2(20, 10, 60, 50))
	check("recorta a los límites", M.normalize_rect(Vector2(-10, -10), Vector2(200, 200), b) == Rect2(0, 0, 100, 80))
	check("descarta un clic sin arrastre", M.normalize_rect(Vector2(50, 40), Vector2(51, 41), b) == Rect2())
	check("acepta justo en el mínimo", M.normalize_rect(Vector2(10, 10), Vector2(14, 14), b) == Rect2(10, 10, 4, 4))

	# Escala y recorte: en HiDPI la imagen es 2x el viewport.
	var vp = Vector2(100, 80)
	var img = Vector2(200, 160)
	check("escala 2x", M.scale_for(img, vp) == Vector2(2, 2))
	check("recorte escala a píxeles", M.crop_rect(Rect2(10, 20, 30, 40), vp, img) == Rect2(20, 40, 60, 80))
	check("recorte con ceil en el borde", M.crop_rect(Rect2(10.5, 0, 10.2, 10), vp, img) == Rect2(21, 0, 21, 20))
	check("recorte fuera de la imagen -> vacío", M.crop_rect(Rect2(90, 70, 30, 30), vp, img) == Rect2(180, 140, 20, 20))
	check("recorte a 1:1", M.crop_rect(Rect2(5, 5, 10, 10), vp, vp) == Rect2(5, 5, 10, 10))

	# Barra: centrada arriba, sin solapamiento, hit-test correcto.
	var items = [{"id": "window", "label": "Ventana"}, {"id": "screen", "label": "Pantalla"},
		{"id": "region", "label": "Selección"}, {"id": "cancel", "label": "Cancelar"}]
	var buttons = M.toolbar_layout(vp, 1.0, items)
	check("un rect por botón", buttons.size() == 4)
	var first = Rect2(buttons[0]["rect"])
	var last = Rect2(buttons[3]["rect"])
	check("fila centrada", abs((first.position.x + last.end.x) * 0.5 - vp.x * 0.5) < 0.01)
	check("sin solapamiento", first.end.x <= Rect2(buttons[1]["rect"]).position.x + 0.01)
	check("hit-test primer botón", M.button_at(first.position + first.size * 0.5, buttons) == "window")
	check("hit-test último botón", M.button_at(last.position + last.size * 0.5, buttons) == "cancel")
	check("fuera de la barra -> vacío", M.button_at(Vector2(5, vp.y - 5), buttons) == "")

	# Nombre del archivo según el tipo.
	check("nombre pantalla", M.suggest_name("screen", "2026-01-02_03-04-05") == "Pantallazo-2026-01-02_03-04-05.png")
	check("nombre región", M.suggest_name("region", "S") == "Pantallazo-region-S.png")
	check("nombre ventana", M.suggest_name("window", "S") == "Pantallazo-ventana-S.png")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
