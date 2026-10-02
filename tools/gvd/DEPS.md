# gvd vendoreado — dependencias

Copia de `~/Proyectos/gvd` (commit b08afbb) para que gdtk no dependa de un checkout
externo. Se resuelve en `shell/neighborhood_actions.gd` (`gvd_path_candidates`):
primero `~/gdtk/tools/gvd/gvd.py` (instalado por `deploy.sh`), luego los checkouts viejos.
El stream RTP/H.264/UDP o H.264/TCP **no cifra ni autentica**: sólo LAN confiable.

## Emisor (`gvd.py send`) — Mutter (GNOME) o wlroots (gdtk/sway)
El backend se elige con `--capture auto|mutter|wlr` (auto por `XDG_CURRENT_DESKTOP`):
- **mutter** (GNOME Wayland): monitor virtual `Meta-*` + ScreenCast por PipeWire.
- **wlr** (gdtk, sway, river, hyprland...): captura el output con `wlr-screencopy`
  vía `gvd-capture` (shm), sin monitor virtual ni PipeWire. El cursor va incrustado
  (`overlay-cursor=1`). Con `--virtual` (y `SWAYSOCK`) crea un monitor headless de
  sway (`create_output`) y lo ubica con `--position`: extiende de verdad el
  escritorio, como el `Meta-*` de Mutter; al terminar lo desmonta (`unplug`).

Común:
- python3 + `python-gobject` (gi: Gio, GLib)
- `gst-launch-1.0` con plugins: `gst-plugins-base/good/bad/ugly` (y `gst-plugin-pipewire` sólo en el path Mutter)
- Codificador: `gst-plugin-va` (vah264enc, VA-API Intel/AMD) o `gst-plugins-ugly` (x264enc)
- `gcc` + `pkg-config` para compilar helpers desde fuente

Sólo path Mutter:
- GNOME Mutter ScreenCast (org.gnome.Mutter.ScreenCast) y PipeWire (`pipewire`, `libpipewire` + `pkg-config libpipewire-0.3`)
- `gcc` + `pkg-config libpipewire-0.3` para compilar `gvd-cursor` (cursor separado)

Sólo path wlroots:
- `gcc` + `pkg-config wayland-client` para compilar `gvd-capture`; el protocolo
  `wlr-screencopy-unstable-v1` está vendorizado en `protocols/` (headers generados,
  ya no hace falta `wayland-scanner` ni `wlr-protocols`).

## Receptor (`gvd.py recv`) — gdtk, sway, cualquier Wayland/X11
- python3 + `python-gobject`
- `gst-launch-1.0`, `gst-plugins-base` (udpsrc, rtp), `gst-plugins-good` (rtph264depay), `gst-libav` (avdec_h264)
- Sink: `glimagesink` (gl), `waylandsink`, o `xvimagesink`
- Para `--transport tcp`, `ffplay` es el receptor preferido si está instalado;
  `--sink ffplay` lo selecciona explícitamente y evita artefactos vistos en Tengu.
- Dentro de gdtk el receptor debe abrir su ventana en el socket del compositor del shell
  (`WAYLAND_DISPLAY=wayland-N` del shell), no en el del compositor padre.

## Detección
`python3 gvd.py caps --json` lista lo disponible sin abrir streams (incluye
`send.backends`, `send.wlr_ready` y `send.wlr_capture_bin`).

## Verificación e2e (2026-10-02) y color
- Emisor wlroots: debe conectar al compositor que expone `wlr-screencopy`. En bastion
  (gdtk bajo sway) el shell tiene `WAYLAND_DISPLAY=wayland-1` (sway); si se corre desde
  una terminal del compositor embebido (`wayland-0`) falla con "el compositor no expone
  wlr-screencopy/wl_shm".
- Video e2e verificado bastion→tengu y bastion→cupid: `gvd send --capture wlr` (VA) →
  UDP/RTP H.264 → receptor decodifica (probado con `avdec_h264 ! filesink`, ~390 MB en
  8 s, ~15 fps).
- COLOR (arreglado): el encoder etiquetaba **bt601** por defecto y `vapostproc` ponía
  un valor raro (`2:4:5:1`), lo que hacía que sinks que asumen bt709/HD pintaran
  desviado. `gvd.py` ahora inserta `video/x-raw,colorimetry=bt709` DESPUÉS de
  `vapostproc` (mantiene VA) y el SPS queda bt709; verificable con `gst-launch -v ...
  ! avdec_h264 ! fakesink` (`colorimetry=(string)bt709`). Override: `GVD_COLORIMETRY`.
  Fidelidad verificada también e2e por red (referencia local vs frame decodificado en
  tengu: medias RGB coinciden).
- Sinks: el compositor embebido de gdtk NO expone `wp_viewporter`, así que
  `waylandsink` avisa "missing the ability to scale" y puede abortar. Usar `--sink
  auto` (prefiere gl/xv), `--sink gl` o `--sink ffplay` (ffplay exige `--transport tcp`).
