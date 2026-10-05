extends Reference

# Estilo WindowMaker para los menús verticales (popups ImGui) del shell.
#
# Sólo GDScript de Godot 3 sobre la API curada de ImGuiCanvas. No toca el motor:
# el look se compone con push_style_color/push_style_var más el dibujo manual de
# panel/bisel/barra de título con imgui_draw_rect_filled sobre el draw list de la
# ventana (mismo uso que shell/frame.gd::_bevel).
#
# Uso típico en frame.gd (popups de _draw_applets):
#   MENU_STYLE.begin(ui)
#   if ui.begin_popup("##id"):
#       MENU_STYLE.chrome(ui, "Título")
#       if MENU_STYLE.item(ui, "Etiqueta", "Ctrl+K", seleccionado):
#           ...
#       ui.end_popup()
#   MENU_STYLE.end(ui)      # SIEMPRE, aunque el popup no esté abierto
#
# begin()/end() son un par balanceado de pushes/pops de estilo; end() se llama
# incondicionalmente para no dejar el stack desalineado entre frames.
#
# LÍMITES (lo que NO se puede sin tocar el motor):
#  - No hay color de texto por estado (normal/hover/activo usan el mismo COL_TEXT);
#    el resaltado de un ítem se hace con el fondo del header, no con otro color.
#  - No hay `calc_text_size`: el centrado del título usa la métrica empírica del
#    shell (alto ~13 px y ancho ~7 px por carácter, escalados por imgui_scale).
#  - No hay outline de rect sin relleno (`imgui_draw_rect` no existe): el marco se
#    arma con 4 franjas rellenas (bisel) o con `imgui_draw_polyline` cerrado.
#  - ImGui no expone una barra de título para popups (`begin_popup` no lleva
#    título ni variables Título/FontSize): la barra se dibuja a mano con chrome().
#  - El tamaño del popup es auto-ajustado por ImGui; en el primer frame de apertura
#    wsize aún no incluye el contenido, así que el panel usa un ancho/alto mínimo
#    derivado del título para no parpadear.

# --- Paleta WindowMaker -------------------------------------------------------
const FACE = Color(0.72, 0.72, 0.75, 1.0)          # gris del panel
const LIGHT = Color(0.96, 0.96, 0.96, 1.0)        # bisel claro (arriba/izquierda)
const DARK = Color(0.32, 0.32, 0.35, 1.0)         # bisel oscuro (abajo/derecha)
const TITLE_BG = Color(0.42, 0.42, 0.55, 1.0)     # barra de título inactiva
const HILITE = Color(0.78, 0.79, 0.84, 1.0)       # resaltado de ítem
const ACTIVE = Color(0.24, 0.32, 0.62, 1.0)       # ítem presionado/seleccionado
const TEXT = Color(0.06, 0.06, 0.08, 1.0)         # texto oscuro sobre gris
const TEXT_DISABLED = Color(0.35, 0.35, 0.38, 1.0)

# Interiores de control (checkbox/input) derivados de FACE, sin inventar nombres
# fuera de la paleta pedida.
const CONTROL_BG = Color(0.60, 0.61, 0.66, 1.0)
const CONTROL_HOVER = Color(0.68, 0.69, 0.74, 1.0)
const CONTROL_ACTIVE = Color(0.52, 0.53, 0.58, 1.0)
const TITLE_TEXT = Color(0.97, 0.97, 1.0, 1.0)    # título en blanco

# Cantidad EXACTA de pushes de estilo. end() usa estos números.
const COLOR_COUNT = 13
const VAR_COUNT = 5

# Geometría del look (escalada por ui.get_imgui_scale()).
const BEVEL_W = 2.0      # grosor del bisel del panel
const TITLE_BEVEL = 1.0  # grosor del bisel de la barra de título
const TITLE_H = 16.0     # alto de la barra de título
const GAP_Y = 2.0        # separación barra -> primer ítem
const PAD_X = 6.0        # sangría horizontal del texto de título e ítems

const CHAR_W = 7.0       # ancho empírico de carácter del shell
const LINE_H = 13.0      # alto empírico de línea del shell


