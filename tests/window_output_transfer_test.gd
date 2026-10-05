extends SceneTree

# Fase C (SPEC-embedded-multi-output.md §7): transferencia de una ventana entre
# salidas del span (cruce por arrastre y accion de menu). Prueba el modelo puro
# shell/output_layout.gd: clamp_local, transfer_rect, cross, move_window,
# remove_output y reconcile_outputs. Sin render, sin I/O, sin procesos.
# Correr:
#   <binario dev> --no-window --path shell -s $PWD/tests/window_output_transfer_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _layout_with_secondary():
	var L = load("res://output_layout.gd")
	var lay = L.normalize_layout({"outputs": [L.default_primary(Rect2(0, 0, 1920, 1080))]})
	var add = L.add_output(lay, {"id": "physical:HDMI-1", "kind": "physical",
		"rect": Rect2(0, 0, 1280, 800)}, "east")
	return [L, add.layout]


func _init():
	var pair = _layout_with_secondary()
	var L = pair[0]
	var lay = pair[1]
	check("secundaria anclada al este en 1920",
		L.output_by_id(lay, "physical:HDMI-1").rect == Rect2(1920, 0, 1280, 800))

	# --- clamp_local -----------------------------------------------------------
	check("clamp_local encaja en la salida",
		L.clamp_local(Vector2(5000, -50), Vector2(800, 600),
			L.output_by_id(lay, "physical:HDMI-1")) == Vector2(480, 0))
	check("clamp_local permite borde si la ventana es mas grande",
		L.clamp_local(Vector2(-100, 0), Vector2(1500, 900),
			L.output_by_id(lay, "physical:HDMI-1")) == Vector2(-100, 0))

	# --- transfer_rect ---------------------------------------------------------
	var win = Rect2(100, 200, 800, 600)
	var to_sec = L.transfer_rect(lay, "primary", "physical:HDMI-1", win)
	check("transfer a secundaria ok", bool(to_sec.ok))
	check("transfer conserva tamano", to_sec.rect.size == win.size)
	check("transfer posicion relativa + origen",
		to_sec.rect.position == Vector2(1920 + 100, 200))
	check("transfer de vuelta a principal",
		L.transfer_rect(lay, "physical:HDMI-1", "primary", to_sec.rect).rect.position
			== Vector2(100, 200))
	var onto_gap = L.transfer_rect(lay, "primary", "bogus", win)
	check("transfer a salida inexistente falla", not bool(onto_gap.ok))

	# --- cross ----------------------------------------------------------------
	var c = L.cross(lay, "primary", Vector2(1910, 400), Vector2(20, 0))
	check("cross decide el cruce al este",
		bool(c.crossed) and String(c.to) == "physical:HDMI-1")
	check("cross devuelve local en la salida destino",
		Vector2(c.local).x < 20.0 and Vector2(c.local).x >= 0.0)
	var stay = L.cross(lay, "physical:HDMI-1", Vector2(2000, 400), Vector2(-5, 0))
	check("cross sin cruce mantiene from", not bool(stay.crossed))

	# --- move_window / windows_of ---------------------------------------------
	var assigned = L.assign_window(lay, 7, "primary")
	var m = L.move_window(assigned.layout, 7, "physical:HDMI-1")
	check("move_window reasigna", bool(m.ok)
		and L.window_output(m.layout, 7) == "physical:HDMI-1")
	check("windows_of lista la ventana", L.windows_of(m.layout, "physical:HDMI-1") == ["7"])
	var disabled = L.add_output(lay, {"id": "physical:DP-1", "kind": "physical",
		"rect": Rect2(0, 0, 1024, 768), "enabled": false}, "south")
	var dis_lay = L.assign_window(disabled.layout, 7, "primary").layout
	check("move_window a salida deshabilitada falla",
		not bool(L.move_window(dis_lay, 7, "physical:DP-1").ok))

	# --- remove_output devuelve las ventanas a la principal -------------------
	var rem = L.remove_output(m.layout, "physical:HDMI-1")
	check("remove_output ok", bool(rem.ok))
	check("ventana devuelta a principal", L.window_output(rem.layout, 7) == "primary")
	check("remove_output reporta moved", Array(rem.moved).has("7"))
	check("no se puede retirar la principal",
		not bool(L.remove_output(m.layout, "primary").ok))

	# --- reconcile_outputs retira una salida ausente --------------------------
	var rec = L.reconcile_outputs(m.layout, [
		L.default_primary(Rect2(0, 0, 1920, 1080)),
	])
	check("reconcile retira la secundaria",
		Array(rec.removed).has("physical:HDMI-1"))
	check("reconcile devuelve la ventana a principal",
		L.window_output(rec.layout, 7) == "primary")
	check("reconcile conserva exactamente una primary", L.primary_count(rec.layout) == 1)

	print(("ok   " if failed == 0 else "FAIL ") + "window_output_transfer (%d fallas)" % failed)
	OS.exit_code = 1 if failed > 0 else 0
	quit()
