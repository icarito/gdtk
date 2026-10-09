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

	# Etiqueta de menú: nunca vacía y sin el token "##" de ImGui (el ID único lo
	# aporta el nombre de archivo con push_id, no la etiqueta).
	check("etiqueta vacía -> placeholder", C.item_label("") == "(sin texto)")
	check("etiqueta normal sin cambios", C.item_label("hola mundo") == "hola mundo")
	check("etiqueta neutraliza ##", C.item_label("a##b") == "a# #b")
	check("etiqueta neutraliza ## inicial", C.item_label("##x") == "# #x")
	check("etiqueta neutraliza varios ##", C.item_label("a##b##c").find("##") < 0)

	# Imágenes: se distinguen por la extensión; dimensiones del IHDR de un PNG.
	check("is_image reconoce .png", C.is_image("1700000000000000010.png"))
	check("is_image rechaza texto", not C.is_image("1700000000000000010"))
	var hdr = PoolByteArray()
	for b in [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]:
		hdr.append(b)
	for b in [0, 0, 0, 3, 0, 0, 0, 4]:
		hdr.append(b)
	check("png_size lee el IHDR", C.png_size(hdr) == [3, 4])
	check("png_size rechaza no-PNG", C.png_size(PoolByteArray([1, 2, 3])) == [])
	check("image_label con dimensiones", C.image_label([1920, 1080]) == "Imagen 1920×1080")
	check("image_label sin dimensiones", C.image_label([]) == "Imagen")

	# Frontera de confianza de pick()/valid_name().
	check("nombre válido", C.valid_name("1700000000000000010"))
	check("rechaza traversal ../x", not C.valid_name("../x"))
	check("rechaza separador a/b", not C.valid_name("a/b"))
	check("rechaza vacío y ocultos",
		not C.valid_name("") and not C.valid_name(".") and not C.valid_name("..") and not C.valid_name(".lock"))
	check("acepta nombre de imagen", C.valid_name("1700000000000000010.png"))

	var a = C.new()
	check("pick válido encola", a.pick("1700000000000000010") and a._picks == ["1700000000000000010"])
	check("pick rechaza traversal", not a.pick("../x") and a._picks == ["1700000000000000010"])
	check("pick rechaza separador", not a.pick("a/b") and a._picks == ["1700000000000000010"])
	check("thumb_file apunta a la imagen",
		a.thumb_file("1700000000000000010.png").ends_with("1700000000000000010.png"))
	check("thumb_file vacío para texto", a.thumb_file("1700000000000000010") == "")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
