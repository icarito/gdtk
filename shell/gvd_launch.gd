extends Reference

# K17 (SPEC-ui-rework-2026-10) — planes PUROS de automatización de gvd.
#
# El shell lanza y corta el monitor virtual solo: emisor local si este equipo es
# GNOME/wlroots, receptor remoto por ssh (buzón), receptor local en un tile y
# `--position` según el mapa. Este módulo NO ejecuta nada:
# no toca red, procesos, filesystem ni estado global; sólo decide y describe los
# argv, igual que host_dispatch.gd / neighborhood_actions.gd. El caller (shell.gd)
# hace el I/O real en Threads (`_launch_tracked`, `_toggle_service`) sin bloquear
# el frame.
#
# Vocabulario: los nombres internos (gvd, ssh) viven sólo en código/logs; ninguna
# cadena de este módulo se muestra al usuario.

const ACTIONS = preload("res://neighborhood_actions.gd")
const SESSION = preload("res://gvd_session.gd")
const DIRECTIONS = preload("res://neighborhood_directions.gd")
const INBOX = preload("res://neighborhood_inbox.gd")

const POSITIONS = ["right", "left", "above", "below"]
const SSH_PROG = "ssh"
# Sin credenciales: no interactivo y con timeout corto (mismo contrato que el buzón
# de direcciones). El transporte no cifra ni autentica el stream: sólo LAN de
# confianza o red protegida (ver tools/gvd/README.md).
const SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3", "-T"]


static func valid_position(p):
	return POSITIONS.has(String(p).strip_edges())


# Id de salida interna del compositor embebido (`primary`, `remote:<hid>`): seguro
# como elemento de argv, sin espacios ni metacaracteres de shell. Puro.
static func valid_output_id(id):
	var v = String(id).strip_edges()
	if v == "" or v.length() > 64:
		return false
	var safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:"
	for i in range(v.length()):
		if safe.find(v[i]) < 0:
			return false
	var alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	return alnum.find(v.substr(0, 1)) >= 0


# Dirección del compás -> `--position` de gvd. `invert` usa la perspectiva del
# peer (cuando el emisor remoto coloca su monitor virtual hacia este equipo).
static func position_for(direction, invert = false):
	var d = String(direction).strip_edges()
	if bool(invert):
		d = DIRECTIONS.inverse(d)
	return DIRECTIONS.to_gvd_position(d)


# Backend de emisión local: "mutter" si el escritorio es GNOME Wayland (ScreenCast
# por PipeWire), "wlr" si es un compositor wlroots CONVENCIONAL (sway, river,
# hyprland, wayfire, niri, labwc...) donde gvd captura con wlr-screencopy, y
# "gdtk" sólo cuando el broker de salidas embebidas anuncia capacidad. "" si no
# puede emitir (X11, sin sesión gráfica, gdtk sin broker).
#
# gdtk NO es sway: anida su propio `WaylandCompositor` y las ventanas del usuario
# viven ahí, no en el sway anfitrión. Crear un output `HEADLESS-*` en sway amplía
# el escritorio EXTERIOR y sólo captura un workspace vacío (SPEC-embedded-multi-
# output §1/§13). Por eso, mientras `embedded_ready` sea falso, gdtk no es emisor
# válido —aunque haya `SWAYSOCK`— y jamás devuelve "wlr". Puro: no lee entorno ni
# I/O; la capacidad embedded entra como argumento explícito.
const EMBEDDED_BACKEND = "gdtk"
const WLR_DESKTOPS = ["sway", "river", "hyprland", "wayfire", "niri",
	"labwc", "phoc", "miracle", "waybox"]

static func local_emit_backend(desktop, session_type = "wayland", embedded_ready = false):
	var d = String(desktop).strip_edges().to_lower()
	var s = String(session_type).strip_edges().to_lower()
	if s != "" and s != "wayland":
		return ""
	if d.find("gnome") >= 0:
		return "mutter"
	if d.find(EMBEDDED_BACKEND) >= 0:
		return EMBEDDED_BACKEND if bool(embedded_ready) else ""
	for name in WLR_DESKTOPS:
		if d.find(name) >= 0:
			return "wlr"
	return ""


