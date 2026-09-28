extends Reference

var messages = []
var draft = ""
var scroll_to_bottom = true
var pending = []


func _init():
	messages.append("bot: hola, esto es un chat XMPP mock")


func draw(ui):
	var now = OS.get_ticks_msec()
	var i = 0
	while i < pending.size():
		if now >= pending[i].due:
			messages.append(pending[i].text)
			scroll_to_bottom = true
			pending.remove(i)
		else:
			i += 1
	# Sin tick periódico en reposo: la respuesta pendiente pide sus propios frames.
	if not pending.empty():
		ui.request_redraw()
	var vp = ui.get_viewport_rect().size
	var hist_h = max(80.0, vp.y - 78.0)
	ui.begin_child("##historial", Vector2(0, hist_h))
	for message in messages:
		ui.text_wrapped(message)
	if scroll_to_bottom:
		ui.set_scroll_here_y(1.0)
		scroll_to_bottom = false
	ui.end_child()

	var result = ui.input_text_enter("##msg", draft)
	draft = result.text
	if result.submitted and draft.strip_edges() != "":
		_send(draft)
		draft = ""
	ui.same_line()
	if ui.button("Enviar") and draft.strip_edges() != "":
		_send(draft)
		draft = ""


func _send(text):
	messages.append("yo: " + text)
	scroll_to_bottom = true
	pending.append({"text": "bot: " + text, "due": OS.get_ticks_msec() + 1000})
