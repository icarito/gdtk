extends Control

# Capa del menú contextual del Vecindario. Existe como nodo hijo propio, agregado
# ÚLTIMO y con z_index alto, para dibujarse por encima de los íconos/etiquetas que
# son nodos nativos hijos del Control del Vecindario (en Godot los hijos se dibujan
# después del _draw del padre, por eso el menú quedaba oculto detrás de los íconos).

const MENU = preload("./menu_style.gd")

const MENU_TITLE_H = 20.0
const MENU_PAD_X = 8.0

var rows = []            # filas tal como las arma neighborhood_ui._menu_rows
var rect = Rect2()       # _menu_rect
var hover = -1           # índice resaltado (-1 = ninguno)
var title = "Vecino"


func _draw():
	if rows.empty():
		return
	var font = get_font("font", "Label")
	if font == null:
		return
	var b = 2.0
	_bevel(rect, MENU.FACE, MENU.LIGHT, MENU.DARK, b)
	var t = Rect2(rect.position + Vector2(b, b), Vector2(rect.size.x - 2.0 * b, MENU_TITLE_H))
	_bevel(t, MENU.TITLE_BG, MENU.LIGHT, MENU.DARK, 1.0)
	var tw = font.get_string_size(title).x
	draw_string(font, t.position + Vector2((t.size.x - tw) * 0.5, 14.0), title, MENU.TITLE_TEXT)
	var idx = 0
	for row in rows:
		var r = Rect2(row.rect)
		var item = row.get("item", null)
		if item == null:
			if row.has("reason"):
				draw_string(font, r.position + Vector2(MENU_PAD_X + 10.0, 11.0),
					String(row.reason), MENU.TEXT_DISABLED)
			else:
				draw_rect(Rect2(r.position + Vector2(MENU_PAD_X, r.size.y * 0.5),
					Vector2(r.size.x - 2.0 * MENU_PAD_X, 1.0)), MENU.DARK)
			idx += 1
			continue
		var enabled = bool(item.get("enabled", false))
		if idx == hover and enabled:
			draw_rect(r, MENU.HILITE)
		var color = MENU.TEXT if enabled else MENU.TEXT_DISABLED
		draw_string(font, r.position + Vector2(MENU_PAD_X + 10.0, 17.0),
			String(item.get("label", "")), color)
		idx += 1


func _bevel(r, face, light, dark, b):
	draw_rect(r, face)
	draw_rect(Rect2(r.position, Vector2(r.size.x, b)), light)
	draw_rect(Rect2(r.position, Vector2(b, r.size.y)), light)
	draw_rect(Rect2(Vector2(r.position.x, r.end.y - b), Vector2(r.size.x, b)), dark)
	draw_rect(Rect2(Vector2(r.end.x - b, r.position.y), Vector2(b, r.size.y)), dark)
