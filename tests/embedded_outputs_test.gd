extends SceneTree

# Prueba la API multi-output del compositor embebido (Fase B, primer incremento).
# NO toca la sesión viva: levanta un WaylandCompositor aislado en un
# XDG_RUNTIME_DIR privado y sin Xwayland, y evita el dbus-update-activation-
# environment de start() cambiando XDG_CURRENT_DESKTOP.
#
# Cubre: salida primaria compatible, add/configure/remove, consulta por id,
# listado, escala y señales output_added/changed/removed.
#
# LÍMITE documentado: no prueba wl_surface.enter/leave de un toplevel real ni la
# reasignación de ventanas al retirar una salida porque eso exige un cliente
# Wayland. Tampoco captura/render por output (fase posterior). El
# toplevel_output_changed queda cubierto sólo en su no-op con ids inexistentes.
#
# Correr (el binario debe tener el módulo recompilado; ver AGENTS.md):
#   godot --no-window --path shell -s $PWD/tests/embedded_outputs_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


class OutputProbe:
	extends Reference
	var added = []
	var changed = []
	var removed = []
	var moved = []

	func _on_added(id):
		added.append(id)

	func _on_changed(id):
		changed.append(id)

	func _on_removed(id):
		removed.append(id)

	func _on_moved(toplevel_id, output_id):
		moved.append([toplevel_id, output_id])


func _finish():
	OS.exit_code = 1 if failed > 0 else 0
	quit()


func _init():
	# Aislar socket y estado de la sesión viva.
	var dir = "/tmp/gdtk_eo_test_" + str(OS.get_process_id())
	OS.execute("mkdir", ["-p", dir])
	OS.execute("chmod", ["700", dir])
	OS.set_environment("XDG_RUNTIME_DIR", dir)
	OS.set_environment("GDTK_NO_XWAYLAND", "1")
	# Si no corriéramos como desktop gdtk, start() ejecutaría dbus-update-
	# activation-environment y redirigiría las apps D-Bus de la sesión al socket
	# de prueba. Lo evitamos.
	OS.set_environment("XDG_CURRENT_DESKTOP", "test-embedded-outputs")

	var comp = ClassDB.instance("WaylandCompositor")
	check("WaylandCompositor instanciable", comp != null)
	if comp == null:
		OS.execute("rm", ["-rf", dir])
		_finish()
		return

	var probe = OutputProbe.new()
	comp.connect("output_added", probe, "_on_added")
	comp.connect("output_changed", probe, "_on_changed")
	comp.connect("output_removed", probe, "_on_removed")
	comp.connect("toplevel_output_changed", probe, "_on_moved")

	comp.default_size = Vector2(640, 480)
	var socket = comp.start()
	check("start() devuelve socket", socket != "")

	var primary = comp.get_primary_output_id()
	check("primary >= 1", primary >= 1)
	check("la principal no emite output_added al crear", probe.added.empty())

	var outs = comp.get_outputs()
	check("una salida inicial", outs.size() == 1)
	if outs.size() == 1:
		check("id primaria coincide", int(outs[0].id) == primary)
		check("primaria marcada", bool(outs[0].primary))
		check("nombre primary", String(outs[0].name) == "primary")
		check("rect primaria", outs[0].rect == Rect2(0, 0, 640, 480))
	check("scale primaria", int(outs[0].scale) == 1)
	check("segunda primary rechazada",
		comp.add_output("primary:otra", Rect2(640, 0, 320, 240), 1.0, true) == 0)
	check("sigue habiendo una sola primary", comp.get_outputs().size() == 1)

	# add_output
	var id2 = comp.add_output("remote:test", Rect2(640, 0, 320, 240), 1.0, false)
	check("add_output devuelve id", id2 > primary)
	check("output_added emitido", probe.added.has(id2))
	check("dos salidas", comp.get_outputs().size() == 2)
	var o2 = comp.get_output(id2)
	check("get_output nombre", String(o2.name) == "remote:test")
	check("get_output rect", o2.rect == Rect2(640, 0, 320, 240))
	check("get_output no primaria", not bool(o2.primary))
	check("get_output enabled", bool(o2.enabled))

	# configure_output
	var okc = comp.configure_output(id2, Rect2(700, 50, 400, 300), 2.0)
	check("configure_output ok", okc)
	var o2b = comp.get_output(id2)
	check("configure rect", o2b.rect == Rect2(700, 50, 400, 300))
	check("configure scale", int(o2b.scale) == 2)
	check("output_changed emitido", probe.changed.has(id2))

	# toplevel inexistente: no-op seguro, sin señales.
	check("get_toplevel_output inexistente = 0", comp.get_toplevel_output(99999) == 0)
	comp.set_toplevel_output(99999, id2)
	check("sin toplevels no hay señal de movimiento", probe.moved.empty())

	# remove: reasigna (sin ventanas) y destruye.
	comp.remove_output(id2)
	check("output_removed emitido", probe.removed.has(id2))
	check("vuelve a una salida", comp.get_outputs().size() == 1)
	check("get_output retirado vacío", comp.get_output(id2).empty())
	check("primary intacta", comp.get_primary_output_id() == primary)

	# la principal no se puede retirar.
	comp.remove_output(primary)
	check("remove de primary es no-op", comp.get_primary_output_id() == primary)
	check("sigue habiendo una salida", comp.get_outputs().size() == 1)

	comp.free()
	OS.execute("rm", ["-rf", dir])
	_finish()
