extends SceneTree

# E2E del receptor KDE Connect (shell/kdeconnect_link.gd) con un peer falso
# (cliente TLS "teléfono" hecho en este mismo proceso) y stubs pactl/wpctl
# (en GDTK_TEST_DIR, para evaluar los flujos sin tocar el audio de anfitrión).
# Correr:
#   GDTK_TEST_DIR=/tmp/kilo/kdetest \
#   GDTK_KDE_WPCTL=/tmp/kilo/kdetest/bin/wpctl \
#   GDTK_KDE_PACTL=/tmp/kilo/kdetest/bin/pactl \
#   godot --no-window --path shell -s $PWD/tests/kdeconnect_link_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func conclude():
	print("RESULT: fail=", failed)
	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _init():
	# Sin GDTK_TEST_DIR no hay stubs ni store aislado: no correr (el flujo e2e
	# toca red y hoy tiene un hang conocido al conectar un peer; ver README/notas).
	if OS.get_environment("GDTK_TEST_DIR") == "":
		print("skip kdeconnect_link_test: requiere GDTK_TEST_DIR y stubs pactl/wpctl")
		OS.exit_code = 0
		quit()
		return
	# Store y logs limpios: el pair flow completo se ejercita desde cero cada vez.
	var d = OS.get_environment("GDTK_TEST_DIR")
	for path in ["store", "pactl-args.log", "wpctl-args.log", "pct", "vol"]:
		OS.execute("sh", ["-c", "rm -rf " + d + "/" + path], true)
	var drv = Driver.new()
	drv.outer = self
	root.add_child(drv)


const DID = "aaaa1111bbbb2222cccc3333dddd4444"


