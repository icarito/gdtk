extends Reference

# Generador PURO de los archivos de AJUSTES (QSettings ini) que consume
# `deskflow-core <modo> --new-instance -s <cfg>` (deskflow-core 1.26 verificado en
# hardware real). NO es el layout: el layout barrier (section: screens/links/options)
# va aparte en su propio archivo, referenciado por `externalConfigFile` en modo
# servidor.
#
# Puro: no ejecuta Deskflow, no toca el filesystem (ni ~/.config) y no abre red.
# Sólo produce texto determinista a partir de entradas ya validadas.
#
# build_client_settings(local_name, server_addr, port=24800):
#   [core]     coreMode=1, computerName/screenName=<local_name>, port
#   [client]   remoteHost=<server_addr>
#   [security] tlsEnabled=false
#   [gui]      autoHide=true
#
# build_server_settings(local_name, layout_conf_path, port=24800, screens=[]):
#   [core]     coreMode=2, computerName/screenName=<local_name>, port
#   [server]   externalConfig=true, externalConfigFile=<layout_conf_path>
#   [internalConfig] clipboardSharing=true (el portapapeles no es opción: "Controlar"
#              asume compartido; el layout barrier también lo fuerza a true)
#   [security] tlsEnabled=false
#   [computer_<nombre>] name=<nombre> por cada pantalla (local + `screens`)
#
# El bloque `[computer_*]` es lo que Deskflow >= 1.27 usa para resolver las pantallas
# (Settings::knownComputers): 1.27 dejó de leer `section: screens` del config externo.
# 1.26 lo ignora y sigue leyendo screens del externo, así el mismo ini sirve para ambos.
#
# Valida `server_addr` (IPv4/IPv6/hostname: sin espacios, saltos, '=', ';' ni
# metacaracteres de shell) y las rutas con `valid_local_path` de
# neighborhood_actions. Devuelve "" si algo es inválido. Nunca viajan secretos.

const LAYOUT = preload("res://deskflow_layout.gd")

const DEFAULT_PORT = 24800
const CORE_MODE_CLIENT = 1
const CORE_MODE_SERVER = 2
# Bytes seguros para una dirección: hostname/IPv4/IPv6. Sin espacios ni control.
const _ADDR_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-_%[]"


# Dirección de servidor/remoto segura para un ini: IPv4, IPv6 o hostname, sin
# espacios, saltos de línea ni '='. Rechaza vacío y valores fuera de rango.
static func valid_server_addr(addr):
	var v = String(addr)
	if v == "" or v != v.strip_edges() or v.length() > 255:
		return false
	return _only_chars(v, _ADDR_CHARS)


# Puerto TCP válido (1..65535).
static func valid_port(port):
	var p = int(port)
	return p >= 1 and p <= 65535


# Ruta local usable en argv/ini: reusa la validación única de neighborhood_actions
# (absoluta sin ".."/"~", o nombre desnudo del PATH).
static func valid_local_path(path):
	var script = load("res://neighborhood_actions.gd")
	return script != null and script.valid_local_path(path)


static func _setting(key, value):
	return String(key) + "=" + String(value)


# ini de CLIENTE. "" si local_name/addr/puerto son inválidos.
static func build_client_settings(local_name, server_addr, port = DEFAULT_PORT):
	var name = String(local_name).strip_edges()
	if not LAYOUT.valid_peer(name):
		return ""
	var addr = String(server_addr)
	if not valid_server_addr(addr):
		return ""
	if not valid_port(port):
		return ""
	var lines = PoolStringArray()
	lines.append("[core]")
	lines.append(_setting("coreMode", CORE_MODE_CLIENT))
	lines.append(_setting("computerName", name))
	lines.append(_setting("screenName", name))
	lines.append(_setting("port", int(port)))
	lines.append("")
	lines.append("[client]")
	lines.append(_setting("remoteHost", addr))
	lines.append("")
	lines.append("[security]")
	lines.append(_setting("tlsEnabled", "false"))
	lines.append("")
	lines.append("[gui]")
	lines.append(_setting("autoHide", "true"))
	return lines.join("\n") + "\n"


