extends Reference

# Cliente del canal peer (shell/peer_link.gd): manda una petición a un vecino y
# espera la respuesta. Bloqueo acotado (timeout) porque se usa desde acciones de UI
# puntuales, nunca por frame. Devuelve {} si no se pudo o no llegó respuesta.

const LINK = preload("res://peer_link.gd")


static func request(host, ctl_port, hid, token, method, params = {}, timeout_ms = 1500):
	var r = request_status(host, ctl_port, hid, token, method, params, timeout_ms)
	return r.response if bool(r.get("ok", false)) else {}


static func request_status(host, ctl_port, hid, token, method, params = {}, timeout_ms = 1500):
	var out = {"ok": false, "error": "", "response": {}}
	var p = int(ctl_port)
	if String(host).strip_edges() == "" or p <= 0:
		out.error = "destino inválido"
		return out
	var peer = StreamPeerTCP.new()
	if peer.connect_to_host(String(host), p) != OK:
		out.error = "no se pudo conectar"
		return out
	var deadline = OS.get_ticks_msec() + int(timeout_ms)
	while OS.get_ticks_msec() < deadline:
		# En este motor StreamPeerTCP no expone poll(): get_status()/get_partial_data()
		# ya sondean el socket internamente (core/io/stream_peer_tcp.cpp).
		var st = peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			break
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			peer.disconnect_from_host()
			out.error = "conexión rechazada"
			return out
		OS.delay_msec(5)
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()
		out.error = "timeout conectando"
		return out
	peer.put_data(LINK.encode_request(hid, token, method, params).to_utf8())
	var buf = PoolByteArray()
	while OS.get_ticks_msec() < deadline:
		# Drenar primero: el servidor responde y cierra enseguida; si se mirara el
		# estado antes, el FIN podía cortar la lectura y perderse la respuesta.
		var avail = peer.get_available_bytes()
		if avail > 0:
			var d = peer.get_partial_data(avail)
			if d[0] == OK:
				buf.append_array(d[1])
				var s = buf.get_string_from_utf8()
				if s.find("\n") >= 0:
					peer.disconnect_from_host()
					var resp = LINK.parse_response(s)
					out.response = resp
					out.ok = not resp.empty()
					if not out.ok:
						out.error = "respuesta inválida"
					elif not bool(resp.get("ok", false)):
						out.error = String(resp.get("error", "rechazado"))
					return out
		elif peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		OS.delay_msec(5)
	peer.disconnect_from_host()
	out.error = "sin respuesta"
	return out


# --- Stream persistente de input de «Pantalla compartida» -----------------------
# A diferencia de `request_status` (una conexión por lote), acá la conexión queda
# abierta: el handshake se hace UNA vez y los lotes siguientes se escriben sin
# esperar respuesta. Estas funciones corren SÓLO desde el Thread del worker.

# Conecta y espera STATUS_CONNECTED; deja TCP_NODELAY activo. Devuelve el peer o null.
static func connect_peer(host, ctl_port, timeout_ms = 1500):
	var p = int(ctl_port)
	if String(host).strip_edges() == "" or p <= 0:
		return null
	var peer = StreamPeerTCP.new()
	if peer.connect_to_host(String(host), p) != OK:
		return null
	var deadline = OS.get_ticks_msec() + int(timeout_ms)
	while OS.get_ticks_msec() < deadline:
		var st = peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			peer.set_no_delay(true)
			return peer
		if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
			peer.disconnect_from_host()
			return null
		OS.delay_msec(5)
	peer.disconnect_from_host()
	return null


# Cierra el peer si sigue conectado. No bloquea (shutdown + close del socket).
static func close_peer(peer):
	if peer != null and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()


# Manda una petición y espera UNA línea de respuesta, SIN cerrar la conexión. La usa
# el handshake de `window_input_stream` para recibir `ok` y un eventual token nuevo.
static func request_on(peer, hid, token, method, params = {}, timeout_ms = 1500):
	var out = {"ok": false, "error": "", "response": {}}
	if peer == null or peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		out.error = "sin conexión"
		return out
	peer.put_data(LINK.encode_request(hid, token, method, params).to_utf8())
	var buf = PoolByteArray()
	var deadline = OS.get_ticks_msec() + int(timeout_ms)
	while OS.get_ticks_msec() < deadline:
		# Drenar primero: el servidor responde enseguida; mirar el estado antes podía
		# cortar la lectura con el FIN y perder la respuesta.
		var avail = peer.get_available_bytes()
		if avail > 0:
			var d = peer.get_partial_data(avail)
			if d[0] == OK:
				buf.append_array(d[1])
				var s = buf.get_string_from_utf8()
				if s.find("\n") >= 0:
					var resp = LINK.parse_response(s)
					out.response = resp
					out.ok = not resp.empty()
					if not out.ok:
						out.error = "respuesta inválida"
					elif not bool(resp.get("ok", false)):
						out.error = String(resp.get("error", "rechazado"))
					return out
		elif peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		OS.delay_msec(5)
	out.error = "sin respuesta"
	return out


# Escribe un lote en el stream abierto, sin esperar respuesta. false si el socket
# ya no está conectado (el worker cierra y reintenta el handshake en el próximo lote).
static func send_stream(peer, events):
	if peer == null or peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return false
	return peer.put_data(LINK.encode_window_stream(events).to_utf8()) == OK

