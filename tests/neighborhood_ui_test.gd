extends SceneTree

# Autoprueba del Vecindario K10a: mapa 2D único, imán de dirección, menú
# contextual con lenguaje humano y APIs puras conservadas (acciones, directions,
# hosts). No renderiza ni ejecuta procesos. Correr:
#   godot --no-window --path shell -s $PWD/tests/neighborhood_ui_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _has(actions, id):
	for a in actions:
		if a.id == id:
			return true
	return false


func _init():
	var MAP = load("res://neighborhood_map.gd")
	var ui = load("res://neighborhood_ui.gd").new()

	# Wi-Fi y hosts no comparten selección.
	check("selected (SSID) y selected_host separados", ui.selected == "" and ui.selected_host == "")

	# Assets nuevos (The Noun Project): deben resolver fuera de la UI también.
	check("ícono de AP presente", ui._icon_texture("np/access-point") != null)
	check("ícono de tablet presente", ui._icon_texture("np/device-tablet") != null)
	check("sin shell el device local es unknown", ui._local_device_kind() == "unknown")

	# --- Vocabulario: helper de traducción -----------------------------------
	check("acción pantalla en lenguaje humano",
		MAP.human_action_label("use_as_screen") == "Ver su escritorio aquí")
	check("acción extender escritorio",
		MAP.human_action_label("share_my_screen") == "Extender mi escritorio a él")
	check("acción controlar al vecino",
		MAP.human_action_label("serve_input_here") == "Controlarlo con mi teclado y mouse")
	check("acción usar su teclado y mouse",
		MAP.human_action_label("use_remote_input") == "Usar su teclado y mouse aquí")
	check("etiqueta de cardinales", MAP.direction_label("north") == "Norte"
		and MAP.direction_label("south") == "Sur"
		and MAP.direction_label("east") == "Este"
		and MAP.direction_label("west") == "Oeste")

	var screen_action = {"id": "use_as_screen", "enabled": false,
		"reason": "gvd no disponible en este equipo"}
	check("razón sin nombre interno", MAP.human_reason(screen_action) == "no tiene el receptor de pantalla")
	check("razón de conflicto", MAP.human_reason({"id": "x", "enabled": false,
		"reason": "conflicto de borde: dos hosts reclaman la misma dirección"}) == "dos equipos en el mismo lado")
	check("razón de confirmación", MAP.human_reason({"id": "x", "enabled": false,
		"reason": "dirección sin confirmar: no se generan links"}) == "falta confirmar la posición")
	check("razón de no confiable", MAP.human_reason({"id": "x", "enabled": false,
		"reason": "host degradado: sin hid confirmado"}) == "sin identificar: no es confiable")
	check("acción disponible sin razón", MAP.human_reason({"id": "x", "enabled": true, "reason": "y"}) == "")

	check("estado de dirección confirmada en español",
		MAP.direction_status_text("confirmada", "east") == "posición confirmada: Este")
	check("estado de dirección sin posición",
		MAP.direction_status_text("sin_direccion", "none") == "sin posición")

	check("debug off por defecto", not MAP.debug_enabled("") and not MAP.debug_enabled("0"))
	check("debug on con 1/true", MAP.debug_enabled("1") and MAP.debug_enabled("true"))

	# Ninguna cadena visible producida debe contener vocabulario interno.
	var visible = [MAP.human_action_label("use_as_screen"), MAP.human_action_label("share_my_screen"),
		MAP.human_action_label("use_remote_input"), MAP.human_action_label("serve_input_here"),
		MAP.direction_status_text("confirmada", "north"), MAP.EMPTY_SEARCHING, MAP.EMPTY_NONE]
	var clean_vocab = true
	for s in visible:
		if MAP.has_internal_terms(s):
			clean_vocab = false
	check("sin vocabulario interno en cadenas visibles", clean_vocab)
	check("map detecta jerga", MAP.has_internal_terms("gvd deskflow") and not MAP.has_internal_terms("Ver su escritorio aquí"))

	# --- Estado vacío --------------------------------------------------------
	check("buscando durante la gracia",
		MAP.empty_message(0, 1000) == "Buscando equipos cercanos…")
	check("sin equipos tras la gracia",
		MAP.empty_message(0, MAP.EMPTY_GRACE_MS + 1) == "No hay otros equipos")
	check("sin mensaje si hay equipos", MAP.empty_message(3, 0) == "")

	# --- Wi-Fi como infraestructura -----------------------------------------
	var nets = [{"ssid": "MiRed", "in_use": true, "r_frac": 0.5, "angle": 0.3},
		{"ssid": "Otra", "in_use": false, "r_frac": 0.9, "angle": 2.0}]
	check("Red: <SSID> de la red en uso", MAP.wifi_label(nets) == "Red: MiRed")
	check("sin red en uso no hay etiqueta", MAP.wifi_label([{"ssid": "X", "in_use": false}]) == "")
	check("puntos de Wi-Fi por red", MAP.wifi_dots(nets, Vector2(1280, 800), 80.0).size() == 2)

	# --- Mapa 2D: ubicación por dirección y anillo --------------------------
	var vp = Vector2(1280, 800)
	var bar = 80.0
	var center = vp * 0.5
	var radii = MAP.map_radii(vp, bar)
	check("anillo exterior mayor que el medio", radii.outer > radii.mid)
	var map_hosts = [
		{"id": "n", "label": "Norte", "capabilities": {}},
		{"id": "s", "label": "Sur", "capabilities": {}},
		{"id": "e", "label": "Este", "capabilities": {}},
		{"id": "w", "label": "Oeste", "capabilities": {}},
		{"id": "f", "label": "Libre", "capabilities": {}},
	]
	var dirs = {"n": {"direction": "north", "confirm": "confirmed"},
		"s": {"direction": "south"}, "e": {"direction": "east"}, "w": {"direction": "west"}}
	var nodes = MAP.map_layout(map_hosts, dirs, vp, bar)
	check("un nodo por host", nodes.size() == 5)
	var by_id = {}
	for node in nodes:
		by_id[String(node.id)] = node
	check("norte arriba", by_id.n.center.y < center.y and abs(by_id.n.center.x - center.x) < 1.0)
	check("sur abajo", by_id.s.center.y > center.y and abs(by_id.s.center.x - center.x) < 1.0)
	check("este derecha", by_id.e.center.x > center.x and abs(by_id.e.center.y - center.y) < 1.0)
	check("oeste izquierda", by_id.w.center.x < center.x and abs(by_id.w.center.y - center.y) < 1.0)
	check("direccional pegado al anillo medio",
		abs((by_id.n.center - center).length() - radii.mid) < 1.0)
	check("sin dirección en el anillo exterior y atenuado",
		by_id.f.dimmed and abs((by_id.f.center - center).length() - radii.outer) < 1.0)
	check("pos = centro - media caja", by_id.n.pos == by_id.n.center - Vector2(by_id.n.size, by_id.n.size) * 0.5)
	var inside = true
	for node in nodes:
		if node.pos.x < 0.0 or node.pos.y < 0.0 \
				or node.pos.x + node.size > vp.x or node.pos.y + node.size > vp.y:
			inside = false
	check("todos los nodos dentro de pantalla", inside)

	# Varios hosts sin dirección: repartidos uniformemente (posiciones distintas).
	var free_nodes = MAP.map_layout([
		{"id": "f1", "label": "F1", "capabilities": {}},
		{"id": "f2", "label": "F2", "capabilities": {}},
		{"id": "f3", "label": "F3", "capabilities": {}},
	], {}, vp, bar)
	check("sin dirección se reparten", free_nodes[0].center != free_nodes[1].center
		and free_nodes[1].center != free_nodes[2].center)

	# --- Imán de arrastre ----------------------------------------------------
	check("imán este", MAP.magnet_direction(Vector2(80.0, 0.0)) == "east")
	check("imán oeste", MAP.magnet_direction(Vector2(-80.0, 0.0)) == "west")
	check("imán sur", MAP.magnet_direction(Vector2(0.0, 80.0)) == "south")
	check("imán norte", MAP.magnet_direction(Vector2(0.0, -80.0)) == "north")
	check("sin imán en la zona muerta", MAP.magnet_direction(Vector2(10.0, 10.0)) == "")
	check("drag_direction usa el centro del nodo",
		MAP.drag_direction(Vector2(100.0, 100.0), Vector2(180.0, 108.0)) == "east")
	check("hit_node encuentra y descarta",
		MAP.hit_node(Vector2(by_id.n.center), nodes) != null
		and MAP.hit_node(Vector2(0.0, 0.0), nodes) == null)

	# --- Menú contextual -----------------------------------------------------
	var menu_actions = [
		{"id": "use_as_screen", "label": "Ver su escritorio aquí", "enabled": true, "reason": "", "plan": null},
		{"id": "share_my_screen", "label": "Extender mi escritorio a él", "enabled": false,
			"reason": "gvd no disponible en este equipo", "plan": null},
	]
	var menu = MAP.neighbor_menu({"id": "h1"}, menu_actions, "east", false)
	var labels = []
	var kinds = []
	for it in menu:
		kinds.append(String(it.get("kind", "")))
		if String(it.get("kind", "")) != "separator":
			labels.append(String(it.get("label", "")))
	check("menú traduce acciones", labels.has("Ver su escritorio aquí")
		and labels.has("Extender mi escritorio a él"))
	check("menú sin edición de posición",
		not labels.has("Colocar al Norte") and not labels.has("Colocar al Sur")
		and not labels.has("Colocar al Este") and not labels.has("Colocar al Oeste")
		and not labels.has("Quitar de la disposición"))
	var menu_clean = true
	for it in menu:
		if MAP.has_internal_terms(String(it.get("label", ""))) or MAP.has_internal_terms(String(it.get("reason", ""))):
			menu_clean = false
	check("menú sin vocabulario interno", menu_clean)
	var disabled_item = null
	for it in menu:
		if String(it.get("id", "")) == "share_my_screen":
			disabled_item = it
	check("acción no disponible con razón humana",
		not bool(disabled_item.enabled) and String(disabled_item.reason) == "no tiene el receptor de pantalla")
	var debug_menu = MAP.neighbor_menu({"id": "h1", "capabilities": {"gvd": {}}}, [], "none", true)
	var has_debug = false
	for it in debug_menu:
		if String(it.get("kind", "")) == "debug":
			has_debug = true
	check("ítems de depuración sólo con GDTK_DEBUG", has_debug)
	var plain_menu = MAP.neighbor_menu({"id": "h1"}, [], "none", false)
	var plain_debug = false
	for it in plain_menu:
		if String(it.get("kind", "")) == "debug":
			plain_debug = true
	check("sin depuración por defecto", not plain_debug)

	# Nombre de peer seguro para el layout.
	check("safe_peer limpia espacios", MAP.safe_peer("Tengu Uno") == "Tengu_Uno")
	check("safe_peer cae al fallback", MAP.safe_peer("..") == "peer")
	check("safe_peer conserva válidos", MAP.safe_peer("tengu.local") == "tengu.local")

	# --- APIs puras conservadas (acciones, directions, hosts) -----------------
	var local = ui._local_context()
	check("contexto local con HOME", local.has("home"))
	if local.has("gvd_path"):
		check("ruta del receptor existe en disco", File.new().file_exists(local.gvd_path))
	else:
		check("sin ruta del receptor si no existe el candidato", true)

	var host = {"id": "h1", "hid": "h1", "label": "Tengu", "kind": "laptop", "state": "visto",
		"degraded": false, "capabilities": {"gvd": {"txt": {"role": "recv", "state": "ready"},
		"address": "192.168.1.20", "host": "tengu.local", "port": 5600}}}
	var actions = ui._host_actions(host)
	check("host recv produce acción de pantalla", _has(actions, "use_as_screen"))

	var tooltip = ui._host_tooltip(host)
	check("tooltip con nombre y estado humano", tooltip.find("Tengu") >= 0 and tooltip.find("a la vista") >= 0)
	check("tooltip sin vocabulario interno", not MAP.has_internal_terms(tooltip))

	var icon = ui._host_icon(host)
	var icon_file = "res://icons/" + icon + ".png"
	if not File.new().file_exists(icon_file):
		icon_file = "res://icons/" + icon + ".svg"
	check("icono de host resuelto a un asset existente", File.new().file_exists(icon_file))
	check("laptop mapea al ícono de laptop", icon == "np/device-laptop")
	check("tablet mapea al ícono de tablet",
		ui._host_icon({"kind": "tablet", "icon": "tablet"}) == "np/device-tablet")
	check("kind desconocido cae al respaldo",
		ui._host_icon({"kind": "unknown", "icon": ""}) == "sugar/network-wired")

	var hosts = [host]
	check("_host_by_id encuentra y descarta", ui._host_by_id(hosts, "h1") != null
		and ui._host_by_id(hosts, "nope") == null and ui._host_by_id(hosts, "") == null)

	var named = {"id": "h9", "label": "tengu.local", "kind": "laptop", "degraded": false,
		"capabilities": {"gvd": {"txt": {"name": "Tengu", "role": "recv"}},
		"deskflow": {"txt": {"name": "Tengu", "role": "server"}}}}
	check("host_label prefiere el name del servicio", ui.host_label(named) == "Tengu")
	var unnamed = {"id": "dns-123", "label": "vecino", "capabilities": {}}
	check("host_label cae al label", ui.host_label(unnamed) == "vecino")
	var bare = {"id": "solo-id"}
	check("host_label cae al id", ui.host_label(bare) == "solo-id")

	# --- Compás de dirección (modelo puro conservado) ------------------------
	check("sin dirección por defecto", ui.compass_state("h1") == "sin_direccion")
	check("dirección ausente es none", ui.compass_direction("h1") == "none")
	check("badge sin dirección no vacío", ui.compass_badge("h1") == "sin dirección")

	ui.directions["h1"] = {"direction": "east", "confirm": "proposed"}
	check("entry proposed -> propuesta", ui.compass_state("h1") == "propuesta")
	check("compass_direction lee east", ui.compass_direction("h1") == "east")

	ui.directions["h1"] = {"direction": "east", "confirm": "confirmed"}
	check("entry confirmed -> confirmada", ui.compass_state("h1") == "confirmada")

	ui.direction_conflicts = [{"direction": "east", "hids": ["h1"]}]
	check("conflicto vence sobre confirmada", ui.compass_state("h1") == "conflicto")
	ui.direction_conflicts = []

	ui.directions["h1"] = {"direction": "diagonal", "confirm": "confirmed"}
	check("dirección inválida -> sin_direccion", ui.compass_state("h1") == "sin_direccion")
	ui.directions.erase("h1")

	# _select_direction conserva la propuesta sin confirmar (API previa).
	ui._select_direction("h2", "west")
	check("_select_direction guarda propuesta", ui.directions.has("h2")
		and ui.directions["h2"].direction == "west"
		and ui.directions["h2"].confirm == "unconfirmed")
	ui._select_direction("h2", "none")
	check("_select_direction none borra la entrada", not ui.directions.has("h2"))

	# _apply_direction (imán/menú) guarda confirmada y arma el link del layout.
	ui.model = null
	ui._apply_direction("h1", "east")
	check("_apply_direction guarda confirmada", ui.directions.has("h1")
		and ui.directions["h1"].direction == "east"
		and ui.directions["h1"].confirm == "confirmed")
	var links = ui._layout_links_for("h1", "east")
	check("link de layout con peer", links.size() == 1 and links[0].direction == "east"
		and links[0].host == "h1" and links[0].peer != "")
	ui._apply_direction("h1", "none")
	check("_apply_direction none borra", not ui.directions.has("h1"))
	var remove_links = ui._layout_links_for("h1", "none")
	check("link de quitar lleva direction none", remove_links.size() == 1
		and remove_links[0].direction == "none" and remove_links[0].host == "h1")

	# El shell es el único que persiste: doble que registra el layout aplicado.
	var rec_shell = ShellRecorder.new()
	ui.shell = rec_shell
	ui.directions.erase("h1")
	ui._apply_direction("h1", "west")
	check("_apply_direction delega en el shell", rec_shell.last_links.size() == 1
		and rec_shell.last_links[0].direction == "west")
	ui.shell = null

	# _host_actions mezcla la dirección en el contexto local (doble de prueba).
	ui.directions["h1"] = {"direction": "east", "confirm": "confirmed"}
	var rec = Recorder.new()
	ui._actions = rec
	ui._host_actions(host)
	check("contexto lleva direction", rec.last_local.get("direction", "") == "east")
	check("contexto lleva direction_confirm",
		rec.last_local.get("direction_confirm", "") == "confirmed")
	ui.direction_conflicts = [{"direction": "east", "hids": ["h1"]}]
	ui._host_actions(host)
	check("contexto lleva direction_conflict",
		bool(rec.last_local.get("direction_conflict", false)))
	ui.direction_conflicts = []
	ui._actions = null
	ui.directions.erase("h1")

	# --- Menú de la vista (instancia, sin render) ----------------------------
	ui._open_menu(host, Vector2(100, 100))
	check("abrir menú arma filas", not ui._menu_rows.empty() and ui._menu_host != null)
	check("menú dentro del viewport", ui._menu_rect.position.x >= 0.0 and ui._menu_rect.position.y >= 0.0)
	ui._close_menu()
	check("cerrar menú limpia el estado", ui._menu_host == null and ui._menu_rows.empty())

	# Host degradado (sin id confiable): la acción aparece pero no habilitable.
	var loose = {"id": "degraded:x", "label": "Suelto", "kind": "unknown", "state": "visto",
		"degraded": true, "capabilities": {"gvd": {"txt": {"role": "recv", "state": "ready"},
		"address": "10.0.0.9", "port": 5600}}}
	var loose_actions = ui._host_actions(loose)
	check("degradado no confiable", loose_actions.size() == 1 and not loose_actions[0].enabled)

	ui.free()
	OS.exit_code = 1 if failed > 0 else 0
	quit()


# Doble de prueba de neighborhood_actions.gd: registra el contexto local recibido.
class Recorder:
	extends Reference
	var last_local = {}
	func gvd_path_candidates(_home = "", _gdtk_home = ""):
		return []
	func resolve_gvd_path(_candidates, _exists = null):
		return ""
	func host_actions(_host, local = {}):
		last_local = local
		return []
	func format_command(_plan):
		return ""


# Doble del shell: registra el payload de apply_deskflow_layout.
class ShellRecorder:
	extends Reference
	var last_links = []
	func deskflow_server_available():
		return false
	func apply_deskflow_layout(links):
		last_links = links
