extends Reference

# Acciones de host del Vecindario (SPEC-sugar-neighborhood-host-actions, Kilo D y E).
# Dado un host del modelo puro (shell/neighborhood_hosts.gd) y el contexto local,
# decide qué acciones se ofrecen y construye los comandos de gvd y la descripción de
# Deskflow. Es puro: no ejecuta procesos, no toca el filesystem y no guarda estado;
# lo que depende del equipo (ruta de gvd, config de Deskflow) lo resuelve el caller
# y lo pasa en `local`.
#
# Forma de `local` (todas las claves opcionales):
#   gvd_path:          ruta ya resuelta de gvd.py, o binario `gvd` del PATH futuro
#   gvd_sender:        true si este equipo puede emitir pantalla (GNOME/Mutter)
#   provision_channel: true si hay canal autorizado para abrir el receptor remoto
#                      (ssh o control remoto gdtk); sin él, state=capable no habilita
#   deskflow_server:   true si este equipo publica servidor Deskflow local
#   deskflow_config:   ruta de config cliente/servidor Deskflow; si falta y hay
#                      `home`, se propone ~/gdtk/deskflow-<modo>.conf
#   home:              HOME para resolver las rutas por defecto
#
# Direccion (SPEC-screen-share-compass.md §3, §4, §6; tarea "Kilo C"), todas
# opcionales:
#   direction:         "north"|"south"|"east"|"west"|"none"|"" — direccion de ESTE
#                      host hacia el peer, tal como la ve este equipo. Con una
#                      direccion valida != "none", las acciones de pantalla pasan
#                      `--position` (north->above, south->below, east->right,
#                      west->left) via `neighborhood_directions.to_gvd_position`.
#   direction_confirm: "unconfirmed"|"proposed"|"confirmed"|"" — confirmacion del
#                      vinculo por canal autorizado. Sin confirmar NO bloquea la
#                      pantalla (aviso de UI) pero SI bloquea los links Deskflow
#                      locales (`serve_input_here`).
#   direction_conflict:true si dos hosts reclaman el mismo borde: deshabilita
#                      pantalla y `serve_input_here` con state "conflicto".
#   local_name:        nombre local para el layout Deskflow (default "gdtk-local").
#
# Integración con el shell (sólo documentación: este módulo no ejecuta nada):
#   - Deskflow: reusar `_toggle_service()`, `_service_running()` y `service_pids` de
#     shell/shell.gd con la actividad "Deskflow" existente; los planes con kind
#     "service_toggle" y campo "activity": "Deskflow" describen argv y config destino.
#     No crear un segundo ciclo de vida. Si hay que cambiar el config, generar el
#     archivo de forma explícita y reversible antes del toggle.
#   - gvd recv local: reusar la actividad "Pantalla" del shell (ya lanza
#     `python3 $HOME/gvd/gvd.py recv --sink wayland`); al integrar, resolver la ruta
#     real con resolve_gvd_path() (~/Proyectos/gvd en desarrollo, ~/gvd o PATH después).
#   - Portapapeles: ya NO es una opción de menú (SPEC-ui-rework decisión
#     2026-10-01). Con "Controlar" se asume compartido (clipboardSharing=true en
#     los ajustes/layout generados); con "Extender" se asume compartido por el
#     puente de una fase posterior. Este módulo no ofrece ninguna acción de
#     portapapeles.
#   - Estados pendiente/activo/falló y la sospecha por hid con otro nombre/dirección
#     son de la UI/sesión: este módulo sólo dice "disponible" o "no confiable".

const DEFAULT_GVD_PORT = 5600
const DEFAULT_DESKFLOW_PORT = 24800
# Modelo puro de la brujula (direccion N/S/E/O), generador puro de links Deskflow
# (compas) y los dos formatos reales de Deskflow: layout barrier y ajustes QSettings.
const DIRECTIONS = preload("res://neighborhood_directions.gd")
const DESKFLOW_LAYOUT = preload("res://deskflow_layout.gd")
const DESKFLOW_CONF = preload("res://deskflow_conf.gd")
const DESKFLOW_SETTINGS = preload("res://deskflow_settings.gd")
const POSITIONS = ["right", "left", "above", "below"]
const SINKS = ["wayland", "x11"]
const DESKFLOW_MODES = ["client", "server"]
# Caracteres seguros para nombres de host y para átomos de ruta/binary sin shell.
const _SAFE_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
# Subconjunto que no necesita comillas al mostrar un comando.
const _CMD_SAFE = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/="


