extends Reference

# Modelo puro (K11a) del estado compartido de Configuración.
#
# Vive en su propio proyecto Godot (`settings/`) y el shell lo carga desde
# `shell/settings_bridge.gd` leyendo el fuente con GDScript.set_source_code (mismo
# patrón que host.gd::sc): no hay `preload` entre proyectos.
#
# Reglas: sin I/O, sin procesos, sin dependencias del shell. Sólo normaliza,
# valida, serializa y calcula geometría. Todo lo visible usa lenguaje humano.

const VERSION = 1

# Paleta de acento (8 colores) + hex personalizado. El default reproduce el azul
# de foco actual del shell (RING_FOCUS = 0.55, 0.80, 1.0) para que sin configuración
# no cambie nada.
const ACCENT_PALETTE = [
	"#8ccdff", "#f7b733", "#4ec26e", "#ef6aa8",
	"#9b7ef0", "#e8615a", "#35c9c4", "#e6d24a",
]
const ACCENT_DEFAULT = "#8ccdff"

# Distribuciones XKB (`XKB_DEFAULT_LAYOUT`, ver session/keyboard.sh).
const KEYBOARDS = [
	{"id": "latam", "label": "Latinoamericana"},
	{"id": "es", "label": "Española"},
	{"id": "us", "label": "Estadounidense"},
	{"id": "gb", "label": "Británica"},
	{"id": "br", "label": "Brasileña"},
	{"id": "de", "label": "Alemana"},
	{"id": "fr", "label": "Francesa"},
]
const KEYBOARD_DEFAULT = "latam"

# Lista activa de Super+Espacio (GDTK_LAYOUTS del applet Teclado, shell/applet_keyboard.gd):
# elegidas en orden; la primera es XKB_DEFAULT_LAYOUT de la próxima sesión. El orden
# de los ids espeja KEYBOARDS y el LAYOUTS del applet.
const KEYBOARD_LAYOUTS_DEFAULT = ["latam", "es"]

# Idiomas para ~/.config/gdtk/locale (LANG). Lista corta.
const LOCALES = [
	{"id": "es_PE.UTF-8", "label": "Español (Perú)"},
	{"id": "es_ES.UTF-8", "label": "Español (España)"},
	{"id": "en_US.UTF-8", "label": "English (United States)"},
	{"id": "pt_BR.UTF-8", "label": "Português (Brasil)"},
]
const LOCALE_DEFAULT = "es_PE.UTF-8"

# Modos de fondo: rellenar, ajustar (contiene), centrar (tamaño real) o color sólido.
# "gradient" es el default interno (el degradado actual del Hogar); no se ofrece como
# opción de imagen pero se conserva para no cambiar el aspecto sin configuración.
const WALLPAPER_MODES = ["fill", "fit", "center", "solid"]
const WALLPAPER_MODE_LABELS = {
	"fill": "Rellenar",
	"fit": "Ajustar",
	"center": "Centrar",
	"solid": "Color sólido",
}
const WALLPAPER_DEFAULT_COLOR = "#0f1118"
const WALLPAPER_DEFAULT = {"mode": "gradient", "color": WALLPAPER_DEFAULT_COLOR, "path": ""}

# Táctil: dirección del desplazamiento de dos dedos. "Natural" (como en un móvil)
# queda activo por defecto; el valor vive en settings.json y lo aplica la sesión/sway
# (`session/input-settings.sh`) y la app en vivo (swaymsg).
const NATURAL_SCROLL_DEFAULT = true

# Apariencia del Frame y del Hogar (SPEC-sugar-frame-blocks).
#   bevel:  factor sobre el ancho de bisel automático. El ancho base ya escala con
#           la unidad de rejilla (y por lo tanto con la pantalla); este factor sólo
#           lo engrosa o adelgaza. 1.0 = el actual.
#   flat:   bloques planos: el relieve 3D aparece sólo al pasar el mouse o hundir.
#   emboss: íconos del sistema (Inicio/Vecindario) y burbujas del anillo con
#           relieve grabado dentro del bloque.
const BEVEL_MIN = 0.5
const BEVEL_MAX = 2.0
const BEVEL_DEFAULT = 1.0
const APPEARANCE_DEFAULT = {
	"bevel": 1.0,
	"flat": false,
	"emboss": true,
}

