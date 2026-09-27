extends Node

# El Frame (como en Sugar): franja superpuesta arriba con Inicio, todo lo que
# corre (actividades internas con instancia viva y toplevels wayland sin padre,
# los haya lanzado el shell o no) y el reloj. No ocupa espacio: la app usa toda
# la pantalla y el Frame se dibuja encima (ViewLayer va en layer -1, bajo ImGui).
#
# Se muestra con F6 o dejando el mouse en la esquina superior izquierda
# CORNER_MS; en el Home está siempre. Se oculta al elegir algo, con Esc, con F6
# o al sacar el mouse (si entró en él después de mostrarse).
#
# Alt+Tab / Alt+Shift+Tab ciclan entre lo abierto sin mostrar el Frame. Se eligió
# Alt+Tab (no Ctrl+Tab, que usan las apps para pestañas): bajo cage en DRM llega
# al shell; sólo en cage anidado lo roba el escritorio anfitrión (probar con el
# control remoto: `key alt+Tab`).

const FRAME_H = 48.0
const CORNER = 4.0
const CORNER_MS = 250
const ITEM_W = 200.0
const CLOSE_W = 28.0
const PAD = 8.0

onready var shell = get_parent()

var visible = false
var entered = false
# 0: armada; >0: ms en que el mouse llegó a la esquina; -1: desarmada hasta salir.
var corner_since = 0
var swallowed = {}
# Layout del último frame dibujado (para el control remoto / tests).
var items_layout = []
var drawn = false


func set_visible(v):
	visible = v
	entered = false
	corner_since = -1


# Lo que corre, en orden estable: internas (por instancia viva) y ventanas raíz.
func running():
	var out = []
	for name in shell.script_instances.keys():
		out.append({"key": "s:" + name, "name": name, "title": name, "id": -1})
	for id in shell.compositor.get_ids():
		if shell.compositor.get_parent_id(id) > 0:
			continue
		var name = shell._activity_for_window(id)
		var title = shell.compositor.get_title(id)
		if title == "":
			title = name if name != "" else "Ventana " + str(id)
		out.append({"key": "w:" + str(id), "name": name, "title": title, "id": id})
	return out


func _is_current(item):
	if item.id >= 0:
		return item.id == shell._current_wayland_id()
	return shell.current_activity != null and shell.current_activity.name == item.name


func switch_to(item):
	set_visible(false)
	if item.id < 0 or item.name != "":
		shell._open_by_name(item.name)
	else:
		# Toplevel que todavía no tiene actividad dinámica: se la crea ya.
		shell.unmanaged.erase(item.id)
		shell._open_unmanaged_window(item.id)


func close(item):
	if item.id >= 0:
		# Cierre educado (xdg_toplevel.close): la app puede preguntar antes de irse.
		shell.compositor.close(item.id)
	else:
		shell._close_script_activity(item.name)


func cycle(step):
	var items = running()
	if items.empty():
		return
	var at = -1
	for i in range(items.size()):
		if _is_current(items[i]):
			at = i
	if at < 0:
		at = 0 if step > 0 else items.size()
	else:
		at = posmod(at + step, items.size())
	switch_to(items[at])


func _input(event):
	if not (event is InputEventKey):
		return
	var code = event.scancode
	if not event.pressed:
		# La suelta de una tecla que nos comimos tampoco va a la app.
		if swallowed.has(code):
			swallowed.erase(code)
			get_tree().set_input_as_handled()
		return
	var home = shell.current_activity == null
	if code == KEY_F6:
		if not event.echo:
			set_visible(not visible)
	elif code == KEY_ESCAPE and visible and not home:
		set_visible(false)
	elif code == KEY_TAB and event.alt:
		cycle(-1 if event.shift else 1)
	else:
		return
	swallowed[code] = true
	get_tree().set_input_as_handled()


# Llamado en cada imgui_frame del shell, después de la vista.
func draw(ui):
	var home = shell.current_activity == null
	var mouse = ui.get_mouse_pos()
	var now = OS.get_ticks_msec()
	if mouse.x <= CORNER and mouse.y <= CORNER:
		if corner_since == 0:
			corner_since = now
		elif corner_since > 0 and now - corner_since >= CORNER_MS and not visible:
			set_visible(true)
			entered = true
		if corner_since > 0:
			# Sin input no hay frames: hay que volver a mirar al cumplirse CORNER_MS.
			ui.request_redraw()
	else:
		corner_since = 0
	if visible and not home:
		if mouse.y <= FRAME_H:
			entered = true
		elif entered and mouse.y > FRAME_H + 16.0:
			set_visible(false)

	items_layout = []
	drawn = visible or home
	if not drawn:
		return

	var vp = ui.get_viewport_rect().size
	ui.set_next_window_pos(Vector2.ZERO, true)
	ui.set_next_window_size(Vector2(vp.x, FRAME_H), true)
	var flags = ui.WINDOW_NO_DECORATION | ui.WINDOW_NO_MOVE | ui.WINDOW_NO_SAVED_SETTINGS | ui.WINDOW_NO_SCROLLBAR
	var chosen = null
	var to_close = null
	if ui.begin("##frame", flags):
		var y = 10.0
		ui.set_cursor_pos(Vector2(PAD, y))
		if ui.button("Inicio", Vector2(90, 28)):
			set_visible(false)
			shell._go_home()

		var items = running()
		var clock_x = vp.x - 70.0
		var x = PAD + 90.0 + PAD * 2.0
		var w = ITEM_W
		if items.size() > 0:
			# ponytail: se achican para caber; con muchísimas no hay scroll.
			w = clamp((clock_x - x) / items.size() - CLOSE_W - PAD, 60.0, ITEM_W)
		for item in items:
			var current = _is_current(item)
			var label = item.title
			var max_chars = int(w / 8.0)
			if label.length() > max_chars:
				label = label.substr(0, max_chars - 2) + ".."
			ui.set_cursor_pos(Vector2(x, y))
			if current:
				ui.push_style_color(ui.COL_BUTTON, Color(0.26, 0.59, 0.98, 0.9))
			if ui.button(label + "##" + item.key, Vector2(w, 28)):
				chosen = item
			if current:
				ui.pop_style_color()
			ui.set_cursor_pos(Vector2(x + w + 2.0, y))
			if ui.button("x##c" + item.key, Vector2(CLOSE_W - 4.0, 28)):
				to_close = item
			items_layout.append({"title": item.title, "id": item.id, "current": current,
				"x": x, "y": y, "w": w, "close_x": x + w + 2.0})
			x += w + CLOSE_W + PAD

		var t = OS.get_time()
		ui.set_cursor_pos(Vector2(clock_x, y + 5.0))
		ui.text("%02d:%02d" % [t.hour, t.minute])
	ui.end()

	if chosen != null:
		switch_to(chosen)
	elif to_close != null:
		close(to_close)
