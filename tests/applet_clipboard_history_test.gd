extends SceneTree

# Autoprueba de la parte pura del historial navegable del applet Portapapeles:
# orden de nombres, resumen recortado/multilínea y la frontera de confianza de pick().
#   godot --no-window --path shell -s $PWD/tests/applet_clipboard_history_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var C = load("res://applet_clipboard.gd")

	# Orden: más nuevo primero, archivos ocultos fuera.
	var names = C.sorted_names(["1700000000000000002", ".lock", "1700000000000000010", ".in.42", "1700000000000000001"])
	check("orden descendente y sin ocultos",
		names == ["1700000000000000010", "1700000000000000002", "1700000000000000001"])
	check("sin entradas -> lista vacía", C.sorted_names([]) == [])

	# Resumen: primera línea no vacía, multilínea y recorte a 60.
	check("resumen multilínea toma la primera línea no vacía",
		C.summary("\n\n  hola   mundo\t x \nsegunda") == "hola mundo x")
	var big = ""
	for _i in range(120):
		big += "a"
	var long = C.summary(big + "\nb")
	check("resumen recortado a 60", long.length() == 60 and long == big.substr(0, 60))
	check("resumen con límite explícito", C.summary("abcdef", 3) == "abc")

	# Frontera de confianza de pick()/valid_name().
	check("nombre válido", C.valid_name("1700000000000000010"))
	check("rechaza traversal ../x", not C.valid_name("../x"))
	check("rechaza separador a/b", not C.valid_name("a/b"))
	check("rechaza vacío y ocultos",
		not C.valid_name("") and not C.valid_name(".") and not C.valid_name("..") and not C.valid_name(".lock"))

	var a = C.new()
	check("pick válido encola", a.pick("1700000000000000010") and a._picks == ["1700000000000000010"])
	check("pick rechaza traversal", not a.pick("../x") and a._picks == ["1700000000000000010"])
	check("pick rechaza separador", not a.pick("a/b") and a._picks == ["1700000000000000010"])

	OS.exit_code = 1 if failed > 0 else 0
	quit()