# Escala de la interfaz: factor sobre la escala automática (por resolución). También
# se exporta a los toolkits (GTK/GNOME con GDK_SCALE/GDK_DPI_SCALE, Qt, Firefox) para
# que las apps no queden con UI diminuta en pantallas densas. 1.0 = sin cambios.
const UI_SCALE_MIN = 0.75
const UI_SCALE_MAX = 2.0
const UI_SCALE_DEFAULT = 1.0
const UI_SCALE_CURSOR_BASE = 24.0

const CONTROL_MODES = ["off", "use_remote", "share_here"]
const CONTROL_MODE_LABELS = {
	"off": "Desactivado",
	"use_remote": "Usar el teclado y mouse de otro equipo",
	"share_here": "Permitir que otros equipos usen este teclado y mouse",
}
const CONTROL_DEFAULT = {
	"mode": "off",
	"host": "",
	"port": 24800,
	"auto": false,
	"name": "",
}
# Multi-monitor (SPEC-physical-multi-monitor): escritorio extendido en una sola
# ventana (span). `enabled` activa/desactiva; `primary` es el nombre de la salida
# principal ("" = automática: externa > interna); `order` es el orden izquierda->
# derecha de las demás salidas ([] = automático por posición física). El shell lo
# relee en vivo y reordena sway/el envolvente sin reiniciar.
const SPAN_DEFAULT = {"enabled": false, "primary": "", "order": []}
# Notificaciones (SPEC-notificaciones): interruptor global, transitorio, atención de
# foco, urgencia, tope de historial, modo de la columna y silencio. history_max entre
# 1 y 1000 para no dejar el store sin tope.
const NOTIF_HISTORY_MIN = 1
const NOTIF_HISTORY_MAX = 1000
const NOTIFICATIONS_DEFAULT = {
	"enabled": true,
	"toast_transitorio": true,
	"atencion_foco": true,
	"urgencia": true,
	"history_max": 100,
	"columna_modo": false,
	"silencio": false,
}
const HOST_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-_%[]"
const NAME_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"

const FIELDS = ["keyboard", "locale", "accent", "wallpaper", "natural_scroll", "deskflow", "appearance", "ui_scale", "span", "notifications"]

const HEX_CHARS = "0123456789abcdef"


# --- Defaults y normalización -------------------------------------------------

func defaults():
	return {
		"version": VERSION,
		"keyboard": KEYBOARD_DEFAULT,
		"keyboard_layouts": KEYBOARD_LAYOUTS_DEFAULT.duplicate(true),
		"locale": LOCALE_DEFAULT,
		"accent": ACCENT_DEFAULT,
		"wallpaper": WALLPAPER_DEFAULT.duplicate(true),
		"natural_scroll": NATURAL_SCROLL_DEFAULT,
		"deskflow": CONTROL_DEFAULT.duplicate(true),
		"appearance": APPEARANCE_DEFAULT.duplicate(true),
		"ui_scale": UI_SCALE_DEFAULT,
		"span": SPAN_DEFAULT.duplicate(true),
		"notifications": NOTIFICATIONS_DEFAULT.duplicate(true),
	}


# Une `data` con los defaults y valida campo por campo. Los campos desconocidos se
# conservan tal cual: la app y el shell comparten un solo archivo y otra página
# (p. ej. Pantallas, K11b) puede agregar datos sin que este modelo los borre.
func normalize(data):
	if typeof(data) != TYPE_DICTIONARY:
		data = {}
	var out = defaults()
	out["version"] = VERSION
	out["keyboard_layouts"] = _keyboard_layouts_in(data)
	out["keyboard"] = out["keyboard_layouts"][0]
	out["locale"] = locale_id(data.get("locale", ""))
	out["accent"] = accent_hex(data.get("accent", ""))
	out["wallpaper"] = wallpaper(data.get("wallpaper", {}))
	out["natural_scroll"] = nat_scroll(data.get("natural_scroll", null))
	out["deskflow"] = deskflow(data.get("deskflow", {}))
	out["appearance"] = appearance(data.get("appearance", {}))
	out["ui_scale"] = ui_scale_value(data.get("ui_scale", null))
	out["span"] = span(data.get("span", {}))
	out["notifications"] = notifications(data.get("notifications", {}))
	for k in data.keys():
		if not out.has(k):
			out[k] = data[k]
	return out


