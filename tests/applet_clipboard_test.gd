extends SceneTree

# Applet Portapapeles: resumen del último ítem y elección de la entrada más nueva.
# El script de captura (session/gdtk-clipboard) se prueba aparte, a mano.

var fails = 0


func check(cond, msg):
	if cond:
		print("ok ", msg)
	else:
		fails += 1
		printerr("FAIL ", msg)


func _init():
	var C = load("res://applet_clipboard.gd")
	check(C.summary("") == "", "vacío -> vacío")
	check(C.summary("\n\n  hola   mundo\t x \nsegunda") == "hola mundo x", "primera línea no vacía, espacios colapsados")
	check(C.newest([]) == "", "sin entradas")
	check(C.newest(["1700000000000000002", ".lock", "1700000000000000010", ".in.42"]) == "1700000000000000010",
		"la más nueva gana; ocultas ignoradas")
	var p = C.new()._paths()
	check(p.script.ends_with("/session/gdtk-clipboard") and p.script.find("..") < 0, "ruta del script resuelta")
	# Portapapeles del Grupo: lo copiado acá se encola; lo recibido no rebota.
	var a = C.new()
	a._queue_sync("hola")
	a._last_received = "de tengu"
	a._queue_sync("de tengu")
	a._queue_sync("")
	check(a.take_outbox() == ["hola"], "encola lo local, no lo recibido ni lo vacío")
	check(a.take_outbox().empty(), "take_outbox vacía la cola")
	OS.exit_code = 1 if fails > 0 else 0
	quit()
