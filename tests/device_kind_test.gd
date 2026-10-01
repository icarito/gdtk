extends SceneTree

# Autoprueba del modelo puro del tipo de equipo local (shell/device_kind.gd).
#   godot --no-window --path shell -s $PWD/tests/device_kind_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var dk = load("res://device_kind.gd").new()
	dk.run_selftest()
	check("selftest() de device_kind", true)

	# La lista es la misma que publica el TXT mDNS del Vecindario.
	var publish = load("res://neighborhood_publish.gd").new()
	var txt = publish.build_common_txt({"hid": "h", "name": "n", "kind": "tablet", "icon": "tablet"})
	check("kind publicado en TXT", txt.has("kind=tablet"))
	check("normalize coincide con el vocabulario publicado", dk.normalize("laptop") == "laptop"
		and dk.normalize("phone") == "unknown")

	check("chasis Surface/convertible es tablet",
		dk.from_chassis(30) == "tablet" and dk.from_chassis(31) == "tablet"
		and dk.from_chassis(32) == "tablet")
	check("notebook es laptop", dk.from_chassis(9) == "laptop" and dk.from_chassis(8) == "laptop")
	check("hand held es mobile", dk.from_chassis(11) == "mobile")
	check("torre es desktop", dk.from_chassis(3) == "desktop" and dk.from_chassis(7) == "desktop"
		and dk.from_chassis(35) == "desktop")
	check("other/unknown no adivina",
		dk.from_chassis(1) == "unknown" and dk.from_chassis(2) == "unknown")
	check("Surface Pro/Go es tablet",
		dk.from_product("Surface Pro 3") == "tablet" and dk.from_product("Surface Go 2") == "tablet")
	check("Surface Laptop/notebook es laptop",
		dk.from_product("Surface Laptop 4") == "laptop" and dk.from_product("ThinkPad Notebook") == "laptop")

	check("override gana", dk.detect("mobile", "3", false) == "mobile")
	check("producto manda sobre chasis", dk.detect("", "9", true, "Surface Pro 3") == "tablet")
	check("chasis si no hay override", dk.detect("", "30", false) == "tablet")
	check("batería sugiere laptop", dk.detect("", "", true) == "laptop")
	check("sin datos -> unknown", dk.detect("", "", false) == "unknown"
		and dk.detect("", "no-numero", false) == "unknown")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
