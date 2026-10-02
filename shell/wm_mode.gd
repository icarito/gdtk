extends Reference

# K13a — Modelo PURO del modo de ventanas del shell.
#
# Dos modos globales (no por ventana), conmutables:
#   - "floating": ventanas libres con barra de título (default, WindowMaker).
#   - "tiled": la fila de pantallas de siempre.
#
# Es puro: sin I/O, sin procesos ni estado global. Sólo normaliza, serializa y
# decide el modo; la persistencia la hace frame.gd (tmp+rename) y la colocación
# shell.gd / float_layout.gd. Vocabulario visible: "Flotante" / "Mosaico" (nunca
# "tiling"/"layout"/"WM").

const FLOATING = "floating"
const TILED = "tiled"


# Modo por defecto del producto: ventanas flotantes libres.
static func default_mode():
	return FLOATING


# Normaliza cualquier entrada tolerante (string, mayúsculas, alias en español)
# al modo canónico. Lo desconocido cae al default (floating).
static func normalize(value):
	var m = String(value).strip_edges().to_lower()
	if m == TILED or m == "tile" or m == "mosaico" or m == "mosaic":
		return TILED
	return FLOATING


static func is_floating(value):
	return normalize(value) == FLOATING


static func is_tiled(value):
	return normalize(value) == TILED


static func toggled(value):
	return TILED if is_floating(value) else FLOATING


# Acepta un string ("floating"), el diccionario persistido ({"window_mode": ...})
# o un diccionario con "mode". Sin dato -> default.
static func parse(value):
	if typeof(value) == TYPE_DICTIONARY:
		if value.has("window_mode"):
			return normalize(value["window_mode"])
		if value.has("mode"):
			return normalize(value["mode"])
		return default_mode()
	return normalize(value)


# Forma canónica que se escribe en el JSON.
static func serialize(value):
	return normalize(value)


# Etiqueta corta para el bloque del Frame ("Flotante" / "Mosaico").
static func label(value):
	return "Flotante" if is_floating(value) else "Mosaico"


# Nombre largo para tooltip / menú, en lenguaje humano.
static func describe(value):
	return "Ventanas flotantes" if is_floating(value) else "Ventanas en mosaico"


# Autoprueba del modelo. Devuelve true si pasa.
static func selftest():
	assert(default_mode() == FLOATING, "default flotante")
	assert(normalize("floating") == FLOATING, "floating")
	assert(normalize("TILED") == TILED, "tiled")
	assert(normalize("mosaico") == TILED, "alias mosaico")
	assert(normalize("cualquier cosa") == FLOATING, "desconocido -> flotante")
	assert(normalize("") == FLOATING, "vacío -> flotante")
	assert(is_floating("floating"), "is_floating")
	assert(is_tiled("tiled"), "is_tiled")
	assert(toggled("floating") == TILED, "toggle a tiled")
	assert(toggled("tiled") == FLOATING, "toggle a floating")
	assert(parse({"window_mode": "tiled"}) == TILED, "parse dict")
	assert(parse({"mode": "floating"}) == FLOATING, "parse dict mode")
	assert(parse({}) == FLOATING, "parse dict vacío -> default")
	assert(parse("tiled") == TILED, "parse string")
	assert(serialize("TILED") == TILED, "serialize canónico")
	assert(label("floating") == "Flotante", "label flotante")
	assert(label("tiled") == "Mosaico", "label mosaico")
	return true


func run_selftest():
	return selftest()
