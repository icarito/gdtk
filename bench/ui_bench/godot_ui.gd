extends Control

# Controles nativos de Godot equivalentes a la escena ImGui: N filas de
# Label + ProgressBar + Button y una polilínea de 300 puntos dibujada con
# _draw().

const POLY_POINTS = 300

var count = 20
var mode = "static"
var rows = []
var values = []
var polyline = null
var tick = 0


func configure(p_count, p_mode):
	count = p_count
	mode = p_mode
	_build()


func _build():
	for child in get_children():
		child.queue_free()
	rows = []
	values = []

	rect_size = get_viewport_rect().size

	var box = VBoxContainer.new()
	box.rect_position = Vector2(16, 16)
	box.rect_size = Vector2(420, 0)
	add_child(box)

	for i in range(count):
		var row = HBoxContainer.new()
		var label = Label.new()
		label.text = "Fila %d: 0" % i
		label.rect_min_size = Vector2(140, 0)
		row.add_child(label)
		var bar = ProgressBar.new()
		bar.rect_min_size = Vector2(180, 0)
		bar.value = 0.0
		row.add_child(bar)
		var button = Button.new()
		button.text = "Boton %d" % i
		row.add_child(button)
		box.add_child(row)
		rows.append({"label": label, "bar": bar})
		values.append(0)

	polyline = Control.new()
	polyline.set_script(load("res://polyline.gd"))
	polyline.rect_position = Vector2(16, 480)
	polyline.rect_size = Vector2(900, 200)
	add_child(polyline)
	polyline.configure(POLY_POINTS)


func set_frame_values(p_frame):
	tick = p_frame
	for i in range(rows.size()):
		var v = int(50.0 + 49.0 * sin(float(p_frame) * 0.05 + float(i)))
		values[i] = v
		rows[i]["label"].text = "Fila %d: %d" % [i, v]
		rows[i]["bar"].value = float(v)
	if polyline != null:
		polyline.set_frame_values(p_frame)
