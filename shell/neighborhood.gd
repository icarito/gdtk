extends Reference

# Vecindario: lectura de Wi-Fi (NetworkManager vía nmcli) y de los hosts DNS-SD de
# gdtk (avahi-browse -> shell/neighborhood_hosts.gd), sin exponer secretos ni salida
# cruda. Las funciones de parseo y de geometría simbólica son puras (static): el
# hilo de fondo sólo las usa para refrescar cada ~20 s y la vista lee el último
# resultado sin bloquear el frame.
#
# Sólo estado: conectar abre `nmtui connect` fuera de esta vista (shell._open_nmtui),
# nunca se pasan contraseñas por argumentos ni se guardan acá.

const REFRESH_MS = 20000      # refresco normal del listado
const RESCAN_MS = 60000       # rescan best-effort una vez por minuto
const SLEEP_STEP_MS = 100     # granularidad para que stop() no espere de más
const AVAHI_TIMEOUT = "4"      # avahi-browse puede quedarse esperando si no hay servicio
const BT_TIMEOUT = "2"        # timeout de cada bluetoothctl (worker)
const BT_MAX = 16             # tope de dispositivos para no inflar el mapa

# Hosts DNS-SD de gdtk: el modelo puro vive en neighborhood_hosts.gd, acá sólo se
# invoca avahi-browse de forma acotada. Si no está o falla, no hay hosts y el
# Wi-Fi sigue igual.
const HOSTS_SCRIPT = preload("res://neighborhood_hosts.gd")
const PUBLISH_PLAN = preload("res://neighborhood_publish_plan.gd")
const BT_APPLET = preload("res://applet_bluetooth.gd")  # reutiliza su parser puro
const MAP = preload("res://neighborhood_map.gd")        # geometría pura (anti-solape)
const GDTK_SERVICES = ["_gdtk-gvd._udp", "_gdtk-deskflow._tcp", "_gdtk-clip._tcp"]

# Cápsula de un nodo en la vista: el disco del AP más el alto de su etiqueta
# (SSID arriba, dBm abajo). La separación de la geometría simbólica usa la cápsula,
# no el disco: así dos nodos nunca dejan sus etiquetas superpuestas.
const NODE_HALF_W = 32.0      # media anchura (64 px de diámetro)
const NODE_HALF_H = 50.0      # media altura (64 x 100 px: disco + etiqueta debajo)
const LABEL_TAIL = 18.0       # alto extra bajo el disco ocupado por el texto

var networks = []             # lista de nodos "red" (ESS), copiada por poll()
var hosts = []                # hosts DNS-SD de gdtk, copiada por poll()
var bt_devices = []           # dispositivos Bluetooth conocidos, copiada por poll()
var status = ""               # "", "ok", "empty", "off", "no_nmcli", "error"
var version = 0               # sube cuando el hilo escribió un resultado nuevo

var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _want_refresh = false      # pide un refresco inmediato (tras una acción)
var _hosts_model = null        # instancia diferida de HOSTS_SCRIPT (sólo hilo)
var _nets = []
var _hosts = []
var _bt = []
var _status = ""
var _version = 0
var _rescan_at = -RESCAN_MS
var _local_ready = false      # identidad local resuelta una sola vez (hilo)
var _local_hid = ""
var _local_name = ""


# --- ciclo de vida -----------------------------------------------------------

# Arranca el hilo de refresco (idempotente). Se llama al abrir la vista.
func start():
	if _thread != null:
		return
	_want_stop = false
	_thread = Thread.new()
	_thread.start(self, "_work")


func running():
	return _thread != null


# Detiene el hilo y espera a que termine (llamado en shell._exit_tree).
func stop():
	_mutex.lock()
	_want_stop = true
	_mutex.unlock()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


# Copia el último resultado del hilo a las variables públicas (hilo principal).
func poll():
	_mutex.lock()
	networks = _nets
	hosts = _hosts
	bt_devices = _bt
	status = _status
	version = _version
	_mutex.unlock()


