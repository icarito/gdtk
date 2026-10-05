extends SceneTree

# Autoprueba del modelo puro del layout de salidas (shell/output_layout.gd,
# Fase B de SPEC-embedded-multi-output.md). Sin render, sin I/O, sin procesos.
# Correr:
#   <binario dev> --no-window --path shell -s $PWD/tests/output_layout_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var L = load("res://output_layout.gd")
	check("output_layout.gd carga", L != null)

	# --- Descriptor primary ---------------------------------------------------
	var prim = L.default_primary()
	check("descriptor primary completo",
		String(prim.id) == "primary" and bool(prim.primary) and bool(prim.enabled)
		and String(prim.kind) == "physical" and String(prim.target) == "main_viewport"
		and prim.rect == Rect2(0, 0, 1920, 1080))
	var empty = L.normalize_layout({})
	check("layout vacio crea exactamente una primary",
		L.primary_count(empty) == 1 and L.primary_id(empty) == "primary"
		and L.output_count(empty) == 1)
	var custom = L.normalize_layout({"outputs": [L.default_primary(Rect2(0, 0, 2560, 1440))]})
	check("primary conserva rect custom", L.primary_output(custom).rect == Rect2(0, 0, 2560, 1440))

	# --- Validacion de exactamente una primary --------------------------------
	var two_primary = {"outputs": [
		{"id": "primary", "kind": "physical", "rect": Rect2(0, 0, 100, 100), "primary": true},
		{"id": "remote:a", "kind": "remote", "rect": Rect2(0, 100, 100, 100),
			"primary": true, "direction": "south"},
	]}
	check("dos primary: validate_layout reporta error", not L.validate_layout(two_primary).empty())
	var fixed = L.normalize_layout(two_primary)
	check("normalize deja exactamente una primary",
		L.primary_count(fixed) == 1 and L.output_count(fixed) == 2)
	var no_primary = {"outputs": [
		{"id": "remote:a", "kind": "remote", "rect": Rect2(0, 100, 100, 100), "direction": "south"},
	]}
	check("sin primary: validate_layout reporta error", not L.validate_layout(no_primary).empty())
	check("sin primary: normalize inyecta la default",
		L.primary_count(L.normalize_layout(no_primary)) == 1)

	# --- Rechazo de ids / rects / direcciones invalidos -----------------------
	check("id invalido rechazado",
		L.sanitize_output({"id": "bogus", "rect": Rect2(0, 0, 10, 10)}) == null)
	check("id remoto sin hid rechazado",
		L.sanitize_output({"id": "remote:", "rect": Rect2(0, 0, 10, 10)}) == null)
	check("rect de tamano nulo rechazado",
		L.sanitize_output({"id": "remote:a", "rect": Rect2(0, 0, 0, 10)}) == null)
	check("rect escala invalida rechazada",
		L.sanitize_output({"id": "remote:a", "rect": Rect2(0, 0, 10, 10), "scale": 0.0}) == null)
	check("direccion invalida rechazada",
		L.sanitize_output({"id": "remote:a", "rect": Rect2(0, 0, 10, 10),
			"direction": "diagonal"}) == null)
	check("direccion cardinal valida aceptada",
		L.sanitize_output({"id": "remote:a", "rect": Rect2(0, 0, 10, 10),
			"direction": "east"}) != null)

	# --- Add N/S/E/O sin solapes ----------------------------------------------
	var lay = L.normalize_layout({})
	for d in L.DIRECTIONS:
		var res = L.add_output(lay, {"id": "remote:" + d, "kind": "remote",
			"rect": Rect2(0, 0, 1280, 800)}, d)
		check("add %s ok" % d, bool(res.ok))
		lay = res.layout
	check("cuatro secundarias ancladas", L.output_count(lay) == 5)
	check("sin solapes entre salidas", not L.any_overlap(lay.outputs))
	check("validate_layout sano", L.validate_layout(lay).empty())
	check("north pegado al borde superior",
		L.output_by_id(lay, "remote:north").rect == Rect2(0, -800, 1280, 800))
	check("south pegado al borde inferior",
		L.output_by_id(lay, "remote:south").rect == Rect2(0, 1080, 1280, 800))
	check("east pegado al borde derecho",
		L.output_by_id(lay, "remote:east").rect == Rect2(1920, 0, 1280, 800))
	check("west pegado al borde izquierdo",
		L.output_by_id(lay, "remote:west").rect == Rect2(-1280, 0, 1280, 800))

	# Segunda salida al mismo borde: se encadena, sin solape.
	var chain = L.add_output(lay, {"id": "remote:east2", "rect": Rect2(0, 0, 1280, 800)}, "east")
	check("segunda al este se encadena", bool(chain.ok))
	check("cadena este sin solape",
		L.output_by_id(chain.layout, "remote:east2").rect.position.x == 3200.0
		and not L.any_overlap(chain.layout.outputs))

	# Direccion desde el propio descriptor (sin tercer argumento).
	var from_desc = L.add_output(L.normalize_layout({}),
		{"id": "remote:d", "rect": Rect2(0, 0, 100, 100), "direction": "east"})
	check("direccion tomada del descriptor",
		bool(from_desc.ok)
		and L.output_by_id(from_desc.layout, "remote:d").rect.position == Vector2(1920, 0))

	# Rechazos de add: id duplicado, direccion invalida, rect invalido, id invalido.
	var dup = L.add_output(lay, {"id": "remote:east", "rect": Rect2(0, 0, 10, 10)}, "east")
	check("add duplicado rechazado", not bool(dup.ok) and L.output_count(dup.layout) == 5)
	check("add direccion invalida rechazado",
		not bool(L.add_output(lay, {"id": "remote:x", "rect": Rect2(0, 0, 10, 10)},
			"diagonal").ok))
	check("add rect invalido rechazado",
		not bool(L.add_output(lay, {"id": "remote:x", "rect": Rect2(0, 0, 0, 0)}, "east").ok))
	check("add id invalido rechazado",
		not bool(L.add_output(lay, "bogus", "east").ok))

	# --- output en un punto y conversion global/local -------------------------
	var east_o = L.output_by_id(lay, "remote:east")
	check("output_at en la principal", L.output_at(lay, Vector2(10, 10)) == "primary")
	check("output_at en remoto", L.output_at(lay, Vector2(2000, 100)) == "remote:east")
	check("output_at en hueco devuelve vacio", L.output_at(lay, Vector2(9000, 9000)) == "")
	check("borde inferior incluido en contains",
		L.contains(east_o, Vector2(1920, 0)) and not L.contains(east_o, Vector2(3200, 0)))
	check("global -> local", L.global_to_local(east_o, Vector2(2000, 100)) == Vector2(80, 100))
	check("local -> global", L.local_to_global(east_o, Vector2(80, 100)) == Vector2(2000, 100))

	# --- Cruce de borde -------------------------------------------------------
	var ce = L.cross(lay, "primary", Vector2(1919, 400), Vector2(5, 0))
	check("cruce al este", bool(ce.crossed) and String(ce.to) == "remote:east")
	check("local correcta en el destino", ce.local == Vector2(4, 400))
	check("sin cruce dentro de la salida",
		not bool(L.cross(lay, "primary", Vector2(100, 100), Vector2(5, 0)).crossed))
	check("cruce al oeste",
		bool(L.cross(lay, "primary", Vector2(1, 400), Vector2(-5, 0)).crossed)
		and String(L.cross(lay, "primary", Vector2(1, 400), Vector2(-5, 0)).to) == "remote:west")
	check("cruce al norte",
		bool(L.cross(lay, "primary", Vector2(400, 1), Vector2(0, -5)).crossed)
		and String(L.cross(lay, "primary", Vector2(400, 1), Vector2(0, -5)).to) == "remote:north")
	check("cruce al sur",
		bool(L.cross(lay, "primary", Vector2(400, 1079), Vector2(0, 5)).crossed)
		and String(L.cross(lay, "primary", Vector2(400, 1079), Vector2(0, 5)).to) == "remote:south")

	# --- Asignar / mover ventanas entre salidas -------------------------------
	var asg = L.assign_window(lay, "app:1")
	check("assign sin destino cae a primary",
		bool(asg.ok) and L.window_output(asg.layout, "app:1") == "primary")
	lay = asg.layout
	var mv = L.move_window(lay, "app:1", "remote:east")
	check("move a salida remota",
		bool(mv.ok) and L.window_output(mv.layout, "app:1") == "remote:east")
	lay = mv.layout
	check("windows_of devuelve la ventana",
		L.windows_of(lay, "remote:east") == ["app:1"])
	check("move a output inexistente rechazado", not bool(L.move_window(lay, "app:1", "remote:nope").ok))
	check("move ventana inexistente rechazado", not bool(L.move_window(lay, "nope", "primary").ok))
	check("assign window id invalido rechazado", not bool(L.assign_window(lay, "").ok))
	var back = L.move_window(lay, "app:1", "primary")
	check("move de vuelta a primary",
		bool(back.ok) and L.window_output(back.layout, "app:1") == "primary")

	# Deshabilitado: assign cae a primary, move se rechaza.
	var disabled = L.normalize_layout({"outputs": [
		L.default_primary(),
		{"id": "remote:d", "kind": "remote", "rect": Rect2(1920, 0, 800, 600),
			"primary": false, "enabled": false, "direction": "east"},
	]})
	var d_asg = L.assign_window(disabled, "x", "remote:d")
	check("assign a deshabilitado cae a primary", L.window_output(d_asg.layout, "x") == "primary")
	check("move a deshabilitado rechazado", not bool(L.move_window(d_asg.layout, "x", "remote:d").ok))

	# --- Retirada devuelve ventanas a primary ---------------------------------
	var rl = L.normalize_layout({})
	rl = L.add_output(rl, {"id": "remote:r", "rect": Rect2(0, 0, 800, 600)}, "east").layout
	rl = L.assign_window(rl, "w-a", "remote:r").layout
	rl = L.assign_window(rl, "w-b", "remote:r").layout
	rl = L.assign_window(rl, "w-c", "primary").layout
	check("dos ventanas en el remoto", L.windows_of(rl, "remote:r").size() == 2)
	var rem = L.remove_output(rl, "remote:r")
	check("retirar remoto ok", bool(rem.ok) and L.output_count(rem.layout) == 1)
	check("todas las ventanas vuelven a primary",
		L.window_output(rem.layout, "w-a") == "primary"
		and L.window_output(rem.layout, "w-b") == "primary"
		and L.window_output(rem.layout, "w-c") == "primary")
	check("moved reporta las reasignadas", rem.moved.size() == 2)
	check("el output ya no existe", L.output_by_id(rem.layout, "remote:r") == null)
	check("retirar la principal rechazado", not bool(L.remove_output(rl, "primary").ok))
	check("retirar inexistente rechazado", not bool(L.remove_output(rl, "remote:nope").ok))

	# --- Envolvente y span (SPEC-physical-multi-monitor.md) -------------------
	var sp = L.normalize_layout({"outputs": [
		L.default_primary(Rect2(0, 0, 1920, 1080)),
		{"id": "physical:DP-1", "kind": "physical", "rect": Rect2(1920, 0, 1280, 800),
			"primary": false, "target": "span"},
	]})
	check("bounding_rect del span", L.bounding_rect(sp) == Rect2(0, 0, 3200, 1080))
	check("bounding_rect con una sola salida",
		L.bounding_rect(L.normalize_layout({})) == Rect2(0, 0, 1920, 1080))
	var sr = L.span_rects(sp)
	check("span_rects: principal en (0,0)",
		sr.size() == 2 and sr[0].id == "primary" and sr[0].rect == Rect2(0, 0, 1920, 1080))
	check("span_rects: secundaria a la derecha",
		sr[1].id == "physical:DP-1" and sr[1].rect == Rect2(1920, 0, 1280, 800))

	# --- Reconcile de descubrimiento fisico ----------------------------------
	var base = L.normalize_layout({})
	var rec = L.reconcile_outputs(base, [
		{"id": "primary", "kind": "physical", "rect": Rect2(0, 0, 1920, 1080), "primary": true},
		{"id": "physical:DP-1", "kind": "physical", "rect": Rect2(1920, 0, 1280, 800),
			"primary": false, "target": "span"},
	])
	check("reconcile agrega la secundaria",
		bool(rec.ok) and rec.added == ["physical:DP-1"] and L.output_count(rec.layout) == 2)
	check("reconcile conserva una sola primary", L.primary_count(rec.layout) == 1)
	check("reconcile sin remociones", rec.removed.empty() and rec.moved.empty())
	var rl2 = L.assign_window(rec.layout, "w-1", "physical:DP-1").layout
	check("ventana asignada a la fisica",
		L.window_output(rl2, "w-1") == "physical:DP-1")
	# Cambio de geometria de una salida existente.
	var rec2 = L.reconcile_outputs(rl2, [
		{"id": "primary", "kind": "physical", "rect": Rect2(0, 0, 1920, 1080), "primary": true},
		{"id": "physical:DP-1", "kind": "physical", "rect": Rect2(1920, 0, 1024, 768),
			"primary": false, "target": "span"},
	])
	check("reconcile reporta cambio de geometria",
		bool(rec2.ok) and rec2.changed == ["physical:DP-1"]
		and L.window_output(rec2.layout, "w-1") == "physical:DP-1")
	# Desenchufar la fisica devuelve su ventana a la principal.
	var rec3 = L.reconcile_outputs(rec2.layout, [
		{"id": "primary", "kind": "physical", "rect": Rect2(0, 0, 1920, 1080), "primary": true},
	])
	check("reconcile retira la ausente",
		bool(rec3.ok) and rec3.removed == ["physical:DP-1"] and L.output_count(rec3.layout) == 1)
	check("reconcile devuelve la ventana a primary",
		L.window_output(rec3.layout, "w-1") == "primary" and rec3.moved == ["w-1"])
	check("reconcile con descriptor invalido no rompe",
		not bool(L.reconcile_outputs(base, "bogus").ok))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