# ¿Este equipo puede emitir pantalla? GNOME (Mutter), wlroots convencional (sway)
# o gdtk con capacidad embedded explícita. `embedded_ready` es la capacidad ya
# resuelta por el caller (p. ej. `caps --json`); este módulo no consulta nada.
static func local_can_emit(desktop, session_type = "wayland", embedded_ready = false):
	return local_emit_backend(desktop, session_type, embedded_ready) != ""


# ¿Corresponde crear un monitor headless EXTERIOR en sway (`--virtual`)? Sólo un
# wlroots convencional (sway) con su socket. `gdtk + SWAYSOCK` nunca habilita el
# `--virtual` exterior: su extensión real debe vivir en el compositor embebido.
static func local_outer_virtual_allowed(desktop, session_type, sway_socket = false):
	if not bool(sway_socket):
		return false
	return local_emit_backend(desktop, session_type) == "wlr"


# Ruta de gvd dentro de un plan puro de neighborhood_actions: `python3 <ruta.py>`
# o el binario del PATH directamente. "" si el plan no la trae.
static func gvd_path_of(plan):
	if typeof(plan) != TYPE_DICTIONARY:
		return ""
	var cmd = String(plan.get("cmd", "")).strip_edges()
	var args = plan.get("args", [])
	if cmd == "python3" and typeof(args) == TYPE_ARRAY and args.size() > 0:
		var p = String(args[0]).strip_edges()
		return p if ACTIONS.valid_local_path(p) else ""
	if cmd != "" and cmd != "python3" and ACTIONS.valid_local_path(cmd):
		return cmd
	return ""


# Puerto de gvd anunciado en el plan, o el default 5600.
static func port_of_plan(plan):
	var args = plan.get("args", []) if typeof(plan) == TYPE_DICTIONARY else []
	if typeof(args) == TYPE_ARRAY:
		for i in range(args.size() - 1):
			if String(args[i]).strip_edges() == "--port":
				var n = String(args[i + 1]).strip_edges()
				if n.is_valid_integer():
					return int(n)
	return ACTIONS.DEFAULT_GVD_PORT


# Host destino (`--host`) del plan, o "" si falta.
static func target_host_of(plan):
	var args = plan.get("args", []) if typeof(plan) == TYPE_DICTIONARY else []
	if typeof(args) == TYPE_ARRAY:
		for i in range(args.size() - 1):
			if String(args[i]).strip_edges() == "--host":
				return String(args[i + 1]).strip_edges()
	return ""


# Plan del emisor LOCAL ("Extender mi escritorio a él"): `gvd send --host <peer>`
# con `--position` si el mapa la conoce. Delega en neighborhood_actions.
#
# Dos modos de extensión, mutuamente excluyentes:
#   - `wlr_virtual`: wlroots convencional con sway; agrega `--virtual` para que gvd
#     cree un monitor headless en el sway EXTERIOR y el escritorio se extienda.
#   - `capture_backend` + `output_id`: extensión real en el compositor embebido de
#     gdtk; agrega `--capture gdtk --output <id>` SÓLO con id validado. Este modo
#     nunca agrega `--virtual`.
#
# Compat: los parámetros 5/6 son opcionales y con default vacío, así las llamadas
# existentes de 4/5 argumentos no cambian de comportamiento ni de argv.
static func local_send_argv(gvd_path, peer, port = 0, position = "", wlr_virtual = false,
		capture_backend = "", output_id = ""):
	var pos = String(position).strip_edges()
	if pos != "" and not valid_position(pos):
		return _bad("posición inválida: " + pos)
	var opts = {}
	if pos != "":
		opts["position"] = pos
	var plan = ACTIONS.gvd_send_plan(gvd_path, peer, port, opts)
	if not bool(plan.get("ok", false)) \
			or typeof(plan.get("args", [])) != TYPE_ARRAY:
		return plan
	var cap = String(capture_backend).strip_edges().to_lower()
	if cap != "":
		if cap != EMBEDDED_BACKEND:
			return _bad("backend de captura inválido: " + cap)
		var oid = String(output_id).strip_edges()
		if not valid_output_id(oid):
			return _bad("output id inválido: " + oid)
		plan["args"].append_array(["--capture", cap, "--output", oid])
	elif bool(wlr_virtual):
		plan["args"].append("--virtual")
	return plan