func keyboard_id(v):
	if v is String and has_option(KEYBOARDS, v):
		return v
	return KEYBOARD_DEFAULT


func locale_id(v):
	if v is String:
		if has_option(LOCALES, v):
			return v
		# Tolerar el idioma sin codificación ("es_PE" -> "es_PE.UTF-8").
		if has_option(LOCALES, v + ".UTF-8"):
			return v + ".UTF-8"
	return LOCALE_DEFAULT


func has_option(options, id):
	for o in options:
		if o.id == id:
			return true
	return false


# "#RRGGBB" o "RRGGBB" -> "#rrggbb"; cualquier otra cosa -> ACCENT_DEFAULT.
func accent_hex(v):
	var h = valid_hex(v)
	return h if h != "" else ACCENT_DEFAULT


# Normaliza un color hex de 6 dígitos; "" si no es válido. Acepta "#" opcional.
func valid_hex(v):
	if not (v is String):
		return ""
	var s = v.strip_edges().to_lower()
	if s.begins_with("#"):
		s = s.substr(1)
	if s.length() != 6:
		return ""
	for i in range(s.length()):
		if HEX_CHARS.find(s[i]) < 0:
			return ""
	return "#" + s


func color_of_hex(hex):
	var h = valid_hex(hex)
	if h == "":
		h = ACCENT_DEFAULT
	return Color(
		("0x" + h.substr(1, 2)).hex_to_int() / 255.0,
		("0x" + h.substr(3, 2)).hex_to_int() / 255.0,
		("0x" + h.substr(5, 2)).hex_to_int() / 255.0,
		1.0)


func wallpaper(w):
	if typeof(w) != TYPE_DICTIONARY:
		w = {}
	var out = WALLPAPER_DEFAULT.duplicate(true)
	var mode = w.get("mode", out.mode)
	if mode is String and (mode in WALLPAPER_MODES or mode == "gradient"):
		out.mode = mode
	out.color = valid_hex(w.get("color", ""))
	if out.color == "":
		out.color = WALLPAPER_DEFAULT_COLOR
	out.path = wallpaper_path(w.get("path", ""))
	return out


# Sólo rutas absolutas y limpias (sin NUL ni traversal ".."); el modelo no toca el
# disco, así que no puede verificar que exista. "" si no es una ruta aceptable.
func wallpaper_path(p):
	if not (p is String):
		return ""
	p = p.strip_edges().replace("\u0000", "")
	if p == "" or not p.is_abs_path():
		return ""
	for part in p.split("/", false):
		if part == "..":
			return ""
	return p


# Tipo efectivo de fondo: "gradient" (sin configurar), "solid" o "image".
func wallpaper_kind(w):
	var ww = wallpaper(w)
	if ww.mode in ["fill", "fit", "center"] and ww.path != "":
		return "image"
	return "solid"


# Bool tolerante para natural_scroll: acepta bool real y las formas de texto/número
# que pueda dejar un archivo escrito a mano; ante cualquier otra cosa, el default.
func nat_scroll(v):
	if v is bool:
		return v
	if v is String:
		var s = v.strip_edges().to_lower()
		if s in ["false", "0", "no", "off", ""]:
			return false
		if s in ["true", "1", "yes", "on"]:
			return true
		return NATURAL_SCROLL_DEFAULT
	if v is float or v is int:
		return int(v) != 0
	return NATURAL_SCROLL_DEFAULT


func deskflow(v):
	if typeof(v) != TYPE_DICTIONARY:
		v = {}
	var out = CONTROL_DEFAULT.duplicate(true)
	var mode = String(v.get("mode", out.mode)).strip_edges()
	if CONTROL_MODES.has(mode):
		out.mode = mode
	out.host = host_name(v.get("host", ""))
	out.port = tcp_port(v.get("port", out.port))
	out.auto = bool_value(v.get("auto", out.auto), false)
	out.name = screen_name(v.get("name", ""))
	if out.mode == "use_remote" and out.host == "":
		out.mode = "off"
	return out


