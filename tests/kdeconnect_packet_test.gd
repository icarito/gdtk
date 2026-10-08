extends SceneTree

# Autoprueba del codec KDE Connect (shell/kdeconnect_packet.gd). Correr:
#   godot --no-window --path shell -s $PWD/tests/kdeconnect_packet_test.gd

const PK = preload("res://kdeconnect_packet.gd")

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	check("identity: estructura", PK.packet_type(PK.identity_packet(
		"740bd4b9b4184ee497d6caf1da8151be", "gdtk", 1716)) == PK.IDENTITY)
	var idpk = PK.identity_packet("740bd4b9b4184ee497d6caf1da8151be", "gdtk", 1717)
	var ib = PK.body_of(idpk)
	check("identity: deviceId/name/type/puerto", ib.deviceId == "740bd4b9b4184ee497d6caf1da8151be"
		and ib.deviceName == "gdtk" and ib.deviceType == "desktop" and ib.tcpPort == 1717)
	check("identity: version v8", ib.protocolVersion == 8)
	check("identity: capabilities incluidas", PK.INCOMING_CAPS.find(PK.MOUSEPAD_REQUEST) >= 0
		and PK.OUTGOING_CAPS.find(PK.SYSTEMVOLUME) >= 0
		and PK.INCOMING_CAPS.find("kdeconnect.battery") < 0)

	check("pair true con timestamp", int(PK.body_of(PK.pair_packet(true)).timestamp) > 0)
	check("pair false sin timestamp", not PK.body_of(PK.pair_packet(false)).has("timestamp"))

	check("deviceId válido (32-38 hex)", PK.valid_device_id("740bd4b9b4184ee497d6caf1da8151be")
		and PK.valid_device_id("0123456789abcdef0123456789abcdef-"))
	check("deviceId inválido", not PK.valid_device_id("corto")
		and not PK.valid_device_id("u".repeat(39))
		and not PK.valid_device_id("mal id con espacios-abc-def-hij"))

	check("sanitize limpia puntuación", PK.sanitize_device_name('Te(1)"!?;:') == "Te1"
		and PK.sanitize_device_name("") == "gdtk")
	check("sanitize al 32 chars", PK.sanitize_device_name("x".repeat(40)) == "x".repeat(32))

	var parsed_rt = PK.parse(PK.encode(idpk))
	check("encode/parse roundtrip", parsed_rt != null and PK.packet_type(parsed_rt) == PK.IDENTITY
		and PK.body_of(parsed_rt).deviceId == ib.deviceId)
	check("parse: basura → null", PK.parse("no json{") == null
		and PK.parse("[1,2,3,4,5,6,7,8]") == null)

	# mousepad: movimiento relativo puro.
	var mv = PK.mousepad_events({"dx": 3.0, "dy": -2.0})
	check("mousepad: motion", mv.size() == 1 and mv[0].k == "motion" and mv[0].dx == 3
		and mv[0].dy == -2)
	check("mousepad: ceros sin eventos", PK.mousepad_events({"dx": 0.0, "dy": 0.0}).size() == 0)
	var sc = PK.mousepad_events({"dx": 0.0, "dy": 3.0, "scroll": true})
	check("mousepad: scroll dx/dy", sc.size() == 1 and sc[0].k == "scroll" and sc[0].dy == 3)
	var scl = PK.mousepad_events({"dx": 4.0, "dy": 0.0, "scroll": true})
	check("mousepad: scroll horizontal", scl.size() == 1 and scl[0].k == "scroll"
		and scl[0].dx == 4)

	var cl = PK.mousepad_events({"singleclick": true})
	check("mousepad: singleclick press+release", cl.size() == 2
		and cl[0].k == "button" and cl[0].code == BUTTON_LEFT and cl[0].pressed
		and cl[1].k == "button" and not cl[1].pressed and cl[1].clicks == 1)
	var db = PK.mousepad_events({"doubleclick": true})
	check("mousepad: doubleclick clicks=2", db.size() == 2 and db[0].clicks == 2
		and db[0].code == BUTTON_LEFT)
	check("mousepad: rightclick", PK.mousepad_events({"rightclick": true})[0].code == BUTTON_RIGHT)
	check("mousepad: middleclick", PK.mousepad_events({"middleclick": true})[0].code == BUTTON_MIDDLE)
	var hold = PK.mousepad_events({"singlehold": true})
	var rele = PK.mousepad_events({"singlerelease": true})
	check("mousepad: hold/release", hold.size() == 1 and hold[0].pressed
		and rele.size() == 1 and not rele[0].pressed)

	var key = PK.mousepad_events({"key": "a", "sendAck": true})
	check("mousepad: key a", key.size() == 1 and key[0].k == "key"
		and key[0].code == OS.find_scancode_from_string("a") and key[0].unicode == 97)
	var cap = PK.mousepad_events({"key": "A"})
	check("mousepad: key A con shift", cap.size() == 1 and cap[0].shift)
	var nl = PK.mousepad_events({"key": "\n"})
	check("mousepad: key enter", nl.size() == 1 and nl[0].code == KEY_ENTER
		and nl[0].unicode == 10)
	var bad = PK.mousepad_events({"key": "¡"})
	check("mousepad: tecla sin scancode ignorada", bad.size() == 0)

	var spec = PK.mousepad_events({"specialKey": 0x01000012})  # Qt Key_Left
	check("mousepad: specialKey Left", spec.size() == 1 and spec[0].code == KEY_LEFT)
	var f5 = PK.mousepad_events({"specialKey": 0x01000034 + 0, "ctrl": true})  # Qt F5
	check("mousepad: specialKey F5+ctrl", f5.size() == 1 and f5[0].code == KEY_F5
		and f5[0].ctrl)
	check("mousepad: specialKey raro ignorado", PK.mousepad_events({"specialKey": 7}).size() == 0)

	# echo: sólo con sendAck.
	check("echo: sin sendAck null", PK.mousepad_echo({"key": "a"}) == null)
	var ec = PK.mousepad_echo({"key": "a", "sendAck": true, "ctrl": false})
	check("echo: con sendAck key+isAck", ec != null and PK.packet_type(ec) == PK.MOUSEPAD_ECHO
		and PK.body_of(ec).isAck and PK.body_of(ec).key == "a")
	var ecs = PK.mousepad_echo({"specialKey": 0x01000012, "sendAck": true})
	check("echo: specialKey echo", PK.body_of(ecs).specialKey == 0x01000012)

	# presenter: motion relativo; stop no genera nada.
	var pr = PK.presenter_events({"dx": 2.0, "dy": 5.0})
	check("presenter: motion", pr.size() == 1 and pr[0].k == "motion" and pr[0].dx == 2)
	check("presenter: stop sin eventos", PK.presenter_events({"stop": true}).size() == 0)

	# systemvolume: request → tipo.
	check("sysvol: requestSinks", PK.volume_request({"requestSinks": true}).k == "sinks")
	check("sysvol: legacy volumeup", PK.volume_request({"command": "volumeUp"}).k == "master"
		and PK.volume_request({"command": "volumeUp"}).command == "volumeup")
	check("sysvol: legacy mute", PK.volume_request({"command": "mute"}).command == "mute")
	check("sysvol: comando raro null", PK.volume_request({"command": "bailar"}) == null)
	var st = PK.volume_request({"name": "alsa_out", "volume": 49})
	check("sysvol: set porcentaje", st.k == "set" and st.volume_pct == 49.0
		and st.name == "alsa_out")
	var rawv = PK.volume_request({"name": "alsa_out", "volume": 65536})
	check("sysvol: set raw PA → pct", rawv.volume_pct >= 99.9 and rawv.volume_pct <= 100.1
		and rawv.volume_pct == 100.0)
	var def = PK.volume_request({"name": "alsa_out", "enabled": true})
	check("sysvol: enabled → set_default", def.set_default)
	var mut = PK.volume_request({"name": "alsa_out", "muted": true})
	check("sysvol: muted", mut.muted)

	# sinkList en unidades raw del protocolo.
	var sl = PK.body_of(PK.build_sink_list([
		{"name": "out1", "pct": 50.0, "muted": true, "default": true}]))
	check("sinkList: 1 stream", sl.sinkList.size() == 1)
	var s0 = sl.sinkList[0]
	check("sinkList: volume raw + muted + enabled", s0.volume == 32768
		and s0.maxVolume == 65536 and s0.muted and s0.enabled and s0.name == "out1")
	check("streamState: pct directo", PK.body_of(PK.build_stream_state("out1", 49.0, true, false)).volume == 49
		and PK.body_of(PK.build_stream_state("out1", 49.0, true, false)).muted)

	# parsers pactl/wpctl (formatos reales).
	var sinks_line = "49\talsa_output.pci.stub\tdriver\tspec\ndemasiada-basura\t\t\t\n0\totro_sink_name"
	var ss = PK.parse_pactl_sinks(sinks_line)
	check("parse_sinks: 2 y por TAB", ss.size() == 2 and ss[0].index == "49"
		and ss[0].name == "alsa_output.pci.stub" and ss[1].name == "otro_sink_name")
	check("parse_sinks: basura fuera", PK.parse_pactl_sinks("# comment\n\n\n").size() == 0)
	check("default_sink: texto real", PK.parse_pactl_default_sink(
		"Variable: X\nDefault Sink: alsa_output.pci.stub\n") == "alsa_output.pci.stub")
	check("default_sink: ausente ''", PK.parse_pactl_default_sink("Ün solo .\n") == "")
	var pv = PK.parse_pactl_volume("Sink Input #12\n\tVolume: front-left: 65536 / 100% / 0.00 dB,  front-right: 65536 / 100% / 0.00 dB\n\t100% 1.00")
	check("pactl volume: 100%", pv.pct == 100.0)
	check("pactl volume: basura -1", PK.parse_pactl_volume("no hay volumen aquí").pct == -1.0)
	check("pactl mute: yes/no", PK.parse_pactl_mute("Mute: yes").muted
		and not PK.parse_pactl_mute("Mute: no").muted)
	var wz = PK.parse_wpctl_volume("Volume: 0.98\n")
	check("wpctl: 98% sin mute", wz.pct == 98.0 and not wz.muted)
	var wz2 = PK.parse_wpctl_volume("Volume: 1.50 [MUTED]\n")
	check("wpctl: 150% con mute", wz2.pct == 150.0 and wz2.muted)
	check("wpctl: basura -1", PK.parse_wpctl_volume(" nada]").pct == -1.0)

	check("packet: body por defecto {} y shape", typeof(PK.body_of(PK.packet(PK.PING, null))) == TYPE_DICTIONARY)
	check("packet_type: no-dict", PK.packet_type(null) == "" and PK.packet_type([1,2]) == "")
	check("body_of: no-dict body → {}", PK.body_of({"type": "x", "body": "no"}).size() == 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
