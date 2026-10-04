extends SceneTree

# K13d — Autoprueba de las decisiones puras de arrastre/soltar entre mosaico y
# flotante. Sin input real ni shell.gd.
#   godot --no-window --path shell -s $PWD/tests/wm_drag_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var D = load("res://wm_drag.gd")
	check("wm_drag.gd carga", D != null)
	check("selftest() del modelo", D.selftest())

	var cr = Rect2(0, 80, 1280, 640)
	# Soltar dentro del hueco: queda flotante.
	check("drop dentro -> flotante", D.drop_zone(Vector2(400, 300), cr, {}, false, "floating").kind == "float")
	# Soltar fuera del hueco: reincorporar al mosaico en ese lado.
	check("drop arriba -> reincorporar top",
		D.drop_zone(Vector2(400, 40), cr, {}, false, "floating").target == "top")
	check("drop abajo -> reincorporar bottom",
		D.drop_zone(Vector2(400, 790), cr, {}, false, "floating").target == "bottom")
	check("drop izquierda -> reincorporar left",
		D.drop_zone(Vector2(-5, 300), cr, {}, false, "floating").target == "left")
	check("drop derecha -> reincorporar right",
		D.drop_zone(Vector2(1400, 300), cr, {}, false, "floating").target == "right")
	# Sobre un bloque del Frame: reincorporar.
	check("drop sobre bloque -> reincorporar",
		D.drop_zone(Vector2(400, 300), cr, {}, true, "floating").kind == "reincorporate")

	# Desprender de la celda al arrastrar fuera.
	check("dentro de la celda no desprende", not D.drag_out(Rect2(100, 100, 400, 300), Vector2(300, 250)))
	check("fuera de la celda desprende", D.drag_out(Rect2(100, 100, 400, 300), Vector2(700, 250)))
	check("rect nulo desprende", D.drag_out(null, Vector2(0, 0)))

	# Barra del Frame y tamaño recordado.
	check("sobre barra superior", D.over_frame_bar(Vector2(10, 10), Vector2(1280, 800), 80.0))
	check("sobre barra inferior", D.over_frame_bar(Vector2(10, 795), Vector2(1280, 800), 80.0))
	check("centro no es barra", not D.over_frame_bar(Vector2(10, 400), Vector2(1280, 800), 80.0))
	check("restore_size recuerda", D.restore_size(Vector2(500, 400), Vector2(800, 600)) == Vector2(500, 400))
	check("restore_size fallback", D.restore_size(null, Vector2(800, 600)) == Vector2(800, 600))
	check("restore_size inválido -> fallback", D.restore_size(Vector2(0, 0), Vector2(800, 600)) == Vector2(800, 600))

	# Bordes de xdg_toplevel.resize -> zona del chrome.
	check("edges top", D.edges_zone(1) == "top")
	check("edges bottom", D.edges_zone(2) == "bottom")
	check("edges left", D.edges_zone(4) == "left")
	check("edges right", D.edges_zone(8) == "right")
	check("edges tl", D.edges_zone(1 | 4) == "tl")
	check("edges br", D.edges_zone(2 | 8) == "br")
	check("edges vacío -> br", D.edges_zone(0) == "br")

	# FRT/SDL: Super puede venir sólo como modificador del evento de mouse.
	check("Super del evento inicia drag", D.super_active(true, false, false, false))
	check("Super físico inicia drag", D.super_active(false, false, true, false))
	check("sin Super no inicia drag", not D.super_active(false, false, false, false))

	# Regresión e2e de cableado: tanto el drag con Super como el iniciado sobre la
	# barra terminan en _chrome_drag_motion; el motion debe trasladar el modelo Y el
	# nodo de contenido en el mismo evento. Si sólo se redibuja window_deco, se ve
	# exactamente el bug de “mover una label” mientras la ventana queda quieta.
	var f = File.new()
	var source = ""
	if f.open("res://shell.gd", File.READ) == OK:
		source = f.get_as_text()
		f.close()
	check("shell.gd disponible para regresión del drag", source != "")
	check("motion de ambos drags usa el camino común",
		source.find("if chrome_drag != null:\n\t\t\t_chrome_drag_motion(event.position)") >= 0)
	check("motion mueve el modelo flotante",
		source.find("float_layout.drag_to(id, pos - chrome_drag.grab, box)") >= 0)
	check("motion mueve ventana y decoración juntas",
		source.find("_apply_live_float_move(id, float_layout.rect(id))") >= 0)
	check("traslación viva mueve el nodo de contenido",
		source.find("node.rect_position = content.position") >= 0)

	# Regresión del Frame: Super debe ganar también sobre los appicons de la barra
	# superior. Antes el guard `mouse_pos.y > _vh()` dejaba esa barra fuera y el
	# motion levantaba el label/appicon en vez de mover la ventana.
	var ff = File.new()
	var frame_source = ""
	if ff.open("res://frame.gd", File.READ) == OK:
		frame_source = ff.get_as_text()
		ff.close()
	check("Super+drag no excluye la barra superior",
		frame_source.find("super_press != null and mouse_pos.y > _vh()") < 0)
	check("Super+drag del Frame acepta Meta del evento",
		frame_source.find("if shell._super_held(event) and shell.focused_tile >= 0:") >= 0)
	check("Super+drag del Frame no depende del keydown retenido",
		frame_source.find("if super_press != null and shell.focused_tile >= 0:") < 0)
	check("Super+drag descarta el appicon candidato",
		frame_source.find("app_press = null\n\t\t\t\t\t\tapp_drag = null") >= 0)

	# Regresión K13 (tarea 3): el arrastre de una maximizada la desmaximiza sin dejar
	# flags stale, y usa el puntero proporcional del modelo puro.
	check("drag de maximizada usa proporcional",
		source.find("WM_DRAG.proportional_grab(pos - src.position, src.size, fr.size)") >= 0)
	check("volver a flotante limpia maximize_state",
		source.find("maximize_state.erase(id)\n\t\tvar a = int(anchor)") >= 0)
	# Tarea 4: las flotantes nuevas se anclan al escritorio virtual en pantalla.
	check("nueva flotante se ancla al escritorio actual",
		source.find("hybrid.set_floating(id, _current_float_anchor())") >= 0)

	OS.exit_code = 1 if failed > 0 else 0
	quit()
