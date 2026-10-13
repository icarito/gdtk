extends Node

# Canal de control peer-to-peer de gdtk (sin ssh). Escucha en la LAN un protocolo
# JSON mínimo (shell/peer_link.gd) con métodos de PANTALLA únicamente, autenticado
# por token por-par (TOFU: el primer pedido de un vecino CONFIRMADO provisiona el
# token y lo devuelve; después hay que presentarlo). Pensado para LAN de confianza.
#
# No expone el control remoto completo: sólo los métodos de peer_link.METHODS.

# Debe entrar junto con peer_control en la recarga transaccional. Con preload el
# proceso conservaba el validador anterior y rechazaba teclas especiales de Godot 3
# aunque peer_link.gd ya estuviera actualizado en disco.
var LINK = Host.sc("res://peer_link.gd") if Host != null else load("res://peer_link.gd")

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
	if OS.get_name() == "Android":
		tokens_path = "user://peer-tokens.json"
	else:
		var base = OS.get_environment("XDG_CONFIG_HOME")
		if base == "":
			base = OS.get_environment("HOME").plus_file(".config")
		tokens_path = base.plus_file("gdtk").plus_file("peer-tokens.json")
	_load_tokens()
	_listen()


# Al reiniciar el shell el proceso anterior puede tener el puerto unos segundos
# (ERR_ALREADY_IN_USE): se reintenta cada LISTEN_RETRY_MS en vez de quedar sordo.
const LISTEN_RETRY_MS = 5000
var _listen_retry_at = 0

# Un stream de input sin datos durante este tiempo se cierra solo (el cliente
# reconecta al próximo lote). Evita conexiones colgadas tras dejar de compartir.
const STREAM_IDLE_MS = 10000


func _listen():
	_listen_retry_at = OS.get_ticks_msec() + LISTEN_RETRY_MS
	var s = TCP_Server.new()
	var err = s.listen(port, "0.0.0.0")
	if err != OK:
		printerr("PeerControl: no pude escuchar en 0.0.0.0:", port, " (", err, "); reintento")
		return
	server = s
	print("PeerControl: escuchando en 0.0.0.0:", port)


func _exit_tree():
	stop()


func stop():
	port = 0   # parado a propósito: _process no reintenta
	if server != null:
		server.stop()
		server = null
	for conn in conns:
		if conn.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			conn.peer.disconnect_from_host()
	conns = []


func listening():
	return server != null and port > 0


# Este canal es el único que lee/escribe el archivo de tokens (ver _save_tokens): el
# shell ya no lo toca, pide los `cli:` por método. Antes los dos escribían el archivo
# entero y un read-modify-write cruzado borraba claves o pisaba un `srv:` con un
# snapshot viejo → el equipo quedaba rechazado ("unauthorized") por sus pares.
func _read_token_file():
	var f = File.new()
	if tokens_path == "" or f.open(tokens_path, File.READ) != OK:
		return {}
	var data = JSON.parse(f.get_as_text()).result
	f.close()
	return data if typeof(data) == TYPE_DICTIONARY else {}


# Este canal es el ÚNICO escritor de peer-tokens.json. Mantiene en memoria las dos
# familias de claves: `srv:` (tokens que ESTE equipo emite a cada par) y `cli:`
# (tokens que el shell presenta a cada par, ver shell._peer_token_get/set). Antes el
# shell reescribía el archivo entero por su lado (read-modify-write) y las dos
# escrituras se pisaban: una actualización perdida dejaba un `cli:` sin escribir o un
# `srv:` pisado por un snapshot viejo, y el par quedaba en `unauthorized` para siempre.
func _load_tokens():
	tokens = {}
	var data = _read_token_file()
	for k in data.keys():
		var key = String(k)
		if (key.begins_with("srv:") or key.begins_with("cli:")) \
				and LINK.valid_hid(key.substr(4)) and String(data[k]) != "":
			tokens[key] = String(data[k])


func _save_tokens():
	if tokens_path == "":
		return
	var f = File.new()
	if f.open(tokens_path, File.WRITE) != OK:
		return
	f.store_string(JSON.print(tokens))
	f.close()


# Token que este equipo debe presentar al par `hid` (clave `cli:`).
func token_for(hid):
	return String(tokens.get("cli:" + String(hid), ""))


# Guarda el token que el par `hid` nos emitió (TOFU). Único escritor.
func set_client_token(hid, tok):
	var id = String(hid)
	if id == "":
		return
	tokens["cli:" + id] = String(tok)
	_save_tokens()


# Olvida los tokens del par (emitido y presentado) en memoria y disco.
func token_forget(hid):
	var id = String(hid)
	tokens.erase("cli:" + id)
	tokens.erase("srv:" + id)
	_save_tokens()


# hids con algún token (cli: o srv:), sin copiar los valores. Ordenado.
func token_hids():
	var out = []
	var seen = {}
	for k in tokens.keys():
		var key = String(k)
		if not (key.begins_with("cli:") or key.begins_with("srv:")):
			continue
		var hid = key.substr(4).strip_edges()
		if hid != "" and not seen.has(hid):
			seen[hid] = true
			out.append(hid)
	out.sort()
	return out


