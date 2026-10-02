extends SceneTree

# Autoprueba del modelo puro de shell/system_osd.gd (parsers de volumen y brillo).
# No toca hardware ni lanza comandos: sólo los parseos y constantes.
#   godot --no-window --path shell -s $PWD/tests/system_osd_test.gd

var failed = 0


func check(name, ok):
	print(("ok   " if ok else "FAIL ") + name)
	if not ok:
		failed += 1


func _init():
	var osd = load("res://system_osd.gd").new()

	var a = osd.parse_wpctl(PoolStringArray(["Volume: 0.98"]))
	check("wpctl: volumen simple", abs(float(a.volume) - 0.98) < 0.001 and not a.muted)
	var b = osd.parse_wpctl(PoolStringArray(["Volume: 0.40 [MUTED]"]))
	check("wpctl: muteado", abs(float(b.volume) - 0.40) < 0.001 and b.muted)

	var pv = osd.parse_pactl_volume(PoolStringArray([
		"Volume: front-left: 65536 / 100% / 0.00 dB, front-right: 65536 / 100% / 0.00 dB"]))
	check("pactl: volumen por porcentaje", abs(float(pv) - 1.0) < 0.001)
	check("pactl: mute yes", osd.parse_pactl_mute(PoolStringArray(["Mute: yes"])))
	check("pactl: mute no", not osd.parse_pactl_mute(PoolStringArray(["Mute: no"])))

	var am = osd.parse_amixer(PoolStringArray([
		"Front Left: Playback 40 [40%] [-30.00dB] [on]"]))
	check("amixer: volumen 40%", abs(float(am.volume) - 0.40) < 0.001 and not am.muted)
	var am2 = osd.parse_amixer(PoolStringArray(["[50%] [off]"]))
	check("amixer: mute off", am2.muted)

	check("parse_pct/pct_of redondean", osd.parse_pct(55) == 0.55 and osd.pct_of(0.55) == 55)

	# Constantes del motor (deben coincidir con core/os/keyboard.h).
	check("constantes multimedia", osd.KEY_VOLUMEUP == (16777216 | 0x46)
		and osd.KEY_VOLUMEDOWN == (16777216 | 0x44)
		and osd.KEY_VOLUMEMUTE == (16777216 | 0x45)
		and osd.KEY_BRIGHTNESSUP == (16777216 | 0x35)
		and osd.KEY_BRIGHTNESSDOWN == (16777216 | 0x34))

	check("which encuentra sh", osd.which("sh") != "")

	OS.exit_code = 1 if failed > 0 else 0
	quit()
