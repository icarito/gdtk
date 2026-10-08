extends Reference

# Código puro del receptor KDE Connect: codec de packets JSON, identity, pair,
# mapeo mousepad/presenter a descriptores de eventos y parsers de volumen
# (wpctl/pactl). Sin I/O ni nodos (contrato §3 de SPEC-architecture); el servicio
# con sockets vive en kdeconnect_link.gd y los tests en tests/kdeconnect_*_test.gd.
#
# Protocolo (kdeconnect-meta / protocol.md, v8): packets JSON "id"/"type"/"body"
# con framing "\n" sobre TCP+TLS; identity se intercambia por TLS con
# capabilities; pairing por paquetes kdeconnect.pair (timeout 30s, timestamp).
# deviceId: 32-38 alfanum (- _ ok) y Common Name del cert TLS propio;
# deviceName sin "',;:.!?()[]<> y máx 32.

const PROTOCOL_VERSION = 8
const IDENTITY = "kdeconnect.identity"
const PAIR = "kdeconnect.pair"
const MOUSEPAD_REQUEST = "kdeconnect.mousepad.request"
const MOUSEPAD_ECHO = "kdeconnect.mousepad.echo"
const PRESENTER = "kdeconnect.presenter"
const PING = "kdeconnect.ping"
const SYSTEMVOLUME = "kdeconnect.systemvolume"
const SYSTEMVOLUME_REQ = "kdeconnect.systemvolume.request"

# incomingCapabilities: packets que gdtk consume; outgoingCapabilities: los que
# emite. Declarar battery/clipboard como incoming sólo cuando se implementen:
# el app Android habilita sus plugins según estas listas.
const INCOMING_CAPS = [IDENTITY, PAIR, MOUSEPAD_REQUEST, PRESENTER, SYSTEMVOLUME_REQ, PING]
const OUTGOING_CAPS = [IDENTITY, PAIR, MOUSEPAD_ECHO, SYSTEMVOLUME, PING]

# Caracteres que el spec prohíbe en deviceName (se sanea quitando).
const INVALID_NAME_CHARS = ['"', "'", ",", ";", ":", ".", "!", "?", "(", ")", "[", "]", "<", ">"]

const PA_MAX_VOLUME = 65536  # escala raw de PulseAudio (coherente con la doc)


static func _now_ms():
	return int(OS.get_system_time_msecs())


# --- packets ---------------------------------------------------------------

static func packet(type, body):
	return {"id": _now_ms(), "type": str(type), "body": body if body != null else {}}


static func encode(p):
	return JSON.print(p)


static func parse(text):
	var parsed = JSON.parse(str(text))
	if parsed.error != OK or typeof(parsed.result) != TYPE_DICTIONARY:
		return null
	return parsed.result


static func packet_type(p):
	if typeof(p) != TYPE_DICTIONARY:
		return ""
	return str(p.get("type", ""))


static func body_of(p):
	var b = p.get("body", {})
	if typeof(b) != TYPE_DICTIONARY:
		return {}
	return b


# --- identity / pairing ----------------------------------------------------

static func identity_packet(device_id, device_name, tcp_port):
	return packet(IDENTITY, {
		"deviceId": device_id,
		"deviceName": sanitize_device_name(device_name),
		"deviceType": "desktop",
		"protocolVersion": PROTOCOL_VERSION,
		"tcpPort": int(tcp_port),
		"incomingCapabilities": INCOMING_CAPS,
		"outgoingCapabilities": OUTGOING_CAPS,
	})


static func pair_packet(accept):
	# pair:false sirve tanto para rechazar un pedido entrante como para desparear.
	var body = {"pair": bool(accept)}
	if accept:
		body["timestamp"] = int(_now_ms() / 1000.0)
	return packet(PAIR, body)


# deviceId = 32-38 chars de [A-z0-9_-] (doc: típicamente UUIDv4 sin guiones).
static func valid_device_id(id):
	var s = str(id)
	if s.length() < 32 or s.length() > 38:
		return false
	for i in range(s.length()):
		var ch = s[i]
		var ok = (ch >= "0" and ch <= "9") or (ch >= "a" and ch <= "z") \
			or (ch >= "A" and ch <= "Z") or ch == "-" or ch == "_"
		if not ok:
			return false
	return true


static func sanitize_device_name(name):
	var out = ""
	var src = str(name)
	for i in range(src.length()):
		var ch = src[i]
		if INVALID_NAME_CHARS.find(ch) < 0:
			out += ch
	if out.length() > 32:
		out = out.substr(0, 32)
	if out == "":
		out = "gdtk"
	return out


# --- mousepad / presenter → descriptores de eventos -------------------------
# Descriptores puros (InputEvents los construye kdeconnect_link.gd con el
# punto del viewport del momento):; descriptor semantics:
#   {"k":"motion","dx":..,"dy":..}          movimiento relativo
#   {"k":"scroll","dx":..,"dy":..}          rueda (ejes dx/dy)
#   {"k":"button","code":BUTTON_*,"pressed":bool,"clicks":1|2}
#   {"k":"key","code":scancode,"unicode":int,"shift/ctrl/alt/meta":bool}
# Un click del protocolo viene como par press+release, y un key también.

