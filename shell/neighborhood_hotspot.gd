extends Reference

# Señal Wi-Fi del Vecindario (SPEC-sugar-senal-wifi.md): modelo PURO de la señal
# que comparte Internet («Este equipo») y de la conexión a APs con clave.
#
# No ejecuta procesos, no toca disco ni red: sólo arma los argv de nmcli (sin
# secretos), valida psk/SSID y parsea la salida -t de nmcli. El shell/worker hacen
# la I/O. El secreto NUNCA viaja por argv: se escribe a un archivo 0600 efímero y
# se pasa con `passwd-file <archivo>` (formato `setting.propiedad:clave`).
#
# Perfil: se reutiliza el perfil estable `Hotspot` (SSID = hostname). El canal se
# fija al de la STA cuando hay uplink Wi-Fi (el driver de radio única exige el
# mismo canal para STA+AP).

const PROFILE = "Hotspot"       # nombre fijo del perfil de la señal
# La radio no se fija en el perfil: en bastion es `wlan0` y en cupid `mlan0`; NM
# elige el dispositivo Wi-Fi al activar. `iface` opcional permite forzarlo.

# Límites WPA-PSK y SSID (802.11): la clave va de 8 a 63 caracteres; el SSID hasta
# 32. Sin caracteres de control en ninguno de los dos.
const WPA_MIN = 8
const WPA_MAX = 63
const SSID_MAX = 32

const CONNECTIVITY = ["full", "limited", "portal", "none"]


# --- validación --------------------------------------------------------------

static func _has_control(s):
	return s.find("\n") >= 0 or s.find("\r") >= 0 or s.find("\t") >= 0 or s.find("\u0000") >= 0


# Clave WPA-PSK válida: 8..63 caracteres, sin controles. No se restringe el
# alfabeto: nmcli recibe la clave por archivo, no por shell.
static func valid_psk(psk):
	var s = String(psk)
	if s.length() < WPA_MIN or s.length() > WPA_MAX:
		return false
	return not _has_control(s)


# SSID válido: 1..32 caracteres imprimibles (sin controles). Sin restricción de
# caracteres más allá de los de control: va por argv, no por shell.
static func valid_ssid(ssid):
	var s = String(ssid)
	if s == "" or s.length() > SSID_MAX:
		return false
	return not _has_control(s)


# --- planes argv (sin secretos) ----------------------------------------------

# Alta del perfil AP (idempotente: sólo se corre si el perfil no existe). Queda
# con key-mgmt wpa-psk sin clave: la clave entra al activar con passwd-file. Sin
# `iface` NM elige la radio Wi-Fi (bastion wlan0, cupid mlan0).
static func create_plan(ssid, iface = ""):
	var s = String(ssid).strip_edges()
	if not valid_ssid(s):
		return []
	var args = ["connection", "add", "type", "wifi"]
	var ifc = String(iface).strip_edges()
	if ifc != "":
		args.append_array(["ifname", ifc])
	args.append_array(["con-name", PROFILE, "autoconnect", "no", "ssid", s, "mode", "ap",
		"802-11-wireless-security.key-mgmt", "wpa-psk", "ipv4.method", "shared"])
	return args


# Alta del perfil de estación para una red protegida: la clave entra recién al
# activar con `passwd-file` (nunca por argv). `con-name` = SSID para que el worker
# lo reconozca en `saved` y no vuelva a pedir la clave. Sin `iface` NM elige radio.
static func connect_plan(ssid, iface = ""):
	var s = String(ssid).strip_edges()
	if not valid_ssid(s):
		return []
	var args = ["connection", "add", "type", "wifi"]
	var ifc = String(iface).strip_edges()
	if ifc != "":
		args.append_array(["ifname", ifc])
	args.append_array(["con-name", s, "ssid", s,
		"802-11-wireless-security.key-mgmt", "wpa-psk"])
	return args


static func up_plan(profile = PROFILE):
	return ["connection", "up", "id", String(profile)]


static func down_plan(profile = PROFILE):
	return ["connection", "down", "id", String(profile)]


