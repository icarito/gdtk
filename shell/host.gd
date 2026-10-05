extends Node

# Host persistente del shell (handoff en proceso): es dueño del compositor Wayland y del
# input remoto EIS, así sobreviven al recambio del shell. Las apps siguen conectadas a
# este compositor, por lo que recargar el shell (GDScript) no las cierra.
# No cubre cambios del binario/módulo C++: eso sigue necesitando reiniciar el proceso.

var compositor = null
var remote_input = null
var remote = null        # control remoto JSON-RPC (remote.gd)
var peer_control = null  # canal peer LAN sin ssh (peer_control.gd)
var main = null          # main.gd, para pedirle la recarga
var live_reload = false  # true mientras se instancia el shell por recarga
var layout = {}          # layout del shell (orden/grupos/foco) para restaurar tras recargar
var reload_status = {}   # estado del último handoff (SPEC-session-continuity C1)
var health_model = null  # snapshot puro del heartbeat (health_snapshot.gd, C2)
var _health_path = ""    # $XDG_RUNTIME_DIR/gdtk/health.json; "" si no hay latido
var _health_interval_ms = 1000
var _health_last_ms = 0
var _health_sequence = 0


func _ready():
	compositor = WaylandCompositor.new()
	compositor.name = "Compositor"
	add_child(compositor)
	var socket = compositor.start()
	if socket == "":
		printerr("Host: no se pudo iniciar el compositor wayland")
	else:
		print("compositor socket: ", socket)
		# Diagnóstico de rendimiento (SPEC-rendimiento-compositor): deja en shell.log si los
		# clientes usan GPU (dmabuf) o copia por CPU (shm). Si dice "off", las apps van por
		# software y el alto consumo de CPU/FPS bajo no es del shell.
		if compositor.has_method("get_dmabuf_state"):
			print("compositor dmabuf: ", compositor.dmabuf_state)
		# Sincronización explícita (P2): "on" o el motivo de seguir en implicit sync.
		if compositor.has_method("get_explicit_sync_state"):
			print("compositor sync explícito: ", compositor.explicit_sync_state)
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

	# Canal peer (LAN, sin ssh) para pedirle a un vecino que abra su receptor gvd.
	peer_control = load("res://peer_control.gd").new()
	peer_control.name = "PeerControl"
	add_child(peer_control)
	var peer_port = int(OS.get_environment("GDTK_PEER_PORT"))
	if peer_port <= 0:
		peer_port = 7788
	peer_control.start(null, peer_port)

	_health_setup()


# --- Heartbeat semántico (SPEC-session-continuity C2) ----------------------
# El event loop escribe $XDG_RUNTIME_DIR/gdtk/health.json a ~1 Hz. `sequence`
# sólo avanza cuando este tick del hilo principal corre: un cuelgue congela el
# archivo y el supervisor deja de promover. El I/O queda acotado a la frecuencia
# elegida; no hay polling ni subprocesos por tick.

func _health_setup():
	var script = load("res://health_snapshot.gd")
	if script == null:
		printerr("Host: no se pudo cargar health_snapshot.gd; sin heartbeat")
		return
	health_model = script.new()
	var rt = OS.get_environment("XDG_RUNTIME_DIR")
	if rt == "":
		# Sin runtime dir no hay path canónico; no se inventa uno.
		printerr("Host: XDG_RUNTIME_DIR vacío; heartbeat desactivado")
		return
	_health_path = health_model.health_path(rt)
	var dir = Directory.new()
	dir.make_dir_recursive(_health_path.get_base_dir())
	if not dir.dir_exists(_health_path.get_base_dir()):
		printerr("Host: no se pudo crear ", _health_path.get_base_dir())
		_health_path = ""
		return
	_chmod_private(_health_path.get_base_dir())
	_health_interval_ms = health_model.interval_ms(OS.get_environment("GDTK_HEALTH_INTERVAL"))
	_health_last_ms = 0
	_health_sequence = 0


# Godot 3 no expone chmod; el XDG_RUNTIME_DIR ya es 0700 y el subdir hereda el
# umask, así que se ajusta una sola vez al arrancar (nunca por tick). Best-effort.
func _chmod_private(dir):
	OS.execute("chmod", ["700", dir], true)


func _process(_delta):
	if _health_path == "" or health_model == null:
		return
	var now = OS.get_ticks_msec()
	if not health_model.should_write(_health_last_ms, now, _health_interval_ms):
		return
	_health_last_ms = now
	_health_sequence += 1
	var snap = health_model.build(OS.get_process_id(), reload_status,
		_health_sequence, now)
	_health_write(health_model.encode(snap))


# Escritura atómica: temporal en el mismo dir + rename. Un lector nunca ve JSON
# parcial; el archivo se reemplaza (no se borra) y no contiene secretos.
func _health_write(body):
	var path = _health_path
	var dir = Directory.new()
	dir.make_dir_recursive(path.get_base_dir())
	var tmp = "%s.%d.tmp" % [path, OS.get_process_id()]
	var w = File.new()
	if w.open(tmp, File.WRITE) != OK:
		printerr("Host: no se pudo escribir heartbeat ", tmp)
		return false
	w.store_string(body)
	w.close()
	if dir.rename(tmp, path) != OK:
		printerr("Host: no se pudo renombrar heartbeat ", tmp, " -> ", path)
		return false
	return true


# Recrea el control remoto (remote.gd) y el canal peer (peer_control.gd) para que un
# reload también tome sus cambios. Compila ambos antes de liberar los viejos: si algo
# no compila, conserva los actuales (una recarga de shell válida no debe quedarse sin
# control remoto ni canal peer). Devuelve true si reemplazó ambos.
func reload_remote():
	var remote_script = sc("res://remote.gd")
	var peer_script = sc("res://peer_control.gd")
	if remote_script == null or peer_script == null:
		printerr("Host.reload_remote: remote.gd/peer_control.gd no compilan; se conservan los actuales")
		return false
	if remote != null and is_instance_valid(remote):
		remove_child(remote)
		remote.free()
	remote = remote_script.new()
	remote.name = "Remote"
	add_child(remote)
	if peer_control != null and is_instance_valid(peer_control):
		remove_child(peer_control)
		peer_control.free()
	peer_control = peer_script.new()
	peer_control.name = "PeerControl"
	add_child(peer_control)
	var peer_port = int(OS.get_environment("GDTK_PEER_PORT"))
	if peer_port <= 0:
		peer_port = 7788
	peer_control.start(null, peer_port)
	return true


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
		return main.reload_shell()
	return false
