extends Node

# Canal de control peer-to-peer de gdtk (sin ssh). Escucha en la LAN un protocolo
# JSON mínimo (shell/peer_link.gd) con métodos de PANTALLA únicamente, autenticado
# por token por-par (TOFU: el primer pedido de un vecino CONFIRMADO provisiona el
# token y lo devuelve; después hay que presentarlo). Pensado para LAN de confianza.
#
# No expone el control remoto completo: sólo ping/gvd_*.

const LINK = preload("res://peer_link.gd")

var shell = null
var server = null
var port = 0
var conns = []
var tokens = {}
var tokens_path = ""


func start(p_shell, p_port):
	shell = p_shell
	port = int(p_port)
	if port <= 0:
		return
	var base = OS.get_environment("XDG_CONFIG_HOME")
	if base == "":
		base = OS.get_environment("HOME").plus_file(".config")
	tokens_path = base.plus_file("gdtk").plus_file("peer-tokens.json")
	_load_tokens()
	server = TCP_Server.new()
	var err = server.listen(port, "0.0.0.0")
	if err != OK:
		printerr("PeerControl: no pude escuchar en 0.0.0.0:", port, " (", err, ")")
		server = null
	else:
		print("PeerControl: escuchando en 0.0.0.0:", port)


func _exit_tree():
	stop()


func stop():
	if server != null:
		server.stop()
		server = null
	for conn in conns:
		if conn.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			conn.peer.disconnect_from_host()
	conns = []


func listening():
	return server != null and port > 0


func _load_tokens():
	tokens = {}
	var f = File.new()
	if tokens_path == "" or f.open(tokens_path, File.READ) != OK:
		return
	var data = JSON.parse(f.get_as_text()).result
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		return
	for k in data.keys():
		if LINK.valid_hid(String(k)) and String(data[k]) != "":
			tokens[String(k)] = String(data[k])


func _save_tokens():
	var f = File.new()
	if tokens_path == "" or f.open(tokens_path, File.WRITE) != OK:
		return
	f.store_string(JSON.print(tokens))
	f.close()


func _send(conn, line):
	if conn.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		conn.peer.put_data(line.to_utf8())


func _process(_delta):
	if server == null:
		return
	while server.is_connection_available():
		var peer = server.take_connection()
		peer.set_no_delay(true)
		conns.append({"peer": peer, "buf": PoolByteArray(), "close": false})
	for i in range(conns.size() - 1, -1, -1):
		var conn = conns[i]
		_poll(conn)
		if conn.close:
			if conn.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				conn.peer.disconnect_from_host()
			conns.remove(i)


func _poll(conn):
	var peer = conn.peer
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		conn.close = true
		return
	var available = peer.get_available_bytes()
	if available > 0:
		var data = peer.get_partial_data(available)
		if data[0] == OK:
			var buf = conn.buf
			buf.append_array(data[1])
			conn.buf = buf
	# una sola línea por conexión (petición/ respuesta), sin pipelining
	var idx = -1
	for i in range(conn.buf.size()):
		if conn.buf[i] == 10:
			idx = i
			break
	if idx < 0:
		return
	var line = conn.buf.subarray(0, idx - 1).get_string_from_utf8().strip_edges() if idx > 0 else ""
	_handle(conn, line)
	conn.close = true


func _peer_is_confirmed(hid):
	if shell != null and is_instance_valid(shell) and shell.has_method("_peer_is_confirmed"):
		return bool(shell._peer_is_confirmed(String(hid)))
	return false


func _handle(conn, line):
	var r = LINK.parse_request(line)
	if r.empty():
		_send(conn, LINK.encode_response(false, "bad request"))
		return
	var hid = String(r.hid)
	if String(r.method) == "ping":
		_send(conn, LINK.encode_response(true, "", {"paired": tokens.has("srv:" + hid)}))
		return
	var known = String(tokens.get("srv:" + hid, ""))
	var extra = {}
	if known == "":
		if not _peer_is_confirmed(hid):
			_send(conn, LINK.encode_response(false, "unpaired"))
			return
		known = LINK.new_token()
		tokens["srv:" + hid] = known
		_save_tokens()
		extra["token"] = known
	elif String(r.token) != known:
		_send(conn, LINK.encode_response(false, "unauthorized"))
		return
	if shell == null or not is_instance_valid(shell):
		_send(conn, LINK.encode_response(false, "shell busy", extra))
		return
	var params = r.params
	var ok = false
	var err = ""
	match String(r.method):
		"gvd_recv":
			ok = bool(shell._peer_gvd_open(int(params.get("port", 0)), String(params.get("from", ""))))
			if not ok:
				err = "no se pudo abrir el receptor"
		"gvd_stop":
			ok = bool(shell._peer_gvd_stop())
		"gvd_status":
			ok = true
			extra["active"] = bool(shell._peer_gvd_active())
		"gvd_send":
			ok = bool(shell._peer_gvd_send(int(params.get("port", 0)), String(params.get("target", ""))))
			if not ok:
				err = "no se pudo abrir el emisor"
		_:
			err = "método no soportado"
	_send(conn, LINK.encode_response(ok, err, extra))
