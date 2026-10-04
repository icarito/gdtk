# Sesión 2026-10-04 — Grupo: compartir ventanas y audio por arrastre

Contrato: `specs/SPEC-sugar-group-2026-10.md` § «Enviar audio y ventanas».

## Hecho
- Primera versión (menú + reabrir la app en el otro equipo) descartada por el usuario: compartir una
  ventana es transmitirla por gvd, y todo va por arrastrar y soltar en Grupo.
- gvd: backend `--capture shm` (`shm_capture`, mismo contrato que gvd-capture) + test.
- `shell/window_cast.gd` (Viewport fuera de pantalla → archivo con seqlock, escritura en Thread),
  `gvd_launch.window_send_argv`, `shell._group_drop_window/_group_share_window/_group_unshare_window`,
  hook en `frame._finish_drag`.
- Audio: `audio_send.gd` (Kilo, brief `briefs/A1-audio-send-model.txt`), `applet_audio.gd`, hook en
  `frame._finish_applet_drag`, `shell._group_drop_audio`, métodos peer `audio_recv/audio_stop`.
- `peer_control`: `peer-tokens.json` tiene dos escritores (srv: el canal, cli: el shell); el canal
  descartaba sus srv: al cargar y pisaba los cli: al guardar → `unauthorized` entre pares tras
  cada recarga. Ahora cada uno lee y reescribe sólo sus claves (test). En tengu se borró a mano el
  srv: viejo de cupid para re-emparejar.
- `gvd recv` reinicia su ventana al cambiar el tamaño del video: el cierre «de la persona» se
  detecta en `_close_window_id` (frame y RPC ahora pasan por ahí), no por toplevel_removed.
- `remote.gd`: reintenta el listen (tras `Host.reload_remote` en el arranque el puerto 7777 podía
  quedar sin nadie escuchando y el shell sin RPC).

## Verificado e2e (por RPC 7777, gestos reales de arrastre)
- tengu → cupid: bloque de Alacritty/htop soltado sobre cupid → se ve en vivo en cupid (x264/RTP
  944×500 a 20 fps). Cerrar la «Pantalla compartida» en cupid → cupid termina su `gvd recv` y avisa;
  tengu corta emisor y archivo. Cerrar la ventana original en tengu → corta y cierra el receptor.
- cupid → tengu: bloque Audio soltado sobre tengu → salida por omisión = túnel, el bloque dice
  «tengu»; de vuelta sobre «Este equipo» → salida local restaurada y módulos descargados en ambos.
- Tests: neighborhood_ui, peer_link, peer_control, group_model, audio_send, gvd_launch, frame_menu,
  neighborhood_actions y `tools/gvd` (10) en verde.

## Pendiente / notas
- bastion: sólo sincronizado; entra en el próximo login (prohibido reiniciar su shell con VS Code).
- El receptor no ajusta su ventana al tamaño del video: se ve con franjas negras.
- La ventana compartida no incluye popups que caigan fuera de su rect; readback GL por tick
  (`ponytail` en window_cast.gd) hasta el broker dmabuf de SPEC-embedded-multi-output.md.
- No hay resaltado del equipo destino mientras se arrastra.
- bastion corre el peer_control viejo (bug de tokens) hasta su próximo login: puede pedir
  re-emparejar con tengu/cupid.
- En cupid se agregó el bloque Audio a `frame-applets.json` para la prueba (copia en
  `/tmp/frame-applets.bak.json` de cupid).
