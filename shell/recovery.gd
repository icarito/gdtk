extends Reference

# Reinicio del shell sin perder el estado (ver session/gdtk-supervisor): antes de salir con
# código 75 se guarda qué estaba abierto; al arrancar se reabre de a una actividad.
# Las apps Wayland mueren con el shell (su compositor vive en este proceso): se relanzan.
# ponytail: no se guardan las actividades dinámicas (ventanas que no lanzó el shell).

const EXIT_RESTART = 75
const LAUNCH_TIMEOUT_MS = 10000

var queue = []
var current = ""
var waiting_since = -1


static func state_path():
	var dir = OS.get_environment("XDG_RUNTIME_DIR")
	return (dir if dir != "" else "/tmp").plus_file("gdtk-state.json")


func save(shell):
	var open = []
	for a in shell.ACTIVITIES:
		if a.get("dynamic", false):
			continue
		var alive = shell.wayland_ids.has(a.name) and shell._id_alive(shell.wayland_ids[a.name])
		if alive or shell.script_instances.has(a.name):
			open.append(a.name)
	var state = {"open": open, "current": shell.current_activity.name if shell.current_activity != null else ""}
	var f = File.new()
	if f.open(state_path(), File.WRITE) == OK:
		f.store_string(to_json(state))
		f.close()


func restart(shell):
	save(shell)
	shell.get_tree().quit(EXIT_RESTART)


# Salida pedida por el usuario: la marca le dice al supervisor que termine la sesión aunque
# el motor se caiga al cerrarse (pasa en tengu: free() inválido en el teardown).
static func quit(shell):
	var f = File.new()
	if f.open(state_path().get_base_dir().plus_file("gdtk-quit"), File.WRITE) == OK:
		f.close()
	shell.get_tree().quit()


# Al arrancar: aviso si venimos de una caída y, fuera del modo seguro, estado a restaurar.
func load(shell):
	var crash = OS.get_environment("GDTK_LAST_CRASH")
	if OS.get_environment("GDTK_SAFE") != "":
		shell.activity_error = "Modo a prueba de fallos (GLES2) tras varias caídas. Log: " + crash
		return
	if crash != "":
		shell.activity_error = "El shell se recuperó de una caída. Log: " + crash
	var f = File.new()
	if f.open(state_path(), File.READ) != OK:
		return
	var state = parse_json(f.get_as_text())
	f.close()
	Directory.new().remove(state_path())
	if typeof(state) == TYPE_DICTIONARY:
		queue = state.get("open", [])
		current = state.get("current", "")


# Cada frame: abre la siguiente actividad cuando la anterior ya tiene ventana.
func tick(shell):
	if queue.empty() and current == "":
		return
	shell.request_redraw()  # hasta terminar de reabrir, aunque no haya input
	if shell.pending_wayland != "" and OS.get_ticks_msec() - waiting_since < LAUNCH_TIMEOUT_MS:
		return
	shell.pending_wayland = ""
	if not queue.empty():
		waiting_since = OS.get_ticks_msec()
		shell._open_by_name(queue.pop_front())
		return
	if current != "":
		shell._open_by_name(current)
	else:
		shell._go_home()
	current = ""
