extends SceneTree

# Autoprueba K10b del modelo puro de bloques "Compartido" del Frame: tipos,
# estados, vocabulario humano, menú contextual, desaparición al cortar y lectura
# de snapshots cacheados. No renderiza, no ejecuta procesos ni toca el disco.
# Correr:
#   godot --no-window --path shell -s $PWD/tests/shared_block_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _ids(blocks):
	var out = []
	for b in blocks:
		out.append(String(b.id))
	return out


func _init():
	var SB = load("res://shared_block.gd")

	# --- Vocabulario humano --------------------------------------------------
	check("tipo pantalla", SB.type_label("screen") == "pantalla")
	check("tipo teclado y mouse", SB.type_label("input") == "teclado y mouse")
	check("tipo portapapeles", SB.type_label("clipboard") == "portapapeles")
	check("tipo inválido vacío", SB.type_label("recv") == "")
	check("estado conectando", SB.state_text("starting") == "conectando")
	check("estado activo", SB.state_text("active") == "activo")
	check("estado error", SB.state_text("error") == "error")
	check("valid_type sólo tipos reales", SB.valid_type("screen") and not SB.valid_type("server"))
	check("valid_state sólo estados visibles",
		SB.valid_state("starting") and SB.valid_state("active") and SB.valid_state("error")
		and not SB.valid_state("idle"))

	check("título con equipo y tipo",
		SB.title_for("Tengu", "screen") == "Tengu · pantalla")
	check("título sin equipo cae al tipo", SB.title_for("", "input") == "teclado y mouse")
	check("detalle humano",
		SB.detail_for("Tengu", "screen", "active", "") == "Tengu · pantalla · activo")
	check("detalle con motivo",
		SB.detail_for("Tengu", "input", "error", "se cortó") == "Tengu · teclado y mouse · error — se cortó")

	# Un motivo con jerga se sustituye: nunca se filtra un nombre interno.
	check("motivo sin jerga", SB.safe_reason("no se pudo lanzar gvd") == "error de conexión")
	check("motivo limpio se conserva", SB.safe_reason("se cortó la conexión") == "se cortó la conexión")

	# --- build: normalización y descarte -------------------------------------
	var built = SB.build([
		{"host": "h1", "type": "screen", "state": "active", "label": "Tengu"},
		{"host": "h1", "type": "screen", "state": "starting", "label": "Tengu"},
		{"host": "h2", "type": "nope", "state": "active", "label": "X"},
		{"host": "", "type": "input", "state": "active"},
		{"host": "h3", "type": "clipboard", "state": "error", "label": "Ana"},
	])
	check("build descarta duplicados/vacíos/tipo inválido", built.size() == 2)
	check("error sin motivo no es error",
		String(built[1].state) == "active")
	var with_reason = SB.build([
		{"host": "h3", "type": "clipboard", "state": "error", "label": "Ana",
			"reason": "se cortó la conexión"}])
	check("error con motivo se conserva",
		String(with_reason[0].state) == "error" and String(with_reason[0].state_text) == "error")

	# --- from_cache: snapshots cacheados -------------------------------------
	# Sin sesiones -> sin bloques.
	check("sin sesiones no hay bloques",
		SB.from_cache({}, {}, {}, {}, false).empty())

	# Pantalla activa.
	var blocks = SB.from_cache(
		{"h1": "active"}, {"h1": true}, {}, {}, false, {"h1": "Tengu"})
	check("una sesión de pantalla activa", blocks.size() == 1
		and String(blocks[0].type) == "screen" and String(blocks[0].state) == "active")
	check("id estable equipo:tipo", String(blocks[0].id) == "h1:screen")
	check("título del bloque", String(blocks[0].title) == "Tengu · pantalla")

	# Lanzamiento de pantalla en curso -> conectando.
	var starting = SB.from_cache(
		{"h1": "starting"}, {}, {}, {}, false, {"h1": "Tengu"})
	check("pantalla en curso -> conectando", starting.size() == 1
		and String(starting[0].state) == "starting"
		and String(starting[0].state_text) == "conectando")

	# Teclado y mouse: vivo el servicio -> activo; si no, conectando.
	var input_on = SB.from_cache(
		{"h1": "active"}, {}, {"h1": true}, {}, true, {"h1": "Tengu"})
	check("control compartido activo con servicio vivo", input_on.size() == 1
		and String(input_on[0].type) == "input" and String(input_on[0].state) == "active")
	var input_boot = SB.from_cache(
		{"h1": "starting"}, {}, {"h1": true}, {}, false, {"h1": "Tengu"})
	check("control compartido arrancando -> conectando", input_boot.size() == 1
		and String(input_boot[0].state) == "starting")
	# Intención sin servicio y sin arranque: no se finge una sesión.
	check("intención sin servicio no muestra bloque",
		SB.from_cache({"h1": "idle"}, {}, {"h1": true}, {}, false, {"h1": "Tengu"}).empty())

	# Portapapeles.
	var clip = SB.from_cache(
		{"h1": "active"}, {}, {}, {"h1": true}, false, {"h1": "Tengu"})
	check("portapapeles compartido", clip.size() == 1
		and String(clip[0].type) == "clipboard" and String(clip[0].state) == "active")

	# Varios equipos y tipos: orden determinista por equipo y tipo.
	var many = SB.from_cache(
		{"a": "active", "b": "active", "c": "idle"},
		{"a": true, "b": true}, {"a": true, "b": true}, {"a": true},
		true, {"a": "Ana", "b": "Iván"})
	check("un bloque por equipo y tipo", many.size() == 5)
	check("orden determinista", _ids(many) == ["a:screen", "a:input", "a:clipboard",
		"b:screen", "b:input"])

	# Error por host: todos sus bloques pasan a error con motivo humano.
	var err = SB.from_cache(
		{"h1": "active"}, {"h1": true}, {"h1": true}, {}, true, {"h1": "Tengu"},
		{"h1": "no se pudo lanzar deskflow"})
	check("error por host marca sus bloques", err.size() == 2
		and String(err[0].state) == "error" and String(err[1].state) == "error")
	check("motivo saneado en el detalle",
		String(err[0].reason) == "error de conexión"
		and String(err[0].detail).find("error de conexión") >= 0)

	# --- Menú contextual -----------------------------------------------------
	var menu = SB.menu(blocks[0])
	check("menú con Detener y Ver detalles", menu.size() == 2
		and String(menu[0].label) == "Detener" and String(menu[1].label) == "Ver detalles")
	check("menú sin bloques vacío", SB.menu({}).empty())

	# --- Vocabulario: nada visible con jerga ---------------------------------
	var visible = []
	for b in many:
		visible.append(String(b.title))
		visible.append(String(b.detail))
	for m in menu:
		visible.append(String(m.label))
	var clean = true
	for s in visible:
		if SB.MAP.has_internal_terms(s):
			clean = false
	check("cadenas visibles sin vocabulario interno", clean)

	# --- Hit test del layout dibujado ----------------------------------------
	var layout = [{"id": "h1:screen", "x": 10.0, "y": 5.0, "w": 40.0, "h": 40.0},
		{"id": "h1:input", "x": 60.0, "y": 5.0, "w": 40.0, "h": 40.0}]
	check("hit encuentra el bloque",
		SB.hit(Vector2(20.0, 20.0), layout) != null
		and String(SB.hit(Vector2(20.0, 20.0), layout).id) == "h1:screen")
	check("hit fuera no encuentra", SB.hit(Vector2(200.0, 200.0), layout) == null)
	check("block_by_id encuentra y descarta",
		SB.block_by_id(many, "b:input") != null and SB.block_by_id(many, "z:screen") == null)

	# Cortar la sesión: el snapshot vacío hace desaparecer el bloque.
	check("al cortar desaparece",
		SB.from_cache({"h1": "idle"}, {}, {}, {}, false, {"h1": "Tengu"}).empty())

	# --- diagram(): bloque-resumen de la dockapp "Compartiendo" (G5) ---------
	var none = SB.diagram([], [], [])
	check("diagram sin nada vacío", none.empty())

	var d = SB.diagram(
		[{"host": "tengu", "peer_name": "tengu", "type": "screen",
			"side": "south", "state": "active"}],
		[{"peer_name": "ivan", "type": "input", "side": "west", "state": "active"}],
		[])
	check("diagram no vacío", not d.empty())
	check("lado sur con la sesión local", d.sides.south.size() == 1
		and String(d.sides.south[0].origin) == "local"
		and String(d.sides.south[0].type) == "screen")
	check("lado oeste con la remota", d.sides.west.size() == 1
		and String(d.sides.west[0].origin) == "remote"
		and String(d.sides.west[0].type) == "input")
	check("entrada con claves esperadas", d.sides.south[0].has("type")
		and d.sides.south[0].has("peer_name") and d.sides.south[0].has("initial")
		and d.sides.south[0].has("state") and d.sides.south[0].has("origin"))
	check("inicial del equipo", String(d.sides.south[0].initial) == "T")
	check("norte y este vacíos", d.sides.north.empty() and d.sides.east.empty())

	var d_ids = []
	var d_labels = []
	for m in d.menu:
		if String(m.get("kind", "")) == "separator":
			continue
		d_ids.append(String(m.get("id", "")))
		d_labels.append(String(m.get("label", "")))
	check("menú contiene stop:screen:tengu", d_ids.has("stop:screen:tengu"))
	check("menú contiene stop:input:ivan", d_ids.has("stop:input:ivan"))
	check("menú termina con open_group",
		not d.menu.empty() and String(d.menu[d.menu.size() - 1].id) == "open_group"
		and String(d.menu[d.menu.size() - 1].label) == "Abrir Grupo")
	check("menú tiene separador antes de Abrir Grupo",
		d.menu.size() >= 2 and String(d.menu[d.menu.size() - 2].kind) == "separator")

	# Ventanas extendidas: alimentan el menú aunque no haya sesiones.
	var dw = SB.diagram([], [], [
		{"id": "w1", "title": "Pantalla compartida", "peer_name": "tengu", "maximized": false},
		{"id": "w2", "title": "Pantalla compartida", "peer_name": "ivan", "maximized": true},
	])
	check("diagram con ventanas no vacío", not dw.empty())
	var w_ids = []
	var w_by_id = {}
	for m in dw.menu:
		if String(m.get("kind", "")) == "separator":
			continue
		w_ids.append(String(m.get("id", "")))
		w_by_id[String(m.get("id", ""))] = String(m.get("label", ""))
	check("menú ventana mostrar", w_ids.has("win_show:w1")
		and String(w_by_id["win_show:w1"]).find("tengu") >= 0)
	check("menú ventana maximizar/restaurar", w_ids.has("win_max:w1")
		and w_ids.has("win_max:w2")
		and String(w_by_id["win_max:w1"]) == "Maximizar"
		and String(w_by_id["win_max:w2"]) == "Restaurar")
	check("menú ventana cerrar", w_ids.has("win_close:w1") and w_ids.has("win_close:w2"))
	check("sides vacíos sin sesiones", dw.sides.north.empty() and dw.sides.south.empty()
		and dw.sides.east.empty() and dw.sides.west.empty())

	# Una entrada sin lado ubicable no se cuela en el diagrama.
	check("sesión sin lado no se dibuja",
		SB.diagram([{"peer_name": "x", "type": "screen", "state": "active"}], [], []).empty())

	# Vocabulario: ningún texto visible del diagrama filtra nombres internos.
	var d_visible = [String(d.tooltip), String(dw.tooltip)]
	d_visible += d_labels
	for m in dw.menu:
		if String(m.get("kind", "")) != "separator":
			d_visible.append(String(m.get("label", "")))
	var d_clean = true
	for s in d_visible:
		if SB.MAP.has_internal_terms(s):
			d_clean = false
	check("diagram sin vocabulario interno", d_clean)

	# --- radial(): vista radial de la dockapp (N10) ---------------------------
	check("radial sin nada vacío", SB.radial([], [], []).empty())
	var rad = SB.radial(
		[{"host": "tengu", "peer_name": "Tengu", "type": "input", "side": "east", "state": "active"},
		{"host": "tengu", "peer_name": "Tengu", "type": "screen", "side": "east", "state": "starting"}],
		[{"host": "ivan", "peer_name": "Ivan", "type": "input", "side": "west", "state": "active"}],
		[{"id": "w1", "peer_name": "Cupid", "maximized": false}],
		{"ivan": 200.0}, {"capturing": true})
	var by = {}
	for r in rad:
		by[String(r.peer_name)] = r
	check("radial un par por equipo", rad.size() == 3)
	check("radial fusiona pantalla y teclado", by.Tengu.kind == "both"
		and by.Tengu.direction == "out" and by.Tengu.state == "starting")
	check("radial ángulo por lado", is_equal_approx(by.Tengu.angle, 0.0))
	check("radial ubicación guardada gana", is_equal_approx(by.Ivan.angle, 200.0))
	check("radial controlado por", by.Ivan.direction == "in" and by.Ivan.kind == "input")
	check("radial ventana = viendo pantalla de", by.Cupid.viewing and by.Cupid.kind == "screen"
		and by.Cupid.direction == "in")
	check("radial foco en quien controlas", by.Tengu.focused and not by.Ivan.focused)
	check("radial sin captura no hay foco remoto",
		not SB.radial([{"host": "t", "peer_name": "T", "type": "input", "side": "east",
			"state": "active"}], [], [], {}, {"capturing": false})[0].focused)
	var two = SB.radial([
		{"host": "a", "peer_name": "A", "type": "screen", "side": "north", "state": "active"},
		{"host": "b", "peer_name": "B", "type": "screen", "side": "north", "state": "active"}], [], [])
	check("radial separa pares del mismo lado", not is_equal_approx(two[0].angle, two[1].angle))
	var dr = SB.diagram([{"host": "t", "peer_name": "T", "type": "input", "side": "east",
		"state": "active"}], [], [], {}, {"capturing": true})
	check("diagram trae radial y foco", dr.radial.size() == 1 and dr.local_focus == false)
	check("texto de foco", SB.focus_text(dr.radial, false) == "Controlando a T"
		and SB.focus_text(dr.radial, true).find("este equipo") >= 0)

	# --- Interruptor retro del radar (2026-10-08): master on/off --------------
	# Encendido y sin sesiones sigue vacío: para eso no hay dockapp.
	check("master encendido sin nada vacío", SB.diagram([], [], [], {}, {}, true).empty())
	# Cortado sin sesiones: stub no vacío (la dockapp queda con el interruptor).
	var doff = SB.diagram([], [], [], {}, {}, false)
	check("master apagado no vacío", not doff.empty())
	check("master apagado marcado", String(doff.master) == "off")
	check("apagado sin blips", doff.radial.empty() and doff.sides.north.empty()
		and doff.sides.south.empty() and doff.sides.east.empty() and doff.sides.west.empty())
	check("apagado lo dice en el tooltip", String(doff.tooltip).find("apagado") >= 0)
	check("apagado ofrece encender", _first_action_id(doff) == "master_on")
	# Con sesiones el menú abajo conserva los cortes por equipo.
	var s1 = [{"host": "tengu", "peer_name": "tengu", "type": "screen",
		"side": "south", "state": "active"}]
	var don = SB.diagram(s1, [], [], {}, {}, true)
	check("master encendido marcado", String(don.master) == "on")
	check("encendido ofrece apagar todo", _first_action_id(don) == "master_off"
		and String(don.menu[1].kind) == "separator")
	check("apagado con sesiones conserva cortes y ofrece encender",
		_first_action_id(SB.diagram(s1, [], [], {}, {}, false)) == "master_on")
	check("interruptor sin vocabulario interno",
		not SB.MAP.has_internal_terms(String(don.menu[0].label))
		and not SB.MAP.has_internal_terms(String(SB.diagram([], [], [], {}, {},
			false).menu[0].label))
		and not SB.MAP.has_internal_terms(String(doff.tooltip)))

	OS.exit_code = 1 if failed > 0 else 0
	quit()


# Primera fila de acción del menú (salteando separadores).
func _first_action_id(dg):
	for m in dg.menu:
		if String(m.get("kind", "")) == "separator":
			continue
		return String(m.get("id", ""))
	return ""
