extends SceneTree

# K13b — Autoprueba del chrome WindowMaker (barra de título, botones, bordes).
# Sólo geometría pura; sin render ni I/O.
#   godot --no-window --path shell -s $PWD/tests/window_chrome_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _eq(a, b):
	return abs(a.position.x - b.position.x) < 0.001 and abs(a.position.y - b.position.y) < 0.001 \
		and abs(a.size.x - b.size.x) < 0.001 and abs(a.size.y - b.size.y) < 0.001


func _init():
	var C = load("res://window_chrome.gd")
	check("window_chrome.gd carga", C != null)
	check("selftest() del modelo", C.selftest())

	var fr = Rect2(100, 200, 400, 300)
	var p = C.parts(fr)
	check("marco = rect exterior", _eq(p.frame, fr))
	check("barra centrada arriba", p.title.position == Vector2(102, 202) and p.title.size == Vector2(396, 20))
	check("contenido debajo de la barra",
		p.content.position == Vector2(102, 222) and p.content.size == Vector2(396, 276))
	check("content_rect == parts.content", _eq(C.content_rect(fr), p.content))
	check("min a la izquierda", p.min_btn.position.x < fr.position.x + 40.0)
	check("close a la derecha", p.close_btn.end.x > fr.end.x - 40.0)

	check("hit min", C.hit(p.min_btn.position + Vector2(2, 2), fr) == "min")
	check("hit close", C.hit(p.close_btn.position + Vector2(2, 2), fr) == "close")
	check("hit título", C.hit(Vector2(300, 210), fr) == "title")
	check("hit contenido", C.hit(Vector2(300, 300), fr) == "content")
	check("hit fuera", C.hit(Vector2(0, 0), fr) == "")
	check("hit borde/esquina", C.hit(Vector2(101, 201), fr) == "tl"
		and C.hit(Vector2(499, 499), fr) == "br"
		and C.hit(Vector2(499, 300), fr) == "right"
		and C.hit(Vector2(300, 201), fr) == "top")
	check("is_edge", C.is_edge("br") and C.is_edge("left") and not C.is_edge("title")
		and not C.is_edge("content") and not C.is_edge("min"))

	# Redimensión: bordes, mínimos y diagonales (no invierte el rect).
	var g = C.resized(fr, "right", Vector2(60, 0))
	check("resize derecha", _eq(g, Rect2(100, 200, 460, 300)))
	var sh = C.resized(fr, "bottom", Vector2(0, -9999))
	check("resize abajo respeta mínimo", _eq(sh, Rect2(100, 200, 400, 240)))
	var dg = C.resized(fr, "tl", Vector2(-40, -50))
	check("resize diagonal tl", _eq(dg, Rect2(60, 150, 440, 350)))

	# Marco degenerado: no rompe.
	var empty = C.parts(Rect2(0, 0, 0, 0))
	check("marco vacío no rompe", empty.content.size == Vector2.ZERO and C.hit(Vector2(1, 1), Rect2(0, 0, 0, 0)) == "")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
