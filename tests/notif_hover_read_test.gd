extends SceneTree

# Regresión del pendiente de notificaciones-v2: abrir la tarjeta de hover de la DOCKAPP
# marca la notificación como leída (antes sólo se marcaba al activar un bloque de la
# columna). Se marca en la transición cerrada→abierta (o ítem nuevo a la vista), no en
# cada frame: mark_read encola un comando por llamada.
#   godot --no-window --path shell -s $PWD/tests/notif_hover_read_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


class NotifyStub:
	extends Reference
	var hover_card = true
	var read_marks = []
	var items_by_id = {
		7: {"id": 7, "app": "App", "summary": "Hola", "body": "cuerpo", "read": false, "ms": 0},
		8: {"id": 8, "app": "App", "summary": "Otra", "body": "dos", "read": false, "ms": 1},
	}
	var _last = 7
	func latest():
		return items_by_id.get(_last, {})
	func mark_read(id):
		read_marks.append(int(id))


class DockStub:
	extends Reference
	var hovered = true
	var hover_rect = Rect2(100, 100, 40, 40)


class FrameStub:
	extends Reference
	const NX_BG = Color(0.1, 0.1, 0.12)
	const NX_TEXT = Color(0.9, 0.9, 0.92)
	const NX_TEXT_DIM = Color(0.5, 0.5, 0.55)
	const NX_LIGHT = Color(1, 1, 1)
	const NX_DARK = Color(0, 0, 0)
	var applet_mods = {"notificaciones": DockStub.new()}
	func _truncate_w(_ui, text, _w):
		return String(text)
	func _text_w(_ui, _text):
		return 8.0


class ShellStub:
	extends Reference
	const WINDOW_NO_DECORATION = 0
	const WINDOW_NO_BACKGROUND = 0
	const WINDOW_NO_MOVE = 0
	const WINDOW_NO_RESIZE = 0
	const WINDOW_NO_SAVED_SETTINGS = 0
	const WINDOW_NO_TITLE_BAR = 0
	const WINDOW_NO_COLLAPSE = 0
	const WINDOW_NO_BRING_TO_FRONT_ON_FOCUS = 0
	const WINDOW_NO_SCROLLBAR = 0
	const STYLE_VAR_WINDOW_PADDING = 0
	var notify = NotifyStub.new()
	var frame = FrameStub.new()
	var blocks = []
	func _screen_size():
		return Vector2(1920, 1080)
	func set_next_window_pos(_p, _c):
		pass
	func set_next_window_size(_s, _c):
		pass
	func set_next_window_bg_alpha(_a):
		pass
	func push_style_var_vec2(_a, _b):
		pass
	func pop_style_var():
		pass
	func begin(_n, _f):
		return false
	func end():
		pass


func _read_source():
	var f = File.new()
	if f.open("res://shell.gd", File.READ) != OK:
		return ""
	var t = f.get_as_text()
	f.close()
	return t


func _init():
	var P = load("res://notifications_panel.gd")
	check("panel carga", P != null)
	if P == null:
		OS.exit_code = 1
		quit()
		return
	var panel = P.new()
	var sh = ShellStub.new()
	var dock = sh.frame.applet_mods["notificaciones"]

	# Pointer sobre la dockapp: la tarjeta abre y marca la notificación (7).
	panel._draw_hover_card(sh)
	check("abrir la tarjeta de la dockapp marca read", sh.notify.read_marks == [7])
	# Hover sostenido: la tarjeta sigue abierta; NO re-marca cada frame.
	panel._draw_hover_card(sh)
	check("hover sostenido no re-marca", sh.notify.read_marks.size() == 1)

	# Puntero fuera: la tarjeta cierra y el estado de marcado se resetea.
	dock.hovered = false
	panel._draw_hover_card(sh)
	check("al cerrar la tarjeta se resetea", panel._card_open == false \
		and panel._card_marked_id == -1)

	# Reabrir con OTRA notificación a la vista: marca la nueva.
	dock.hovered = true
	sh.notify._last = 8
	sh.notify.items_by_id[7]["read"] = true
	panel._draw_hover_card(sh)
	check("reabrir marca la notificación nueva", sh.notify.read_marks == [7, 8])

	# Sin el ajuste "texto completo al pasar el puntero": ni tarjeta ni marca.
	dock.hovered = true
	sh.notify.hover_card = false
	panel._draw_hover_card(sh)
	check("hover_card apagado no marca", sh.notify.read_marks.size() == 2)

	# Frescura para la pausa del scanout (video fullscreen): un bloque recién nacido es
	# fresco; uno del historial (_columna fijada) no retiene el video.
	panel._anim = {7: {"born": OS.get_ticks_msec()}}
	check("toast recién nacido es fresco", panel.has_fresh())
	panel._anim = {7: {"born": OS.get_ticks_msec() - 60000}}
	check("bloque viejo (columna fijada) no es fresco", not panel.has_fresh())
	panel._anim = {7: {"born": OS.get_ticks_msec() + 400}}
	check("estalón futuro (stagger) cuenta como fresco", panel.has_fresh())
	var shellsrc = _read_source()
	check("overlay de scanout usa has_fresh",
		shellsrc.find("has_fresh()") >= 0
		and shellsrc.find("has_fresh()") > shellsrc.find("func _scanout_overlay_active"))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