# Pide un refresco inmediato (p. ej. tras conectar/desconectar un dispositivo).
# El worker lo atiende sin esperar el periodo; nunca bloquea al llamador.
func request_refresh():
	_mutex.lock()
	_want_refresh = true
	_mutex.unlock()


func _refresh_requested():
	_mutex.lock()
	var r = _want_refresh
	_mutex.unlock()
	return r


func status_line():
	match status:
		"off":
			return "Wi-Fi apagado"
		"empty":
			return "No hay redes al alcance"
		"no_nmcli":
			return "NetworkManager (nmcli) no disponible"
		"error":
			return "No se pudo leer el Wi-Fi"
		"ok":
			return str(networks.size()) + " red(es) al alcance"
	return "Leyendo Wi-Fi..."


# --- hilo de fondo -----------------------------------------------------------

func _stopped():
	_mutex.lock()
	var s = _want_stop
	_mutex.unlock()
	return s


func _work(_userdata):
	while true:
		if _stopped():
			return
		_mutex.lock()
		_want_refresh = false
		_mutex.unlock()
		var res = _scan()
		_mutex.lock()
		_nets = res.get("nets", [])
		_hosts = res.get("hosts", [])
		_bt = res.get("bt", [])
		_status = res.get("status", "")
		_version += 1
		_mutex.unlock()
		var waited = 0
		while waited < REFRESH_MS:
			OS.delay_msec(SLEEP_STEP_MS)
			waited += SLEEP_STEP_MS
			if _stopped():
				return
			if _refresh_requested():
				break


func _scan():
	var out = []
	var hosts = _read_hosts()
	var bt = _read_bt()
	if OS.execute("sh", ["-c", "command -v nmcli >/dev/null 2>&1"]) != 0:
		return {"status": "no_nmcli", "nets": [], "hosts": hosts, "bt": bt}
	# Radio: si está apagada no se lista (y no se enciende en silencio).
	var code = OS.execute("nmcli", ["radio", "wifi"], true, out)
	var radio = str(out[0]).strip_edges() if out.size() > 0 else ""
	if code != 0 or radio != "enabled":
		return {"status": ("off" if code == 0 else "error"), "nets": [], "hosts": hosts, "bt": bt}
	# Rescan best-effort una vez por minuto: el error de permisos se ignora.
	var now = OS.get_ticks_msec()
	if now - _rescan_at >= RESCAN_MS:
		_rescan_at = now
		OS.execute("nmcli", ["device", "wifi", "rescan"], true)
	out = []
	code = OS.execute("nmcli",
		["-t", "-f", "IN-USE,SSID,BSSID,CHAN,FREQ,SIGNAL,SECURITY", "device", "wifi", "list"],
		true, out)
	if code != 0:
		return {"status": "error", "nets": [], "hosts": hosts, "bt": bt}
	var text = ""
	for line in out:
		text += str(line) + "\n"
	var nets = parse_nmcli(text)
	return {"status": ("ok" if not nets.empty() else "empty"),
		"nets": nets, "hosts": hosts, "bt": bt}


# Hosts del Vecindario: servicios DNS-SD de gdtk resueltos con avahi-browse
# (`-r` resolver, `-t` termina tras el volcado, `-p` parseable), nunca vecinos ARP
# como objetos de acción. Es acotado: si avahi-browse no existe o falla se
# devuelve [] sin salida cruda ni secretos, y el Wi-Fi no se ve afectado.
func _read_hosts():
	var out = []
	if OS.execute("sh", ["-c", "command -v avahi-browse >/dev/null 2>&1"]) != 0:
		return []
	var text = ""
	for svc in GDTK_SERVICES:
		out = []
		if OS.execute("timeout", [AVAHI_TIMEOUT, "avahi-browse", "-rtp", svc], true, out) != 0:
			continue
		for line in out:
			text += str(line) + "\n"
	if text.strip_edges() == "":
		return []
	if _hosts_model == null:
		_hosts_model = HOSTS_SCRIPT.new()
	_ensure_local_identity()
	var hosts = _hosts_model.model_from_text(text)
	# El host local se descubre a sí mismo por mDNS: se filtra del modelo con la
	# misma identidad que publica el Vecindario (hid opaco + hostname visible).
	return HOSTS_SCRIPT.exclude_local(hosts, _local_hid, _local_name)


