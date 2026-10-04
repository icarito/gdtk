extends SceneTree

# Regresión de CABLEADO del arrastre entre escritorios en el exposé. El camino real
# (press/motion/release sobre una miniatura) no se puede ejercitar headless sin una
# sesión viva, así que se fija en el código la causa de que no anduviera y las
# llamadas clave, igual que wm_drag_test.gd con shell.gd.
#   godot --no-window --path shell -s $PWD/tests/expose_drag_wiring_test.gd

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
	var shell = read_file("res://shell.gd")
	var tiles = read_file("res://tiles_ui.gd")
	var layout = read_file("res://expose_layout.gd")
	check("shell.gd disponible", shell != "")
	check("tiles_ui.gd disponible", tiles != "")
	check("expose_layout.gd disponible", layout != "")

	# La entrada del exposé es una función propia y `_on_view_input` la atiende ANTES
	# de los guards de pointer-lock y captura remota (si no, un cliente con lock o
	# Deskflow capturando se tragaba el press/motion/drop y el drag no arrancaba).
	check("entrada de exposé extraída a _on_expose_input",
		shell.find("func _on_expose_input(event):") >= 0)
	check("_on_view_input despacha exposé antes de los guards",
		shell.find("if expose:\n\t\t_on_expose_input(event)\n\t\treturn\n\tif client_pointer_locked:") >= 0)
	check("captura remota no consume en exposé",
		shell.find("func _capture_remote_input_event(event):\n\t# En exposé") >= 0 and
		shell.find("if expose:\n\t\treturn false\n\t# InputCapture") >= 0)
	check("entrar a exposé suelta el pointer lock del cliente",
		shell.find("if client_pointer_locked:\n\t\t\t_set_client_pointer_lock(false)") >= 0)
	check("entrar a exposé suelta la captura remota",
		shell.find("if mouse_locked:\n\t\t\t_set_capture_cursor(false)") >= 0)

	# Press levanta la miniatura; motion mueve el fantasma y marca el destino;
	# release mueve (o selecciona/sale si no hubo movimiento).
	check("press arma expose_drag", shell.find("\"pos\": event.position, \"moved\": false}") >= 0)
	check("motion del fantasma actualiza la posición",
		shell.find("d[\"pos\"] = event.position") >= 0)
	check("motion resalta el destino bajo el cursor",
		shell.find("_expose_unit_at(event.position)") >= 0 and
		shell.find("expose_drag_target = -1 if expose_drag_gap >= 0 else _expose_unit_at(event.position)") >= 0)
	check("release sin mover selecciona/sale", shell.find("_expose_commit()") >= 0)
	check("release con movimiento suelta en el destino",
		shell.find("_expose_drop(int(d.id), target)") >= 0)

	# Huecos de inserción (estilo GNOME): no hay ranura vacía final; al arrastrar sobre
	# el espacio entre tarjetas se resalta una barra y al soltar se crea un escritorio
	# nuevo en esa posición con la ventana.
	check("visible_slots no agrega ranura vacía final",
		layout.find("if not out.empty():\n\t\tout.append(-1)") < 0)
	check("gap_at puro en expose_layout.gd",
		layout.find("static func gap_at(cards_rects, x):") >= 0)
	check("gap_x puro en expose_layout.gd",
		layout.find("static func gap_x(cards_rects, gap):") >= 0)
	check("shell resuelve el hueco bajo el cursor",
		shell.find("func _expose_gap_at(pos):\n\treturn EXPOSE_LAYOUT.gap_at(expose_unit_cards, pos.x)") >= 0)
	check("release en un hueco crea escritorio nuevo",
		shell.find("_expose_insert(int(d.id), gap)") >= 0)
	check("_expose_insert usa inserción en índice de wm_units",
		shell.find("WM_UNITS.solo_before(wm_units, id, anchor_id, axis)") >= 0 and
		shell.find("WM_UNITS.solo(wm_units, id, 0, axis)") >= 0)
	check("_expose_insert rearma tiles conservando flotantes",
		shell.find("_rebuild_tiles_preserving_floats()") >= 0)
	check("tiles_ui dibuja la barra de inserción",
		tiles.find("shell._expose_gap_bar_rect(shell.expose_drag_gap)") >= 0)
	check("tiles_ui ya no rotula 'Nuevo escritorio'",
		tiles.find("\"Nuevo escritorio\"") < 0)
	check("inserción en índice en wm_units.gd",
		read_file("res://wm_units.gd").find("static func solo_before(units, id, anchor, axis = AXIS_X):") >= 0)

	# Drop: flotante reancla y normaliza el rect en el destino; tiled solo/join.
	check("drop reancla la flotante", shell.find("hybrid.reanchor(id, anchor)") >= 0
		and shell.find("_join_into(id, tid, \"right\")") >= 0)
	check("drop encaja el rect flotante en el destino",
		shell.find("float_layout.restore_one(id, lr, box)") >= 0)
	check("drop tiled solo/join", shell.find("WM_UNITS.solo(wm_units, id, -1, _default_axis())") >= 0 and
		shell.find("WM_UNITS.join(wm_units, id, jt, s)") >= 0)

	# El hit-test de destino usa los mismos marcos que se dibujan.
	check("_expose_unit_at recorre expose_unit_cards",
		shell.find("func _expose_unit_at(pos):\n\tfor i in range(expose_unit_cards.size()):\n\t\tif expose_unit_cards[i].has_point(pos):") >= 0)
	check("tiles_ui resalta el marco destino",
		tiles.find("shell.expose_unit_cards[shell.expose_drag_target]") >= 0)
	check("tiles_ui dibuja el fantasma",
		tiles.find("shell.expose_drag.pos - shell.expose_drag.grab") >= 0)

	# La grilla interior (sin solapes) existe y `plan` la usa por workspace.
	check("arrange puro presente en expose_layout.gd", layout.find("static func arrange(cell, items, gap):") >= 0)
	check("plan usa arrange por workspace", layout.find("var placed = arrange(frame, items, inner_gap)") >= 0)

	# Escalado del exposé: la miniatura se escala para LLENAR su tarjeta, sin tope 1.0
	# (si no, una ventana chica/flotante no se redimensionaba al cambiar de escritorio);
	# tras el drop se recalcula el layout y la animación parte del footprint visible.
	check("miniatura escala a su tarjeta (sin tope 1.0)",
		shell.find("EXPOSE_LAYOUT.thumb_scale(card, rect)") >= 0 and
		shell.find("min(min(card.size.x / max(rect.size.x, 1.0)") < 0)
	check("drop/inserción recalculan el layout del exposé",
		shell.find("_compute_expose_layout()\n\trequest_redraw()") >= 0)
	check("reacomodo parte del footprint visible",
		shell.find("var cur = _node_footprint(node)") >= 0 and
		layout.find("static func lerp_rect(from, to, e):") >= 0)

	# Entrada genie: origen del ícono por actividad/app, o centro 0.2 con fade.
	check("origen de launch por actividad/app con timeout",
		shell.find("func _remember_origin(name, rect):") >= 0 and
		shell.find("func _take_origin(name):") >= 0)
	check("origen del pin/ítem del Frame sin tocar frame.gd",
		shell.find("func _frame_origin_for_app(app):") >= 0 and
		shell.find("frame.bar_layout.get(zone, [])") >= 0)
	check("entrada sin ícono usa genie desde el centro",
		shell.find("EXPOSE_LAYOUT.intro_from(rect, null, now, 0, 0, 0.2)") >= 0)
	check("intro_from puro en expose_layout.gd",
		layout.find("static func intro_from(rect, origin, now, since, max_age, k = 0.2):") >= 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
