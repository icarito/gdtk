extends Reference

# Protocolo PURO del canal peer-to-peer de gdtk (sin ssh). Líneas JSON simples:
#   request:  {"v":1,"hid":"<sender>","token":"<par>","method":"gvd_recv","params":{...}}
#   response: {"v":1,"ok":true} | {"v":1,"ok":false,"error":"..."}
#
# Autenticación por token por-par (TOFU): el servidor guarda un token por hid la
# primera vez que un vecino CONFIRMADO pide algo y se lo devuelve en la respuesta
# (`token`); las siguientes peticiones deben traerlo. Modelo: LAN de confianza (igual
# que gvd), pero no se ejecuta nada sin token una vez emparejado.
#
# No toca red ni filesystem: sólo encoding/validación (testeable headless).

const VERSION = 1
# Métodos permitidos en el canal peer (lista blanca: el canal NO expone el control
# remoto completo, sólo lo necesario para pantalla y el aviso de lados compartidos).
const METHODS = ["ping", "gvd_recv", "gvd_stop", "gvd_send", "gvd_status",
	"share_notify", "share_stop", "clip_set", "audio_recv", "audio_stop", "gvd_size",
	"window_input", "window_input_stream", "gvd_meta"]

# Parámetros válidos de los avisos de lados compartidos (G5). El `side` llega YA
# invertido por el emisor: acá sólo se valida el vocabulario, no se transforma.
const SHARE_TYPES = ["screen", "input"]
const SHARE_SIDES = ["north", "south", "east", "west"]
const SHARE_STATES = ["starting", "active", "stopped", "error"]

const _HID_OK = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"


# Valida los params de los avisos de lados compartidos. Para cualquier otro
# método no impone restricciones (cada handler valida lo suyo). Puro.
# Tamaño del video que anuncia el emisor en `gvd_recv` (w, h): Vector2() si falta o es
# inválido. El receptor ajusta su ventana a esto. Puro.
static func video_size(params):
	var p = params if typeof(params) == TYPE_DICTIONARY else {}
	var w = int(p.get("w", 0))
	var h = int(p.get("h", 0))
	if w < 2 or h < 2 or w > 8192 or h > 8192:
		return Vector2()
	return Vector2(w, h)


# Lote de input de una «Pantalla compartida». Se valida aquí para que el canal peer
# nunca entregue al compositor campos arbitrarios. Las posiciones son normalizadas
# (0..1), independientes del tamaño con que el receptor dibuja el video.
static func window_input_events(params):
	var p = params if typeof(params) == TYPE_DICTIONARY else {}
	var src = p.get("events", [])
	if typeof(src) != TYPE_ARRAY or src.empty() or src.size() > 64:
		return []
	var out = []
	for raw in src:
		if typeof(raw) != TYPE_DICTIONARY:
			return []
		var kind = String(raw.get("kind", ""))
		match kind:
			"motion":
				var x = float(raw.get("x", -1.0))
				var y = float(raw.get("y", -1.0))
				if x < 0.0 or x > 1.0 or y < 0.0 or y > 1.0:
					return []
				out.append({"kind": kind, "x": x, "y": y})
			"button":
				var button = int(raw.get("button", 0))
				if button < 1 or button > 9 or typeof(raw.get("pressed", null)) != TYPE_BOOL:
					return []
				out.append({"kind": kind, "button": button, "pressed": bool(raw.pressed)})
			"key":
				var physical = int(raw.get("physical", 0))
				# Godot 3 reserva el rango 0x01000000 para teclas especiales
				# (flechas, función, multimedia). También deben cruzar el canal.
				if physical <= 0 or physical > 0x1FFFFFFF or typeof(raw.get("pressed", null)) != TYPE_BOOL:
					return []
				out.append({"kind": kind, "physical": physical, "pressed": bool(raw.pressed),
					"echo": bool(raw.get("echo", false))})
			"reset", "keepalive":
				out.append({"kind": kind})
			_:
				return []
	return out


# Línea de un lote de la «Pantalla compartida» DENTRO del stream persistente ya
# autenticado. A diferencia de `window_input`, la línea no repite hid/token ni
# método: la conexión queda marcada como stream tras el handshake. Puro.
static func encode_window_stream(events):
	return JSON.print({
		"v": VERSION,
		"events": events if typeof(events) == TYPE_ARRAY else [],
	}) + "\n"


# Decodifica una línea del stream: aplica la misma validación que `window_input`.
# Devuelve el lote validado o [] si la línea es basura/versión distinta/inválida.
# Puro.
static func parse_window_stream(line):
	var parsed = JSON.parse(String(line))
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return []
	var r = parsed.result
	if int(r.get("v", 0)) != VERSION:
		return []
	return window_input_events(r)


# Título, acento e ícono de la ventana que se comparte (`gvd_meta`), para que el
# receptor la muestre como «título @equipo» con el color y el ícono del origen. Título:
# texto plano, sin caracteres de control, hasta 200; acento: "#rrggbb" o ""; ícono: PNG
# en base64 de hasta ICON_B64_MAX ("" si falta o no es base64). {} si nada es válido.
# El PNG se decodifica recién en el shell (tamaño acotado ahí). Puro.
const ICON_B64_MAX = 65536
const _B64_OK = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="


