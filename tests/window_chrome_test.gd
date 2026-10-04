extends SceneTree

# K13b — Autoprueba del chrome OpenStep/WindowMaker (barra de título, botones
# full-height, borde de 1 px, barra inferior y asa diagonal). Sólo geometría pura;
# sin render ni I/O.
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

	# OpenStep: borde 1 px, barra 22 px, barra inferior 8 px, botones full-height.
	check("borde 1 pt", C.BORDER == 1.0)
	check("barra superior 22", C.TITLE_H == 22.0)
	check("barra inferior 8", C.RESIZE_H == 8.0)
	check("botón cuadrado full-height", C.BTN == C.TITLE_H and C.BTN_MARGIN == 0.0)

	var fr = Rect2(100, 200, 400, 300)
	var p = C.parts(fr)
	check("marco = rect exterior", _eq(p.frame, fr))
	check("barra centrada arriba", p.title.position == Vector2(101, 201) and p.title.size == Vector2(398, 22))
	check("contenido debajo de la barra",
		p.content.position == Vector2(101, 223) and p.content.size == Vector2(398, 268))
	check("barra inferior", p.resize.position == Vector2(101, 491) and p.resize.size == Vector2(398, 8))
	check("content_rect == parts.content", _eq(C.content_rect(fr), p.content))
	check("min pegado a la esquina", p.min_btn.position == Vector2(101, 201) and p.min_btn.size == Vector2(22, 22))
	check("close pegado a la esquina derecha",
		p.close_btn.position == Vector2(477, 201) and p.close_btn.size == Vector2(22, 22))
	check("asa diagonal en la esquina inferior derecha", C.grip_rect(fr).end == Vector2(499, 499))

	check("hit min", C.hit(p.min_btn.position + Vector2(2, 2), fr) == "min")
	check("hit close", C.hit(p.close_btn.position + Vector2(2, 2), fr) == "close")
	check("hit título", C.hit(Vector2(300, 210), fr) == "title")
	check("hit contenido", C.hit(Vector2(300, 300), fr) == "content")
	check("hit fuera", C.hit(Vector2(0, 0), fr) == "")
	check("hit borde/esquina", C.hit(Vector2(101, 499), fr) == "bl"
		and C.hit(Vector2(499, 499), fr) == "br"
		and C.hit(Vector2(499, 300), fr) == "right"
		and C.hit(Vector2(300, 200), fr) == "top")
	check("hit barra inferior", C.hit(Vector2(300, 495), fr) == "bottom")
	check("is_edge", C.is_edge("br") and C.is_edge("left") and not C.is_edge("title")
		and not C.is_edge("content") and not C.is_edge("min"))
	check("zone_at esquinas", C.zone_at(Vector2(105, 205), fr, 0.3) == "tl"
		and C.zone_at(Vector2(495, 495), fr, 0.3) == "br")
	check("zone_at bordes", C.zone_at(Vector2(300, 205), fr, 0.3) == "top"
		and C.zone_at(Vector2(105, 350), fr, 0.3) == "left")

	# Redimensión: bordes, mínimos y diagonales (no invierte el rect).
	var g = C.resized(fr, "right", Vector2(60, 0))
	check("resize derecha", _eq(g, Rect2(100, 200, 460, 300)))
	var sh = C.resized(fr, "bottom", Vector2(0, -9999))
	check("resize abajo respeta mínimo", _eq(sh, Rect2(100, 200, 400, 240)))
	var dg = C.resized(fr, "tl", Vector2(-40, -50))
	check("resize diagonal tl", _eq(dg, Rect2(60, 150, 440, 350)))

	# CSD: asa de mover (pastilla encima del borde, estilo asa de fronteras) y franja inferior.
	check("pill encima del borde", _eq(C.move_grip_rect(fr, 1.0), Rect2(280, 190, 40, 10)))
	check("pill escala x2", _eq(C.move_grip_rect(fr, 2.0), Rect2(260, 180, 80, 20)))
	check("pill oculta en el borde", _eq(C.move_grip_rect(fr, 1.0, 0.0), Rect2(280, 200, 40, 10)))
	check("pill revelada", _eq(C.reveal_clip(C.move_grip_rect(fr, 1.0, 1.0), 200.0), Rect2(280, 190, 40, 10)))
	check("pill a medio salir", _eq(C.reveal_clip(C.move_grip_rect(fr, 1.0, 0.5), 200.0), Rect2(280, 195, 40, 5)))
	check("pill oculta detrás", _eq(C.reveal_clip(C.move_grip_rect(fr, 1.0, 0.0), 200.0), Rect2()))
	check("csd grip", C.csd_hit(Vector2(300, 199), fr, 1.0) == "grip")
	check("csd grip tolerancia", C.csd_hit(Vector2(300, 205), fr, 1.0) == "grip")
	check("pill desfasada 1 bloque", _eq(C.move_grip_rect(fr, 1.0, 1.0, 40.0), Rect2(140, 190, 40, 10)))
	check("grip desfasado a la izquierda", C.csd_hit(Vector2(145, 205), fr, 1.0, 40.0) == "grip")
	check("desfase no sale del marco", C.move_grip_rect(fr, 1.0, 1.0, 5000.0).position.x == 460.0)
	check("csd cuerpo es del cliente", C.csd_hit(Vector2(150, 230), fr, 1.0) == "")
	check("csd bottom", C.csd_hit(Vector2(300, 497), fr, 1.0) == "bottom")
	check("csd esquinas", C.csd_hit(Vector2(102, 497), fr, 1.0) == "bl" and C.csd_hit(Vector2(498, 497), fr, 1.0) == "br")
	check("csd hover cerca del borde superior", C.move_grip_hover(Vector2(150, 190), fr, 1.0)
		and not C.move_grip_hover(Vector2(150, 150), fr, 1.0))

	# Marco degenerado: no rompe.
	var empty = C.parts(Rect2(0, 0, 0, 0))
	check("marco vacío no rompe", empty.content.size == Vector2.ZERO and empty.resize.size == Vector2.ZERO
		and C.hit(Vector2(1, 1), Rect2(0, 0, 0, 0)) == "")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
