extends SceneTree

# Autoprueba del hueco central del Frame (K12): la función pura content_rect que
# ubica ventanas, diálogos y ventanas hijas entre los bloques del Frame, y el
# encaje clamp_inside que las limita a ese rect. Sin render, sin I/O, sin procesos.
#   godot --no-window --path shell -s $PWD/tests/content_rect_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _eq(a, b):
	return abs(a.position.x - b.position.x) < 0.001 and abs(a.position.y - b.position.y) < 0.001 \
		and abs(a.size.x - b.size.x) < 0.001 and abs(a.size.y - b.size.y) < 0.001


func _init():
	var S = load("res://content_layout.gd")

	check("selftest() del modelo", S.selftest())

	check("viewport no válido -> rect vacío", S.content_rect("nope", 80.0, {}) == Rect2())

	# Barras superior e inferior: es el hueco central de hoy (frame superior+inferior).
	# Cada barra fijada reserva su franja (sin gap extra con la ventana).
	var top_bottom = S.content_rect(Vector2(1280, 800), 80.0, {"top": true, "bottom": true})
	check("arriba y abajo: franja central", _eq(top_bottom, Rect2(0, 80, 1280, 640)))
	check("no pisa la barra superior", top_bottom.position.y == 80.0)
	check("no pisa la barra inferior", top_bottom.end.y == 720.0)

	# Los cuatro lados: un bloque por lado (K12, no sólo arriba y abajo).
	var all4 = S.content_rect(Vector2(1280, 800), 80.0,
		{"top": true, "bottom": true, "left": true, "right": true})
	check("cuatro lados: hueco más angosto", _eq(all4, Rect2(80, 80, 1120, 640)))

	# Área de diálogos: viewport menos un bloque por cada lado SIEMPRE (haya o no
	# barras fijadas). Es donde el diálogo flota sobre su host conservando su tamaño.
	check("área de diálogos = full - 1 bloque por lado",
		_eq(S.dialog_area(Vector2(1280, 800), 80.0), all4))
	check("área de diálogos sin bloque = viewport",
		_eq(S.dialog_area(Vector2(1280, 800), 0.0), Rect2(0, 0, 1280, 800)))
	check("área de diálogos no depende del pin", _eq(
		S.dialog_area(Vector2(1280, 800), 80.0),
		S.content_rect(Vector2(1280, 800), 80.0, ["top", "bottom", "left", "right"])))

	# Sólo laterales: no se reserva alto extra.
	var sides = S.content_rect(Vector2(1280, 800), 80.0, {"left": true, "right": true})
	check("sólo laterales", _eq(sides, Rect2(80, 0, 1120, 800)))

	# Con autohide (sin lados reservados) la ventana usa todo el viewport; una barra
	# fijada (pin) reserva su franja. El autohide no redimensiona la ventana.
	check("autohide: viewport completo", _eq(S.content_rect(Vector2(1280, 800), 80.0, {}), Rect2(0, 0, 1280, 800)))
	check("pin superior reserva su franja", _eq(S.content_rect(Vector2(1280, 800), 80.0, {"top": true}), Rect2(0, 80, 1280, 720)))
	check("pin inferior reserva su franja", _eq(S.content_rect(Vector2(1280, 800), 80.0, {"bottom": true}), Rect2(0, 0, 1280, 720)))
	check("ambas barras fijadas: hueco entre las dos", _eq(S.content_rect(Vector2(1280, 800), 80.0, {"top": true, "bottom": true}), Rect2(0, 80, 1280, 640)))

	# Sin lados ocupados: viewport completo.
	check("sin Frame -> viewport completo",
		_eq(S.content_rect(Vector2(1280, 800), 80.0, {}), Rect2(0, 0, 1280, 800)))
	check("bloque 0 -> viewport completo",
		_eq(S.content_rect(Vector2(1280, 800), 0.0, {"top": true, "bottom": true}),
			Rect2(0, 0, 1280, 800)))

	# Formas alternativas: array de lados, alias arriba/abajo y cardinales.
	check("array de lados",
		_eq(S.content_rect(Vector2(1280, 800), 80.0, ["top", "bottom"]), top_bottom))
	check("alias up/down",
		_eq(S.content_rect(Vector2(1280, 800), 80.0, {"up": true, "down": true}), top_bottom))
	check("cardinales north/south",
		_eq(S.content_rect(Vector2(1280, 800), 80.0, ["north", "south"]), top_bottom))
	check("lado en False no se reserva",
		_eq(S.content_rect(Vector2(1280, 800), 80.0, {"top": false, "left": false}), Rect2(0, 0, 1280, 800)))

	# Viewport como Rect2: se conserva el origen y se recorta el tamaño.
	var in_rect = S.content_rect(Rect2(10, 20, 1000, 600), 50.0, {"top": true, "left": true})
	check("Rect2 conserva el origen", _eq(in_rect, Rect2(60, 70, 950, 550)))

	# Viewport más chico que dos bloques: nunca tamaño negativo.
	var tiny = S.content_rect(Vector2(100, 90), 80.0, {"top": true, "bottom": true, "left": true, "right": true})
	check("viewport chico -> sin negativos", tiny.size.x >= 0.0 and tiny.size.y >= 0.0)
	check("viewport chico recorta a cero", tiny.size == Vector2.ZERO)

	# Determinismo/pureza.
	var again = S.content_rect(Vector2(1280, 800), 80.0, {"top": true, "bottom": true})
	check("determinista", _eq(top_bottom, again))

	# clamp_inside: un diálogo chico que cabe se recorta a los bordes del hueco.
	var cr = all4
	var fits = S.clamp_inside(cr, Vector2(-500, -500), Vector2(300, 200))
	check("diálogo que cabe se pega arriba-izquierda", fits == cr.position)
	var inside = S.clamp_inside(cr, Vector2(200, 300), Vector2(300, 200))
	check("diálogo dentro no se mueve", inside == Vector2(200, 300))
	var low = S.clamp_inside(cr, Vector2(5000, 5000), Vector2(300, 200))
	check("diálogo fuera se recorta al borde inferior-derecho",
		low == cr.end - Vector2(300, 200))

	# Un diálogo más grande que el hueco no se puede centrar: se ancla arriba-izquierda
	# (después la capa recortada lo limita, no invade el Frame).
	var big = S.clamp_inside(cr, Vector2(0, 0), Vector2(2000, 2000))
	check("diálogo más grande que el hueco se ancla al origen", big == cr.position)

	# El centrado de un diálogo razonable cae dentro del hueco y no toca las barras.
	var dlg = Vector2(400, 300)
	var centered = (cr.position + cr.size * 0.5 - dlg * 0.5)
	var placed = S.clamp_inside(cr, centered, dlg)
	check("centrado queda dentro del hueco", placed.x >= cr.position.x and placed.y >= cr.position.y
		and placed.x + dlg.x <= cr.end.x and placed.y + dlg.y <= cr.end.y)

	# Vocabulario: la salida es geométrica, sin nombres internos.
	check("sin cadenas visibles", typeof(S.content_rect(Vector2(1280, 800), 80.0, {"top": true})) == TYPE_RECT2)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