static func video_meta(params):
	var p = params if typeof(params) == TYPE_DICTIONARY else {}
	var raw = p.get("title", "")
	var title = ""
	if typeof(raw) == TYPE_STRING:
		for i in range(min(raw.length(), 200)):
			var c = raw.ord_at(i)
			title += " " if c < 32 or c == 127 else raw[i]
		title = title.strip_edges()
	var acc = String(p.get("accent", "")).strip_edges().to_lower()
	if acc.length() != 7 or acc[0] != "#" or not acc.substr(1).is_valid_hex_number():
		acc = ""
	var icon = p.get("icon", "")
	if typeof(icon) != TYPE_STRING or icon.length() > ICON_B64_MAX or icon.length() % 4 != 0:
		icon = ""
	else:
		for i in range(icon.length()):
			if _B64_OK.find(icon[i]) < 0:
				icon = ""
				break
	if title == "" and acc == "" and icon == "":
		return {}
	return {"title": title, "accent": acc, "icon": icon}


static func valid_share_params(method, params):
	var p = params if typeof(params) == TYPE_DICTIONARY else {}
	match String(method):
		"share_notify":
			return SHARE_TYPES.has(String(p.get("type", "")).strip_edges()) \
				and SHARE_SIDES.has(String(p.get("side", "")).strip_edges()) \
				and SHARE_STATES.has(String(p.get("state", "")).strip_edges())
		"share_stop":
			return SHARE_TYPES.has(String(p.get("type", "")).strip_edges())
	return true


static func valid_hid(hid):
	var s = String(hid).strip_edges()
	if s == "" or s.length() > 128 or s.begins_with("-"):
		return false
	for i in range(s.length()):
		if _HID_OK.find(s[i]) < 0:
			return false
	return true


static func valid_method(m):
	return METHODS.has(String(m))


static func new_token():
	return Crypto.new().generate_random_bytes(24).hex_encode()


static func encode_request(hid, token, method, params = {}):
	return JSON.print({
		"v": VERSION,
		"hid": String(hid),
		"token": String(token),
		"method": String(method),
		"params": params if typeof(params) == TYPE_DICTIONARY else {},
	}) + "\n"


static func parse_request(line):
	var parsed = JSON.parse(String(line))
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return {}
	var r = parsed.result
	if int(r.get("v", 0)) != VERSION:
		return {}
	var m = String(r.get("method", ""))
	if not valid_method(m):
		return {}
	var hid = String(r.get("hid", ""))
	if not valid_hid(hid):
		return {}
	var p = r.get("params", {})
	return {
		"hid": hid,
		"token": String(r.get("token", "")),
		"method": m,
		"params": p if typeof(p) == TYPE_DICTIONARY else {},
	}


static func encode_response(ok, error = "", extra = {}):
	var o = {"v": VERSION, "ok": bool(ok)}
	if String(error) != "":
		o["error"] = String(error)
	if typeof(extra) == TYPE_DICTIONARY:
		for k in extra.keys():
			o[String(k)] = extra[k]
	return JSON.print(o) + "\n"


static func parse_response(line):
	var parsed = JSON.parse(String(line))
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return {}
	return parsed.result


static func selftest():
	var ok = true
	var req = encode_request("hid-1", "tok", "gvd_recv", {"port": 5600})
	var p = parse_request(req)
	ok = ok and p.hid == "hid-1" and p.token == "tok" and p.method == "gvd_recv" and int(p.params.port) == 5600
	ok = ok and parse_request("basura").empty()
	ok = ok and parse_request(JSON.print({"v": 1, "hid": "x", "method": "rm -rf"}) + "\n").empty()
	ok = ok and parse_request(JSON.print({"v": 2, "hid": "x", "method": "ping"}) + "\n").empty()
	ok = ok and not valid_hid("a b") and valid_hid("aa033bda2a7c6092")
	var resp = parse_response(encode_response(true, "", {"token": "t2"}))
	ok = ok and bool(resp.ok) and String(resp.token) == "t2"
	var bad = parse_response(encode_response(false, "unpaired"))
	ok = ok and not bool(bad.ok) and String(bad.error) == "unpaired"
	ok = ok and new_token().length() == 48
	ok = ok and valid_method("share_notify") and valid_method("share_stop")
	ok = ok and valid_method("window_input")
	ok = ok and window_input_events({"events": [{"kind": "motion", "x": 0.5, "y": 1.0},
		{"kind": "button", "button": 1, "pressed": true},
		{"kind": "key", "physical": 65, "pressed": false}, {"kind": "reset"}]}).size() == 4
	ok = ok and window_input_events({"events": [{"kind": "key", "physical": 0x01000014,
		"pressed": true}]}).size() == 1
	ok = ok and window_input_events({"events": [{"kind": "motion", "x": 2.0, "y": 0.0}]}).empty()
	var sl = encode_window_stream([{"kind": "motion", "x": 0.25, "y": 0.5},
		{"kind": "reset"}])
	ok = ok and sl.ends_with("\n") and sl.count("\n") == 1
	ok = ok and valid_method("window_input_stream")
	ok = ok and parse_window_stream(sl).size() == 2
	ok = ok and parse_window_stream("basura").empty()
	ok = ok and parse_window_stream(JSON.print({"v": 9, "events": [{"kind": "reset"}]}) + "\n").empty()
	ok = ok and parse_window_stream(JSON.print({"v": 1, "events": [
		{"kind": "button", "button": 99, "pressed": true}]}) + "\n").empty()
	ok = ok and valid_share_params("share_notify",
		{"type": "screen", "side": "north", "state": "active"})
	ok = ok and not valid_share_params("share_notify",
		{"type": "screen", "side": "up", "state": "active"})
	ok = ok and valid_share_params("share_stop", {"type": "input"})
	ok = ok and not valid_share_params("share_stop", {})
	return ok