func host_name(v):
	if not (v is String):
		return ""
	var s = v.strip_edges()
	if s == "" or s.length() > 255:
		return ""
	for i in range(s.length()):
		if HOST_CHARS.find(s.substr(i, 1)) < 0:
			return ""
	return s


func tcp_port(v):
	var p = int(v)
	return p if p >= 1 and p <= 65535 else int(CONTROL_DEFAULT.port)


func screen_name(v):
	if not (v is String):
		return ""
	var s = v.strip_edges()
	if s == "" or s.length() > 63 or s.begins_with(".") or s.begins_with("-") \
			or s.ends_with(".") or s.ends_with("-"):
		return ""
	for i in range(s.length()):
		if NAME_CHARS.find(s.substr(i, 1)) < 0:
			return ""
	return s


func bool_value(v, fallback):
	if v is bool:
		return v
	if v is String:
		var s = v.strip_edges().to_lower()
		if s in ["true", "1", "yes", "on"]:
			return true
		if s in ["false", "0", "no", "off", ""]:
			return false
	if v is float or v is int:
		return int(v) != 0
	return bool(fallback)


# Apariencia del Frame/Hogar normalizada. `bevel` es un factor (0.5..2.0) sobre el
# bisel automático; `flat` y `emboss` son booleanos tolerantes.
func appearance(a):
	if typeof(a) != TYPE_DICTIONARY:
		a = {}
	var out = APPEARANCE_DEFAULT.duplicate(true)
	out.bevel = bevel_scale(a.get("bevel", out.bevel))
	out.flat = bool_value(a.get("flat", out.flat), out.flat)
	out.emboss = bool_value(a.get("emboss", out.emboss), out.emboss)
	return out


func bevel_scale(v):
	if not (v is float or v is int or v is String):
		return BEVEL_DEFAULT
	var f = float(v)
	if f <= 0.0:
		return BEVEL_DEFAULT
	return clamp(f, BEVEL_MIN, BEVEL_MAX)


# Factor de escala de UI normalizado (0.75..2.0). Un valor inválido cae al default.
func ui_scale_value(v):
	if not (v is float or v is int or v is String):
		return UI_SCALE_DEFAULT
	var f = float(v)
	if f <= 0.0:
		return UI_SCALE_DEFAULT
	return clamp(f, UI_SCALE_MIN, UI_SCALE_MAX)


# Escritorio extendido multi-monitor normalizado. `enabled` es tolerante a textos
# ("on"/"1"); `primary` es un nombre de salida válido (ver screen_name) o "" (auto);
# `order` es una lista de nombres de salida sin duplicados.
func span(v):
	if typeof(v) != TYPE_DICTIONARY:
		v = {}
	var out = SPAN_DEFAULT.duplicate(true)
	out.enabled = bool_value(v.get("enabled", out.enabled), out.enabled)
	out.primary = screen_name(v.get("primary", ""))
	out.order = span_order(v.get("order", []))
	return out


func span_order(list):
	var out = []
	if typeof(list) != TYPE_ARRAY:
		return out
	for item in list:
		var n = screen_name(item)
		if n != "" and not out.has(n):
			out.append(n)
	return out


# Ajustes del sistema de notificaciones normalizados (SPEC-notificaciones). Los
# booleanos son tolerantes ("on"/"1"); `history_max` se acota a [1, 1000].
func notifications(v):
	if typeof(v) != TYPE_DICTIONARY:
		v = {}
	var out = NOTIFICATIONS_DEFAULT.duplicate(true)
	out.enabled = bool_value(v.get("enabled", out.enabled), out.enabled)
	out.toast_transitorio = bool_value(v.get("toast_transitorio", out.toast_transitorio), out.toast_transitorio)
	out.atencion_foco = bool_value(v.get("atencion_foco", out.atencion_foco), out.atencion_foco)
	out.urgencia = bool_value(v.get("urgencia", out.urgencia), out.urgencia)
	out.columna_modo = bool_value(v.get("columna_modo", out.columna_modo), out.columna_modo)
	out.silencio = bool_value(v.get("silencio", out.silencio), out.silencio)
	out.history_max = notif_history(v.get("history_max", out.history_max))
	return out


