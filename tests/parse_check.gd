extends SceneTree

# Chequeo de PARSEO con el binario instalado (trae clases nativas): compila cada
# script crítico desde su texto con GDScript.set_source_code + reload (el mismo
# camino que Host.sc, que SÍ detecta cosas que `load()` deja pasar, p. ej. una
# variable que choca con un parámetro). Ruido conocido de RemoteInput/host.gd no
# es falla si el script compila.
#   ~/gdtk/bin/godot-gdtk --no-window --path shell -s <este archivo>

func _init():
	var paths = [
		"res://wm_units.gd", "res://wm_hybrid.gd", "res://wm_drag.gd",
		"res://float_layout.gd", "res://window_chrome.gd", "res://window_deco.gd",
		"res://tiles_ui.gd", "res://frame.gd", "res://remote.gd", "res://shell.gd",
		"res://system_osd.gd", "res://expose_bg.gd", "res://applet_clipboard.gd",
		"res://audio_send.gd", "res://window_cast.gd", "res://peer_control.gd", "res://neighborhood_ui.gd",
		"res://output_layout.gd", "res://span_layout.gd", "res://menu_style.gd",
		"res://screenshot_model.gd", "res://screenshot_ui.gd",
		"res://notify.gd", "res://applet_notif.gd", "res://notifications_panel.gd",
	]
	var failed = 0
	for p in paths:
		var f = File.new()
		var ok = false
		if f.open(p, File.READ) == OK:
			var g = GDScript.new()
			g.set_source_code(f.get_as_text())
			ok = g.reload() == OK
			f.close()
		print(("ok   " if ok else "FAIL ") + p)
		if not ok:
			failed += 1
	OS.exit_code = 1 if failed > 0 else 0
	quit()