# ini de SERVIDOR. `layout_conf_path` es el archivo barrier real que Deskflow lee
# por `externalConfigFile`; "" si el nombre, la ruta o el puerto son inválidos.
static func build_server_settings(local_name, layout_conf_path, port = DEFAULT_PORT, screens = []):
	var name = String(local_name).strip_edges()
	if not LAYOUT.valid_peer(name):
		return ""
	var path = String(layout_conf_path).strip_edges()
	if not valid_local_path(path):
		return ""
	if not valid_port(port):
		return ""
	# Deskflow >= 1.27 dejó de leer `section: screens` del config externo y resuelve las
	# pantallas con `Settings::knownComputers()`, que son los grupos `[computer_<nombre>]`
	# del archivo de settings (NO `[internalConfig] screens`: el core 1.27 crashea con eso).
	# El local va primero; dedupe y validación como los peers.
	var names = [name]
	if typeof(screens) == TYPE_ARRAY:
		for s in screens:
			var sn = String(s).strip_edges()
			if not LAYOUT.valid_peer(sn):
				return ""
			if not names.has(sn):
				names.append(sn)
	var lines = PoolStringArray()
	lines.append("[core]")
	lines.append(_setting("coreMode", CORE_MODE_SERVER))
	lines.append(_setting("computerName", name))
	lines.append(_setting("screenName", name))
	lines.append(_setting("port", int(port)))
	# Escuchar en IPv4 e IPv6 (dual-stack): el mDNS a veces resuelve `bastion.local` sólo a
	# IPv6 y el cliente quedaba en "Connection refused" contra un servidor sólo IPv4.
	lines.append(_setting("interface", "::"))
	lines.append("")
	lines.append("[server]")
	lines.append(_setting("externalConfig", "true"))
	lines.append(_setting("externalConfigFile", path))
	lines.append("")
	# El portapapeles ya no es una opción de producto: "Controlar" asume
	# compartido. `[internalConfig]` espeja la clave real de Deskflow por si algún
	# día se corre sin external config (con externalConfig=true manda el layout,
	# que también la fuerza a true).
	lines.append("[internalConfig]")
	lines.append(_setting("clipboardSharing", "true"))
	lines.append("")
	lines.append("[security]")
	lines.append(_setting("tlsEnabled", "false"))
	for n in names:
		lines.append("")
		lines.append("[computer_" + String(n) + "]")
		lines.append(_setting("name", String(n)))
	return lines.join("\n") + "\n"


static func _only_chars(s, allowed):
	for i in range(s.length()):
		if allowed.find(s.substr(i, 1)) < 0:
			return false
	return true


static func selftest():
	var client = build_client_settings("gdtk-local", "192.168.1.20", 24800)
	assert(client != "", "cliente no vacio")
	assert(client.find("[core]") >= 0 and client.find("coreMode=1") >= 0, "coreMode cliente")
	assert(client.find("computerName=gdtk-local") >= 0 and client.find("screenName=gdtk-local") >= 0,
		"nombre local")
	assert(client.find("port=24800") >= 0, "puerto")
	assert(client.find("[client]") >= 0 and client.find("remoteHost=192.168.1.20") >= 0, "remoteHost")
	assert(client.find("[security]") >= 0 and client.find("tlsEnabled=false") >= 0, "tls off")
	assert(client.find("[gui]") >= 0 and client.find("autoHide=true") >= 0, "gui autoHide")

	var server = build_server_settings("gdtk-local", "/home/u/.config/Deskflow/deskflow-server.conf", 24800)
	assert(server != "", "servidor no vacio")
	assert(server.find("coreMode=2") >= 0, "coreMode servidor")
	assert(server.find("[server]") >= 0 and server.find("externalConfig=true") >= 0, "externalConfig")
	assert(server.find("externalConfigFile=/home/u/.config/Deskflow/deskflow-server.conf") >= 0,
		"externalConfigFile")
	assert(server.find("[internalConfig]") >= 0 and server.find("clipboardSharing=true") >= 0,
		"portapapeles compartido siempre")
	assert(server.find("[computer_gdtk-local]") >= 0 and server.find("name=gdtk-local") >= 0,
		"servidor declara [computer_] del local (Deskflow >= 1.27)")
	assert(server.find("screens\\") < 0, "servidor no usa screens\\ (crash 1.27)")
	assert(build_server_settings("gdtk-local", "/home/u/.config/Deskflow/deskflow-server.conf", 24800,
		["a", "b"]).find("[computer_a]") >= 0, "servidor declara [computer_] de las pantallas")
	assert(server.find("[gui]") < 0, "servidor sin gui")

	assert(valid_server_addr("192.168.1.20"), "IPv4 valida")
	assert(valid_server_addr("tengu.local"), "hostname valido")
	assert(valid_server_addr("fe80::1"), "IPv6 valida")
	assert(not valid_server_addr(""), "addr vacia")
	assert(not valid_server_addr("bad host"), "addr con espacio")
	assert(not valid_server_addr("a=b"), "addr con igual")
	assert(not valid_server_addr("a\nb"), "addr con salto")
	assert(not valid_server_addr("a;b"), "addr con punto y coma")

	assert(build_client_settings("gdtk-local", "bad host") == "", "cliente rechaza addr invalida")
	assert(build_client_settings("bad host", "192.168.1.20") == "", "cliente rechaza nombre invalido")
	assert(build_client_settings("gdtk-local", "192.168.1.20", 0) == "", "cliente rechaza puerto")
	assert(build_server_settings("gdtk-local", "~/x.conf") == "", "servidor rechaza tilde")
	assert(build_server_settings("gdtk-local", "/a/../b") == "", "servidor rechaza traversal")
	assert(build_client_settings("gdtk-local", "192.168.1.20") == client, "determinista")
	return true


func run_selftest():
	return selftest()