# Candidatos de gvd en orden: desarrollo, instalación futura, binario en PATH.
static func gvd_path_candidates(home = ""):
	var h = String(home).strip_edges()
	var out = []
	if h != "":
		out.append(h.plus_file("gdtk/tools/gvd").plus_file("gvd.py"))
		out.append(h.plus_file("Proyectos/gvd").plus_file("gvd.py"))
		out.append(h.plus_file("gvd").plus_file("gvd.py"))
	out.append("gvd")
	return out


# Elige el primer candidato válido. `exists` (opcional) verifica existencia:
# Dictionary (el path es clave) o FuncRef(path -> bool). Con null devuelve el
# primero válido (el caller ya confía en su lista).
static func resolve_gvd_path(candidates, exists = null):
	for p in candidates:
		var v = String(p)
		if not valid_local_path(v):
			continue
		if exists == null:
			return v
		var t = typeof(exists)
		if t == TYPE_DICTIONARY and exists.has(v):
			return v
		elif t == TYPE_OBJECT and exists is FuncRef and exists.call_func(v):
			return v
	return ""


# Ruta utilizable en argv sin shell: absoluta sin ".." y sin "~" (debe venir
# expandida), o nombre desnudo que el PATH resuelve (p. ej. `gvd`).
static func valid_local_path(path):
	var v = String(path).strip_edges()
	if v == "" or v.find("~") >= 0 or _has_control(v):
		return false
	if v.begins_with("/"):
		for seg in v.split("/", false):
			if seg == "..":
				return false
		return true
	return v.find("/") < 0 and _only_chars(v, _SAFE_CHARS)


# Host destino seguro para argv: hostname/IPv4/mDNS. Sin ":" (IPv6 requiere
# corchetes y gvd no lo declara), sin espacios ni metacaracteres.
static func valid_host(h):
	var v = String(h).strip_edges()
	if v == "" or v.length() > 253 or not _only_chars(v, _SAFE_CHARS):
		return false
	if v.begins_with(".") or v.begins_with("-") or v.ends_with(".") or v.ends_with("-"):
		return false
	return true


# Plan de envío: `python3 <gvd.py> send --host <host> [--port N] [--position X]`.
# El puerto va sólo si difiere del default (5600); la posición, sólo si es válida.
static func gvd_send_plan(gvd_path, target_host, port = 0, opts = {}):
	var p = String(gvd_path).strip_edges()
	if not valid_local_path(p):
		return _bad("ruta gvd inválida: " + p)
	var host = String(target_host).strip_edges()
	if not valid_host(host):
		return _bad("host inválido: " + host)
	var n = int(port)
	if n < 0 or n > 65535:
		return _bad("puerto inválido: " + str(port))
	var cmd = p
	var args = []
	if p.ends_with(".py"):
		cmd = "python3"
		args.append(p)
	args.append_array(["send", "--host", host])
	if n > 0 and n != DEFAULT_GVD_PORT:
		args.append_array(["--port", str(n)])
	var pos = String(opts.get("position", "")).strip_edges()
	if pos != "":
		if not POSITIONS.has(pos):
			return _bad("posición inválida: " + pos)
		args.append_array(["--position", pos])
	return {"ok": true, "kind": "process", "cmd": cmd, "args": args, "error": ""}


# Plan del receptor local: `python3 <gvd.py> recv --sink <sink>` (puerto `port`
# sólo si difiere del default 5600; así el receptor escucha donde el emisor envía).
static func gvd_recv_plan(gvd_path, opts = {}):
	var p = String(gvd_path).strip_edges()
	if not valid_local_path(p):
		return _bad("ruta gvd inválida: " + p)
	var sink = String(opts.get("sink", "wayland")).strip_edges()
	if not SINKS.has(sink):
		return _bad("sink inválido: " + sink)
	var n = int(opts.get("port", 0))
	if n < 0 or n > 65535:
		return _bad("puerto inválido: " + str(opts.get("port", "")))
	var cmd = p
	var args = []
	if p.ends_with(".py"):
		cmd = "python3"
		args.append(p)
	args.append_array(["recv", "--sink", sink])
	if n > 0 and n != DEFAULT_GVD_PORT:
		args.append_array(["--port", str(n)])
	return {"ok": true, "kind": "process", "cmd": cmd, "args": args, "error": ""}


