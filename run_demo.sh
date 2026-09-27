#!/bin/sh
# Build + verificación del POC del módulo imgui (ver SPEC.md).
set -e

GDTK="/run/media/icarito/DATA/icarito/Proyectos/gdtk"
GODOT_DIR="/home/icarito/Proyectos/godot3-box3d/godot-dev"
BIN="$GODOT_DIR/bin/godot.x11.opt.tools.64.gdtk"

# 1) Importar el proyecto demo para generar .import.
"$BIN" --path "$GDTK/demo" --editor --quit

# 2) Correr el demo y guardar el screenshot de verificación.
"$BIN" --path "$GDTK/demo" -- --screenshot="$GDTK/poc.png"
