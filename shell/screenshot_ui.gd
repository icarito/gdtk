extends Reference

# Selector de pantallazos estilo GNOME: congela el escritorio y deja capturar una
# VENTANA, la PANTALLA entera o una SELECCIÓN rectangular. Al confirmar, el shell
# guarda el PNG a disco y copia la imagen al portapapeles del compositor embebido.
#
# Congelado: el shell saca la foto ANTES de dibujar este overlay (ver
# shell._open_screenshot_picker), así la captura no incluye el dim ni la barra.
# El overlay se dibuja en una ventana ImGui fullscreen NoMouseInputs y el mouse se
# maneja a mano en shell._input (mismo patrón que system_osd.gd).
#
# Sin I/O pesada acá: `handle_input`/`draw` corren en el frame; la confirmación sólo
# recorta la Image congelada (memoria) y delega el guardado/copiado al shell.

const MODEL = preload("res://screenshot_model.gd")

# ImGuiWindowFlags_NoMouseInputs (thirdparty/imgui/imgui.h): el módulo no lo expone
# como constante. La ventana es fullscreen y no debe robar hover/clics; el input lo
# resuelve handle_input.
const WINDOW_NO_MOUSE_INPUTS = 512

# Botones de la barra. "cancel" no cambia de modo: cierra.
const BUTTONS = [
	{"id": "window", "label": "Ventana"},
	{"id": "screen", "label": "Pantalla"},
	{"id": "region", "label": "Selección"},
	{"id": "cancel", "label": "Cancelar"},
]

const HINT = "Clic en una ventana · o arrastrá para seleccionar · Esc cancela"

var active = false
var mode = "region"
var frozen = null          # Image del escritorio, ya flip_y (coords de pantalla)
var vp = Vector2.ZERO      # tamaño de la UI (Viewport) al abrir
var drag_from = null       # Vector2 o null: arrastre de selección en curso
var sel = Rect2()          # selección de región
var hover = Rect2()        # ventana/diálogo bajo el cursor (para resaltar y capturar)
var hover_id = -1          # id de ventana elegida, -2 si es un diálogo, -1 si nada


func is_active():
	return active


func begin(image, vp_size, wanted_mode = "region"):
	frozen = image
	vp = Vector2(vp_size)
	mode = String(wanted_mode)
	drag_from = null
	sel = Rect2()
	hover = Rect2()
	hover_id = -1
	active = frozen != null and frozen.get_width() > 0
	return active


func cancel():
	active = false
	frozen = null
	drag_from = null
	sel = Rect2()
	hover = Rect2()
	hover_id = -1
	return true


# Devuelve true si consumió el evento (no debe ir a la app ni al resto del shell).
func handle_input(shell, event):
	if not active:
		return false
	if event is InputEventKey and event.pressed and not event.echo:
		var sc = int(event.scancode) if int(event.scancode) != 0 else int(event.physical_scancode)
		if sc == KEY_ESCAPE:
			cancel()
		elif sc == KEY_ENTER or sc == KEY_KP_ENTER:
			_confirm(shell)
		shell.request_redraw()
		return true
	var buttons = MODEL.toolbar_layout(vp, shell.ui_scale(vp), BUTTONS)
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		var pos = Vector2(event.position)
		if event.pressed:
			var bid = MODEL.button_at(pos, buttons)
			if bid != "":
				_on_button(shell, bid)
				return true
			if mode == "region":
				drag_from = pos
				sel = Rect2()
			elif mode == "window":
				_update_hover(shell, pos)
				if hover_id >= 0:
					_confirm(shell)
			elif mode == "screen":
				_confirm(shell)
		else:
			if mode == "region" and drag_from != null:
				var r = MODEL.normalize_rect(drag_from, pos, Rect2(Vector2.ZERO, vp))
				drag_from = null
				if r.size.x > 0.0 and r.size.y > 0.0:
					sel = r
					_confirm(shell)
		shell.request_redraw()
		return true
	if event is InputEventMouseMotion:
		var pos = Vector2(event.position)
		if mode == "window":
			_update_hover(shell, pos)
		elif mode == "region" and drag_from != null:
			sel = MODEL.normalize_rect(drag_from, pos, Rect2(Vector2.ZERO, vp), 0.0)
			shell.request_redraw()
		return true
	return false


# --- acciones ---------------------------------------------------------------

func _on_button(shell, bid):
	match bid:
		"cancel":
			cancel()
		"screen":
			mode = "screen"
			_confirm(shell)
			return
		"window":
			mode = "window"
			hover = Rect2()
			hover_id = -1
		"region":
			mode = "region"
			sel = Rect2()
			drag_from = null
	shell.request_redraw()


func _update_hover(shell, pos):
	var hit = shell._view_hit_test(pos)
	var dlg = hit.get("dialog", 0)
	if typeof(dlg) == TYPE_OBJECT and dlg != null:
		# Diálogo: el rect lo da el shell; _view_hit_test devuelve el objeto, no un id.
		hover = shell._dialog_rect(dlg)
		hover_id = -2
	else:
		var id = int(hit.get("id", -1))
		if id < 0:
			hover = Rect2()
			hover_id = -1
		else:
			hover = shell._screenshot_window_rect(id, pos)
			hover_id = id
	shell.request_redraw()


func _confirm(shell):
	if not active or frozen == null:
		return
	var kind = mode
	var rect = Rect2()
	match mode:
		"screen":
			rect = Rect2(Vector2.ZERO, vp)
		"window":
			if hover_id == -1 or hover.size.x <= 0.0 or hover.size.y <= 0.0:
				return
			rect = hover
		"region":
			if sel.size.x <= 0.0 or sel.size.y <= 0.0:
				return
			rect = sel
		_:
			return
	var crop = MODEL.crop_rect(rect, vp, Vector2(frozen.get_width(), frozen.get_height()))
	if crop.size.x < 1.0 or crop.size.y < 1.0:
		cancel()
		shell.request_redraw()
		return
	var piece = frozen.get_rect(crop)
	active = false
	frozen = null
	shell._screenshot_done(piece, kind)
	shell.request_redraw()


