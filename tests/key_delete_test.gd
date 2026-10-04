extends SceneTree

# Regresión de la tecla Supr (Delete) hacia apps Wayland alojadas.
#
# Causa raíz (verificada): el adaptador SDL2 del FRT retenía el keydown de
# SDLK_DELETE (0x7F) en require_unicode() esperando un SDL_TEXTINPUT que Delete
# nunca produce; el evento no llegaba a Godot ni, por lo tanto, al compositor.
# El compositor ya traduce KEY_DELETE -> evdev 111, así que el arreglo es de
# engine y vive en patches/frt/gdtk-frt-key-delete-hscroll.patch.
#
# Este test es puro (no abre sesión gráfica): comprueba por texto el cableado
# shell -> compositor -> wl_server y que el parche del engine siga en el repo,
# con el mismo patrón que dnd_wiring_test.gd.
#   godot --no-window --path shell -s $PWD/tests/key_delete_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func read_file(path):
	var f = File.new()
	var text = ""
	if f.open(path, File.READ) == OK:
		text = f.get_as_text()
		f.close()
	return text


func _init():
	var shell_dir = ProjectSettings.globalize_path("res://")
	var repo = shell_dir.rstrip("/")
	if repo.ends_with("/shell"):
		repo = repo.substr(0, repo.length() - 6)

	var comp = read_file(repo + "/modules/wayland/wayland_compositor.cpp")
	var shell = read_file("res://shell.gd")
	var patch = read_file(repo + "/patches/frt/gdtk-frt-key-delete-hscroll.patch")

	check("wayland_compositor.cpp disponible", comp != "")
	check("shell.gd disponible", shell != "")
	check("parche FRT Delete disponible", patch != "")

	# 1. El compositor conoce Delete y lo traduce a evdev 111.
	check("EVDEV_KEY_DELETE = 111",
		comp.find("EVDEV_KEY_DELETE = 111") >= 0)
	check("_scancode_to_evdev mapea KEY_DELETE",
		comp.find("case KEY_DELETE:") >= 0 and comp.find("return EVDEV_KEY_DELETE;") >= 0)

	# 2. WaylandCompositor::key usa el physical_scancode con respaldo al lógico
	#    (por si el FRT no trae physical) y emite por el seat.
	check("key usa physical_scancode",
		comp.find("p_event->get_physical_scancode()") >= 0)
	check("key cae al scancode lógico",
		comp.find("scancode = p_event->get_scancode()") >= 0)
	check("key emite wl_server_key",
		comp.find("wl_server_key(server,") >= 0)

	# 3. El shell no intercepta Delete: las pulsaciones llegan a compositor.key
	#    desde _unhandled_input. Si alguien agregara un atajo de Supr en shell.gd
	#    con set_input_as_handled, este check lo delata.
	check("shell reenvía a compositor.key",
		shell.find("compositor.key(event)") >= 0)
	check("shell.gd no consume KEY_DELETE",
		shell.find("KEY_DELETE") == -1)

	# 4. El adaptador FRT (fuera del repo) debe excluir SDLK_DELETE de
	#    require_unicode(); sin esto el keydown nunca sale hacia Godot.
	check("parche toca sdl2_adapter.h",
		patch.find("sdl2_adapter.h") >= 0)
	check("parche excluye SDLK_DELETE de require_unicode",
		patch.find("if (c == SDLK_DELETE)") >= 0 and patch.find("require_unicode") >= 0)

	# Opcional: comprobar el árbol de engine real (fuera del repo) si el usuario
	# exporta GDTK_FRT_PATH al directorio platform/frt.
	var frt = OS.get_environment("GDTK_FRT_PATH")
	if frt != "":
		var adapter = read_file(frt.rstrip("/") + "/sdl2_adapter.h")
		check("engine sdl2_adapter.h disponible", adapter != "")
		if adapter != "":
			check("engine ya excluye SDLK_DELETE",
				adapter.find("if (c == SDLK_DELETE)") >= 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
