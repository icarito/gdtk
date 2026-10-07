# SPEC — Grupo sin SSH (control por canal peer)

Estado: **en curso**. Directiva del operador (2026-10-07): el Grupo de gdtk **no
debe depender de SSH**; el control va por el **canal peer** y el transporte pesado
lo hacen **Deskflow (EIS)** y **gstreamer/ffmpeg (gvd) / PipeWire**. Prioridad:
**control primero** (lag), después audio/video. Usar siempre la **ruta más corta**
(el mesh directo).

## Lo que ya estaba (sin cambios)

`shell/peer_link.gd` + `shell/peer_control.gd`: canal peer JSON por **TCP en
`:7788`** (el `ctl` del TXT), autenticado por **token por-par (TOFU)**. Métodos ya
cubiertos SIN ssh: `gvd_recv/stop/send/status/meta/size`, `share_notify/stop`,
`clip_set`, `audio_recv/stop`, `window_input(_stream)`. El shell ya tiene el cliente
(`_peer_send_async`, `_peer_endpoint_for`, `PEER_CALL`) y gvd ya usa el canal peer
(`_queue_gvd_peer_launch`).

## Lo que se migró (2026-10-07)

El **handshake de dirección** del Vecindario era lo único por SSH
(`neighborhood_inbox.gd`: escribía JSON en `~/.config/gdtk/direction-inbox` del peer
con `ssh`). Ahora viaja por el canal peer:

- `peer_link.gd`: método **`direction`** (whitelist) + `direction_message(params)`
  que valida el DTO de `neighborhood_handshake.gd` (`kind` ∈ {proposal,response},
  `from`/`to` hids válidos, `direction` ∈ vocabulario, `accepted` bool).
- `peer_control.gd`: `direction` se atiende **sin token** (como `ping`): es la
  **vinculación inicial** del Grupo; sólo aplica un DTO validado, no ejecuta nada.
- `shell.gd`: `_send_direction(host_id,msg)` (por `_peer_send_async` al `ctl` del
  peer) reemplaza a `_send_inbox`; `_peer_direction(hid,msg)` aplica con
  `HANDSHAKE.apply` y persiste. `propose_direction`/`answer_direction` ya no ejecutan
  `ssh`. El buzón ssh queda **sólo** para leer (compatibilidad); `_send_inbox` queda
  deprecado.

## Regla

- **SSH** sólo para **aprovisionamiento/operación** (deploy, `gdtk-mesh-provision`,
  diagnóstico). Nunca en el runtime del Grupo.
- El transporte de pantalla/audio/entrada es **P2P**: Deskflow, gvd
  (gstreamer/ffmpeg) y PipeWire. gdtk sólo señaliza (peer channel) y ordena el
  arranque.
- **Ruta más corta**: con el mesh activo, los peers están en `10.42.0.x` (1 salto);
  el descubrimiento y el canal peer usan esa dirección.

## Pendiente

- gvd: `gvd_launch.gd::remote_recv_argv/remote_send_argv` (ssh) quedan como
  **fallback legado**; el camino vivo es el método peer `gvd_recv/gvd_send`. Revisar
  si se pueden eliminar.
- Clientes deben recargar para tener el receptor `_peer_direction`.
