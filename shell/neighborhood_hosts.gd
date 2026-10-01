extends Reference

# Modelo puro de hosts DNS-SD del Vecindario. Sin Avahi runtime, filesystem ni UI.

const SERVICE_GVD = "_gdtk-gvd._udp"
const SERVICE_DESKFLOW = "_gdtk-deskflow._tcp"
const SERVICE_CLIP = "_gdtk-clip._tcp"
const SERVICE_KINDS = {
	SERVICE_GVD: "gvd",
	SERVICE_DESKFLOW: "deskflow",
	SERVICE_CLIP: "clip",
}
const DEFAULT_TTL_SEC = 120


static func parse_services(text, now_sec = 0):
	var out = []
	for raw in text.split("\n", false):
		var line = raw.strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var rec = _parse_avahi_line(line, now_sec)
		if rec.empty():
			rec = _parse_simple_line(line, now_sec)
		if not rec.empty() and SERVICE_KINDS.has(rec.service):
			out.append(rec)
	return out


static func build_hosts(services, overrides = {}, now_sec = 0, ttl_sec = DEFAULT_TTL_SEC):
	var hosts = {}
	var order = []
	for svc in services:
		var hid = str(svc.txt.get("hid", "")).strip_edges()
		var id = hid if hid != "" else _degraded_id(svc)
		if not hosts.has(id):
			hosts[id] = _new_host(id, hid, svc)
			order.append(id)
		_add_service(hosts[id], svc, now_sec, ttl_sec)
	for hid in overrides.keys():
		if not hosts.has(hid):
			hosts[hid] = _new_saved_host(hid)
			order.append(hid)
	var out = []
	for id in order:
		var host = hosts[id]
		_apply_override(host, overrides.get(id, {}))
		if host.live_count > 0:
			host.state = "visto"
		elif host.services.size() > 0:
			host.state = "perdido"
		elif host.saved:
			host.state = "guardado"
		host.erase("live_count")
		host.erase("saved")
		out.append(host)
	return sort_hosts(out)


static func model_from_text(text, overrides = {}, now_sec = 0, ttl_sec = DEFAULT_TTL_SEC):
	return build_hosts(parse_services(text, now_sec), overrides, now_sec, ttl_sec)


# Excluye del modelo cualquier host que sea esta misma máquina descubierta por
# mDNS. `local_hid` es la identidad opaca local (PUBLISH_PLAN.local_identity) y
# `local_name` el hostname/etiqueta visible. Puro: no toca red ni disco.
static func exclude_local(hosts, local_hid, local_name = ""):
	var out = []
	if typeof(hosts) != TYPE_ARRAY:
		return out
	var hid = String(local_hid).strip_edges()
	var name = String(local_name).strip_edges().to_lower()
	for h in hosts:
		if typeof(h) != TYPE_DICTIONARY:
			continue
		if _is_local_host(h, hid, name):
			continue
		out.append(h)
	return out


static func _is_local_host(host, local_hid, local_name):
	if local_hid != "":
		if String(host.get("hid", "")).strip_edges() == local_hid:
			return true
		if String(host.get("id", "")).strip_edges() == local_hid:
			return true
	if local_name != "":
		return _host_name_is(host, local_name)
	return false


static func _host_name_is(host, local_name):
	if String(host.get("label", "")).strip_edges().to_lower() == local_name:
		return true
	var caps = host.get("capabilities", {})
	if typeof(caps) == TYPE_DICTIONARY:
		for cap in caps.values():
			if typeof(cap) != TYPE_DICTIONARY:
				continue
			var txt = cap.get("txt", {})
			if typeof(txt) == TYPE_DICTIONARY \
					and String(txt.get("name", "")).strip_edges().to_lower() == local_name:
				return true
	for svc in host.get("services", []):
		if typeof(svc) != TYPE_DICTIONARY:
			continue
		if String(svc.get("name", "")).strip_edges().to_lower() == local_name:
			return true
	return false


# Orden determinista de las fichas: nombre ascendente (sin distinguir mayúsculas)
# y, a igual nombre, id ascendente. Puro; no depende del orden de discovery.
static func sort_hosts(hosts):
	var arr = []
	if typeof(hosts) != TYPE_ARRAY:
		return arr
	for h in hosts:
		arr.append(h)
	var n = arr.size()
	for i in range(n):
		for j in range(i + 1, n):
			if _host_before(arr[j], arr[i]):
				var tmp = arr[i]
				arr[i] = arr[j]
				arr[j] = tmp
	return arr


static func _host_before(a, b):
	var la = String(a.get("label", "")).strip_edges().to_lower()
	var lb = String(b.get("label", "")).strip_edges().to_lower()
	if la != lb:
		return la < lb
	return String(a.get("id", "")) < String(b.get("id", ""))


static func _new_host(id, hid, svc):
	var txt = svc.txt
	var label = str(txt.get("name", svc.name)).strip_edges()
	if label == "":
		label = str(svc.host)
	var kind = _valid_kind(str(txt.get("kind", "unknown")))
	var icon = str(txt.get("icon", kind))
	return {
		"id": id,
		"hid": hid,
		"label": label,
		"kind": kind,
		"icon": icon,
		"auth": str(txt.get("auth", "")),
		"state": "visto",
		"connected": false,
		"degraded": hid == "",
		"services": [],
		"capabilities": {},
		"last_seen": 0,
		"live_count": 0,
		"saved": false,
	}


static func _new_saved_host(hid):
	return {
		"id": hid,
		"hid": hid,
		"label": hid,
		"kind": "unknown",
		"icon": "unknown",
		"auth": "",
		"state": "guardado",
		"connected": false,
		"degraded": false,
		"services": [],
		"capabilities": {},
		"last_seen": 0,
		"live_count": 0,
		"saved": true,
	}


