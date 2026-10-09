#!/bin/sh
# gdtk installer — instala una versión publicada (binario + shell + sesión) en
# ~/gdtk, instala las dependencias del sistema y habilita la entrada de sesión.
#
# Pensado para un equipo x86_64 con Arch/derivadas. Todo se puede ajustar por
# variables de entorno y todo lo que use root está acotado a `sudo`.
#
#   Uso remoto:   curl -fsSL https://raw.githubusercontent.com/icarito/gdtk/main/install.sh | sh
#   Uso local:    ./install.sh [opciones]
#
# Opciones:
#   --home DIR        instalación (default: ~/gdtk)          [GDTK_HOME]
#   --version V       versión a instalar (default: última)    [GDTK_VERSION]
#   --from ARCHIVO    instalar desde un tarball/árbol local    [GDTK_FROM]
#   --driver GLES2|GLES3  driver del shell (default: GLES3)   [GDTK_DRIVER]
#   --no-deps         no instalar dependencias               [GDTK_NO_DEPS=1]
#   --minimal         sólo dependencias esenciales (sin gstreamer/deskflow)
#   --no-session      no tocar /usr/share/wayland-sessions     [GDTK_NO_SESSION=1]
#   -y, --yes         no preguntar                            [GDTK_YES=1]
#   -h, --help        esta ayuda
#
# Variables: GDTK_REPO (default icarito/gdtk), GDTK_DRIVER, GDTK_HOME, GDTK_VERSION,
# GDTK_FROM, GDTK_YES, GDTK_NO_DEPS, GDTK_MINIMAL, GDTK_NO_SESSION.
set -eu

REPO="${GDTK_REPO:-icarito/gdtk}"
HOME_DIR="${GDTK_HOME:-$HOME/gdtk}"
VERSION="${GDTK_VERSION:-latest}"
DRIVER="${GDTK_DRIVER:-GLES3}"
FROM="${GDTK_FROM:-}"
ASSUME_YES="${GDTK_YES:-0}"
WANT_DEPS=1
MINIMAL="${GDTK_MINIMAL:-0}"
WANT_SESSION=1
[ "${GDTK_NO_DEPS:-0}" = 1 ] && WANT_DEPS=0
[ "${GDTK_NO_SESSION:-0}" = 1 ] && WANT_SESSION=0

say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf 'aviso: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		--home) HOME_DIR="$2"; shift 2;;
		--version) VERSION="$2"; shift 2;;
		--from) FROM="$2"; shift 2;;
		--driver) DRIVER="$2"; shift 2;;
		--no-deps) WANT_DEPS=0; shift;;
		--minimal) MINIMAL=1; shift;;
		--no-session) WANT_SESSION=0; shift;;
		-y|--yes) ASSUME_YES=1; shift;;
		-h|--help)
			printf '%s\n' \
				'gdtk installer — instala binario + shell + sesión en ~/gdtk' \
				'' \
				'Uso: install.sh [opciones]' \
				'  --home DIR          instalación (default: ~/gdtk)          [GDTK_HOME]' \
				'  --version V         versión a instalar (default: última)   [GDTK_VERSION]' \
				'  --from ARCHIVO      instalar desde un tarball/árbol local  [GDTK_FROM]' \
				'  --driver GLES2|GLES3  driver del shell (default: GLES3)    [GDTK_DRIVER]' \
				'  --no-deps           no instalar dependencias               [GDTK_NO_DEPS=1]' \
				'  --minimal           sin gstreamer/deskflow/sensores' \
				'  --no-session        no tocar /usr/share/wayland-sessions   [GDTK_NO_SESSION=1]' \
				'  -y, --yes           no preguntar                           [GDTK_YES=1]' \
				'  -h, --help          esta ayuda'
			exit 0;;
		*) die "opción desconocida: $1 (ver --help)";;
	esac
done

[ "$(uname -m)" = "x86_64" ] || die "gdtk se publica sólo para x86_64 (detectado: $(uname -m))"
command -v tar >/dev/null 2>&1 || die "falta 'tar'"
[ -n "$FROM" ] || command -v curl >/dev/null 2>&1 || die "falta 'curl' para descargar la versión publicada"

# --- dependencias -----------------------------------------------------------
# Nombres de paquete para Arch/derivadas. CORE es lo que enlaza el binario;
# el resto son las piezas de la sesión (cada una opcional, la sesión degrada sola).
CORE_PKGS="wlroots0.20 libei sdl2-compat libglvnd libxkbcommon wayland systemd-libs mesa vulkan-icd-loader"
SESSION_PKGS="sway dbus"
PORTAL_PKGS="xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk pipewire pipewire-pulse wireplumber grim wl-clipboard"
SERVICE_PKGS="polkit polkit-gnome gnome-keyring libsecret python python-gobject avahi"
OPTIONAL_PKGS="deskflow libpulse gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav gst-plugin-va iio-sensor-proxy brightnessctl dex"