# Identidad local (hid opaco + hostname) resuelta una vez. Misma regla que el
# shell (_local_hostname -> PUBLISH_PLAN.local_identity) sin cargar shell.gd en
# tests ni exponer secretos.
func _ensure_local_identity():
	if _local_ready:
		return
	_local_ready = true
	var host = OS.get_environment("HOSTNAME").strip_edges()
	if host == "":
		var f = File.new()
		if f.file_exists("/etc/hostname") and f.open("/etc/hostname", File.READ) == OK:
			host = f.get_as_text().strip_edges()
			f.close()
	var identity = PUBLISH_PLAN.local_identity(host)
	_local_hid = String(identity.hid)
	_local_name = String(identity.name)


# --- Bluetooth ---------------------------------------------------------------
# Dispositivos conocidos por bluetoothctl: nombre, estado (conectado/vinculado) y
# RSSI de los conectados (para ubicarlos simbólicamente). Todo desde el worker, con
# timeout corto; sin adaptador o radio apagada devuelve [] y el Wi-Fi no se afecta.
func _read_bt():
	var out = []
	if OS.execute("sh", ["-c", "command -v bluetoothctl >/dev/null 2>&1"]) != 0:
		return []
	if OS.execute("timeout", [BT_TIMEOUT, "bluetoothctl", "show"], true, out) != 0:
		return []
	var p = BT_APPLET.parse_bluetooth_show(_join(out))
	if p.no_controller or p.powered != "yes":
		return []
	var devs = parse_bt_devices(_join(_bt_run(["devices"])))
	var connected = parse_bt_devices(_join(_bt_run(["devices", "Connected"])))
	var paired = parse_bt_devices(_join(_bt_run(["devices", "Paired"])))
	var conn_set = _bt_addr_set(connected)
	var pair_set = _bt_addr_set(paired)
	var result = []
	for d in devs:
		if result.size() >= BT_MAX:
			break
		var addr = d.address
		var rssi = 0
		var icon = ""
		if conn_set.has(addr):
			var parsed = parse_bt_info(_join(_bt_run(["info", addr])))
			rssi = parsed.rssi
			icon = parsed.icon
		result.append({
			"address": addr, "name": d.name,
			"connected": conn_set.has(addr), "paired": pair_set.has(addr),
			"rssi": rssi, "icon": icon,
		})
	_place_bt(result)
	return result


func _bt_run(args):
	var out = []
	if OS.execute("timeout", [BT_TIMEOUT, "bluetoothctl"] + args, true, out) != 0:
		return []
	return out


func _bt_addr_set(list):
	var s = {}
	for d in list:
		s[d.address] = true
	return s


func _join(lines):
	var t = ""
	for l in lines:
		t += str(l) + "\n"
	return t


# --- parseo puro -------------------------------------------------------------

# Separa una línea de nmcli -t por `:` sin romper los `\:` (BSSID) y `\\` escapados.
static func split_escaped(line):
	var out = []
	var cur = ""
	var i = 0
	while i < line.length():
		var ch = line[i]
		if ch == "\\" and i + 1 < line.length():
			cur += line[i + 1]
			i += 2
			continue
		if ch == ":":
			out.append(cur)
			cur = ""
		else:
			cur += ch
		i += 1
	out.append(cur)
	return out


static func dbm_of(sig):
	return int(sig / 2.0 - 100.0)


static func band_of(freq_mhz):
	return "5" if freq_mhz >= 3000 else "2.4"


# Anillo simbólico por RSSI: cerca (> -60), medio (-60..-75), lejos (< -75).
static func ring_of(dbm):
	if dbm > -60:
		return "cerca"
	if dbm >= -75:
		return "medio"
	return "lejos"


