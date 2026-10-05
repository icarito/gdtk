#!/bin/bash
# Banco e2e tengu(emisor) -> cupid(receptor): sync, reabre la ventana de stamp, la comparte y mide.
# Nunca toca bastion. Uso: tools/e2e/winlat/run.sh [etiqueta]
set -e
D="$(cd "$(dirname "$0")" && pwd)"; T=icarito@192.168.18.163; C=icarito@192.168.18.30
TID=61950c8964e60e15   # id de cupid visto desde tengu
rpc() { ssh -o BatchMode=yes "$1" "python3 -c \"import sys,os,json; sys.path.insert(0,os.path.expanduser('~/gdtk/mcp')); from gdtk_mcp import call_shell; print(json.dumps(call_shell(sys.argv[1], json.loads(sys.argv[2]))))\" $2 '${3:-{\}}'"; }
"$D/sync.sh" >/dev/null
# limpieza: receptores/emisores viejos y ventanas «Pantalla compartida» huérfanas
ssh $C 'pkill -f "[g]vd.py recv"; pkill -f "[r]ecv_probe"' || true
ssh $T 'pkill -f "[g]vd.py send"' || true
for w in $(rpc $C state | python3 -c "import sys,json; print(' '.join(str(w['id']) for w in json.load(sys.stdin)['windows']))"); do rpc $C close_window "{\"id\":$w}" >/dev/null; done
ssh $T 'pkill -f "[w]inlat/stamp_app.py"; rm -f /tmp/winlat-keys.log' || true
sleep 1
rpc $T launch '{"cmd":"python3","args":["/home/icarito/gdtk/tools/e2e/winlat/stamp_app.py"]}' >/dev/null
sleep 3
WID=$(rpc $T state | python3 -c "import sys,json; print([w['id'] for w in json.load(sys.stdin)['windows'] if w['title']=='winlat'][0])")
rpc $T share_window "{\"host\":\"$TID\",\"id\":$WID}" >/dev/null
sleep 8
echo "== ${1:-run}: visual (cupid)"; ssh $C 'python3 ~/gdtk/tools/e2e/winlat/sampler.py 25 1.5'
