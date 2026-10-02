extends SceneTree
# Preflight del shell: compila cada .gd del arbol para atrapar errores de parseo
# antes de promover una version. res:// apunta a <content>/shell, asi que se corre:
#   godot --no-window --path <content>/shell -s gdtk-preflight.gd
# Imprime "FAIL <ruta>" por cada script que no compila y sale con 3 si hay fallas.
# Cargar un script con error de parseo lo reporta el motor y load() devuelve null.

var total = 0
var fails = []


func _initialize():
	_scan("res://")
	for f in fails:
		print("FAIL ", f)
	print("preflight: %d scripts, %d fallas" % [total, fails.size()])
	OS.exit_code = 0 if fails.empty() else 3
	quit()


func _scan(dir_path):
	var d = Directory.new()
	if d.open(dir_path) != OK:
		return
	d.list_dir_begin(true, true)
	var name = d.get_next()
	while name != "":
		var path = dir_path.plus_file(name)
		if name.ends_with(".gd"):
			total += 1
			if not _compiles(path):
				fails.append(path)
		else:
			_scan(path)
		name = d.get_next()
	d.list_dir_end()


# En este build load() devuelve un GDScript aunque el parseo falle (por eso antes
# daba 0 fallas con scripts rotos). Se compila desde el texto como Host.sc: una
# GDScript nueva + set_source_code + reload, cuyo codigo de error si distingue un
# parseo roto. Los preload() relativos deben escribirse con res:// para que este
# chequeo (sin path de script) los resuelva igual que en runtime.
func _compiles(path):
	var f = File.new()
	if f.open(path, File.READ) != OK:
		return false
	var src = f.get_as_text()
	f.close()
	var g = GDScript.new()
	g.set_source_code(src)
	return g.reload() == OK
