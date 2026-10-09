# Handoff — KDE Connect (auditoría 2026-10-08)

## Veredicto

Prototipo incompleto, apagado por defecto con un opt-in experimental. No existe
flujo de emparejamiento en Vecindario/Grupo ni RPC `kdeconnect` en remote.gd,
aunque los comentarios del receptor afirman que lo hay. No activar el servicio
principal para probar interoperabilidad: Host conserva explícitamente el opt-in
por un antecedente de cuelgue TLS, todavía sin resolución verificada.

## Bloqueantes para retomar

1. **Transporte incompatible**: v8 envía identidad de conexión por TCP sin cifrar,
   valida el destino, invierte los roles TLS (quien inició TCP es servidor TLS) y
   luego intercambia identidad cifrada. El prototipo inicia TLS inmediatamente con
   los roles habituales de TCP. El peer de test imita ese mismo flujo incorrecto.
2. **Identidad autenticada**: pertenecer al store por `deviceId` declarado habilita
   input, sin comprobar certificado del par. Un probe sin sockets confirmó esa
   autorización. El protocolo exige fijar certificados durante el emparejamiento y
   verificarlos al reconectar. El comentario de la limitación StreamPeerSSL no
   convierte el ID declarado en autenticación; resolver transporte/certificados
   antes de exponer el receptor como control autorizado.
3. **Estado de emparejamiento**: la respuesta positiva al pedido saliente se
   convierte en otro pedido pendiente, en lugar de completar el pareo. El probe
   confirmó `paired=false, pending=1`. Falta operación de solicitud explícita y
   cableado con UI/RPC; el timeout del prompt no valida timestamp del protocolo.
4. **Persistencia**: en el entorno ordinario se usa XDG_RUNTIME_DIR para identidad,
   certificados y pareos. Deben persistir entre logins/reboots; XDG_STATE_DIR no es
   XDG_STATE_HOME. Separar descubrimiento/host y confianza criptográfica.
5. **Errores ejecutados**: `String.is_empty()` no existe en este Godot 3 y rompe
   parse_pactl_sinks; el dispatcher evalúa PK.BATTERY, constante inexistente. Ambos
   scripts compilan, pero fallan al ejecutar esas rutas. No confundir preflight con
   prueba funcional. `specialKey=4` (Left real) devuelve cero eventos: el prototipo
   interpreta códigos Qt en lugar de los índices 1..32 del protocolo.
6. **Verificación engañosa**: el E2E usa auto_pair y peer falso. Timeout/error TCP
   pueden concluir sin incrementar fallas. El codec test actual abortó su _init en
   parse_pactl_sinks y terminó por timeout externo; no es verde.

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
