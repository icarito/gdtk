extends SceneTree

# Autoprueba del modelo puro de governor de CPU (SPEC-power-governor) y del parseo de
# sysmon.gd. No ejecuta pkexec/sudo, no escribe /sys ni abre agentes.
#   godot --no-window --path shell -s $PWD/tests/governor_control_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var G = load("res://governor_control.gd")

	# Token ASCII estricto: allowlist, no denylist.
	check("token válido", G.valid_token("schedutil"))
	check("token con guion y guion bajo", G.valid_token("a_b-1"))
	check("token vacío rechazado", not G.valid_token(""))
	check("token con espacio rechazado", not G.valid_token("perf rmance"))
	check("token con punto y coma rechazado", not G.valid_token("perf;rm"))
	check("token con barra rechazado", not G.valid_token("../x"))
	check("token con salto rechazado", not G.valid_token("perf\nrm"))
	check("token con $ rechazado", not G.valid_token("$(id)"))
	check("token con comilla rechazado", not G.valid_token("a'b"))
	check("token con backtick rechazado", not G.valid_token("a`id`"))

	# Lista del kernel y membresía exacta.
	var avail = G.parse_available("performance powersave schedutil\n")
	check("parse_available", avail == ["performance", "powersave", "schedutil"])
	check("membresía exacta", G.governor_available("performance", avail))
	check("membresía no parcial", not G.governor_available("perf", avail))
	check("membresía ausente", not G.governor_available("ondemand", avail))

	# argv pkexec: sin `sh -c`, sin shell, sólo helper + governor.
	var argv = G.build_argv("schedutil")
	check("argv pkexec", argv == ["--disable-internal-agent", G.HELPER_PATH, "schedutil"])
	check("argv sin shell", not argv.has("sh") and not argv.has("-c"))
	check("argv inválido vacío", G.build_argv("bad name").empty())

	# validate_request: no debe llegar a pkexec un pedido inválido.
	check("validate sin governors", G.validate_request("schedutil", []).state == G.STATE_UNAVAILABLE)
	check("validate token inválido", G.validate_request("a;b", avail).state == G.STATE_ERROR)
	check("validate no disponible", G.validate_request("ondemand", avail).state == G.STATE_ERROR)
	check("validate ok", G.validate_request("powersave", avail).ok)

	# plan_apply: máquina de estados y faltantes de provisión.
	var p = G.plan_apply("powersave", avail, true, true, true)
	check("plan applying", p.state == G.STATE_APPLYING and p.program == G.PKEXEC_PATH)
	check("plan argv", p.argv == ["--disable-internal-agent", G.HELPER_PATH, "powersave"])
	check("plan sin helper", G.plan_apply("powersave", avail, false, true, true).state == G.STATE_NOT_PROVISIONED)
	check("plan sin policy", G.plan_apply("powersave", avail, true, false, true).state == G.STATE_NOT_PROVISIONED)
	check("plan sin pkexec", G.plan_apply("powersave", avail, true, true, false).state == G.STATE_NOT_PROVISIONED)
	check("plan unavailable", G.plan_apply("powersave", [], true, true, true).state == G.STATE_UNAVAILABLE)
	check("plan error no disponible", G.plan_apply("nope", avail, true, true, true).state == G.STATE_ERROR)

	# observe_result: applying → verified/error, idle intacto.
	check("observe verified", G.observe_result(G.STATE_APPLYING, "powersave", "powersave", 100, 1000) == G.STATE_VERIFIED)
	check("observe esperando", G.observe_result(G.STATE_APPLYING, "powersave", "schedutil", 100, 1000) == G.STATE_APPLYING)
	check("observe timeout", G.observe_result(G.STATE_APPLYING, "powersave", "schedutil", 1000, 1000) == G.STATE_ERROR)
	check("observe idle intacto", G.observe_result(G.STATE_IDLE, "powersave", "schedutil", 9000, 1000) == G.STATE_IDLE)
	check("observe sin pedido espera", G.observe_result(G.STATE_APPLYING, "", "powersave", 100, 1000) == G.STATE_APPLYING)

	# sysmon.gd parsea con el binario dev (no usa clases nativas).
	var sysmon = load("res://sysmon.gd")
	check("sysmon.gd parsea", sysmon != null)
	if sysmon != null:
		var inst = sysmon.new()
		check("sysmon estado inicial idle", inst.governor_state == G.STATE_IDLE)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
