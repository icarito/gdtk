extends "res://pages/page.gd"

# Página "Apps por defecto": terminal, navegador y gestor de archivos. Cada campo
# guarda el id de un .desktop o "" (automático: el sistema decide). El navegador y
# el gestor también se escriben en mimeapps.list (store.gd); el terminal no es mime.

var _candidates = {}


func _build():
	h_title("Apps por defecto")
	h_note("Qué aplicación abre el sistema para cada tarea.")
	h_gap(6)
	_candidates = scan_apps()
	_add_row("terminal", "Terminal")
	_add_row("browser", "Navegador")
	_add_row("files", "Gestor de archivos")
	h_gap(4)
	box.add_child(STYLE.note("“Automático” deja que el sistema elija la aplicación instalada."))


func _add_row(field, label):
	var row = h_row()
	h_label(label, row)
	var opt = OptionButton.new()
	opt.rect_min_size.x = 300
	opt.add_item("Automático")
	var ids = [""]
	var cur = _cur(field)
	var apps = _candidates.get(field, [])
	for i in range(apps.size()):
		var e = apps[i]
		ids.append(e.id)
		opt.add_item(e.name)
		if e.id == cur:
			opt.select(i + 1)
	opt.connect("item_selected", self, "_on_selected", [field, ids])
	STYLE.apply_option(opt)
	row.add_child(opt)
	if apps.empty():
		box.add_child(STYLE.note("No se encontraron aplicaciones para esta tarea."))


func _cur(field):
	var d = settings.get("defaults", {})
	if typeof(d) != TYPE_DICTIONARY:
		d = {}
	return String(d.get(field, ""))


func _on_selected(index, field, ids):
	var d = settings.get("defaults", {}).duplicate(true)
	d[field] = String(ids[index])
	settings["defaults"] = d
	host.set_field("defaults", d)


func scan_apps():
	var out = []
	var seen = {}
	for dir in _app_dirs():
		var d = Directory.new()
		if d.open(dir) != OK:
			continue
		d.list_dir_begin(true, true)
		var fname = d.get_next()
		while fname != "":
			if not d.current_is_dir() and fname.get_extension().to_lower() == "desktop" and not seen.has(fname):
				var e = parse_desktop(dir.plus_file(fname), fname)
				if e != null:
					seen[fname] = true
					out.append(e)
			fname = d.get_next()
		d.list_dir_end()
	out.sort_custom(self, "_by_name")
	return {
		"terminal": _filter(out, "terminal"),
		"browser": _filter(out, "browser"),
		"files": _filter(out, "files"),
	}


func _app_dirs():
	return [
		OS.get_environment("HOME").plus_file(".local/share/applications"),
		"/usr/local/share/applications",
		"/usr/share/applications",
	]


# Lee la sección [Desktop Entry]: Name (sin localizar), Exec, Terminal y MimeType.
# Devuelve null para entradas ocultas, sin nombre o sin comando.
func parse_desktop(path, id):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return null
	var e = {"id": id, "name": "", "exec": "", "terminal": false, "mime": [],
		"hidden": false, "nodisplay": false}
	var in_main = false
	while not f.eof_reached():
		var line = f.get_line().strip_edges()
		if line.begins_with("[") and line.ends_with("]"):
			in_main = (line == "[Desktop Entry]")
			continue
		if not in_main or line == "" or line.begins_with("#"):
			continue
		var eq = line.find("=")
		if eq <= 0:
			continue
		var key = line.substr(0, eq).strip_edges()
		var val = line.substr(eq + 1).strip_edges()
		match key:
			"Name":
				if e.name == "":
					e.name = val
			"Exec":
				e.exec = val
			"Terminal":
				e.terminal = (val.to_lower() == "true")
			"MimeType":
				e.mime = val.split(";", false)
			"Hidden":
				e.hidden = (val.to_lower() == "true")
			"NoDisplay":
				e.nodisplay = (val.to_lower() == "true")
	f.close()
	if e.hidden or e.nodisplay or e.name == "" or e.exec == "":
		return null
	return e


func _by_name(a, b):
	return a.name.to_lower() < b.name.to_lower()


func _filter(apps, field):
	var out = []
	for e in apps:
		if _matches(e, field):
			out.append(e)
	return out


func _matches(e, field):
	if field == "terminal":
		return bool(e.terminal)
	if field == "browser":
		return _has_mime(e, "x-scheme-handler/http") or _has_mime(e, "x-scheme-handler/https")
	if field == "files":
		return _has_mime(e, "inode/directory")
	return false


func _has_mime(e, m):
	return e.mime.has(m)
