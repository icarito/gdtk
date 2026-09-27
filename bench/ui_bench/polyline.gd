extends Control

# Control equivalente al plot nativo de ImGui: 300 puntos dibujados con _draw().

var points = []
var tick = 0


func configure(p_count):
	points = []
	for i in range(p_count):
		points.append(Vector2(0, 0))
	# Curva inicial tambien en modo estatico (equivalente al plot de ImGui).
	set_frame_values(0)


func set_frame_values(p_frame):
	tick = p_frame
	var n = points.size()
	if n < 2:
		return
	var width = rect_size.x
	var height = rect_size.y
	for i in range(n):
		var x = width * float(i) / float(n - 1)
		var y = height * 0.5 - sin(float(i) * 0.1 + float(p_frame) * 0.1) * height * 0.4
		points[i] = Vector2(x, y)
	update()


func _draw():
	if points.size() >= 2:
		draw_polyline(points, Color(0.9, 0.6, 0.2), 2.0, true)