# Plan de servicio Deskflow para el shell: kind "service_toggle" + actividad
# "Deskflow" (ver el encabezado para la integración con _toggle_service).
static func deskflow_plan(mode, config_path):
	if not DESKFLOW_MODES.has(String(mode)):
		return _bad("modo Deskflow inválido: " + String(mode))
	var cfg = String(config_path).strip_edges()
	if not valid_local_path(cfg):
		return _bad("config Deskflow inválida: " + cfg)
	return {"ok": true, "kind": "service_toggle", "activity": "Deskflow", "mode": String(mode),
		"config": cfg, "cmd": "deskflow-core", "args": ["deskflow-core", String(mode),
		"--new-instance", "-s", cfg], "error": ""}


# Acciones disponibles para un host del modelo (capabilities de neighborhood_hosts).
# Devuelve una lista de {id, label, enabled, state, reason, plan}.
# Acciones: use_as_screen ("Ver su escritorio aquí"), share_my_screen ("Extender mi
# escritorio a él"), use_remote_input ("Usar su teclado y mouse aquí") y
# serve_input_here ("Controlarlo con mi teclado y mouse"). "Ver pantalla" (role=send)
# queda reservado: sin invitación no se ofrece, ni aunque el peer lo anuncie.
static func host_actions(host, local = {}):
	var out = []
	if typeof(host) != TYPE_DICTIONARY:
		return out
	var caps = host.get("capabilities", {})
	if typeof(caps) != TYPE_DICTIONARY:
		return out
	var gvd = caps.get("gvd", null)
	if gvd != null and typeof(gvd) == TYPE_DICTIONARY and _txt(gvd, "role") == "recv":
		out.append(_screen_action(gvd, local, "use_as_screen", "Ver su escritorio aquí"))
		if bool(local.get("gvd_sender", false)):
			out.append(_screen_action(gvd, local, "share_my_screen", "Extender mi escritorio a él"))
	var df = caps.get("deskflow", null)
	if df != null and typeof(df) == TYPE_DICTIONARY:
		out.append_array(_deskflow_actions(df, local, host))
	# Host degradado (sin hid): nada se conecta solo y todo pasa a no confiable.
	if bool(host.get("degraded", false)):
		for a in out:
			a.enabled = false
			a.state = "no confiable"
			if a.reason == "":
				a.reason = "host degradado: sin hid confirmado"
	return out


static func _screen_action(gvd, local, id, label):
	# Direccion de este host hacia el peer: con cardinal valida se ancla el monitor
	# virtual con `--position`; sin direccion (o "none") no se pasa posicion.
	var direction = String(local.get("direction", "")).strip_edges()
	var position = ""
	if DIRECTIONS.valid_direction(direction) and direction != "none":
		position = DIRECTIONS.to_gvd_position(direction)
	var conflict = bool(local.get("direction_conflict", false))
	var gpath = String(local.get("gvd_path", "")).strip_edges()
	var enabled = valid_local_path(gpath)
	var reason = "" if enabled else "gvd no disponible en este equipo"
	var plan = null
	if enabled:
		var opts = {}
		if position != "":
			opts["position"] = position
		plan = gvd_send_plan(gpath, _peer_target(gvd), int(gvd.get("port", 0)), opts)
		if not plan.ok:
			enabled = false
			reason = plan.error
			plan = null
	# state=capable: el peer tiene que abrir su receptor por un canal ya autorizado
	# (ssh o control remoto gdtk); sin canal, la acción se muestra deshabilitada.
	if enabled and _txt(gvd, "state", "ready") == "capable" \
			and not bool(local.get("provision_channel", false)):
		enabled = false
		reason = "state=capable: hay que abrir el receptor del peer por un canal autorizado"
	# Conflicto de borde: dos hosts en la misma arista. No se ofrece la accion ni
	# su plan hasta resolver; la direccion sin confirmar NO bloquea la pantalla.
	if conflict:
		return {"id": id, "label": label, "enabled": false, "state": "conflicto",
			"reason": "conflicto de borde: dos hosts reclaman la misma dirección", "plan": null}
	return {"id": id, "label": label, "enabled": enabled, "state": "disponible",
		"reason": reason, "plan": plan}


