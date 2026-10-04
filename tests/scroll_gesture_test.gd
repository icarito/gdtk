extends SceneTree

# Prueba pura del mapeo rueda/gesto -> eje del compositor anidado
# (shell/scroll_gesture.gd). No toca la sesión gráfica ni el compositor.
#   godot --no-window --path shell -s $PWD/tests/scroll_gesture_test.gd
#
# Firma: positivo = derecha/abajo (mismo contrato que BUTTON_WHEEL_*).

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var S = load("res://scroll_gesture.gd")
	check("scroll_gesture.gd carga", S != null)
	if S == null:
		OS.exit_code = 1
		quit()
		return

	# Rueda vertical.
	check("WHEEL_UP -> axis arriba", (S.wheel_axis(BUTTON_WHEEL_UP) as Vector2) == Vector2(0.0, -S.WHEEL_STEP))
	check("WHEEL_DOWN -> axis abajo", (S.wheel_axis(BUTTON_WHEEL_DOWN) as Vector2) == Vector2(0.0, S.WHEEL_STEP))
	# Rueda horizontal (dos dedos).
	check("WHEEL_LEFT -> axis izquierda", (S.wheel_axis(BUTTON_WHEEL_LEFT) as Vector2) == Vector2(-S.WHEEL_STEP, 0.0))
	check("WHEEL_RIGHT -> axis derecha", (S.wheel_axis(BUTTON_WHEEL_RIGHT) as Vector2) == Vector2(S.WHEEL_STEP, 0.0))
	# Botón que no es rueda no genera eje.
	check("boton no-rueda -> cero", (S.wheel_axis(BUTTON_LEFT) as Vector2) == Vector2.ZERO)

	# Pan continuo: se escala linealmente y conserva signo por eje.
	var pan = S.pan_axis(Vector2(0.5, -0.25))
	check("pan (0.5,-0.25) -> (5,-2.5)", pan == Vector2(5.0, -2.5))
	check("pan cero -> cero", S.pan_axis(Vector2.ZERO) == Vector2.ZERO)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
