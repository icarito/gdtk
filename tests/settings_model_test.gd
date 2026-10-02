extends SceneTree

# Autoprueba del modelo puro de Configuración (K11a). Sin I/O ni procesos.
#   godot --no-window --path shell -s $PWD/tests/settings_model_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _settings_dir():
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir().plus_file("settings")


func _init():
	var S = load(_settings_dir().plus_file("settings_model.gd")).new()
	check("modelo cargado", S != null)

	S.selftest()
	check("selftest() del modelo", true)

	var d = S.defaults()
	check("default teclado", d.keyboard == S.KEYBOARD_DEFAULT)
	check("default idioma", d.locale == S.LOCALE_DEFAULT)
	check("default acento en paleta", d.accent in S.ACCENT_PALETTE)
	check("default fondo sin imagen", d.wallpaper.path == "")
	check("default scroll natural activo", d.natural_scroll == true and S.NATURAL_SCROLL_DEFAULT)
	check("default control compartido apagado", d.deskflow.mode == "off"
		and d.deskflow.port == 24800 and not d.deskflow.auto)
	check("scroll natural tolera false de texto", S.nat_scroll("false") == false and S.nat_scroll("on") == true)
	check("scroll natural cae al default con basura", S.nat_scroll("cosa") == S.NATURAL_SCROLL_DEFAULT)
	check("argumentos de scroll natural",
		S.natural_scroll_cmd(false) == ["input", "type:touchpad", "natural_scroll", "disabled"]
		and S.natural_scroll_cmd(true) == ["input", "type:touchpad", "natural_scroll", "enabled"])
	var df = S.deskflow({"mode": "use_remote", "host": "bastion.local", "port": "24801",
		"auto": "yes", "name": "tengu"})
	check("control compartido cliente normalizado", df.mode == "use_remote"
		and df.host == "bastion.local" and df.port == 24801 and df.auto and df.name == "tengu")
	check("control compartido sin host se apaga",
		S.deskflow({"mode": "use_remote", "host": ""}).mode == "off")
	check("control compartido valida host/nombre",
		S.host_name("bad host") == "" and S.screen_name("bad name") == ""
		and S.screen_name("bastion") == "bastion")

	# Hex: válidos, normalización y rechazos.
	check("hex sin # aceptado", S.valid_hex("AABBCC") == "#aabbcc")
	check("hex con # aceptado", S.valid_hex("#4EC26E") == "#4ec26e")
	check("hex corto rechazado", S.valid_hex("#abc") == "")
	check("hex con letra invalida rechazado", S.valid_hex("#zz0011") == "")
	check("acento invalido cae al default", S.accent_hex("rojo") == S.ACCENT_DEFAULT)
	check("color de hex", S.color_of_hex("#000000").r == 0.0 and S.color_of_hex("#ffffff").b == 1.0)

	var n = S.normalize({"keyboard": "de", "locale": "en_US", "accent": "#35C9C4"})
	check("normalize teclado", n.keyboard == "de")
	check("normalize idioma sin codificacion", n.locale == "en_US.UTF-8")
	check("normalize acento", n.accent == "#35c9c4")
	check("normalize teclado invalido", S.normalize({"keyboard": "nope"}).keyboard == S.KEYBOARD_DEFAULT)

	# Campos desconocidos se conservan (otra página puede escribir el mismo archivo).
	var x = S.normalize({"screens": [{"x": 0}], "otro": 1})
	check("campos desconocidos conservados", x.has("screens") and x.has("otro"))

	# JSON ida y vuelta.
	var json = S.to_json(n)
	var back = S.parse(json)
	check("json ida y vuelta", back.keyboard == n.keyboard and back.accent == n.accent)
	check("json invalido usa defaults", S.parse("{{no json").keyboard == S.KEYBOARD_DEFAULT)

	# Archivos de sesión.
	check("contenido teclado", S.keyboard_file_content("es") == "XKB_DEFAULT_LAYOUT=es\n")
	check("contenido idioma", S.locale_file_content("pt_BR") == "LANG=pt_BR.UTF-8\n")
	check("acento es en vivo", S.is_live("accent"))
	check("teclado no es en vivo", not S.is_live("keyboard"))
	check("aviso de reinicio", S.restart_notice("keyboard") != "" and S.restart_notice("accent") == "")

	# Fondo.
	var fill = S.wallpaper_rect("fill", Vector2(100, 50), Vector2(200, 200))
	check("fondo rellenar cubre", fill.size == Vector2(400, 200) and fill.position == Vector2(-100, 0))
	var fit = S.wallpaper_rect("fit", Vector2(100, 50), Vector2(200, 200))
	check("fondo ajustar contiene", fit.size == Vector2(200, 100) and fit.position == Vector2(0, 50))
	var center = S.wallpaper_rect("center", Vector2(80, 40), Vector2(200, 200))
	check("fondo centrar tamano real", center.size == Vector2(80, 40) and center.position == Vector2(60, 80))
	check("fondo solido llena", S.wallpaper_rect("solid", Vector2(10, 10), Vector2(200, 200)) == Rect2(0, 0, 200, 200))
	check("imagen valida", S.wallpaper_kind({"mode": "fill", "path": "/tmp/x.png"}) == "image")
	check("fill sin ruta cae a solido", S.wallpaper_kind({"mode": "fill", "path": ""}) == "solid")
	check("ruta con tilde rechazada", S.wallpaper({"path": "~/x.png"}).path == "")
	check("ruta con traversal rechazada", S.wallpaper({"path": "/a/../b.png"}).path == "")
	check("modo desconocido cae a gradiente", S.wallpaper({"mode": "zoom"}).mode == "gradient")

	# Vocabulario de producto: nada de nombres internos en lo visible.
	var forbidden = ["gvd", "deskflow", "mdns", "dns-sd", "recv", "server", "client", "hid", "role"]
	var labels = []
	for o in S.KEYBOARDS:
		labels.append(o.label.to_lower())
	for o in S.LOCALES:
		labels.append(o.label.to_lower())
	for k in S.WALLPAPER_MODE_LABELS.keys():
		labels.append(String(S.WALLPAPER_MODE_LABELS[k]).to_lower())
	for k in S.CONTROL_MODE_LABELS.keys():
		labels.append(String(S.CONTROL_MODE_LABELS[k]).to_lower())
	for t in forbidden:
		var hit = false
		for l in labels:
			if l.find(t) >= 0:
				hit = true
		check("sin jerga visible: " + t, not hit)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
