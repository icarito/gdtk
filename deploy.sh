#!/bin/sh
# Copia el shell a un host (ssh) en ~/gdtk. Uso: ./deploy.sh usuario@host [GLES2|GLES3]
# Reenlaza el binario FRT con libstdc++ dinámica: la estática de CachyOS (cachyos-v4) trae
# instrucciones AVX y da SIGILL en CPUs viejas. Y quita .note.gnu.property: el crt1.o de esa
# glibc marca el binario como x86-64-v4 y el loader lo rechaza ("CPU ISA level is lower than required").
# ponytail: parche de toolchain; binarios portables de verdad = build en el SDK buildroot del CI.
set -e
HOST="$1"; DRIVER="${2:-GLES2}"
[ -n "$HOST" ] || { echo "uso: $0 usuario@host [GLES2|GLES3]"; exit 1; }
GDTK="$(cd "$(dirname "$0")" && pwd)"
# Árbol aislado del motor con SlugVector2D; GODOT permite elegir otro checkout.
GODOT="${GODOT:-/home/icarito/Proyectos/godot3-box3d/godot-gdtk-slug}"
# Fork con el módulo imgui (no toda rama del fork lo trae): FORK=/ruta ./deploy.sh ...
# Default: worktree propio del fork en main (el checkout principal cambia de rama y /tmp se borra).
# Actualizar: git -C <worktree> checkout --detach main
FORK="${FORK:-/home/icarito/Proyectos/godot3-box3d/godot-box3d-3-gdtk}"
export SCONS_CACHE="${SCONS_CACHE-$HOME/.cache/scons-godot3}" SCONS_CACHE_LIMIT="${SCONS_CACHE_LIMIT:-30000}"
# Sin editor (tools=no): el shell no importa recursos (sólo .gd/.tscn en texto) y ahorra ~35 MB de binario.
# release_debug y no release: el HUD/control remoto habilitan eval/quit sólo con OS.is_debug_build().
# Módulos fuera: ni el shell ni addons/ los usan (sin física, audio Dummy, sin red salvo StreamPeerTCP).
BIN="$GODOT/bin/godot.frt.opt.debug.x86_64.gdtklite"
NO_MODULES="bullet csg gridmap enet upnp webrtc websocket webxr mobile_vr gdnative visual_script theora webm
	vorbis opus ogg stb_vorbis minimp3 gltf jsonrpc camera opensimplex raycast box3d decal"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC2046
(cd "$GODOT" && scons -j8 platform=frt arch=x86_64 target=release_debug tools=no frt_desktop_gl=yes \
	production=yes lto=none use_static_cpp=no progress=no extra_suffix=gdtklite imgui_implot3d=yes \
	custom_modules="$FORK","$GDTK/modules" $(for m in $NO_MODULES; do printf 'module_%s_enabled=no ' "$m"; done))
grep -q ImGuiCanvas "$BIN" || { echo "el binario no trae ImGuiCanvas: $FORK sin módulo imgui"; exit 1; }
grep -q SlugVector2D "$BIN" || { echo "el binario no trae SlugVector2D"; exit 1; }
objcopy --remove-section=.note.gnu.property "$BIN" "$TMP/godot-gdtk"