static func _deskflow_actions(df, local, host):
	var out = []
	var role = _txt(df, "role")
	var explicit_cfg = String(local.get("deskflow_config", "")).strip_edges()
	if role == "server":
		# El peer es el servidor: el layout lo manda el remoto, por lo que el cliente
		# local (`use_remote_input`) no depende de la direccion ni de su confirmacion;
		# el compas local es solo pista visual y propuesta. Sí necesita la dirección
		# del servidor descubierto para el ajuste `remoteHost`.
		var cfg = explicit_cfg if explicit_cfg != "" else _default_config(local.get("home", ""), "client")
		out.append(_remote_input_action(cfg, df, local))
	elif role == "client":
		# Este equipo es el servidor Deskflow: los links SI dependen de la direccion.
		# Requiere direccion CONFIRMADA y sin conflicto; sin confirmar no se genera
		# config (pista/propuesta), y un conflicto de borde no genera layout.
		var srv = bool(local.get("deskflow_server", false))
		var conflict = bool(local.get("direction_conflict", false))
		var direction = String(local.get("direction", "")).strip_edges()
		var confirm = String(local.get("direction_confirm", "")).strip_edges()
		var has_dir = DIRECTIONS.valid_direction(direction) and direction != "none"
		var scfg = explicit_cfg if explicit_cfg != "" else _default_server_settings(local.get("home", ""))
		var enabled = srv
		var state = "disponible"
		var reason = ""
		var plan = null
		if conflict:
			enabled = false
			state = "conflicto"
			reason = "conflicto de borde: dos hosts reclaman la misma dirección"
		elif not srv:
			enabled = false
			reason = "gdtk no publica servidor Deskflow local"
		elif not has_dir or confirm != "confirmed":
			enabled = false
			reason = "dirección sin confirmar: no se generan links"
		else:
			plan = deskflow_plan("server", scfg)
			if not plan.ok:
				enabled = false
				reason = plan.error
				plan = null
			else:
				# Layout barrier real (deskflow_conf.build_server_conf), no el v1 del
				# compas: deskflow_layout.gd queda sólo para el compás visual.
				var local_name = _safe_local_name(local)
				var peer_name = _safe_peer_name(host)
				var layout_text = DESKFLOW_CONF.build_server_conf(local_name,
					[{"direction": direction, "peer": peer_name}])
				var layout_path = _layout_config_path(local)
				if layout_text == "":
					enabled = false
					reason = "layout: no se pudo generar deskflow-server.conf"
					plan = null
				elif layout_path == "" or not valid_local_path(layout_path):
					enabled = false
					reason = "ruta de layout Deskflow inválida"
					plan = null
				else:
					var settings_text = DESKFLOW_SETTINGS.build_server_settings(local_name,
						layout_path, _announced_port(df))
					if settings_text == "":
						enabled = false
						reason = "ajustes Deskflow inválidos"
						plan = null
					else:
						plan["settings_text"] = settings_text
						plan["layout_path"] = layout_path
						plan["layout_text"] = layout_text
		out.append({"id": "serve_input_here", "label": "Controlarlo con mi teclado y mouse",
			"enabled": enabled, "state": state, "reason": reason, "plan": plan})
	# El portapapeles ya no es una opción: con "Controlar" (o "Extender") se asume
	# compartido y va en los ajustes/layout generados (clipboardSharing=true).
	return out


