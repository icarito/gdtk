extends Node

# Receptor KDE Connect (protocolo v8) como servicio de Host. El teléfono es el
# controlador y gdtk es el controlado: el app KDE-Connect Android (o GSConnect)
# descubre a gdtk y habla el wire protocol de kdeconnect-meta (protocol.md):
# packets JSON "id"/"type"/"body" con framing "\n" sobre TCP+TLS.
#
# Alcance v1 (mouse + mixer + mínimo de protocolo):
#   - discovery: UDP en 1716 (broadcast saliente + listener) y listener TCP en
#     1716..1718 (escalera por si otro daemon ocupa 1716)
#   - TLS autofirmado propio (cert persistido, CN = deviceId) en ambos roles
#     (listener acepta, dial saliente conecta)
#   - identity + capabilities; pairing kdeconnect.pair con dos caminos: pedidos
#     entrantes quedan pendientes y se aceptan con el RPC "kdeconnect" de
#     remote.gd (auto_pair sólo para tests); y gdtk pide pair apenas descubre
#     un device nuevo (el usuario acepta en la UI del teléfono)
#   - kdeconnect.mousepad.request / kdeconnect.presenter → Input.parse_input_event
#     (mismo sink que click/move/scroll del control remoto), solo devices pareados
#   - kdeconnect.systemvolume: lista de sinks, set de volumen/mute/default y
#     comandos legacy master; wpctl/pactl en WORKER (Thread+Mutex, contrato §1
#     de SPEC-architecture); el pop del OSD va por shell.system_osd.rpc_action
#     (mismo camino que las teclas multimedia)
#   - kdeconnect.ping / kdeconnect.battery: contador y estado para el RPC
#
# Limitación conocida del engine 3.6 (probada con probe + openssl s_client):
# StreamPeerSSL no pide ni entrega el client cert del par, así que el pin de
# device por cert queda para una versión con módulo C; TLS cifra igual y el
# control libre queda gateado a devices pareados vía store JSON (sin secretos),
# con aceptación explícita de por medio.

const PK = preload("res://kdeconnect_packet.gd")

const DEFAULT_TCP_PORT = 1716
const DEFAULT_UDP_PORT = 1716
const TCP_LADDER = 3          # intenta 1716..1718 si otro daemon tiene 1716
const DIAL_UDP_PORT = 1716
const BROADCAST_MS = 5000
const DIAL_RETRY_MS = 15000
const DIAL_TIMEOUT_MS = 8000
const HANDSHAKE_TIMEOUT_MS = 15000
const PAIR_REQUEST_MS = 30000
const MAX_PACKET_BYTES = 512 * 1024
const LINE_FEED = 10
const MASTER_STEP_PCT = 5

var shell = null          # lo setea Host/Main (main.gd _handoff_wire), opcional
var do_broadcast = true   # los tests lo apagan: no mandar broadcast reales
var auto_pair = false     # pairings entrantes sin confirmación (sólo tests)
var device_id = ""
var device_name = "gdtk"

var tcp = null
var tcp_port = 0
var udp = null
var udp_port = 0

var conns = []            # links TLS activos (pre-identity o con device_id)
var dials = []            # conexiones de salida en curso (TCP → TLS)
var dialing = {}          # device_id → {"ip","port"} en curso de dial
var pair_requested = {}   # device_id → true: ya pedimos pair esta sesión
var pair_requests = []    # [{"device_id","name","ms"}] esperando el usuario
var known = {}            # device_id → {"ip","port","name","last_ms","dial_ms"}
var store = {"self": {"device_id": "", "name": "gdtk"}, "devices": {}}
var battery = {}          # {"charge","charging"} si el teléfono lo manda
var pings = 0

var event_queue = []      # InputEvents → Input.parse_input_event (hasta 8/frame)
var parse_events = true   # los tests lo apagan para inspeccionar la cola cruda
var _button_mask = 0
var _bcast_last = 0
var _store_path = ""

# worker de volumen (Thread + Mutex + Semaphore; patrón applet_volume):
var _worker = null
var _worker_mutex = Mutex.new()
var _worker_run = false
var _worker_jobs = []
var _worker_results = []
var _wpctl = ""
var _pactl = ""