static func mousepad_events(body):
	var out = []
	if typeof(body) != TYPE_DICTIONARY:
		return out
	var dx = float(body.get("dx", 0.0))
	var dy = float(body.get("dy", 0.0))
	if dx != 0.0 or dy != 0.0:
		var kind = "scroll" if bool(body.get("scroll", false)) else "motion"
		out.append({"k": kind, "dx": int(dx), "dy": int(dy)})
	if bool(body.get("singleclick", false)):
		out += _click(BUTTON_LEFT, 1)
	if bool(body.get("doubleclick", false)):
		out += _click(BUTTON_LEFT, 2)
	if bool(body.get("middleclick", false)):
		out += _click(BUTTON_MIDDLE, 1)
	if bool(body.get("rightclick", false)):
		out += _click(BUTTON_RIGHT, 1)
	if bool(body.get("singlehold", false)):
		out.append({"k": "button", "code": BUTTON_LEFT, "pressed": true, "clicks": 1})
	if bool(body.get("singlerelease", false)):
		out.append({"k": "button", "code": BUTTON_LEFT, "pressed": false, "clicks": 1})
	var mods = {"shift": bool(body.get("shift", false)), "ctrl": bool(body.get("ctrl", false)),
		"alt": bool(body.get("alt", false)), "meta": bool(body.get("super", false))}
	if body.has("key") or body.has("specialKey"):
		for ev in char_key_events(str(body.get("key", "")), mods):
			out.append(ev)
		if body.has("specialKey"):
			var code = special_key_code(int(body.specialKey))
			if code != 0:
				out.append({"k": "key", "code": code, "unicode": 0, "shift": mods.shift,
					"ctrl": mods.ctrl, "alt": mods.alt, "meta": mods.meta})
	return out


static func presenter_events(body):
	var out = []
	if typeof(body) != TYPE_DICTIONARY:
		return out
	if body.has("dx") or body.has("dy"):
		var dx = int(round(float(body.get("dx", 0.0))))
		var dy = int(round(float(body.get("dy", 0.0))))
		if dx != 0 or dy != 0:
			out.append({"k": "motion", "dx": dx, "dy": dy})
	return out


static func mousepad_echo(body):
	# Echo con isAck:true si el remitente lo pidió (sendAck) para key/specialKey.
	if typeof(body) != TYPE_DICTIONARY:
		return null
	if not bool(body.get("sendAck", false)):
		return null
	var echo = {"isAck": true}
	if body.has("key"):
		echo["key"] = str(body.key)
	if body.has("specialKey"):
		echo["specialKey"] = int(body.specialKey)
	for m in ["alt", "ctrl", "shift", "super"]:
		if body.has(m):
			echo[m] = bool(body[m])
	return packet(MOUSEPAD_ECHO, echo)


static func _click(button, clicks):
	return [{"k": "button", "code": button, "pressed": true, "clicks": clicks},
		{"k": "button", "code": button, "pressed": false, "clicks": clicks}]


static func char_key_events(text, mods):
	# Un char (posiblemente multi-byte unicode) por request; igual que remote.gd
	# `_key_event_for_char` pero en descriptores.
	var out = []
	if str(text) == "":
		return out
	var ch = str(text).substr(0, 1)
	var code = 0
	var uni = 0
	var shift = bool(mods.get("shift", false))
	if ch == "\n":
		code = KEY_ENTER
		uni = 10
	elif ch == "\t":
		code = KEY_TAB
		uni = 9
	elif ch == " ":
		code = KEY_SPACE
		uni = 32
	else:
		var lower = ch.to_lower()
		code = OS.find_scancode_from_string(lower)
		if code == 0:
			return out
		if ch != lower:
			shift = true
		uni = ord(ch)
	out.append({"k": "key", "code": code, "unicode": uni, "shift": shift,
		"ctrl": bool(mods.get("ctrl", false)), "alt": bool(mods.get("alt", false)),
		"meta": bool(mods.get("meta", false))})
	return out


static func special_key_code(qt_value):
	# specialKey viaja como valor de Qt::Key (0x01000000+). Mapeo lo que el
	# shell admite; fuera de tablas → 0 (ignorado).
	var map = {
		0x01000000: KEY_ESCAPE, 0x01000001: KEY_TAB, 0x01000002: KEY_BACKTAB,
		0x01000003: KEY_BACKSPACE, 0x01000004: KEY_ENTER, 0x01000005: KEY_KP_ENTER,
		0x01000006: KEY_INSERT, 0x01000007: KEY_DELETE, 0x01000008: KEY_PAUSE,
		0x01000009: KEY_PRINT, 0x0100000a: KEY_SYSREQ, 0x0100000b: KEY_CLEAR,
		0x01000010: KEY_HOME, 0x01000011: KEY_END, 0x01000012: KEY_LEFT,
		0x01000013: KEY_UP, 0x01000014: KEY_RIGHT, 0x01000015: KEY_DOWN,
		0x01000016: KEY_PAGEUP, 0x01000017: KEY_PAGEDOWN,
		0x01000020: KEY_SHIFT, 0x01000021: KEY_CONTROL, 0x01000022: KEY_META,
		0x01000023: KEY_ALT, 0x01000024: KEY_CAPSLOCK, 0x01000025: KEY_NUMLOCK,
		0x01000026: KEY_SCROLLLOCK,
	}
	if map.has(qt_value):
		return map[qt_value]
	if qt_value >= 0x01000030 and qt_value <= 0x0100003b:
		return KEY_F1 + (qt_value - 0x01000030)  # KEY_F1..KEY_F12 consecutivos
	return 0


