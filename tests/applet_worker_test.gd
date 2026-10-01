extends SceneTree

# Autoprueba de los applets con worker (shell/applet_keyboard.gd, shell/applet_bluetooth.gd).
# Sólo parsers puros y estado local: sin I/O real, sin lanzar procesos. Correr:
#   godot --no-window --path shell -s $PWD/tests/applet_worker_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var K = load("res://applet_keyboard.gd")
	var B = load("res://applet_bluetooth.gd")
	check("keyboard: script carga", K != null and K.can_instance())
	check("bluetooth: script carga", B != null and B.can_instance())

	# Parser puro del `localectl status` (sin procesos).
	var kt = "System Locale: LANG=es_MX.UTF-8\nVC Keymap: es\nX11 Layout: es\nX11 Variant:\n"
	check("parse_localectl_layout: X11 Layout", K.parse_localectl_layout(kt) == "es")
	check("parse_localectl_layout: ausente -> \"\"", K.parse_localectl_layout("VC Keymap: us\n") == "")
	check("parse_localectl_layout: texto vacío -> \"\"", K.parse_localectl_layout("") == "")

	# Parser puro de `bluetoothctl show` (sin procesos).
	var bt = "Controller AA:BB:CC:DD:EE:FF (public)\n\tName: Tengu\n\tPowered: yes\n\tDiscovering: no\n"
	var pb = B.parse_bluetooth_show(bt)
	check("parse_bluetooth_show: powered/controller/name/discovering",
		pb.powered == "yes" and pb.controller == "AA:BB:CC:DD:EE:FF (public)" \
		and pb.name == "Tengu" and pb.discovering == "no" and not pb.no_controller)
	var pb2 = B.parse_bluetooth_show("No default controller available\n")
	check("parse_bluetooth_show: sin adaptador", pb2.no_controller and pb2.powered == "")
	var pb3 = B.parse_bluetooth_show("\tPowered: no\n\tName: X\n")
	check("parse_bluetooth_show: apagado", pb3.powered == "no" and pb3.name == "X" and not pb3.no_controller)

	# Validación XKB y etiquetas (hilo principal, sin procesos).
	var kb = K.new()
	check("_safe_xkb: válidos", kb._safe_xkb("es") == "es" \
		and kb._safe_xkb("us,intl:dead_acute") == "us,intl:dead_acute")
	check("_safe_xkb: inseguros -> \"\"", kb._safe_xkb("es; rm -rf /") == "" \
		and kb._safe_xkb("es $(x)") == "" and kb._safe_xkb("es `id`") == "")
	check("_label: conocido y desconocido", kb._label("es") == "ES" and kb._label("zz") == "ZZ")
	check("LAYOUTS: es/latam/us", kb.LAYOUTS.has("es") and kb.LAYOUTS.has("latam") and kb.LAYOUTS.has("us"))

	# Defaults del snapshot público.
	check("keyboard: defaults", kb.state == "sin_dato" and kb.value == "sin dato" \
		and kb.detail == "" and kb.version == 0)
	var b = B.new()
	check("bluetooth: defaults", b.state == "sin_dato" and b.value == "sin dato" \
		and b.detail == "" and b.version == 0)

	# choose() inválido: no toca disco ni arranca worker; publica el error.
	check("keyboard.choose inválido -> false", kb.choose("xx") == false)
	check("keyboard.choose inválido: state error + detalle",
		kb.state == "error" and kb.detail.find("no válida") >= 0)
	check("keyboard: choose inválido no arrancó worker", not kb.running())

	# stop() es idempotente y seguro sin worker arrancado.
	kb.stop()
	kb.stop()
	b.stop()
	check("stop() idempotente sin worker", true)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