# Acción cliente (peer role=server): genera el ini de CLIENTE con `remoteHost` =
# dirección del servidor descubierto y puerto anunciado, y lo adjunta al plan
# (`settings_text`) para que el shell lo escriba antes del toggle. Sin dirección
# válida queda deshabilitada con razón explícita.
static func _remote_input_action(cfg, df, local):
	var base = {"id": "use_remote_input", "label": "Usar su teclado y mouse aquí",
		"enabled": false, "state": "disponible", "reason": "", "plan": null}
	var addr = _peer_target(df)
	if addr == "":
		base.reason = "sin dirección del servidor"
		return base
	if cfg == "":
		base.reason = "config Deskflow inválida"
		return base
	var text = DESKFLOW_SETTINGS.build_client_settings(_safe_local_name(local), addr,
		_announced_port(df))
	if text == "":
		base.reason = "ajustes Deskflow inválidos"
		return base
	var plan = deskflow_plan("client", cfg)
	if not plan.ok:
		base.reason = plan.error
		return base
	plan["settings_text"] = text
	base.enabled = true
	base.plan = plan
	return base


# Nombre seguro del peer para el layout Deskflow: label del host (o id) filtrado a
# caracteres permitidos, sin espacios/saltos, y sin '.'/'-' en los extremos; si
# queda vacio o no es valido, se usa "peer". Determinista y sin secretos.
static func _safe_peer_name(host):
	var raw = ""
	if typeof(host) == TYPE_DICTIONARY:
		raw = String(host.get("label", host.get("id", "")))
	var cleaned = ""
	for i in range(raw.length()):
		var ch = raw.substr(i, 1)
		if _SAFE_CHARS.find(ch) >= 0:
			cleaned += ch
	cleaned = cleaned.strip_edges().lstrip(".-").rstrip(".-")
	if cleaned == "" or not DESKFLOW_LAYOUT.valid_peer(cleaned):
		return "peer"
	return cleaned


# Nombre local seguro para la config de Deskflow (computerName/screenName y la
# pantalla del layout): el solicitado en `local` o "gdtk-local".
static func _safe_local_name(local):
	var name = String(local.get("local_name", "gdtk-local")).strip_edges()
	if not DESKFLOW_LAYOUT.valid_peer(name):
		name = "gdtk-local"
	return name


# Ruta del layout barrier del servidor: `local.layout_config` explícito, o
# $XDG_CONFIG_HOME/Deskflow/deskflow-server.conf, o ~/.config/Deskflow/... .
static func _layout_config_path(local):
	var explicit = String(local.get("layout_config", "")).strip_edges()
	if explicit != "":
		return explicit
	var xdg = String(local.get("xdg_config_home", "")).strip_edges()
	if xdg != "":
		return xdg.plus_file("Deskflow").plus_file("deskflow-server.conf")
	var home = String(local.get("home", "")).strip_edges()
	if home != "":
		return home.plus_file(".config").plus_file("Deskflow").plus_file("deskflow-server.conf")
	return ""


# Puerto anunciado por el peer Deskflow, o el default 24800 si falta/ inválido.
static func _announced_port(df):
	var p = int(df.get("port", 0))
	if p < 1 or p > 65535:
		return DEFAULT_DESKFLOW_PORT
	return p


static func _default_config(home, mode):
	var h = String(home).strip_edges()
	if h == "":
		return ""
	return h.plus_file("gdtk").plus_file("deskflow-" + mode + ".conf")


# Ajustes de servidor por defecto: <home>/gdtk/deskflow-server-settings.ini.
static func _default_server_settings(home):
	var h = String(home).strip_edges()
	if h == "":
		return ""
	return h.plus_file("gdtk").plus_file("deskflow-server-settings.ini")


# Dirección del peer para argv: address (SRV/A) si es válida, si no el host mDNS.
static func _peer_target(svc):
	var addr = String(svc.get("address", "")).strip_edges()
	if valid_host(addr):
		return addr
	var host = String(svc.get("host", "")).strip_edges()
	if valid_host(host):
		return host
	return ""


# Representación del plan lista para mostrar/log (cita los argumentos que hacen
# falta). Los planes corren por argv (sin shell), así que esto es sólo descriptivo.
static func format_command(plan):
	if typeof(plan) != TYPE_DICTIONARY or not bool(plan.get("ok", false)):
		return ""
	var parts = PoolStringArray([_quote(String(plan.get("cmd", "")))])
	for a in plan.get("args", []):
		parts.append(_quote(String(a)))
	return parts.join(" ")


static func _quote(s):
	if s == "":
		return "''"
	if _only_chars(s, _CMD_SAFE):
		return s
	return "'" + s.replace("'", "'\\''") + "'"