# Radio continuo dentro del anillo: más señal = más cerca del centro.
static func _radius_frac(dbm):
	if dbm > -60:
		var t = clamp((dbm + 60.0) / 40.0, 0.0, 1.0)   # -60 -> 0, -20 -> 1
		return lerp(0.46, 0.20, t)
	elif dbm >= -75:
		var t2 = clamp((dbm + 75.0) / 15.0, 0.0, 1.0)  # -75 -> 0, -60 -> 1
		return lerp(0.74, 0.46, t2)
	var t3 = clamp((dbm + 100.0) / 25.0, 0.0, 1.0)      # -100 -> 0, -75 -> 1
	return lerp(0.96, 0.74, t3)


# Ángulo por banda: 2.4 GHz en el semicírculo derecho, 5 GHz en el izquierdo.
# G3: arcos más anchos (hasta ±1.9 rad) para repartir las redes por casi toda la
# elipse y no apilarlas en dos franjas estrechas.
const WIFI_ARC = 1.9
static func _angle_for(band, t):
	if band == "5":
		return PI + lerp(-WIFI_ARC, WIFI_ARC, t)
	return lerp(-WIFI_ARC, WIFI_ARC, t)


# Lista de nodos "red" (ESS): agrupa radios con el mismo SSID, elige la primaria
# (la radio en uso, si la hay), calcula congestión por canal y ubica simbólicamente.
static func parse_nmcli(text):
	var radios = []
	for raw in text.split("\n", false):
		var line = raw.strip_edges()
		if line == "":
			continue
		var f = split_escaped(line)
		if f.size() < 7:
			continue
		var ssid = f[1]
		if ssid == "":
			continue  # red oculta: sin SSID no hay nodo que mostrar
		var freq = 0
		var fparts = f[4].split(" ", false)
		if fparts.size() > 0 and fparts[0].is_valid_integer():
			freq = int(fparts[0])
		var sig = int(f[5]) if f[5].is_valid_integer() else 0
		sig = int(clamp(sig, 0, 100))
		radios.append({
			"ssid": ssid,
			"bssid": f[2],
			"chan": int(f[3]) if f[3].is_valid_integer() else 0,
			"freq": freq,
			"signal": sig,
			"dbm": dbm_of(sig),
			"security": f[6].strip_edges(),
			"in_use": f[0].strip_edges() == "*",
			"band": band_of(freq),
		})
	# Agrupa por SSID, conservando el orden de aparición.
	var order = []
	var groups = {}
	for r in radios:
		if not groups.has(r.ssid):
			groups[r.ssid] = []
			order.append(r.ssid)
		groups[r.ssid].append(r)
	var nets = []
	for ssid in order:
		var rs = groups[ssid]
		var primary = rs[0]
		for r in rs:
			if r["signal"] > primary["signal"]:
				primary = r
		var in_use = false
		for r in rs:
			if r.in_use:
				in_use = true
				primary = r
		nets.append({
			"ssid": ssid,
			"radios": rs,
			"bssid": primary.bssid,
			"chan": primary.chan,
			"freq": primary.freq,
			"signal": primary["signal"],
			"dbm": primary.dbm,
			"security": primary.security,
			"band": primary.band,
			"in_use": in_use,
			"congestion": 1,
			"ring": ring_of(primary.dbm),
			"angle": 0.0,
			"r_frac": 0.0,
		})
	# Congestión: nº de redes que comparten el canal de la primaria.
	var by_chan = {}
	for n in nets:
		by_chan[n.chan] = int(by_chan.get(n.chan, 0)) + 1
	for n in nets:
		n.congestion = by_chan[n.chan]
	_place_all(nets)
	return nets


# Ubicación simbólica: radio continuo por RSSI + ángulo por banda/canal, con un
# pequeño desplazamiento determinista por hash del BSSID para despegar solapados.
static func _place_all(nets):
	var chans = {"2.4": [], "5": []}
	for n in nets:
		if not chans[n.band].has(n.chan):
			chans[n.band].append(n.chan)
	chans["2.4"].sort()
	chans["5"].sort()
	for n in nets:
		var list = chans[n.band]
		var t = 0.5
		if list.size() > 1:
			t = float(list.find(n.chan)) / float(list.size() - 1)
		var h = abs(n.bssid.hash())
		n.r_frac = clamp(_radius_frac(n.dbm) + (0.5 - float(h % 100) / 100.0) * 0.03, 0.12, 0.98)
		n.angle = _angle_for(n.band, t) + (float((h / 100) % 1000) / 1000.0 - 0.5) * 0.22


