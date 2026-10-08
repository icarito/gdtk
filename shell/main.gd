extends Node

# Escena persistente: instancia el shell y puede recambiarlo sin cerrar las apps.
# El compositor Wayland y el EIS viven en el autoload Host (ver host.gd).
#
# El handoff es transaccional (SPEC-session-continuity C1): se compila e instancia
# el candidato antes de tocar el shell activo, de modo que un shell.gd inválido
# deja la UI viva y permite corregir el archivo y reintentar. La secuencia y los
# estados observables viven en reload_plan.gd; acá sólo están las operaciones.

var shell = null

var _plan = null
var _pending_services = {}
var _prev_layout = null


func _ready():
	Host.main = self
	Host.reload_status = {"generation": 0, "state": "idle", "error": "",
		"changed_ms": OS.get_ticks_msec()}
	reload_shell()


# Devuelve true si el candidato quedó agregado y cableado. Un fallo esperado de
# parseo/compilación o instanciación conserva el shell activo, publica el estado
# en Host.reload_status y NO reinicia el proceso: se puede corregir shell.gd y
# volver a pedir la recarga.
func reload_shell():
	var plan = _get_plan()
	if plan == null:
		Host.reload_status = {"generation": 0, "state": "failed",
			"error": "no se pudo compilar reload_plan.gd",
			"changed_ms": OS.get_ticks_msec()}
		push_error("gdtk: no se pudo compilar reload_plan.gd")
		return false
	var ok = plan.run(self, shell)
	Host.reload_status = plan.status()
	if not ok:
		push_error("gdtk: recarga fallida (%s): %s" % [plan.state, plan.error])
	return ok


func _get_plan():
	if _plan == null:
		var script = Host.sc("res://reload_plan.gd")
		if script == null:
			return null
		_plan = script.new()
	return _plan


# --- driver del ReloadPlan (SPEC-session-continuity C1) --------------------
# Cada método es una operación chica del handoff. El activo nunca se toca hasta
# que el candidato compiló e instanció (los dos primeros pasos fallan temprano).

func _handoff_compile():
	return Host.sc("res://shell.gd")


func _handoff_construct(script):
	if script == null:
		return null
	return script.new()


# Guarda lo necesario para reinsertar el activo tal cual si el swap no termina:
# el layout previo (por si _save_layout lo pisó) y los service_pids a copiar.
func _handoff_stage(active):
	_pending_services = {}
	_prev_layout = null
	if active == null or not is_instance_valid(active):
		return
	if active.has_method("_save_layout"):
		_prev_layout = Host.layout.duplicate(true)
		active._save_layout()
	var svc = active.get("service_pids")
	if svc != null:
		_pending_services = svc.duplicate()


func _handoff_set_live(v):
	Host.live_reload = v


func _handoff_detach(active):
	if active != null and is_instance_valid(active) and active.get_parent() == self:
		remove_child(active)


func _handoff_attach(candidate):
	if candidate == null or not is_instance_valid(candidate):
		return false
	candidate.name = "Shell"
	candidate.service_pids = _pending_services
	add_child(candidate)
	if candidate.get_parent() != self:
		return false
	shell = candidate
	return true


func _handoff_wire(candidate):
	Host.reload_remote()  # también toma cambios de remote.gd/peer_control.gd
	if Host.remote != null:
		Host.remote.shell = candidate
	if Host.peer_control != null:
		Host.peer_control.shell = candidate
	if Host.kdeconnect != null:
		Host.kdeconnect.shell = candidate


# Handoff falló después de retirar el activo: reinsertarlo y devolver el layout
# previo antes de siquiera considerar un reinicio del proceso.
func _handoff_restore(active):
	if active != null and is_instance_valid(active) and active.get_parent() == null:
		add_child(active)
	if _prev_layout != null:
		Host.layout = _prev_layout
	shell = active


func _handoff_dispose(active):
	if active != null and is_instance_valid(active):
		if active.get_parent() == self:
			remove_child(active)
		active.free()
