# Portal del input remoto. El backend org.freedesktop.impl.portal.RemoteDesktop lo
# implementa el propio shell (libei, ver modules/wayland/eis_server.c) y se enruta con
# ~/.config/xdg-desktop-portal/gdtk-portals.conf, que xdg-desktop-portal elige según
# XDG_CURRENT_DESKTOP. Problema: el servicio xdg-desktop-portal.service del usuario es
# único y puede venir ya arrancado de otra sesión (o activado por systemd sin escritorio),
# en cuyo caso no ve nuestro desktop y RemoteDesktop cae en el backend gtk, que no lo
# implementa (Deskflow falla con "la interfaz ... no existe").
#
# Por eso, al arrancar la sesión gdtk: se fija XDG_CURRENT_DESKTOP en el gestor de systemd
# del usuario y, si el portal ya estaba corriendo, se reinicia para que relea la config.
# Si no hay systemd, el portal se activa por D-Bus con el entorno de quien lo pide (ya
# lleva XDG_CURRENT_DESKTOP de la sesión) y no hace falta nada más.
export XDG_CURRENT_DESKTOP=gdtk
if command -v systemctl >/dev/null 2>&1; then
	systemctl --user set-environment XDG_CURRENT_DESKTOP=gdtk 2>/dev/null || true
	systemctl --user try-restart xdg-desktop-portal.service 2>/dev/null || true
fi
