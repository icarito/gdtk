extends Reference

# Vecindario: lectura de Wi-Fi (NetworkManager vía nmcli) y de los vecinos de la red
# local (ip -4 neigh show), sin exponer secretos ni salida cruda. Las funciones de
# parseo y de geometría simbólica son puras (static): el hilo de fondo sólo las usa
# para refrescar cada ~20 s y la vista lee el último resultado sin bloquear el frame.
#
# Sólo estado: conectar abre `nmtui connect` fuera de esta vista (shell._open_nmtui),
# nunca se pasan contraseñas por argumentos ni se guardan acá.

const REFRESH_MS = 20000      # refresco normal del listado
const RESCAN_MS = 60000       # rescan best-effort una vez por minuto
const SLEEP_STEP_MS = 100     # granularidad para que stop() no espere de más

# Cápsula de un nodo en la vista: el disco del AP más el alto de su etiqueta
# (SSID arriba, dBm abajo). La separación de la geometría simbólica usa la cápsula,
# no el disco: así dos nodos nunca dejan sus etiquetas superpuestas.
const NODE_HALF_W = 32.0      # media anchura (64 px de diámetro)
const NODE_HALF_H = 50.0      # media altura (64 x 100 px: disco + etiqueta debajo)
const LABEL_TAIL = 18.0       # alto extra bajo el disco ocupado por el texto

var networks = []             # lista de nodos "red" (ESS), copiada por poll()
var hosts = []                # vecinos de la red local, copiada por poll()
var status = ""               # "", "ok", "empty", "off", "no_nmcli", "error"
var version = 0               # sube cuando el hilo escribió un resultado nuevo

var _mutex = Mutex.new()
var _thread = null
var _want_stop = false
var _nets = []
var _hosts = []
var _status = ""
var _version = 0
var _rescan_at = -RESCAN_MS


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
	status = _status
	version = _version
	_mutex.unlock()


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
		var res = _scan()
		_mutex.lock()
		_nets = res.get("nets", [])
		_hosts = res.get("hosts", [])
		_status = res.get("status", "")
		_version += 1
		_mutex.unlock()
		var waited = 0
		while waited < REFRESH_MS:
			OS.delay_msec(SLEEP_STEP_MS)
			waited += SLEEP_STEP_MS
			if _stopped():
				return


func _scan():
	var out = []
	if OS.execute("sh", ["-c", "command -v nmcli >/dev/null 2>&1"]) != 0:
		return {"status": "no_nmcli", "nets": [], "hosts": _read_hosts()}
	# Radio: si está apagada no se lista (y no se enciende en silencio).
	var code = OS.execute("nmcli", ["radio", "wifi"], true, out)
	var radio = str(out[0]).strip_edges() if out.size() > 0 else ""
	if code != 0 or radio != "enabled":
		return {"status": ("off" if code == 0 else "error"), "nets": [], "hosts": _read_hosts()}
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
		return {"status": "error", "nets": [], "hosts": _read_hosts()}
	var text = ""
	for line in out:
		text += str(line) + "\n"
	var nets = parse_nmcli(text)
	return {"status": ("ok" if not nets.empty() else "empty"),
		"nets": nets, "hosts": _read_hosts()}


func _read_hosts():
	var out = []
	if OS.execute("ip", ["-4", "neigh", "show"], true, out) != 0:
		return []
	var text = ""
	for line in out:
		text += str(line) + "\n"
	return parse_neigh(text)


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
static func _angle_for(band, t):
	if band == "5":
		return PI + lerp(-1.35, 1.35, t)
	return lerp(-1.35, 1.35, t)


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


# Media altura de la cápsula de un nodo de radio `rad`: el disco más la etiqueta.
static func capsule_half_h(rad):
	return float(rad) + LABEL_TAIL


# Una pasada de repulsión por cápsulas. Empuja cada par a lo largo de la recta que
# une sus centros, hasta separarlos según la función soporte de la caja en esa
# dirección ((hw_i+hw_j)|dx| + (hh_i+hh_j)|dy|): es estable y determinista, y no se
# atasca como el empuje por eje mínimo en un caso denso.
static func _separate_once(p, half_w, half_h, gap):
	var n = p.size()
	for i in range(n):
		for j in range(i + 1, n):
			var d = p[j] - p[i]
			var dist = d.length()
			var dir
			if dist < 0.0001:
				# Coincidencia exacta: se rompe la simetría de forma determinista.
				dir = Vector2(1.0, 0.0).rotated(float(i * 7 + j) * 0.7)
				dist = 0.0
			else:
				dir = d / dist
			var need = (float(half_w[i]) + float(half_w[j]) + gap) * abs(dir.x) \
				+ (float(half_h[i]) + float(half_h[j]) + gap) * abs(dir.y)
			if dist >= need:
				continue  # ya separados (hay eje que los separa)
			var push = (need - dist) * 0.5
			p[i] -= dir * push
			p[j] += dir * push


# Separación por cápsulas (pura y determinista). Cada nodo ocupa una caja
# [p - (hw, hh), p + (hw, hh)]; dos cajas nunca deben solaparse (con `gap` de margen),
# así la etiqueta debajo del disco también queda libre. Se aplica repulsión iterativa
# con un resorte decreciente hacia la posición original para conservar el anillo y el
# sector angular aproximados (el nodo puede salir del anillo si hace falta: la última
# pasada es repulsión pura). Los mismos nodos dan siempre la misma disposición.
static func relax_capsules(pts, half_w, half_h, gap = 2.0, iterations = 48, spring = 0.02):
	# Copia a Array: acepta igual Array que PoolVector2Array (este último no tiene
	# duplicate() en Godot 3).
	var p = []
	for v in pts:
		p.append(v)
	var n = p.size()
	for it in range(iterations):
		_separate_once(p, half_w, half_h, gap)
		# Resorte decreciente hacia la posición original.
		var s = spring * float(iterations - it - 1) / float(iterations)
		if s > 0.0:
			for i in range(n):
				p[i] = p[i].linear_interpolate(pts[i], s)
	# Pasadas finales sin resorte: en un caso denso una sola vuelta puede quedar a
	# medias. Se insiste sólo mientras quede algún par solapado (acotado y determinista).
	var guard = 0
	while guard < iterations and capsules_overlap(p, half_w, half_h, gap):
		guard += 1
		_separate_once(p, half_w, half_h, gap)
	return p


# Compatibilidad: la relajación circular histórica es el caso hw == hh == radio.
static func relax_positions(pts, radii, gap = 2.0, iterations = 16, spring = 0.03):
	return relax_capsules(pts, radii, radii, gap, iterations, spring)


# ¿Se solapa algún par de cápsulas? Prueba pura (misma definición que relax_capsules)
# para verificar que ninguna etiqueta pisa a otro nodo.
static func capsules_overlap(pts, half_w, half_h, gap = 0.0):
	for i in range(pts.size()):
		for j in range(i + 1, pts.size()):
			if abs(pts[j].x - pts[i].x) < float(half_w[i]) + float(half_w[j]) + gap \
					and abs(pts[j].y - pts[i].y) < float(half_h[i]) + float(half_h[j]) + gap:
				return true
	return false


# Vecinos IPv4 de la red local: REACHABLE/STALE, sin FAILED ni INCOMPLETE.
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
	return true


# Wrapper de instancia para poder correr la autoprueba desde un test/SceneTree.
func run_selftest():
	return selftest()
