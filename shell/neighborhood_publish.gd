extends Reference

const SERVICE_GVD = "_gdtk-gvd._udp"
const SERVICE_DESKFLOW = "_gdtk-deskflow._tcp"
const MAX_TXT_BYTES = 200
const MAX_TXT_ENTRY_BYTES = 255

const AVAHI_PROG = "avahi-publish-service"

const _KINDS = ["desktop", "laptop", "tablet", "mobile", "tv", "unknown"]
const _AUTH = ["ask", "paired"]
const _SECRET_WORDS = [
	"token", "secret", "password", "passwd", "apikey", "api_key",
	"authorization", "bearer", "cookie", "credential", "private_key", "-----begin"
]


var _avahi_cache = null


func detect_avahi():
	if _avahi_cache == null:
		var path = which_in_path(AVAHI_PROG, OS.get_environment("PATH"))
		var available = path != ""
		_avahi_cache = {
			"available": available,
			"path": path,
			"state": "ready" if available else "degraded"
		}
	return _avahi_cache.duplicate()


# Resuelve un ejecutable en un valor de PATH escaneando sólo con File, sin lanzar
# procesos. Devuelve la ruta absoluta o "" si no está. Es puro y testeable: recibe
# el PATH como argumento en vez de leer el entorno.
static func which_in_path(prog, path_value) -> String:
	var name = String(prog).strip_edges()
	if name == "":
		return ""
	for d in String(path_value).split(":", false):
		if d == "":
			continue
		var candidate = d + "/" + name
		if File.new().file_exists(candidate):
			return candidate
	return ""


func build_common_txt(identity):
	var kind = _one_of(String(identity.get("kind", "unknown")), _KINDS, "unknown")
	var icon = _txt_atom(String(identity.get("icon", kind)), kind)
	var txt = [
		"v=1",
		"hid=" + _txt_atom(String(identity.get("hid", "")), ""),
		"name=" + _txt_value(String(identity.get("name", "gdtk"))),
		"kind=" + kind,
		"icon=" + icon,
		"auth=" + _one_of(String(identity.get("auth", "ask")), _AUTH, "ask"),
	]
	# Canal peer: sólo si escucha. "ctl=" vacío no valida y tumbaba TODO el anuncio.
	var ctl = _txt_atom(String(identity.get("ctl", "")), "")
	if ctl != "":
		txt.append("ctl=" + ctl)
	# Acento del host opcional: sólo "#rrggbb" exacto, normalizado a minúsculas.
	# Misma regla que NeighborhoodHosts.valid_accent, copiada para no acoplarlos.
	var accent = _valid_accent(String(identity.get("accent", "")))
	if accent != "":
		txt.append("accent=" + accent)
	return txt


# "#rrggbb" exacto (6 hex, sin alfa ni nombres); "" para cualquier otra cosa.
func _valid_accent(s):
	var v = String(s).strip_edges().to_lower()
	if v.length() != 7 or v[0] != "#":
		return ""
	for i in range(1, 7):
		if "0123456789abcdef".find(v[i]) < 0:
			return ""
	return v


func build_gvd_txt(identity, opts = {}):
	var txt = build_common_txt(identity)
	txt.append("role=" + _one_of(String(opts.get("role", "recv")), ["recv"], "recv"))
	txt.append("state=" + _one_of(String(opts.get("state", "ready")), ["ready", "capable"], "ready"))
	txt.append("codec=" + _txt_atom(String(opts.get("codec", "h264")), "h264"))
	txt.append("rtp=" + _txt_atom(String(opts.get("rtp", "96")), "96"))
	txt.append("cursor=" + _one_of(String(opts.get("cursor", "separate")), ["separate", "none"], "separate"))
	txt.append("cursor_port=" + _txt_atom(String(opts.get("cursor_port", "+1")), "+1"))
	txt.append("size=" + _txt_atom(String(opts.get("size", "1280x800")), "1280x800"))
	txt.append_array(_layout_entries(opts))
	return txt


func build_deskflow_txt(identity, opts = {}):
	var txt = build_common_txt(identity)
	# Por defecto un host gdtk se anuncia como CLIENTE: compartir este teclado/mouse
	# requiere que Settings pida share_here y que el backend InputCapture esté disponible.
	# role=server sólo si el caller lo pide explícitamente.
	txt.append("role=" + _one_of(String(opts.get("role", "client")), ["server", "client"], "client"))
	txt.append("clip=" + _one_of(String(opts.get("clip", "1")), ["0", "1"], "1"))
	txt.append("tls=" + _one_of(String(opts.get("tls", "required")), ["required"], "required"))
	txt.append("screen=" + _txt_atom(String(opts.get("screen", "edge")), "edge"))
	txt.append_array(_layout_entries(opts))
	return txt


