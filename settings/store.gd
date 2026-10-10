extends Reference

# I/O de la app Configuración (K11a). Único escritor de `~/.config/gdtk/settings.json`
# (tmp + rename atómico) y de los archivos de sesión `keyboard` y `locale` que lee
# `session/keyboard.sh` y (a futuro) la sesión.
#
# `GDTK_SETTINGS` redirige TODO (settings.json y archivos de sesión) a otra carpeta:
# sirve para pilotos y pruebas sin tocar la configuración real.

const MODEL_PATH = "res://settings_model.gd"

var model = null


func _init():
	model = load(MODEL_PATH).new()


func tree_dir():
	var override = OS.get_environment("GDTK_SETTINGS")
	if override != "":
		return override.get_base_dir()
	var xdg = OS.get_environment("XDG_CONFIG_HOME")
	if xdg != "":
		return xdg.plus_file("gdtk")
	return OS.get_environment("HOME").plus_file(".config").plus_file("gdtk")


func settings_path():
	var override = OS.get_environment("GDTK_SETTINGS")
	if override != "":
		return override
	return tree_dir().plus_file("settings.json")


func load_settings():
	var f = File.new()
	if f.open(settings_path(), File.READ) != OK:
		return model.defaults()
	var text = f.get_as_text()
	f.close()
	return model.parse(text)


# Guarda settings.json y los archivos de sesión. Devuelve "" si todo fue bien.
func save(settings):
	# "deskflow" lo escribe el shell (interruptor del Grupo): se conserva lo del disco.
	settings["deskflow"] = load_settings().get("deskflow", settings.get("deskflow", {}))
	var normalized = model.normalize(settings)
	var err = write_atomic(settings_path(), model.to_json(normalized))
	if err != "":
		return err
	err = write_atomic(tree_dir().plus_file("keyboard"), model.keyboard_file_content(normalized.keyboard, normalized.get("keyboard_layouts", [])))
	if err != "":
		return err
	err = write_atomic(tree_dir().plus_file("locale"), model.locale_file_content(normalized.locale))
	if err != "":
		return err
	return write_mimeapps(normalized)


# Ruta de mimeapps.list. Con GDTK_SETTINGS seteado se redirige junto al settings.json
# de prueba para no tocar la configuración real.
func mimeapps_path():
	var override = OS.get_environment("GDTK_SETTINGS")
	if override != "":
		return override.get_base_dir().plus_file("mimeapps.list")
	var xdg = OS.get_environment("XDG_CONFIG_HOME")
	if xdg != "":
		return xdg.plus_file("mimeapps.list")
	return OS.get_environment("HOME").plus_file(".config").plus_file("mimeapps.list")


# Actualiza sólo [Default Applications]: navegador -> http/https, gestor -> inode/directory.
# Conserva el resto del archivo. El terminal no es mime: no se escribe.
func write_mimeapps(normalized):
	var path = mimeapps_path()
	var existing = read_text(path)
	var content = mimeapps_content(existing, normalized.get("defaults", {}))
	if content == existing:
		return ""
	return write_atomic(path, content)


func mimeapps_pairs(defaults):
	var browser = String(defaults.get("browser", ""))
	var files = String(defaults.get("files", ""))
	return [
		["x-scheme-handler/http", browser],
		["x-scheme-handler/https", browser],
		["inode/directory", files],
	]


func mimeapps_content(existing, defaults):
	var pairs = mimeapps_pairs(defaults)
	var updates = {}
	for p in pairs:
		updates[p[0]] = p[1]
	var lines = _split_lines(existing)
	var start = -1
	var end = lines.size()
	for i in range(lines.size()):
		var s = lines[i].strip_edges()
		if start < 0:
			if s == "[Default Applications]":
				start = i
		elif s.begins_with("[") and s.ends_with("]"):
			end = i
			break
	if start < 0:
		var body = []
		for p in pairs:
			if updates[p[0]] != "":
				body.append(p[0] + "=" + updates[p[0]])
		if body.empty():
			return existing
		if not lines.empty() and lines[lines.size() - 1].strip_edges() != "":
			lines.append("")
		lines.append("[Default Applications]")
		for line in body:
			lines.append(line)
		return _join_lines(lines)
	var out = []
	for i in range(start + 1):
		out.append(lines[i])
	for i in range(start + 1, end):
		var key = _line_key(lines[i])
		if updates.has(key):
			if updates[key] != "":
				out.append(key + "=" + updates[key])
			updates.erase(key)
		else:
			out.append(lines[i])
	for p in pairs:
		if updates.has(p[0]) and updates[p[0]] != "":
			out.append(p[0] + "=" + updates[p[0]])
	for i in range(end, lines.size()):
		out.append(lines[i])
	return _join_lines(out)


func _split_lines(text):
	if text == "":
		return []
	var parts = text.split("\n")
	if not parts.empty() and parts[parts.size() - 1] == "":
		parts.remove(parts.size() - 1)
	return parts


func _line_key(line):
	var s = line.strip_edges()
	if s == "" or s.begins_with("#") or s.begins_with("["):
		return ""
	var eq = s.find("=")
	if eq <= 0:
		return ""
	return s.substr(0, eq).strip_edges()


func _join_lines(lines):
	if lines.empty():
		return ""
	return PoolStringArray(lines).join("\n") + "\n"


func read_text(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var text = f.get_as_text()
	f.close()
	return text


func write_atomic(path, text):
	var dir = path.get_base_dir()
	if dir != "":
		var d = Directory.new()
		if not d.dir_exists(dir) and d.make_dir_recursive(dir) != OK:
			return "No se pudo crear la carpeta de configuración"
	var tmp = path + ".tmp"
	var f = File.new()
	if f.open(tmp, File.WRITE) != OK:
		return "No se pudo escribir la configuración"
	f.store_string(text)
	f.close()
	var d2 = Directory.new()
	if d2.rename(tmp, path) != OK:
		d2.remove(tmp)
		return "No se pudo guardar la configuración"
	return ""
