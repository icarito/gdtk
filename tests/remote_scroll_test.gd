extends SceneTree

# Prueba el generador de eventos de entrada del RPC del shell (shell/remote.gd):
# scroll vertical, scroll HORIZONTAL de dos dedos (dx -> BUTTON_WHEEL_LEFT/RIGHT) y
# la tecla Delete. Es puro: no abre el servidor, no toca la sesión gráfica.
#   godot --no-window --path shell -s $PWD/tests/remote_scroll_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _pressed_buttons(queue):
	var out = []
	for ev in queue:
		if ev is InputEventMouseButton and ev.pressed:
			out.append(ev.button_index)
	return out


func _pressed_key(queue):
	for ev in queue:
		if ev is InputEventKey and ev.pressed:
			return ev
	return null


func _init():
	var Remote = load("res://remote.gd")
	check("remote.gd carga", Remote != null)
	if Remote == null:
		OS.exit_code = 1
		quit()
		return
	var r = Remote.new()

	# Vertical: dy > 0 baja, dy < 0 sube (contrato existente).
	r._scroll({"x": 10.0, "y": 20.0, "dy": 2.0})
	check("dy>0 -> dos pasos rueda abajo", _pressed_buttons(r.event_queue) == [BUTTON_WHEEL_DOWN, BUTTON_WHEEL_DOWN])
	r.event_queue = []
	r._scroll({"x": 10.0, "y": 20.0, "dy": -1.0})
	check("dy<0 -> un paso rueda arriba", _pressed_buttons(r.event_queue) == [BUTTON_WHEEL_UP])

	# Horizontal: dx -> BUTTON_WHEEL_RIGHT/LEFT (axis horizontal del compositor).
	r.event_queue = []
	r._scroll({"x": 10.0, "y": 20.0, "dx": 3.0})
	check("dx>0 -> rueda derecha", _pressed_buttons(r.event_queue) == [BUTTON_WHEEL_RIGHT, BUTTON_WHEEL_RIGHT, BUTTON_WHEEL_RIGHT])
	r.event_queue = []
	r._scroll({"x": 10.0, "y": 20.0, "dx": -1.0})
	check("dx<0 -> rueda izquierda", _pressed_buttons(r.event_queue) == [BUTTON_WHEEL_LEFT])

	# Los dos ejes a la vez emiten vertical y después horizontal.
	r.event_queue = []
	r._scroll({"x": 0.0, "y": 0.0, "dy": 1.0, "dx": 1.0})
	check("dy+dx -> vertical y horizontal", _pressed_buttons(r.event_queue) == [BUTTON_WHEEL_DOWN, BUTTON_WHEEL_RIGHT])

	# Sin ejes se conserva el contrato viejo (un paso vertical).
	r.event_queue = []
	r._scroll({"x": 0.0, "y": 0.0})
	check("sin dy/dx -> un paso vertical (compat)", _pressed_buttons(r.event_queue) == [BUTTON_WHEEL_DOWN])

	# Delete: el RPC debe emitir KEY_DELETE con physical_scancode real (el compositor
	# lo traduce a evdev 111; ver wayland_compositor.cpp _scancode_to_evdev).
	r.event_queue = []
	r._key({"combo": "Delete"})
	var key = _pressed_key(r.event_queue)
	check("combo Delete emite KEY_DELETE", key != null and int(key.scancode) == KEY_DELETE \
		and int(key.physical_scancode) == KEY_DELETE)

	r.free()
	OS.exit_code = 1 if failed > 0 else 0
	quit()
