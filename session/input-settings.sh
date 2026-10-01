#!/bin/sh
# Aplica ajustes de entrada del usuario desde ~/.config/gdtk/settings.json.
# Hoy: dirección del desplazamiento (natural) del touchpad Y del mouse/TrackPoint.
# Best effort: sin settings.json o sin swaymsg no hace nada y la sesión sigue con
# el default de sway.conf (natural activo). Lo llama sway al iniciar; el shell lo
# reaplica en vivo al detectar el cambio (sin reiniciar) y la app Configuración al
# togglear.
set -u

cfg="${GDTK_SETTINGS:-${XDG_CONFIG_HOME:-$HOME/.config}/gdtk/settings.json}"
natural=enabled
if [ -r "$cfg" ]; then
	if command -v jq >/dev/null 2>&1; then
		val=$(jq -r 'if .natural_scroll == false then "disabled" else "enabled" end' "$cfg" 2>/dev/null)
		[ -n "$val" ] && natural="$val"
	fi
	# Sin jq (o si no pudo parsear): alcanza con detectar el false explícito.
	if [ "$natural" = enabled ] && grep -q '"natural_scroll"[[:space:]]*:[[:space:]]*false' "$cfg" 2>/dev/null; then
		natural=disabled
	fi
fi

if command -v swaymsg >/dev/null 2>&1; then
	# El scroll natural no es sólo de touchpad: también aplica al mouse/TrackPoint.
	swaymsg input type:touchpad natural_scroll "$natural" >/dev/null 2>&1 || true
	swaymsg input type:pointer natural_scroll "$natural" >/dev/null 2>&1 || true
fi
exit 0
