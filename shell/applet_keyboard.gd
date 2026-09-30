extends Reference

# Applet Teclado del Frame (SPEC-sugar-frame-applets.md): distribución de teclado.
# Módulo autocontenido: no usa shell, no crea providers ni abre ventanas; el Frame
# conecta su UI con choose(layout). No aplica el mapa en vivo: el keymap de los
# clientes del compositor embebido y del input remoto se compila al arrancar, así que
# la elección sólo rige la PRÓXIMA sesión. se consulta como máximo cada PERIOD_MS
# (~5 s) y sólo se lanza localectl cuando no hay XKB_DEFAULT_LAYOUT en el entorno.
#
# Fuentes:
#   - sesión activa: XKB_DEFAULT_LAYOUT del entorno (lo que exporta session/keyboard.sh);
#     si falta, localectl status con timeout corto.
#   - próxima sesión: ${XDG_CONFIG_HOME:-$HOME/.config}/gdtk/keyboard. Se lee y se
#     escribe como texto, sin evaluarlo (nunca `.` ni eval). choose() sólo escribe
#     líneas de variables con caracteres seguros para que keyboard.sh pueda sourcearlas.

const PERIOD_MS = 5000
const TIMEOUT_S = "2"

# Ids exactos que ofrece el selector (frame.gd) y su etiqueta corta/larga. La etiqueta
# corta es la que cabe en el bloque de 44 px; la larga va al tooltip.
const LAYOUTS = {
	"es": {"label": "ES", "name": "Español (ES)"},
	"latam": {"label": "LAT", "name": "Latinoamericano (LAT)"},
	"us": {"label": "US", "name": "Inglés (US)"},
}

# activo | cambiando | error | sin_dato
var state = "sin_dato"
var value = "sin dato"   # texto muy corto para el bloque (ES, LAT, US)
var detail = ""          # texto para tooltip; dice si requiere reiniciar la sesión

var _timeout = ""
var _localectl = ""
var _probed = false
var _last_ms = -PERIOD_MS
var _last_value = ""     # último valor activo real, para no fingir un estado en error
var _env_layout = ""
var _env_variant = ""
var _env_model = ""
var _env_options = ""
var _config_exists = false
var _config_layout = ""
var _config_variant = ""
var _config_model = ""
var _config_options = ""


# Lee la configuración activa (entorno o localectl) y la guardada para la próxima
# sesión. Devuelve true si cambió state, value o detail (hay algo que redibujar).
func refresh(force := false):
	var now = OS.get_ticks_msec()
	if not force and now - _last_ms < PERIOD_MS:
		return false
	_last_ms = now
	_probe()

	_env_layout = OS.get_environment("XKB_DEFAULT_LAYOUT").strip_edges()
	_env_variant = OS.get_environment("XKB_DEFAULT_VARIANT").strip_edges()
	_env_model = OS.get_environment("XKB_DEFAULT_MODEL").strip_edges()
	_env_options = OS.get_environment("XKB_DEFAULT_OPTIONS").strip_edges()
	_read_config()

	var active = _env_layout
	if active == "":
		if _localectl == "":
			# Sin entorno y sin localectl no hay de dónde leer: sin_dato, no se inventa.
			if _config_layout != "":
				var only_pending = "%s elegida para la próxima sesión. No se pudo leer la distribución actual (falta localectl). El cambio requiere reiniciar la sesión." % _name(_config_layout)
				return _apply("cambiando", _label(_config_layout), only_pending)
			return _apply("sin_dato", "sin dato",
				"sin XKB_DEFAULT_LAYOUT en el entorno y localectl no está instalado")
		var read = _localectl_layout()
		if read["error"] != "":
			return _apply("error", _error_value(), read["error"])
		active = read["layout"]

	if active == "":
		# X11 Layout ausente en localectl: no se inventa una distribución.
		if _config_layout != "":
			var pending_detail = "%s elegida para la próxima sesión. No se pudo leer la distribución actual. El cambio requiere reiniciar la sesión." % _name(_config_layout)
			return _apply("cambiando", _label(_config_layout), pending_detail)
		return _apply("sin_dato", "sin dato",
			"sin distribución X11 configurada (ni XKB_DEFAULT_LAYOUT ni localectl)")

	_last_value = _label(active)
	var pending = _config_layout
	if pending != "" and pending != active:
		# La sesión sigue con `active`; el archivo rige la próxima. No se afirma cambio vivo.
		var pending_detail = "Ahora: %s. Próxima sesión: %s. El cambio no se aplica en vivo: requiere reiniciar la sesión." % [_name(active), _name(pending)]
		return _apply("cambiando", _label(pending), pending_detail)
	return _apply("activo", _label(active),
		"Distribución %s activa en esta sesión. Cambiarla requiere reiniciar la sesión." % _name(active))


