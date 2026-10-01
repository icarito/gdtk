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

	# Applet de teclado -> su menú; el resto -> selector de controles del Frame.
	check("applet_menu teclado", F.applet_menu("teclado") == "teclado")
	check("applet_menu otros", F.applet_menu("recursos") == "picker" and F.applet_menu("reloj") == "picker")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
