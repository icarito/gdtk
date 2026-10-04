#!/bin/bash
# Lanza un subagente Kilo (DeepSeek v4.1 Flash) adjunto al server de la extensión de VS Code,
# para que se vea en el Agent Manager. Abrí VS Code en ~/Proyectos/gdtk (el server toma esa
# carpeta como proyecto; si VS Code está en ~/gdtk las sesiones no se ven en vivo).
# uso: tools/kilo-launch.sh <titulo> <archivo-brief> [logdir]   (correr en background)
set -u
T="$1"; BRIEF="$2"; LOG="${3:-/tmp/kilo-gdtk}"; mkdir -p "$LOG"
PID=$(ss -ltnp 2>/dev/null | grep -E '127.0.0.1:4096\b' | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
[ -n "$PID" ] || { echo "no hay server Kilo en :4096 (¿extensión abierta?)" >&2; exit 1; }
# Contraseña sólo en memoria (autorizado por el usuario); nunca imprimirla.
export KILO_SERVER_PASSWORD="$(tr '\0' '\n' < /proc/$PID/environ | sed -n 's/^KILO_SERVER_PASSWORD=//p')"
DIR="$(readlink -f /proc/$PID/cwd)"
REPO="$(readlink -f "$(dirname "$0")/..")"
if [ "$DIR" != "$REPO" ]; then
  echo "el server Kilo corre en $DIR, no en el repo $REPO: abrí VS Code en ~/Proyectos/gdtk" >&2
  exit 1
fi
exec kilo run --attach http://127.0.0.1:4096 --dir "$DIR" \
  --agent code -m kilo/deepseek/deepseek-v4.1-flash --auto --format json \
  --title "$T" "$(cat "$BRIEF")

Nota: NO uses board_read/board_post (no hay otros participantes; mandarle a main falla). Reportá todo en tu respuesta final: archivos tocados, funciones nuevas, tests corridos, dudas." \
  > "$LOG/$T.jsonl" 2>&1