# Elige la distribución para la próxima sesión. Sólo acepta ids exactos (es, latam, us);
# guarda el archivo de forma atómica conservando las opciones XKB actuales sólo si tienen
# caracteres seguros. No evalúa ni aplica nada en vivo. Devuelve true si escribió.
func choose(layout):
	if not LAYOUTS.has(layout):
		detail = "Distribución no válida: %s (sólo es, latam, us)." % str(layout)
		return false
	var path = _config_path()
	if path == "":
		return _apply("error", _error_value(),
			"no se pudo ubicar la configuración: falta HOME/XDG_CONFIG_HOME")
	_read_config()
	# Opciones y modelo actuales: primero el entorno (lo que se aplicó), luego el archivo
	# previo. Sólo pasan valores con caracteres seguros; si no, quedan vacíos.
	var env_model = OS.get_environment("XKB_DEFAULT_MODEL").strip_edges()
	var env_options = OS.get_environment("XKB_DEFAULT_OPTIONS").strip_edges()
	var model = _safe_xkb(env_model if env_model != "" else _config_model)
	var options = _safe_xkb(env_options if env_options != "" else _config_options)
	var body = "XKB_DEFAULT_LAYOUT=%s\nXKB_DEFAULT_VARIANT=\nXKB_DEFAULT_MODEL=%s\nXKB_DEFAULT_OPTIONS=%s\n" \
		% [layout, model, options]
	var dir = Directory.new()
	dir.make_dir_recursive(path.get_base_dir())
	if not dir.dir_exists(path.get_base_dir()):
		return _apply("error", _error_value(), "no se pudo crear la carpeta de configuración")
	var tmp = path + ".tmp"
	var w = File.new()
	if w.open(tmp, File.WRITE) != OK:
		return _apply("error", _error_value(), "no se pudo escribir la configuración")
	w.store_string(body)
	w.close()
	if dir.rename(tmp, path) != OK:
		return _apply("error", _error_value(), "no se pudo guardar la distribución (rename)")
	_config_exists = true
	_config_layout = layout
	_config_variant = ""
	_config_model = model
	_config_options = options
	# Refresca para mostrar el pendiente, sin afirmar un cambio instantáneo.
	refresh(true)
	return true


# Consulta localectl status una vez (sólo si falta el entorno). Devuelve
# {"layout": "...", "error": "..."} con error vacío si pudo leer; layout vacío es válido
# (X11 Layout ausente). Nunca lanza procesos si falta localectl.
func _localectl_layout():
	if _localectl == "":
		return {"layout": "", "error": "no se pudo leer el teclado: falta localectl y XKB_DEFAULT_LAYOUT"}
	var out = []
	var code = 0
	if _timeout != "":
		code = OS.execute(_timeout, [TIMEOUT_S, _localectl, "status"], true, out, true)
	else:
		code = OS.execute(_localectl, ["status"], true, out, true)
	if code == 124:
		return {"layout": "", "error": "localectl no respondió (timeout)"}
	if code != 0:
		return {"layout": "", "error": "localectl falló (código %d)" % code}
	var text = ""
	for line in out:
		text += String(line) + "\n"
	var layout = ""
	for raw in text.split("\n", false):
		var l = raw.strip_edges()
		if l.begins_with("X11 Layout:"):
			layout = l.substr("X11 Layout:".length()).strip_edges()
	return {"layout": layout, "error": ""}