static func _bad(error):
	return {"ok": false, "kind": "", "cmd": "", "args": [], "error": error}


static func _txt(svc, key, default = ""):
	var txt = svc.get("txt", {})
	if typeof(txt) != TYPE_DICTIONARY:
		return str(default)
	var v = str(txt.get(key, "")).strip_edges()
	return v if v != "" else str(default)


static func _only_chars(s, allowed):
	for i in range(s.length()):
		if allowed.find(s.substr(i, 1)) < 0:
			return false
	return true


static func _has_control(s):
	return s.find("\n") >= 0 or s.find("\r") >= 0 or s.find("\t") >= 0 or s.find("\u0000") >= 0


static func _by_id(acts):
	var out = {}
	for a in acts:
		out[a.id] = a
	return out


static func selftest():
	var gvd = {"txt": {"role": "recv", "state": "ready"}, "address": "192.168.1.20",
		"host": "tengu.local", "port": 5600}
	var df = {"txt": {"role": "server"}, "address": "192.168.1.20", "port": 24800}
	var host = {"id": "h1", "hid": "h1", "degraded": false, "capabilities": {"gvd": gvd, "deskflow": df}}
	var local = {"gvd_path": "/home/u/Proyectos/gvd/gvd.py", "home": "/home/u"}
	var by = _by_id(host_actions(host, local))
	assert(by.has("use_as_screen") and by.has("use_remote_input") and not by.has("share_clipboard"),
		"dos acciones por dos capacidades (sin portapapeles)")
	var scr = by["use_as_screen"]
	assert(scr.enabled and scr.plan.ok, "pantalla disponible")
	assert(scr.label == "Ver su escritorio aquí", "verbo Ver su escritorio aquí")
	assert(by["use_remote_input"].label == "Usar su teclado y mouse aquí",
		"verbo Usar su teclado y mouse aquí")
	assert(scr.plan.cmd == "python3" and scr.plan.args[1] == "send", "argv de gvd send")
	assert(scr.plan.args[3] == "192.168.1.20", "host seguro en argv")
	assert(scr.plan.args.find("--port") < 0, "puerto default no va en argv")
	assert(by["use_remote_input"].plan.args[1] == "client", "deskflow cliente")
	assert(by["use_remote_input"].plan.config == "/home/u/gdtk/deskflow-client.conf",
		"config Deskflow por defecto")
	assert(by["use_remote_input"].plan.settings_text.find("coreMode=1") >= 0
		and by["use_remote_input"].plan.settings_text.find("remoteHost=192.168.1.20") >= 0,
		"ajustes de cliente con remoteHost")
	# Sin dirección del servidor descubierto, la acción cliente se deshabilita.
	var no_addr = _by_id(host_actions({"id": "h1", "capabilities":
		{"deskflow": {"txt": {"role": "server"}, "port": 24800}}}, local))
	assert(not no_addr["use_remote_input"].enabled
		and no_addr["use_remote_input"].reason == "sin dirección del servidor",
		"cliente sin dirección deshabilitado")

	# state=capable sin canal autorizado queda deshabilitada; con canal, habilitada.
	var capable_svc = {"txt": {"role": "recv", "state": "capable"},
		"address": "192.168.1.20", "port": 5600}
	var capable = _by_id(host_actions({"id": "h1", "capabilities": {"gvd": capable_svc}}, local))
	assert(capable["use_as_screen"] != null and not capable["use_as_screen"].enabled
		and capable["use_as_screen"].reason != "", "capable sin canal deshabilitada")
	var with_channel = _by_id(host_actions({"id": "h1", "capabilities": {"gvd": capable_svc}},
		{"gvd_path": local.gvd_path, "provision_channel": true}))
	assert(with_channel["use_as_screen"].enabled, "capable con canal habilitada")

	# role=send no ofrece "Ver pantalla" todavía.
	var sender = _by_id(host_actions({"id": "h1", "capabilities":
		{"gvd": {"txt": {"role": "send"}, "address": "192.168.1.20", "port": 5600}}}, local))
	assert(sender.empty(), "sin Ver pantalla sin role=recv")

	# Host degradado (sin hid): acción presente pero no confiable.
	var degraded = host_actions({"id": "degraded:x", "degraded": true, "capabilities":
		{"gvd": {"txt": {"role": "recv", "state": "ready"}, "address": "10.0.0.9", "port": 5600}}}, local)
	assert(degraded.size() == 1 and not degraded[0].enabled and degraded[0].state == "no confiable",
		"host degradado no confiable")

	# Sin gvd local: la pantalla se deshabilita con razón; Deskflow sigue.
	var sin_gvd = _by_id(host_actions(host, {"home": "/home/u"}))
	assert(not sin_gvd["use_as_screen"].enabled and sin_gvd["use_as_screen"].reason != "",
		"sin gvd local se deshabilita")
	assert(sin_gvd["use_remote_input"].enabled, "deskflow no depende de gvd")

	# Validaciones de host y ruta.
	assert(valid_host("tengu.local") and valid_host("192.168.1.20"), "hosts válidos")
	assert(not valid_host("bad host") and not valid_host("-x") and not valid_host("a;b")
		and not valid_host(""), "hosts inválidos rechazados")
	assert(valid_local_path("/home/u/Proyectos/gvd/gvd.py"), "ruta absoluta válida")
	assert(not valid_local_path("~/gvd/gvd.py"), "tilde sin expandir rechazada")
	assert(not valid_local_path("/a/../b/gvd.py"), "traversal rechazado")
	assert(valid_local_path("gvd"), "binario del PATH válido")

	# Resolución de ruta: instalado en gdtk, desarrollo, ~/gvd, luego PATH.
	var c = gvd_path_candidates("/home/u")
	assert(c.size() == 4 and c[0] == "/home/u/gdtk/tools/gvd/gvd.py"
		and c[1] == "/home/u/Proyectos/gvd/gvd.py"
		and c[2] == "/home/u/gvd/gvd.py" and c[3] == "gvd", "candidatos gvd")
	assert(resolve_gvd_path(c, {c[2]: true}) == c[2], "usa ~/gvd si no hay desarrollo")
	assert(resolve_gvd_path(c, {c[3]: true}) == "gvd", "cae al PATH")
	assert(resolve_gvd_path(c, null) == c[0], "sin exists devuelve el primero")

	# argv: puerto alternativo y posición; rechazos.
	var p = gvd_send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5601, {"position": "right"})
	assert(p.ok and p.args.find("--port") >= 0 and p.args.find("5601") >= 0
		and p.args.find("--position") >= 0 and p.args.find("right") >= 0, "puerto y posición en argv")
	assert(not gvd_send_plan("/home/u/Proyectos/gvd/gvd.py", "bad host", 0).ok, "host con espacio")
	assert(not gvd_send_plan("~/gvd/gvd.py", "tengu.local", 0).ok, "ruta con tilde")
	assert(not gvd_send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 99999).ok, "puerto inválido")
	assert(not gvd_send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 0,
		{"position": "diagonal"}).ok, "posición inválida")
	var r = gvd_recv_plan("/home/u/gvd/gvd.py")
	assert(r.ok and r.cmd == "python3" and r.args[2] == "--sink" and r.args[3] == "wayland",
		"argv de gvd recv")
	assert(not gvd_recv_plan("/home/u/gvd/gvd.py", {"sink": "fbdev"}).ok, "sink inválido")
	var rp2 = gvd_recv_plan("/home/u/gvd/gvd.py", {"port": 5601})
	assert(rp2.ok and rp2.args.find("--port") >= 0 and rp2.args.find("5601") >= 0,
		"puerto del receptor en argv")
	assert(gvd_recv_plan("/home/u/gvd/gvd.py", {"port": 5600}).args.find("--port") < 0,
		"puerto default no va en argv")
	assert(not gvd_recv_plan("/home/u/gvd/gvd.py", {"port": 99999}).ok, "puerto inválido")

	# format_command: cita sólo lo necesario.
	assert(format_command(p) == "python3 /home/u/Proyectos/gvd/gvd.py send --host tengu.local"
		+ " --port 5601 --position right", "formato de comando")
	assert(format_command(deskflow_plan("client", "/home/u/gdtk/deskflow client.conf")).find("'") >= 0,
		"cita config con espacio")
	return true


func run_selftest():
	return selftest()
