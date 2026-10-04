extends SceneTree

# Pruebas PURAS de la grilla regular de la barra del Frame (requisito A) y del plan
# de teselas del DockApp de ventanas (requisito B). No instancia shell/frame.
# Correr:
#   /home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk \
#     --no-window --path shell -s $PWD/tests/frame_grid_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


# Mismo cálculo que shell.frame_bar_h para un vp dado (sin instanciar el shell).
func _bar_h(w, h, scale):
	var u = max(80.0, floor(min(float(w), float(h)) / 10.0)) * scale
	if float(h) >= 3.0 * u:
		return ceil(u)
	return max(64.0, floor(u * 0.5))


func _init():
	var F = load("res://frame.gd")
	check("frame.gd carga", F != null)
	if F == null:
		OS.exit_code = 1
		quit()
		return

	# --- Requisito A: grilla regular ---------------------------------------------
	# La pantalla se divide en n celdas de paso entero `pitch`; el sobrante va a un
	# margen simétrico. n*pitch + 2*margin == vp_w exacto, margin < n y el bloque
	# cuadrado queda entre 0.7x y 1.4x del lado objetivo.
	var cases = [[1280, 720], [1366, 768], [1440, 900], [1920, 1080],
		[2160, 1440], [2560, 1440], [3840, 2160]]
	var scales = [0.5, 1.0, 2.0]
	for c in cases:
		for sc in scales:
			var w = c[0]
			var target = _bar_h(c[0], c[1], sc)
			var g = F.bar_grid(w, target, 0.0)
			var tag = "%dx%d sc %.1f" % [c[0], c[1], sc]
			check("grilla exacta " + tag, int(g.n) * int(g.pitch) + 2 * int(g.margin) == w)
			check("margin < n " + tag, int(g.margin) < int(g.n))
			check("n >= MIN_CELLS " + tag, int(g.n) >= int(F.MIN_CELLS))
			check("pitch entero > 0 " + tag, int(g.pitch) >= 1)
			check("side razonable " + tag,
				float(g.side) >= 0.7 * target and float(g.side) <= 1.4 * target)
			check("ultima celda al borde " + tag,
				int(g.margin) + int(g.n) * int(g.pitch) == w - int(g.margin))
	# PAD > 0: el lado del bloque es pitch - pad.
	var gp = F.bar_grid(1920, 108, 4.0)
	check("side = pitch - pad", abs(float(gp.side) - (float(gp.pitch) - 4.0)) < 0.001)
	# Pantalla chica: nunca baja de MIN_CELLS.
	check("ancho minimo respeta MIN_CELLS", int(F.bar_grid(500, 80, 0.0).n) >= int(F.MIN_CELLS))
	# Ambas barras comparten grilla (misma n y pitch para distinto rol).
	check("bar_fixed_cells top = 3 / dock = 1",
		F.bar_fixed_cells("top") == 3 and F.bar_fixed_cells("dock") == 1)

	# --- Requisito B: plan del DockApp de ventanas -------------------------------
	# Modo normal: n <= F.
	var p = F.window_plan(3, 5, -1, 0)
	check("plan normal: mode", p.mode == "normal")
	check("plan normal: per_cell 1", int(p.per_cell) == 1)
	check("plan normal: rango", p.visible_range == [0, 3])
	check("plan normal: sin scroll", int(p.scroll_max) == 0)

	# Borde: n == F sigue normal; n == F+1 pasa a mini.
	check("plan n==F normal", F.window_plan(5, 5, -1, 0).mode == "normal")
	check("plan n==F+1 mini", F.window_plan(6, 5, -1, 0).mode == "mini")

	# Modo mini: F < n <= 4F (hasta 4 por celda).
	p = F.window_plan(10, 4, -1, 0)
	check("plan mini: mode", p.mode == "mini")
	check("plan mini: per_cell 4", int(p.per_cell) == 4)
	check("plan mini: rango completo", p.visible_range == [0, 10])
	check("plan mini: sin scroll", int(p.scroll_max) == 0)
	check("plan capacidad exacta 4F = mini", F.window_plan(16, 4, -1, 0).mode == "mini")

	# Modo scroll: n > 4F.
	p = F.window_plan(20, 4, -1, 0)
	check("plan scroll: mode", p.mode == "scroll")
	check("plan scroll: per_cell 4", int(p.per_cell) == 4)
	check("plan scroll: scroll_max", int(p.scroll_max) == 4)
	check("plan scroll: rango inicial", p.visible_range == [0, 16])

	# Clamp del scroll pedido.
	p = F.window_plan(20, 4, -1, 99)
	check("plan scroll: clamp al maximo", p.visible_range == [4, 20])
	p = F.window_plan(20, 4, -1, -5)
	check("plan scroll: clamp negativo", p.visible_range == [0, 16])

	# Auto-scroll: la ventana enfocada siempre visible.
	p = F.window_plan(20, 4, 18, 0)
	check("plan scroll: foco a la derecha se hace visible", p.visible_range == [3, 19])
	p = F.window_plan(20, 4, 2, 10)
	check("plan scroll: foco a la izquierda se hace visible", p.visible_range == [2, 18])

	# F mínimo 1 (tramo de una sola celda): capacidad 4.
	p = F.window_plan(5, 0, -1, 0)
	check("plan F=1: scroll", p.mode == "scroll" and int(p.scroll_max) == 1)
	check("plan F=1: rango", p.visible_range == [0, 4])

	# Sin ventanas: plan trivial.
	p = F.window_plan(0, 6, -1, 0)
	check("plan sin ventanas: normal y rango vacio",
		p.mode == "normal" and p.visible_range == [0, 0])

	print("FRAME_GRID_TEST_" + ("OK" if failed == 0 else "FAIL"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
