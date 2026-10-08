extends SceneTree

# Autoprueba del applet Volumen (shell/applet_volume.gd) y del parser de salidas de
# audio (shell/audio_send.gd). No toca hardware ni lanza procesos: choose() sólo
# encola, así que no debe arrancar el worker.
#   godot --no-window --path shell -s $PWD/tests/applet_volume_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var send = load("res://audio_send.gd")

	# parse_sinks: columnas tab = id, name, driver, format, state; filtra el túnel
	# que crea el propio módulo (prefijo gdtk_send_).
	var short = "0\talsa_output.pci-0000_00_1f.3.analog-stereo\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED\n" \
		+ "1\tgdtk_send_ab12\tPipeWire\ts16le 1ch 48000Hz\tRUNNING\n" \
		+ "2\tbluez_output.AC_12_34\tPipeWire\ts16le 2ch 48000Hz\tIDLE\n"
	var sinks = send.parse_sinks(short)
	check("parse_sinks: cantidad (túnel filtrado)", sinks.size() == 2)
	check("parse_sinks: nombre y estado", sinks.size() == 2 \
		and sinks[0].name == "alsa_output.pci-0000_00_1f.3.analog-stereo" and sinks[0].state == "SUSPENDED" \
		and sinks[1].name == "bluez_output.AC_12_34" and sinks[1].state == "IDLE")
	check("parse_sinks: texto vacío", send.parse_sinks("").size() == 0)
	check("parse_sinks: línea corrupta ignorada", send.parse_sinks("no-es-un-sink\n").size() == 0)
	check("parse_sinks: sin columna de estado", send.parse_sinks("0\talsa_output.foo\n").size() == 1)

	# choose() no ejecuta nada sincrónicamente: valida, encola y no arranca el worker.
	var bad = load("res://applet_volume.gd").new()
	check("choose: vacío rechazado", bad.choose("") == false)

	var vol = load("res://applet_volume.gd").new()
	check("choose: encola sin arrancar worker", vol.choose("alsa_output.foo") == true and not vol.running())
	check("choose: sin lectura síncrona", vol.value == "sin dato" and vol.sinks.size() == 0 and vol.current_sink == "")
	check("choose: estado optimista", vol.state == "cambiando" and vol.detail == "Cambiando la salida de audio…")
	vol.stop()

	OS.exit_code = 1 if failed > 0 else 0
	quit()
