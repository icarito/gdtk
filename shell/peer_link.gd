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
	"share_notify", "share_stop", "clip_set", "audio_recv", "audio_stop"]

# Parámetros válidos de los avisos de lados compartidos (G5). El `side` llega YA
# invertido por el emisor: acá sólo se valida el vocabulario, no se transforma.
const SHARE_TYPES = ["screen", "input"]
const SHARE_SIDES = ["north", "south", "east", "west"]
const SHARE_STATES = ["starting", "active", "stopped", "error"]

const _HID_OK = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"


# Valida los params de los avisos de lados compartidos. Para cualquier otro
# método no impone restricciones (cada handler valida lo suyo). Puro.
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
	ok = ok and valid_share_params("share_notify",
		{"type": "screen", "side": "north", "state": "active"})
	ok = ok and not valid_share_params("share_notify",
		{"type": "screen", "side": "up", "state": "active"})
	ok = ok and valid_share_params("share_stop", {"type": "input"})
	ok = ok and not valid_share_params("share_stop", {})
	return ok