# Dispositivos de `bluetoothctl devices`: líneas "Device AA:BB:.. Nombre".
static func parse_bt_devices(text):
	var out = []
	for raw in String(text).split("\n", false):
		var l = raw.strip_edges()
		if not l.begins_with("Device "):
			continue
		var rest = l.substr("Device ".length())
		var sp = rest.find(" ")
		var addr = (rest.substr(0, sp) if sp >= 0 else rest).strip_edges()
		var name = (rest.substr(sp + 1) if sp >= 0 else "").strip_edges()
		if addr == "":
			continue
		out.append({"address": addr, "name": (name if name != "" else addr)})
	return out


# Campos de `bluetoothctl info <addr>` que importan: RSSI (dBm) e Icon.
static func parse_bt_info(text):
	var res = {"rssi": 0, "icon": ""}
	for raw in String(text).split("\n", false):
		var l = raw.strip_edges()
		if l.begins_with("RSSI:"):
			var v = l.substr("RSSI:".length()).strip_edges()
			if v.is_valid_integer():
				res.rssi = int(v)
		elif l.begins_with("Icon:"):
			res.icon = l.substr("Icon:".length()).strip_edges()
	return res


# Ubicación simbólica de un dispositivo: **banda propia** en el sector inferior
# (G3), repartida por índice para no encimarse, y radio por estado/RSSI (conectado
# más cerca del centro; si hay RSSI, como el Wi-Fi). No es un radar real, sólo una
# metáfora estable y reproducible.
const BT_ARC = 1.2
static func _place_bt(devices):
	var n = devices.size()
	for i in range(n):
		var d = devices[i]
		var h = abs(String(d.address).hash())
		var t = 0.5 if n <= 1 else float(i) / float(n - 1)
		d["angle"] = PI * 0.5 + lerp(-BT_ARC, BT_ARC, t) \
			+ (float((h / 100) % 1000) / 1000.0 - 0.5) * 0.10
		var frac = 0.85
		if bool(d.connected):
			frac = 0.26
			if int(d.rssi) != 0:
				frac = clamp(_radius_frac(int(d.rssi)) * 0.6, 0.14, 0.5)
		elif bool(d.paired):
			frac = 0.55
		d["r_frac"] = clamp(frac + (float(int(h / 1000) % 100) / 100.0 - 0.5) * 0.04, 0.12, 0.98)


# Media altura de la cápsula de un nodo de radio `rad`: el disco más la etiqueta.
# La geometría de relajación vive ahora en neighborhood_map.gd (puro); acá se
# conservan estos wrappers para no romper la API histórica usada por los tests.
static func capsule_half_h(rad):
	return MAP.capsule_half_h(rad)


static func relax_capsules(pts, half_w, half_h, gap = 2.0, iterations = 48, spring = 0.02):
	return MAP.relax_capsules(pts, half_w, half_h, gap, iterations, spring)


# Compatibilidad: la relajación circular histórica es el caso hw == hh == radio.
static func relax_positions(pts, radii, gap = 2.0, iterations = 16, spring = 0.03):
	return MAP.relax_positions(pts, radii, gap, iterations, spring)


# ¿Se solapa algún par de cápsulas? Prueba pura (misma definición que relax_capsules)
# para verificar que ninguna etiqueta pisa a otro nodo.
static func capsules_overlap(pts, half_w, half_h, gap = 0.0):
	return MAP.capsules_overlap(pts, half_w, half_h, gap)