func start(target_shell, opts = {}):
	shell = target_shell
	do_broadcast = bool(opts.get("broadcast", OS.get_environment("GDTK_KDE_BROADCAST") != "0"))
	auto_pair = bool(opts.get("auto_pair", OS.get_environment("GDTK_KDE_AUTOPAIR") == "1"))
	_setup_store_path(opts)
	_load_store()
	_setup_identity()
	_check_cert()
	tcp_port = int(opts.get("tcp_port", _env_port("GDTK_KDE_TCP", DEFAULT_TCP_PORT)))
	udp_port = int(opts.get("udp_port", _env_port("GDTK_KDE_UDP", DEFAULT_UDP_PORT)))
	var skip_tools = OS.get_environment("GDTK_KDE_SKIP_TOOLS") == "1"
	_worker_tool("wpctl", "GDTK_KDE_WPCTL", skip_tools)
	_worker_tool("pactl", "GDTK_KDE_PACTL", skip_tools)
	if tcp_port > 0:
		_open_tcp()
	if udp_port > 0:
		_open_udp()
	var no_worker = OS.get_environment("GDTK_KDE_NO_WORKER") == "1"
	if not no_worker and (_wpctl != "" or _pactl != ""):
		_worker_launch()
	set_process(true)
	print("KdeConnect: device_id=", device_id, " name=", device_name,
		" tcp=", tcp_port, " udp=", udp_port,
		" auto_pair=", auto_pair, " pareados=", store.devices.keys().size())


func _env_port(env, default):
	var v = OS.get_environment(env)
	return int(v) if v != "" else default


func _setup_store_path(opts):
	var base = ""
	if opts.has("store_dir"):
		base = str(opts.store_dir)
	elif OS.get_environment("XDG_STATE_DIR") != "":
		base = OS.get_environment("XDG_STATE_DIR").plus_file("gdtk")
	elif OS.get_environment("XDG_RUNTIME_DIR") != "":
		base = OS.get_environment("XDG_RUNTIME_DIR").plus_file("gdtk")
	else:
		base = OS.get_environment("HOME").plus_file(".local").plus_file("state").plus_file("gdtk")
	_store_path = base.plus_file("kdeconnect-pair.json")


# --- identidad, store, cert ---------------------------------------------------

func _setup_identity():
	if PK.valid_device_id(str(store["self"].get("device_id", ""))):
		device_id = store["self"]["device_id"]
	else:
		# 32 hex alfanuméricos (convención UUIDv4 sin guiones).
		device_id = Crypto.new().generate_random_bytes(16).hex_encode()
		store["self"]["device_id"] = device_id
		_save_store()
	var env_name = OS.get_environment("GDTK_KDE_NAME")
	if env_name != "":
		device_name = PK.sanitize_device_name(env_name)
	else:
		device_name = PK.sanitize_device_name(str(store["self"].get("name", "gdtk")))
		store["self"]["name"] = device_name


func _load_store():
	var dir = Directory.new()
	dir.make_dir_recursive(_store_path.get_base_dir())
	var f = File.new()
	if f.file_exists(_store_path) and f.open(_store_path, File.READ) == OK:
		var parsed = PK.parse(f.get_as_text())
		f.close()
		if parsed != null:
			store = parsed
			if typeof(store.get("self", null)) != TYPE_DICTIONARY:
				store["self"] = {"device_id": "", "name": "gdtk"}
			if typeof(store.get("devices", null)) != TYPE_DICTIONARY:
				store["devices"] = {}


func _save_store():
	var tmp = _store_path + ".tmp"
	var f = File.new()
	if f.open(tmp, File.WRITE) != OK:
		printerr("KdeConnect: no se pudo escribir ", _store_path)
		return
	f.store_string(PK.encode(store))
	f.close()
	Directory.new().rename(tmp, _store_path)
	OS.execute("chmod", ["600", _store_path], true)


func _check_cert():
	# Cert TLS propio con CN = deviceId, persistido junto al store: regenerarlo
	# en cada arranque invalidaría el pin que el teléfono haga de nosotros.
	var dir_path = _store_path.get_base_dir()
	var cert = X509Certificate.new()
	var key = CryptoKey.new()
	var cert_path = dir_path.plus_file("gdtk-kdeconnect.crt")
	var key_path = dir_path.plus_file("gdtk-kdeconnect.key")
	if cert.load(cert_path) != OK or key.load(key_path) != OK:
		if not _provision_cert(cert_path, key_path):
			printerr("KdeConnect: sin cert TLS propio; sockets off")
			set_meta("tls_cert", null)
			set_meta("tls_key", null)
			return
		if cert.load(cert_path) != OK or key.load(key_path) != OK:
			printerr("KdeConnect: el cert provisionado no sirve; sockets off")
			set_meta("tls_cert", null)
			set_meta("tls_key", null)
			return
	set_meta("tls_cert", cert)
	set_meta("tls_key", key)


