extends Reference

# Actividad "Perfil remoto" (SPEC-hud-remote 3): visor del HUD de otra
# instancia. Pide host:puerto y conecta `DebugHud.remote_source`; con
# GDTK_HUD_REMOTE=host:puerto auto-conecta (util para la verificacion).

var host = "127.0.0.1"
var port = "7777"
var attempted = false


func _init():
	var preset = OS.get_environment("GDTK_HUD_REMOTE")
	if preset != "":
		var colon = preset.rfind(":")
		if colon > 0:
			host = preset.substr(0, colon)
			port = preset.substr(colon + 1)
		else:
			host = preset


func draw(c):
	c.text("Visor remoto del HUD de debug")
	c.text("Abre el HUD (F1) en la instancia perfilada y conecta aqui.")
	host = c.input_text("host", host)
	port = c.input_text("puerto", port)
	if c.button("Conectar"):
		_connect()
	c.same_line()
	if c.button("Desconectar"):
		DebugHud.stop_remote()
		DebugHud.visible = false
	c.text("estado: " + DebugHud.remote_status)
	if DebugHud.remote_error != "":
		c.text_colored(Color(1.0, 0.4, 0.4), DebugHud.remote_error)
	if DebugHud.remote_source != "":
		c.text("fuente: " + DebugHud.remote_source)
		var remote_frame = -1
		if DebugHud.mirror != null:
			remote_frame = DebugHud.mirror.frame
		c.text("frame remoto: %d  frames locales: %d" % [remote_frame, DebugHud.metrics.frame])
	if not attempted and OS.get_environment("GDTK_HUD_REMOTE") != "":
		attempted = true
		_connect()


func _connect():
	DebugHud.start_remote(host, int(port))
	DebugHud.visible = true
