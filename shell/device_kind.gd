extends Reference

# Modelo PURO del tipo de equipo local (kind de Vecindario: desktop/laptop/
# tablet/mobile/tv/unknown). Sin I/O: recibe el override del entorno, el valor de
# /sys/class/dmi/id/chassis_type y si hay batería. El shell hace las lecturas y
# cachea el resultado; acá sólo se decide. La misma lista que publica
# neighborhood_publish.gd para el TXT mDNS.

const KINDS = ["desktop", "laptop", "tablet", "mobile", "tv"]


# Normaliza a un kind válido o "unknown".
static func normalize(kind):
	var k = String(kind).strip_edges().to_lower()
	return k if KINDS.has(k) else "unknown"


# Tipo SMBIOS de chasis (DMI) a kind. Convertibles y desmontables cuentan como
# tablet; "portable/notebook/sub-notebook" como laptop; caja de escritorio,
# todo-en-uno, mini PC y stick PC como desktop; "hand held" como mobile.
static func from_chassis(code):
	var c = int(code)
	if c == 30 or c == 31 or c == 32:
		return "tablet"
	if c == 8 or c == 9 or c == 10 or c == 14:
		return "laptop"
	if c == 11:
		return "mobile"
	if c == 3 or c == 4 or c == 5 or c == 6 or c == 7 or c == 13 \
			or c == 15 or c == 16 or c == 35 or c == 36:
		return "desktop"
	return "unknown"


# Decisión final: override explícito del entorno > nombre de producto (Surface
# Pro/Go, etc.) > chasis DMI > batería (heurística de portátil) > desconocido.
# `chassis_text` es el contenido crudo de chassis_type (puede venir vacío o no
# numérico); `product_text` el de product_name. Puro.
static func detect(env_kind, chassis_text, battery_present, product_text = ""):
	var forced = normalize(env_kind)
	if forced != "unknown":
		return forced
	var by_product = from_product(product_text)
	if by_product != "unknown":
		return by_product
	var raw = String(chassis_text).strip_edges()
	if raw != "" and raw.is_valid_integer():
		var by_chassis = from_chassis(int(raw))
		if by_chassis != "unknown":
			return by_chassis
	if bool(battery_present):
		return "laptop"
	return "unknown"


# Pistas por nombre comercial del equipo (DMI product_name): Surface Pro/Go son
# tablets desmontables; Surface Laptop/Book, notebooks y portátiles son laptops.
static func from_product(name):
	var s = String(name).strip_edges().to_lower()
	if s == "":
		return "unknown"
	if s.find("surface pro") >= 0 or s.find("surface go") >= 0 or s.find("tablet") >= 0:
		return "tablet"
	if s.find("surface laptop") >= 0 or s.find("surface book") >= 0 \
			or s.find("notebook") >= 0 or s.find("laptop") >= 0:
		return "laptop"
	if s.find("desktop") >= 0 or s.find("tower") >= 0 or s.find("mini pc") >= 0:
		return "desktop"
	return "unknown"


static func selftest():
	assert(normalize("Tablet") == "tablet" and normalize("nope") == "unknown", "normalize")
	assert(from_chassis(30) == "tablet" and from_chassis(32) == "tablet", "chasis tablet")
	assert(from_chassis(31) == "tablet" and from_chassis(9) == "laptop", "convertible/laptop")
	assert(from_chassis(11) == "mobile" and from_chassis(3) == "desktop", "mobile/desktop")
	assert(from_chassis(2) == "unknown" and from_chassis(99) == "unknown", "desconocido")
	assert(from_product("Surface Pro 3") == "tablet" and from_product("Surface Go 2") == "tablet", "Surface Pro/Go")
	assert(from_product("Surface Laptop 4") == "laptop" and from_product("ThinkPad Notebook") == "laptop", "portátil por nombre")
	assert(from_product("OptiPlex Tower") == "desktop" and from_product("") == "unknown", "nombre desktop/vacío")
	assert(detect("tv", "9", true) == "tv", "override manda")
	assert(detect("", "30", false) == "tablet", "chasis sin override")
	assert(detect("", "9", true, "Surface Pro 3") == "tablet", "producto manda sobre chasis")
	assert(detect("", "", true) == "laptop", "batería si no hay chasis")
	assert(detect("", "nope", false) == "unknown", "sin datos")
	return true


func run_selftest():
	return selftest()
