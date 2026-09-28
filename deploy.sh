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
# Árbol del motor propio de gdtk (worktree): no comparte objetos ni parches con el de Odisea.
GODOT=/home/icarito/Proyectos/godot3-box3d/godot-dev
# Fork con el módulo imgui (no toda rama del fork lo trae): FORK=/ruta ./deploy.sh ...
FORK="${FORK:-/home/icarito/Proyectos/godot3-box3d/godot-box3d-3}"
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
objcopy --remove-section=.note.gnu.property "$BIN" "$TMP/godot-gdtk"

ssh "$HOST" 'mkdir -p ~/gdtk/bin ~/gdtk/session'
RHOME="$(ssh "$HOST" 'echo $HOME')"  # Exec= de un .desktop no expande variables
rsync -a "$TMP/godot-gdtk" "$HOST:gdtk/bin/"
rsync -a --exclude '*crash*' --exclude '.import' "$GDTK/shell" "$GDTK/addons" "$HOST:gdtk/"  # shell/addons -> ../addons
rsync -a "$GDTK/mcp" "$HOST:gdtk/"
rsync -a "$GDTK/session/gdtk-session" "$GDTK/session/gdtk-session-x11" "$GDTK/session/keyboard.sh" "$GDTK/session/gdtk-supervisor" "$HOST:gdtk/session/"
desktop() { # desktop <archivo> <nombre> <script>
	printf '[Desktop Entry]\nName=%s\nComment=Shell tipo Sugar sobre Godot/ImGui con compositor wlroots embebido\nExec=env GDTK_VIDEO_DRIVER=%s %s/gdtk/session/%s\nType=Application\nDesktopNames=gdtk\n' \
		"$2" "$DRIVER" "$RHOME" "$3" | ssh "$HOST" "cat > ~/gdtk/session/$1"
}
desktop gdtk.desktop "gdtk Wayland (cage, sin lápiz)" gdtk-session
desktop gdtk-x11.desktop "gdtk X11 (lápiz Wacom)" gdtk-session-x11
ssh "$HOST" '~/gdtk/bin/godot-gdtk --version || true'
ssh "$HOST" 'sudo -n cp ~/gdtk/session/gdtk.desktop /usr/share/wayland-sessions/ && sudo -n cp ~/gdtk/session/gdtk-x11.desktop /usr/share/xsessions/' \
	|| echo "Instalar con sudo: ~/gdtk/session/gdtk.desktop en /usr/share/wayland-sessions/ y gdtk-x11.desktop en /usr/share/xsessions/"