# Plan del receptor LOCAL ("Ver su escritorio aquí"): `gvd recv --sink auto`
# (prefiere gl/xv; waylandsink aborta en el compositor embebido) y `--port` si el
# emisor remoto usa otro puerto. El emisor wlroots ya no transmite el puntero en
# el video (--overlay-cursor 0); se usa el puntero propio de este equipo, así que
# se desactiva el cursor separado (no hay que mover el cursor de sway por red).
static func local_recv_argv(gvd_path, has_sway = false, port = 0):
	var plan = ACTIONS.gvd_recv_plan(gvd_path, {"sink": "auto", "port": int(port)})
	if bool(plan.get("ok", false)) and typeof(plan.get("args", [])) == TYPE_ARRAY:
		plan["args"].append_array(["--cursor", "none"])
	return plan


# argv de ssh para abrir el receptor remoto (buzón ssh). El comando remoto
# resuelve gvd por candidatos y no interpola nada no confiable: `has_sway` sólo
# elige una variante fija.
static func remote_recv_argv(peer, has_sway = false):
	var cmd = _remote_loop() + " recv --sink auto"
	if bool(has_sway):
		cmd += " --cursor sway"
	cmd += "; done; echo 'vecindario: gvd no encontrado (recv)' >&2"
	return _ssh_argv(peer, cmd)


# argv de ssh para que el peer emita hacia `target_host` ("Ver su escritorio
# aquí"). La posición se invierte: el emisor remoto coloca su monitor virtual
# desde su propia perspectiva. host/posición validados; nada de shell-injection.
static func remote_send_argv(peer, target_host, port = 0, position = ""):
	var host = String(target_host).strip_edges()
	if not INBOX.valid_peer(host):
		return _bad("destino inválido: " + host)
	var pos = String(position).strip_edges()
	if pos != "" and not valid_position(pos):
		return _bad("posición inválida: " + pos)
	var cmd = _remote_loop() + " send --host " + _sh_quote(host)
	var n = int(port)
	if n > 0 and n != ACTIONS.DEFAULT_GVD_PORT:
		cmd += " --port " + str(n)
	if pos != "":
		cmd += " --position " + pos
	cmd += "; done; echo 'vecindario: gvd no encontrado (send)' >&2"
	return _ssh_argv(peer, cmd)


# Claves de sesión rastreada por tipo. El emisor local conserva la clave histórica
# (el propio hid) para no romper el estado de sesión del Vecindario; receptor y
# emisor remotos usan claves propias.
static func local_sender_key(host_id):
	return String(host_id)


static func remote_recv_key(host_id):
	return "gvdrecv:" + String(host_id)


static func remote_send_key(host_id):
	return "gvdsend:" + String(host_id)


static func session_keys(host_id):
	var id = String(host_id)
	return [local_sender_key(id), remote_recv_key(id), remote_send_key(id)]


# Quita de los links Deskflow (barrier) los que apuntan a `direction` mientras gvd
# extiende el monitor virtual hacia ese vecino. Devuelve {links, removed,
# suspended}; `removed` se guarda para restaurar al cortar la sesión. Puro.
static func deskflow_suspend(links, direction):
	var out = {"links": [], "removed": [], "suspended": false}
	if typeof(links) != TYPE_ARRAY:
		return out
	var d = String(direction).strip_edges().to_lower()
	if not DIRECTIONS.valid_direction(d) or d == "none":
		for l in links:
			out.links.append(l)
		return out
	for l in links:
		if typeof(l) == TYPE_DICTIONARY \
				and String(l.get("direction", "")).strip_edges().to_lower() == d:
			out.removed.append(l)
			out.suspended = true
		else:
			out.links.append(l)
	return out


# Reincorpora los links quitados por deskflow_suspend sin duplicar. Puro.
static func deskflow_restore(links, removed):
	var out = []
	if typeof(links) == TYPE_ARRAY:
		for l in links:
			out.append(l)
	if typeof(removed) != TYPE_ARRAY:
		return out
	for r in removed:
		if not _has_link(out, r):
			out.append(r)
	return out


