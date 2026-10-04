extends SceneTree

# Autoprueba de la lógica nueva del Hogar/anillo y del Frame que no necesita
# compositor: entradas del anillo (sólo lectura: activas + pines del Frame), layout
# animado, orden unificado de bloques de barra y animación de asentado.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/ring_frame_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	# XDG_CONFIG_HOME temporal para no tocar los archivos reales del usuario.
	var base = OS.get_user_data_dir() + "/ringframe_test"
	Directory.new().make_dir_recursive(base)
	OS.set_environment("XDG_CONFIG_HOME", base)

	var shell = load("res://shell.gd").new()
	var frame = load("res://frame.gd").new()
	shell.frame = frame   # en producción lo setea _ready
	frame.shell = shell   # onready get_parent() fuera del árbol

	# 1) Salir ya no es actividad del anillo.
	var names = []
	for a in shell.ACTIVITIES:
		names.append(a.name)
	check("ACTIVITIES sin Salir: " + str(names), not names.has("Salir"))

	# 2) Layout orbital generalizado (actividades + favoritos).
	var lay = shell._orbit_layout(Vector2(1024, 600), 9)
	check("_orbit_layout(9) devuelve 9", lay.size() == 9)
	var in_bounds = true
	for p in lay:
		if p.x < 0 or p.x > 1024 or p.y < 80 or p.y > 600:
			in_bounds = false
	check("posiciones dentro del lienzo", in_bounds)
	check("_home_layout coincide con ACTIVITIES", shell._home_layout(Vector2(1024, 600)).size() == shell.ACTIVITIES.size())

	# 3) Entradas del anillo DINÁMICAS y de sólo lectura: las cerradas no aparecen;
	# las activas sí; los pines del Frame se resuelven como favoritos.
	var closed = shell._ring_entries()
	var closed_names = []
	for e in closed:
		closed_names.append(e.name)
	check("anillo sin actividades cerradas", not closed_names.has("Terminal") and not closed_names.has("Configuración"))
	shell.script_instances["Prueba"] = {}
	shell.ACTIVITIES.append({"name": "Prueba", "script": "res://x.gd", "dynamic": true})
	shell._touch_mru("Prueba")
	var entries = shell._ring_entries()
	var has_open = false
	for e in entries:
		if e.kind == "activity" and e.name == "Prueba":
			has_open = true
	check("anillo muestra la actividad abierta", has_open)
	check("MRU ordena la más reciente primero", shell._mru_before({"name": "Prueba"}, {"name": "Terminal"}))
	shell.script_instances.erase("Prueba")
	shell.ACTIVITIES.pop_back()
	# Un pin del Frame (sin app resuelta) igual aparece en el anillo, sin poder editarse.
	frame.bar_order = {"top": [], "dock": ["p:zzz-noexiste.desktop"]}
	frame._sync_pins()
	var fe = shell._ring_entries()
	var has_pin = false
	for e in fe:
		if e.kind == "favorite" and e.id == "zzz-noexiste.desktop":
			has_pin = true
	check("pin del Frame aparece en el anillo", has_pin)
	check("pinned_ids devuelve el pin", frame.pinned_ids() == ["zzz-noexiste.desktop"])

	# 4) Tokens y orden unificado: tokens pin/applet, sync de pines y mover/quitar.
	check("token pin", frame._tok_pin("x.desktop") == "p:x.desktop")
	check("token applet", frame._tok_applet("reloj") == "a:reloj")
	check("_tok_kind / _tok_id", frame._tok_kind("p:x") == "p" and frame._tok_id("p:x") == "x")
	check("token válido", frame._maybe_order_token("a:reloj") and not frame._maybe_order_token("z:reloj"))
	frame.bar_order = {"top": ["p:a.desktop", "a:reloj"], "dock": ["p:b.desktop", "a:recursos"]}
	frame._sync_pins()
	check("_sync_pins top", frame.pinned_top == ["a.desktop"])
	check("_sync_pins dock", frame.pinned_dock == ["b.desktop"])
	frame._order_remove("a:reloj")
	check("_order_remove saca el applet", not frame.bar_order["top"].has("a:reloj"))
	frame._order_insert("dock", "a:reloj", 1)
	check("_order_insert intercala", frame.bar_order["dock"] == ["p:b.desktop", "a:reloj", "a:recursos"])

	# 5) Inserción con hueco (applets y pines comparten el mismo helper).
	check("order gap slot 0", frame._order_with_gap(["a", "b", "c"], "a", 0) == ["a", "b", "c"])
	check("order gap slot 1", frame._order_with_gap(["a", "b", "c"], "a", 1) == ["b", "a", "c"])
	check("order gap slot fin", frame._order_with_gap(["a", "b", "c"], "a", 3) == ["b", "c", "a"])
	check("order gap item externo", frame._order_with_gap(["a", "b"], "z", 1) == ["a", "z", "b"])

	# 6) Slot de la barra: grilla de celdas fijas (origen + ancho), saltando el
	# arrastrado. Pines y applets comparten el mismo cálculo (orden unificado).
	frame.bar_order = {"top": ["p:p1", "p:p2", "a:reloj"], "dock": []}
	frame.bar_cell = {"top": 90.0, "dock": 0.0}
	frame.bar_origin = {"top": 100.0, "dock": 0.0}
	frame.bar_layout = {"top": [
		{"kind": "p", "id": "p1", "tok": "p:p1", "x": 100, "y": 0, "w": 80, "h": 80, "rect": Rect2(100, 0, 80, 80)},
		{"kind": "p", "id": "p2", "tok": "p:p2", "x": 190, "y": 0, "w": 80, "h": 80, "rect": Rect2(190, 0, 80, 80)},
		{"kind": "a", "id": "reloj", "tok": "a:reloj", "x": 280, "y": 0, "w": 120, "h": 80, "rect": Rect2(280, 0, 120, 80)}],
		"dock": []}
	check("_zone_slot top celda 0", frame._zone_slot("top", 100, "p:p1") == 0)
	check("_zone_slot top celda 1", frame._zone_slot("top", 250, "p:p1") == 1)
	check("_zone_slot top celda 2 (cuenta pin y applet)", frame._zone_slot("top", 320, "") == 2)
	check("_slot_index coincide con _zone_slot",
		frame._slot_index("top", 250, "p:p1", frame.bar_layout["top"]) == 1)

	# 6b) DockApp de ventanas ("w:windows"): token válido, span dinámico según n y
	# bloque de clip cuando no hay ninguna. Es un bloque más: los pines se pueden
	# colocar antes O después de él (cualquier slot), no sólo a su izquierda.
	check("token ventanas válido", frame._maybe_order_token("w:windows"))
	check("token ventanas ajeno se descarta", not frame._maybe_order_token("w:otro"))
	check("DockApp vacío = un slot", frame._window_block_width(80.0, []) == 80.0)
	check("DockApp con 3 ventanas = 3 slots",
		frame._window_block_width(80.0, [{"screen": 0}, {"screen": 0}, {"screen": 0}]) == 240.0)
	check("DockApp fusionado pega las ventanas",
		frame._window_block_width(80.0, [{"screen": 2}, {"screen": 2}]) == 160.0)
	frame.bar_order = {"top": ["p:a.desktop", "w:windows", "a:reloj"], "dock": []}
	frame._sync_pins()
	check("_sync_pins ignora el DockApp de ventanas", frame.pinned_top == ["a.desktop"])
	frame._order_remove("w:windows")
	check("_order_remove saca el DockApp de ventanas", not frame.bar_order["top"].has("w:windows"))
	frame.bar_order = {"top": ["p:p1", "w:windows"], "dock": []}
	frame.bar_cell = {"top": 80.0, "dock": 0.0}
	frame.bar_origin = {"top": 0.0, "dock": 0.0}
	frame.bar_layout = {"top": [
		{"kind": "p", "id": "p1", "tok": "p:p1", "x": 0, "y": 0, "w": 80, "h": 80, "rect": Rect2(0, 0, 80, 80)},
		{"kind": "w", "id": "windows", "tok": "w:windows", "x": 80, "y": 0, "w": 160, "h": 80, "rect": Rect2(80, 0, 160, 80)}],
		"dock": []}
	# El DockApp vale UNA celda (su tramo se dibuja sobre los huecos siguientes).
	check("celda libre bajo el tramo del DockApp queda a su derecha", frame._zone_slot("top", 170, "p:p1") == 2)
	# Slots fijos: p1 deja su celda 0 vacía; el DockApp sigue en la celda 1.
	check("soltar en su propia celda (vacía) la conserva", frame._zone_slot("top", 40, "p:p1") == 0)
	check("soltar sobre el DockApp cae en su celda (lo corre)", frame._zone_slot("top", 100, "p:p1") == 1)
	check("slot detrás del pin y del DockApp", frame._zone_slot("top", 300, "") == 3)
	# Cargar (sin archivo o con archivo previo) deja exactamente un token de ventanas
	# en la barra superior; así las ventanas nunca desaparecen del Frame.
	frame._load_applets()
	check("_load_applets garantiza el DockApp de ventanas",
		frame.bar_order["top"].count("w:windows") == 1)

	# 6c) Huecos: soltar lejos deja slots vacíos ("") persistidos, así el bloque
	# respeta la posición elegida y no se compacta a la izquierda.
	check("_order_with_slots abre huecos", frame._order_with_slots(["a", "b"], "a", 3) == ["", "b", "", "a"])
	check("_order_with_slots ocupa hueco existente", frame._order_with_slots(["a", "", "c"], "a", 1) == ["", "a", "c"])
	frame.bar_order = {"top": ["p:a"], "dock": []}
	frame._order_insert("top", "p:b", 3)
	check("_order_insert abre huecos", frame.bar_order["top"] == ["p:a", "", "", "p:b"])
	var cfg = File.new()
	Directory.new().make_dir_recursive(frame._applets_path().get_base_dir())
	cfg.open(frame._applets_path(), File.WRITE)
	cfg.store_string(JSON.print({"order": {"top": ["p:x.desktop", "", "w:windows"], "dock": []}}))
	cfg.close()
	frame._load_applets()
	check("_load_applets conserva los huecos",
		frame.bar_order["top"] == ["p:x.desktop", "", "w:windows"])

	# 7) Animación de la barra: arranca en el destino, retarget con ease-out y asienta.
	check("_bar_x primera vez = destino", frame._bar_x("t", 100.0, 1000) == 100.0)
	frame._bar_x("t", 200.0, 1000)  # arranca el retarget
	var bx = frame._bar_x("t", 200.0, 1000 + shell.LAYOUT_MS / 2)
	check("_bar_x interpola hacia el destino", bx > 100.0 and bx < 200.0)
	check("_bar_x al final = destino", frame._bar_x("t", 200.0, 1000 + shell.LAYOUT_MS + 1) == 200.0)
	frame._bar_set("t", 50.0)
	check("_bar_x arranca desde el cursor", frame._bar_x("t", 200.0, 5000) == 50.0)
	check("_bar_x asienta en el destino", frame._bar_x("t", 200.0, 5000 + shell.LAYOUT_MS + 1) == 200.0)

	# 8) Animación del layout del anillo: ease-out y retarget.
	shell.ring_pos = {}
	shell.ring_anim = {}
	shell.ring_intro = {}
	var target = Vector2(100, 200)
	var p0 = shell._ring_show("X", target, 1000)
	check("entrada nueva aparece en destino", p0 == target and shell.ring_intro.has("X"))
	var target2 = Vector2(300, 200)
	shell._ring_show("X", target2, 1000)  # arranca el retarget
	var mid = shell._ring_show("X", target2, 1000 + shell.LAYOUT_MS / 2)
	check("animación en curso entre from y to", mid.x > 100 and mid.x < 300)
	var endv = shell._ring_show("X", target2, 1000 + shell.LAYOUT_MS + 1)
	check("al terminar llega al objetivo", (endv - target2).length() < 0.5)
	check("ease_out acota 0..1", shell._ease_out(-1.0) == 0.0 and shell._ease_out(2.0) == 1.0)
	shell._ring_prune([])
	check("_ring_prune limpia estado", shell.ring_pos.empty() and shell.ring_intro.empty())

	frame.free()
	shell.free()
	print("RING_FRAME_TEST_" + ("OK" if failed == 0 else "FAIL"))
	OS.exit_code = 1 if failed > 0 else 0
	quit()
