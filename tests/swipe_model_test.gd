extends SceneTree

# Autoprueba W5a del modelo puro del gesto continuo de 3 dedos (swipe_model.gd):
# bloqueo de eje, progress sin clamp, velocidad por ventana reciente y snap/fling
# al soltar. No renderiza ni toca disco.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/swipe_model_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _approx(a, b, eps = 0.0001):
	return abs(float(a) - float(b)) <= eps


func _init():
	var SM = load("res://swipe_model.gd")

	# --- begin / active / reset ---------------------------------------------
	var g = SM.new()
	check("inicial inactivo", not g.active)
	g.begin(3, 0)
	check("begin activa y guarda dedos", g.active and g.fingers == 3)
	check("begin sin eje", g.axis == "")

	# --- eje no se bloquea bajo 12 px ---------------------------------------
	g.update(Vector2(5.0, 4.0), 20)
	g.update(Vector2(6.0, 0.0), 40)
	check("no bloquea con 11 px (< LOCK_PX)", g.axis == "")
	check("sin eje progress es 0", _approx(g.progress(100.0), 0.0))

	# --- bloquea x con movimiento horizontal y luego ignora y ---------------
	g.reset()
	g.begin(3, 0)
	g.update(Vector2(20.0, 0.0), 20)
	check("bloquea x con 20 px horizontal", g.axis == "x")
	g.update(Vector2(0.0, 40.0), 40)
	check("axis x se mantiene pese a y", g.axis == "x")
	check("ignora y: progress sólo del eje x",
		_approx(g.progress(100.0), 20.0 / (100.0 * 0.6)))
	check("progress positivo = derecha/abajo", g.progress(100.0) > 0.0)

	# --- progress sin clamp --------------------------------------------------
	g.reset()
	g.begin(3, 0)
	g.update(Vector2(120.0, 0.0), 500)
	check("progress > 1 sin clamp", _approx(g.progress(100.0), 2.0))

	# --- arrastre lento 70% -> step +1 --------------------------------------
	g.reset()
	g.begin(3, 0)
	g.update(Vector2(42.0, 0.0), 500)
	var r_slow = g.end(false, 500, 100.0)
	check("lento 70%: axis x", r_slow.axis == "x")
	check("lento 70%: progress ~0.7", _approx(r_slow.progress, 0.7))
	check("lento 70%: sin fling (v < 0.4)", abs(r_slow.velocity) <= 0.4)
	check("lento 70%: step +1", r_slow.step == 1)

	# --- arrastre lento 30% -> 0 --------------------------------------------
	g.reset()
	g.begin(3, 0)
	g.update(Vector2(18.0, 0.0), 500)
	var r_short = g.end(false, 500, 100.0)
	check("lento 30%: progress ~0.3", _approx(r_short.progress, 0.3))
	check("lento 30%: step 0", r_short.step == 0)

	# --- fling corto rápido -> step con signo del fling ---------------------
	g.reset()
	g.begin(3, 0)
	g.update(Vector2(30.0, 0.0), 20)
	var r_fling = g.end(false, 20, 1000.0)
	check("fling +: progress corto (< 0.5)", abs(r_fling.progress) < 0.5)
	check("fling +: velocidad > FLING", r_fling.velocity > 0.4)
	check("fling +: step +1", r_fling.step == 1)

	g.reset()
	g.begin(3, 0)
	g.update(Vector2(-30.0, 0.0), 20)
	var r_fling_neg = g.end(false, 20, 1000.0)
	check("fling -: velocidad < -FLING", r_fling_neg.velocity < -0.4)
	check("fling -: step -1", r_fling_neg.step == -1)

	# --- ventana de velocidad: sólo lo reciente cuenta ----------------------
	g.reset()
	g.begin(3, 0)
	g.update(Vector2(100.0, 0.0), 50)
	g.update(Vector2(0.0, 0.0), 100)
	g.update(Vector2(-100.0, 0.0), 150)
	var r_win = g.end(false, 160, 1000.0)
	check("ventana 100ms ignora muestra vieja", r_win.velocity < -0.4)
	check("ventana: step sigue el fling reciente", r_win.step == -1)

	# --- cancelled -> 0 ------------------------------------------------------
	g.reset()
	g.begin(3, 0)
	g.update(Vector2(45.0, 0.0), 20)
	var r_cancel = g.end(true, 20, 100.0)
	check("cancelled: axis x igual", r_cancel.axis == "x")
	check("cancelled: step 0", r_cancel.step == 0)

	# --- vertical hacia arriba 60% -> axis y, step -1 -----------------------
	g.reset()
	g.begin(3, 0)
	g.update(Vector2(0.0, -36.0), 500)
	var r_up = g.end(false, 500, 100.0)
	check("vertical: axis y", r_up.axis == "y")
	check("vertical arriba: progress ~-0.6", _approx(r_up.progress, -0.6))
	check("vertical arriba: step -1", r_up.step == -1)

	# --- end usa el último size de progress() si no se pasa ----------------
	g.reset()
	g.begin(3, 0)
	g.update(Vector2(42.0, 0.0), 500)
	g.progress(100.0)
	var r_stored = g.end(false, 500)
	check("end reutiliza size guardado en progress()",
		_approx(r_stored.progress, 0.7) and r_stored.step == 1)

	# --- reset ---------------------------------------------------------------
	g.reset()
	check("reset: inactivo, sin eje y sin dedos",
		not g.active and g.axis == "" and g.fingers == 0)
	var r_empty = g.end(false, 0, 100.0)
	check("end sin eje: step 0", r_empty.axis == "" and r_empty.step == 0)

	# Cadena vertical de vistas.
	var lv = SM.vertical_levels(true)
	check("cadena con ventanas", lv == [-2, -1, 0, 1, 2, 3])
	check("cadena sin ventanas salta pantalla/exposé", SM.vertical_levels(false) == [-2, -1, 2, 3])
	check("pantalla + 0.4 arriba sigue en pantalla", SM.vertical_target(lv, 0, -0.4, 0) == 0)
	check("pantalla + 0.6 arriba -> exposé", SM.vertical_target(lv, 0, -0.6, -1) == 1)
	check("pantalla + 1.6 arriba -> Hogar", SM.vertical_target(lv, 0, -1.6, -1) == 2)
	check("pantalla + 9 arriba -> Apps (tope)", SM.vertical_target(lv, 0, -9.0, -1) == 3)
	check("pantalla abajo -> Grupo", SM.vertical_target(lv, 0, 0.7, 1) == -1)
	check("pantalla mucho abajo -> Vecindario", SM.vertical_target(lv, 0, 1.6, 1) == -2)
	check("fling corto arriba avanza uno", SM.vertical_target(lv, 0, -0.2, -1) == 1)
	check("Hogar abajo sin ventanas -> Grupo", SM.vertical_target([-2, -1, 2, 3], 2, 0.6, 1) == -1)
	check("pos continua del tramo pantalla-exposé", abs(SM.vertical_pos(lv, 0, -0.3) - 2.3) < 0.001)
	OS.exit_code = 1 if failed > 0 else 0
	quit()
