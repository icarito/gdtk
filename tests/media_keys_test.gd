extends SceneTree

# Teclas multimedia por Deskflow: el compositor debe mapear volumen/silencio/brillo a
# evdev (el emisor las manda por InputCapture y el receptor las vuelve a teclas Godot
# para su OSD), y el RPC `media` (brillo interceptado por sway) debe pasar primero por
# la captura. Regresión de cableado sobre las fuentes, sin compositor.
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
	var comp = _read("res://../modules/wayland/wayland_compositor.cpp")
	check("leer wayland_compositor.cpp", comp != "")
	for pair in [["KEY_VOLUMEMUTE", "EVDEV_KEY_MUTE = 113"], ["KEY_VOLUMEDOWN", "EVDEV_KEY_VOLUMEDOWN = 114"],
			["KEY_VOLUMEUP", "EVDEV_KEY_VOLUMEUP = 115"], ["KEY_BRIGHTNESSDOWN", "EVDEV_KEY_BRIGHTNESSDOWN = 224"],
			["KEY_BRIGHTNESSUP", "EVDEV_KEY_BRIGHTNESSUP = 225"]]:
		check(pair[0] + " mapeada a evdev", comp.find("case " + pair[0] + ":") >= 0 and comp.find(pair[1]) >= 0)
	var ri = _read("res://../modules/wayland/remote_input.cpp")
	check("capture_key usa el mismo mapeo", ri.find("_scancode_to_evdev(p_scancode)") >= 0)
	var shell = _read("res://shell.gd")
	check("shell reenvía multimedia a la captura", shell.find("func _forward_media_to_capture(action):") >= 0)
	check("sólo con la captura activa", shell.find("if not mouse_locked or remote_input == null") >= 0)
	var remote = _read("res://remote.gd")
	check("RPC media prueba la captura antes del OSD local",
		remote.find("_forward_media_to_capture") >= 0
		and remote.find("_forward_media_to_capture") < remote.find("system_osd.rpc_action"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
