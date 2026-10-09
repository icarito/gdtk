#!/bin/sh
# make-release.sh — compila el motor + el shell y arma el tarball que consume
# install.sh en el equipo del usuario (binario + shell + sesión, sin git ni tests).
#
# Uso:
#   tools/make-release.sh [VERSION]         # compila y empaqueta
#   GDTK_NO_BUILD=1 GDTK_BIN=/ruta/godot.frt.opt.debug.x86_64.gdtklite tools/make-release.sh 0.1.0
#
# Variables (mismos defaults que deploy.sh):
#   GODOT=/ruta/al/arbol-del-motor   FORK=/ruta/al/fork/con-imgui
#   GDTK_VERSION, GDTK_BIN, GDTK_NO_BUILD=1, GDTK_DIST
# Salida: $GDTK_DIST/gdtk-<version>-linux-x86_64.tar.gz (+ .sha256)
set -e
GDTK="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-${GDTK_VERSION:-$(git -C "$GDTK" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}}"
[ -n "$VERSION" ] || VERSION="$(date +%Y.%m.%d)"
DIST="${GDTK_DIST:-$GDTK/dist}"
GODOT="${GODOT:-/home/icarito/Proyectos/godot3-box3d/godot-gdtk-slug}"
FORK="${FORK:-/home/icarito/Proyectos/godot3-box3d/godot-box3d-3-gdtk}"
export SCONS_CACHE="${SCONS_CACHE-$HOME/.cache/scons-godot3}" SCONS_CACHE_LIMIT="${SCONS_CACHE_LIMIT:-30000}"
BIN="${GDTK_BIN:-$GODOT/bin/godot.frt.opt.debug.x86_64.gdtklite}"
NO_MODULES="bullet csg gridmap enet upnp webrtc websocket webxr mobile_vr gdnative visual_script theora webm
	vorbis opus ogg stb_vorbis minimp3 gltf jsonrpc camera opensimplex raycast box3d decal"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [ "${GDTK_NO_BUILD:-0}" = 1 ]; then
	echo "==> sin build (GDTK_NO_BUILD=1): uso $BIN"
else
	echo "==> compilando el motor (release_debug, tools=no, GL frontend)"
	# shellcheck disable=SC2046
	(cd "$GODOT" && scons -j8 platform=frt arch=x86_64 target=release_debug tools=no frt_desktop_gl=yes \
		production=yes lto=none use_static_cpp=no progress=no extra_suffix=gdtklite imgui_implot3d=yes \
		custom_modules="$FORK","$GDTK/modules" $(for m in $NO_MODULES; do printf 'module_%s_enabled=no ' "$m"; done))
fi
[ -f "$BIN" ] || { echo "error: no existe el binario $BIN" >&2; exit 1; }
grep -q ImGuiCanvas "$BIN" || { echo "error: el binario no trae ImGuiCanvas ($FORK sin módulo imgui)" >&2; exit 1; }
grep -q SlugVector2D "$BIN" || { echo "error: el binario no trae SlugVector2D" >&2; exit 1; }

echo "==> armando árbol de release"
stage="$TMP/gdtk"
mkdir -p "$stage/bin"
objcopy --remove-section=.note.gnu.property "$BIN" "$stage/bin/godot-gdtk"
rsync -a --exclude '.import' --exclude '*crash*' --exclude '*.o' --exclude '__pycache__' \
	"$GDTK/shell" "$GDTK/addons" "$GDTK/settings" "$stage/"
rsync -a --exclude '__pycache__' "$GDTK/mcp" "$stage/"
# gvd vendoreado: los helpers C se recompilan en el equipo destino (ISA local).
rsync -a --exclude 'gvd-capture' --exclude 'gvd-cursor' --exclude '__pycache__' "$GDTK/tools" "$stage/"
# session/ sin los .desktop versionados (install.sh los regenera con la ruta real).
rsync -a --exclude '*.desktop' --exclude '*.o' "$GDTK/session" "$stage/"
printf '%s\n' "$VERSION" >"$stage/VERSION"

echo "==> empaquetando"
mkdir -p "$DIST"
name="gdtk-$VERSION-linux-x86_64.tar.gz"
tar -czf "$DIST/$name" -C "$stage" .
( cd "$DIST" && sha256sum "$name" >"$name.sha256" )
echo "==> listo:"
ls -lh "$DIST/$name" "$DIST/$name.sha256"
echo
echo "Publicar (ejemplo con gh):"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION $DIST/$name $DIST/$name.sha256 --title v$VERSION"