# Provisión por openssl CLI: un único spawn (sólo cuando no hay cert aún).
# El Crypto.generate_self_signed_certificate del fork está DESCARTADO: genera
# un PEM de 54 bytes que él mismo no parsea (biseión completa hecho en probe).
func _provision_cert(cert_path, key_path):
	var subj = "/CN=" + device_id
	var res = OS.execute("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
		"-keyout", key_path, "-out", cert_path, "-days", "3650", "-subj", subj], true)
	if res != 0:
		printerr("KdeConnect: openssl falló al provisionar (rc=", res, ")")
		return false
	OS.execute("chmod", ["600", key_path], true)
	var chk = File.new()
	if not chk.file_exists(cert_path) or not chk.file_exists(key_path):
		printerr("KdeConnect: openssl no dejó los archivos del cert")
		return false
	return true


# --- sockets -------------------------------------------------------------------

func _open_tcp():
	tcp = TCP_Server.new()
	for i in range(TCP_LADDER):
		var port = tcp_port + i
		if tcp.listen(port, "0.0.0.0") == OK:
			tcp_port = port
			print("KdeConnect: escuchando TCP ", port)
			return
	printerr("KdeConnect: sin puerto TCP; listener off")
	tcp = null
	tcp_port = 0


func _open_udp():
	udp = PacketPeerUDP.new()
	if udp.listen(udp_port, "0.0.0.0") != OK:
		printerr("KdeConnect: UDP ", udp_port, " ocupado; discovery UDP off")
		udp = null
		udp_port = 0
		return
	udp.set_broadcast_enabled(true)
	print("KdeConnect: UDP ", udp_port)


func _broadcast_identity():
	if udp == null or not do_broadcast or tcp_port <= 0:
		return
	var idpk = PK.identity_packet(device_id, device_name, tcp_port)
	udp.set_dest_address("255.255.255.255", DIAL_UDP_PORT)
	udp.put_packet((PK.encode(idpk) + "\n").to_utf8())


# --- loop principal (por frame, no bloqueante) ---------------------------------

func _process(_delta):
	var now = OS.get_ticks_msec()
	if udp != null:
		if do_broadcast and now - _bcast_last >= BROADCAST_MS:
			_bcast_last = now
			_broadcast_identity()
		while udp.get_available_packet_count() > 0:
			var datagram = udp.get_packet()
			var ip = udp.get_packet_ip()
			_udp_identity(ip, PK.parse(datagram.get_string_from_utf8()), now)
	if tcp != null:
		while tcp.is_connection_available():
			var peer = tcp.take_connection()
			_new_inbound(peer, peer.get_connected_host(), now)
	for i in range(dials.size() - 1, -1, -1):
		var d = dials[i]
		if _poll_dial(d, now):
			dials.remove(i)
	for i in range(conns.size() - 1, -1, -1):
		var conn = conns[i]
		_poll_conn(conn, now)
		if conn.close:
			conns.remove(i)
	for i in range(pair_requests.size() - 1, -1, -1):
		if now - int(pair_requests[i].ms) > PAIR_REQUEST_MS:
			pair_requests.remove(i)
	_drain_worker()
	_drain_events()


func _udp_identity(ip, packet, now):
	if packet == null or PK.packet_type(packet) != PK.IDENTITY:
		return
	var body = PK.body_of(packet)
	var did = str(body.get("deviceId", ""))
	if did == device_id or not PK.valid_device_id(did):
		return
	remember_device(did, str(body.get("deviceName", "")), ip,
		int(body.get("tcpPort", DEFAULT_TCP_PORT)), now)
	_maybe_dial(did, now)


func _maybe_dial(did, now):
	# FS del dial saliente: device conocido, sin conexión activa, sin dial en
	# vuelo y con el intervalo de reintento pasado.
	var rec = known.get(did, null)
	if rec == null:
		return
	if _connected_device(did) or dialing.has(did):
		return
	var dial_ms = int(rec.get("dial_ms", 0))
	if dial_ms != 0 and now - dial_ms < DIAL_RETRY_MS:
		return
	rec["dial_ms"] = int(now)
	dialing[did] = {"ip": rec.ip, "port": int(rec.port)}
	_dial(str(rec.ip), int(rec.port), did)


func _connected_device(did):
	for c in conns:
		if c.device_id == did and not c.close:
			return true
	return false


func _dial(ip, port, did):
	var t = StreamPeerTCP.new()
	t.connect_to_host(ip, int(port))
	var d = {
		"ip": str(ip), "port": int(port), "tcp": t, "at": OS.get_ticks_msec(),
		"ssl": StreamPeerSSL.new(), "wrapped": false, "dial_id": str(did),
	}
	d.ssl.blocking_handshake = false
	dials.append(d)


