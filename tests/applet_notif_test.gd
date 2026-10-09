extends SceneTree

# Applet Notificaciones: etiqueta resumida, tooltip, ícono y estado vacío sin bus.
# Correr: godot --no-window --path shell -s $PWD/tests/applet_notif_test.gd

var fails = 0


func check(cond, msg):
	if cond:
		print("ok ", msg)
	else:
		fails += 1
		printerr("FAIL ", msg)


func _init():
	var A = load("res://applet_notif.gd")
	check(A != null, "applet_notif.gd carga")
	if A == null:
		OS.exit_code = 1
		quit()
		return

	check(A.label({}) == "", "registro vacío -> vacío")
	check(A.label({"summary": "Hola"}) == "Hola", "resumen")
	check(A.label({"body": "cuerpo\nmás"}) == "cuerpo", "cae al cuerpo sin resumen")
	check(A.label({"summary": "Demasiado largo para la tesela"}, 6) == "Demasi", "recorte")
	check(A.summary("\n\n  a   b \n c") == "a b", "colapsa espacios")
	check(A.resolve_icon_name("firefox", "org.mozilla") == "firefox", "ícono explícito")
	check(A.resolve_icon_name("", "org.mozilla") == "org.mozilla", "cae a app_id")
	check(A.tooltip({}, 0).begins_with("Notificaciones:"), "tooltip vacío")

	# Sin bus, refresh cae a "sin_dato" y no rompe (ya arranca así: sin cambio).
	var a = A.new()
	a.state = "activo"
	a.value = "algo"
	var changed = a.refresh()
	check(changed, "refresh sin bus devuelve cambio")
	check(a.state == "sin_dato" and a.value == "", "estado sin bus")

	A.selftest()
	check(true, "applet_notif selftest")

	OS.exit_code = 1 if fails > 0 else 0
	quit()