# --- control remoto / automatización ----------------------------------------

# `action`: open (default con ui=true), cancel, screen, window{id}, region{region:[x,y,w,h]}.
func rpc_action(shell, params):
	var a = str(params.get("action", ""))
	if a == "open" or bool(params.get("ui", false)):
		begin(shell._grab_viewport_image(), shell._desktop_rect().size, str(params.get("mode", "region")))
		shell.request_redraw()
		return active
	if a == "cancel":
		return cancel()
	if not active and not begin(shell._grab_viewport_image(), shell._desktop_rect().size, "region"):
		return false
	match a:
		"screen":
			mode = "screen"
			_confirm(shell)
			return true
		"window":
			mode = "window"
			var wid = int(params.get("id", -1))
			if wid < 0:
				return false
			hover_id = wid
			hover = shell._screenshot_window_rect(wid, Vector2.ZERO)
			_confirm(shell)
			return true
		"region":
			var rg = params.get("region", [])
			if typeof(rg) == TYPE_ARRAY and rg.size() == 4:
				mode = "region"
				sel = Rect2(float(rg[0]), float(rg[1]), float(rg[2]), float(rg[3]))
				_confirm(shell)
				return true
	return false


# --- dibujo ------------------------------------------------------------------

func draw(shell):
	if not active:
		return
	var s = shell.ui_scale(vp)
	shell.set_next_window_pos(Vector2.ZERO, true)
	shell.set_next_window_size(vp, true)
	shell.set_next_window_bg_alpha(0.0)
	shell.push_style_var_vec2(shell.STYLE_VAR_WINDOW_PADDING, Vector2.ZERO)
	var flags = shell.WINDOW_NO_DECORATION | shell.WINDOW_NO_BACKGROUND | shell.WINDOW_NO_MOVE \
		| shell.WINDOW_NO_RESIZE | shell.WINDOW_NO_SAVED_SETTINGS | shell.WINDOW_NO_SCROLLBAR \
		| shell.WINDOW_NO_TITLE_BAR | shell.WINDOW_NO_COLLAPSE \
		| shell.WINDOW_NO_BRING_TO_FRONT_ON_FOCUS | WINDOW_NO_MOUSE_INPUTS
	if shell.begin("##gdtk_shot", flags):
		shell.imgui_draw_rect_filled(Rect2(Vector2.ZERO, vp), Color(0.0, 0.0, 0.0, 0.45), 0.0)
		var r = _sel_rect()
		if r.size.x > 0.0 and r.size.y > 0.0:
			shell.imgui_draw_rect_filled(r, Color(1.0, 1.0, 1.0, 0.06), 0.0)
			_draw_border(shell, r, Color(0.55, 0.80, 1.0, 0.95), 2.0 * s)
		if mode == "region" and drag_from == null:
			_draw_crosshair(shell, s)
		_draw_toolbar(shell, s)
		_draw_hint(shell, s)
	shell.end()
	shell.pop_style_var()


func _sel_rect():
	if mode == "window" and hover_id >= 0:
		return hover
	if mode == "region":
		return sel
	return Rect2()


func _draw_border(shell, r, col, w):
	shell.imgui_draw_line(r.position, Vector2(r.end.x, r.position.y), col, w)
	shell.imgui_draw_line(Vector2(r.end.x, r.position.y), r.end, col, w)
	shell.imgui_draw_line(r.end, Vector2(r.position.x, r.end.y), col, w)
	shell.imgui_draw_line(Vector2(r.position.x, r.end.y), r.position, col, w)


func _draw_crosshair(shell, s):
	var m = shell.get_mouse_pos()
	var arm = 14.0 * s
	var col = Color(1.0, 1.0, 1.0, 0.5)
	shell.imgui_draw_line(Vector2(m.x - arm, m.y), Vector2(m.x + arm, m.y), col, 1.0 * s)
	shell.imgui_draw_line(Vector2(m.x, m.y - arm), Vector2(m.x, m.y + arm), col, 1.0 * s)


func _draw_toolbar(shell, s):
	for b in MODEL.toolbar_layout(vp, s, BUTTONS):
		var rect = Rect2(b["rect"])
		var on = String(b["id"]) == mode
		var face = Color(0.24, 0.34, 0.62, 0.98) if on else Color(0.14, 0.15, 0.19, 0.95)
		# Sombra + placa, misma familia visual que el OSD/Hogar.
		shell.imgui_draw_rect_filled(Rect2(rect.position + Vector2(0.0, 2.0 * s), rect.size),
			Color(0.0, 0.0, 0.0, 0.30), 8.0 * s)
		shell.imgui_draw_rect_filled(rect, face, 8.0 * s)
		var tw = shell._text_w(String(b["label"]))
		shell.set_cursor_pos(rect.position + Vector2((rect.size.x - tw) * 0.5, (rect.size.y - 13.0 * s) * 0.5))
		shell.text_colored(Color(0.95, 0.95, 0.98, 1.0), String(b["label"]))


func _draw_hint(shell, s):
	var tw = shell._text_w(HINT)
	var pos = Vector2((vp.x - tw) * 0.5, vp.y - 44.0 * s)
	shell.set_cursor_pos(pos + Vector2(1.0, 1.0))
	shell.text_colored(Color(0.0, 0.0, 0.0, 0.6), HINT)
	shell.set_cursor_pos(pos)
	shell.text_colored(Color(0.92, 0.93, 0.97, 0.95), HINT)
