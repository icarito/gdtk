extends SceneTree

# Controles de audio universales (SPEC-notificaciones-2 §6): una acción de volumen
# (up/down/mute) se aplica local y se difunde a todos los equipos del Grupo por el
# canal peer; viaja la ACCIÓN, no el nivel (cada host conserva su volumen). El equipo
# que la recibe la aplica sin re-difundirla (si no, rebotaría). No se difunde mientras
# la captura de Deskflow tiene el teclado (la tecla es del equipo remoto).
#   godot --no-window --path shell -s $PWD/tests/universal_audio_test.gd

var failed = 0


class ShellStub:
	extends Reference
	var broadcasts = []
	var redraws = 0
	func request_redraw():
		redraws += 1
	func _broadcast_media(action):
		broadcasts.append(String(action))


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _read(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return ""
	var t = f.get_as_text()
	f.close()
	return t


func _init():
	# --- system_osd: aplica local + difunde salvo cuando viene de un par ---
	var osd = load("res://system_osd.gd").new()
	var sh = ShellStub.new()
	osd._shell = sh  # sin setup(): no arranca el worker (that toca hardware)

	check("mute aplica y difunde", osd.media_action("mute") and osd.muted \
		and sh.broadcasts == ["mute"])
	sh.broadcasts = []
	var v0 = osd.volume
	check("up aplica y difunde", osd.media_action("up") and osd.volume > v0 \
		and sh.broadcasts == ["up"])
	sh.broadcasts = []
	var v1 = osd.volume
	check("peer (broadcast=false) aplica sin re-difundir",
		osd.media_action("down", false) and osd.volume < v1 and sh.broadcasts.empty())
	check("acción desconocida no aplica ni difunde",
		not osd.media_action("brightness") and sh.broadcasts.empty())

	# --- peer_link: método en la lista blanca + validador puro ---
	var LINK = load("res://peer_link.gd")
	check("peer_link conoce 'media'", LINK.valid_method("media"))
	check("media_action valida y normaliza",
		LINK.media_action({"action": "mute"}) == "mute" \
		and LINK.media_action({"action": " up "}) == "up" \
		and LINK.media_action({"action": "loud"}) == "" \
		and LINK.media_action({}) == "")
	check("selftest de peer_link", LINK.selftest())

	# --- cableado (el camino real necesita una sesión viva) ---
	var shell = _read("res://shell.gd")
	check("shell define _broadcast_media", shell.find("func _broadcast_media(action):") >= 0)
	check("shell define _peer_media", shell.find("func _peer_media(action):") >= 0)
	check("shell difunde a los destinos del Grupo",
		shell.find("_peer_send_async(targets, \"media\", {\"action\": String(action)})") >= 0)
	check("shell no difunde mientras Deskflow captura",
		shell.find("is_capturing()") >= 0 \
		and shell.find("is_capturing()") < shell.find("_peer_send_async(targets, \"media\""))

	var pc = _read("res://peer_control.gd")
	check("peer_control despacha 'media'", pc.find("\"media\":") >= 0 \
		and pc.find("_peer_media") >= 0 and pc.find("LINK.media_action") >= 0)

	var so = _read("res://system_osd.gd")
	check("system_osd difunde por el shell",
		so.find("_shell._broadcast_media(String(action))") >= 0)
	check("handle_input/rpc_action pasan por media_action",
		so.find("KEY_VOLUMEMUTE:\n\t\t\tmedia_action(\"mute\")") >= 0 \
		and so.find("\"mute\":\n\t\t\tmedia_action(\"mute\")") >= 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