static func _add_service(host, svc, now_sec, ttl_sec):
	var seen = int(svc.get("seen_at", now_sec))
	var live = now_sec <= 0 or ttl_sec <= 0 or seen + ttl_sec >= now_sec
	var item = svc.duplicate(true)
	item.state = "visto" if live else "perdido"
	item.capability = SERVICE_KINDS[svc.service]
	host.services.append(item)
	host.last_seen = max(int(host.last_seen), seen)
	if live:
		host.live_count += 1
		host.capabilities[item.capability] = item


static func _apply_override(host, override):
	if typeof(override) != TYPE_DICTIONARY:
		return
	host.saved = true
	if override.has("label"):
		host.label = str(override.label)
	if override.has("kind"):
		host.kind = _valid_kind(str(override.kind))
	if override.has("icon"):
		host.icon = str(override.icon)
	elif override.has("kind"):
		host.icon = host.kind
	if override.has("model"):
		host.model = str(override.model)


static func _valid_kind(kind):
	if ["desktop", "laptop", "tablet", "mobile", "tv"].has(kind):
		return kind
	return "unknown"


static func _degraded_id(svc):
	return "degraded:%s:%s:%s:%s" % [svc.service, svc.name, svc.host, str(svc.port)]


static func _parse_avahi_line(line, now_sec):
	var f = line.split(";", false)
	if f.size() < 9 or f[0] != "=":
		return {}
	var txt = {}
	for i in range(9, f.size()):
		_merge_txt(txt, _unquote(f[i]))
	return _service_record(_unquote(f[4]), _unquote(f[3]), _unquote(f[6]),
		_unquote(f[7]), int(f[8]) if str(f[8]).is_valid_integer() else 0, txt, now_sec)


static func _parse_simple_line(line, now_sec):
	var p = line.split(" ", false)
	if p.size() < 2 or p[0] != "service":
		return {}
	var service = p[1]
	var txt = {}
	var name = ""
	var host = ""
	var address = ""
	var port = 0
	var seen = now_sec
	for i in range(2, p.size()):
		var kv = p[i].split("=", true, 1)
		if kv.size() != 2:
			continue
		var k = kv[0]
		var v = _unquote(kv[1])
		match k:
			"name":
				name = v
				txt.name = v
			"host":
				host = v
			"addr", "address":
				address = v
			"port":
				port = int(v) if v.is_valid_integer() else 0
			"seen", "seen_at":
				seen = int(v) if v.is_valid_integer() else now_sec
			_:
				txt[k] = v
	return _service_record(service, name, host, address, port, txt, seen)


static func _service_record(service, name, host, address, port, txt, seen_at):
	return {
		"service": service,
		"name": name,
		"host": host,
		"address": address,
		"port": port,
		"txt": txt,
		"seen_at": seen_at,
	}


static func _merge_txt(txt, field):
	var s = field.strip_edges()
	if s == "":
		return
	# avahi-browse -p junta todos los TXT en un campo: "a=1" "b=2" (ya sin comillas externas).
	for part in s.split("\" \""):
		var kv = _unquote(part).split("=", true, 1)
		if kv.size() == 2:
			txt[kv[0]] = kv[1]


static func _unquote(s):
	var v = str(s).strip_edges()
	if v.length() >= 2 and v[0] == "\"" and v[v.length() - 1] == "\"":
		return v.substr(1, v.length() - 2)
	return v


static func _find_host(hosts, id):
	for h in hosts:
		if h.id == id:
			return h
	return null


static func selftest():
	var sample = PoolStringArray([
		"=;eth0;IPv4;Tengu GVD;_gdtk-gvd._udp;local;tengu.local;192.168.1.20;5600;\"v=1\";\"hid=h1\";\"name=Tengu\";\"kind=laptop\";\"icon=laptop\";\"auth=ask\";\"role=recv\";\"state=ready\"",
		"=;eth0;IPv4;Tengu Deskflow;_gdtk-deskflow._tcp;local;tengu.local;192.168.1.20;24800;v=1;hid=h1;name=Tengu;kind=laptop;auth=ask;role=server;clip=1",
		"service _gdtk-clip._tcp name=Clip host=loose.local port=9911 v=1 kind=desktop auth=ask",
		"service _gdtk-gvd._udp name=Viejo host=old.local port=5600 hid=old name=Viejo kind=desktop seen=10",
	]).join("\n")
	var hosts = model_from_text(sample, {
		"h1": {"label": "ThinkPad de taller", "kind": "desktop"},
		"saved": {"label": "Guardado", "kind": "tablet"},
	}, 200, 60)
	var h1 = _find_host(hosts, "h1")
	var loose = null
	var old = _find_host(hosts, "old")
	var saved = _find_host(hosts, "saved")
	for h in hosts:
		if h.degraded:
			loose = h
	assert(h1 != null and h1.services.size() == 2, "dos servicios del mismo hid")
	assert(h1.capabilities.has("gvd") and h1.capabilities.has("deskflow"), "dos capacidades")
	assert(h1.label == "ThinkPad de taller" and h1.kind == "desktop", "override label/kind")
	assert(loose != null and loose.degraded and loose.services.size() == 1, "servicio sin hid degradado")
	assert(old != null and old.state == "perdido" and old.services[0].state == "perdido", "servicio vencido")
	assert(saved != null and saved.state == "guardado" and saved.label == "Guardado", "host guardado")
	return true


func run_selftest():
	return selftest()
