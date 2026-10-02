extends "res://pages/page.gd"

# Página de control compartido. Settings declara la intención fina; el shell genera
# los archivos de Deskflow y arranca/para el servicio si se pide inicio automático.

var mode = null
var host_input = null
var port = null
var local_name = null
var auto = null
var hint = null


func _build():
	h_title("Compartir control")
	h_note("Configura desde dónde se comparte el teclado y el mouse. La posición relativa se ajusta en Pantallas.")
	h_gap(6)

	var row = h_row()
	h_label("Modo", row)
	mode = OptionButton.new()
	STYLE.apply_option(mode)
	for id in model.CONTROL_MODES:
		mode.add_item(String(model.CONTROL_MODE_LABELS[id]))
		mode.set_item_metadata(mode.get_item_count() - 1, id)
	mode.selected = _mode_index(_current().mode)
	mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode.connect("item_selected", self, "_changed")
	row.add_child(mode)

	row = h_row()
	h_label("Equipo a usar", row)
	host_input = LineEdit.new()
	host_input.placeholder_text = "bastion.local"
	host_input.text = _current().host
	host_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	host_input.connect("text_changed", self, "_changed_text")
	row.add_child(host_input)

	row = h_row()
	h_label("Puerto", row)
	port = SpinBox.new()
	port.min_value = 1
	port.max_value = 65535
	port.step = 1
	port.value = _current().port
	port.connect("value_changed", self, "_changed_number")
	row.add_child(port)

	row = h_row()
	h_label("Nombre de este equipo", row)
	local_name = LineEdit.new()
	local_name.placeholder_text = OS.get_environment("HOSTNAME")
	local_name.text = _current().name
	local_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	local_name.connect("text_changed", self, "_changed_text")
	row.add_child(local_name)

	auto = CheckBox.new()
	auto.text = "Iniciar automáticamente al aplicar"
	auto.pressed = bool(_current().auto)
	STYLE.apply_button(auto)
	auto.connect("toggled", self, "_changed_bool")
	box.add_child(auto)

	hint = STYLE.note("")
	box.add_child(hint)
	_sync_enabled()


func _current():
	return model.deskflow(settings.get("deskflow", {}))


func _mode_index(id):
	for i in range(model.CONTROL_MODES.size()):
		if String(model.CONTROL_MODES[i]) == String(id):
			return i
	return 0


func _selected_mode():
	var idx = mode.get_selected()
	return String(mode.get_item_metadata(idx)) if idx >= 0 else "off"


func _changed(_value = null):
	_commit()


func _changed_text(_value):
	_commit()


func _changed_number(_value):
	_commit()


func _changed_bool(_value):
	_commit()


func _commit():
	var raw = {
		"mode": _selected_mode(),
		"host": host_input.text,
		"port": int(port.value),
		"name": local_name.text,
		"auto": auto.pressed,
	}
	var clean = model.deskflow(raw)
	settings["deskflow"] = clean
	host_input.set_text(clean.host)
	port.value = clean.port
	local_name.set_text(clean.name)
	host.set_field("deskflow", clean)
	_sync_enabled()


func _sync_enabled():
	var m = _selected_mode() if mode != null else _current().mode
	var uses_remote = m == "use_remote"
	host_input.editable = uses_remote
	port.editable = m != "off"
	local_name.editable = m != "off"
	auto.disabled = m == "off"
	if hint == null:
		return
	match m:
		"use_remote":
			hint.text = "Este equipo se conecta al equipo indicado. Para tengu/cupid, usa bastion.local o la IP de bastion."
		"share_here":
			hint.text = "Este equipo acepta conexiones según la distribución guardada en Pantallas."
		_:
			hint.text = "El control compartido queda apagado desde gdtk."
