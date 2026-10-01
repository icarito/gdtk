extends SceneTree

func _init():
	for path in ["res://apps.gd", "res://frame.gd", "res://shell.gd", "res://neighborhood_ui.gd"]:
		var script = load(path)
		assert(script != null and script.can_instance())
	var shell = load("res://shell.gd").new()
	var positions = shell._home_layout(Vector2(1024, 600))
	assert(positions.size() == shell.ACTIVITIES.size())
	for pos in positions:
		assert(pos.x >= 0 and pos.y >= 80 and pos.y < 520)
	var frame = load("res://frame.gd").new()
	assert(frame._applet_def("recursos") != null)
	assert(frame._applet_width("recursos", 80.0) > frame._applet_width("reloj", 80.0))
	assert(frame._applet_def("bluetooth") == null)
	frame.free()
	shell.free()
	print("DESIGN_CHECK_OK")
	quit()
