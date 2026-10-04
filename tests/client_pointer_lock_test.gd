extends SceneTree

# Prueba pura del pointer lock de un cliente alojado y del cursor oculto
# (client_pointer_locked / client_cursor_hidden). Extrae las funciones reales de
# shell.gd y las corre contra dobles de Input/compositor, sin sesión gráfica.
#   <binario dev> --no-window --path shell -s $PWD/tests/client_pointer_lock_test.gd
var failed = 0

class InputProbe:
	extends Reference
	const MOUSE_MODE_VISIBLE = 0
	const MOUSE_MODE_HIDDEN = 1
	const MOUSE_MODE_CAPTURED = 2
	var mode = 0
	var changes = []
	func get_mouse_mode():
		return mode
	func set_mouse_mode(value):
		mode = value
		changes.append(value)

class TreeProbe:
	extends Reference
	var handled = 0
	func set_input_as_handled():
		handled += 1

class CursorProbe:
	extends Reference
	var visible = false

class CompositorProbe:
	extends Reference
	var rel = []
	var buttons = []
	func has_method(name):
		return name == "pointer_motion_relative" or name == "pointer_has_focus"
	func pointer_motion_relative(delta):
		rel.append(delta)
	func pointer_button(button, pressed):
		buttons.append([button, pressed])
	func pointer_has_focus():
		return true

func check(label, ok):
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		failed += 1

func _function(source, name):
	var start = source.find("func " + name + "(")
	if start < 0:
		return ""
	var end = source.find("\nfunc ", start + 1)
	return source.substr(start, end - start if end >= 0 else source.length() - start)

func _init():
	var f = File.new()
	if f.open("res://shell.gd", File.READ) != OK:
		check("leer shell.gd", false)
		OS.exit_code = 1
		quit()
		return
	var source = f.get_as_text()
	f.close()
	var harness = "extends Reference\n"
	harness += "const SCROLL_GESTURE = preload(\"res://scroll_gesture.gd\")\n"
	harness += "var compositor\nvar eis_cursor\nvar mouse_locked = false\n"
	harness += "var client_pointer_locked = false\nvar client_cursor_hidden = false\n"
	harness += "var _ptr_log_samples = 0\nvar last_activity = 0\nvar focused_tile = -1\n"
	harness += "var input_enabled = true\nvar input_probe\nvar tree_probe\nvar redraws = 0\n"
	harness += "func get_tree():\n\treturn tree_probe\nfunc request_redraw():\n\tredraws += 1\n"
	harness += "func set_process_input(value):\n\tinput_enabled = value\n"
	harness += "func _set_capture_cursor(_active):\n\tpass\nfunc _reset_cursor(_pos = null):\n\tpass\n"
	harness += "func _focus_tile(_id):\n\tpass\nfunc _id_alive(_id):\n\treturn true\n"
	harness += "func _forward_pan(_event):\n\tpass\n"  # scroll de dedos: fuera de este test
	for name in ["_on_client_pointer_lock", "_on_client_cursor_hidden", "_set_client_pointer_lock",
			"_apply_client_cursor_state", "_forward_client_pointer", "_ptr_log_motion"]:
		harness += "\n" + _function(source, name)
	harness = harness.replace("RemoteInput.DEVICE_ID", "69").replace("Input.", "input_probe.")
	var script = GDScript.new()
	script.set_source_code(harness)
	var err = script.reload()
	check("funciones reales del pointer lock compilan", err == OK)
	if err != OK:
		OS.exit_code = 1
		quit()
		return
	var shell = script.new()
	shell.input_probe = InputProbe.new()
	shell.tree_probe = TreeProbe.new()
	shell.eis_cursor = CursorProbe.new()
	shell.compositor = CompositorProbe.new()

	var motion = InputEventMouseMotion.new()
	motion.relative = Vector2(-5, 3)
	check("motion sin lock no se reenvía", not shell._forward_client_pointer(motion))
	shell._set_client_pointer_lock(true)
	check("lock enciende el flag", shell.client_pointer_locked)
	check("lock captura el mouse de Godot", shell.input_probe.mode == 2)
	check("lock apaga el _input del canvas", not shell.input_enabled)
	check("motion con lock se reenvía con el relativo", shell._forward_client_pointer(motion))
	check("relativo llega entero al compositor", shell.compositor.rel == [Vector2(-5, 3)])
	check("el motion se marca como manejado", shell.tree_probe.handled == 1)
	check("el log acumuló la muestra", shell._ptr_log_samples == 1)
	var button = InputEventMouseButton.new()
	button.button_index = BUTTON_LEFT
	button.pressed = true
	check("botón con lock se reenvía", shell._forward_client_pointer(button))
	check("botón llega al compositor", shell.compositor.buttons == [[BUTTON_LEFT, true]])

	shell._on_client_cursor_hidden(true)
	check("cursor oculto del cliente se registra", shell.client_cursor_hidden)
	check("cursor oculto no cambia el modo estando lockeado", shell.input_probe.mode == 2)
	shell._set_client_pointer_lock(false)
	check("al soltar se devuelve el input al canvas", shell.input_enabled)
	check("el cursor queda oculto si el cliente lo pidió", shell.input_probe.mode == 1)
	shell._on_client_cursor_hidden(false)
	check("cuando el cliente manda surface vuelve visible", shell.input_probe.mode == 0)
	var before = shell.input_probe.changes.size()
	shell._on_client_cursor_hidden(false)
	check("sin transición no cambia el modo", shell.input_probe.changes.size() == before)
	OS.exit_code = 1 if failed > 0 else 0
	quit()
