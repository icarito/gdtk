extends Reference

# Modelo puro (K11a) del estado compartido de Configuración.
#
# Vive en su propio proyecto Godot (`settings/`) y el shell lo carga desde
# `shell/settings_bridge.gd` leyendo el fuente con GDScript.set_source_code (mismo
# patrón que host.gd::sc): no hay `preload` entre proyectos.
#
# Reglas: sin I/O, sin procesos, sin dependencias del shell. Sólo normaliza,
# valida, serializa y calcula geometría. Todo lo visible usa lenguaje humano
# (nada de gvd/deskflow/mDNS ni nombres internos).

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

const FIELDS = ["keyboard", "locale", "accent", "wallpaper", "natural_scroll"]

const HEX_CHARS = "0123456789abcdef"


# --- Defaults y normalización -------------------------------------------------

func defaults():
	return {
		"version": VERSION,
		"keyboard": KEYBOARD_DEFAULT,
		"locale": LOCALE_DEFAULT,
		"accent": ACCENT_DEFAULT,
		"wallpaper": WALLPAPER_DEFAULT.duplicate(true),
		"natural_scroll": NATURAL_SCROLL_DEFAULT,
	}


# Une `data` con los defaults y valida campo por campo. Los campos desconocidos se
# conservan tal cual: la app y el shell comparten un solo archivo y otra página
# (p. ej. Pantallas, K11b) puede agregar datos sin que este modelo los borre.
func normalize(data):
	if typeof(data) != TYPE_DICTIONARY:
		data = {}
	var out = defaults()
	out["version"] = VERSION
	out["keyboard"] = keyboard_id(data.get("keyboard", ""))
	out["locale"] = locale_id(data.get("locale", ""))
	out["accent"] = accent_hex(data.get("accent", ""))
	out["wallpaper"] = wallpaper(data.get("wallpaper", {}))
	out["natural_scroll"] = nat_scroll(data.get("natural_scroll", null))
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

# `session/keyboard.sh` sourcea este archivo: asigna y exporta XKB_DEFAULT_*.
func keyboard_file_content(keyboard):
	return "XKB_DEFAULT_LAYOUT=" + keyboard_id(keyboard) + "\n"


# LANG para la próxima sesión.
func locale_file_content(locale):
	return "LANG=" + locale_id(locale) + "\n"


# Los cambios de teclado e idioma no son en vivo: la UI avisa que aplican al
# reiniciar. Acento y fondo sí se aplican al instante en el shell.
func is_live(field):
	return field == "accent" or field == "wallpaper" or field == "natural_scroll"


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
	assert(locale_file_content("en_US") == "LANG=en_US.UTF-8\n")
	assert(is_live("accent") and is_live("wallpaper"))
	assert(not is_live("keyboard") and not is_live("locale"))
	assert(d.natural_scroll == NATURAL_SCROLL_DEFAULT)
	assert(nat_scroll("false") == false and nat_scroll("on") == true)
	assert(nat_scroll(0) == false and nat_scroll(1) == true)
	assert(nat_scroll("cosa") == NATURAL_SCROLL_DEFAULT)
	assert(natural_scroll_cmd(false) == ["input", "type:touchpad", "natural_scroll", "disabled"])
	assert(natural_scroll_cmd(true) == ["input", "type:touchpad", "natural_scroll", "enabled"])
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
	print("settings_model selftest ok")
