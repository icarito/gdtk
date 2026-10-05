extends SceneTree

# Autoprueba del modelo puro del modo span fisico (shell/span_layout.gd,
# SPEC-physical-multi-monitor.md). Sin render, sin I/O, sin procesos.
# Correr:
#   <binario dev> --no-window --path shell -s $PWD/tests/span_layout_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var S = load("res://span_layout.gd")
	check("span_layout.gd carga", S != null)

	# --- Parseo de swaymsg ----------------------------------------------------
	check("json invalido devuelve vacio", S.parse_outputs("no json") == [])
	var json = """
	[
	  {"name": "eDP-1", "active": true, "scale": 1.0,
	   "current_mode": {"width": 1920, "height": 1080, "refresh": 60000},
	   "rect": {"x": 0, "y": 0, "width": 1920, "height": 1080}},
	  {"name": "DP-1", "active": true, "scale": 1.0,
	   "current_mode": {"width": 1280, "height": 800, "refresh": 60000},
	   "rect": {"x": 1920, "y": 0, "width": 1280, "height": 800}},
	  {"name": "HDMI-A-1", "active": false,
	   "current_mode": {"width": 1024, "height": 768}, "rect": {"x": 0, "y": 0}}
	]
	"""
	var outs = S.parse_outputs(json)
	check("parseo descarta inactivas", outs.size() == 2)
	check("parseo toma nombre y tamano logico",
		String(outs[0].name) == "eDP-1" and float(outs[0].width) == 1920.0)
	# Escala: el modo fisico se divide por scale para el tamano logico.
	var hidpi = S.parse_outputs("""[{"name":"eDP-1","active":true,"scale":2.0,
		"current_mode":{"width":3840,"height":2160}}]""")
	check("parseo aplica escala al tamano logico",
		float(hidpi[0].width) == 1920.0 and float(hidpi[0].height) == 1080.0)

	# --- Eleccion de principal ------------------------------------------------
	check("principal externa por defecto", S.choose_primary(outs) == "DP-1")
	check("principal forzada respetada", S.choose_primary(outs, "eDP-1") == "eDP-1")
	check("forzada inexistente cae a externa", S.choose_primary(outs, "VGA-9") == "DP-1")
	var only_internal = S.parse_outputs(
		'[{"name":"eDP-1","active":true,"rect":{"width":1920,"height":1080}}]')
	check("sin externa usa la interna", S.choose_primary(only_internal) == "eDP-1")

	# --- Orden ----------------------------------------------------------------
	var ordered = S.order_outputs(outs, "eDP-1")
	check("orden: principal primero", String(ordered[0].name) == "eDP-1")
	check("orden conserva el resto", ordered.size() == 2 and String(ordered[1].name) == "DP-1")

	# --- Plan de span ---------------------------------------------------------
	var plan = S.plan(outs, "eDP-1")
	check("plan ok", bool(plan.ok) and String(plan.primary) == "eDP-1")
	check("plan activo con dos salidas", bool(plan.active))
	check("plan: principal en (0,0)",
		plan.entries[0].rect == Rect2(0, 0, 1920, 1080))
	check("plan: secundaria a la derecha",
		plan.entries[1].rect == Rect2(1920, 0, 1280, 800))
	check("plan: desktop envolvente", plan.desktop == Rect2(0, 0, 3200, 1080))
	check("plan: screen es la principal", plan.screen == Rect2(0, 0, 1920, 1080))
	check("plan: ids primary/physical:<name>",
		plan.entries[0].id == "primary" and plan.entries[1].id == "physical:DP-1")
	check("plan: descriptors validos para reconcile",
		plan.descriptors.size() == 2 and bool(plan.descriptors[0].primary)
		and not bool(plan.descriptors[1].primary)
		and String(plan.descriptors[1].target) == "span")

	var single = S.plan(only_internal, "eDP-1")
	check("una sola salida: no activo", not bool(single.active) and bool(single.single))
	check("una sola salida: desktop = screen",
		single.desktop.size == single.screen.size)

	# Orden explícito del usuario (Configuración > Monitores): izquierda->derecha.
	var three = S.parse_outputs("""[
	  {"name":"eDP-1","active":true,"rect":{"width":1920,"height":1080}},
	  {"name":"DP-1","active":true,"rect":{"width":1280,"height":800,"x":1920,"y":0}},
	  {"name":"HDMI-A-1","active":true,"rect":{"width":1600,"height":900,"x":3200,"y":0}}
	]""")
	check("tres salidas detectadas", three.size() == 3)
	var o3 = S.order_outputs(three, "eDP-1", ["HDMI-A-1", "DP-1"])
	check("orden explícito manda", String(o3[1].name) == "HDMI-A-1" and String(o3[2].name) == "DP-1")
	var plan3 = S.plan(three, "eDP-1", ["HDMI-A-1", "DP-1"])
	check("plan respeta el orden elegido",
		plan3.entries[1].id == "physical:HDMI-A-1"
		and plan3.entries[1].rect.position.x == 1920.0
		and plan3.entries[2].id == "physical:DP-1"
		and plan3.entries[2].rect.position.x == 3520.0)
	check("orden desconocido va al final por posición",
		String(S.order_outputs(three, "eDP-1", ["HDMI-A-1"])[2].name) == "DP-1")

	# --- Comandos sway --------------------------------------------------------
	var cmds = S.position_commands(plan)
	check("comandos de posicion por salida", cmds.size() == 2
		and cmds[0] == ["output", "eDP-1", "pos", "0", "0"]
		and cmds[1] == ["output", "DP-1", "pos", "1920", "0"])
	var span_cmd = S.span_window_command(plan.desktop)
	check("comando de ventana span",
		span_cmd.find("floating enable") >= 0 and span_cmd.find("resize set 3200 1080") >= 0)
	check("comando single usa fullscreen",
		S.single_window_command().find("fullscreen enable") >= 0)

	# --- Ops del compositor embebido -----------------------------------------
	var ops = S.output_ops(plan)
	check("output_ops refleja el plan", ops.size() == 2
		and String(ops[0].id) == "primary" and bool(ops[0].primary)
		and String(ops[1].id) == "physical:DP-1" and not bool(ops[1].primary))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
