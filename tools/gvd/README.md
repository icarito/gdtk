# gvd — monitor virtual de GNOME mostrado en otro host

Extiende un escritorio GNOME (Wayland) hacia otra máquina: Mutter crea un monitor
virtual, se codifica en H.264 y viaja por RTP/UDP o H.264/TCP a un receptor que lo
muestra a pantalla completa con la menor latencia posible. Pensado para
gdtk / Vecindario, pero no depende de él.

`gvd.py` es un solo archivo (Python 3 + PyGObject/Gio + `gst-launch-1.0`, sin pip ni root) con tres subcomandos:

- **`send`** (host con GNOME Wayland): pide a Mutter un monitor virtual, lo coloca en el layout, captura su stream de PipeWire, lo codifica y lo manda.
- **`recv`** (Linux con GStreamer; ffplay opcional para TCP): recibe, decodifica y muestra. En UDP reordena RTP con un margen de 30 ms.
- **`caps --json`**: reporta capacidades locales (`schema=gvd.caps.v1`) para que un integrador decida sin abrir streams.

## Inicio rápido
```
# receptor (p. ej. tengu; usar el WAYLAND_DISPLAY/DISPLAY de la sesión activa)
python3 gvd.py recv --sink wayland

# emisor (GNOME Wayland)
python3 gvd.py send --host tengu.local          # 1280x800@30, 8 Mbps, a la derecha
```
`./extend-tengu.sh [left|right|above|below] [-r]` es el atajo para mi caso (`-r` lanza el receptor por ssh; Ctrl-C cierra el monitor).

## Estructura del repo
| Archivo | Qué es |
|---|---|
| `gvd.py` | La herramienta (`send`/`recv`/`caps`). |
| `gvd-cursor.c` | Helper C (libpipewire) que lee `SPA_META_Cursor`; `send` lo compila a `gvd-cursor` (ignorado en git). |
| `extend-tengu.sh` | Atajo emisor→tengu. |
| `DESIGN.md` | Diseño de integración con gdtk/Vecindario y decisiones abiertas. |
| `SPEC-gvd-*.md` / `*-results.md` | Especificaciones por fase y sus resultados medidos (historial de decisiones). |
| `rdp_baseline.md` | Plan (no ejecutado) de línea base con gnome-remote-desktop/FreeRDP. |
| `spike_virtual.py`, `spike_cursor.py`, `gst_cursor_probe.py`, `inject_pointer.py`, `fake_cursor.py` | Spikes y utilidades de prueba usados en los SPEC (no necesarios para operar gvd). `fake_cursor.py` simula el emisor de cursor para probar `recv`. |

## Historial por fase
| Fase | Resultado |
|---|---|
| 0a | Decode H.264 en tengu (Core2, software) viable a 1280x800@30; tiles JPEG descartados. |
| 0b | Monitor virtual vía `org.gnome.Mutter.ScreenCast.RecordVirtual` + `ApplyMonitorsConfig` temporal. |
| 0c | Investigación RDP como alternativa (sólo plan). |
| 1 | `gvd.py send/recv` end-to-end, local y por red. |
| 2 | Cursor fuera del video (metadata PipeWire → UDP → cursor nativo de sway). |

## Cómo funciona `send`
1. `org.gnome.Mutter.ScreenCast` (D-Bus, sesión): `CreateSession` → `RecordVirtual` con `modes=[{size, refresh-rate, is-preferred=true}]` y `cursor-mode=2` (cursor como metadata, NO dentro del video; default `--cursor-mode separate`). Con `--cursor-mode embedded` usa `cursor-mode=1`.
2. `PipeWireStreamAdded` entrega el node id. `Session.Start`. Si `--cursor-mode separate`, se compila/lanza `gvd-cursor` (C, libpipewire) que lee `SPA_META_Cursor` del node y manda `x:u16 y:u16 seq:u32` (big-endian, 8 B) por UDP a `host:port+1` (5601), limitado a 120 Hz.
3. `org.gnome.Mutter.DisplayConfig.ApplyMonitorsConfig` con `method=1` (temporal, no persiste) coloca el monitor `right|left|above|below`. Mutter exige que el layout quede anclado en `(0,0)`, por eso `left`/`above` re-anclan también el monitor real.
4. Pipeline: `pipewiresrc keepalive-time=200 ! videoconvert ! [vapostproc ! vah264enc | x264enc] ! h264parse config-interval=-1 ! identity(gvd_stamp) ! [rtph264pay ! udpsink | tcpclientsink]`. UDP usa RTP; TCP envía H.264 Annex B directamente. El emisor ajusta las marcas de tiempo de cada cuadro codificado al reloj del pipeline para RTP; Mutter/PipeWire puede repetir la misma marca en cuadros distintos. `--fps` fija la frecuencia del monitor virtual; `--refresh` permite ajustarla por separado.
   - `keepalive-time=200`: PipeWire sólo emite con daño; esto repite el último frame (≥5 fps) para que el receptor se enganche y se recupere tras pérdidas.
   - `auto` prueba `vah264enc` con un dry-run de 1 s y cae a `x264enc` (baseline, veryfast/zerolatency). `--quality balanced` usa VA `target-usage=4`; `--quality speed` vuelve a VA `7` o x264 `ultrafast`.
   - Video progresivo, sin B-frames y keyframe completo aproximadamente cada segundo a la frecuencia del monitor virtual. x264 no usa intra-refresh: un receptor que perdio paquetes necesita un IDR completo para recuperar sus referencias.