# Vecinos IPv4 de la red local (ip -4 neigh show): REACHABLE/STALE, sin FAILED ni
# INCOMPLETE. Se mantiene por compatibilidad y para las autopruebas; el campo
# público `hosts` ya no usa ARP sino hosts DNS-SD (model_from_text).
static func parse_neigh(text):
	var out = []
	for raw in text.split("\n", false):
		var line = raw.strip_edges()
		if line == "":
			continue
		var parts = line.split(" ", false)
		if parts.empty():
			continue
		var state = parts[parts.size() - 1]
		if state == "FAILED" or state == "INCOMPLETE":
			continue
		var mac = ""
		var dev = ""
		for i in range(parts.size()):
			if parts[i] == "lladdr" and i + 1 < parts.size():
				mac = parts[i + 1]
			elif parts[i] == "dev" and i + 1 < parts.size():
				dev = parts[i + 1]
		out.append({
			"ip": parts[0],
			"mac": mac,
			"dev": dev,
			"state": ("REACHABLE" if state == "REACHABLE" else "STALE"),
		})
	return out


static func _find_net(nets, ssid):
	for n in nets:
		if n.ssid == ssid:
			return n
	return null


# --- autoprueba --------------------------------------------------------------

# Ejemplos de `nmcli -t` (BSSID con `\:`, mismo SSID en 2.4 y 5 GHz) y un assert
# sobre el anillo. Correr con tests/neighborhood_test.gd o inst.run_selftest().
static func selftest():
	var sample = PoolStringArray([
		":MiRed:AA\\:BB\\:CC\\:DD\\:EE\\:01:6:2437 MHz:72:WPA2",
		"*:MiRed:AA\\:BB\\:CC\\:DD\\:EE\\:02:36:5180 MHz:40:WPA2",
		":Otra:11\\:22\\:33\\:44\\:55\\:66:1:2412 MHz:25:",
	]).join("\n")
	var nets = parse_nmcli(sample)
	assert(nets.size() == 2, "dos ESS distintos")
	var mired = _find_net(nets, "MiRed")
	var otra = _find_net(nets, "Otra")
	assert(mired != null and mired.radios.size() == 2, "MiRed agrupa 2 radios")
	assert(mired.radios[0].bssid == "AA:BB:CC:DD:EE:01", "BSSID desescapado")
	assert(mired.in_use and mired.band == "5", "primaria en uso en 5 GHz")
	assert(dbm_of(72) == -64 and ring_of(-64) == "medio", "anillo medio")
	assert(ring_of(dbm_of(25)) == "lejos", "señal débil: anillo lejano")
	assert(otra.band == "2.4" and cos(otra.angle) > 0.0, "2.4 GHz a la derecha")
	assert(cos(mired.angle) < 0.0, "5 GHz a la izquierda")
	assert(parse_neigh("192.168.1.1 dev wlan0 lladdr aa:bb:cc:dd:ee:ff REACHABLE\n192.168.1.9 dev wlan0 FAILED").size() == 1,
		"sin FAILED")
	var rel = relax_positions([Vector2(10.0, 10.0), Vector2(10.0, 10.0)], [32.0, 32.0], 2.0, 16, 0.0)
	assert((rel[0] - rel[1]).length() >= 64.0, "repulsión separa nodos de 64 px")
	var bt = parse_bt_devices("Device AA:BB:CC:DD:EE:01 Parlante\nDevice 11:22:33:44:55:66 Auriculares")
	assert(bt.size() == 2 and bt[0].address == "AA:BB:CC:DD:EE:01" and bt[0].name == "Parlante",
		"parseo de bluetoothctl devices")
	var info = parse_bt_info("RSSI: -57\nIcon: audio-card")
	assert(info.rssi == -57 and info.icon == "audio-card", "parseo de info")
	var placed = [{"address": "AA:BB:CC:DD:EE:01", "connected": true, "paired": true, "rssi": -50},
		{"address": "11:22:33:44:55:66", "connected": false, "paired": false, "rssi": 0}]
	_place_bt(placed)
	assert(placed[0].r_frac < placed[1].r_frac, "conectado más cerca que el lejano")
	return true


# Wrapper de instancia para poder correr la autoprueba desde un test/SceneTree.
func run_selftest():
	return selftest()
