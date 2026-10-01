extends SceneTree

# Autoprueba del generador puro de ajustes QSettings de Deskflow (deskflow-core
# 1.26). No hace I/O, no lanza procesos ni Deskflow. Correr:
#   godot --no-window --path shell -s $PWD/tests/deskflow_settings_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var S = load("res://deskflow_settings.gd")

	# Selftest interno del módulo.
	S.selftest()
	check("selftest() de deskflow_settings", true)

	# Cliente: QSettings con [core] coreMode=1 y [client] remoteHost.
	var client = S.build_client_settings("tengu", "192.168.1.20", 24800)
	check("cliente no vacio", client != "")
	check("cliente [core] coreMode=1", client.find("[core]") >= 0 and client.find("coreMode=1") >= 0)
	check("cliente computerName/screenName", client.find("computerName=tengu") >= 0
		and client.find("screenName=tengu") >= 0)
	check("cliente puerto", client.find("port=24800") >= 0)
	check("cliente [client] remoteHost", client.find("[client]") >= 0
		and client.find("remoteHost=192.168.1.20") >= 0)
	check("cliente [security] tlsEnabled=false", client.find("[security]") >= 0
		and client.find("tlsEnabled=false") >= 0)
	check("cliente [gui] autoHide=true", client.find("[gui]") >= 0
		and client.find("autoHide=true") >= 0)

	# Servidor: coreMode=2 y externalConfigFile apuntando al layout barrier.
	var layout = "/home/u/.config/Deskflow/deskflow-server.conf"
	var server = S.build_server_settings("tengu", layout, 24800)
	check("servidor no vacio", server != "")
	check("servidor coreMode=2", server.find("coreMode=2") >= 0)
	check("servidor externalConfig=true", server.find("[server]") >= 0
		and server.find("externalConfig=true") >= 0)
	check("servidor externalConfigFile", server.find("externalConfigFile=" + layout) >= 0)
	check("servidor portapapeles compartido", server.find("[internalConfig]") >= 0
		and server.find("clipboardSharing=true") >= 0)
	check("servidor [security] tlsEnabled=false", server.find("tlsEnabled=false") >= 0)
	check("servidor sin [client] ni [gui]", server.find("[client]") < 0 and server.find("[gui]") < 0)

	# El ini sólo admite rutas locales válidas (sin "~" ni traversal).
	check("servidor rechaza ruta con tilde", S.build_server_settings("tengu", "~/bad.conf") == "")
	check("servidor rechaza traversal", S.build_server_settings("tengu", "/a/../b.conf") == "")
	check("servidor rechaza ruta vacia", S.build_server_settings("tengu", "") == "")

	# Puerto por defecto y alternativo.
	check("puerto por defecto 24800", client.find("port=24800") >= 0)
	check("puerto alternativo", S.build_client_settings("tengu", "10.0.0.2", 25800).find("port=25800") >= 0)
	check("puerto invalido rechazado", S.build_client_settings("tengu", "10.0.0.2", 70000) == "")

	# Validación de dirección.
	check("IPv4 valida", S.valid_server_addr("192.168.1.20"))
	check("IPv6 valida", S.valid_server_addr("fe80::1"))
	check("hostname valido", S.valid_server_addr("tengu.local"))
	check("addr con espacio invalida", not S.valid_server_addr("a b"))
	check("addr con igual invalida", not S.valid_server_addr("a=b"))
	check("addr con salto invalida", not S.valid_server_addr("a\nb"))
	check("addr con shell invalida", not S.valid_server_addr("a;rm -rf /"))
	check("addr vacia invalida", not S.valid_server_addr(""))
	check("addr con tilde invalida", not S.valid_server_addr("~/x"))

	# Validación de nombre local (mismo criterio que los peers del layout).
	check("nombre con espacio rechazado", S.build_client_settings("bad name", "10.0.0.2") == "")
	check("nombre vacio rechazado", S.build_client_settings("", "10.0.0.2") == "")

	# Determinismo.
	check("cliente determinista",
		S.build_client_settings("tengu", "192.168.1.20") == S.build_client_settings("tengu", "192.168.1.20"))

	OS.exit_code = 1 if failed > 0 else 0
	quit()
