extends Reference

# Buzón del handshake de dirección del Vecindario (K3, SPEC-screen-share-compass
# §6 §9 §14). Modelo PURO y simulable del transporte entre hosts por ssh.
#
# Diseño (buzón por ssh, sin secretos y sin mDNS):
#   - proponer = `ssh <peer>` escribe de forma atómica (tmp + mv) el JSON de
#     `neighborhood_handshake.proposal(...)` en
#     ~/.config/gdtk/direction-inbox/<from_hid>.json del peer.
#   - responder = igual pero en <from_hid>.response.json del buzón del proponente.
#   - cada shell escanea su propio buzón (el caller, en un Thread con TTL) y
#     consume los archivos decodificados con `neighborhood_handshake.decode`.
#
# Este módulo NO ejecuta nada: no hace ssh, no lee/escribe archivos, no toca red
# ni procesos. Sólo produce rutas/nombres saneados, el argv de ssh sin
# shell-injection y la decisión pura de qué hacer con cada archivo del buzón. El
# caller (shell.gd) hace el I/O real fuera del hilo de render.

# Sólo [a-z0-9] en los hids reales (hex de PUBLISH_PLAN), pero se admite también
# `-` y `_` para ids opacos de otros orígenes; se descarta el resto (incluye `..`).
const _HID_ALLOWED = "abcdefghijklmnopqrstuvwxyz0123456789-_"
const _FILENAME_ALLOWED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
const _PEER_ALLOWED = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:@[]"
const _HID_MAX = 64
const _FILENAME_MAX = 96

const KIND_PROPOSAL = "proposal"
const KIND_RESPONSE = "response"
# `kind` real del DTO de neighborhood_handshake.gd (contrato en disco).
const DTO_PROPOSAL = "direction_proposal"
const DTO_RESPONSE = "direction_response"

const SSH_PROG = "ssh"
const SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-T"]
const REMOTE_INBOX = "gdtk/direction-inbox"
const REMOTE_SUFFIX = ".json"


# Sanea un hid a un token apto para nombre de archivo. Nunca lanza: descarta todo
# lo que no sea [a-z0-9_-], colapsa a minúsculas y acota el largo. Sin resultado
# válido devuelve "" (el caller debe negarse a usar el buzón).
static func safe_hid(hid):
	var s = String(hid).strip_edges().to_lower()
	var out = ""
	for i in range(s.length()):
		var c = s[i]
		if _HID_ALLOWED.find(c) >= 0:
			out += c
		if out.length() >= _HID_MAX:
			break
	return out


# ¿El hid sobrevive entero al saneamiento? Un hid vacío o con caracteres raros no
# se usa como nombre de archivo (evita colisiones y rutas inesperadas).
static func hid_is_safe(hid):
	var s = String(hid).strip_edges()
	return s != "" and safe_hid(s) == s.to_lower()


# Basename de la propuesta de `from_hid`: "<from_hid>.json" (o "" si no es apto).
static func proposal_name(from_hid):
	var h = safe_hid(from_hid)
	return "" if h == "" else h + REMOTE_SUFFIX


# Basename de la respuesta de `from_hid`: "<from_hid>.response.json". Distinto del
# de la propuesta para que ambos convivan en el mismo buzón sin pisarse.
static func response_name(from_hid):
	var h = safe_hid(from_hid)
	return "" if h == "" else h + ".response.json"


# Nombres de archivo que este módulo considera del handshake y a qué kind
# corresponden. Desconocido/basura -> "".
static func file_kind(filename):
	var n = String(filename)
	if not valid_filename(n):
		return ""
	if n.ends_with(".response" + REMOTE_SUFFIX):
		return KIND_RESPONSE
	return KIND_PROPOSAL


# Nombre de archivo seguro: sólo basename, sin separadores ni "..", extensión
# .json y largo acotado. Evita path traversal y escrituras fuera del buzón.
static func valid_filename(filename):
	var n = String(filename)
	if n == "" or n.length() > _FILENAME_MAX:
		return false
	if n.find("/") >= 0 or n.find("\\") >= 0 or n.find("..") >= 0:
		return false
	if not n.ends_with(REMOTE_SUFFIX):
		return false
	if n.begins_with("."):
		return false
	var stem = n.substr(0, n.length() - REMOTE_SUFFIX.length())
	if stem == "":
		return false
	for i in range(stem.length()):
		if _FILENAME_ALLOWED.find(stem[i]) < 0:
			return false
	return true


# Directorio del buzón local: <base>/gdtk/direction-inbox. Sin base -> "".
static func inbox_dir(base):
	var b = String(base).strip_edges()
	if b == "":
		return ""
	return b + "/" + REMOTE_INBOX


static func proposal_path(base, from_hid):
	var dir = inbox_dir(base)
	var name = proposal_name(from_hid)
	return "" if dir == "" or name == "" else dir + "/" + name


static func response_path(base, from_hid):
	var dir = inbox_dir(base)
	var name = response_name(from_hid)
	return "" if dir == "" or name == "" else dir + "/" + name


