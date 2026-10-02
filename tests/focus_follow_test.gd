extends SceneTree

# Autoprueba del modelo puro de "lazy focus follows mouse" (Feature Tiles): la
# política decide a quién enfocar cuando el puntero se mueve sobre la vista.
# No renderiza, no toca el compositor ni el disco. Correr:
#   godot --no-window --path shell -s $PWD/tests/focus_follow_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var FF = load("res://focus_follow.gd")

	# Sin ventana bajo el puntero: nunca cambia el foco.
	var none = FF.decide(7, 0, -1)
	check("sin hit no enfoca", int(none.target) < 0)

	# Pasar el mouse sobre la ventana ya enfocada no reenfoca nada.
	var same = FF.decide(7, 0, 7)
	check("misma ventana no reenfoca", int(same.target) < 0)

	# Otra ventana: el foco la sigue.
	var other = FF.decide(7, 0, 9)
	check("otra ventana toma el foco", int(other.target) == 9)
	check("ventana no marca diálogo", int(other.dialog) == 0)

	# Una minimizada no se restaura por pasar el mouse.
	var mini = FF.decide(7, 0, 9, 0, true)
	check("minimizada no se restaura al pasar", int(mini.target) < 0)

	# Un diálogo transitorio bajo el puntero toma el foco aunque el tile de fondo
	# sea el ya enfocado.
	var dlg = FF.decide(7, 0, 31, 31)
	check("diálogo toma el foco", int(dlg.target) == 31 and int(dlg.dialog) == 31)

	# El diálogo ya enfocado no se reenfoca solo.
	var dlg_same = FF.decide(7, 31, 31, 31)
	check("diálogo ya enfocado no reenfoca", int(dlg_same.target) < 0)

	# Salir del diálogo de vuelta a su tile raíz limpia el estado de diálogo.
	var dlg_out = FF.decide(7, 31, 7, 0)
	check("volver al tile raíz cierra el diálogo",
		int(dlg_out.target) == 7 and int(dlg_out.dialog) == 0)

	# Desde un diálogo, moverse a una ventana normal devuelve el foco al tile.
	var back = FF.decide(7, 31, 9, 0)
	check("de diálogo a ventana vuelve al tile", int(back.target) == 9 and int(back.dialog) == 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
