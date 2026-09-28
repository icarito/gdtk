extends Node

# El Frame (como en Sugar): franja superpuesta arriba con Inicio, todo lo que
# corre (actividades internas con instancia viva y toplevels wayland sin padre,
# los haya lanzado el shell o no) y el reloj. No ocupa espacio: la app usa toda
# la pantalla y el Frame se dibuja encima (ViewLayer va en layer -1, bajo ImGui).
#
# Se muestra con F6, tocando Super sola (como GNOME/Sugar) o dejando el mouse
# HOT_MS en la esquina superior izquierda o contra el borde superior; en el Home
# está siempre. Se oculta al elegir algo, con Esc, con F6/Super o al sacar el
# mouse (si entró en él después de mostrarse).
# Super+F6 abre y cierra el HUD de debug (ya no hay widget mini ni F1).
#
# Super: la pulsación se retiene; si se suelta sin otra tecla ni clic entre medio
# alterna el Frame y la app no ve nada. Si llega otra tecla (Super+L...), la
# pulsación retenida se reenvía antes a la app y el combo le llega entero. FRT la
# entrega como scancode KEY_META (keysym) con physical KEY_SUPER_L/R.
#
# Borde: y <= EDGE en cualquier x (Deskflow entrando/saliendo por arriba, o chocar
# el borde). HOT_MS evita disparos al pasar hacia pestañas/menús pegados arriba, y
# un clic mientras espera la desarma hasta salir del borde (clic en una pestaña).
#
# Alt+Tab / Alt+Shift+Tab ciclan entre lo abierto sin mostrar el Frame. Se eligió
# Alt+Tab (no Ctrl+Tab, que usan las apps para pestañas): bajo cage en DRM llega
# al shell; sólo en cage anidado lo roba el escritorio anfitrión (probar con el
# control remoto: `key alt+Tab`).

const FRAME_H = 48.0
const CORNER = 4.0
const EDGE = 1.0
const HOT_MS = 250
# Entrada/salida del Frame deslizándose desde arriba (ease-out).
const SLIDE_MS = 130
const SUPER_KEYS = [KEY_META, KEY_SUPER_L, KEY_SUPER_R]
const ITEM_W = 200.0
const CLOSE_W = 28.0
const PAD = 8.0

onready var shell = get_parent()

var visible = false
var entered = false
# 0: armada; >0: ms en que el mouse llegó a la esquina; -1: desarmada hasta salir.
var corner_since = 0
var swallowed = {}
var hot_timer = false
# Pulsación de Super retenida mientras no se sepa si es un toque solo.
var super_press = null
# Deslizamiento: último estado dibujado (visible u Home) y cuándo cambió.
var shown = false
var slide_since = 0
# Layout del último frame dibujado (para el control remoto / tests).
var sysmon = preload("res://sysmon.gd").new()
var items_layout = []
var drawn = false


func set_visible(v):
	visible = v
	entered = false
	corner_since = -1
	# Desde _input (tecla tragada, ImGui no la ve) nadie más pide el frame que lo muestra.
	shell.request_redraw()
	shell.last_activity = OS.get_ticks_msec()


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


# Monitor del sistema: muestrea sólo con el Frame a la vista; fuera del Home (Frame abierto
# a pedido) la gráfica avanza sola, en el Home se refresca con el próximo frame.
func _process(_delta):
	var home = shell.current_activity == null
	if (visible or home) and sysmon.tick() and visible and not home:
		shell.request_redraw()


# Super dejó de ser un toque solo: la app recibe la pulsación retenida.
func _super_used():
	if super_press != null and shell._current_wayland_id() >= 0:
		shell.compositor.key(super_press)
	super_press = null


