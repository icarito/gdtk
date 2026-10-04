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
#
# Sólo se hace si de verdad corremos una sesión gdtk: lanzar este script a mano en otra
# sesión (pruebas) dejaba el gestor de systemd del usuario en gdtk y le rompía el portal
# a GNOME/xfce (sin InputCapture, etc.).

# --- Archivos de configuración del portal (idempotente, sin efectos en otras sesiones) ---
# Routing: ScreenCast/Screenshot al backend wlroots, RemoteDesktop/InputCapture al shell.
# Se instala siempre (también en sesiones de prueba sin la marca gdtk), así el routing no
# depende de cómo se lanzó la sesión.
_session_dir="${HERE:-}/session"
if [ ! -f "$_session_dir/gdtk-portals.conf" ] && [ -n "${0:-}" ]; then
	_session_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
fi
if [ -f "$_session_dir/gdtk-portals.conf" ]; then
	mkdir -p "$HOME/.config/xdg-desktop-portal" 2>/dev/null || true
	cp -f "$_session_dir/gdtk-portals.conf" "$HOME/.config/xdg-desktop-portal/gdtk-portals.conf" 2>/dev/null || true
fi

# Backend wlroots (xdg-desktop-portal-wlr): config del ScreenCast. El shell va fullscreen
# sobre sway, así que "chooser_type=none" captura la (única) salida = todo gdtk, sin
# selector que taparle la pantalla a la persona.
if [ -x /usr/lib/xdg-desktop-portal-wlr ]; then
	mkdir -p "$HOME/.config/xdg-desktop-portal-wlr" 2>/dev/null || true
	cat > "$HOME/.config/xdg-desktop-portal-wlr/config" <<'EOF'
# Gestionado por la sesión gdtk (session/portal.sh): ScreenCast de Meet/Zoom vía
# wlr-screencopy / ext-image-copy-capture sobre sway. El shell va fullscreen, así que
# la salida capturada es todo el escritorio gdtk.
[screencast]
max_fps=30
chooser_type=none
EOF
	# El servicio de xdpw tiene ConditionEnvironment=WAYLAND_DISPLAY: si el gestor de
	# systemd trae un WAYLAND_DISPLAY viejo (p. ej. el socket del compositor anidado),
	# xdpw arranca pero no conecta. Este drop-in lo fuerza al socket de sway, que
	# sway.conf deja en gdtk-sway-env. `-` = no fallar si todavía no existe.
	if command -v systemctl >/dev/null 2>&1; then
		_drop="$HOME/.config/systemd/user/xdg-desktop-portal-wlr.service.d"
		mkdir -p "$_drop" 2>/dev/null || true
		cat > "$_drop/override.conf" <<'EOF'
[Service]
EnvironmentFile=-%t/gdtk-sway-env
EOF
		systemctl --user daemon-reload 2>/dev/null || true
	fi
elif command -v pipewire >/dev/null 2>&1; then
	# El backend wlroots no está instalado (?xdg-desktop-portal-wlr): sin él no hay
	# ScreenCast. Se anota una sola vez, no se aborta la sesión.
	_log="$HOME/.local/state/gdtk/autostart.log"
	mkdir -p "$(dirname "$_log")" 2>/dev/null || true
	echo "portal: falta xdg-desktop-portal-wlr; compartir pantalla (Meet/Zoom) no andará" >> "$_log" 2>/dev/null || true
fi

case "${DESKTOP_SESSION:-}${XDG_SESSION_DESKTOP:-}" in
	*gdtk*) ;;
	*) return 0 2>/dev/null || exit 0 ;;
esac
export XDG_CURRENT_DESKTOP=gdtk
if command -v systemctl >/dev/null 2>&1; then
	systemctl --user set-environment XDG_CURRENT_DESKTOP=gdtk 2>/dev/null || true
	systemctl --user try-restart xdg-desktop-portal.service 2>/dev/null || true
fi
