extends SceneTree

# Con el Frame oculto (autohide) la franja no debe atender mouse: `bars_shown`
# distingue Home/visible/pin/exposé, y `drop_mouse_interaction` descarta el estado
# del último dibujo (el rect fantasma del interruptor del radar se comía clics y
# disparaba el corte del intercambio). Extrae las funciones reales de frame.gd sin
# instanciarlo (su cuerpo usa Host.sc, no disponible en headless).
# Correr:
#   godot --no-window --path shell -s $PWD/tests/frame_hidden_mouse_test.gd

var failed = 0


class ShellStub:
	extends Reference
	var current_activity = "app"
	var expose = false


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _function(source, name):
	var start = source.find("func " + name + "(")
	if start < 0:
		return ""
	var end = source.find("\nfunc ", start + 1)
	return source.substr(start, end - start if end >= 0 else source.length() - start)


func _init():
	var f = File.new()
	if f.open("res://frame.gd", File.READ) != OK:
		check("leer frame.gd", false)
		OS.exit_code = 1
		quit()
		return
	var source = f.get_as_text()
	f.close()
	var harness = "extends Reference\nvar shell\nvar visible = false\n"
	harness += "var pin_top_bar = false\nvar pin_bottom_bar = false\n"
	harness += "var mouse_down = false\nvar lifted = null\nvar dragging = null\nvar drag_candidate = null\n"
	harness += "var app_press = null\nvar app_drag = null\nvar applet_press = null\nvar applet_drag = null\n"
	harness += "var shared_press = \"\"\nvar shared_drag = false\nvar shared_power_press = false\nvar shared_power_rect = Rect2()\n"
	harness += "var win_dock_press = false\nvar win_dock_drag = false\nvar win_scroll_press = false\nvar win_drag = null\n"
	harness += "var place_rects = []\nvar items_layout = []\nvar applets_layout = []\nvar applets_drawn = false\n"
	harness += "var shared_layout = []\nvar shared_drawn = false\n"
	harness += "var bar_layout = {}\nvar window_region = {}\nvar window_span = {}\n"
	for name in ["_clear_zone_layout", "bars_shown", "drop_mouse_interaction"]:
		harness += "\n" + _function(source, name)
	var script = GDScript.new()
	script.set_source_code(harness)
	var err = script.reload()
	check("funciones reales del frame compilan", err == OK)
	if err != OK:
		OS.exit_code = 1
		quit()
		return
	var fr = script.new()
	fr.shell = ShellStub.new()
	fr.visible = false
	check("oculto sin home/pin no atiende mouse", not fr.bars_shown())
	fr.shell.current_activity = null
	check("Home atiende mouse", fr.bars_shown())
	fr.shell.current_activity = "app"
	fr.visible = true
	check("Frame visible atiende mouse", fr.bars_shown())
	fr.visible = false
	fr.pin_bottom_bar = true
	check("barra fijada atiende mouse", fr.bars_shown())
	fr.pin_bottom_bar = false
	fr.shell.expose = true
	check("exposé atiende mouse", fr.bars_shown())
	fr.shell.expose = false

	# El reset descarta el rect del interruptor del radar y los press/arrastres vivos.
	fr.shared_power_rect = Rect2(10, 20, 12, 20)
	fr.shared_power_press = true
	fr.mouse_down = true
	fr.app_press = "app"
	fr.dragging = {"id": 1}
	fr.drop_mouse_interaction()
	check("reset borra el rect del interruptor", fr.shared_power_rect == Rect2())
	check("reset suelta presses y arrastres",
		not fr.shared_power_press and not fr.mouse_down \
		and fr.app_press == null and fr.dragging == null)
	OS.exit_code = 1 if failed > 0 else 0
	quit()
