#!/bin/sh
# Verificación del shell tipo Sugar bajo cage (ver SPEC-shell.md).
set -e

GDTK="/run/media/icarito/DATA/icarito/Proyectos/gdtk"
export GDTK_GODOT="${GDTK_GODOT:-/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk}"
export SDL_VIDEODRIVER=wayland

# 1) Home style Sugar: anillo de actividades + reloj.
timeout 60 "$GDTK/session/gdtk-session" -- --screenshot="$GDTK/shell-home.png"

# 2) Actividad interna abierta al arrancar: barra "Inicio" + chat.
timeout 60 "$GDTK/session/gdtk-session" -- --open=Chat --screenshot="$GDTK/shell-chat.png"
