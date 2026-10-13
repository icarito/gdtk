extends SceneTree

# Autoprueba del texto del multiplicador de velocidad del puntero (deskflow_mouse.gd):
#   "$BIN" --no-window --path shell -s $PWD/tests/deskflow_mouse_test.gd

var failed = 0


func check(name, cond):
	if cond:
		print("ok   " + name)
	else:
		failed += 1
		print("FAIL " + name)


func _init():
	var M = load("res://deskflow_mouse.gd")
	check("1.0 = 1.0", M.adjust_text(1.0) == "1.0")
	check("1.5 = 1.5", M.adjust_text(1.5) == "1.5")
	check("clampa bajo", M.adjust_text(0.01) == "0.1")
	check("clampa alto", M.adjust_text(99.0) == "10.0")
	check("texto numerico", M.adjust_text("2.5") == "2.5")
	check("texto entero lleva .0", M.adjust_text("2") == "2.0")
	check("basura cae al clamp bajo", M.adjust_text("x") == "0.1")
	OS.exit_code = 1 if failed > 0 else 0
	quit()
