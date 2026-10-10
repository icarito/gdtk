# Handoff — KDE Connect (auditoría 2026-10-08)

## Estado 2026-10-10 17:45 — MAYORÍA DE BLOQUEANTES RESUELTOS, transporte sigue abierto

Fixes aplicados (commit `ac62ead`, tests e2e reales verdes):

- **Errores ejecutados (5)**: resueltos. `String.is_empty()` fuera de
  `parse_pactl_sinks` (y filas con nombre vacío rechazadas, `:313`);
  `PK.BATTERY` definida y declarada en `INCOMING_CAPS`; `special_key_code` ahora
  mapea los índices 1..32 de protocol.md v8 (antes interpretaba códigos Qt), con
  Linefeed(3) → KEY_ENTER.
- **Estado de emparejamiento (3)**: resuelto. La respuesta positiva a nuestro pedido
  saliente COMPLETA el pareo (`_on_pair`, `:597`); los pedidos entrantes quedan
  pendientes con timestamp ±30 min (`PK.pair_timestamp_ok`) y aceptación/rechazo por
  RPC `kdeconnect` (nuevo en `remote.gd:263`, ops
  `state|pair_accept|pair_reject|pair_request|unpair`). El op `pair_request` es la
  solicitud explícita que faltaba.
- **Persistencia (4)**: identidad/cert/pareos en `XDG_STATE_HOME`
  (`~/.local/state/gdtk/kdeconnect-pair.json`), con fallback a `~/.local/state`.
- **Límites (framing/timeout)**: buffer sin newline respeta `MAX_PACKET_BYTES`
  (`:444`); el timeout del dial se evalúa antes del branch TLS-wrapped y cierra el
  stream correcto (`_poll_dial`/`_disconnect_dial`).
- **remember_device** refresca la IP de un device conocido (`:586`).
- **Cuelgue de motor hallado y rodeado**: `StreamPeerSSL.put_data` hace busy-loop con
  write parcial en este fork (`modules/mbedtls/stream_peer_mbedtls.cpp:146`) y colgaba
  `_process`; ahora hay cola de salida + `put_partial_data` (`_send_packet`/`_flush_conn`).
  Segunda trampa del engine reportada (sin fix): `accept_stream` entrega
  `STATUS_CONNECTED` con handshake incompleto (`:127-145`).
- **Tests**: `kdeconnect_packet_test` 62 ok rc=0 (antes abortaba en `_init` y moría por
  timeout); `kdeconnect_link_test` es ahora e2e real (listener TCP + TLS en proceso,
  framing real, gate despareado, pendiente→accept, `pair_request`→completa,
  specialKey por cable, volumen con stubs `pactl`/`wpctl`, MAX_PACKET_BYTES, timeout de
  dial) → 32 ok rc=0, sin `auto_pair`.
- **Comentario stale**: `host.gd:174-176` todavía dice que el handshake TLS entrante
  puede colgar el motor; tras el fix del busy-loop queda parcialmente obsoleto (queda el
  trap de `accept_stream`). No se tocó (fuera del write set del fix).

## Bloqueantes abiertos (transporte — requiere módulo C en el engine)

1. **Transporte incompatible + identidad autenticada (1 y 2)**: sigue. El flujo v8
   correcto es identity en claro con `targetDeviceId`/`targetProtocolVersion`, el par
   valida el destino, TLS con ROLES INVERTIDOS (el iniciador TCP pasa a servidor TLS) y
   recién ahí identity bajo TLS + pinning del cert. El prototipo envuelve TLS enseguida
   con roles TCP (`kdeconnect_link.gd:_new_inbound:385` accept / `_dial:347` connect),
   sin identity en claro ni validación de target, y autoriza por el `deviceId`
   declarado sin verificar certificado (`_on_identity:560`). Implementarlo bien exige
   que `StreamPeerSSL` exponga el cert del par → módulo C en el engine.
2. Mientras tanto el control queda gateado a devices pareados vía store JSON (sin
   secretos) y con aceptación explícita del usuario. No exponer el receptor como canal
   de control de otra confianza hasta resolver 1.


Otros límites observados: el dial deja de tener timeout al envolver TLS; el buffer
sin newline no respeta MAX_PACKET_BYTES; remember_device no actualiza IP al cambiar
un peer ya conocido. Revisar límites y recuperación antes de habilitarlo.

## Orden de trabajo

Transporte y certificado persistente → pareo bidireccional explícito → regresiones
con roles/framing auténticos y rechazo/despareo/reconexión → prueba con Android real
en instancia aislada → integrar hosts y acciones de emparejar/aceptar/rechazar/
olvidar en Vecindario/Grupo. La ausencia de botón es sólo uno de los bloqueantes.
No hace falta una reescritura de Vecindario para representar el teléfono como host.

## Referencias primarias

- [Protocolo v8 oficial](https://github.com/KDE/kdeconnect-meta/blob/master/protocol.md):
  Device Connection, Device Pairing y Mousepad.
- [LAN de KDE](https://github.com/KDE/kdeconnect-kde/blob/master/core/backends/lan/lanlinkprovider.cpp):
  tcpSocketConnected/tcpPacketReceived/configureSslSocket.

Anclajes de trabajo: shell/kdeconnect_link.gd, kdeconnect_packet.gd, host.gd,
remote.gd; tests/kdeconnect_packet_test.gd y kdeconnect_link_test.gd.
