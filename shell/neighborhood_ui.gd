extends Control

# Vista simbólica: el modelo de Wi-Fi sigue en neighborhood.gd; aquí sólo hay
# anillos, iconos SVG y botones nativos con foco/tooltip.
const BG = Color(0.055, 0.065, 0.095, 1.0)
const RING = Color(0.60, 0.69, 0.82, 0.20)
const TEXT = Color(0.91, 0.94, 0.98, 1.0)
const ICON_SIZE = 58.0

var shell = null
var model = null
var selected = ""
var drawn_version = -1
var drawn_size = Vector2.ZERO
var center = Vector2.ZERO
var radius = 0.0
var points = []


func refresh(force = false):
	if model == null:
		return
	var vp = get_viewport_rect().size
	if not force and model.version == drawn_version and vp == drawn_size:
		return
	drawn_version = model.version
	drawn_size = vp
	rect_size = vp
	for child in get_children():
		child.free()
	points = []
	var bar = shell.frame_bar_h(vp)
	center = vp * 0.5
	radius = max(60.0, min(vp.x * 0.36, (vp.y - 2.0 * bar - 130.0) * 0.5))
	var active = null
	for net in model.networks:
		if net.in_use:
			active = net
			break
	var center_icon = "network-connected" if active != null else "network-off"
	_make_icon(self, center_icon, center - Vector2(30, 30), 60.0)
	var title = "Vecindario"
	_label(title, Vector2(16, bar + 10), 220)
	if active != null:
		_label(active.ssid, center + Vector2(-90, 38), 180)
	elif model.networks.empty():
		_label(model.status_line(), center + Vector2(-130, 40), 260)
		if model.status == "off":
			var enable = _button("Encender Wi-Fi", center + Vector2(-72, 65), Vector2(144, 32))
			enable.connect("pressed", shell, "_wifi_radio_on")
	var desired = []
	for net in model.networks:
		var r = lerp(radius * 0.42, radius, clamp(float(net.r_frac), 0.0, 1.0))
		desired.append(center + Vector2(cos(net.angle), sin(net.angle)) * r)
	var half = []
	for i in range(desired.size()):
		half.append(ICON_SIZE * 0.5)
	if desired.size() > 1:
		desired = model.relax_capsules(desired, half, half, 4.0, 48, 0.02)
	for i in range(model.networks.size()):
		var net = model.networks[i]
		var pos = Vector2(clamp(desired[i].x, ICON_SIZE, vp.x - ICON_SIZE),
			clamp(desired[i].y, bar + ICON_SIZE, vp.y - bar - ICON_SIZE))
		points.append({"pos": pos, "selected": net.ssid == selected, "active": net.in_use})
		var hit = _button("", pos - Vector2(ICON_SIZE, ICON_SIZE) * 0.5, Vector2(ICON_SIZE, ICON_SIZE))
		hit.hint_tooltip = net.ssid + (" · conectada" if net.in_use else "") + "\n" + str(int(net.dbm)) + " dBm"
		hit.connect("pressed", self, "_select", [net.ssid])
		_make_icon(hit, "network-connected" if net.in_use else "network-open" if net.security == "" else "network-secure", Vector2(4, 4), ICON_SIZE - 8.0)
	var chosen = null
	for net in model.networks:
		if net.ssid == selected:
			chosen = net
			break
	if chosen != null:
		var caption = chosen.ssid + (" · conectada" if chosen.in_use else " · abierta" if chosen.security == "" else " · protegida")
		_label(caption, Vector2(vp.x * 0.5 - 170, bar + 12), 230)
		if not chosen.in_use:
			var connect_button = _button("Conectar", Vector2(vp.x * 0.5 + 68, bar + 8), Vector2(92, 32))
			connect_button.connect("pressed", shell, "_open_nmtui")
	update()


func _select(ssid):
	selected = ssid
	call_deferred("refresh", true)


func _button(caption, pos, size):
	var button = Button.new()
	button.text = caption
	button.flat = caption == ""
	button.rect_position = pos
	button.rect_min_size = size
	button.rect_size = size
	button.focus_mode = Control.FOCUS_ALL
	add_child(button)
	return button


func _label(caption, pos, width):
	var label = Label.new()
	label.text = caption
	label.rect_position = pos
	label.rect_size = Vector2(width, 22)
	label.clip_text = true
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_color_override("font_color", TEXT)
	add_child(label)


func _make_icon(parent, name, pos, size):
	var path = "res://icons/" + name + ".svg"
	if OS.get_current_video_driver() == OS.VIDEO_DRIVER_GLES3 \
			and ClassDB.class_exists("SlugVector2D") and ClassDB.class_exists("SlugVector"):
		var vector = ClassDB.instance("SlugVector")
		vector.set_svg_path(path)
		if vector.is_valid():
			var icon = ClassDB.instance("SlugVector2D")
			icon.set_vector(vector)
			icon.set_size(size)
			icon.set_centered(false)
			parent.add_child(icon)
			icon.position = pos
			return
	var image = Image.new()
	if image.load(path) != OK:
		return
	var texture = ImageTexture.new()
	texture.create_from_image(image, Texture.FLAG_FILTER)
	var icon = TextureRect.new()
	icon.texture = texture
	icon.expand = true
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.rect_position = pos
	icon.rect_size = Vector2(size, size)
	parent.add_child(icon)


func _draw():
	draw_rect(Rect2(Vector2.ZERO, rect_size), BG)
	for fraction in [0.48, 0.74, 1.0]:
		draw_arc(center, radius * fraction, 0.0, TAU, 64, RING, 1.0)
	for point in points:
		if point.selected or point.active:
			draw_arc(point.pos, ICON_SIZE * 0.5 + 3.0, 0.0, TAU, 32,
				Color(1.0, 0.84, 0.43, 1.0) if point.active else TEXT, 2.0)
