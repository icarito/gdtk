extends Node

# Host persistente del shell (handoff en proceso): es dueño del compositor Wayland y del
# input remoto EIS, así sobreviven al recambio del shell. Las apps siguen conectadas a
# este compositor, por lo que recargar el shell (GDScript) no las cierra.
# No cubre cambios del binario/módulo C++: eso sigue necesitando reiniciar el proceso.

var compositor = null
var remote_input = null
var remote = null        # control remoto JSON-RPC (remote.gd)
var main = null          # main.gd, para pedirle la recarga
var live_reload = false  # true mientras se instancia el shell por recarga
var layout = {}          # layout del shell (orden/grupos/foco) para restaurar tras recargar


func _ready():
	compositor = WaylandCompositor.new()
	compositor.name = "Compositor"
	add_child(compositor)
	var socket = compositor.start()
	if socket == "":
		printerr("Host: no se pudo iniciar el compositor wayland")
	else:
		print("compositor socket: ", socket)
		# Publica el socket del compositor interno en un archivo estable del runtime
		# dir: otros gdtk (p. ej. el receptor remoto lanzado por ssh para "Extender")
		# lo leen sin depender del número wayland-N ni de adivinar cuál es.
		var rt = OS.get_environment("XDG_RUNTIME_DIR")
		if rt != "":
			var f = File.new()
			if f.open(rt.plus_file("gdtk-wayland"), File.WRITE) == OK:
				f.store_line(socket)
				f.close()

	remote_input = RemoteInput.new()
	remote_input.name = "RemoteInput"
	add_child(remote_input)
	var rerr = remote_input.start()
	if rerr != "":
		print("RemoteInput: ", rerr)

	remote = load("res://remote.gd").new()
	remote.name = "Remote"
	add_child(remote)


# Recrea el control remoto (remote.gd) para que un reload también tome sus cambios.
func reload_remote():
	if remote != null and is_instance_valid(remote):
		remove_child(remote)
		remote.free()
	remote = sc("res://remote.gd").new()
	remote.name = "Remote"
	add_child(remote)


# Script sin caché: una recarga toma los .gd nuevos del disco. ResourceLoader con
# no_cache NO alcanza para GDScript (Godot 3 cachea los scripts compilados), así que se
# compila desde el texto del archivo con GDScript.set_source_code + reload.
func sc(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		printerr("Host.sc: no se pudo leer ", path)
		return null
	var src = f.get_as_text()
	f.close()
	var g = GDScript.new()
	g.set_source_code(src)
	var err = g.reload()
	if err != OK:
		printerr("Host.sc: error compilando ", path, " (", err, ")")
		return null
	return g


func reload_shell():
	if main != null:
		main.reload_shell()