func _poll_dial(d, now):
	# true = ya no importa (promovido a conn, muerto o expirado).
	var st = d.tcp.get_status()
	if not d.wrapped:
		if st == StreamPeerTCP.STATUS_CONNECTED:
			var err = d.ssl.connect_to_stream(d.tcp)
			d.wrapped = true
			if err == OK:
				return false
		elif st == StreamPeerTCP.STATUS_ERROR:
			dialing.erase(d.dial_id)
			return true
		elif now - d.at > DIAL_TIMEOUT_MS:
			dialing.erase(d.dial_id)
			return true
		return false
	d.ssl.poll()
	var s = d.ssl.get_status()
	if s == StreamPeerSSL.STATUS_CONNECTED:
		var conn = _new_conn(d.ssl, d.ip, true, now)
		conns.append(conn)
		dialing.erase(d.dial_id)
		return true
	if s == StreamPeerSSL.STATUS_ERROR:
		dialing.erase(d.dial_id)
		return true
	return false


# --- conexión: TLS + identity + framing ----------------------------------------

func _new_inbound(peer_tcp, ip, now):
	var cert = _tls_cert()
	var key = _tls_key()
	var wrap = StreamPeerSSL.new()
	wrap.blocking_handshake = false
	var conn = _new_conn(wrap, str(ip), false, now)
	var err = wrap.accept_stream(peer_tcp, key, cert)
	if err != OK or cert == null or key == null:
		printerr("KdeConnect: TLS entrante no arrancó (", err, "); descartado")
		conn.close = true
		return
	conns.append(conn)
	print("KdeConnect: conexión entrante desde ", ip)


func _tls_cert():
	return get_meta("tls_cert")


func _tls_key():
	return get_meta("tls_key")


func _new_conn(tcp_stream, ip, outbound, now):
	# El par `tcp_stream` ya viene envuelto por quien armó el link:
	# StreamPeerSSL con blocking_handshake=false, listo para su poll por frame.
	return {
		"ssl": tcp_stream, "buf": PoolByteArray(), "ip": str(ip),
		"outbound": outbound, "device_id": "", "device_name": "", "device_type": "",
		"paired": false, "identity_sent": false, "pair_sent": false,
		"close": false, "at": int(now),
	}


func _poll_conn(conn, now):
	if conn.close:
		return
	conn.ssl.poll()
	var st = conn.ssl.get_status()
	if st == StreamPeerSSL.STATUS_HANDSHAKING:
		if now - conn.at > HANDSHAKE_TIMEOUT_MS:
			conn.close = true
			return
		return  # handshake sigue; timeout cubierto por HANDSHAKE_TIMEOUT_MS
	if st == StreamPeerSSL.STATUS_ERROR or st == StreamPeerSSL.STATUS_DISCONNECTED:
		conn.close = true
		_clear_session_pair_gate(conn.device_id)
		return
	if not conn.identity_sent:
		conn.identity_sent = true
		_send_packet(conn, PK.identity_packet(device_id, device_name, tcp_port))
	var avail = conn.ssl.get_available_bytes()
	if avail > 0:
		var data = conn.ssl.get_partial_data(avail)
		if data[0] != OK:
			conn.close = true
			_clear_session_pair_gate(conn.device_id)
			return
		var buf = conn.buf
		buf.append_array(data[1])
		conn.buf = buf
	_consume_lines(conn)


func _consume_lines(conn):
	while true:
		var idx = -1
		for i in range(conn.buf.size()):
			if conn.buf[i] == LINE_FEED:
				idx = i
				break
		if idx < 0:
			break
		var line_bytes = conn.buf.subarray(0, idx - 1)
		if idx + 1 <= conn.buf.size() - 1:
			conn.buf = conn.buf.subarray(idx + 1, conn.buf.size() - 1)
		else:
			conn.buf = PoolByteArray()
		if line_bytes.size() > MAX_PACKET_BYTES:
			conn.close = true
			return
		if line_bytes.size() > 0:
			_on_line(conn, line_bytes.get_string_from_utf8())


func _send_packet(conn, packet):
	if conn.close:
		return
	conn.ssl.put_data((PK.encode(packet) + "\n").to_utf8())


func _clear_session_pair_gate(did):
	if did != "":
		pair_requested.erase(did)


# --- dispatch --------------------------------------------------------------------