# Rangos [west_lo,west_hi, east_lo,east_hi, north_lo,north_hi, south_lo,south_hi]
# para el portal InputCapture, derivados de los links Deskflow locales. Las
# direcciones suspendidas (gvd extiende el escritorio hacia ese borde: el input NO
# cruza) quedan en rango puntual 0..0, así el borde no captura input. Puro; espeja
# el orden que espera `eis_server_set_capture_ranges`.
static func capture_ranges(links, disabled = []):
	var r = [0.0, 100.0, 0.0, 100.0, 0.0, 100.0, 0.0, 100.0]
	var idx = {"west": 0, "east": 2, "north": 4, "south": 6}
	if typeof(links) == TYPE_ARRAY:
		for l in links:
			if typeof(l) != TYPE_DICTIONARY:
				continue
			var d = String(l.get("direction", "")).strip_edges()
			if not idx.has(d):
				continue
			var lr = l.get("local_range")
			if lr == null or typeof(lr) != TYPE_ARRAY or lr.size() < 2:
				continue
			var e = int(idx[d])
			r[e] = clamp(float(lr[0]), 0.0, 100.0)
			r[e + 1] = clamp(float(lr[1]), 0.0, 100.0)
	if typeof(disabled) == TYPE_ARRAY:
		for d in disabled:
			var ds = String(d).strip_edges()
			if idx.has(ds):
				var de = int(idx[ds])
				r[de] = 0.0
				r[de + 1] = 0.0
	return r


static func _remote_loop():
	return "for c in \"$HOME/gdtk/tools/gvd/gvd.py\" \"$HOME/Proyectos/gvd/gvd.py\"" \
		+ " \"$HOME/gvd/gvd.py\" \"$(command -v gvd 2>/dev/null)\"; do" \
		+ " [ -n \"$c\" ] && [ -f \"$c\" ] && exec python3 \"$c\""


static func _ssh_argv(peer, remote_cmd):
	if not INBOX.valid_peer(peer):
		return _bad("equipo inválido para ssh")
	var args = []
	for o in SSH_OPTS:
		args.append(String(o))
	args.append(String(peer).strip_edges())
	args.append(String(remote_cmd))
	return {"ok": true, "cmd": SSH_PROG, "args": args, "error": ""}


# Cita un token para el comando remoto de ssh. Los valores que llegan acá ya
# pasaron validación; aun así se cita lo que no sea seguro.
static func _sh_quote(s):
	var v = String(s)
	if v == "":
		return "''"
	var safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:@"
	for i in range(v.length()):
		if safe.find(v[i]) < 0:
			return "'" + v.replace("'", "'\\''") + "'"
	return v


static func _has_link(list, link):
	if typeof(link) != TYPE_DICTIONARY:
		return false
	var k = _link_key(link)
	for l in list:
		if typeof(l) == TYPE_DICTIONARY and _link_key(l) == k:
			return true
	return false


static func _link_key(link):
	return String(link.get("direction", "")).strip_edges().to_lower() + "|" \
		+ String(link.get("peer", "")).strip_edges()


static func _bad(error):
	return {"ok": false, "cmd": "", "args": [], "error": error}


