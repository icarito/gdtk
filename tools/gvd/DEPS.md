# gvd vendoreado — dependencias

Copia de `~/Proyectos/gvd` (commit b08afbb) para que gdtk no dependa de un checkout
externo. Se resuelve en `shell/neighborhood_actions.gd` (`gvd_path_candidates`):
primero `~/gdtk/tools/gvd/gvd.py` (instalado por `deploy.sh`), luego los checkouts viejos.
El stream RTP/H.264/UDP o H.264/TCP **no cifra ni autentica**: sólo LAN confiable.

## Emisor (`gvd.py send`) — hoy sólo en un escritorio GNOME/Mutter
- python3 + `python-gobject` (gi: Gio, GLib)
- GNOME Mutter ScreenCast (org.gnome.Mutter.ScreenCast) y PipeWire (`pipewire`, `libpipewire` + `pkg-config libpipewire-0.3`)
- `gst-launch-1.0` con plugins: `gst-plugin-pipewire`, `gst-plugins-base/good/bad/ugly`
- Codificador: `gst-plugin-va` (vah264enc, VA-API Intel/AMD) o `gst-plugins-ugly` (x264enc)
- `gcc` + `pkg-config` para compilar `gvd-cursor` (cursor separado) desde `gvd-cursor.c`

## Receptor (`gvd.py recv`) — gdtk, sway, cualquier Wayland/X11
- python3 + `python-gobject`
- `gst-launch-1.0`, `gst-plugins-base` (udpsrc, rtp), `gst-plugins-good` (rtph264depay), `gst-libav` (avdec_h264)
- Sink: `glimagesink` (gl), `waylandsink`, o `xvimagesink`
- Para `--transport tcp`, `ffplay` es el receptor preferido si está instalado;
  `--sink ffplay` lo selecciona explícitamente y evita artefactos vistos en Tengu.
- Dentro de gdtk el receptor debe abrir su ventana en el socket del compositor del shell
  (`WAYLAND_DISPLAY=wayland-N` del shell), no en el del compositor padre.

## Detección
`python3 gvd.py caps --json` lista lo disponible sin abrir streams.
