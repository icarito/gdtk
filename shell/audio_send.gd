extends Reference

# Modelo puro de «Enviar audio a otro equipo» (Grupo).
# No hace I/O: sólo construye/parsea para que el shell ejecute
# OS.execute("pactl", argv, true, out). Ver SPEC-sugar-group-2026-10.md.

const RECV_PORT = 4714


static func _valid_port(port):
	var p = int(port)
	return p >= 1 and p <= 65535


static func sink_name(hid):
	var s = str(hid)
	var out = ""
	for i in range(s.length()):
		var c = s.substr(i, 1)
		var code = ord(c)
		if (code >= 48 and code <= 57) \
				or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122) \
				or c == "_":
			out += c
		else:
			out += "_"
	return "gdtk_send_" + out


static func recv_load_argv(sender_ip, port = RECV_PORT):
	if not String(sender_ip).is_valid_ip_address():
		return []
	if not _valid_port(port):
		return []
	return ["load-module", "module-native-protocol-tcp",
		"port=" + str(int(port)),
		# Sólo la ACL: auth-anonymous=1 abriría el puerto a cualquiera en PulseAudio.
		"auth-ip-acl=" + String(sender_ip)]


static func tunnel_load_argv(peer_ip, port, hid):
	if not String(peer_ip).is_valid_ip_address():
		return []
	if not _valid_port(port):
		return []
	var ip = String(peer_ip)
	var server = "tcp:" + ip + ":" + str(int(port))
	if ip.find(":") != -1:
		server = "tcp:[" + ip + "]:" + str(int(port))
	return ["load-module", "module-tunnel-sink",
		"server=" + server,
		"sink_name=" + sink_name(hid)]


static func unload_argv(module_id):
	var mid = 0
	if typeof(module_id) == TYPE_STRING:
		if not String(module_id).is_valid_integer():
			return []
		mid = int(module_id)
	elif typeof(module_id) == TYPE_INT or typeof(module_id) == TYPE_REAL:
		mid = int(module_id)
	else:
		return []
	if mid <= 0:
		return []
	return ["unload-module", str(mid)]


static func parse_module_id(out_text):
	for line in String(out_text).split("\n"):
		var t = line.strip_edges()
		if t == "":
			continue
		if t.is_valid_integer():
			return int(t)
		return -1
	return -1


static func parse_default_sink(info_text):
	var marker = "Default Sink: "
	for line in String(info_text).split("\n"):
		var idx = line.find(marker)
		if idx != -1:
			return line.substr(idx + marker.length()).strip_edges()
	return ""


static func parse_sink_inputs(short_text):
	var out = []
	for line in String(short_text).split("\n"):
		if line.strip_edges() == "":
			continue
		var cols = line.split("\t")
		if cols.size() == 0:
			continue
		var first = cols[0].strip_edges()
		if first.is_valid_integer():
			out.append(int(first))
	return out


static func move_argvs(input_ids, sink):
	if String(sink) == "":
		return []
	var out = []
	for id in input_ids:
		out.append(["move-sink-input", str(id), String(sink)])
	return out
