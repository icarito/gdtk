extends SceneTree

# Chequeo de PARSEO con el binario instalado (trae clases nativas): carga cada
# script crítico y reporta si compila. Ruido conocido de RemoteInput/host.gd no
# es falla si el script carga.
#   ~/gdtk/bin/godot-gdtk --no-window --path shell -s <este archivo>

func _init():
	var paths = [
		"res://wm_units.gd", "res://wm_hybrid.gd", "res://wm_drag.gd",
		"res://float_layout.gd", "res://window_chrome.gd", "res://window_deco.gd",
		"res://tiles_ui.gd", "res://frame.gd", "res://remote.gd", "res://shell.gd",
		"res://system_osd.gd", "res://expose_bg.gd", "res://applet_clipboard.gd",
		"res://audio_send.gd", "res://window_cast.gd", "res://peer_control.gd",
	]
	var failed = 0
	for p in paths:
		var s = load(p)
		var ok = s != null
		print(("ok   " if ok else "FAIL ") + p)
		if not ok:
			failed += 1
	OS.exit_code = 1 if failed > 0 else 0
	quit()
