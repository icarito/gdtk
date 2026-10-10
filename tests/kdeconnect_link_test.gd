extends SceneTree

# E2E del receptor KDE Connect (shell/kdeconnect_link.gd) con un peer real
# (cliente TLS "teléfono" en este mismo proceso) y stubs pactl/wpctl (statefuls,
# en GDTK_TEST_DIR). Ejercita roles TLS, framing por líneas, el gate de no
# pareados y los dos caminos de pairing SIN auto_pair. Correr:
#   env -u WAYLAND_DISPLAY -u DISPLAY SDL_VIDEODRIVER=offscreen \
#   godot --no-window --path shell -s $PWD/tests/kdeconnect_link_test.gd
# GDTK_TEST_DIR es opcional (default /tmp/gdtk-kde-link-test).

const PORT = 18510
const DID = "aaaa1111bbbb2222cccc3333dddd4444"  # 32 chars válidos

var failed = 0
var test_dir = ""
var drv = null


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func conclude(reason = "e2e completo"):
	print("RESULT: ", reason, " fail=", failed)
	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _init():
	test_dir = OS.get_environment("GDTK_TEST_DIR")
	if test_dir == "":
		test_dir = "/tmp/gdtk-kde-link-test"
	OS.execute("sh", ["-c", "rm -rf '" + test_dir + "'; mkdir -p '" + test_dir + "/bin'"], true)
	_write_stub("pactl", _pactl_stub())
	_write_stub("wpctl", _wpctl_stub())
	# Entorno del link: sin auto_pair, sin broadcast, stubs como tools.
	OS.set_environment("GDTK_KDE_AUTOPAIR", "0")
	OS.set_environment("GDTK_KDE_BROADCAST", "0")
	OS.set_environment("GDTK_KDE_NAME", "gdtk-test")
	OS.set_environment("GDTK_KDE_SKIP_TOOLS", "0")
	OS.set_environment("GDTK_KDE_WPCTL", test_dir + "/bin/wpctl")
	OS.set_environment("GDTK_KDE_PACTL", test_dir + "/bin/pactl")
	drv = Driver.new()
	drv.outer = self
	root.add_child(drv)


func _write_stub(name, text):
	var path = test_dir + "/bin/" + name
	var f = File.new()
	f.open(path, File.WRITE)
	f.store_string(text)
	f.close()
	OS.execute("chmod", ["+x", path], true)


func _pactl_stub():
	return "\n".join([
		"#!/bin/sh",
		"D='" + test_dir + "'",
		"echo \"$@\" >> \"$D/pactl-args.log\"",
		"case \"$1\" in",
		"  info) echo \"Default Sink: alsa_output.stub\" ;;",
		"  list) echo \"49\talsa_output.stub\tdriver\tspec\"; echo \"50\totro_sink\tdriver\tspec\" ;;",
		"  get-sink-volume) if [ -f \"$D/pactl-vol\" ]; then cat \"$D/pactl-vol\"; else echo \"Volume: front-left: 41287 / 63% / -1.00 dB\"; fi ;;",
		"  get-sink-mute) echo \"Mute: no\" ;;",
		"  set-sink-volume) echo \"Volume: front-left: 0 / $3 / 0.00 dB\" > \"$D/pactl-vol\"; echo ok ;;",
		"  *) echo ok ;;",
		"esac",
	])


func _wpctl_stub():
	return "\n".join([
		"#!/bin/sh",
		"D='" + test_dir + "'",
		"echo \"$@\" >> \"$D/wpctl-args.log\"",
		"v=$(cat \"$D/wpctl-vol\" 2>/dev/null)",
		"[ -z \"$v\" ] && v=0.66",
		"case \"$1\" in",
		"  get-volume) echo \"Volume: $v\" ;;",
		"  set-volume) case \"$3\" in +5%) echo 0.71 > \"$D/wpctl-vol\" ;; -5%) echo 0.61 > \"$D/wpctl-vol\" ;; *) echo \"$v\" > \"$D/wpctl-vol\" ;; esac; echo \"Volume: $(cat \"$D/wpctl-vol\")\" ;;",
		"  set-mute) echo ok ;;",
		"  *) echo ok ;;",
		"esac",
	])