func _on_line(conn, line):
	var packet = PK.parse(line)
	if packet == null:
		return
	var type = PK.packet_type(packet)
	if type == PK.IDENTITY:
		_on_identity(conn, PK.body_of(packet))
		return
	if conn.device_id == "":
		return  # sin identity no se acepta nada (exigencia del spec v8)
	if not conn.paired and type != PK.PAIR:
		return  # gate v1: los plugins requieren estar pareado
	match type:
		PK.PAIR:
			_on_pair(conn, PK.body_of(packet))
		PK.MOUSEPAD_REQUEST:
			_on_mousepad(conn, PK.body_of(packet))
		PK.PRESENTER:
			for ev in PK.presenter_events(PK.body_of(packet)):
				_enqueue_event(ev)
		PK.SYSTEMVOLUME_REQ:
			_on_volume_request(conn, PK.body_of(packet))
		PK.PING:
			pings += 1
			print("KdeConnect: ping desde ", conn.device_name)
		PK.BATTERY:
			var body = PK.body_of(packet)
			if body.has("currentCharge") and int(body.currentCharge) >= 0:
				battery = {"charge": int(body.currentCharge),
					"charging": bool(body.get("isCharging", false))}
		_:
			pass


func _on_identity(conn, body):
	var did = str(body.get("deviceId", ""))
	if did == device_id or not PK.valid_device_id(did):
		conn.close = true
		return
	# Un solo link por deviceId: la conexión más nueva gana; la vieja se cierra.
	for other in conns:
		if other != conn and other.device_id == did:
			other.close = true
	conn.device_id = did
	conn.device_name = PK.sanitize_device_name(str(body.get("deviceName", "phone")))
	conn.device_type = str(body.get("deviceType", "phone"))
	remember_device(did, conn.device_name, conn.ip,
		int(body.get("tcpPort", DEFAULT_TCP_PORT)), OS.get_ticks_msec())
	conn.paired = store.devices.has(did)
	print("KdeConnect: %s device %s (%s...) pareado=%s" % [
		"dial propia" if conn.outbound else "entrante" , conn.device_name,
		did.substr(0, 8), str(conn.paired)])
	if not conn.paired and not pair_requested.has(did):
		pair_requested[did] = true
		_send_packet(conn, PK.pair_packet(true))
		print("KdeConnect: pedido de pair hacia ", conn.device_name)


func remember_device(did, name, ip, port, now):
	var label = ""
	if str(name) != "":
		label = PK.sanitize_device_name(name)
	else:
		label = ""
	var rec = known.get(did, null)
	if rec == null:
		rec = {"ip": str(ip), "port": int(port), "name": label, "last_ms": int(now),
			"dial_ms": 0}
		known[did] = rec
	else:
		if str(name) != "":
			rec.name = label
		rec.port = int(port)
		rec.last_ms = int(now)


# --- pairing ----------------------------------------------------------------------

func _on_pair(conn, body):
	var did = conn.device_id
	if bool(body.get("pair", false)):
		if conn.paired:
			return
		if auto_pair:
			var ok = _pair_accept_internal(conn)
			_send_packet(conn, PK.pair_packet(ok))
		else:
			pair_requests.append({
				"device_id": did,
				"name": conn.device_name,
				"ms": OS.get_ticks_msec(),
			})
			print("KdeConnect: pedido de pair PENDIENTE de ", conn.device_name,
				" (", did.substr(0, 8), "...) — hay aceptarlo con el RPC kdeconnect")
	else:
		# pair:false = rechazo de nuestro pedido o desparéo del teléfono.
		_drop_request_for(did)
		pair_requested.erase(did)
		if store.devices.has(did):
			print("KdeConnect: despareo pedido por ", conn.device_name)
			_store_remove(did)
			conn.paired = false
		conn.close = true


func _drop_request_for(did):
	for i in range(pair_requests.size() - 1, -1, -1):
		if str(pair_requests[i].device_id) == did:
			pair_requests.remove(i)


func _pair_accept_internal(conn):
	var did = conn.device_id
	if did == "":
		return false
	print("KdeConnect: pair ACEPTADO con ", conn.device_name)
	store.devices[did] = {
		"name": conn.device_name, "ip": conn.ip,
		"first_ms": OS.get_ticks_msec(), "last_ms": OS.get_ticks_msec(),
	}
	_save_store()
	conn.paired = true
	_drop_request_for(did)
	return true


func _store_remove(did):
	if store.devices.has(did):
		store["devices"].erase(did)
		_save_store()
		return true
	return false


func control(params = {}):
	# API del RPC "kdeconnect" para remote.gd vía Host.kdeconnect_control.
	var op = str(params.get("op", "state"))
	var did = str(params.get("device", ""))
	match op:
		"state":
			return state()
		"pair_accept":
			for r in pair_requests:
				if str(r.device_id) == did:
					for c in conns:
						if c.device_id == did and not c.close:
							var ok = _pair_accept_internal(c)
							if ok:
								_send_packet(c, PK.pair_packet(true))
							return {"ok": ok}
					_drop_request_for(did)
					return {"ok": false, "error": "device desconectado"}
			return {"ok": false, "error": "sin pedido pendiente"}
		"pair_reject":
			_drop_request_for(did)
			for c in conns:
				if c.device_id == did and not c.close:
					if c.paired:
						_store_remove(did)
						c.paired = false
					_send_packet(c, PK.pair_packet(false))
					c.close = true
					break
			return {"ok": true}
		"unpair":
			for c in conns:
				if c.device_id == did and not c.close:
					_send_packet(c, PK.pair_packet(false))
					c.close = true
					pair_requested.erase(did)
					break
			return {"ok": _store_remove(did)}
		"broadcast":
			_bcast_last = 0
			if do_broadcast:
				_broadcast_identity()
			return {"ok": true}
		_:
			return {"ok": false, "error": "op desconocida: " + op}


