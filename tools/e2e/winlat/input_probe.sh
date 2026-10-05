#!/bin/bash
# Latencia de ENTRADA de la ventana compartida (tras run.sh, con la ventana compartida activa).
# cupid (receptor) manda N teclas por RPC (`key`) con la ventana compartida enfocada; stamp_app en
# tengu anota la llegada en /tmp/winlat-keys.log. Latencia = llegada(tengu) - envío(cupid) (NTP ±5 ms).
# uso: tools/e2e/winlat/input_probe.sh [N=20] [pausa_s=0.7]
N=${1:-20}; P=${2:-0.7}; T=icarito@192.168.18.163; C=icarito@192.168.18.30
ssh $T 'rm -f /tmp/winlat-keys.log; touch /tmp/winlat-keys.log'
SENT=$(ssh $C "python3 - $N $P <<'E2'
import sys,os,time
sys.path.insert(0,os.path.expanduser('~/gdtk/mcp'))
from gdtk_mcp import call_shell
for _ in range(int(sys.argv[1])):
    t=time.time_ns(); call_shell('key',{'combo':'x'}); print(t); time.sleep(float(sys.argv[2]))
E2")
sleep 2
GOT=$(ssh $T "awk '{print \$2}' /tmp/winlat-keys.log")
python3 - "$SENT" "$GOT" <<'E3'
import sys,json
s=[int(x) for x in sys.argv[1].split()]; g=[int(x) for x in sys.argv[2].split()]
# cada tecla = press+release o sólo press; se empareja cada envío con la primera llegada posterior
lat=[]; j=0
for t in s:
    while j<len(g) and g[j]<t-50_000_000: j+=1
    if j<len(g): lat.append((g[j]-t)/1e6); j+=1
lat.sort()
print(json.dumps({"sent":len(s),"got":len(g),"n":len(lat),"p50":round(lat[len(lat)//2],1) if lat else None,
  "p90":round(lat[int(len(lat)*.9)],1) if lat else None,"all":[round(x) for x in lat]}))
E3