run_root() {
	# Ejecuta como root sin colgarse si no hay forma de pedir la clave.
	if [ "$(id -u)" = 0 ]; then "$@"; return; fi
	if command -v sudo >/dev/null 2>&1; then
		if sudo -n true 2>/dev/null; then sudo -n "$@"; return; fi
		if [ -t 0 ]; then sudo "$@"; return; fi
	fi
	return 127
}

install_deps() {
	[ "$WANT_DEPS" = 1 ] || { say "dependencias: omitidas (--no-deps)"; return; }
	pkgs="$CORE_PKGS $SESSION_PKGS $PORTAL_PKGS $SERVICE_PKGS"
	[ "$MINIMAL" = 1 ] || pkgs="$pkgs $OPTIONAL_PKGS"
	if command -v pacman >/dev/null 2>&1; then
		say "dependencias (pacman): instalando $CORE_PKGS $SESSION_PKGS $PORTAL_PKGS $SERVICE_PKGS$( [ "$MINIMAL" = 1 ] || printf ' + opcionales')"
		if ! run_root pacman -S --needed --noconfirm $pkgs; then
			warn "no se pudieron instalar todas las dependencias; hacelo a mano:"
			note "sudo pacman -S --needed $pkgs"
		fi
	elif command -v apt-get >/dev/null 2>&1; then
		say "dependencias (apt): adaptando nombres Debian/Ubuntu"
		apt_pkgs="sway dbus xdg-desktop-portal xdg-desktop-portal-wlr xdg-desktop-portal-gtk pipewire pipewire-pulse wireplumber grim wl-clipboard policykit-1 policykit-1-gnome gnome-keyring libsecret-1-0 python3 python3-gi avahi-daemon libpulse0"
		[ "$MINIMAL" = 1 ] || apt_pkgs="$apt_pkgs deskflow gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav iio-sensor-proxy brightnessctl"
		run_root apt-get update || true
		if ! run_root apt-get install -y --no-install-recommends $apt_pkgs; then
			warn "no se pudieron instalar todas las dependencias (¿wlroots 0.20 / libei disponibles?)"
			note "El binario necesita wlroots 0.20, libei y sdl2; en Ubuntu puede que falten."
		fi
	else
		warn "gestor de paquetes desconocido; instalá a mano las dependencias:"
		note "core: $CORE_PKGS"
		note "sesión: $SESSION_PKGS"
		note "portales: $PORTAL_PKGS"
		note "servicios: $SERVICE_PKGS"
	fi
}

# --- obtener la versión -----------------------------------------------------
resolve_tag() {
	# latest -> tag_name de la última release (sin depender de jq).
	api="https://api.github.com/repos/$REPO/releases/latest"
	tag="$(curl -fsSL "$api" 2>/dev/null | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
	[ -n "$tag" ] || die "no pude resolver la última release de $REPO (¿existe alguna publicada?)"
	printf '%s\n' "$tag"
}

fetch() {
	# Deja el tarball en la variable global TGZ.
	if [ -n "$FROM" ]; then
		say "usando artefacto local: $FROM"
		TGZ="$tmp/local.tar.gz"
		if [ -d "$FROM" ]; then
			tar -czf "$TGZ" -C "$FROM" .
		else
			cp "$FROM" "$TGZ"
		fi
		return
	fi
	if [ "$VERSION" = latest ]; then
		tag="$(resolve_tag)"
		ver="${tag#v}"
	else
		tag="v${VERSION#v}"; ver="${VERSION#v}"
	fi
	say "descargando gdtk $ver desde $REPO"
	name="gdtk-$ver-linux-x86_64.tar.gz"
	base="https://github.com/$REPO/releases/download/$tag/$name"
	TGZ="$tmp/$name"
	curl -fL --retry 3 -o "$TGZ" "$base" || die "no pude descargar $base"
	# checksum opcional: si existe el .sha256, verificarlo.
	if curl -fsL --retry 3 -o "$tmp/$name.sha256" "$base.sha256" 2>/dev/null; then
		( cd "$tmp" && sha256sum -c "$name.sha256" >/dev/null 2>&1 ) || die "la verificación sha256 falló"
		say "sha256 verificado"
	else
		warn "sin archivo .sha256 para verificar la descarga"
	fi
}

