extends SceneTree

# Chequeo de diseño (movido de shell/design_check.gd; tech-debt §C). Va FUERA del
# patrón `*_test.gd` a propósito: instancia `shell.gd`/`frame.gd` completos, lo que con
# el binario dev de verify_all cuelga (no trae clases nativas). Correrlo con el binario
# instalado:
#   ~/gdtk/bin/godot-gdtk --no-window --path shell -s $PWD/tests/design_check.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var shell = load("res://shell.gd")
	var frame = load("res://frame.gd")
	check("cargan shell y frame", shell != null and frame != null
		and shell.can_instance() and frame.can_instance())
	var apps = load("res://apps.gd")
	var nui = load("res://neighborhood_ui.gd")
	check("cargan apps y neighborhood_ui", apps != null and nui != null)
	if shell == null or frame == null:
		OS.exit_code = 1
		quit()
		return

	var sh = shell.new()
	var fr = frame.new()
	check("anillo del Hogar dentro del área útil", _ring_ok(sh))
	check("anchura de applets: la de 2 celdas mide más, la de 1 todas iguales",
		fr._applet_width("notificaciones", 80.0) > fr._applet_width("reloj", 80.0)
		and fr._applet_width("recursos", 80.0) == fr._applet_width("reloj", 80.0))
	# El módulo bluetooth quedó SIN instancia en el Frame (tech-debt §A): el archivo se
	# conserva porque su parser lo reutiliza shell/neighborhood.gd.
	check("bluetooth no es un applet del Frame", fr._applet_def("bluetooth") == null)
	fr.free()
	sh.free()
	print("DESIGN_CHECK_OK" if failed == 0 else "DESIGN_CHECK_FAIL")
	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _ring_ok(sh):
	var positions = sh._home_layout(Vector2(1024, 600))
	if positions.size() != sh.ACTIVITIES.size():
		return false
	for pos in positions:
		if pos.x < 0 or pos.y < 80 or pos.y >= 520:
			return false
	return true
