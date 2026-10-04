extends Reference

# Applet Audio del Frame: a dónde sale el sonido de este equipo. Se arrastra sobre un
# equipo de la vista Grupo para mandarle todo el audio y sobre «Este equipo» para
# traerlo de vuelta (SPEC-sugar-group-2026-10.md «Enviar audio y ventanas»).
# Sin worker: el túnel lo maneja el shell, que llama set_dest() al cambiar.

var state = "listo"
var value = "Aquí"
var detail = "Arrastralo sobre un equipo del Grupo para sacar el sonido por ahí"

var _changed = false


func set_dest(name):
	var n = String(name)
	var st = "activo" if n != "" else "listo"
	var v = n if n != "" else "Aquí"
	_changed = _changed or st != state or v != value
	state = st
	value = v
	detail = ("Sonando en " + n + ". Soltalo sobre «Este equipo» para traerlo de vuelta") if n != "" \
		else "Arrastralo sobre un equipo del Grupo para sacar el sonido por ahí"


func refresh(_force := false):
	var c = _changed
	_changed = false
	return c


func stop():
	pass