5. SIGINT/SIGTERM: detiene el pipeline y hace `Session.Stop`; el monitor desaparece solo (también tras SIGKILL, lo cierra Mutter al caer el bus).

## Uso
```
# receptor (p. ej. tengu; elegir el WAYLAND_DISPLAY/DISPLAY de la sesión activa)
scp gvd.py icarito@tengu.local:~/gvd/
ssh icarito@tengu.local 'WAYLAND_DISPLAY=wayland-1 python3 ~/gvd/gvd.py recv --sink wayland'

# emisor (GNOME Wayland)
python3 gvd.py send --host tengu.local                         # 1280x800@30, 8 Mbps, a la derecha
python3 gvd.py send --host tengu.local --position left --encoder x264 --bitrate 8000
python3 gvd.py send --local --size 1280x800 --stats            # prueba local (encode→decode)
python3 gvd.py send --host tengu.local --cursor-mode embedded  # cursor dentro del video
```
`send`: `--host --port 5600 --transport {udp,tcp} --size --fps 30 --bitrate 8000 --quality {balanced,speed} --refresh --position --encoder {auto,va,x264} --local --stats --cursor-mode {separate,embedded}`
`recv`: `--port 5600 --transport {udp,tcp} --sink {auto,ffplay,gl,xv,wayland} --jitter-ms 30 --stats --max-seconds --cursor {sway,none} --video-size 1280x800`
`caps`: `--json` para que un integrador detecte capacidades sin abrir streams.

Para video por Wi-Fi, empezar con `send --fps 30 --bitrate 6000 --quality balanced`
y `recv --jitter-ms 30`. Si hay paquetes tardios, probar `--jitter-ms 60`;
en una LAN estable se puede probar `0`. Este margen agrega latencia para tolerar
reordenamiento, no retransmite paquetes. Tras una perdida, el receptor descarta
cuadros dependientes hasta el siguiente keyframe: puede congelarse brevemente en
vez de mostrar referencias corruptas. Ambos extremos deben actualizarse para
que la recuperacion de x264 funcione con keyframes completos.

Si los artefactos persisten por perdida de paquetes Wi-Fi o problemas con RTP,
usar `--transport tcp` en ambos extremos. TCP retransmite los datos perdidos y
envía H.264 Annex B sin RTP; puede añadir latencia variable. `--jitter-ms` sólo
aplica a UDP. Con TCP, `recv --sink auto` prefiere ffplay si está instalado: en
Tengu evitó las franjas horizontales que aparecían con la recepción GStreamer
durante movimiento intenso. Se puede pedir explícitamente con `--sink ffplay`.
El cursor separado sigue por UDP y GVD lo mueve también al usar ffplay.

Los artefactos parecidos a entrelazado tambien pueden ser tearing del compositor
o estar en el video de origen; estos ajustes no hacen desentrelazado del contenido.
El perfil balanced dedica mas trabajo a la compresion; no implica menos Mbps
si se mantiene el mismo bitrate CBR.

Cursor separado (`separate`, default): el video va sin cursor y la posición viaja por
UDP en `port+1` (5601); `recv` mueve el cursor nativo de sway con i3-ipc (`seat * cursor
set x y`), descubriendo `$SWAYSOCK` o, si falta, un glob `/run/user/<uid>/sway-ipc.*.sock`.
`--cursor none` lo desactiva; sin sway disponible sigue sin cursor (avisa una vez).

Sinks en tengu: `ffplay` para TCP; `glimagesink` (ventana, Wayland y X11), `waylandsink` (con `fullscreen`), `xvimagesink` (sólo X11).