func _layout_entries(opts):
	var v = opts.get("layout", 0)
	var want = v if typeof(v) == TYPE_BOOL else int(v) == 1
	return ["layout=1"] if want else []


func build_gvd_launch(identity, port = 5600, opts = {}):
	return build_publish_args(SERVICE_GVD, port, build_gvd_txt(identity, opts), _service_name("gvd", identity))


func build_deskflow_launch(identity, port, opts = {}):
	return build_publish_args(SERVICE_DESKFLOW, port, build_deskflow_txt(identity, opts), _service_name("deskflow", identity))


func build_publish_args(service_type, port, txt, service_name):
	var err = _service_error(service_type, port, service_name)
	if err != "":
		return _bad(err)
	var check = validate_txt(txt)
	if not check.ok:
		return _bad(check.error)
	var args = [String(service_name), String(service_type), str(int(port))]
	for entry in txt:
		args.append(String(entry))
	return {"ok": true, "cmd": "avahi-publish-service", "args": args, "error": "", "txt_bytes": check.bytes}


func prepare_launch_args(service_type, port, txt, service_name, avahi_path = "avahi-publish-service"):
	if String(avahi_path).strip_edges() == "":
		return {"ok": false, "state": "degraded", "error": "avahi-publish-service no disponible", "cmd": "", "args": []}
	var plan = build_publish_args(service_type, port, txt, service_name)
	if plan.ok:
		plan.cmd = String(avahi_path)
		plan.state = "ready"
	return plan


func validate_txt(txt):
	var total = 0
	for entry in txt:
		var e = String(entry)
		total += e.to_utf8().size()
		var err = _txt_entry_error(e)
		if err != "":
			return {"ok": false, "error": err, "bytes": total}
	if total > MAX_TXT_BYTES:
		return {"ok": false, "error": "TXT mayor a %d bytes" % MAX_TXT_BYTES, "bytes": total}
	return {"ok": true, "error": "", "bytes": total}


func txt_valid(txt):
	return validate_txt(txt).ok


func _service_error(service_type, port, service_name):
	if not [SERVICE_GVD, SERVICE_DESKFLOW].has(String(service_type)):
		return "servicio no permitido: " + String(service_type)
	var p = int(port)
	if p < 1 or p > 65535:
		return "puerto inválido"
	var name = String(service_name)
	if name.strip_edges() == "" or _has_control(name) or _looks_private(name):
		return "nombre de servicio inválido"
	return ""


func _txt_entry_error(entry):
	if entry.to_utf8().size() > MAX_TXT_ENTRY_BYTES:
		return "entrada TXT mayor a %d bytes" % MAX_TXT_ENTRY_BYTES
	var eq = entry.find("=")
	if eq <= 0:
		return "entrada TXT sin clave=valor"
	var key = entry.substr(0, eq)
	var value = entry.substr(eq + 1, entry.length() - eq - 1)
	if value == "":
		return "TXT vacío: " + key
	if _has_control(entry) or _bad_key(key):
		return "TXT inválido: " + key
	if _looks_secret(entry) or _looks_private(value):
		return "TXT sensible: " + key
	return ""


func _bad_key(key):
	var allowed = "abcdefghijklmnopqrstuvwxyz0123456789_"
	for i in range(key.length()):
		if allowed.find(key.substr(i, 1)) < 0:
			return true
	return false


func _has_control(s):
	return s.find("\n") >= 0 or s.find("\r") >= 0 or s.find("\t") >= 0 or s.find("\u0000") >= 0


func _looks_secret(s):
	var lower = String(s).to_lower()
	for word in _SECRET_WORDS:
		if lower.find(word) >= 0:
			return true
	return false


func _looks_private(s):
	var v = String(s)
	return v.begins_with("~/") or v.find("/") >= 0 or v.find("\\") >= 0


func _one_of(value, allowed, fallback):
	return value if allowed.has(value) else fallback


func _txt_value(value):
	var v = value.strip_edges()
	if v == "":
		return "gdtk"
	return v


func _txt_atom(value, fallback):
	var v = value.strip_edges()
	if v == "" or v.find("=") >= 0 or _has_control(v) or _looks_secret(v) or _looks_private(v):
		return fallback
	return v


func _service_name(kind, identity):
	return "gdtk " + kind + " " + _txt_value(String(identity.get("name", "host")))


func _bad(error):
	return {"ok": false, "cmd": "", "args": [], "error": error, "txt_bytes": 0}