# Asegura que el perfil pida WPA-PSK (hoy en bastion el perfil existe abierto).
static func ensure_wpa_plan(profile = PROFILE):
	return ["connection", "modify", String(profile),
		"802-11-wireless-security.key-mgmt", "wpa-psk"]


# Fija el canal del AP. `channel` sólo no basta: nmcli exige `band` junto al canal
# (802-11-wireless.band bg|a). Sólo con canal > 0; el llamador lo omite si no hay STA.
static func channel_plan(profile = PROFILE, chan = 0, band = "bg"):
	var c = int(chan)
	if c <= 0:
		return []
	return ["connection", "modify", String(profile),
		"802-11-wireless.band", String(band), "802-11-wireless.channel", str(c)]


# Banda de nmcli ("bg" 2.4 GHz, "a" 5 GHz) a partir de la banda del nodo Wi-Fi
# ("2.4"/"5") que publica el worker. "" si no se reconoce.
static func band_arg(band):
	match String(band):
		"2.4":
			return "bg"
		"5":
			return "a"
	return ""


# Contenido del archivo de claves para `nmcli ... passwd-file <archivo>`: una
# línea por secreto con el formato documentado `setting.propiedad:clave`. La
# clave puede contener `:` (se corta en el primero) y espacios.
static func passwd_file_text(psk):
	if not valid_psk(psk):
		return ""
	return "802-11-wireless-security.psk:" + String(psk) + "\n"


# --- parseo de estado (puro) -------------------------------------------------

# Separa una línea -t por `:` respetando `\:` y `\\` (misma regla que
# neighborhood.gd, copiada para no crear un ciclo de preload).
static func _split_escaped(line):
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


# ¿Está activo el perfil de la señal? Sobre
# `nmcli -t -f NAME,DEVICE,TYPE connection show --active`.
# Devuelve {active: bool, device: str, profile: str}.
static func parse_active(text, profile = PROFILE):
	var res = {"active": false, "device": "", "profile": String(profile)}
	for raw in String(text).split("\n", false):
		var l = String(raw).strip_edges()
		if l == "":
			continue
		var f = _split_escaped(l)
		if f.size() < 2:
			continue
		if f[0] == String(profile):
			res.active = true
			res.device = f[1]
			break
	return res


# Nombres de perfiles guardados (`nmcli -t -f NAME connection show`). El nombre
# de un perfil normal coincide con el SSID; se usa para no pedir la clave cuando
# NM ya la tiene en su store.
static func parse_saved(text):
	var out = []
	for raw in String(text).split("\n", false):
		var l = String(raw).strip_edges()
		if l == "":
			continue
		var f = _split_escaped(l)
		var name = f[0] if not f.empty() else ""
		if name != "" and not out.has(name):
			out.append(name)
	return out


# Conectividad de NM (`nmcli -t -f CONNECTIVITY general`). Tolera la forma bare
# (`full`) y la `CLAVE:valor`; `""`/`unknown` => "sin_dato".
static func parse_connectivity(text):
	for raw in String(text).split("\n", false):
		var l = String(raw).strip_edges()
		if l == "":
			continue
		var v = l
		var c = l.find(":")
		if c >= 0:
			v = l.substr(c + 1).strip_edges()
		v = v.to_lower()
		if CONNECTIVITY.has(v):
			return v
		return "sin_dato"
	return "sin_dato"


# Traducción humana de la conectividad: ¿hay Internet? "limited"/"portal" son
# cautivo (hay enlace, no Internet confiable).
static func internet_state(connectivity):
	match String(connectivity):
		"full":
			return "sí"
		"limited", "portal":
			return "limitada"
		"none":
			return "no"
	return "sin dato"


# ¿El perfil de la señal está activo entre las conexiones activas?
static func is_share_active(text, profile = PROFILE):
	return bool(parse_active(text, profile).active)


# --- autoprueba --------------------------------------------------------------