## Integración con gdtk / Vecindario
gdtk debe tratar a gvd como proceso externo. En desarrollo, buscar primero
`$GVD_PATH`; luego `~/Proyectos/gvd/gvd.py`; luego `~/gvd/gvd.py` para hosts donde
se copió el PoC. Ejecutar siempre con `python3`.

Comandos base:
```
# B recibe como cliente Wayland dentro del compositor de gdtk
python3 /home/icarito/Proyectos/gvd/gvd.py recv --sink wayland --port 5600

# A extiende una pantalla GNOME hacia B
python3 /home/icarito/Proyectos/gvd/gvd.py send --host B.local --port 5600 \
  --size 1280x800 --fps 30 --bitrate 8000 --position right

# Vecindario detecta capacidades antes de mostrar la acción
python3 /home/icarito/Proyectos/gvd/gvd.py caps --json
```

Dependencias mínimas por rol:
- `recv`: Python 3, PyGObject (`gi`), `gst-launch-1.0`, `gst-inspect-1.0`,
  `rtph264depay`, `h264parse`, `avdec_h264`, `videoconvert`, y un sink disponible
  (`waylandsink` para gdtk; `glimagesink`/`xvimagesink` como fallback).
- `send`: lo anterior más GNOME Wayland/Mutter ScreenCast por D-Bus, PipeWire,
  `pipewiresrc`, `rtph264pay`, `x264enc` o `vah264enc`+`vapostproc`.
- cursor separado: `gvd-cursor.c`, `gcc`, `pkg-config`, `libpipewire-0.3`
  para compilar el helper en el emisor; `recv --cursor sway` necesita el socket
  i3/sway si se quiere mover el cursor nativo.

Puertos: video RTP/H.264 por UDP o TCP `--port` (5600 por defecto); cursor separado por
UDP `--port + 1` (5601 por defecto). Abrir ambos en la LAN si hay firewall.

Seguridad: no hay cifrado ni autenticación en el stream. Vecindario debería
ofrecer esta acción sólo en vecinos de confianza, idealmente sobre LAN propia o
WireGuard. SSH sirve para lanzar procesos remotos, no protege el RTP.

Discovery hints: `caps --json` da un contrato barato (`schema=gvd.caps.v1`) con
defaults, puertos, sinks, encoders y dependencias locales. Para Vecindario alcanza
con sondear por SSH:
```
ssh B 'python3 ~/Proyectos/gvd/gvd.py caps --json 2>/dev/null || python3 ~/gvd/gvd.py caps --json'
```
Si luego se agrega mDNS, anunciar `_gvd._udp` con TXT mínimo como
`schema=gvd.caps.v1`, `port=5600`, `cursor_port=5601`, `codec=h264`,
`size=1280x800`, `role=recv`.

## Formato en el cable (contrato para interoperar)
RTP/UDP o H.264 Annex B/TCP en el puerto 5600, H.264 constrained-baseline (baseline con x264), SPS/PPS repetidos (`config-interval=-1`), keyframe completo cada 1 s de video, sin intra-refresh. UDP usa `payload=96`, `clock-rate=90000`, `mtu=1200`. El receptor debe usar el mismo transporte. Sin cifrado ni autenticación: sólo LAN de confianza.

Cursor (si el emisor usa `--cursor-mode separate`): UDP puerto 5601, datagramas de 8 bytes big-endian `x:u16 y:u16 seq:u32` en píxeles del stream; el receptor descarta `seq` viejo y aplica sólo el último.

## Medido (PoC)
~30 fps (mín ~20 con escritorio quieto). CPU de tengu (Core2 L9400, decode H.264 por software): ~26–30 % de 2 cores. Encoder en A: VA-API.

## Limitaciones conocidas
- Sin recuperación explícita de pérdidas (sólo keyframes periódicos); sin cifrado; un monitor por proceso.
- Se vio el fondo y el dock en la captura de `Meta-0`; es esperable en un monitor secundario, pero falta verificar con una ventana arrastrada de verdad.
- Falta medir con movimiento real del escritorio y por Wi-Fi.

Verificacion del pipeline sin modificar el monitor activo:
`python3 -m unittest discover -s tests -v`. Codifica 1280x800@30, envia RTP por
loopback y decodifica; incluye perdida de paquetes y reordenamiento, con VA
(si esta disponible) y x264. Requiere PyGObject con Gst y los plugins de GVD;
`wait-for-keyframe` requiere GStreamer >= 1.20.
