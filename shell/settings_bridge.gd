extends Reference

# Puente de Configuración (K11a) del lado del shell.
#
# Lee `~/.config/gdtk/settings.json` (escrito por la app `settings/`) sin bloquear
# el frame: la lectura y la carga de la imagen de fondo corren en Threads de un solo
# uso y el hilo principal sólo aplica el snapshot. TTL de relectura ~3 s.
#
# El modelo puro vive en `settings/settings_model.gd`, otro proyecto Godot; acá se
# compila desde el fuente (mismo patrón que host.gd::sc), sin `preload` entre
# proyectos. El shell sólo consume `accent`, `wallpaper_*` y `settings`.

const TTL_MS = 3000

var model = null
var settings = {}
var revision = 0
var accent = Color(0.55, 0.80, 1.0, 1.0)  # azul de foco actual, por si aún no hay archivo

var _last_check = -1000000
var _io_thread = null
var _io_state = {}
var _io_mutex = Mutex.new()

var _wall_thread = null
var _wall_state = {}
var _wall_mutex = Mutex.new()
var _wall_key = ""
var _wall_loading = false
var _tex = null
var _img_size = Vector2.ZERO


func _init():
	model = _load_model()
	if model == null:
		printerr("settings_bridge: no se pudo cargar settings/settings_model.gd")
	else:
		settings = model.defaults()


# --- Rutas --------------------------------------------------------------------

func settings_dir():
	var root = ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	return root.plus_file("settings")


func config_dir():
	var xdg = OS.get_environment("XDG_CONFIG_HOME")
	if xdg != "":
		return xdg.plus_file("gdtk")
	return OS.get_environment("HOME").plus_file(".config").plus_file("gdtk")


# Permite apuntar a otro archivo en pruebas o pilotos (GDTK_SETTINGS).
func settings_path():
	var override = OS.get_environment("GDTK_SETTINGS")
	if override != "":
		return override
	return config_dir().plus_file("settings.json")


# Argumentos para lanzar la app de Configuración como cualquier actividad wayland.
# `page` (opcional) abre directo una página concreta (`--page <id>`).
func launch_argv(page = ""):
	var argv = [OS.get_executable_path(), "--path", settings_dir()]
	if String(page) != "":
		argv.append("--page")
		argv.append(String(page))
	return argv


# --- Lectura no bloqueante ----------------------------------------------------

# Reaplica de inmediato, sin Thread (arranque o pruebas).
func reload_now():
	if model == null:
		return
	_apply_text(_read_text(settings_path()))


# Espera los Threads de un solo uso antes de descartar el puente (recarga/cierre
# del shell): no dejar hilos vivos mutando un estado ya liberado.
func stop():
	if _io_thread != null:
		_io_thread.wait_to_finish()
		_io_thread = null
	if _wall_thread != null:
		_wall_thread.wait_to_finish()
		_wall_thread = null


func poll():
	if model == null:
		return
	var now = OS.get_ticks_msec()
	_reap_io()
	_reap_wall()
	if now - _last_check >= TTL_MS and _io_thread == null:
		_last_check = now
		_start_io()
	_want_wallpaper()


func _start_io():
	var path = settings_path()
	var state = {"done": false, "text": ""}
	_io_state = state
	_io_thread = Thread.new()
	_io_thread.start(self, "_io_work", {"path": path, "state": state})


func _io_work(userdata):
	_mutex_set(_io_mutex, userdata.state, "text", _read_text(userdata.path))


