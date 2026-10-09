extends SceneTree

# Ejecuta el vigía real con un snapshot de worker y un RemoteInput falso.
var failed = 0
class Capture:
	extends Reference
	var active = false
	var releases = 0
	func has_method(name):
		return name == "release_capture"
	func is_capturing():
		return active
	func release_capture():
		releases += 1
		active = false
		return true
class Model:
	extends Reference
	func deskflow(cfg):
		return cfg
class Settings:
	extends Reference
	var model = Model.new()
	var settings = {"deskflow": {"name": "bastion"}}
func check(label, ok):
	print(("ok   " if ok else "FAIL ") + label)
	if not ok:
		failed += 1
func function(source, name):
	var start = source.find("func " + name + "(")
	var end = source.find("\nfunc ", start + 1)
	return source.substr(start, end - start if end >= 0 else source.length() - start)
func _init():
	var f = File.new()
	f.open("res://shell.gd", File.READ)
	var source = f.get_as_text()
	f.close()
	var harness = "extends Reference\nvar DESKFLOW_WATCH = load(\"res://deskflow_watch.gd\")\nvar remote_input\nvar settings_bridge\nvar _svc_mutex = Mutex.new()\nvar _df_log_snapshot = {}\nvar _df_watch_at = 0\nvar _df_watch_baseline = \"\"\nvar _df_watch_capturing = false\nvar _df_mismatch = 0\nfunc _deskflow_local_name(name):\n\treturn name\nfunc _set_capture_cursor(_active):\n\tpass\nfunc request_redraw():\n\tpass\n"
	for name in ["_deskflow_log_state", "_deskflow_watch"]:
		harness += "\n" + function(source, name)
	var script = GDScript.new()
	script.set_source_code(harness)
	var err = script.reload()
	check("vigía real compila", err == OK)
	if err != OK:
		OS.exit_code = 1
		quit()
		return
	var shell = script.new()
	shell.remote_input = Capture.new()
	shell.settings_bridge = Settings.new()
	var old = "[1] INFO: switch from \"tengu\" to \"bastion\" at 1,2\n"
	shell._df_log_snapshot = {"text": old, "sampled_at": 1000}
	shell._deskflow_watch(1000) # consume evento antes del nuevo cruce
	shell.remote_input.active = true
	for now in [1300, 1600, 1900]:
		shell._df_log_snapshot = {"text": old + "[2] WARNING: x11\n", "sampled_at": now}
		shell._deskflow_watch(now)
	check("captura nueva no cae por switch local viejo", shell.remote_input.releases == 0)
	var gone = old + "[3] INFO: switch from \"bastion\" to \"tengu\" at 2,3\n[4] IPC: client \"tengu\" is dead\n"
	shell._df_log_snapshot = {"text": gone, "sampled_at": 2200}
	shell._deskflow_watch(2200)
	check("caída nueva rescata la captura", shell.remote_input.releases == 1)
	shell.remote_input.active = true
	for now in [2500, 2800, 3100]:
		shell._df_log_snapshot = {"text": gone + "[5] WARNING: x11\n", "sampled_at": now}
		shell._deskflow_watch(now)
	check("no repite rescate por caída ya consumida", shell.remote_input.releases == 1)
	var jump = gone + "[6] INFO: jump from \"tengu\" to \"bastion\" at 960,540\n"
	for now in [3400, 3700, 4000]:
		shell._df_log_snapshot = {"text": jump, "sampled_at": now}
		shell._deskflow_watch(now)
	check("jump nuevo recupera el cursor local", shell.remote_input.releases == 2)
	shell.remote_input.active = true
	shell._df_log_snapshot = {"text": gone, "sampled_at": 0}
	shell._deskflow_watch(4300)
	check("snapshot vencido no suelta captura", shell.remote_input.releases == 2)
	OS.exit_code = 1 if failed else 0
	quit()