class Driver extends Node:

	var outer = null
	var link = null
	var frames = 0
	var phase_frames = 0
	var phase = "setup"
	var start_ms = 0
	var bytes_left = 0

	var peer_tcp = null
	var peer_ssl = null
	var peer_wrapped = false
	var buf = PoolByteArray()
	var out_buf = PoolByteArray()
	var lines = []          # líneas JSON leídas del peer

	func set_phase(p):
		phase = p
		phase_frames = 0

	func _ready():
		set_process(true)
		var d = outer.test_dir
		link = load("res://kdeconnect_link.gd").new()
		add_child(link)
		link.start(null, {"tcp_port": PORT, "udp_port": 0, "broadcast": false,
			"auto_pair": false, "store_dir": d + "/store"})
		link.parse_events = false
		outer.check("link: listener en un puerto válido",
			link.tcp_port >= PORT and link.tcp_port <= PORT + 2)
		outer.check("link: udp off", link.udp == null and link.udp_port == 0)
		outer.check("link: deviceId propio 32 hex", link.device_id.length() == 32)
		outer.check("link: cert TLS disponible", link.get_meta("tls_cert") != null)
		_standalone_checks()
		start_ms = OS.get_ticks_msec()
		_open_peer()
		set_phase("hs")

	# --- checks puros (sin red) de los fixes de persistencia y límites ---------

	func _standalone_checks():
		var d = outer.test_dir
		# Fix 3: persistencia en XDG_STATE_HOME, no XDG_RUNTIME_DIR.
		var probe = load("res://kdeconnect_link.gd").new()
		OS.set_environment("XDG_STATE_HOME", d + "/state")
		OS.set_environment("XDG_RUNTIME_DIR", d + "/runtime")
		probe._setup_store_path({})
		outer.check("store: usa XDG_STATE_HOME (no runtime)",
			probe._store_path.begins_with(d + "/state/gdtk/")
			and not probe._store_path.begins_with(d + "/runtime/"))
		OS.set_environment("XDG_STATE_HOME", "")
		OS.set_environment("XDG_RUNTIME_DIR", "")
		probe.free()
		# Fix 4: remember_device refresca la IP de un device conocido.
		link.remember_device(DID, "Tel", "10.0.0.1", 1716, 1000)
		link.remember_device(DID, "Tel", "10.0.0.2", 1716, 2000)
		outer.check("remember: IP actualizada al cambiar de red",
			str(link.known[DID].ip) == "10.0.0.2")
		link.known.erase(DID)
		# Fix 5: el timeout del dial cubre el caso TLS ya envuelto.
		var now = OS.get_ticks_msec()
		var dd = {"ip": "127.0.0.1", "port": 1, "tcp": StreamPeerTCP.new(),
			"at": now - 60000, "ssl": StreamPeerSSL.new(), "wrapped": true, "dial_id": "dead"}
		link.dials.append(dd)
		link.dialing["dead"] = true
		var gone = link._poll_dial(dd, now)
		outer.check("dial: timeout con TLS envuelto", gone and not link.dialing.has("dead"))

	# --- peer ------------------------------------------------------------------

	func _open_peer():
		peer_tcp = StreamPeerTCP.new()
		peer_ssl = StreamPeerSSL.new()
		peer_ssl.blocking_handshake = false
		peer_wrapped = false
		buf = PoolByteArray()
		out_buf = PoolByteArray()
		lines = []
		peer_tcp.connect_to_host("127.0.0.1", link.tcp_port)

	func _send_json(p):
		_send_bytes((JSON.print(p) + "\n").to_utf8())

	# put_partial_data + cola: put_data del fork hace busy-loop si el socket no
	# acepta todo (WANT_WRITE sent=0). Mismo cuidado que kdeconnect_link.gd.
	func _send_bytes(ba):
		if peer_ssl == null:
			return
		var ob = out_buf
		ob.append_array(ba)
		out_buf = ob
		_flush_peer()

	func _flush_peer():
		if peer_ssl == null or peer_ssl.get_status() != StreamPeerSSL.STATUS_CONNECTED:
			return
		var ob = out_buf
		while ob.size() > 0:
			var r = peer_ssl.put_partial_data(ob)
			if r[0] != OK:
				return
			var sent = int(r[1])
			if sent <= 0:
				break
			if sent >= ob.size():
				ob = PoolByteArray()
			else:
				ob = ob.subarray(sent, ob.size() - 1)
		out_buf = ob

	func _send_identity(did, name):
		_send_json({"id": 1, "type": "kdeconnect.identity", "body": {
			"deviceId": did, "deviceName": name, "deviceType": "phone",
			"protocolVersion": 8, "tcpPort": 0,
			"incomingCapabilities": ["kdeconnect.mousepad.echo", "kdeconnect.systemvolume"],
			"outgoingCapabilities": ["kdeconnect.mousepad.request", "kdeconnect.systemvolume.request"]}})

	func _read_lines():
		if peer_ssl == null or peer_ssl.get_status() != StreamPeerSSL.STATUS_CONNECTED:
			return
		var avail = peer_ssl.get_available_bytes()
		if avail <= 0:
			return
		var data = peer_ssl.get_partial_data(avail)
		if data[0] != OK:
			return
		buf.append_array(data[1])
		while true:
			var idx = -1
			for i in range(buf.size()):
				if buf[i] == 10:
					idx = i
					break
			if idx < 0:
				break
			var lb = buf.subarray(0, idx - 1)
			if idx + 1 <= buf.size() - 1:
				buf = buf.subarray(idx + 1, buf.size() - 1)
			else:
				buf = PoolByteArray()
			if lb.size() > 0:
				lines.append(lb.get_string_from_utf8())

	func take_packet_of(type):
		for i in range(lines.size()):
			var p = JSON.parse(lines[i])
			if p.error == OK and typeof(p.result) == TYPE_DICTIONARY \
					and str(p.result.get("type", "")) == type:
				lines.remove(i)
				return {"type": type, "body": p.result.get("body", {})}
		return null

	func has_packet_of(type):
		for i in range(lines.size()):
			var p = JSON.parse(lines[i])
			if p.error == OK and typeof(p.result) == TYPE_DICTIONARY \
					and str(p.result.get("type", "")) == type:
				return true
		return false

	func conn_ready(did):
		return link.conns.size() >= 1 and str(link.conns[0].device_id) == did \
			and not link.conns[0].close

	func store_has_did():
		var f = File.new()
		var s = ""
		if f.open(outer.test_dir + "/store/kdeconnect-pair.json", File.READ) == OK:
			s = f.get_as_text()
			f.close()
		var p = JSON.parse(s)
		return p.error == OK and typeof(p.result) == TYPE_DICTIONARY \
			and p.result.get("devices", {}).has(DID)

	func log_has(path, needle):
		var f = File.new()
		var s = ""
		if f.open(outer.test_dir + "/" + path, File.READ) == OK:
			s = f.get_as_text()
			f.close()
		return s.find(needle) >= 0

	func _repeat_byte(b, n):
		var ba = PoolByteArray()
		ba.resize(n)
		for i in range(n):
			ba[i] = b
		return ba

	func _process(_d):
		frames += 1
		phase_frames += 1
		if frames > 20000 or OS.get_ticks_msec() - start_ms > 40000:
			outer.check("link: e2e dentro del tiempo (fase " + phase + ")", false)
			outer.conclude("timeout phase " + phase)
			return
		if peer_wrapped:
			peer_ssl.poll()
			_read_lines()
			_flush_peer()
		match phase:
			"hs":
				var st = peer_tcp.get_status()
				if st == StreamPeerTCP.STATUS_CONNECTED:
					var err = peer_ssl.connect_to_stream(peer_tcp)
					peer_wrapped = (err == OK)
					set_phase("id_peer")
				elif st == StreamPeerTCP.STATUS_ERROR:
					outer.check("peer: TCP conectado", false)
					outer.conclude("peer TCP error")
			"id_peer":
				var idp = take_packet_of("kdeconnect.identity")
				if idp == null:
					return
				outer.check("identity: deviceId 32", str(idp.body.get("deviceId", "")).length() == 32)
				outer.check("identity: capability mousepad", Array(idp.body.get("incomingCapabilities", [])).find("kdeconnect.mousepad.request") >= 0)
				outer.check("identity: anuncia el listener", int(idp.body.get("tcpPort", 0)) == link.tcp_port)
				_send_identity(DID, "Teléfono de prueba")
				set_phase("conn1")
			"conn1":
				if not conn_ready(DID):
					return
				if phase_frames < 15:
					return
				# Conexión entrante: gdtk NO debe auto-pedir pair.
				outer.check("pair: entrante no auto-pide", link.pair_requests.size() == 0
					and not has_packet_of("kdeconnect.pair"))
				# Gate: sin parear, un mousepad se descarta.
				_send_json({"id": 3, "type": "kdeconnect.mousepad.request",
					"body": {"dx": 7.0, "dy": -2.0}})
				set_phase("gate")
			"gate":
				if phase_frames < 15:
					return
				outer.check("gate: mousepad de no pareado ignorado", link.event_queue.size() == 0)
				# Pedido entrante del teléfono (timestamp fresco) → queda PENDIENTE.
				_send_json({"id": 4, "type": "kdeconnect.pair",
					"body": {"pair": true, "timestamp": OS.get_system_time_secs()}})
				set_phase("pending")
			"pending":
				if link.pair_requests.size() == 0:
					return
				outer.check("pair: pedido entrante queda pendiente",
					link.pair_requests.size() == 1 and not link.conns[0].paired)
				var r = link.control({"op": "pair_accept", "device": DID})
				outer.check("pair_accept: ok", bool(r.ok))
				set_phase("accepted")
			"accepted":
				if phase_frames < 5:
					return
				outer.check("pair: conn pareada tras accept", link.conns.size() == 1
					and link.conns[0].paired)
				outer.check("pair: pending limpio tras accept", link.pair_requests.size() == 0)
				outer.check("pair: store JSON contiene el DID", store_has_did())
				set_phase("ack")
			"ack":
				var pp = take_packet_of("kdeconnect.pair")
				if pp == null:
					return
				outer.check("pair: ack true al aceptar", bool(pp.body.pair))
				_send_json({"id": 5, "type": "kdeconnect.mousepad.request",
					"body": {"dx": 7.0, "dy": -2.0}})
				set_phase("motion")
			"motion":
				if link.event_queue.size() == 0:
					return
				var mv = link.event_queue[0]
				outer.check("mouse: motion relativo (dx=7, dy=-2)",
					mv is InputEventMouseMotion and mv.relative == Vector2(7.0, -2.0)
					and mv.button_mask == 0)
				link.event_queue.clear()
				# specialKey 4 = Left según protocol.md v8 (índice, no Qt).
				_send_json({"id": 6, "type": "kdeconnect.mousepad.request",
					"body": {"specialKey": 4}})
				set_phase("spec")
			"spec":
				if link.event_queue.size() == 0:
					return
				outer.check("mouse: specialKey 4 = KEY_LEFT",
					link.event_queue[0] is InputEventKey
					and link.event_queue[0].scancode == KEY_LEFT)
				link.event_queue.clear()
				_send_json({"id": 7, "type": "kdeconnect.mousepad.request",
					"body": {"specialKey": 25, "ctrl": true}})
				set_phase("spec2")
			"spec2":
				if link.event_queue.size() == 0:
					return
				outer.check("mouse: specialKey 25 = F5 + ctrl",
					link.event_queue[0] is InputEventKey
					and link.event_queue[0].scancode == KEY_F5
					and link.event_queue[0].control)
				link.event_queue.clear()
				_send_json({"id": 8, "type": "kdeconnect.systemvolume.request",
					"body": {"requestSinks": true}})
				set_phase("vol_sinks")
			"vol_sinks":
				var sv = take_packet_of("kdeconnect.systemvolume")
				if sv == null or not sv.body.has("sinkList"):
					return
				var s0 = sv.body.sinkList[0]
				outer.check("volumen: sinkList del pactl stub", s0.name == "alsa_output.stub"
					and s0.enabled and not s0.muted)
				outer.check("volumen: escala PA del sinkList",
					int(s0.volume) == int(round(63.0 * 65536.0 / 100.0))
					and int(s0.maxVolume) == 65536)
				_send_json({"id": 9, "type": "kdeconnect.systemvolume.request",
					"body": {"name": "alsa_output.stub", "volume": 40}})
				set_phase("vol_set")
			"vol_set":
				var sv = take_packet_of("kdeconnect.systemvolume")
				if sv == null or not sv.body.has("name"):
					return
				outer.check("volumen: set aplicado", sv.body.name == "alsa_output.stub"
					and int(sv.body.volume) == 40 and not sv.body.muted)
				outer.check("volumen: pactl registró el set", log_has("pactl-args.log",
					"set-sink-volume alsa_output.stub 40%"))
				link.control({"op": "unpair", "device": DID})
				set_phase("unpaired")
			"unpaired":
				if phase_frames < 5:
					return
				outer.check("unpair: store vacío", link.store.devices.size() == 0)
				set_phase("wait_close1")
			"wait_close1":
				if link.conns.size() > 0:
					return
				_open_peer()
				set_phase("hs2")
			"hs2":
				var st = peer_tcp.get_status()
				if st == StreamPeerTCP.STATUS_CONNECTED:
					var err = peer_ssl.connect_to_stream(peer_tcp)
					peer_wrapped = (err == OK)
					set_phase("id_peer2")
				elif st == StreamPeerTCP.STATUS_ERROR:
					outer.check("peer2: TCP conectado", false)
					outer.conclude("peer2 TCP error")
			"id_peer2":
				var idp = take_packet_of("kdeconnect.identity")
				if idp == null:
					return
				_send_identity(DID, "Teléfono de prueba")
				set_phase("conn2")
			"conn2":
				if not conn_ready(DID):
					return
				if phase_frames < 15:
					return
				outer.check("pair: sin pedido entrante no hay pending",
					link.pair_requests.size() == 0 and not link.conns[0].paired)
				# Pedido SALIENTE explícito (equivalente al dial por descubrimiento).
				var r = link.control({"op": "pair_request", "device": DID})
				outer.check("pair_request: ok", bool(r.ok))
				set_phase("req")
			"req":
				var pp = take_packet_of("kdeconnect.pair")
				if pp == null:
					return
				outer.check("pair_request: salió pair:true", bool(pp.body.pair))
				# El teléfono ACEPTA nuestro pedido saliente.
				_send_json({"id": 10, "type": "kdeconnect.pair",
					"body": {"pair": true, "timestamp": OS.get_system_time_secs()}})
				set_phase("completed")
			"completed":
				if link.conns.size() == 0 or not link.conns[0].paired:
					return
				# Fix 2: la respuesta positiva COMPLETA el pareo, no deja otro pending.
				outer.check("pair: respuesta positiva completa (sin pending)",
					link.conns[0].paired and link.pair_requests.size() == 0)
				outer.check("pair: store tras completar saliente", store_has_did())
				bytes_left = 600000   # > MAX_PACKET_BYTES (512 KiB)
				set_phase("buf")
			"buf":
				var chunk = min(32768, bytes_left)
				_send_bytes(_repeat_byte(97, chunk))
				bytes_left -= chunk
				if bytes_left <= 0:
					set_phase("buf_wait")
			"buf_wait":
				if link.conns.size() > 0:
					return
				# Fix 5: buffer sin newline que supera MAX_PACKET_BYTES cierra el link.
				outer.check("framing: buffer sin newline > MAX cierra la conexión",
					link.conns.size() == 0)
				outer.conclude("e2e completo")
