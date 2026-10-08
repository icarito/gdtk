extends SceneTree

# Autoprueba de la lista activa del applet Teclado (shell/applet_keyboard.gd):
# rotación, alta/baja con mínimo 1 y config persistida (GDTK_LAYOUTS, primera =
# XKB_DEFAULT_LAYOUT). Escribe en un XDG_CONFIG_HOME temporal.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/applet_keyboard_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var dir = "/tmp/gdtk_kb_test_%d" % OS.get_ticks_msec()
	OS.set_environment("XDG_CONFIG_HOME", dir)
	var k = load("res://applet_keyboard.gd").new()
	k.active = ["latam", "es"]
	k.current = "latam"
	check("next desde latam = es", k.next_layout() == "es")
	k.current = "es"
	check("next desde es envuelve a latam", k.next_layout() == "latam")
	k.active = ["es"]
	check("una sola: sin rotación", k.next_layout() == "")
	check("no quita la última", not k.toggle_active("es") and k.active == ["es"])
	check("rechaza id inválido", not k.apply("dvorak") and k.current == "es")
	check("agrega us", k.toggle_active("us") and k.active == ["es", "us"])
	check("apply latam la agrega y la usa", k.apply("latam") and k.current == "latam" \
		and k.active == ["es", "us", "latam"])
	check("quita us", k.toggle_active("us") and k.active == ["es", "latam"])
	k.stop()  # reapea las escrituras
	var f = File.new()
	var ok = f.open(dir + "/gdtk/keyboard", File.READ) == OK
	var text = f.get_as_text() if ok else ""
	f.close()
	check("config con GDTK_LAYOUTS=es,latam", text.find("GDTK_LAYOUTS=es,latam\n") >= 0)
	check("primera = XKB_DEFAULT_LAYOUT", text.begins_with("XKB_DEFAULT_LAYOUT=es\n"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
