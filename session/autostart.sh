#!/bin/sh
# Autostart de la sesión gdtk: agente polkit, llavero de GNOME, daemon de
# notificaciones (mako) y las entradas de ~/.config/autostart.
#
# POSIX sh. Lo invocan gdtk-session-sway y gdtk-session-x11 después de portal.sh;
# gdtk-session es un alias de gdtk-session-sway, así que también lo recibe.
# Todo es opcional: lo que falte o falle se anota en el log y la sesión sigue.
# Idempotente: no relanza lo que ya corre. Log: ~/.local/state/gdtk/autostart.log.
# Paquetes y notas en session/DEPS.md.
#
# En sway este script corre antes de que exista el compositor: si no hay
# WAYLAND_DISPLAY espera en segundo plano al primer socket wayland-* y recién
# entonces arranca lo que necesita pantalla; la sesión no se bloquea por eso.

log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/gdtk"
log="$log_dir/autostart.log"
run_base="${XDG_RUNTIME_DIR:-/tmp}"
run_dir="$run_base/gdtk"
mkdir -p "$log_dir" "$run_dir" 2>/dev/null || true

say() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$log" 2>/dev/null || true; }
have() { command -v "$1" >/dev/null 2>&1; }
running() { # running <pidfile>
	[ -f "$1" ] || return 1
	_p="$(cat "$1" 2>/dev/null)" || return 1
	[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}

# Espera en segundo plano a que sway cree su socket. No bloquea la sesión.
wait_wayland() {
	_n=0
	while [ "$_n" -lt 150 ]; do
		for _s in "$run_base"/wayland-*; do
			[ -S "$_s" ] || continue
			WAYLAND_DISPLAY="${_s##*/}"
			export WAYLAND_DISPLAY
			say "compositor listo: $WAYLAND_DISPLAY"
			return 0
		done
		sleep 0.2
		_n=$((_n + 1))
	done
	say "sin compositor Wayland tras 30 s; omito lo que necesita pantalla"
	return 1
}

# Agente de autenticación polkit: polkit-gnome, lxqt, mate o xfce.
start_polkit() {
	[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] || { say "polkit omitido: sin pantalla"; return 0; }
	_cand=""
	for _c in /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 \
		/usr/libexec/polkit-gnome-authentication-agent-1 \
		/usr/lib/lxqt-policykit/lxqt-policykit-agent \
		/usr/lib/mate-polkit/polkit-mate-authentication-agent-1 \
		/usr/lib/xfce-polkit/xfce-polkit; do
		[ -x "$_c" ] && { _cand="$_c"; break; }
	done
	if [ -z "$_cand" ]; then
		for _n in polkit-gnome-authentication-agent-1 lxqt-policykit-agent mate-polkit xfce-polkit; do
			_cand="$(command -v "$_n" 2>/dev/null)" || _cand=""
			[ -n "$_cand" ] && break
		done
	fi
	[ -n "$_cand" ] || { say "agente polkit no encontrado (instalar polkit-gnome)"; return 0; }
	running "$run_dir/polkit.pid" && { say "agente polkit ya corre"; return 0; }
	"$_cand" >>"$log" 2>&1 &
	echo $! >"$run_dir/polkit.pid"
	say "agente polkit iniciado ($_cand, pid $!)"
}

# Llavero: gnome-keyring-daemon reutiliza el control si ya corre. La salida trae
# el entorno (GNOME_KEYRING_CONTROL/SSH_AUTH_SOCK) y se publica para D-Bus/systemd.
start_keyring() {
	have gnome-keyring-daemon || { say "gnome-keyring-daemon no instalado"; return 0; }
	_out="$(gnome-keyring-daemon --start --components=secrets,pkcs11 2>>"$log")" \
		|| { say "gnome-keyring-daemon falló"; return 0; }
	[ -n "$_out" ] || { say "gnome-keyring-daemon no devolvió entorno"; return 0; }
	# shellcheck disable=SC2086
	eval "$_out"
	export GNOME_KEYRING_CONTROL SSH_AUTH_SOCK
	say "llavero iniciado (control=${GNOME_KEYRING_CONTROL:-?}, ssh=${SSH_AUTH_SOCK:-?})"
	if have dbus-update-activation-environment; then
		dbus-update-activation-environment --systemd \
			${GNOME_KEYRING_CONTROL:+GNOME_KEYRING_CONTROL} \
			${SSH_AUTH_SOCK:+SSH_AUTH_SOCK} 2>>"$log" \
			|| say "dbus-update-activation-environment falló"
	fi
}

# Notificaciones layer-shell (mako).
start_mako() {
	have mako || { say "mako no instalado"; return 0; }
	[ -n "${WAYLAND_DISPLAY:-}" ] || { say "mako omitido: sin WAYLAND_DISPLAY"; return 0; }
	running "$run_dir/mako.pid" && { say "mako ya corre"; return 0; }
	mako >>"$log" 2>&1 &
	echo $! >"$run_dir/mako.pid"
	say "mako iniciado (pid $!)"
}

_key() { # _key <archivo .desktop> <clave>  (sólo [Desktop Entry])
	awk -v k="$2" '
		{ sub(/\r$/, "") }
		/^\[/ { sec = ($0 == "[Desktop Entry]"); next }
		sec && $0 ~ "^[ \t]*" k "[ \t]*=" {
			sub("^[ \t]*" k "[ \t]*=[ \t]*", ""); print; exit
		}' "$1"
}

_list_has() { case ";$1;" in *";$2;"*) return 0 ;; esac; return 1; }

# Entradas ~/.config/autostart/*.desktop respetando Hidden/OnlyShowIn/NotShowIn.
# Se prefiere dex (si está) porque resuelve bien Exec y el filtrado.
start_desktop_entries() {
	_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
	[ -d "$_dir" ] || return 0
	# Deskflow lo maneja el shell (un solo deskflow-core, que el supervisor mata con el
	# shell). La app gráfica de Deskflow en autostart lanzaba su PROPIO core con otra config:
	# un segundo cliente que sobrevivía a los reinicios ("zombi") y retenía el puntero.
	# dex no permite excluir entradas: si hay alguna de Deskflow se usa el loop propio.
	if have dex && ! ls "$_dir" | grep -qi deskflow; then
		dex --autostart --environment "${XDG_CURRENT_DESKTOP:-gdtk}" >>"$log" 2>&1 \
			|| say "dex falló"
		return 0
	fi
	_marker="$run_dir/autostart.entries.$(printf '%s' "${WAYLAND_DISPLAY:-${DISPLAY:-tty}}" | tr -c 'A-Za-z0-9._-' '_')"
	[ -f "$_marker" ] && return 0
	: >"$_marker"
	for _f in "$_dir"/*.desktop; do
		[ -f "$_f" ] || continue
		[ "$(_key "$_f" Hidden)" = "true" ] && { say "omitido (Hidden): ${_f##*/}"; continue; }
		case "$(printf '%s %s' "${_f##*/}" "$(_key "$_f" Exec)" | tr 'A-Z' 'a-z')" in
			*deskflow*) say "omitido (Deskflow lo maneja el shell): ${_f##*/}"; continue ;;
		esac
		_only="$(_key "$_f" OnlyShowIn)"
		if [ -n "$_only" ] && ! _list_has "$_only" "${XDG_CURRENT_DESKTOP:-gdtk}" \
			&& ! _list_has "$_only" gdtk; then
			say "omitido (OnlyShowIn=$_only): ${_f##*/}"; continue
		fi
		_not="$(_key "$_f" NotShowIn)"
		if [ -n "$_not" ] && { _list_has "$_not" "${XDG_CURRENT_DESKTOP:-gdtk}" \
			|| _list_has "$_not" gdtk; }; then
			say "omitido (NotShowIn=$_not): ${_f##*/}"; continue
		fi
		_exec="$(_key "$_f" Exec)"
		[ -n "$_exec" ] || continue
		_exec="$(printf '%s\n' "$_exec" \
			| sed -e 's/%[uUfFiIcCkKdDnNvVm]/ /g' -e 's/%%/%/g')"
		sh -c "$_exec" >>"$log" 2>&1 &
		say "autostart: ${_f##*/} (pid $!)"
	done
}

run_autostart() {
	start_polkit
	start_keyring
	start_mako
	start_desktop_entries
	say "autostart terminado"
}

# En sway aún no hay compositor: difiere en segundo plano y sale enseguida.
case "${GDTK_SESSION:-}" in
wayland)
	if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${GDTK_AUTOSTART_WAIT:-0}" != 1 ]; then
		GDTK_AUTOSTART_WAIT=1
		export GDTK_AUTOSTART_WAIT
		( wait_wayland; run_autostart ) >>"$log" 2>&1 &
		say "esperando al compositor en segundo plano (pid $!)"
		exit 0
	fi
	;;
esac
run_autostart