# Empuja colores y variables del look. Balancear SIEMPRE con end(). Los push de
# estilo son globales a ImGui, así que deben envolver también al begin_popup.
static func begin(ui):
	var s = ui.get_imgui_scale()
	ui.push_style_color(ui.COL_POPUP_BG, FACE)
	ui.push_style_color(ui.COL_BORDER, DARK)
	ui.push_style_color(ui.COL_TEXT, TEXT)
	ui.push_style_color(ui.COL_TEXT_DISABLED, TEXT_DISABLED)
	ui.push_style_color(ui.COL_HEADER, HILITE)
	ui.push_style_color(ui.COL_HEADER_HOVERED, HILITE)
	ui.push_style_color(ui.COL_HEADER_ACTIVE, ACTIVE)
	ui.push_style_color(ui.COL_SEPARATOR, DARK)
	ui.push_style_color(ui.COL_FRAME_BG, CONTROL_BG)
	ui.push_style_color(ui.COL_FRAME_BG_HOVERED, CONTROL_HOVER)
	ui.push_style_color(ui.COL_FRAME_BG_ACTIVE, CONTROL_ACTIVE)
	ui.push_style_color(ui.COL_MENU_BAR_BG, FACE)
	ui.push_style_color(ui.COL_CHECK_MARK, TEXT)
	ui.push_style_var_float(ui.STYLE_VAR_FRAME_ROUNDING, 0.0)
	ui.push_style_var_float(ui.STYLE_VAR_WINDOW_ROUNDING, 0.0)
	ui.push_style_var_vec2(ui.STYLE_VAR_FRAME_PADDING, Vector2(4.0, 3.0) * s)
	ui.push_style_var_vec2(ui.STYLE_VAR_ITEM_SPACING, Vector2(4.0, 2.0) * s)
	ui.push_style_var_vec2(ui.STYLE_VAR_WINDOW_PADDING, Vector2(PAD_X, PAD_X) * s)


# Descarta exactamente lo empujado en begin() (mismo orden, cantidades exactas).
static func end(ui):
	ui.pop_style_var(VAR_COUNT)
	ui.pop_style_color(COLOR_COUNT)


# Bisel reutilizable: panel `face` con franjas `light` arriba/izquierda y `dark`
# abajo/derecha, de grosor `b`. Mismo criterio que frame.gd::_bevel pero genérico.
static func bevel_rect(ui, rect, face, light, dark, b):
	ui.imgui_draw_rect_filled(rect, face, 0.0)
	ui.imgui_draw_rect_filled(Rect2(rect.position, Vector2(rect.size.x, b)), light, 0.0)
	ui.imgui_draw_rect_filled(Rect2(rect.position, Vector2(b, rect.size.y)), light, 0.0)
	ui.imgui_draw_rect_filled(Rect2(Vector2(rect.position.x, rect.end.y - b), Vector2(rect.size.x, b)), dark, 0.0)
	ui.imgui_draw_rect_filled(Rect2(Vector2(rect.end.x - b, rect.position.y), Vector2(b, rect.size.y)), dark, 0.0)


# Chrome del menú: panel gris con bisel, barra de título con su propio bisel y el
# título en blanco; deja el cursor justo debajo de la barra para el primer ítem.
# Debe llamarse como PRIMERA sentencia dentro de `if ui.begin_popup(...)`.
static func chrome(ui, title):
	var s = ui.get_imgui_scale()
	var b = BEVEL_W * s
	var th = TITLE_H * s
	var tb = TITLE_BEVEL * s
	var wpos = ui.get_window_pos()
	var wsize = ui.get_window_size()
	# ImGui auto-ajusta el popup; en el primer frame wsize puede ser mínimo. El
	# panel nunca queda más chico que el título + una fila de ítem.
	var min_w = float(String(title).length()) * CHAR_W * s + 16.0 * s
	var min_h = b + th + GAP_Y * s + 18.0 * s
	var panel_w = max(wsize.x, min_w)
	var panel_h = max(wsize.y, min_h)
	var panel = Rect2(wpos, Vector2(panel_w, panel_h))
	bevel_rect(ui, panel, FACE, LIGHT, DARK, b)
	var title_rect = Rect2(wpos + Vector2(b, b), Vector2(panel_w - 2.0 * b, th))
	bevel_rect(ui, title_rect, TITLE_BG, LIGHT, DARK, tb)
	# Origen local del popup -> pantalla, para convertir posiciones locales.
	ui.set_cursor_pos(Vector2.ZERO)
	var origin = ui.get_cursor_screen_pos()
	var text_pos = Vector2(wpos.x + b + PAD_X * s, wpos.y + b + (th - LINE_H * s) * 0.5)
	ui.set_cursor_pos(text_pos - origin)
	ui.text_colored(TITLE_TEXT, String(title))
	# Primer ítem debajo de la barra (coordenada local).
	ui.set_cursor_pos(Vector2(PAD_X * s, wpos.y + b + th + GAP_Y * s - origin.y))  # x = padding: antes 0 y el 1.er ítem quedaba pegado al borde


# Ítem de menú. Si hay ícono lo dibuja a la izquierda y alinea la etiqueta; el
# `shortcut` se autoalinea a la derecha por MenuItem. Devuelve el bool del ítem.
static func item(ui, label, shortcut = "", selected = false, icon_tex = null):
	if icon_tex != null:
		var s = ui.get_imgui_scale()
		ui.image(icon_tex, Vector2(16.0, 16.0) * s)
		ui.same_line(0.0, 6.0 * s)
	return ui.menu_item(label, shortcut, selected)
