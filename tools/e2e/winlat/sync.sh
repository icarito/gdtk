#!/bin/bash
# Sincroniza shell/settings/tools a tengu y cupid (sin compilar motor) y recarga sus shells.
# Sólo para el banco e2e: NO toca bastion. Uso: tools/e2e/winlat/sync.sh [host...]
set -e
GDTK="$(cd "$(dirname "$0")/../../.." && pwd)"
HOSTS=("$@"); [ ${#HOSTS[@]} -gt 0 ] || HOSTS=(icarito@192.168.18.163 icarito@192.168.18.30)
for H in "${HOSTS[@]}"; do
  rsync -a --delete --exclude '*crash*' --exclude '.import' "$GDTK/shell" "$GDTK/settings" "$H:gdtk/"
  rsync -a --exclude 'gvd-capture' --exclude 'gvd-cursor' --exclude '__pycache__' "$GDTK/tools" "$GDTK/mcp" "$H:gdtk/"
  ssh "$H" 'python3 -c "import sys,os; sys.path.insert(0,os.path.expanduser(\"~/gdtk/mcp\")); from gdtk_mcp import call_shell; print(call_shell(\"reload_shell\",{}))"'
  echo "sync+reload $H ok"
done