func notif_history(v):
	var n = int(v)
	if n < NOTIF_HISTORY_MIN:
		n = NOTIF_HISTORY_MIN
	if n > NOTIF_HISTORY_MAX:
		n = NOTIF_HISTORY_MAX
	return n


# Variables de entorno para que el resto del escritorio escale igual que el shell.
# GTK/GNOME usan GDK_SCALE (entero) + GDK_DPI_SCALE (fracción); Qt y el cursor sus
# propias variables. Puro y testeable.
func ui_scale_env(factor):
	var f = ui_scale_value(factor)
	var gdk = floor(f)
	if gdk < 1.0:
		gdk = 1.0
	var dpi = f / gdk
	return {
		"GDK_SCALE": str(int(gdk)),
		"GDK_DPI_SCALE": str(dpi),
		"QT_SCALE_FACTOR": str(f),
		"QT_AUTO_SCREEN_SCALE_FACTOR": "0",
		"XCURSOR_SIZE": str(int(round(UI_SCALE_CURSOR_BASE * f))),
	}


# Argumentos de `swaymsg` para fijar la dirección del scroll. El scroll natural no
# es sólo de touchpad: también aplica al mouse/TrackPoint (`type:pointer`), así que
# se devuelven los dos comandos. Puro (no ejecuta nada): lo usan la app, el shell
# (en vivo) y los tests.
func natural_scroll_cmds(value):
	var v = "enabled" if nat_scroll(value) else "disabled"
	return [
		["input", "type:touchpad", "natural_scroll", v],
		["input", "type:pointer", "natural_scroll", v],
	]


# Compatibilidad: primer comando (touchpad).
func natural_scroll_cmd(value):
	return natural_scroll_cmds(value)[0]


# --- Serialización ------------------------------------------------------------

func to_json(d):
	return JSON.print(normalize(d), "  ")


func parse(text):
	var data = null
	if text is String and text.strip_edges() != "":
		data = JSON.parse(text).result
	return normalize(data)


# --- Archivos de sesión (session/keyboard.sh y locale) ------------------------

# Lista elegida del data: ids válidos y sin repetir, en el orden dado. Los archivos
# viejos (sólo "keyboard") caen a [keyboard]; nada válido cae al par por defecto.
func keyboard_layouts_list(v, fallback):
	if typeof(v) != TYPE_ARRAY:
		return fallback.duplicate(true)
	var out = []
	for id in v:
		if typeof(id) == TYPE_STRING and has_option(KEYBOARDS, id) and not out.has(id):
			out.append(id)
	return out if not out.empty() else fallback.duplicate(true)


func _keyboard_layouts_in(data):
	if typeof(data) == TYPE_DICTIONARY:
		var ids = keyboard_layouts_list(data.get("keyboard_layouts", null), [])
		if not ids.empty():
			return ids
		# Archivo viejo sin GDTK_LAYOUTS: el teclado vigente es la lista entera.
		if data.has("keyboard"):
			return [keyboard_id(data.get("keyboard", ""))]
	return defaults()["keyboard_layouts"].duplicate(true)


# `session/keyboard.sh` sourcea este archivo: asigna y exporta XKB_DEFAULT_*.
# GDTK_LAYOUTS es la lista que rota Super+Espacio (el applet Teclado la lee).
func keyboard_file_content(keyboard, layouts = []):
	var ids = keyboard_layouts_list(layouts, [])
	var first = ids[0] if not ids.empty() else keyboard_id(keyboard)
	var text = "XKB_DEFAULT_LAYOUT=" + first + "\n"
	if not ids.empty():
		text += "GDTK_LAYOUTS=" + PoolStringArray(ids).join(",") + "\n"
	return text


# LANG para la próxima sesión.
func locale_file_content(locale):
	return "LANG=" + locale_id(locale) + "\n"


