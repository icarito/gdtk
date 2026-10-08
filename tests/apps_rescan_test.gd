extends SceneTree

# Autoprueba de la auto-detección de apps instaladas/desinstaladas (shell/apps.gd
# maybe_rescan): con XDG_DATA_HOME/XDG_DATA_DIRS temporales, un .desktop nuevo debe
# aparecer en la lista y al borrarlo debe desaparecer, sin volver a llamar a scan() a
# mano. El escaneo real se aísla de la máquina con esos dos directorios.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/apps_rescan_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _write_desktop(path, name):
	var f = File.new()
	var err = f.open(path, File.WRITE)
	if err != OK:
		return false
	f.store_string("[Desktop Entry]\nType=Application\nName=%s\nExec=/bin/true\n" % name)
	f.close()
	return true


func _init():
	var base = "/tmp/gdtk_apps_test_%d" % OS.get_ticks_msec()
	var data_home = base + "/data"
	var apps_home = data_home + "/applications"
	var data_dirs = base + "/dirs"
	Directory.new().make_dir_recursive(apps_home)
	Directory.new().make_dir_recursive(data_dirs)
	OS.set_environment("XDG_DATA_HOME", data_home)
	OS.set_environment("XDG_DATA_DIRS", data_dirs)

	var f = load("res://apps.gd").new()
	# Primer chequeo: escanea (aunque nadie haya llamado scan) y no ve apps todavía.
	check("primer maybe_rescan escanea", f.maybe_rescan(0))
	check("sin apps al inicio", f.apps.size() == 0)
	# Recién escaneado: sin cambios, no reescanea ni dentro del intervalo ni pasado.
	check("sin cambios no reescanea", not f.maybe_rescan(10))
	check("mismo estado no reescanea (intervalo vencido)", not f.maybe_rescan(999999))

	# Instalan una app local: aparece tras el intervalo de sondeo.
	check("escribe .desktop local", _write_desktop(apps_home + "/foo.desktop", "Foo"))
	check("detecta app instalada", f.maybe_rescan(999999 + f.RESCAN_POLL_MS))
	check("la app está en la lista", _has(f, "Foo"))
	check("no reescanea sin cambios", not f.maybe_rescan(999999 + 2 * f.RESCAN_POLL_MS))

	# La desinstalan: desaparece.
	var dir = Directory.new()
	check("borra .desktop local", dir.remove(apps_home + "/foo.desktop") == OK)
	check("detecta app desinstalada", f.maybe_rescan(999999 + 3 * f.RESCAN_POLL_MS))
	check("la app ya no está", not _has(f, "Foo"))

	# Un directorio XDG_DATA_DIRS que aparece después también cuenta.
	var extra = base + "/extra"
	OS.set_environment("XDG_DATA_DIRS", extra)
	Directory.new().make_dir_recursive(extra + "/applications")
	check("escribe .desktop en data dir nuevo", _write_desktop(extra + "/applications/bar.desktop", "Bar"))
	check("detecta el data dir nuevo", f.maybe_rescan(999999 + 4 * f.RESCAN_POLL_MS))
	check("la app del data dir está", _has(f, "Bar"))

	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _has(f, name):
	for a in f.apps:
		if a.name == name:
			return true
	return false
