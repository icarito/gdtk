extends SceneTree

# Autoprueba del buzón de handshake de dirección del Vecindario (K3). Puro: no
# carga res://shell.gd, no hace ssh real ni abre sockets. Correr:
#   godot --no-window --path shell -s $PWD/tests/neighborhood_inbox_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _extract_b64(script):
	var marker = "printf %s '"
	var a = String(script).find(marker)
	var b = String(script).find("' | base64 -d")
	if a < 0 or b < 0 or b <= a + marker.length():
		return ""
	return String(script).substr(a + marker.length(), b - (a + marker.length()))


func _init():
	var inbox = load("res://neighborhood_inbox.gd").new()
	var hs = load("res://neighborhood_handshake.gd").new()
	check("selftest() del buzón", inbox.run_selftest())

	# --- Rutas y nombres -----------------------------------------------------
	check("buzón bajo gdtk/direction-inbox",
		inbox.inbox_dir("/home/u/.config") == "/home/u/.config/gdtk/direction-inbox")
	check("proposal_path usa <hid>.json",
		inbox.proposal_path("/cfg", "aabbcc") == "/cfg/gdtk/direction-inbox/aabbcc.json")
	check("response_path usa <hid>.response.json",
		inbox.response_path("/cfg", "aabbcc") == "/cfg/gdtk/direction-inbox/aabbcc.response.json")
	check("hid basura no produce nombre",
		inbox.proposal_name("") == "" and inbox.response_name("") == "")
	check("traversal se sanea sin salir del buzón",
		inbox.safe_hid("../../etc/passwd") == "etcpasswd"
		and inbox.proposal_name("../x") == "x.json")

	# --- argv de ssh: sin shell-injection ------------------------------------
	var payload = hs.encode(hs.proposal("localhid", "peerhid", "east"))
	var argv = inbox.ssh_write_argv("tengu.local", inbox.proposal_name("localhid"), payload)
	check("argv ssh ok y binario ssh", argv.ok and argv.cmd == "ssh")
	check("BatchMode + ConnectTimeout",
		argv.args.has("BatchMode=yes") and argv.args.has("ConnectTimeout=3"))
	check("peer va como argumento separado, no embebido",
		argv.args[argv.args.size() - 2] == "tengu.local")
	var script = String(argv.args[argv.args.size() - 1])
	check("escritura atómica tmp + mv", script.find("mv -f") >= 0
		and script.find(".tmp.$$") >= 0)
	check("payload viaja en base64, no crudo",
		_extract_b64(script) != "" and script.find(payload) < 0)
	check("payload base64 decodifica al JSON original",
		Marshalls.base64_to_raw(_extract_b64(script)).get_string_from_utf8() == payload)
	check("peer con guion rechazado (opción ssh)",
		not inbox.ssh_write_argv("-oProxyCommand=x", "a.json", payload).ok)
	check("nombre con traversal rechazado",
		not inbox.ssh_write_argv("host", "../x.json", payload).ok)
	check("sin shell real: sólo se construye argv",
		argv.args.size() == inbox.SSH_OPTS.size() + 2)

	# --- Decisión por archivo y consumo --------------------------------------
	var proposal = hs.proposal("peerhid", "localhid", "east")
	var response = hs.response("peerhid", "localhid", "east", true)
	check("proposal válida -> action proposal",
		inbox.plan_file("peerhid.json", hs.decode(hs.encode(proposal)), "localhid").action == "proposal")
	check("response válida -> action response",
		inbox.plan_file("peerhid.response.json", hs.decode(hs.encode(response)), "localhid").action == "response")
	check("archivo ajeno no se toca",
		inbox.plan_file("notas.txt", hs.decode(hs.encode(proposal)), "localhid").action == "ignore"
		and not inbox.plan_file("notas.txt", hs.decode(hs.encode(proposal)), "localhid").delete)
	check("basura se consume (borra)",
		inbox.plan_file("peerhid.json", hs.decode("{no json"), "localhid").delete)
	check("mensaje para otro host se ignora",
		inbox.plan_file("peerhid.json", hs.decode(hs.encode(proposal)), "otro").action == "ignore")

	# --- Simulación end-to-end del handshake (sin ssh) -----------------------
	# Peer propone "este host al este del peer"; el buzón local lo aplica como
	# proposed y el estado persistible queda listo para neighborhood_ui.
	var local_entry = {}
	var file = hs.decode(hs.encode(hs.proposal("peerhid", "localhid", "east")))
	var plan = inbox.plan_file("peerhid.json", file, "localhid")
	check("proposal entra al buzón y se consume", plan.action == "proposal" and plan.delete)
	local_entry = hs.apply(local_entry, file)
	check("proposal deja el entry en proposed",
		local_entry.direction == "east" and local_entry.confirm == "proposed")

	# El proponente recibe la respuesta y confirma.
	var resp = hs.decode(hs.encode(hs.response("localhid", "peerhid", "east", true)))
	var plan_r = inbox.plan_file("localhid.response.json", resp, "peerhid")
	check("response entra al buzón y se consume", plan_r.action == "response" and plan_r.delete)
	var confirmed = hs.apply({"direction": "east", "confirm": "proposed"}, resp)
	check("response aceptada confirma el vínculo",
		confirmed.confirm == "confirmed" and confirmed.direction == "east")

	# Rechazo: vuelve a unconfirmed sin perder la dirección propuesta.
	var reject = hs.decode(hs.encode(hs.response("localhid", "peerhid", "east", false)))
	var rejected = hs.apply({"direction": "east", "confirm": "proposed"}, reject)
	check("response rechazada -> unconfirmed", rejected.confirm == "unconfirmed")

	# --- Destino ssh desde el modelo de hosts --------------------------------
	var host = {"services": [{"address": "", "host": "tengu.local"},
		{"address": "192.168.1.20", "host": "tengu.local"}]}
	check("ssh_target prefiere la dirección resuelta",
		inbox.ssh_target(host).peer == "192.168.1.20")
	check("ssh_target sin destino válido -> no ok",
		not inbox.ssh_target({"services": [{"address": "bad host"}]}).ok
		and not inbox.ssh_target({}).ok)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
