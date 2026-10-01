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
	var normalized = model.normalize(settings)
	var err = write_atomic(settings_path(), model.to_json(normalized))
	if err != "":
		return err
	err = write_atomic(tree_dir().plus_file("keyboard"), model.keyboard_file_content(normalized.keyboard))
	if err != "":
		return err
	return write_atomic(tree_dir().plus_file("locale"), model.locale_file_content(normalized.locale))


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
