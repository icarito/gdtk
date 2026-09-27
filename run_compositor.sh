#!/bin/sh
# Verificación del compositor wayland anidado (ver SPEC-compositor.md y SPEC-dmabuf.md).
set -e

GDTK="/run/media/icarito/DATA/icarito/Proyectos/gdtk"
export GDTK_GODOT="${GDTK_GODOT:-/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk}"
export SDL_VIDEODRIVER=wayland

# 1) es2gears_wayland: prueba de frame callbacks (dmabuf zero-copy).
timeout 90 "$GDTK/session/gdtk-session" -- --open=Gears --screenshot="$GDTK/comp-gears.png"

# 2) alacritty: prueba de teclado con tecleo sintético.
timeout 90 "$GDTK/session/gdtk-session" -- --open=Terminal --type='echo hola gdtk\n' --screenshot="$GDTK/comp-term.png"

# 3) gtk4-widget-factory: prueba de dmabuf genérico.
timeout 90 "$GDTK/session/gdtk-session" -- --open=GTK --screenshot="$GDTK/comp-gtk.png"

# 4) camino shm forzado: valida el shm nuevo sin wlr_texture_read_pixels.
GDTK_FORCE_SHM=1 timeout 90 "$GDTK/session/gdtk-session" -- --open=Gears --screenshot="$GDTK/comp-shm.png"

# 5) driver GLES2 (GDTK_VIDEO_DRIVER lo soporta session/gdtk-session).
GDTK_VIDEO_DRIVER=GLES2 timeout 90 "$GDTK/session/gdtk-session" -- --open=Gears --screenshot="$GDTK/comp-gears-gles2.png"