# Destino ssh válido: hostname, IPv4/IPv6 o user@host. Rechaza vacío, controles,
# espacios y cualquier cosa que empiece con "-" (evita inyección de opciones ssh).
static func valid_peer(peer):
	var p = String(peer).strip_edges()
	if p == "" or p.length() > 255 or p.begins_with("-"):
		return false
	for i in range(p.length()):
		if _PEER_ALLOWED.find(p[i]) < 0:
			return false
	return true


# Script remoto de escritura atómica. `b64` lo genera este módulo (alfabeto base64)
# y `name` pasó por valid_filename: no hay material no confiable interpolado, así
# que no hay inyección. El archivo final se escribe con umask 077 y rename atómico.
static func remote_script(name, b64):
	var clean = String(b64).replace("\n", "").replace("\r", "")
	return "umask 077; cfg=\"${XDG_CONFIG_HOME:-$HOME/.config}\"; " \
		+ "d=\"$cfg/gdtk/direction-inbox\"; mkdir -p \"$d\" && " \
		+ "t=\"$d/.tmp.$$\"; printf %s '" + clean + "' | base64 -d > \"$t\" && " \
		+ "mv -f \"$t\" \"$d/" + String(name) + "\""


# argv completo para que `ssh <peer>` escriba `payload` en `remote_name` del buzón
# remoto. Devuelve {ok, cmd, args, error}; nunca lanza. Sin credenciales: sólo
# BatchMode=yes (no interactivo) y ConnectTimeout=3.
static func ssh_write_argv(peer, remote_name, payload):
	if not valid_peer(peer):
		return _bad("peer inválido")
	if not valid_filename(remote_name):
		return _bad("nombre de archivo inválido")
	var b64 = Marshalls.raw_to_base64(String(payload).to_utf8()).replace("\n", "").replace("\r", "")
	var args = []
	for o in SSH_OPTS:
		args.append(String(o))
	args.append(String(peer).strip_edges())
	args.append(remote_script(remote_name, b64))
	return {"ok": true, "cmd": SSH_PROG, "args": args, "error": ""}


# Decisión pura sobre un archivo del buzón. `decoded` es la salida de
# neighborhood_handshake.decode. Devuelve {action, delete, reason} donde action
# es "proposal" | "response" | "ignore". `delete` indica que el caller debe borrar
# el archivo tras procesarlo: los mensajes válidos se consumen (el estado queda en
# host_directions) y la basura también, para no reprocesarla.
static func plan_file(filename, decoded, local_hid):
	var kind = file_kind(filename)
	if kind == "":
		return {"action": "ignore", "delete": false, "reason": "no es archivo del handshake"}
	if typeof(decoded) != TYPE_DICTIONARY or not bool(decoded.get("ok", false)):
		return {"action": "ignore", "delete": true, "reason": "mensaje inválido"}
	if String(decoded.get("kind", "")) != _expected_dto_kind(kind):
		return {"action": "ignore", "delete": true, "reason": "kind no coincide con el nombre"}
	var to = String(decoded.get("to", ""))
	var local = String(local_hid)
	if to != "" and local != "" and to != local:
		return {"action": "ignore", "delete": true, "reason": "no dirigido a este host"}
	# Validaciones intrínsecas del mensaje: no se aplica algo sin emisor.
	if String(decoded.get("from", "")).strip_edges() == "":
		return {"action": "ignore", "delete": true, "reason": "mensaje sin emisor"}
	return {"action": kind, "delete": true, "reason": ""}


static func _expected_dto_kind(kind):
	return DTO_RESPONSE if String(kind) == KIND_RESPONSE else DTO_PROPOSAL


# Destino ssh de un host del Vecindario (entry de neighborhood_hosts.gd). Prefiere
# la dirección IPv4/IPv6 resuelta (en cualquier servicio); cae al hostname .local.
# Sin servicio con destino válido -> {ok:false, error}.
static func ssh_target(host):
	if typeof(host) != TYPE_DICTIONARY:
		return {"ok": false, "peer": "", "error": "host inválido"}
	var services = host.get("services", [])
	if typeof(services) != TYPE_ARRAY:
		return {"ok": false, "peer": "", "error": "host sin servicios"}
	# IPv4 primero: mDNS suele anunciar antes la IPv6 global, y el canal peer escucha
	# sólo IPv4 (y un literal IPv6 no admite el sufijo ".local").
	for s in services:
		var a4 = String(s.get("address", "")).strip_edges() if typeof(s) == TYPE_DICTIONARY else ""
		if a4.is_valid_ip_address() and a4.find(":") < 0 and valid_peer(a4):
			return {"ok": true, "peer": a4, "error": ""}
	for s in services:
		if typeof(s) == TYPE_DICTIONARY and valid_peer(String(s.get("address", "")).strip_edges()):
			return {"ok": true, "peer": String(s.get("address", "")).strip_edges(), "error": ""}
	for s in services:
		if typeof(s) == TYPE_DICTIONARY and valid_peer(String(s.get("host", "")).strip_edges()):
			return {"ok": true, "peer": String(s.get("host", "")).strip_edges(), "error": ""}
	return {"ok": false, "peer": "", "error": "host sin dirección ssh"}