static func selftest():
	# Planes argv: sin secretos, con el SSID en su lugar.
	var add = create_plan("bastion")
	assert(add.size() > 0 and add.find("Hotspot") >= 0 and add.find("bastion") >= 0,
		"create_plan con perfil y ssid")
	assert(add.find("802-11-wireless-security.psk") < 0, "create_plan sin secreto")
	var con = connect_plan("Casa")
	assert(con.size() > 0 and con.find("con-name") >= 0 and con[con.find("con-name") + 1] == "Casa"
		and con.find("ssid") >= 0 and con[con.find("ssid") + 1] == "Casa"
		and con.find("802-11-wireless-security.key-mgmt") >= 0
		and con.find("802-11-wireless-security.psk") < 0, "connect_plan de estación")
	assert(connect_plan("x".repeat(33)).empty(), "connect_plan rechaza ssid inválido")
	assert(up_plan() == ["connection", "up", "id", "Hotspot"], "up_plan")
	assert(down_plan("X") == ["connection", "down", "id", "X"], "down_plan")
	assert(ensure_wpa_plan() == ["connection", "modify", "Hotspot",
		"802-11-wireless-security.key-mgmt", "wpa-psk"], "ensure_wpa_plan")
	assert(channel_plan("Hotspot", 5) == ["connection", "modify", "Hotspot",
		"802-11-wireless.band", "bg", "802-11-wireless.channel", "5"], "channel_plan")
	assert(channel_plan("Hotspot", 0).empty(), "channel_plan sin canal")
	assert(band_arg("2.4") == "bg" and band_arg("5") == "a" and band_arg("x") == "",
		"band_arg")

	# Validación de clave y SSID.
	assert(not valid_psk("1234567"), "psk corta rechazada")
	assert(valid_psk("12345678"), "psk mínima aceptada")
	assert(valid_psk("x".repeat(63)), "psk máxima aceptada")
	assert(not valid_psk("x".repeat(64)), "psk larga rechazada")
	assert(not valid_psk("clave\ncon salto"), "psk con control rechazada")
	assert(not valid_ssid(""), "ssid vacío rechazado")
	assert(valid_ssid("bastion"), "ssid válido")
	assert(not valid_ssid("x".repeat(33)), "ssid largo rechazado")
	assert(not valid_ssid("a\tb"), "ssid con control rechazado")

	# Archivo de claves con el formato documentado.
	assert(passwd_file_text("secret123") == "802-11-wireless-security.psk:secret123\n",
		"passwd_file_text")
	assert(passwd_file_text("corta") == "", "passwd_file_text rechaza psk inválida")

	# Parseo de activas (nombre con `:` escapado y perfil ausente).
	var act = parse_active("Alvitos_Govista:wlan0:802-11-wireless\nlo:lo:loopback")
	assert(not act.active, "perfil señal no activo")
	var act2 = parse_active("Alvitos_Govista:wlan0:802-11-wireless\nHotspot:wlan0:802-11-wireless")
	assert(act2.active and act2.device == "wlan0", "perfil señal activo con device")
	assert(parse_active("Mi\\:Red:wlan0:802-11-wireless", "Mi:Red").active,
		"nombre de perfil con `:` escapado")

	# Perfiles guardados (un nombre por línea).
	var saved = parse_saved("Hotspot\nAlvitos_Govista\nRede\\:X")
	assert(saved.has("Hotspot") and saved.has("Rede:X"), "parse_saved")

	# Conectividad en forma bare, clave:valor y desconocida.
	assert(parse_connectivity("full") == "full", "connectivity bare")
	assert(parse_connectivity("CONNECTIVITY:limited") == "limited", "connectivity clave:valor")
	assert(parse_connectivity("") == "sin_dato", "connectivity vacía")
	assert(parse_connectivity("unknown") == "sin_dato", "connectivity desconocida")

	# Traducción honesta de Internet.
	assert(internet_state("full") == "sí", "internet full")
	assert(internet_state("limited") == "limitada", "internet limited")
	assert(internet_state("none") == "no", "internet none")
	assert(internet_state("sin_dato") == "sin dato", "internet sin dato")
	return true


func run_selftest():
	return selftest()
