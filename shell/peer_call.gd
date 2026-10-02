extends Reference

# Cliente del canal peer (shell/peer_link.gd): manda una petición a un vecino y
# espera la respuesta. Bloqueo acotado (timeout) porque se usa desde acciones de UI
# puntuales, nunca por frame. Devuelve {} si no se pudo o no llegó respuesta.

const LINK = preload("res://peer_link.gd")


static func request(host, ctl_port, hid, token, method, params = {}, timeout_ms = 1500):
	var p = int(ctl_port)
	if String(host).strip_edges() == "" or p <= 0:
		return {}
	var peer = StreamPeerTCP.new()
	if peer.connect_to_host(String(host), p) != OK:
		return {}
	peer.put_data(LINK.encode_request(hid, token, method, params).to_utf8())
	var deadline = OS.get_ticks_msec() + int(timeout_ms)
	var buf = PoolByteArray()
	while OS.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		var avail = peer.get_available_bytes()
		if avail > 0:
			var d = peer.get_partial_data(avail)
			if d[0] == OK:
				buf.append_array(d[1])
				var s = buf.get_string_from_utf8()
				if s.find("\n") >= 0:
					peer.disconnect_from_host()
					return LINK.parse_response(s)
		OS.delay_msec(5)
	peer.disconnect_from_host()
	return {}