static func selftest():
	var ok = true

	# Posición / inversión.
	ok = ok and valid_position("right") and valid_position("above")
	ok = ok and not valid_position("diagonal") and not valid_position("")
	ok = ok and position_for("east") == "right" and position_for("north") == "above"
	ok = ok and position_for("east", true) == "left"
	ok = ok and position_for("none") == "" and position_for("up") == ""

	# Emisor local: GNOME (Mutter) o un compositor wlroots CONVENCIONAL (sway...).
	ok = ok and local_can_emit("GNOME") and local_can_emit("ubuntu:GNOME", "wayland")
	ok = ok and local_emit_backend("GNOME") == "mutter"
	ok = ok and local_can_emit("sway") and local_emit_backend("sway") == "wlr"
	ok = ok and local_can_emit("river") and local_emit_backend("river") == "wlr"
	# gdtk anida su compositor: sin broker embedded no emite y NUNCA es sway/wlr,
	# tenga o no SWAYSOCK (que la función pura ni mira).
	ok = ok and not local_can_emit("gdtk") and local_emit_backend("gdtk") == ""
	ok = ok and local_emit_backend("gdtk") != "wlr"
	ok = ok and not local_outer_virtual_allowed("gdtk", "wayland", true)
	ok = ok and local_outer_virtual_allowed("sway", "wayland", true)
	ok = ok and not local_outer_virtual_allowed("sway", "wayland", false)
	# Con capacidad embedded explícita, gdtk devuelve un backend estable "gdtk".
	ok = ok and local_can_emit("gdtk", "wayland", true)
	ok = ok and local_emit_backend("gdtk", "wayland", true) == "gdtk"
	ok = ok and local_emit_backend("gdtk", "x11", true) == ""
	ok = ok and not local_can_emit("GNOME", "x11")
	ok = ok and not local_can_emit("XFCE")
	ok = ok and not local_can_emit("")

	# Extracción del plan.
	var real = ACTIONS.gvd_send_plan("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5601,
		{"position": "right"})
	ok = ok and gvd_path_of(real) == "/home/u/Proyectos/gvd/gvd.py"
	ok = ok and port_of_plan(real) == 5601 and target_host_of(real) == "tengu.local"
	var bare = ACTIONS.gvd_send_plan("gvd", "tengu.local", 0, {})
	ok = ok and gvd_path_of(bare) == "gvd" and port_of_plan(bare) == 5600
	ok = ok and gvd_path_of(null) == "" and target_host_of(real) != ""
	ok = ok and gvd_path_of({"ok": false, "cmd": "", "args": []}) == ""

	# Receptor local: sink auto (gl/xv), cursor separado desactivado explícitamente.
	var rp = local_recv_argv("/home/u/gvd/gvd.py", false)
	ok = ok and rp.ok and rp.cmd == "python3" and rp.args[1] == "recv"
	ok = ok and rp.args.find("--sink") >= 0 and rp.args.find("--cursor") >= 0 \
		and rp.args.find("none") >= 0
	var rps = local_recv_argv("/home/u/gvd/gvd.py", true)
	ok = ok and rps.args.find("--cursor") >= 0 and rps.args.find("none") >= 0
	ok = ok and not local_recv_argv("~/gvd/gvd.py", true).ok
	var rpp = local_recv_argv("/home/u/gvd/gvd.py", false, 5601)
	ok = ok and rpp.args.find("--port") >= 0 and rpp.args.find("5601") >= 0
	ok = ok and local_recv_argv("/home/u/gvd/gvd.py", false, 5600).args.find("--port") < 0

	# Emisor local: posición va al argv; ruta inválida falla.
	var sp = local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "right")
	ok = ok and sp.ok and sp.args.find("--position") >= 0 and sp.args.find("right") >= 0
	ok = ok and not local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 0,
		"diagonal").ok
	ok = ok and not local_send_argv("~/gvd/gvd.py", "tengu.local", 0, "").ok
	# wlr_virtual agrega --virtual al argv del emisor (extensión real desde sway).
	var spv = local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "right", true)
	ok = ok and spv.args.find("--virtual") >= 0 and spv.args.find("--position") >= 0
	ok = ok and sp.args.find("--virtual") < 0
	# Captura embebida: `--capture gdtk --output <id>` sólo con id validado y sin
	# --virtual. El id inválido y el backend desconocido fallan cerrados.
	var spc = local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 5600, "right",
		false, "gdtk", "remote:ab12")
	ok = ok and spc.ok and spc.args.has("--capture") and spc.args.has("gdtk")
	ok = ok and spc.args.has("--output") and spc.args.has("remote:ab12")
	ok = ok and spc.args.find("--virtual") < 0 and spc.args.find("--position") >= 0
	ok = ok and not local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 0, "",
		false, "gdtk", "bad id; rm -rf").ok
	ok = ok and not local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 0, "",
		false, "wlr", "remote:ab12").ok
	# Un capture_backend presente con wlr_virtual=true no produce --virtual.
	var spcv = local_send_argv("/home/u/Proyectos/gvd/gvd.py", "tengu.local", 0, "",
		true, "gdtk", "primary")
	ok = ok and spcv.ok and spcv.args.find("--virtual") < 0
	ok = ok and sp.args.find("--capture") < 0

	# Receptor remoto por ssh: sin shell-injection y con la variante de cursor.
	var rr = remote_recv_argv("tengu.local", false)
	ok = ok and rr.ok and rr.cmd == "ssh"
	ok = ok and rr.args.has("BatchMode=yes") and rr.args.has("ConnectTimeout=3")
	ok = ok and rr.args[rr.args.size() - 2] == "tengu.local"
	var rcmd = String(rr.args[rr.args.size() - 1])
	ok = ok and rcmd.find("recv --sink auto") >= 0 and rcmd.find("--cursor") < 0
	ok = ok and rcmd.find("command -v gvd") >= 0
	var rrs = remote_recv_argv("tengu.local", true)
	ok = ok and String(rrs.args[rrs.args.size() - 1]).find("--cursor sway") >= 0
	ok = ok and not remote_recv_argv("-bad", false).ok
	ok = ok and not remote_recv_argv("a b", false).ok

	# Emisor remoto: host destino validado, posición invertida y puerto opcional.
	var rs = remote_send_argv("192.168.1.20", "bastion.local", 5600, "left")
	ok = ok and rs.ok and rs.cmd == "ssh"
	var scmd = String(rs.args[rs.args.size() - 1])
	ok = ok and scmd.find("send --host bastion.local") >= 0
	ok = ok and scmd.find("--position left") >= 0 and scmd.find("--port") < 0
	var rs2 = remote_send_argv("192.168.1.20", "bastion.local", 5601, "")
	ok = ok and String(rs2.args[rs2.args.size() - 1]).find("--port 5601") >= 0
	ok = ok and not remote_send_argv("192.168.1.20", "", 0, "").ok
	ok = ok and not remote_send_argv("192.168.1.20", "bastion.local", 0, "diagonal").ok
	ok = ok and not remote_send_argv("a b", "bastion.local", 0, "").ok

	# Claves de sesión: emisor local conserva el hid; las remotas son propias.
	var keys = session_keys("h1")
	ok = ok and keys.size() == 3 and keys[0] == "h1"
	ok = ok and local_sender_key("h1") == "h1"
	ok = ok and remote_recv_key("h1") == "gvdrecv:h1"
	ok = ok and remote_send_key("h1") == "gvdsend:h1"

	# Suspensión/restauración del vínculo Deskflow por dirección.
	var links = [
		{"direction": "east", "peer": "tengu"},
		{"direction": "north", "peer": "cupid"},
	]
	var sus = deskflow_suspend(links, "east")
	ok = ok and sus.suspended and sus.removed.size() == 1
	ok = ok and sus.links.size() == 1 and String(sus.links[0].direction) == "north"
	var restored = deskflow_restore(sus.links, sus.removed)
	ok = ok and restored.size() == 2
	var again = deskflow_restore(restored, sus.removed)
	ok = ok and again.size() == 2        # no duplica
	var noop = deskflow_suspend(links, "none")
	ok = ok and not noop.suspended and noop.links.size() == 2
	ok = ok and deskflow_suspend(null, "east").links.empty()

	assert(ok, "selftest de gvd_launch")
	return ok


func run_selftest():
	return selftest()


# Plan del emisor de UNA ventana (Grupo: soltar su bloque sobre un equipo): gvd lee
# los frames del archivo que escribe window_cast.gd (`--capture shm`). Sólo rutas
# absolutas sin `..` (el archivo vive en XDG_RUNTIME_DIR).
static func window_send_argv(gvd_path, peer, shm_path, fps = 20, port = 0):
	var p = String(shm_path).strip_edges()
	if not p.begins_with("/") or p.find("..") >= 0:
		return _bad("archivo de frames inválido: " + p)
	var plan = ACTIONS.gvd_send_plan(gvd_path, peer, port, {})
	if bool(plan.get("ok", false)) and typeof(plan.get("args", [])) == TYPE_ARRAY:
		plan["args"].append_array(["--capture", "shm", "--shm", p,
			"--fps", str(int(clamp(int(fps), 1, 60)))])
	return plan
