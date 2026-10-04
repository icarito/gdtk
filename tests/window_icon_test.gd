extends SceneTree

# Resolución del .desktop de una ventana Wayland por app_id (shell/apps.gd,
# match_window_app*). Reproduce el bug: la SEGUNDA ventana de Nautilus no obtenía
# icono porque el app_id reverse-DNS ("org.gnome.Nautilus") no casaba con
# `Exec=nautilus`; sólo andaba la primera, cuyo nombre de actividad coincidía con
# el Name del .desktop. Correr:
#   godot --no-window --path shell -s $PWD/tests/window_icon_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func put(path, body):
	Directory.new().make_dir_recursive(path.get_base_dir())
	var f = File.new()
	f.open(path, File.WRITE)
	f.store_string("[Desktop Entry]\nType=Application\n" + body + "\n")
	f.close()


func _init():
	var root = OS.get_user_data_dir() + "/window_icon_test"
	var home = root + "/home"
	var sys = root + "/sys"
	# Nautilus real: reverse-DNS, sin StartupWMClass, Name localizado != app_id.
	put(sys + "/applications/org.gnome.Nautilus.desktop",
		"Name=Files\nName[es]=Archivos\nExec=nautilus --new-window %U\nIcon=org.gnome.Nautilus\nDBusActivatable=true")
	# StartupWMClass canónico.
	put(sys + "/applications/Alacritty.desktop",
		"Name=Alacritty\nExec=alacritty\nIcon=Alacritty\nStartupWMClass=Alacritty")
	# id del .desktop == app_id, sin StartupWMClass.
	put(sys + "/applications/com.example.Term.desktop",
		"Name=Term\nExec=term\nIcon=com.example.Term")
	# Ruido: otra app cuyo binario no debe casar.
	put(sys + "/applications/otra.desktop", "Name=Otra\nExec=otra\nIcon=otra")
	for b in ["nautilus", "alacritty", "term", "otra"]:
		put(root + "/bin/" + b, "")
	OS.set_environment("PATH", root + "/bin")
	OS.set_environment("XDG_DATA_HOME", home)
	OS.set_environment("XDG_DATA_DIRS", sys)
	OS.set_environment("XDG_CURRENT_DESKTOP", "GNOME")

	var apps = load("res://apps.gd").new()
	apps.scan()

	# --- El caso reportado: dos ventanas, mismo app_id reverse-DNS. ---
	var w1 = apps.match_window_app("org.gnome.Nautilus")
	check("ventana 1 Nautilus resuelve por app_id reverse-DNS", w1 != null)
	check("ventana 1 usa el .desktop correcto", w1 != null and w1.icon == "org.gnome.Nautilus")
	check("ventana 1 no cae en la app de ruido", w1 != null and w1.name == "Archivos")
	var w2 = apps.match_window_app("org.gnome.Nautilus")
	check("ventana 2 da el MISMO .desktop que la 1", w2 == w1)
	check("ventana 2 da el MISMO icono que la 1",
		w1 != null and w2 != null and w2.icon == w1.icon)

	# El binario (nautilus) y la clase suelta también resuelven a la misma entrada.
	check("app_id binario 'nautilus' -> misma entrada", apps.match_window_app("nautilus") == w1)

	# --- StartupWMClass y sufijos. ---
	var al = apps.match_window_app("Alacritty")
	check("StartupWMClass casa (Alacritty)", al != null and al.icon == "Alacritty")
	check("app_id con dominio casa StartupWMClass por el último segmento",
		apps.match_window_app("org.example.Alacritty") == al)

	# --- El último segmento, no el primero: 'deep.sub.term' debe casar Exec=term. ---
	check("reverse-DNS de 3+ niveles casa por el ÚLTIMO segmento",
		apps.match_window_app("deep.sub.term") != null)
	check("id del .desktop casa el app_id completo",
		apps.match_window_app("com.example.Term") != null)

	# --- Sin coincidencia / vacío. ---
	check("app_id desconocido -> null", apps.match_window_app("org.gnome.Nope") == null)
	check("app_id vacío -> null", apps.match_window_app("") == null)
	check("candidatos vacíos para app_id vacío", apps.match_window_apps("").empty())

	OS.exit_code = 1 if failed > 0 else 0
	quit()