func state():
	var devices = []
	for c in conns:
		if c.device_id != "" and not c.close:
			devices.append({"device_id": c.device_id, "name": c.device_name,
				"type": c.device_type, "ip": c.ip, "paired": c.paired,
				"outbound": c.outbound})
	var requests = []
	for r in pair_requests:
		requests.append({"device_id": str(r.device_id), "name": str(r.name)})
	return {
		"device_id": device_id,
		"device_name": device_name,
		"tcp_port": tcp_port,
		"udp_port": udp_port,
		"do_broadcast": do_broadcast,
		"auto_pair": auto_pair,
		"connections": devices,
		"pair_requests": requests,
		"paired_devices": store.devices.keys(),
		"battery": battery,
		"pings": pings,
		"pending_events": event_queue.size(),
	}


# --- mouse / teclado ---------------------------------------------------------------

func _on_mousepad(conn, body):
	# El gate de pareado ya lo validó _on_line; el doble check no costaría.
	var echo = PK.mousepad_echo(body)
	if echo != null:
		_send_packet(conn, echo)
	for desc in PK.mousepad_events(body):
		_enqueue_event(desc)


func _enqueue_event(desc):
	match str(desc.get("k", "")):
		"motion":
			var pos = get_viewport().get_mouse_position()
			var dx = float(desc.dx)
			var dy = float(desc.dy)
			var ev = InputEventMouseMotion.new()
			ev.button_mask = _button_mask
			ev.position = pos + Vector2(dx, dy)
			ev.global_position = ev.position
			ev.relative = Vector2(dx, dy)
			event_queue.append(ev)
		"scroll":
			var pos = get_viewport().get_mouse_position()
			if _button_mask != 0:
				var evm = InputEventMouseMotion.new()
				evm.button_mask = _button_mask
				evm.position = pos
				evm.global_position = pos
				evm.relative = Vector2(0, 0)
				event_queue.append(evm)
			_scroll_steps(pos, float(desc.dx), float(desc.dy))
		"button":
			event_queue.append(_new_button_event(int(desc.code), bool(desc.pressed),
				int(desc.get("clicks", 1))))
		"key":
			_enqueue_key_event(desc)


func _new_button_event(code, pressed, clicks):
	var pos = get_viewport().get_mouse_position()
	var ev = InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = code
	ev.pressed = pressed
	ev.doubleclick = clicks >= 2
	var bit = 1 << (code - 1)
	_button_mask = (_button_mask | bit) if pressed else (_button_mask & ~bit)
	ev.button_mask = _button_mask
	return ev


func _scroll_steps(pos, dx, dy):
	# Igual contrato de ejes que remote.gd _scroll: dy>0 → BUTTON_WHEEL_DOWN,
	# dx>0 → BUTTON_WHEEL_RIGHT.
	if dy != 0.0:
		_wheel_steps(pos, dy, BUTTON_WHEEL_DOWN, BUTTON_WHEEL_UP)
	if dx != 0.0:
		_wheel_steps(pos, dx, BUTTON_WHEEL_RIGHT, BUTTON_WHEEL_LEFT)


func _wheel_steps(pos, amount, positive, negative):
	var steps = int(abs(amount))
	if steps < 1:
		steps = 1
	if steps > 10:
		steps = 10
	var button = positive if amount > 0.0 else negative
	for i in range(steps):
		event_queue.append(_new_button_event(button, true, 1))
		event_queue.append(_new_button_event(button, false, 1))


func _enqueue_key_event(desc):
	# press + release por request; los modificadores van como flags en los dos
	# eventos (macro-secuencias quedan para el teclado del control remoto).
	for pressed in [true, false]:
		var ev = InputEventKey.new()
		ev.scancode = int(desc.code)
		ev.physical_scancode = int(desc.code)
		ev.unicode = int(desc.get("unicode", 0))
		ev.shift = bool(desc.get("shift", false))
		ev.control = bool(desc.get("ctrl", false))
		ev.alt = bool(desc.get("alt", false))
		ev.meta = bool(desc.get("meta", false))
		ev.pressed = pressed
		event_queue.append(ev)


