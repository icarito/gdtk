extends Reference

# Estado simulado de la Linterna de casco (FD-298), sin Godot real.
#
# Reproduce solo lo que Odisea expone hoy en `HelmetFlashlight.gd` (bateria y
# encendido/apagado): el widget/pantalla de Odisea no muestra `scan_mode`,
# `spot_range`, `spot_angle`, `light_color` ni `light_energy`, asi que el port
# tampoco. `tick()` es el `_process(delta)` de HelmetFlashlight (drenaje y
# auto-apagado a 0); `widget_snapshot()` tiene la misma forma que
# `FlashlightScreen.widget_snapshot()`.

signal battery_changed(value, max_value)

var enabled := false
var battery := 100.0
var battery_max := 100.0
var battery_drain_per_second := 0.4
var battery_low_threshold := 20.0

# Debug: fuerza la rama OFFLINE (Manual §7) sin depender del host.
var offline := false

var _last_emitted := 100.0


func get_battery() -> float:
	return battery


func get_battery_max() -> float:
	return battery_max


func is_battery_low() -> bool:
	return battery <= battery_low_threshold


func toggle() -> void:
	if offline:
		return
	set_enabled(not enabled)


func set_enabled(value: bool) -> void:
	if value and battery <= 0.0:
		value = false
	enabled = value


# Drenaje identico a HelmetFlashlight._process (lineas 220-239): auto-apagado a 0 y
# emision del cambio cuando cae >= 1.0 o cruza el umbral de bateria baja.
func tick(delta: float) -> void:
	if not enabled:
		return
	if battery > 0.0:
		var prev := battery
		battery = max(0.0, battery - battery_drain_per_second * delta)
		if battery <= 0.0:
			battery = 0.0
			_last_emitted = 0.0
			emit_signal("battery_changed", battery, battery_max)
			set_enabled(false)
		elif abs(battery - _last_emitted) >= 1.0 or (prev > battery_low_threshold and battery <= battery_low_threshold):
			_last_emitted = battery
			emit_signal("battery_changed", battery, battery_max)


# Boton de debug del overlay: fuerza "bateria baja" sin esperar el drenaje real.
func force_low() -> void:
	if battery > battery_low_threshold:
		battery = max(0.0, battery_low_threshold - 2.0)
	emit_signal("battery_changed", battery, battery_max)


# Forma identica a FlashlightScreen.widget_snapshot() (Odisea lines 49-58).
func widget_snapshot() -> Dictionary:
	var is_offline := offline
	return {
		"proto": 1,
		"id": "player:flashlight",
		"title": "Linterna",
		"on": enabled,
		"battery": battery,
		"battery_max": battery_max,
		"low": is_battery_low() if not is_offline else false,
		"source": "offline" if is_offline else "online",
	}
