#!/bin/sh
# Verificación del compositor wayland anidado (ver SPEC-compositor.md).
set -e

GDTK="/run/media/icarito/DATA/icarito/Proyectos/gdtk"
export GDTK_GODOT="${GDTK_GODOT:-/home/icarito/Proyectos/godot3-box3d/godot/bin/godot.frt.opt.tools.x86_64.gdtk}"
export SDL_VIDEODRIVER=wayland

# 1) es2gears_wayland: prueba de frame callbacks (commit_count).
timeout 90 "$GDTK/session/gdtk-session" -- --open=Gears --screenshot="$GDTK/comp-gears.png"

# 2) alacritty: prueba de teclado con tecleo sintético.
timeout 90 "$GDTK/session/gdtk-session" -- --open=Terminal --type='echo hola gdtk\n' --screenshot="$GDTK/comp-term.png"

# 3) gtk4-widget-factory (software/cairo): prueba de shm genérico.
timeout 90 "$GDTK/session/gdtk-session" -- --open=GTK --screenshot="$GDTK/comp-gtk.png"