func _drain_events():
	# Hasta 8 por frame: un click lleva 3 eventos y las ráfagas de motion no
	# se dejan encolar infinito si el teléfono manda más de lo renderizable.
	# (parse_events queda off en tests para inspeccionar la cola cruda.)
	var n = 0
	while parse_events and n < 8 and event_queue.size() > 0:
		Input.parse_input_event(event_queue.pop_front())
		n += 1


# --- volumen: worker (Thread) + replies -----------------------------------------------

func _worker_tool(prog, env, skip_tools):
	if skip_tools:
		return
	var overridden = OS.get_environment(env)
	if overridden != "":
		if prog == "wpctl":
			_wpctl = overridden
		else:
			_pactl = overridden
		return
	var out = []
	var rc = OS.execute("which", [prog], true, out, true)
	var found = rc == 0 and out.get_string_from_utf8().strip_edges() != ""
	if prog == "wpctl":
		_wpctl = prog if found else ""
	else:
		_pactl = prog if found else ""


func _worker_launch():
	if _worker != null:
		return
	_worker_run = true
	_worker = Thread.new()
	_worker.start(self, "_worker_loop", null, Thread.PRIORITY_NORMAL)
	# Nota de diseño: el worker anda a poll (Mutex + delay) y no en Semaphore
	# wait: en la salida del proceso un semáforo sin post dejaría el hilo vivo
	# más allá del SIGTERM y el proceso se banca en el join del exit.


func _worker_loop(_ud):
	while true:
		var job = null
		_worker_mutex.lock()
		if _worker_jobs.size() > 0:
			job = _worker_jobs.pop_front()
		_worker_mutex.unlock()
		if job != null:
			var res = _volume_apply(job)
			_worker_mutex.lock()
			_worker_results.append(res)
			_worker_mutex.unlock()
			continue
		if not _worker_run:
			break
		OS.delay_msec(20)


func _submit_job(device_of, kind, req = {}):
	var job = {"device_of": device_of, "kind": kind, "req": req}
	_worker_mutex.lock()
	_worker_jobs.append(job)
	_worker_mutex.unlock()


func _drain_worker():
	while true:
		_worker_mutex.lock()
		var res = _worker_results.pop_front() if _worker_results.size() > 0 else null
		_worker_mutex.unlock()
		if res == null:
			return
		for packet in res.get("packets", []):
			for c in conns:
				if c.device_id == res.device_of and not c.close:
					_send_packet(c, packet)


# aplicar y consultar audio — SOLO el worker (thread aparte) ejecuta comandos -----

func _run_tool(prog, argv):
	var out = []
	var rc = OS.execute(prog, argv, true, out, true)
	return {"code": rc, "text": out.get_string_from_utf8()}


func _default_sink():
	if _pactl == "":
		return ""
	return PK.parse_pactl_default_sink(_run_tool(_pactl, ["info"]).text)


func _sink_state(sink_name):
	var state = {"name": str(sink_name), "pct": -1.0, "muted": false, "default": false}
	if _pactl == "":
		return state
	var vol = _run_tool(_pactl, ["get-sink-volume", str(sink_name)])
	state.pct = float(PK.parse_pactl_volume(vol.text).pct)
	var mut = _run_tool(_pactl, ["get-sink-mute", str(sink_name)])
	state.muted = bool(PK.parse_pactl_mute(mut.text).muted)
	return state


func _volume_apply(job):
	# Corre en el worker: OS.execute con captura aca no cruje (el frame de
	# render no se detiene; los snapshots llegan por _drain_worker).
	var did = str(job.get("device_of", ""))
	var kind = str(job.get("kind", ""))
	var req = job.get("req", {})
	var packets = []
	if kind == "sinks":
		packets = _sink_list_packets()
	elif kind == "set":
		packets = _sink_set_packets(req)
	elif kind == "master":
		_master_command_worker(req)
		var default_name = _default_sink()
		if default_name == "":
			default_name = "@DEFAULT_SINK@"
		packets = [PK.build_stream_state(default_name, _status_pct(), _status_muted(), true)]
	elif kind == "master_state":
		var default_name = _default_sink()
		if default_name == "":
			default_name = "@DEFAULT_SINK@"
		packets = [PK.build_stream_state(default_name, _status_pct(), _status_muted(), true)]
	return {"device_of": did, "packets": packets}


