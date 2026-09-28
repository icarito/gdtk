extends CanvasLayer

# Superficies wlr-layer-shell (notificaciones de xfce4-notifyd/mako, OSDs) encima de todo,
# en el rect que el compositor calculó por ancla y márgenes. Con el puntero encima, el
# input va a la superficie (clic en la notificación).
# ponytail: sólo capas top y overlay; background/bottom (fondos, docks) taparían el shell.

const TOP = 2

var shell
var compositor
var boxes = {}
var hits = []


func _ready():
	layer = 100
	shell = get_parent()
	compositor = shell.compositor
	compositor.connect("layers_changed", shell, "request_redraw")
	shell.connect("imgui_frame", self, "_update")
	# Fin de cada frame: el compositor deja sin frame callbacks a lo que no se dibujó.
	shell.connect("redrawn", compositor, "end_frame")


func _update():
	# El output del compositor mide lo que la vista: las anclas se resuelven contra la pantalla
	# aunque todavía no se haya abierto ninguna ventana.
	var vp = shell.get_viewport_rect().size
	if compositor.default_size != vp:
		compositor.default_size = vp
	var seen = {}
	hits = []
	for s in compositor.get_layer_surfaces():
		if s.layer < TOP:
			continue
		seen[s.id] = true
		hits.append(s)
		var box = boxes.get(s.id)
		if box == null:
			box = Control.new()
			box.mouse_filter = Control.MOUSE_FILTER_IGNORE
			boxes[s.id] = box
			add_child(box)
		box.rect_position = s.rect.position
		box.rect_size = s.rect.size
		_fill(box, compositor.get_layers(s.id))
	for id in boxes.keys():
		if not seen.has(id):
			boxes[id].queue_free()
			boxes.erase(id)


# Una TextureRect por surface del árbol (raíz, subsurfaces, popups), como las ventanas.
func _fill(box, layers):
	shell._ensure_premult_material()
	while box.get_child_count() < layers.size():
		var t = TextureRect.new()
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.expand = true
		t.stretch_mode = TextureRect.STRETCH_SCALE
		t.material = shell.premult_material
		box.add_child(t)
	for i in range(box.get_child_count()):
		var t = box.get_child(i)
		t.visible = i < layers.size() and layers[i].texture != null
		if t.visible:
			t.texture = layers[i].texture
			t.rect_position = layers[i].rect.position
			t.rect_size = layers[i].rect.size if layers[i].rect.size.x > 0 else layers[i].texture.get_size()


func _input(event):
	if not (event is InputEventMouseMotion or event is InputEventMouseButton):
		return
	for i in range(hits.size() - 1, -1, -1):
		var r = hits[i].rect
		if r.has_point(event.position):
			compositor.pointer_motion(hits[i].id, event.position - r.position)
			if event is InputEventMouseButton:
				compositor.pointer_button(event.button_index, event.pressed)
			get_tree().set_input_as_handled()
			return