# Los cambios de teclado e idioma no son en vivo: la UI avisa que aplican al
# reiniciar. Acento y fondo sí se aplican al instante en el shell.
func is_live(field):
	return field == "accent" or field == "wallpaper" or field == "natural_scroll" \
		or field == "deskflow" or field == "appearance" or field == "ui_scale" \
		or field == "span" or field == "notifications"


func restart_notice(field):
	if is_live(field):
		return ""
	return "Se aplica al reiniciar la sesión"


# --- Geometría del fondo ------------------------------------------------------

# Rect de dibujo de la imagen dentro del viewport según el modo. Para "solid" y
# "gradient" (o imagen ausente) devuelve el viewport completo. Pura: no carga nada.
func wallpaper_rect(mode, image_size, viewport):
	if mode == "center":
		return Rect2((viewport - image_size) * 0.5, image_size)
	if mode in ["fill", "fit"] and image_size.x > 0.0 and image_size.y > 0.0:
		var sx = viewport.x / image_size.x
		var sy = viewport.y / image_size.y
		var s = max(sx, sy) if mode == "fill" else min(sx, sy)
		var size = image_size * s
		return Rect2((viewport - size) * 0.5, size)
	return Rect2(Vector2.ZERO, viewport)


# --- Utilidades ---------------------------------------------------------------

func label_of(options, id):
	for o in options:
		if o.id == id:
			return o.label
	return id


func accent_color(d):
	return color_of_hex(normalize(d).accent)


