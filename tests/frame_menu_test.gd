extends SceneTree

# K9 — Menús popup sólo con el botón derecho. Prueba la lógica pura de
# shell/frame.gd sin instanciar shell.gd (que en headless falla por RemoteInput).
# Correr:
#   godot --no-window --path shell -s $PWD/tests/frame_menu_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var F = load("res://frame.gd")
	check("frame.gd carga", F != null)

	# El menú se abre con el derecho; el izquierdo queda para la acción del bloque.
	check("menu_trigger: derecho abre menú", F.menu_trigger(BUTTON_RIGHT, true) == "menu")
	check("menu_trigger: izquierdo no abre menú", F.menu_trigger(BUTTON_LEFT, true) == "primary")
	check("menu_trigger: suelta no dispara",
		F.menu_trigger(BUTTON_RIGHT, false) == "" and F.menu_trigger(BUTTON_LEFT, false) == "")

	# Cada applet con su menú propio; el resto no abre menú (el selector genérico sólo
	# aparece en un slot vacío de la barra).
	check("applet_menu teclado", F.applet_menu("teclado") == "teclado")
	check("applet_menu termico", F.applet_menu("termico") == "gov")
	check("applet_menu reloj", F.applet_menu("reloj") == "reloj")
	check("applet_menu sin menú", F.applet_menu("recursos") == "" and F.applet_menu("ventanas") == "")

	# Sombra del Frame: ahora son filas dibujadas dentro de las ventanas reales, no
	# ventanas ImGui separadas que puedan capturar mouse sobre las apps.
	var down = F.shadow_rows(Vector2(0, 10), 100.0, 1.0, 3.0, 0.18)
	check("shadow_rows abajo: tres filas", down.size() == 3)
	check("shadow_rows abajo: y crece", down[0].rect.position.y == 10 and down[2].rect.position.y == 12)
	check("shadow_rows abajo: alpha decrece", down[0].alpha > down[1].alpha and down[1].alpha > down[2].alpha)
	var up = F.shadow_rows(Vector2(0, 10), 100.0, -1.0, 3.0, 0.18)
	check("shadow_rows arriba: y decrece", up[0].rect.position.y == 10 and up[2].rect.position.y == 8)

	# Applets vivos (sysmon/teclado) mientras una franja esté a la vista, no sólo con
	# Home o el Frame enfocados: una barra fijada (pin) también los mantiene al día.
	check("applets_live: Inicio", F.applets_live(true, false, false, false))
	check("applets_live: Frame abierto", F.applets_live(false, true, false, false))
	check("applets_live: barra inferior fija", F.applets_live(false, false, false, true))
	check("applets_live: barra superior fija", F.applets_live(false, false, true, false))
	check("applets_live: todo oculto, otra app enfocada", not F.applets_live(false, false, false, false))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
