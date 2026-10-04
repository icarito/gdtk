extends Reference

# Conversión pura de rueda/gestos de touchpad a deltas de eje del compositor
# anidado (wayland_compositor.pointer_axis / pointer_axis_h).
#
# El eje se expresa en "pasos" (positivo = derecha / abajo), igual que el valor que
# wayland_compositor manda por cada BUTTON_WHEEL_*. La rueda llega como botones
# discretos; el pan continuo (InputEventPanGesture) se escala a pasos para que el
# cliente reciba un axis proporcional al movimiento de los dedos.
const WHEEL_STEP = 10.0
const PAN_STEP = 10.0


static func wheel_axis(button_index):
	match int(button_index):
		BUTTON_WHEEL_LEFT:
			return Vector2(-WHEEL_STEP, 0.0)
		BUTTON_WHEEL_RIGHT:
			return Vector2(WHEEL_STEP, 0.0)
		BUTTON_WHEEL_UP:
			return Vector2(0.0, -WHEEL_STEP)
		BUTTON_WHEEL_DOWN:
			return Vector2(0.0, WHEEL_STEP)
	return Vector2.ZERO


static func pan_axis(delta):
	return Vector2(delta.x, delta.y) * PAN_STEP
