extends SceneTree

func _init():
	assert(ClassDB.class_exists("SlugVector2D"))
	for name in ["network-connected", "network-off", "network-open", "network-secure"]:
		var vector = ClassDB.instance("SlugVector")
		vector.set_svg_path("res://icons/" + name + ".svg")
		assert(vector.is_valid() and vector.get_shape_count() > 0)
		var icon = ClassDB.instance("SlugVector2D")
		icon.set_vector(vector)
		icon.set_size(58.0)
		icon.set_centered(false)
		assert(icon.get_size() == 58.0 and not icon.get_centered())
		icon.free()
	print("SLUG_VECTOR_CHECK_OK")
	quit()