func _master_command_worker(req):
	# up/down/mute/unmute por wpctl (o pactl) analizados fuera del frame.
	var cmd = str(req.get("command", ""))
	if cmd == "volumeup":
		_master_step("+%d%%" % MASTER_STEP_PCT)
	elif cmd == "volumedown":
		_master_step("-%d%%" % MASTER_STEP_PCT)
	elif cmd == "mute" or cmd == "unmute":
		var on = "1" if cmd == "mute" else "0"
		if _pactl != "":
			_run_tool(_pactl, ["set-sink-mute", "@DEFAULT_SINK@", on])
		elif _wpctl != "":
			_run_tool(_wpctl, ["set-mute", "@DEFAULT_AUDIO_SINK@",
				"toggle" if cmd == "mute" else on])


func _sink_list_packets():
	if _pactl == "":
		return []
	var raw = PK.parse_pactl_sinks(_run_tool(_pactl, ["list", "short", "sinks"]).text)
	if raw.size() == 0:
		return []
	var default_name = _default_sink()
	var sinks = []
	for entry in raw:
		var state = _sink_state(str(entry.name))
		state["name"] = str(entry.name)
		state["default"] = (str(entry.name) == default_name)
		sinks.append(state)
	var packets = [PK.build_sink_list(sinks)]
	return packets


func _sink_set_packets(req):
	var sink_name = str(req.get("name", ""))
	if _pactl == "" or sink_name == "":
		return []
	if req.has("volume_pct"):
		var pct = clamp(float(req.volume_pct), 0.0, 150.0)
		_run_tool(_pactl, ["set-sink-volume", sink_name, "%d%%" % int(round(pct))])
	if req.has("muted"):
		_run_tool(_pactl, ["set-sink-mute", sink_name, "1" if bool(req.muted) else "0"])
	if bool(req.get("set_default", false)):
		_run_tool(_pactl, ["set-default-sink", sink_name])
	var state = _sink_state(sink_name)
	state["default"] = (sink_name == _default_sink())
	var packets = [PK.build_stream_state(sink_name, state.pct, state.muted, state.default)]
	return packets


func _status_pct():
	if _wpctl != "":
		var v = PK.parse_wpctl_volume(_run_tool(_wpctl, ["get-volume", "@DEFAULT_AUDIO_SINK@"]).text)
		if float(v.pct) >= 0.0:
			return float(v.pct)
	if _pactl != "":
		var d = _default_sink()
		if d != "":
			return float(PK.parse_pactl_volume(_run_tool(_pactl, ["get-sink-volume", d]).text).pct)
	return -1.0


func _status_muted():
	if _wpctl != "":
		var v = PK.parse_wpctl_volume(_run_tool(_wpctl, ["get-volume", "@DEFAULT_AUDIO_SINK@"]).text)
		if float(v.pct) >= 0.0:
			return bool(v.muted)
	if _pactl != "":
		var d = _default_sink()
		if d != "":
			return bool(PK.parse_pactl_mute(_run_tool(_pactl, ["get-sink-mute", d]).text).muted)
	return false


# --- volumen: request → jobs -------------------------------------------------------

func _on_volume_request(conn, body):
	if not conn.paired:
		return
	var req = PK.volume_request(body)
	if req == null:
		return
	match str(req.get("k", "")):
		"sinks":
			_submit_job(conn.device_id, "sinks")
		"set":
			_submit_job(conn.device_id, "set", req)
		"master":
			_master_command(conn.device_id, str(req.get("command", "")))


func _master_command(did, command):
	# up/down/mute usan el MISMO camino que las teclas multimedia (pop del OSD
	# Sugar + paso sobre wpctl/pactl en system_osd). Sin OSD, o en unmute: se
	# aplica en el worker con wpctl/pactl directos (el frame no se detiene).
	var usable = shell != null and is_instance_valid(shell) and shell.get("system_osd") != null
	if usable and (command == "volumeup" or command == "volumedown" or command == "mute"):
		var action = {"volumeup": "up", "volumedown": "down", "mute": "mute"}[command]
		shell.system_osd.rpc_action({"action": action})
	elif command != "":
		_submit_job(did, "master", {"command": command})
	_submit_job(did, "master_state")


func _master_step(delta_pct):
	if _wpctl != "":
		_run_tool(_wpctl, ["set-volume", "@DEFAULT_AUDIO_SINK@", delta_pct])
	elif _pactl != "":
		_run_tool(_pactl, ["set-sink-volume", "@DEFAULT_SINK@", delta_pct])


# --- teardown -----------------------------------------------------------------------

func _exit_tree():
	_worker_run = false
	# el worker anda a poll de 20ms: en el peor caso terminta mismo; su trabajo
	# en vuelo simplemente cae con la sesión.
	OS.delay_msec(30)
	if _worker != null and _worker.is_active():
		_worker.wait_to_finish()
	_worker = null
	if udp != null:
		udp.close()
		udp = null
	if tcp != null:
		tcp.stop()
		tcp = null
	for c in conns:
		c.close = true
	conns = []
	dials = []
