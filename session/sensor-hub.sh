#!/bin/sh
# Habilita los sensores del Surface Pro 3 (acelerómetro, giroscopio, ALS,
# magnetómetro, inclinación) sin reactivar el táctil N-Trig dañado.
#
# Por qué no basta con cargar i2c_hid: en este equipo el sensor hub (MSHW0030) y
# el táctil (NTRG0001) son ambos I2C-HID y el módulo i2c_hid_acpi auto-enlaza los
# dos. El N-Trig está blacklisteado (i2c_hid/i2c_hid_acpi en
# /etc/modprobe.d/disable-touch.conf). La salida es que cuelgan de controladores
# I2C distintos: MSHW0030 del INT33C2 (i2c-0) y NTRG0001 del INT33C3 (i2c-1).
# Acá se desbinda el controlador del táctil (así NTRG0001 nunca llega a probe-ar
# y no hay eventos fantasma), y recién entonces se carga i2c_hid_acpi a mano
# (modprobe explícito ignora el blacklist), dejando sólo MSHW0030.
#
# Idempotente y opcional: no hace nada si no es un SP3 o si ya hay acelerómetro.
# Usa `sudo -n` (igual que el resto del deploy); si falla, lo anota y la sesión
# sigue. Log: ~/.local/state/gdtk/autostart.log.

log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/gdtk"
log="$log_dir/autostart.log"
mkdir -p "$log_dir" 2>/dev/null || true

say() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$log" 2>/dev/null || true; }
have() { command -v "$1" >/dev/null 2>&1; }

has_accel() {
	for _n in /sys/bus/iio/devices/iio:device*/name; do
		[ -f "$_n" ] || continue
		grep -qi accel "$_n" && return 0
	done
	return 1
}

# Sólo Surface Pro 3: allí MSHW0030 es el sensor hub I2C-HID.
_dmi="$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
[ "$_dmi" = "Surface Pro 3" ] || exit 0

has_accel && { say "sensor-hub: acelerómetro ya presente"; exit 0; }

# El táctil N-Trig cuelga del controlador INT33C3 (i2c-1). Desbinguiéndolo el
# cliente NTRG0001 desaparece antes de que i2c_hid_acpi pueda enlazarlo.
_ctrl=/sys/devices/pci0000:00/INT33C3:00
if [ -L "$_ctrl/driver" ]; then
	_drv="$(basename "$(readlink -f "$_ctrl/driver" 2>/dev/null)")"
	if [ -n "$_drv" ] \
		&& printf '%s\n' INT33C3:00 | sudo -n tee "/sys/bus/platform/drivers/$_drv/unbind" >/dev/null 2>&1; then
		say "sensor-hub: controlador del táctil INT33C3 deshabilitado ($_drv)"
	else
		say "sensor-hub: no se pudo deshabilitar INT33C3 (¿sudo sin contraseña?)"
		exit 0
	fi
fi

if sudo -n modprobe i2c_hid_acpi >/dev/null 2>&1; then
	say "sensor-hub: i2c_hid_acpi cargado (MSHW0030 -> IIO)"
else
	say "sensor-hub: modprobe i2c_hid_acpi falló"
	exit 0
fi

# iio-sensor-proxy expone la orientación por D-Bus (net.hadess.SensorProxy);
# lo consume session/gdtk-rotate.
if have systemctl; then
	sudo -n systemctl start iio-sensor-proxy >/dev/null 2>&1 \
		&& say "sensor-hub: iio-sensor-proxy activo" \
		|| say "sensor-hub: iio-sensor-proxy no arrancó (se usará si ya corre)"
fi
