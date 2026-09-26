extends ImGuiCanvas

var activities = ["Chat", "Pintar", "Escribir", "Terminal", "Música", "Ajustes"]
var activity_msg = ""

var messages = []
var draft = ""
var scroll_to_bottom = true
var pending = []

var frame_count = 0
var screenshot_path = ""


func _ready():
	connect("imgui_frame", self, "_imgui_frame")
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--screenshot="):
			screenshot_path = arg.substr("--screenshot=".length())
	messages.append("bot: hola, esto es un chat XMPP mock")


func _imgui_frame():
	# Ventana 1: actividades estilo Sugar.
	set_next_window_pos(Vector2(20, 20))
	set_next_window_size(Vector2(320, 190))
	if begin("Actividades"):
		for i in range(activities.size()):
			if button(activities[i]):
				activity_msg = "Abrir: " + activities[i]
			if (i + 1) % 3 != 0 and i != activities.size() - 1:
				same_line()
		if activity_msg != "":
			separator()
			text(activity_msg)
	end()

	# Ventana 2: chat mock.
	set_next_window_pos(Vector2(370, 20))
	set_next_window_size(Vector2(380, 400))
	if begin("Chat XMPP (mock)"):
		begin_child("##historial", Vector2(0, 280))
		for message in messages:
			text_wrapped(message)
		if scroll_to_bottom:
			set_scroll_here_y(1.0)
			scroll_to_bottom = false
		end_child()

		var result = input_text_enter("##msg", draft)
		draft = result.text
		if result.submitted and draft.strip_edges() != "":
			_send(draft)
			draft = ""
		same_line()
		if button("Enviar") and draft.strip_edges() != "":
			_send(draft)
			draft = ""
	end()

	# Respuestas eco un segundo despues, sin red.
	var now = OS.get_ticks_msec()
	var i = 0
	while i < pending.size():
		if now >= pending[i].due:
			messages.append(pending[i].text)
			scroll_to_bottom = true
			pending.remove(i)
		else:
			i += 1

	frame_count += 1
	if screenshot_path != "" and frame_count >= 30:
		_capture(screenshot_path)


func _send(text):
	messages.append("yo: " + text)
	scroll_to_bottom = true
	pending.append({"text": "bot: " + text, "due": OS.get_ticks_msec() + 1000})


func _capture(path):
	var image = get_viewport().get_texture().get_data()
	image.flip_y()
	var err = image.save_png(path)
	if err != OK:
		printerr("screenshot: no se pudo guardar ", path, " (error ", err, ")")
	get_tree().quit()