ssh "$HOST" 'mkdir -p ~/gdtk/bin ~/gdtk/session'
RHOME="$(ssh "$HOST" 'echo $HOME')"  # Exec= de un .desktop no expande variables
rsync -a "$TMP/godot-gdtk" "$HOST:gdtk/bin/"
# --delete: un .gd viejo que quede en destino se compila igual (un _remote_input_tmp.gd con
# class_name RemoteInput tumbó el arranque). El shell no escribe en su árbol (usa user:// y
# XDG_RUNTIME_DIR); lo excluido (crash, .import) no se borra.
rsync -a --delete --exclude '*crash*' --exclude '.import' "$GDTK/shell" "$GDTK/addons" "$GDTK/settings" "$HOST:gdtk/"  # shell/addons/settings -> ../addons
rsync -a "$GDTK/mcp" "$HOST:gdtk/"
# gvd vendoreado (tools/gvd/DEPS.md). Los helpers se compilan EN el host destino:
# compilados aquí (con -march nativo de este host) fallaban con "CPU ISA level is
# lower than required" en hosts más viejos (p.ej. cupid i5-4300U). Se excluyen y se
# borran en destino para que gvd.py los recompile a su ISA la primera vez.
rsync -a --exclude 'gvd-capture' --exclude 'gvd-cursor' --exclude '__pycache__' "$GDTK/tools" "$HOST:gdtk/"
ssh "$HOST" 'rm -f ~/gdtk/tools/gvd/gvd-capture ~/gdtk/tools/gvd/gvd-cursor'
rsync -a "$GDTK/session/gdtk-session" "$GDTK/session/gdtk-session-x11" "$GDTK/session/keyboard.sh" "$GDTK/session/gdtk-supervisor" "$GDTK/session/gdtk-version" "$GDTK/session/gdtk-preflight" "$GDTK/session/gdtk-preflight.gd" "$GDTK/session/gdtk-session-sway" "$GDTK/session/sway.conf" "$GDTK/session/gdtk-outputs" "$GDTK/session/portal.sh" "$GDTK/session/autostart.sh" "$GDTK/session/sensor-hub.sh" "$GDTK/session/gdtk-rotate" "$GDTK/session/gdtk-sensor-hub" "$GDTK/session/gdtk-sensor-hub.service" "$GDTK/session/input-settings.sh" "$HOST:gdtk/session/"
# Portal RemoteDesktop propio (input remoto libei): el backend lo implementa el shell
# (modules/wayland/eis_server.c). El frontend xdg-desktop-portal lo enruta sólo en la
# sesión gdtk (UseIn/DesktopNames), así no toca xfce ni las demás sesiones del host.
rsync -a "$GDTK/session/gdtk.portal" "$GDTK/session/gdtk-portals.conf" "$HOST:gdtk/session/"
desktop() { # desktop <archivo> <nombre> <script>
	printf '[Desktop Entry]\nName=%s\nComment=Shell tipo Sugar sobre Godot/ImGui con compositor wlroots embebido\nExec=env GDTK_VIDEO_DRIVER=%s %s/gdtk/session/%s\nType=Application\nDesktopNames=gdtk\n' \
		"$2" "$DRIVER" "$RHOME" "$3" | ssh "$HOST" "cat > ~/gdtk/session/$1"
}
desktop gdtk.desktop "gdtk" gdtk-session-sway   # sway es el default; cage ya no se soporta
desktop gdtk-x11.desktop "gdtk X11 (lápiz Wacom)" gdtk-session-x11
desktop gdtk-sway.desktop "gdtk (sway)" gdtk-session-sway   # alias de compatibilidad
ssh "$HOST" '~/gdtk/bin/godot-gdtk --version || true'
ssh "$HOST" 'sudo -n cp ~/gdtk/session/gdtk.desktop ~/gdtk/session/gdtk-sway.desktop /usr/share/wayland-sessions/ && sudo -n cp ~/gdtk/session/gdtk-x11.desktop /usr/share/xsessions/' \
	|| echo "Instalar con sudo: ~/gdtk/session/gdtk.desktop en /usr/share/wayland-sessions/ y gdtk-x11.desktop en /usr/share/xsessions/"
# Servicio de arranque: habilita el sensor hub del Surface Pro 3 (rotación automática)
# sin depender de cómo se lance la sesión. En otros equipos es un no-op.
ssh "$HOST" 'sudo -n install -Dm755 ~/gdtk/session/gdtk-sensor-hub /usr/local/lib/gdtk/gdtk-sensor-hub && sudo -n cp ~/gdtk/session/gdtk-sensor-hub.service /etc/systemd/system/ && sudo -n systemctl daemon-reload && sudo -n systemctl enable --now gdtk-sensor-hub.service' \
	|| echo "Instalar con sudo: gdtk-sensor-hub.service (ver session/)"
# Portal del usuario (sin sudo): xdg-desktop-portal busca *.portal en XDG_DATA_HOME y
# <desktop>-portals.conf en XDG_CONFIG_HOME; aplica sólo con XDG_CURRENT_DESKTOP=gdtk.
ssh "$HOST" 'mkdir -p ~/.config/xdg-desktop-portal ~/.local/share/xdg-desktop-portal/portals && cp ~/gdtk/session/gdtk-portals.conf ~/.config/xdg-desktop-portal/ && cp ~/gdtk/session/gdtk.portal ~/.local/share/xdg-desktop-portal/portals/'
# Store de versiones (Fase 1): snapshot del árbol desplegado y activarlo, así el
# supervisor puede promover/volver ante un arranque roto. GDTK_NO_STORE=1 lo omite.
if [ -z "${GDTK_NO_STORE:-}" ]; then
	ssh "$HOST" 'chmod +x ~/gdtk/session/gdtk-version ~/gdtk/session/gdtk-preflight 2>/dev/null; GDTK_GODOT="$HOME/gdtk/bin/godot-gdtk" ~/gdtk/session/gdtk-version snapshot --from "$HOME/gdtk" --note "deploy $(date +%F_%T)"' \
		|| echo "aviso: no se creó el snapshot inicial en $HOST (ver el error de gdtk-version arriba)"
fi
