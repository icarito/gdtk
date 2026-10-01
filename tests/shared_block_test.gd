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

	OS.exit_code = 1 if failed > 0 else 0
	quit()
