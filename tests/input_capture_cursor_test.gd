extends SceneTree

# Prueba las funciones del shell con dobles de Input/RemoteInput, sin arrancar
# compositor, Deskflow ni aplicaciones. No toca la sesión gráfica.
var failed = 0

class InputProbe:
	extends Reference
	const MOUSE_MODE_VISIBLE = 0
	const MOUSE_MODE_CAPTURED = 2
	var mode = 0
	var changes = []
	func warp_mouse_position(_pos):
		pass
	func get_mouse_mode():
		return mode
	func set_mouse_mode(value):
		mode = value
		changes.append(value)

class CaptureProbe:
	extends Reference
	var active = false
	var calls = 0
	func is_capturing():
		return active
	func capture_motion(_pos, _rel, _now):
		calls += 1
		return active
	func capture_scroll(_dx, _dy, _now):
		calls += 1
		return active

class TreeProbe:
	extends Reference
	var handled = 0
	func set_input_as_handled():
		handled += 1

class CursorProbe:
	extends Reference
	var visible = true
	var position = Vector2.ZERO

class CompositorProbe:
	extends Reference
	var leaves = 0
	var enabled = true
	func pointer_clear_focus():
		leaves += 1
	func set_local_pointer_enabled(value):
		enabled = value

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
	var harness = "extends Reference\nvar remote_input\nvar eis_cursor\nvar compositor\nvar mouse_locked = false\nvar client_pointer_locked = false\nvar client_cursor_hidden = false\nvar expose = false\nvar chrome_drag = null\nvar _capture_drag_held = false\nvar debug_input = false\nvar input_enabled = true\nvar input_probe\nvar tree_probe\nvar redraws = 0\nfunc get_tree():\n\treturn tree_probe\nfunc request_redraw():\n\tredraws += 1\nfunc set_process_input(value):\n\tinput_enabled = value\nfunc _apply_client_cursor_state():\n\tpass\n"
	for name in ["_set_capture_cursor", "_sync_capture_cursor", "_capture_remote_input_event", "_move_eis_cursor"]:
		harness += "\n" + _function(source, name)
	harness = harness.replace("RemoteInput.DEVICE_ID", "69").replace("Input.", "input_probe.")
	var script = GDScript.new()
	script.set_source_code(harness)
	var err = script.reload()
	check("funciones reales del shell compilan", err == OK)
	if err != OK:
		OS.exit_code = 1
		quit()
		return
	var shell = script.new()
	shell.input_probe = InputProbe.new()
	shell.tree_probe = TreeProbe.new()
	shell.eis_cursor = CursorProbe.new()
	shell.compositor = CompositorProbe.new()
	shell.remote_input = CaptureProbe.new()
	var motion = InputEventMouseMotion.new()
	motion.relative = Vector2(-5, 0)
	check("motion local sin captura pasa al shell", not shell._capture_remote_input_event(motion))
	check("reposo no cambia el modo del mouse", shell.input_probe.changes.empty())
	shell.remote_input.active = true
	check("cruce consume el motion", shell._capture_remote_input_event(motion))
	check("cruce bloquea y oculta el cursor auxiliar", shell.mouse_locked and shell.input_probe.mode == 2 and not shell.eis_cursor.visible)
	check("cruce manda leave al cliente local", shell.compositor.leaves == 1)
	check("cruce inhibe el puntero local en el compositor", not shell.compositor.enabled)
	check("cruce apaga input directo de ImGui", not shell.input_enabled)
	check("ocultar pide redibujar", shell.redraws == 1)
	var gesture = InputEventPanGesture.new()
	gesture.delta = Vector2(0, 1)
	check("gesto durante captura no llega al escritorio", shell._capture_remote_input_event(gesture))
	check("gesto no suelta el lock", shell.mouse_locked and shell.input_probe.mode == 2 and shell.input_probe.changes.size() == 1)
	check("captura sostenida no repite leave", shell.compositor.leaves == 1)
	var touch = InputEventScreenTouch.new()
	check("touch durante captura tampoco suelta el lock", shell._capture_remote_input_event(touch) and shell.mouse_locked)
	motion.device = 69
	var before = shell.remote_input.calls
	check("input EIS no vuelve a Deskflow", not shell._capture_remote_input_event(motion) and shell.remote_input.calls == before)
	shell._move_eis_cursor(motion)
	check("input EIS durante captura no revive cursor auxiliar", not shell.eis_cursor.visible)
	shell.remote_input.active = false
	shell._sync_capture_cursor()
	check("Release sin input físico devuelve el cursor", not shell.mouse_locked and shell.input_probe.mode == 0)
	check("Release rehabilita el puntero local", shell.compositor.enabled)
	check("Release rehabilita input de ImGui", shell.input_enabled)
	check("Release cambia el modo una sola vez", shell.input_probe.changes.size() == 2)
	shell._sync_capture_cursor()
	check("sondeo sin transición no cambia modo", shell.input_probe.changes.size() == 2)
	shell.remote_input.active = true
	shell.mouse_locked = false
	shell._sync_capture_cursor()
	check("recarga adopta captura del Host persistente", shell.mouse_locked and shell.input_probe.mode == 2)
	shell.remote_input.active = false
	shell.mouse_locked = false
	shell._sync_capture_cursor()
	check("recarga limpia lock que quedó en Input", shell.input_probe.mode == 0)
	shell.eis_cursor.visible = true
	motion.device = 0
	shell._move_eis_cursor(motion)
	check("motion físico borra cursor auxiliar previo", not shell.eis_cursor.visible)
	OS.exit_code = 1 if failed > 0 else 0
	quit()