# --- systemvolume -----------------------------------------------------------
# El app Android (SystemVolumePlugin) manda kdeconnect.systemvolume.request:
# {requestSinks:true} para la lista de streams, o {name,volume,muted,enabled}
# para ajustar uno; también admitimos el legado {command:"volumeUp"|...}.

static func volume_request(body):
	if typeof(body) != TYPE_DICTIONARY:
		return null
	if bool(body.get("requestSinks", false)):
		return {"k": "sinks"}
	if body.has("command"):
		var cmd = str(body.command).to_lower()
		if cmd == "volumeup" or cmd == "volumedown" or cmd == "mute" or cmd == "unmute":
			return {"k": "master", "command": cmd}
		return null
	if body.has("name"):
		var req = {"k": "set", "name": str(body["name"])}
		if body.has("volume"):
			# El volumen request <=100 es porcentaje; mayor viene en raw de PA.
			var v = float(body.volume)
			req["volume_pct"] = v if v <= 100.0 else (v * 100.0 / float(PA_MAX_VOLUME))
		if body.has("muted"):
			req["muted"] = bool(body.muted)
		if bool(body.get("enabled", false)):
			req["set_default"] = true
		return req
	return null


static func build_sink_list(sinks):
	# sinks: [{name, pct, muted, default, description?}] del worker → sinkList
	# del protocolo (volume en unidades raw, maxVolume en la escala PA).
	var out = []
	for s in sinks:
		out.append({
			"name": str(s.name),
			"description": str(s.get("description", s.name)),
			"muted": bool(s.get("muted", false)),
			"volume": int(round(float(s.get("pct", 0.0)) * float(PA_MAX_VOLUME) / 100.0)),
			"maxVolume": PA_MAX_VOLUME,
			"enabled": bool(s.get("default", false)),
		})
	return packet(SYSTEMVOLUME, {"sinkList": out})


static func build_stream_state(name, pct, muted, is_default):
	return packet(SYSTEMVOLUME, {
		"name": str(name), "volume": int(round(float(pct))), "muted": bool(muted),
		"enabled": bool(is_default),
	})


# --- parsers de wpctl/pactl (self-contained; mismos formatos que system_osd) --

# `pactl list short sinks`: columnas por TAB: id, name, driver, spec, props...
static func parse_pactl_sinks(text):
	var out = []
	for line in str(text).split("\n"):
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts = line.split("\t")
		if parts.size() < 2:
			continue
		out.append({"index": parts[0], "name": parts[1]})
	return out


# `pactl info` → "Default Sink: alsa_output.pci-0000_00_1b.0.analog-stereo"
static func parse_pactl_default_sink(text):
	for line in str(text).split("\n"):
		line = line.strip_edges()
		if line.begins_with("Default Sink:"):
			return line.substr("Default Sink:".length()).strip_edges()
	return ""


# `pactl get-sink-volume X` → "front-left: 65536 / 100% / 0.00 dB, ...":
# primer porcentaje entre "/ NN% /".
static func parse_pactl_volume(text):
	for line in str(text).split("\n"):
		var parts = line.split("%")
		if parts.size() < 2:
			continue
		var left = parts[0]
		var idx = left.rfind("/")
		if idx < 0:
			continue
		var pct_str = left.substr(idx + 1).strip_edges()
		if pct_str.is_valid_float():
			return {"pct": float(pct_str)}
	return {"pct": -1.0}


# `pactl get-sink-mute X` → "Mute: yes|no"
static func parse_pactl_mute(text):
	for line in str(text).split("\n"):
		line = line.strip_edges()
		if line.begins_with("Mute:"):
			return {"muted": line.to_lower().find("yes") >= 0}
	return {"muted": false}


# `wpctl get-volume X` → "Volume: 0.98" o "Volume: 0.98 [MUTED]"
static func parse_wpctl_volume(text):
	for line in str(text).split("\n"):
		line = line.strip_edges()
		if line.begins_with("Volume:"):
			var rest = line.substr("Volume:".length()).strip_edges()
			var muted = rest.find("[MUTED]") >= 0
			rest = rest.replace("[MUTED]", "").strip_edges()
			if rest.is_valid_float():
				return {"pct": float(rest) * 100.0, "muted": muted}
	return {"pct": -1.0, "muted": false}