func selftest():
	var d = defaults()
	assert(d.keyboard == KEYBOARD_DEFAULT)
	assert(accent_hex("AABBCC") == "#aabbcc")
	assert(accent_hex("#zz0011") == ACCENT_DEFAULT)
	assert(accent_hex("abc") == ACCENT_DEFAULT)
	assert(valid_hex("#8CCDFF") == "#8ccdff")
	assert(keyboard_id("de") == "de")
	assert(keyboard_id("nope") == KEYBOARD_DEFAULT)
	assert(locale_id("es_PE") == "es_PE.UTF-8")
	assert(locale_id("xx_YY") == LOCALE_DEFAULT)
	var n = normalize({"accent": "#4EC26E", "keyboard": "us", "screens": [1, 2]})
	assert(n.accent == "#4ec26e")
	assert(n.screens == [1, 2])
	assert(n.wallpaper.mode == "gradient")
	assert(wallpaper({"mode": "nope"}).mode == "gradient")
	assert(wallpaper({"mode": "fill", "path": "~/x.png"}).path == "")
	assert(wallpaper({"mode": "fill", "path": "/tmp/x.png"}).path == "/tmp/x.png")
	assert(wallpaper_kind({"mode": "fill", "path": "/tmp/x.png"}) == "image")
	assert(wallpaper_kind({"mode": "fill", "path": ""}) == "solid")
	assert(keyboard_file_content("es") == "XKB_DEFAULT_LAYOUT=es\n")
	assert(keyboard_file_content("latam", ["latam", "es"]) \
		== "XKB_DEFAULT_LAYOUT=latam\nGDTK_LAYOUTS=latam,es\n")
	assert(keyboard_layouts_list(["latam", "es", "latam", "nope"], []).size() == 2)
	assert(keyboard_layouts_list("basura", []).empty())
	assert(normalize({"keyboard": "de"}).keyboard_layouts == ["de"])
	assert(normalize({"keyboard_layouts": ["fr", "de", "fr"]}).keyboard == "fr")
	assert(locale_file_content("en_US") == "LANG=en_US.UTF-8\n")
	assert(is_live("accent") and is_live("wallpaper") and is_live("deskflow"))
	assert(not is_live("keyboard") and not is_live("locale"))
	assert(d.natural_scroll == NATURAL_SCROLL_DEFAULT)
	assert(nat_scroll("false") == false and nat_scroll("on") == true)
	assert(nat_scroll(0) == false and nat_scroll(1) == true)
	assert(nat_scroll("cosa") == NATURAL_SCROLL_DEFAULT)
	assert(d.deskflow.mode == "off" and d.deskflow.port == 24800 and not d.deskflow.auto)
	var df = deskflow({"mode": "use_remote", "host": "bastion.local", "port": "24801",
		"auto": "on", "name": "tengu"})
	assert(df.mode == "use_remote" and df.host == "bastion.local" and df.port == 24801
		and df.auto and df.name == "tengu")
	assert(deskflow({"mode": "use_remote", "host": ""}).mode == "off")
	assert(deskflow({"mode": "share_here", "host": "bad host", "port": 70000}).port == 24800)
	assert(host_name("bad host") == "" and host_name("fe80::1") == "fe80::1")
	assert(screen_name("bad name") == "" and screen_name("bastion") == "bastion")
	assert(natural_scroll_cmd(false) == ["input", "type:touchpad", "natural_scroll", "disabled"])
	assert(natural_scroll_cmd(true) == ["input", "type:touchpad", "natural_scroll", "enabled"])
	var a0 = appearance({})
	assert(a0.bevel == BEVEL_DEFAULT and not a0.flat and a0.emboss)
	var a1 = appearance({"bevel": "1.5", "flat": "on", "emboss": "off"})
	assert(a1.bevel == 1.5 and a1.flat and not a1.emboss)
	assert(appearance({"bevel": 9.0}).bevel == BEVEL_MAX)
	assert(appearance({"bevel": 0.01}).bevel == BEVEL_MIN)
	assert(appearance({"bevel": "no"}).bevel == BEVEL_DEFAULT)
	assert(is_live("appearance"))
	assert(ui_scale_value(null) == UI_SCALE_DEFAULT and ui_scale_value(0.0) == UI_SCALE_DEFAULT)
	assert(ui_scale_value(9.0) == UI_SCALE_MAX and ui_scale_value(0.1) == UI_SCALE_MIN)
	var env = ui_scale_env(1.25)
	assert(env.GDK_SCALE == "1" and env.GDK_DPI_SCALE == "1.25" and env.QT_SCALE_FACTOR == "1.25")
	assert(env.XCURSOR_SIZE == "30")
	var env2 = ui_scale_env(2.0)
	assert(env2.GDK_SCALE == "2" and env2.GDK_DPI_SCALE == "1")
	assert(is_live("ui_scale"))
	var nsc = natural_scroll_cmds(false)
	assert(nsc.size() == 2 and nsc[0][1] == "type:touchpad" and nsc[1][1] == "type:pointer"
		and nsc[1][3] == "disabled", "scroll natural también para pointer")
	var r = wallpaper_rect("fill", Vector2(100, 50), Vector2(200, 200))
	assert(r.size == Vector2(400, 200))
	assert(r.position == Vector2(-100, 0))
	var f = wallpaper_rect("fit", Vector2(100, 50), Vector2(200, 200))
	assert(f.size == Vector2(200, 100))
	assert(f.position == Vector2(0, 50))
	var c = wallpaper_rect("center", Vector2(80, 40), Vector2(200, 200))
	assert(c.position == Vector2(60, 80))
	var s = wallpaper_rect("solid", Vector2(80, 40), Vector2(200, 200))
	assert(s == Rect2(0, 0, 200, 200))
	var sp0 = span({})
	assert(not sp0.enabled and sp0.primary == "" and sp0.order.empty())
	var sp1 = span({"enabled": "on", "primary": "DP-1", "order": ["HDMI-A-1", "DP-1", "bad name"]})
	assert(sp1.enabled and sp1.primary == "DP-1")
	assert(sp1.order == ["HDMI-A-1", "DP-1"], "orden sin duplicados ni nombres inválidos")
	assert(span({"enabled": "no"}).enabled == false)
	assert(is_live("span"))
	var nf0 = notifications({})
	assert(nf0.enabled and nf0.toast_transitorio and nf0.history_max == 100 and not nf0.silencio)
	var nf1 = notifications({"enabled": "off", "silencio": "on", "history_max": 5000, "urgencia": "no"})
	assert(not nf1.enabled and nf1.silencio and nf1.history_max == NOTIF_HISTORY_MAX and not nf1.urgencia)
	assert(notifications({"history_max": 0}).history_max == NOTIF_HISTORY_MIN)
	assert(normalize({}).notifications.history_max == 100)
	assert(is_live("notifications"))
	print("settings_model selftest ok")
