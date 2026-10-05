extends SceneTree

# Autoprueba del puente de Configuración del shell (K11a): escritura atómica,
# relectura sin bloquear (Thread + TTL) y aplicación de acento/fondo.
#   godot --no-window --path shell -s $PWD/tests/settings_bridge_test.gd
# No toca ~/.config: usa user:// y el override GDTK_SETTINGS.

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var B = load("res://settings_bridge.gd").new()
	check("modelo del puente cargado", B.model != null)
	check("config_dir bajo gdtk", B.config_dir().find("gdtk") >= 0)
	check("ruta por defecto settings.json", B.settings_path().ends_with("settings.json"))

	var argv = B.launch_argv()
	check("argv relanza el shell", argv.size() == 3 and argv[1] == "--path")
	check("argv apunta a settings/", String(argv[2]).ends_with("/settings"))
	check("argv usa el ejecutable actual", argv[0] == OS.get_executable_path())

	# Escritura atómica tmp + rename en user:// (no toca el HOME real).
	var path = "user://settings_bridge_test/settings.json"
	var err = B.write_atomic(path, "{\"accent\":\"#e8615a\"}")
	check("write_atomic sin error", err == "")
	var f = File.new()
	check("archivo escrito", f.open(path, File.READ) == OK)
	if f.is_open():
		check("contenido escrito", f.get_as_text().find("#e8615a") >= 0)
		f.close()

	# Relectura inmediata con override, sin Thread.
	OS.set_environment("GDTK_SETTINGS", path)
	var err2 = B.write_atomic(path, JSON.print({
		"accent": "#e8615a", "keyboard": "us", "locale": "en_US.UTF-8",
		"wallpaper": {"mode": "solid", "color": "#123456"}, "screens": [{"x": 0, "y": 0}],
		"span": {"enabled": true, "primary": "DP-1", "order": ["HDMI-A-1"]},
	}))
	check("write_atomic del snapshot", err2 == "")
	B.reload_now()
	check("acento aplicado", B.settings.accent == "#e8615a")
	check("color de acento", B.accent.r > 0.85 and B.accent.g < 0.45)
	check("teclado releido", B.settings.keyboard == "us")
	check("idioma releido", B.settings.locale == "en_US.UTF-8")
	check("campo de otra pagina conservado", B.settings.has("screens"))
	check("span releido", B.span().enabled and B.span().primary == "DP-1"
		and B.span().order == ["HDMI-A-1"])
	check("fondo solido", B.wallpaper_kind() == "solid")
	check("sin imagen no hay textura", not B.has_wallpaper_image())

	# JSON inválido no rompe: vuelve a defaults.
	B.write_atomic(path, "{{no json")
	B.reload_now()
	check("json invalido usa defaults", B.settings.accent == B.model.ACCENT_DEFAULT)

	# Poll asíncrono: el Thread relee y aplica en el hilo principal.
	B.write_atomic(path, "{\"accent\":\"#4ec26e\"}")
	B.poll()
	var applied = false
	for i in range(200):
		B.poll()
		OS.delay_msec(10)
		if B.settings.accent == "#4ec26e":
			applied = true
			break
	check("poll aplica cambios en vivo", applied)

	# Limpieza del override y de los archivos de prueba.
	OS.set_environment("GDTK_SETTINGS", "")
	var d = Directory.new()
	d.remove(path)
	d.remove("user://settings_bridge_test")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