# --- instalar ---------------------------------------------------------------
install_tree() {
	src="$1"
	say "instalando en $HOME_DIR"
	mkdir -p "$HOME_DIR"
	# Reemplazar el árbol administrado; la configuración del usuario vive en
	# ~/.config/gdtk y ~/.local/state/gdtk, así que no se toca.
	for d in shell settings addons mcp tools; do rm -rf "$HOME_DIR/$d"; done
	for d in shell settings addons mcp tools; do
		[ -d "$src/$d" ] && cp -a "$src/$d" "$HOME_DIR/$d"
	done
	mkdir -p "$HOME_DIR/session" "$HOME_DIR/bin"
	[ -d "$src/session" ] && cp -a "$src/session/." "$HOME_DIR/session/"
	[ -f "$src/bin/godot-gdtk" ] && cp -a "$src/bin/godot-gdtk" "$HOME_DIR/bin/godot-gdtk"
	[ -f "$src/VERSION" ] && cp -a "$src/VERSION" "$HOME_DIR/VERSION"
	chmod +x "$HOME_DIR"/session/* "$HOME_DIR/bin/godot-gdtk" 2>/dev/null || true
	[ -x "$HOME_DIR/bin/godot-gdtk" ] || die "el artefacto no trae bin/godot-gdtk"
}

write_desktops() {
	# Exec absoluto: un .desktop no expande $HOME.
	for entry in "gdtk.desktop:gdtk:gdtk-session-sway" \
	             "gdtk-sway.desktop:gdtk (sway):gdtk-session-sway" \
	             "gdtk-x11.desktop:gdtk X11 (lápiz Wacom):gdtk-session-x11"; do
		file="${entry%%:*}"; rest="${entry#*:}"; name="${rest%%:*}"; script="${rest##*:}"
		printf '[Desktop Entry]\nName=%s\nComment=Shell tipo Sugar sobre Godot/ImGui con compositor wlroots embebido\nExec=env GDTK_VIDEO_DRIVER_FORCE=%s %s/session/%s\nType=Application\nDesktopNames=gdtk\n' \
			"$name" "$DRIVER" "$HOME_DIR" "$script" >"$HOME_DIR/session/$file"
	done
}

install_portals() {
	conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/xdg-desktop-portal"
	data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/xdg-desktop-portal/portals"
	mkdir -p "$conf_dir" "$data_dir"
	[ -f "$HOME_DIR/session/gdtk-portals.conf" ] && cp "$HOME_DIR/session/gdtk-portals.conf" "$conf_dir/"
	[ -f "$HOME_DIR/session/gdtk.portal" ] && cp "$HOME_DIR/session/gdtk.portal" "$data_dir/"
}

install_session_entry() {
	[ "$WANT_SESSION" = 1 ] || { say "entrada de sesión: omitida (--no-session)"; return; }
	if run_root install -d /usr/share/wayland-sessions; then
		if run_root install -m644 "$HOME_DIR/session/gdtk.desktop" /usr/share/wayland-sessions/ \
		   && run_root install -m644 "$HOME_DIR/session/gdtk-sway.desktop" /usr/share/wayland-sessions/; then
			say "sesión instalada en /usr/share/wayland-sessions"
		else
			warn "no pude instalar la entrada de sesión; copiala a mano (necesita sudo):"
			note "sudo install -m644 $HOME_DIR/session/gdtk.desktop $HOME_DIR/session/gdtk-sway.desktop /usr/share/wayland-sessions/"
		fi
		# X11 opcional (lápiz/touch en GPUs muy viejas).
		run_root install -d /usr/share/xsessions 2>/dev/null \
			&& run_root install -m644 "$HOME_DIR/session/gdtk-x11.desktop" /usr/share/xsessions/ 2>/dev/null \
			&& say "sesión X11 instalada en /usr/share/xsessions" || true
	else
		warn "sin sudo: instalá la entrada de sesión a mano:"
		note "sudo install -d /usr/share/wayland-sessions"
		note "sudo install -m644 $HOME_DIR/session/gdtk.desktop $HOME_DIR/session/gdtk-sway.desktop /usr/share/wayland-sessions/"
	fi
}

# --- main -------------------------------------------------------------------
say "gdtk installer"
note "instalación: $HOME_DIR   driver: $DRIVER   repo: $REPO"
install_deps

	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	TGZ=""
	fetch
	say "descomprimiendo"
	mkdir -p "$tmp/src"
	tar -xzf "$TGZ" -C "$tmp/src"
# Tarball con envoltorio 'gdtk/' o sin él.
src="$tmp/src"
[ -d "$tmp/src/gdtk" ] && [ ! -d "$tmp/src/bin" ] && src="$tmp/src/gdtk"

install_tree "$src"
write_desktops
install_portals
install_session_entry

ver="$(cat "$HOME_DIR/VERSION" 2>/dev/null || echo '?')"
printf '\n'
say "gdtk $ver listo en $HOME_DIR"
note "Cerrá sesión y elegí «gdtk» en la pantalla de login (GDM/SDDM)."
note "Probarlo sin cerrar sesión (dentro de una terminal en tu escritorio actual):"
note "  GDTK_GODOT=$HOME_DIR/bin/godot-gdtk GDTK_HOME=$HOME_DIR $HOME_DIR/session/gdtk-session-sway"
note "Logs en ~/.local/state/gdtk/ (shell.log, supervisor.log, crash-*.log)."
note "Governor de CPU (opcional, una vez por equipo): sudo $HOME_DIR/session/gdtk-governor-provision install"
