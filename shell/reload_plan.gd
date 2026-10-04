extends Reference

# Plan puro del handoff de recarga en caliente (SPEC-session-continuity C1).
# Fija el orden obligatorio y publica el estado observable, pero no toca nodos ni
# Host: recibe un `driver` inyectado (main.gd en producción, un doble en tests)
# que ejecuta las operaciones. Así el handoff queda auditable y se prueba sin
# levantar el compositor real.
#
# Contrato del driver (métodos):
#   _handoff_compile() -> GDScript|null    compila res://shell.gd sin tocar el activo
#   _handoff_construct(script) -> Object|null  instancia el candidato, sin swap
#   _handoff_stage(active) -> void         _save_layout + service_pids del activo
#   _handoff_set_live(bool) -> void        Host.live_reload
#   _handoff_detach(active) -> void        remove_child del activo (sin liberar)
#   _handoff_attach(candidate) -> bool     add_child del candidato (true si quedó)
#   _handoff_wire(candidate) -> void       recablea remote/peer_control
#   _handoff_restore(active) -> void       reinserta el activo si attach falló
#   _handoff_dispose(active) -> void       libera el activo ya reemplazado

const STATES := ["idle", "compiling", "constructing", "swapping", "ready", "failed"]

var state = "idle"
var generation = 0
var error = ""
var changed_ms = 0


# Estado observable (SPEC-session-continuity C1). Sólo diagnóstico, sin secretos.
func status():
	return {"generation": generation, "state": state, "error": error,
		"changed_ms": changed_ms}


func _enter(s, err = ""):
	state = s
	error = err
	changed_ms = OS.get_ticks_msec()
	return status()


func _fail(msg):
	_enter("failed", msg)
	return false


# Ejecuta un intento de handoff sobre `active`. Devuelve true sólo si el candidato
# quedó agregado y cableado; en cualquier fallo el activo permanece.
func run(driver, active):
	generation += 1
	_enter("compiling")
	var script = driver._handoff_compile()
	if script == null:
		driver._handoff_set_live(false)
		return _fail("shell.gd no compiló")

	_enter("constructing")
	var candidate = driver._handoff_construct(script)
	if candidate == null:
		driver._handoff_set_live(false)
		return _fail("no se pudo instanciar el shell candidato")

	_enter("swapping")
	driver._handoff_stage(active)
	driver._handoff_set_live(true)
	driver._handoff_detach(active)
	if not driver._handoff_attach(candidate):
		driver._handoff_restore(active)
		driver._handoff_set_live(false)
		return _fail("no se pudo agregar el shell candidato")

	driver._handoff_wire(candidate)
	driver._handoff_dispose(active)
	driver._handoff_set_live(false)
	_enter("ready")
	return true