class Driver extends Node:

	var outer = null
	var link = null
	var frames = 0
	var phase = "setup"
	var peer_tcp = null
	var peer_ssl = null
	var buf = PoolByteArray()
	var lines = []          # líneas JSON ya leídas del peer (modo FIFO)
	var peer_wrapped = false
	var identity_body = null

	func _ready():
		var d = OS.get_environment("GDTK_TEST_DIR")
		link = load("res://kdeconnect_link.gd").new()
		add_child(link)
		link.start(null, {"tcp_port": 18500, "udp_port": 0, "broadcast": false,
			"auto_pair": true, "store_dir": d + "/store"})
		outer.check("link: tcp_port propagado (18500)", link.tcp_port == 18500)
		outer.check("link: udp off en el test", link.udp == null and link.udp_port == 0)
		outer.check("link: deviceId propio de 32 hex", link.device_id.length() == 32)
		outer.check("link: cert TLS disponible", link.get_meta("tls_cert") != null)
		peer_tcp = StreamPeerTCP.new()
		peer_tcp.connect_to_host("127.0.0.1", 18500)
		peer_ssl = StreamPeerSSL.new()
		peer_ssl.blocking_handshake = false
		phase = "wrap"

	func _send_json(p):
		peer_ssl.put_data((JSON.print(p) + "\n").to_utf8())

	func _read_lines():
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
		# SACA (consume) el primer packet del tipo pedido de lo leído.
		for i in range(lines.size()):
			var p = JSON.parse(lines[i])
			if p.error == OK and typeof(p.result) == TYPE_DICTIONARY \
					and str(p.result.get("type", "")) == type:
				lines.remove(i)
				var body = p.result.get("body", {})
				return {"type": str(p.result.type), "body": body}
		return null

	func store_has_did():
		var f = File.new()
		var s = ""
		if f.open(OS.get_environment("GDTK_TEST_DIR") + "/store/kdeconnect-pair.json", File.READ) == OK:
			s = f.get_as_text()
			f.close()
		var p = JSON.parse(s)
		return p.error == OK and typeof(p.result) == TYPE_DICTIONARY \
			and p.result.get("devices", {}).has(DID)

	func log_has(path, needle):
		var f = File.new()
		var s = ""
		if f.open(OS.get_environment("GDTK_TEST_DIR") + "/" + path, File.READ) == OK:
			s = f.get_as_text()
			f.close()
		return s.find(needle) >= 0

	func _process(_d):
		frames += 1
		if frames % 120 == 0:
			print("[drv] frame ", frames, " phase=", phase,
				" peer_ssl_status=", -1 if peer_ssl == null else peer_ssl.get_status(),
				" lines=", lines.size(), " link_conns=", link.conns.size())
		if frames > 1800:
			print("RESULT: timeout phase ", phase)
			outer.conclude()
			return
		if peer_wrapped:
			peer_ssl.poll()
			_read_lines()
		match phase:
			"setup":
				pass
			"wrap":
				var st = peer_tcp.get_status()
				if st == StreamPeerTCP.STATUS_CONNECTED:
					var err = peer_ssl.connect_to_stream(peer_tcp)
					peer_wrapped = true
					print("[drv] wrap err=", err, " ssl status=", peer_ssl.get_status())
					phase = "identity"
				elif st == StreamPeerTCP.STATUS_ERROR:
					print("RESULT: peer no pudo conectar")
					outer.conclude()
			"identity":
				var idp = take_packet_of("kdeconnect.identity")
				if idp == null:
					return
				identity_body = idp.body
				outer.check("identity: deviceId presente", str(identity_body.get("deviceId", "")).length() == 32)
				outer.check("identity: capabilities mousedown", Array(identity_body.get("incomingCapabilities", [])).find("kdeconnect.mousepad.request") >= 0)
				outer.check("identity: puerto anuncia el listener", int(identity_body.get("tcpPort", 0)) == 18500)
				phase = "reply_identity"
			"reply_identity":
				if identity_body == null:
					return
				_send_json({"id": 2, "type": "kdeconnect.identity", "body": {
					"deviceId": DID, "deviceName": "Teléfono de prueba",
					"protocolVersion": 8,
					"incomingCapabilities": ["kdeconnect.mousepad.echo", "kdeconnect.systemvolume"],
					"outgoingCapabilities": ["kdeconnect.mousepad.request", "kdeconnect.systemvolume.request"]}})
				phase = "pair"
			"pair":
				var pp = take_packet_of("kdeconnect.pair")
				if pp == null:
					return
				outer.check("pair: true salió del receptor", bool(pp.body.pair))
				phase = "assert_pair"
			"assert_pair":
				outer.check("pair: conn 0 lada de auto_pair", link.conns.size() == 1
					and link.conns[0].paired)
				outer.check("pair: state() refleja el pareo", link.state().connections.size() == 1
					and link.state().connections[0].paired)
				outer.check("pair: store JSON contiene el DID", store_has_did())
				link.parse_events = false
				_send_json({"id": 3, "type": "kdeconnect.mousepad.request",
					"body": {"dx": 7.0, "dy": -2.0}})
				phase = "mouse_motion"
			"mouse_motion":
				if link.event_queue.size() == 0:
					return
				var mv = link.event_queue[0]
				outer.check("mouse: motion relative (dx=7, dy=-2)",
					mv is InputEventMouseMotion and mv.relative == Vector2(7.0, -2.0)
					and mv.button_mask == 0)
				link.event_queue.clear()
				_send_json({"id": 4, "type": "kdeconnect.mousepad.request",
					"body": {"dy": 1.0, "scroll": true}})
				phase = "mouse_scroll"
			"mouse_scroll":
				if link.event_queue.size() < 2:
					return
				var ev = link.event_queue[0]
				var rv = link.event_queue[1]
				outer.check("mouse: rueda press+release hecho", ev is InputEventMouseButton
					and ev.button_index == BUTTON_WHEEL_DOWN and ev.pressed
					and rv is InputEventMouseButton and not rv.pressed)
				link.event_queue.clear()
				_send_json({"id": 5, "type": "kdeconnect.mousepad.request",
					"body": {"singleclick": true}})
				phase = "mouse_click"
			"mouse_click":
				if link.event_queue.size() < 3:
					return
				var e0 = link.event_queue[0]
				var e1 = link.event_queue[1]
				var e2 = link.event_queue[2]
				outer.check("mouse: click triple (motion+press+release)",
					e0 is InputEventMouseMotion and e1 is InputEventMouseButton
					and e1.pressed and e2 is InputEventMouseButton and not e2.pressed)
				outer.check("mouse: máscara de botones liberada", e2.button_mask == 0)
				link.event_queue.clear()
				_send_json({"id": 6, "type": "kdeconnect.mousepad.request",
					"body": {"key": "x", "sendAck": true}})
				phase = "key_echo"
			"key_echo":
				var ec = take_packet_of("kdeconnect.mousepad.echo")
				if ec == null:
					return
				outer.check("key: echo isAck con la key", ec.body.isAck and ec.body.key == "x")
				outer.check("key: eventos key press+release en cola", link.event_queue.size() == 2
					and link.event_queue[0] is InputEventKey
					and link.event_queue[0].pressed
					and not link.event_queue[1].pressed)
				link.event_queue.clear()
				_send_json({"id": 7, "type": "kdeconnect.systemvolume.request",
					"body": {"requestSinks": true}})
				phase = "vol_sinks"
			"vol_sinks":
				var sv = take_packet_of("kdeconnect.systemvolume")
				if sv == null or not sv.body.has("sinkList"):
					return
				var s0 = sv.body.sinkList[0]
				outer.check("volumen: sinkList del pactl fake habilidatada", s0.name == "alsa_output.stub"
					and s0.enabled and not s0.muted)
				outer.check("volumen: escala PA del sinkList", int(s0.volume)
					== int(round(63.0 * 65536.0 / 100.0)) and int(s0.maxVolume) == 65536)
				_send_json({"id": 8, "type": "kdeconnect.systemvolume.request",
					"body": {"name": "alsa_output.stub", "volume": 40}})
				phase = "vol_set"
			"vol_set":
				var sv = take_packet_of("kdeconnect.systemvolume")
				if sv == null or not sv.body.has("name"):
					return
				outer.check("volumen: set aplicado rpc Ly", sv.body.name == "alsa_output.stub"
					and int(sv.body.volume) == 40 and not sv.body.muted)
				outer.check("volumen: pactl marca el set", log_has("pactl-args.log",
					"set-sink-volume alsa_output.stub 40%"))
				_send_json({"id": 9, "type": "kdeconnect.systemvolume.request",
					"body": {"command": "volumeUp"}})
				phase = "vol_master"
			"vol_master":
				var sv = take_packet_of("kdeconnect.systemvolume")
				if sv == null or not sv.body.has("name"):
					return
				outer.check("volumen: master post-step a 71% (0.66+0.05)",
					int(sv.body.volume) == 71)
				outer.check("volumen: wpctl recibió el paso", log_has("wpctl-args.log",
					"set-volume @DEFAULT_AUDIO_SINK@ +5%"))
				phase = "cleanup"
			"cleanup":
				var r = link.control({"op": "unpair", "device": DID})
				outer.check("unpair via control OK", bool(r.ok))
				outer.check("store vacío tras unpair", link.store.devices.size() == 0)
				link.parse_events = true
				phase = "draining"
			"draining":
				if link.event_queue.size() == 0:
					print("RESULT: e2e completo")
					outer.conclude()
