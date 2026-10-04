extends SceneTree

# Modificadores pegados (Super => todo clic se vuelve Super+arrastre y la app no recibe
# clics): el receptor EIS debe soltar lo inyectado cuando Deskflow deja de emular, y el
# shell debe soltar en Godot los modificadores al cambiar el foco de teclado.
# Regresión de cableado sobre las fuentes, sin compositor.
var failed = 0

func check(name, cond):
	if cond:
		print("ok   ", name)
	else:
		failed += 1
		print("FAIL ", name)

func _read(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var t = f.get_as_text()
	f.close()
	return t

func _init():
	var eis = _read("res://../modules/wayland/eis_server.c")
	check("eis_server atiende STOP_EMULATING", eis.find("case EIS_EVENT_DEVICE_STOP_EMULATING:") >= 0
		and eis.find("s->cb.stop_emulating(ud)") >= 0)
	var ri = _read("res://../modules/wayland/remote_input.cpp")
	check("RemoteInput registra stop_emulating", ri.find("cb.stop_emulating = &RemoteInput::_cb_stop_emulating;") >= 0)
	check("stop_emulating suelta todo", ri.find("_cb_stop_emulating(void *p_ud) {") >= 0
		and ri.find("self->_release_all();") >= 0)
	var shell = _read("res://shell.gd")
	check("shell suelta modificadores al cambiar el foco",
		shell.find("NOTIFICATION_WM_FOCUS_IN") >= 0 and shell.find("func _clear_stuck_mods():") >= 0)
	check("la suelta va a Godot (Input) y a la app", shell.find("Input.parse_input_event(ev)") >= 0
		and shell.find("release_modifiers()") >= 0)
	OS.exit_code = 1 if failed > 0 else 0
	quit()