static func _bad(error):
	return {"ok": false, "cmd": "", "args": [], "error": error}


static func selftest():
	# Saneamiento de hid / nombres.
	assert(safe_hid("aB3-c_9") == "ab3-c_9", "safe_hid conserva válidos")
	assert(safe_hid("../../etc/passwd") == "etcpasswd", "safe_hid descarta traversal")
	assert(safe_hid("") == "" and not hid_is_safe("a/b"), "hid inválido -> no seguro")
	assert(proposal_name("hidA") == "hida.json", "proposal_name")
	assert(ssh_target({"services": [{"address": "2804::1"}, {"address": "192.168.1.5"}]}).peer == "192.168.1.5",
		"ssh_target prefiere IPv4")
	assert(response_name("hidA") == "hida.response.json", "response_name")
	assert(proposal_name("") == "" and response_name("../x") == "x.response.json",
		"nombres saneados")

	# Filtro de nombres y clasificación.
	assert(valid_filename("abcd.json") and not valid_filename("../x.json")
		and not valid_filename("abcd.txt") and not valid_filename(".hidden.json"),
		"valid_filename")
	assert(file_kind("abcd.json") == KIND_PROPOSAL, "kind proposal")
	assert(file_kind("abcd.response.json") == KIND_RESPONSE, "kind response")
	assert(file_kind("otra-cosa.bin") == "", "kind desconocido")

	# Rutas.
	assert(inbox_dir("/home/u/.config") == "/home/u/.config/gdtk/direction-inbox",
		"inbox_dir")
	assert(proposal_path("/cfg", "HID") == "/cfg/gdtk/direction-inbox/hid.json",
		"proposal_path")
	assert(response_path("/cfg", "HID") == "/cfg/gdtk/direction-inbox/hid.response.json",
		"response_path")
	assert(inbox_dir("") == "" and proposal_path("", "x") == "", "sin base no hay ruta")

	# Peer válido / inválido.
	assert(valid_peer("tengu.local") and valid_peer("192.168.1.20")
		and valid_peer("user@10.0.0.2"), "peers válidos")
	assert(not valid_peer("") and not valid_peer("-oProxyCommand=x")
		and not valid_peer("a b") and not valid_peer("a;rm -rf /"), "peers inválidos")

	# argv de ssh: sin shell-injection y con las opciones del contrato.
	var argv = ssh_write_argv("tengu.local", "abcd.json", "{\"kind\":\"direction_proposal\"}")
	assert(argv.ok and argv.cmd == "ssh", "argv ok")
	assert(argv.args.has("BatchMode=yes") and argv.args.has("ConnectTimeout=3"),
		"argv no interactivo")
	assert(argv.args[argv.args.size() - 2] == "tengu.local", "peer como argumento separado")
	var script = String(argv.args[argv.args.size() - 1])
	assert(script.find("mv -f") >= 0 and script.find("base64 -d") >= 0
		and script.find(";rm -rf") < 0, "script remoto atómico y sin inyección")
	assert(not ssh_write_argv("-bad", "a.json", "{}").ok, "peer con guion rechazado")
	assert(not ssh_write_argv("host", "../x.json", "{}").ok, "nombre inválido rechazado")

	# Decisión por archivo.
	var proposal = {"ok": true, "kind": "direction_proposal", "from": "peerA",
		"to": "me", "direction": "east"}
	var response = {"ok": true, "kind": "direction_response", "from": "peerA",
		"to": "me", "direction": "east", "accepted": true}
	assert(plan_file("peera.json", proposal, "me").action == "proposal", "plan proposal")
	assert(plan_file("peera.response.json", response, "me").action == "response",
		"plan response")
	assert(plan_file("peera.json", proposal, "otro").action == "ignore",
		"mensaje para otro host")
	assert(plan_file("peera.json", {"ok": false, "error": "x"}, "me").delete,
		"basura se borra")
	assert(plan_file("notas.txt", proposal, "me").action == "ignore"
		and not plan_file("notas.txt", proposal, "me").delete, "ajeno no se borra")
	assert(plan_file("peera.response.json", proposal, "me").action == "ignore",
		"kind no coincide con nombre")
	assert(plan_file("peera.json", {"ok": true, "kind": "direction_proposal",
		"from": "", "to": "me"}, "me").action == "ignore", "sin emisor no se aplica")

	# Destino ssh desde un host del modelo.
	var host = {"services": [{"address": "", "host": "tengu.local"},
		{"address": "192.168.1.20", "host": "tengu.local"}]}
	assert(ssh_target(host).peer == "192.168.1.20", "prefiere address")
	assert(not ssh_target({"services": []}).ok, "sin servicios no hay destino")
	assert(not ssh_target({"services": [{"address": "bad host"}]}).ok,
		"destino inválido rechazado")
	return true


func run_selftest():
	return selftest()