func _input(event):
	if event is InputEventMouseButton and event.pressed:
		_super_used()
		if corner_since > 0:
			corner_since = -1
		return
	if not (event is InputEventKey):
		return
	var code = event.scancode
	if SUPER_KEYS.has(code) or SUPER_KEYS.has(event.physical_scancode):
		if event.pressed:
			super_press = event
		elif super_press != null:
			super_press = null
			set_visible(not visible)
		else:
			return  # Suelta tras un combo: va a la app.
		get_tree().set_input_as_handled()
		return
	if event.pressed and code == KEY_F6 and super_press != null:
		super_press = null
		DebugHud.toggle()
		shell.request_redraw()
		swallowed[code] = true
		get_tree().set_input_as_handled()
		return
	if event.pressed:
		_super_used()
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
	# Otra vez tras dibujar la vista: lo que cambió en este frame (un clic que abre
	# una app, la primera textura) arranca el fundido ya, sin un frame a opacidad plena.
	transition()
	var home = shell.current_activity == null
	var mouse = ui.get_mouse_pos()
	var now = OS.get_ticks_msec()
	# MousePos es -FLT_MAX hasta el primer movimiento: eso no es la esquina.
	var hot = mouse.y >= 0.0 and (mouse.y <= EDGE or (mouse.x >= 0.0 and mouse.x <= CORNER and mouse.y <= CORNER))
	if hot:
		if corner_since == 0:
			corner_since = now
		if corner_since > 0:
			var left = HOT_MS - (now - corner_since)
			if left <= 0:
				if not visible:
					set_visible(true)
					entered = true
			elif not hot_timer:
				# Sin input no hay frames: un timer pide el que vuelve a mirar al cumplirse HOT_MS.
				hot_timer = true
				get_tree().create_timer(left / 1000.0).connect("timeout", self, "_hot_wake")
	else:
		corner_since = 0
	if visible and not home:
		if mouse.y <= FRAME_H:
			entered = true
		elif entered and mouse.y > FRAME_H + 16.0:
			set_visible(false)

	items_layout = []
	var off = _slide(visible or home, now)
	drawn = off > -FRAME_H
	if not drawn:
		return

	var vp = ui.get_viewport_rect().size
	ui.set_next_window_pos(Vector2(0.0, off), true)
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
		var mon_x = clock_x - sysmon.W - PAD * 2.0
		var x = PAD + 90.0 + PAD * 2.0
		var w = ITEM_W
		if items.size() > 0:
			# ponytail: se achican para caber; con muchísimas no hay scroll.
			w = clamp((mon_x - x) / items.size() - CLOSE_W - PAD, 60.0, ITEM_W)
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
				"x": x, "y": y + off, "w": w, "close_x": x + w + 2.0})
			x += w + CLOSE_W + PAD

		sysmon.draw(ui, Vector2(mon_x, y), 28.0)
		var t = OS.get_time()
		ui.set_cursor_pos(Vector2(clock_x, y + 5.0))
		ui.text("%02d:%02d" % [t.hour, t.minute])
	ui.end()

	if chosen != null:
		switch_to(chosen)
	elif to_close != null:
		close(to_close)


func _hot_wake():
	hot_timer = false
	shell.request_redraw()


# Desplazamiento vertical del Frame: 0 quieto a la vista, -FRAME_H fuera. Mientras
# desliza pide frames y mantiene despierto el loop; al terminar deja de pedirlos.
func _slide(want, now):
	if want != shown:
		shown = want
		# Si cambia a mitad de camino, sigue desde donde está.
		var done = min(now - slide_since, SLIDE_MS)
		slide_since = now - (SLIDE_MS - done)
	var k = clamp(float(now - slide_since) / SLIDE_MS, 0.0, 1.0)
	if k < 1.0:
		shell.request_redraw()
		shell.last_activity = now
	var p = 1.0 - pow(1.0 - k, 3.0)
	if not shown:
		p = 1.0 - p
	return -FRAME_H * (1.0 - p)


# Cambio de vista (Home <-> app, anillo <-> grilla, entre apps): fundido de FADE_MS
# y, en la vista wayland, zoom leve desde el centro. Devuelve el alfa para ImGui.
# Sólo toca nodos mientras dura: en reposo no hay nada que redibujar.
const FADE_MS = 150
var view_key = ""
var fade_since = 0
var fading = false


func transition():
	var now = OS.get_ticks_msec()
	var key = "home:" + str(shell.apps_view)
	if shell.current_activity != null:
		# Una app nueva cambia de clave otra vez al llegar su primera textura.
		key = shell.current_activity.name + ":" + str(shell.tex_ready_frame >= 0)
	if key != view_key:
		view_key = key
		fade_since = now
		fading = true
	if not fading:
		return 1.0
	var k = clamp(float(now - fade_since) / FADE_MS, 0.0, 1.0)
	var a = 1.0 - pow(1.0 - k, 3.0)
	if k < 1.0:
		shell.request_redraw()
		shell.last_activity = now
	else:
		fading = false
	var v = shell.view
	v.rect_pivot_offset = v.rect_size * 0.5
	var z = lerp(0.94, 1.0, a)
	v.rect_scale = Vector2(z, z)
	# Las capas usan alfa premultiplicado: se escala también el color.
	v.modulate = Color(a, a, a, a)
	return a
