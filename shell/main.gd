extends Node

# Escena persistente: instancia el shell y puede recambiarlo sin cerrar las apps.
# El compositor Wayland y el EIS viven en el autoload Host (ver host.gd).

var shell = null


func _ready():
	Host.main = self
	reload_shell()


func reload_shell():
	var services = {}
	if shell != null and is_instance_valid(shell):
		services = shell.service_pids.duplicate()
		if shell.has_method("_save_layout"):
			shell._save_layout()
		remove_child(shell)
		shell.free()
	Host.live_reload = true
	shell = Host.sc("res://shell.gd").new()
	shell.name = "Shell"
	shell.service_pids = services
	add_child(shell)
	Host.reload_remote()  # también toma cambios de remote.gd
	if Host.remote != null:
		Host.remote.shell = shell
	Host.live_reload = false
