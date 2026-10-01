extends Reference

# Helper PURO de despacho de acciones del Vecindario. Sin I/O: sólo clasifica
# planes y deriva argv. Extraído de shell.gd para poder testearse headless sin
# cargar el shell completo (cuyos autoloads no compilan sin ventana).

# Clasifica un plan puro (`neighborhood_actions.gd`) en mecanismo de ejecución y su
# argv. Puro y testeable (sin I/O). Reglas:
#   kind "service_toggle"            -> "deskflow"
#   kind "deskflow_clipboard"        -> "clipboard"
#   kind "process" + id use_as_screen-> "gvd_recv"; share_my_screen -> "gvd_send";
#                                       sin id, se infiere del argv (recv/send)
# Devuelve {"mechanism": "...", "argv": [cmd, ...]} o "none" si el plan no es válido.
static func dispatch_of(plan, action_id = ""):
	var out = {"mechanism": "none", "argv": []}
	if typeof(plan) != TYPE_DICTIONARY or not bool(plan.get("ok", false)):
		return out
	var aid = String(action_id)
	var kind = String(plan.get("kind", ""))
	if kind == "deskflow_clipboard" or aid == "share_clipboard":
		out.mechanism = "clipboard"
		return out
	if kind == "service_toggle":
		out.mechanism = "deskflow"
		out.argv = _plan_argv(plan)
		return out
	if kind == "process":
		var args = plan.get("args", [])
		if aid == "use_as_screen":
			out.mechanism = "gvd_recv"
		elif aid == "share_my_screen":
			out.mechanism = "gvd_send"
		elif typeof(args) == TYPE_ARRAY and args.has("recv"):
			out.mechanism = "gvd_recv"
		else:
			out.mechanism = "gvd_send"
		out.argv = _plan_argv(plan)
		return out
	return out


# argv ejecutable de un plan: [cmd] + args (para gvd send/recv). Sin I/O.
static func _plan_argv(plan):
	var out = []
	var cmd = String(plan.get("cmd", "")).strip_edges()
	if cmd != "":
		out.append(cmd)
	var args = plan.get("args", [])
	if typeof(args) == TYPE_ARRAY:
		for a in args:
			out.append(String(a))
	return out


# Deskflow: el `mode` del plan decide el camino. "client" reusa la actividad
# "Deskflow"; "server" lanza el argv del propio plan. Sin I/O.
static func deskflow_dispatch_mode(plan):
	if typeof(plan) != TYPE_DICTIONARY:
		return ""
	var mode = String(plan.get("mode", "")).strip_edges()
	if mode == "server":
		return "server"
	if mode == "client":
		return "client"
	return ""


# Clave de sesión rastreada por host/mecanismo; distinta de la clave gvd (host_id).
static func deskflow_session_key(host_id):
	return "deskflow:" + String(host_id)


# argv real para OS.execute del servidor Deskflow: descarta el nombre del programa
# duplicado al inicio de `plan.args` (los planes lo repiten como argv[0] descriptivo)
# y devuelve {"cmd": String, "args": Array}. Sin I/O.
static func deskflow_server_argv(plan):
	var out = {"cmd": "", "args": []}
	if typeof(plan) != TYPE_DICTIONARY:
		return out
	var cmd = String(plan.get("cmd", "")).strip_edges()
	var args = plan.get("args", [])
	var clean = []
	if typeof(args) == TYPE_ARRAY:
		for a in args:
			clean.append(String(a))
	if clean.size() > 0 and clean[0] == cmd:
		clean.remove(0)
	out.cmd = cmd
	out.args = clean
	return out