func _send(conn, line):
	if conn.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		conn.peer.put_data(line.to_utf8())


func _process(_delta):
	if server == null:
		if port > 0 and OS.get_ticks_msec() >= _listen_retry_at:
			_listen()
		return
	while server.is_connection_available():
		var peer = server.take_connection()
		peer.set_no_delay(true)
		conns.append({"peer": peer, "buf": PoolByteArray(), "close": false,
			"stream": false, "hid": "", "last": 0})
	for i in range(conns.size() - 1, -1, -1):
		var conn = conns[i]
		if conn.get("stream", false) \
				and OS.get_ticks_msec() - int(conn.get("last", 0)) > STREAM_IDLE_MS:
			conn.close = true
		else:
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
	# Conexión en modo stream: la autenticación ya ocurrió en el handshake; cada
	# línea es sólo {"events":[...]} y NO se responde. Se refresca `last` sólo al
	# recibir datos para que el idle cierre de verdad.
	if conn.get("stream", false):
		if available > 0 and _poll_stream(conn):
			conn.last = OS.get_ticks_msec()
		return
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
	# El handshake de `window_input_stream` deja la conexión abierta; el resto se cierra.
	if not conn.get("stream", false):
		conn.close = true


# Aplica todas las líneas completas del stream; conserva el resto en conn.buf.
# Devuelve false (y marca close) si una línea es inválida o el shell rechaza el lote.
func _poll_stream(conn):
	var buf = conn.buf
	var line_start = 0
	var consumed = 0
	var batches = []
	for i in range(buf.size()):
		if buf[i] == 10:
			if i > line_start:
				var line = buf.subarray(line_start, i - 1).get_string_from_utf8().strip_edges()
				if line != "":
					var events = LINK.parse_window_stream(line)
					if events.empty():
						conn.close = true
						return false
					batches.append(events)
			line_start = i + 1
			consumed = i + 1
	if consumed >= buf.size():
		conn.buf = PoolByteArray()
	elif consumed > 0:
		conn.buf = buf.subarray(consumed, buf.size() - 1)
	if shell == null or not is_instance_valid(shell) \
			or not shell.has_method("_peer_window_input"):
		return false
	for events in batches:
		if not bool(shell._peer_window_input(String(conn.hid), events)):
			conn.close = true
			return false
	return true


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
	if String(r.method) == "direction":
		# Vinculación inicial del Grupo: sin token (como ping). Sólo aplica un DTO
		# validado; no ejecuta nada.
		var dmsg = LINK.direction_message(r.params)
		if dmsg.empty():
			_send(conn, LINK.encode_response(false, "direction inválido"))
			return
		if shell == null or not is_instance_valid(shell) or not shell.has_method("_peer_direction"):
			_send(conn, LINK.encode_response(false, "no disponible"))
			return
		var dok = bool(shell._peer_direction(hid, dmsg))
		_send(conn, LINK.encode_response(dok, "" if dok else "no aplicado"))
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
		# Auto-sanación: un par CONFIRMADO que presenta un token viejo/ausente re-empara
		# en vez de quedar en `unauthorized` para siempre. Antes, si el emisor perdía su
		# `cli:` (o nuestro memoria quedaba desincronizada), no había forma de re-TOFU y
		# todo pedido se rechazaba. No amplía la confianza: un par confirmado ya podía
		# provisionar por TOFU (no se ejecuta nada de un hid NO confirmado).
		if not _peer_is_confirmed(hid):
			_send(conn, LINK.encode_response(false, "unauthorized"))
			return
		known = LINK.new_token()
		tokens["srv:" + hid] = known
		_save_tokens()
		extra["token"] = known
	if shell == null or not is_instance_valid(shell):
		_send(conn, LINK.encode_response(false, "shell busy", extra))
		return
	var params = r.params
	var ok = false
	var err = ""
	match String(r.method):
		"gvd_recv":
			ok = bool(shell._peer_gvd_open(int(params.get("port", 0)), String(params.get("from", "")), hid,
				LINK.video_size(params)))
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
		"share_notify":
			# El `side` ya viene invertido por el emisor: se delega tal cual.
			if not LINK.valid_share_params("share_notify", params):
				err = "parámetros inválidos"
			elif shell.has_method("_peer_share_notify"):
				ok = bool(shell._peer_share_notify(hid, params))
				if not ok:
					err = "no se pudo avisar"
			else:
				err = "no disponible"
		"share_stop":
			if not LINK.valid_share_params("share_stop", params):
				err = "parámetros inválidos"
			elif shell.has_method("_peer_share_stop"):
				ok = bool(shell._peer_share_stop(hid, params))
				if not ok:
					err = "no se pudo detener"
			else:
				err = "no disponible"
		"mv_slot":
			# Host multiview (F3): pide a ESTE equipo que emita hacia su `port`/`slot`.
			# Params validados (puerto/slot/host seguros); la capacidad de emitir un
			# escritorio completo se resuelve en el shell (rechazo honesto, el tile
			# del host queda degradado).
			var mvs = LINK.mv_slot_params(params)
			if mvs.empty():
				err = "parámetros inválidos"
			elif shell.has_method("_peer_mv_slot"):
				ok = bool(shell._peer_mv_slot(hid, mvs))
				if not ok:
					err = "no se pudo emitir"
			else:
				err = "no disponible"
		"mv_stop":
			if shell.has_method("_peer_mv_stop"):
				ok = bool(shell._peer_mv_stop(hid))
				if not ok:
					err = "no se pudo detener"
			else:
				err = "no disponible"
		"clip_set":
			# Portapapeles del Grupo: sólo texto; el token ya autenticó al par.
			var text = params.get("text", "")
			if typeof(text) != TYPE_STRING or text == "" or text.length() > 65536:
				err = "parámetros inválidos"
			elif shell.has_method("_peer_clip_set"):
				ok = bool(shell._peer_clip_set(text))
			else:
				err = "no disponible"
		"expose":
			if shell.has_method("_peer_expose"):
				ok = bool(shell._peer_expose(bool(params.get("on", false))))
			else:
				err = "no disponible"
		"screen_res":
			# El par rotó o cambió de resolución: refleja el `res=` en el layout sin
			# esperar el rescan del Vecindario (hasta 60 s). Volumen chico, sin stream.
			var rs = LINK.video_size(params)
			if rs == Vector2():
				err = "parámetros inválidos"
			elif shell.has_method("_peer_screen_res"):
				ok = bool(shell._peer_screen_res(hid, rs))
				if not ok:
					err = "no aplicado"
			else:
				err = "no disponible"
		"layout":
			# El par cambió su acomodo de pantallas y empuja el del Grupo: se upserta
			# la geometría de los vecinos. Sin eco (no se re-difunde).
			var ls = LINK.layout_screens(params)
			if ls.empty():
				err = "parámetros inválidos"
			elif shell.has_method("_peer_layout"):
				ok = bool(shell._peer_layout(hid, ls))
				if not ok:
					err = "no aplicado"
			else:
				err = "no disponible"
		"media":
			# Controles de audio universales: aplica la acción (up/down/mute) local; el
			# nivel de este equipo no se toca, sólo se repite la acción del emisor.
			var mact = LINK.media_action(params)
			if mact == "":
				err = "parámetros inválidos"
			elif shell.has_method("_peer_media"):
				ok = bool(shell._peer_media(mact))
				if not ok:
					err = "no se pudo aplicar"
			else:
				err = "no disponible"
		"audio_recv":
			# Enviar audio (Grupo): este equipo acepta un túnel de audio SÓLO desde la IP
			# que hizo el pedido; responde el puerto.
			var rport = int(shell._peer_audio_recv(hid, conn.peer.get_connected_host())) \
				if shell.has_method("_peer_audio_recv") else 0
			ok = rport > 0
			if ok:
				extra["port"] = rport
			else:
				err = "no se pudo recibir audio"
		"gvd_size":
			# La ventana compartida cambió de tamaño: el receptor reajusta la suya.
			var vs = LINK.video_size(params)
			if vs == Vector2():
				err = "parámetros inválidos"
			elif shell.has_method("_peer_gvd_size"):
				ok = bool(shell._peer_gvd_size(hid, vs))
			else:
				err = "no disponible"
		"window_input":
			var events = LINK.window_input_events(params)
			if events.empty():
				err = "parámetros inválidos"
			elif shell.has_method("_peer_window_input"):
				ok = bool(shell._peer_window_input(hid, events))
				if not ok:
					err = "ventana no compartida"
			else:
				err = "no disponible"
		"window_input_stream":
			# Handshake del canal persistente: misma autenticación que el resto y,
			# si sale bien, la conexión queda marcada como stream (sin respuesta por
			# lote). Los equipos con shell viejo no conocen el método: su parseo lo
			# rechaza como "bad request" y el cliente cae al `window_input` clásico.
			var ev_stream = LINK.window_input_events(params)
			if ev_stream.empty():
				err = "parámetros inválidos"
			elif not shell.has_method("_peer_window_input"):
				err = "no disponible"
			elif not bool(shell._peer_window_input(hid, ev_stream)):
				err = "ventana no compartida"
			else:
				ok = true
				conn.stream = true
				conn.hid = hid
				conn.last = OS.get_ticks_msec()
				conn.buf = PoolByteArray()
			_send(conn, LINK.encode_response(ok, err, extra))
			if not ok:
				conn.close = true
			return
		"gvd_meta":
			var meta = LINK.video_meta(params)
			if meta.empty():
				err = "parámetros inválidos"
			elif shell.has_method("_peer_gvd_meta"):
				ok = bool(shell._peer_gvd_meta(hid, meta))
			else:
				err = "no disponible"
		"audio_stop":
			ok = shell.has_method("_peer_audio_stop") and bool(shell._peer_audio_stop(hid))
		_:
			err = "método no soportado"
	_send(conn, LINK.encode_response(ok, err, extra))