# Lee ~/.config/gdtk/keyboard como texto (sin evaluar) y guarda en _config_* sólo los
# valores con caracteres seguros. Un valor inseguro o ausente queda vacío.
func _read_config():
	_config_exists = false
	_config_layout = ""
	_config_variant = ""
	_config_model = ""
	_config_options = ""
	var path = _config_path()
	if path == "":
		return
	var f = File.new()
	if not f.file_exists(path) or f.open(path, File.READ) != OK:
		return
	var text = f.get_as_text()
	f.close()
	_config_exists = true
	for raw in text.split("\n", false):
		var l = raw.strip_edges()
		if l == "" or l.begins_with("#"):
			continue
		var eq = l.find("=")
		if eq < 0:
			continue
		var key = l.substr(0, eq).strip_edges()
		var val = _safe_xkb(l.substr(eq + 1))
		match key:
			"XKB_DEFAULT_LAYOUT":
				_config_layout = val
			"XKB_DEFAULT_VARIANT":
				_config_variant = val
			"XKB_DEFAULT_MODEL":
				_config_model = val
			"XKB_DEFAULT_OPTIONS":
				_config_options = val


# Ruta del archivo que lee session/keyboard.sh, o "" si no hay HOME ni XDG_CONFIG_HOME.
func _config_path():
	var base = OS.get_environment("XDG_CONFIG_HOME").strip_edges()
	if base == "":
		var home = OS.get_environment("HOME").strip_edges()
		if home == "":
			return ""
		base = home + "/.config"
	return base + "/gdtk/keyboard"


# Valor XKB seguro para escribir y sourcear sin comillas: sólo letras, dígitos y los
# separadores de la sintaxis XKB (_ - , : + .). Cualquier otro carácter (espacio,
# comillas, $, `, ;, \...) invalida el valor y se devuelve "" (se deja vacío).
func _safe_xkb(text):
	var s = String(text).strip_edges()
	if s == "":
		return ""
	for i in range(s.length()):
		var c = s[i]
		if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") \
				or c == "_" or c == "-" or c == "," or c == ":" or c == "+" or c == "."):
			return ""
	return s


# Etiqueta corta de un layout (ES/LAT/US); un layout desconocido se abrevia en 4 letras.
func _label(layout):
	if LAYOUTS.has(layout):
		return LAYOUTS[layout]["label"]
	return layout.to_upper().substr(0, 4)


# Nombre largo de un layout para el tooltip.
func _name(layout):
	if LAYOUTS.has(layout):
		return LAYOUTS[layout]["name"]
	return layout


# Resuelve timeout y localectl una sola vez, buscándolos en $PATH sin lanzar procesos.
func _probe():
	if _probed:
		return
	_probed = true
	_timeout = _which("timeout")
	_localectl = _which("localectl")


# Ruta absoluta de un ejecutable en $PATH, o "" si no está. Sólo File, sin shell.
func _which(prog):
	for d in OS.get_environment("PATH").split(":", false):
		if d != "" and File.new().file_exists(d + "/" + prog):
			return d + "/" + prog
	return ""


# Valor textual a mostrar en error: el último activo real, o genérico si nunca hubo lectura.
func _error_value():
	return _last_value if _last_value != "" else "error"


# Fija los tres campos y dice si alguno cambió.
func _apply(new_state, new_value, new_detail):
	var changed = state != new_state or value != new_value or detail != new_detail
	state = new_state
	value = new_value
	detail = new_detail
	return changed
