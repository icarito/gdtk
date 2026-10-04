extends Reference

# Matemática pura del icono de drag and drop. Sin dependencias del motor para
# poder testearse headless (tests/drag_icon_test.gd). shell.gd la usa para
# posicionar el TextureRect del icono respecto al puntero.
#
# El protocolo Wayland ubica el top-left del icono en el hotspot del cursor; el
# cliente ajusta el hotspot con el offset del attach/offset del surface, que el
# compositor expone como get_drag_icon_offset().


# Rect del icono: posición = puntero + hotspot, tamaño = tamaño del buffer.
static func icon_rect(pointer, size, hotspot_offset = Vector2.ZERO):
	return Rect2(Vector2(pointer) + Vector2(hotspot_offset), Vector2(size))


# Reduce el tamaño del icono si excede max_side conservando el aspecto (un buffer
# enorme no debe tapar toda la pantalla). max_side <= 0 desactiva el límite.
static func clamp_size(size, max_side):
	var s = Vector2(size)
	var m = max(s.x, s.y)
	if max_side > 0.0 and m > max_side:
		s *= max_side / m
	return s
