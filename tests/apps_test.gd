extends SceneTree

# Parser .desktop de shell/apps.gd. Correr:
#   godot --no-window --path shell -s $PWD/tests/apps_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func put(path, body):
	Directory.new().make_dir_recursive(path.get_base_dir())
	var f = File.new()
	f.open(path, File.WRITE)
	f.store_string("[Desktop Entry]\nType=Application\n" + body + "\n[Desktop Action x]\nName=NO\n")
	f.close()


func _init():
	var root = OS.get_user_data_dir() + "/apps_test"
	var home = root + "/home"
	var sys = root + "/sys"
	put(home + "/applications/a.desktop", "Name=Uno\nName[es]=Único\nExec=foo %U --x 100%%\nCategories=GTK;Game;")
	put(sys + "/applications/a.desktop", "Name=Otro\nExec=otro")  # tapado por el del usuario
	put(home + "/applications/h.desktop", "Name=H\nExec=h\nHidden=true")
	put(sys + "/applications/h.desktop", "Name=H sistema\nExec=h")  # oculto por Hidden del usuario
	put(sys + "/applications/nd.desktop", "Name=ND\nExec=nd\nNoDisplay=true")
	put(sys + "/applications/t.desktop", "Name=T\nExec=t\nTerminal=true")
	put(sys + "/applications/k.desktop", "Name=K\nExec=k\nOnlyShowIn=KDE;")
	put(sys + "/applications/g.desktop", "Name=G\nExec=g\nNotShowIn=GNOME;")
	put(sys + "/applications/m.desktop", "Name=Mu\u0301sica\nExec=m")  # acento NFD
	put(sys + "/applications/sub/b.desktop", "Name=Bé\nExec=b %f\nIcon=/no/existe.png")
	put(sys + "/applications/d.desktop", "Name=D\nDBusActivatable=true")
	put(sys + "/applications/x.desktop", "Name=X\nExec=noexiste")  # sin el programa: oculto
	put(sys + "/applications/te.desktop", "Name=TE\nExec=foo\nTryExec=noexiste")
	put(sys + "/applications/q.desktop", "Name=Q\nExec=\"/no/con espacio\" %f")  # programa entre comillas
	put(sys + "/applications/p.desktop", "Name=P\nExec=env A=1 p\nPath=/tmp/o'k")
	# Programas falsos en un PATH propio (la grilla oculta lo que no está instalado).
	for b in ["foo", "m", "b", "t", "p", "alacritty", "gapplication"]:
		put(root + "/bin/" + b, "")
	OS.set_environment("PATH", root + "/bin")
	OS.set_environment("XDG_DATA_HOME", home)
	OS.set_environment("XDG_DATA_DIRS", sys)
	OS.set_environment("XDG_CURRENT_DESKTOP", "GNOME")

	var apps = load("res://apps.gd").new()
	apps.scan()
	var names = []
	for a in apps.apps:
		names.append(a.name)
	check("filtra, dedupe y ordena: " + str(names), names == ["Bé", "D", "Música", "P", "T", "Único"])
	check("id con subdirectorio", apps.apps[0].id == "sub-b.desktop")
	check("exec sin field codes: " + apps.apps[5].exec, apps.apps[5].exec == "foo  --x 100%")
	check("DBusActivatable sin Exec: " + apps.apps[1].cmd, apps.apps[1].cmd == "exec gapplication launch d")
	check("Path=: " + apps.apps[3].cmd, apps.apps[3].cmd == "cd '/tmp/o'\\''k' && exec env A=1 p")
	check("Terminal=true: " + apps.apps[4].cmd, apps.apps[4].cmd == "exec alacritty -e t")
	check("icono inexistente", apps.resolve_icon(apps.apps[0].icon) == "")
	apps.query = "UNI"
	check("busca sin acentos ni mayúsculas", apps.matches().size() == 1)
	apps.query = "game"
	check("busca por categoría", apps.matches().size() == 1)
	apps.query = "gtk"
	check("ignora categorías de toolkit", apps.matches().empty())
	apps.query = "be"
	check("busca 'be' -> Bé", apps.matches().size() == 1 and apps.matches()[0].name == "Bé")
	OS.exit_code = 1 if failed > 0 else 0
	quit()