func _read_text(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var text = f.get_as_text()
	f.close()
	return text


func _reap_io():
	if _io_thread == null:
		return
	var done = false
	_io_mutex.lock()
	done = _io_state.get("done", false)
	_io_mutex.unlock()
	if not done:
		return
	_io_thread.wait_to_finish()
	_io_thread = null
	_apply_text(String(_io_state.get("text", "")))


func _mutex_set(mutex, state, key, value):
	mutex.lock()
	state[key] = value
	state["done"] = true
	mutex.unlock()


func _apply_text(text):
	var t = String(text)
	if t.strip_edges() == "":
		return  # lectura vacía/fallida: conservar la configuración vigente
	var next = model.parse(t)
	if str(next) == str(settings):
		return
	settings = next
	revision += 1
	accent = model.color_of_hex(settings.get("accent", ""))
	_want_wallpaper()


# --- Escritura atómica (tmp + rename) ----------------------------------------

# Devuelve "" si pudo, o el mensaje de error. Un solo archivo compartido evita
# lecturas a medias; el tmp vive junto al destino (mismo sistema de archivos).
func write_atomic(path, text):
	var dir = path.get_base_dir()
	if dir != "":
		var d = Directory.new()
		if not d.dir_exists(dir) and d.make_dir_recursive(dir) != OK:
			return "no se pudo crear " + dir
	var tmp = path + ".tmp"
	var f = File.new()
	if f.open(tmp, File.WRITE) != OK:
		return "no se pudo escribir " + tmp
	f.store_string(text)
	f.close()
	var d2 = Directory.new()
	if d2.rename(tmp, path) != OK:
		d2.remove(tmp)
		return "no se pudo renombrar " + tmp
	return ""


# --- Fondo de pantalla --------------------------------------------------------

func wallpaper_kind():
	if model == null:
		return "solid"
	return model.wallpaper_kind(settings.get("wallpaper", {}))


# Apariencia normalizada del Frame/Hogar (bisel, plano, relieve) para el shell.
func appearance():
	if model == null:
		return {"bevel": 1.0, "flat": false, "emboss": true}
	return model.appearance(settings.get("appearance", {}))


# Escala de UI normalizada (factor sobre la automática por resolución).
func ui_scale():
	if model == null:
		return 1.0
	return model.ui_scale_value(settings.get("ui_scale", 1.0))


# Escritorio extendido multi-monitor (SPEC-physical-multi-monitor): enabled,
# primary (nombre de salida o "") y order (izquierda->derecha de las demás).
func span():
	if model == null or not model.has_method("span"):
		return {"enabled": false, "primary": "", "order": []}
	return model.span(settings.get("span", {}))


# Ajustes del sistema de notificaciones (SPEC-notificaciones). Defaults sanos si el
# modelo es viejo o el archivo no trae la clave.
func notifications():
	if model == null or not model.has_method("notifications"):
		return {
			"enabled": true, "toast_transitorio": true, "atencion_foco": true,
			"urgencia": true, "history_max": 100, "columna_modo": false, "silencio": false,
		}
	return model.notifications(settings.get("notifications", {}))


func has_wallpaper_image():
	return _tex != null


func wallpaper_texture():
	return _tex


func wallpaper_rect(viewport):
	if model == null:
		return Rect2(Vector2.ZERO, viewport)
	return model.wallpaper_rect(settings.get("wallpaper", {}).get("mode", "solid"), _img_size, viewport)


func _want_wallpaper():
	if model == null:
		return
	var w = settings.get("wallpaper", {})
	if model.wallpaper_kind(w) != "image":
		_wall_key = ""
		_tex = null
		_img_size = Vector2.ZERO
		return
	var key = String(w.path) + "|" + String(w.mode)
	if key == _wall_key or _wall_loading:
		return
	_wall_key = key
	_start_wall(String(w.path), key)


func _start_wall(path, key):
	var state = {"done": false, "image": null, "key": key}
	_wall_state = state
	_wall_loading = true
	_wall_thread = Thread.new()
	_wall_thread.start(self, "_wall_work", {"path": path, "state": state})


func _wall_work(userdata):
	var img = Image.new()
	if img.load(userdata.path) != OK:
		img = null
	_wall_mutex.lock()
	userdata.state["image"] = img
	userdata.state["done"] = true
	_wall_mutex.unlock()


func _reap_wall():
	if _wall_thread == null:
		return
	var done = false
	_wall_mutex.lock()
	done = _wall_state.get("done", false)
	_wall_mutex.unlock()
	if not done:
		return
	_wall_thread.wait_to_finish()
	_wall_thread = null
	_wall_loading = false
	var img = _wall_state.get("image", null)
	if img != null and img.get_width() > 0:
		var tex = ImageTexture.new()
		tex.create_from_image(img, Texture.FLAG_FILTER)
		_tex = tex
		_img_size = Vector2(img.get_width(), img.get_height())
	else:
		_tex = null
		_img_size = Vector2.ZERO
	revision += 1


func _load_model():
	var path = settings_dir().plus_file("settings_model.gd")
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return null
	var src = f.get_as_text()
	f.close()
	var g = GDScript.new()
	g.set_source_code(src)
	if g.reload() != OK:
		return null
	return g.new()
