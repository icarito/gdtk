extends SceneTree

# Regresión de cableado del drag and drop nativo (wl_data_device). El camino real
# vive en C/wlroots y no se puede ejercitar headless, así que se asegura que los
# listeners y las llamadas al seat sigan presentes tanto en el engine como en el
# shell (mismo patrón que wm_drag_test.gd con shell.gd).
#   godot --no-window --path shell -s $PWD/tests/dnd_wiring_test.gd

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
	# El C está fuera de res:// (shell/): se llega por la raíz global del proyecto.
	var shell_dir = ProjectSettings.globalize_path("res://")
	var repo = shell_dir.rstrip("/")
	if repo.ends_with("/shell"):
		repo = repo.substr(0, repo.length() - 6)

	var server = read_file(repo + "/modules/wayland/wl_server.c")
	var comp = read_file(repo + "/modules/wayland/wayland_compositor.cpp")
	var shell = read_file("res://shell.gd")

	check("wl_server.c disponible", server != "")
	check("wayland_compositor.cpp disponible", comp != "")
	check("shell.gd disponible", shell != "")

	# 1. El compositor pide arrancar el drag y valida el serial del puntero.
	check("escucha request_start_drag",
		server.find("wl_signal_add(&s->seat->events.request_start_drag, &s->request_start_drag)") >= 0)
	check("valida serial de puntero",
		server.find("wlr_seat_validate_pointer_grab_serial(s->seat, ev->origin, ev->serial)") >= 0)
	check("arranca pointer drag",
		server.find("wlr_seat_start_pointer_drag(s->seat, ev->drag, ev->serial)") >= 0)
	check("destruye el source si no valida",
		server.find("wlr_data_source_destroy(ev->drag->source)") >= 0)

	# 2. En start_drag registra el drag y su icono. El icono puede aparecer
	# después (set_icon), así que se re-sincroniza en motion/button.
	check("escucha start_drag",
		server.find("wl_signal_add(&s->seat->events.start_drag, &s->start_drag)") >= 0)
	check("escucha destroy del drag",
		server.find("wl_signal_add(&drag->events.destroy, &s->drag_destroy)") >= 0)
	check("sincroniza el icono en start_drag",
		server.find("drag_icon_sync(s);") >= 0)
	check("re-sincroniza en motion",
		server.find("if (s->drag != NULL) {\n\t\tdrag_icon_sync(s);") >= 0)
	check("reimporta en cada commit del surface",
		server.find("wl_signal_add(&surface->events.commit, &w->commit)") >= 0)
	check("acepta icono creado después de start_drag",
		server.find("(s->drag != NULL) ? s->drag->icon : NULL") >= 0)
	check("expone drag_state al terminar",
		server.find("s->cb.drag_state(s->cb.ud, 0)") >= 0)

	# 3. Motion/button siguen notificando al seat (el grab los intercepta).
	check("motion usa notify_motion",
		server.find("wlr_seat_pointer_notify_motion(s->seat, time_ms, sub_x, sub_y)") >= 0)
	check("button usa notify_button",
		server.find("wlr_seat_pointer_notify_button(s->seat, time_ms, evdev_button,") >= 0)

	# 4. El icono llega al shell y se dibuja junto al puntero.
	check("compositor expone get_drag_icon_texture",
		comp.find("ClassDB::bind_method(D_METHOD(\"get_drag_icon_texture\")") >= 0)
	check("compositor expone get_drag_icon_offset",
		comp.find("ClassDB::bind_method(D_METHOD(\"get_drag_icon_offset\")") >= 0)
	check("compositor expone is_dragging",
		comp.find("ClassDB::bind_method(D_METHOD(\"is_dragging\")") >= 0)
	check("señal drag_icon_changed",
		comp.find("ADD_SIGNAL(MethodInfo(\"drag_icon_changed\"))") >= 0)
	check("señal drag_state_changed",
		comp.find("ADD_SIGNAL(MethodInfo(\"drag_state_changed\"") >= 0)
	check("shell conecta drag_icon_changed",
		shell.find("compositor.connect(\"drag_icon_changed\", self, \"_on_drag_icon_changed\")") >= 0)
	check("shell conecta drag_state_changed",
		shell.find("compositor.connect(\"drag_state_changed\", self, \"_on_drag_state_changed\")") >= 0)
	check("shell dibuja el icono en CanvasLayer alto",
		shell.find("drag_layer.add_child(drag_icon_node)") >= 0 and
		shell.find("drag_layer.layer = 100") >= 0)
	check("shell usa el hotspot del compositor",
		shell.find("compositor.get_drag_icon_offset()") >= 0)
	check("shell usa la matemática pura",
		shell.find("DRAG_ICON.icon_rect(") >= 0)
	check("shell cae a placeholder sin textura",
		shell.find("tex = _drag_placeholder_texture()") >= 0)
	check("shell aplica blend premultiplicado",
		shell.find("drag_icon_node.material = premult_material") >= 0)
	check("shell limpia foco al arrastrar sobre el escritorio",
		shell.find("if client_drag_active:\n\t\t\t\tcompositor.pointer_clear_focus()") >= 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
