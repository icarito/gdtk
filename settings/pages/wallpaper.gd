extends "res://pages/page.gd"

# Página Fondo de pantalla (K11a): imagen (rellenar/ajustar/centrar), color sólido o
# el degradado del shell. El shell lo dibuja detrás del Hogar en vivo.

const EXTS = ["png", "jpg", "jpeg", "webp", "bmp"]

var mode_opt = null
var color_btn = null
var list = null
var preview = null
var path_label = null


func _build():
	h_title("Fondo de pantalla")
	h_note("Imagen o color que se dibuja detrás del Hogar.")
	h_gap(6)

	var mrow = h_row()
	mode_opt = OptionButton.new()
	var modes = ["gradient", "fill", "fit", "center", "solid"]
	for i in range(modes.size()):
		mode_opt.add_item(mode_label(modes[i]), i)
		if modes[i] == settings.get("wallpaper", {}).get("mode", "gradient"):
			mode_opt.select(i)
	mode_opt.connect("item_selected", self, "_on_mode", [modes])
	STYLE.apply_option(mode_opt)
	h_label("Modo", mrow)
	mrow.add_child(mode_opt)

	var crow = h_row()
	color_btn = ColorPickerButton.new()
	color_btn.color = model.color_of_hex(settings.get("wallpaper", {}).get("color", ""))
	color_btn.rect_min_size = Vector2(80, 30)
	color_btn.connect("color_changed", self, "_on_color")
	h_label("Color", crow)
	crow.add_child(color_btn)

	h_gap(8)
	var list_row = h_row()
	list = ItemList.new()
	list.rect_min_size = Vector2(360, 180)
	for p in scan_wallpapers():
		list.add_item(p.get_file())
		list.set_item_metadata(list.get_item_count() - 1, p)
	list.connect("item_selected", self, "_on_image")
	list_row.add_child(list)
	preview = TextureRect.new()
	preview.rect_min_size = Vector2(220, 150)
	preview.expand = true
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	list_row.add_child(preview)
	_show_preview(settings.get("wallpaper", {}).get("path", ""))

	path_label = STYLE.note("Imagen: " + str(settings.get("wallpaper", {}).get("path", "")))
	box.add_child(path_label)


func mode_label(mode):
	if mode == "gradient":
		return "Predeterminado"
	return model.WALLPAPER_MODE_LABELS.get(mode, mode)


func scan_wallpapers():
	var dirs = [
		OS.get_environment("HOME").plus_file("Pictures"),
		OS.get_environment("HOME").plus_file(".config").plus_file("gdtk").plus_file("wallpapers"),
	]
	var out = []
	var seen = {}
	for dir in dirs:
		var d = Directory.new()
		if d.open(dir) != OK:
			continue
		d.list_dir_begin(true, true)
		var fname = d.get_next()
		while fname != "":
			if not d.current_is_dir() and fname.get_extension().to_lower() in EXTS:
				var full = dir.plus_file(fname)
				if not seen.has(full):
					seen[full] = true
					out.append(full)
			fname = d.get_next()
		d.list_dir_end()
	out.sort()
	return out


func _on_mode(index, modes):
	var mode = modes[index]
	var w = settings.get("wallpaper", {}).duplicate(true)
	w["mode"] = mode
	settings["wallpaper"] = w
	host.set_wallpaper(w)


func _on_color(color):
	var w = settings.get("wallpaper", {}).duplicate(true)
	w["color"] = "#" + color.to_html(false)
	settings["wallpaper"] = w
	host.set_wallpaper(w)


func _on_image(index):
	var path = String(list.get_item_metadata(index))
	var w = settings.get("wallpaper", {}).duplicate(true)
	w["path"] = path
	if w.get("mode", "gradient") in ["gradient", "solid"]:
		w["mode"] = "fill"
	settings["wallpaper"] = w
	host.set_wallpaper(w)
	path_label.text = "Imagen: " + path
	_show_preview(path)


func _show_preview(path):
	if path == "" or not File.new().file_exists(path):
		preview.texture = null
		return
	var img = Image.new()
	if img.load(path) == OK:
		var tex = ImageTexture.new()
		tex.create_from_image(img, Texture.FLAG_FILTER)
		preview.texture = tex
