# 2026-10-05 — Vecindario: señal Wi-Fi que comparte Internet + asociarse a APs

Spec: `.operator-shared/specs/SPEC-sugar-senal-wifi.md` (fuente de verdad).

## Estado

Implementado en repo, tests en verde, sincronizado a `~/gdtk`. **No aplicado a una
sesión viva**: la sesión gráfica activa es GNOME (`gdm-wayland-session`), no gdtk;
no hay shell escuchando el RPC (`7777` cerrado, sin `godot-gdtk`), así que no hubo
recarga transaccional. Falta: recargar el shell en la próxima sesión gdtk y probar
la UI.

## Hechos verificados (bastion, 2026-10-05)

- `nmcli ... passwd-file <archivo>` **sí** alimenta el psk: perfil AP nuevo +
  `con up passwd-file` → `nmcli -s ... psk` = la clave del archivo.
- `con modify Hotspot 802-11-wireless-security.psk ""` **no borra** el psk
  guardado → el shell **recrea** el perfil `Hotspot` en cada encendido para que la
  clave tipeada sea la autoritativa.
- `con modify ... channel` solo falla («requiere band»); con `band bg|a` + `channel`
  el AP sube en el canal pedido.
- Radio única: activar el AP **desconecta la STA** aunque banda y canal coincidan.
  `CONNECTIVITY general` → `limited`; AP en `10.42.0.1/24` sin uplink. El driver
  promete `#{managed}<=1, #{AP}<=1, #channels<=1` pero NM no mantiene STA+AP.
- cupid ve el AP `bastion` (`WPA2 WPA3`, señal 100); asociación por ssh bloqueada
  por polkit de cupid (`Insufficient privileges` en sesión no local).
- Rollback probado: `nmcli con up "Alvitos_Govista"` restaura `full`.

## Cambios

- Nuevo `shell/neighborhood_hotspot.gd` (modelo puro: planes argv, validación psk
  8..63/SSID ≤32, `passwd_file_text`, parsers, `internet_state`, `band_arg`).
- `shell/neighborhood.gd`: lee perfil activo/conectividad/perfiles guardados/canal
  y banda de la STA; publica `hotspot` + `share_line()`.
- `shell/neighborhood_map.gd`: `hit_center` (placa «Este equipo»).
- `shell/neighborhood_ui.gd`: menú de «Este equipo» (crear/apagar señal, info
  honesta) y fila `wifi_connect_psk` para redes protegidas.
- `shell/shell.gd`: popup `##clave_wifi`, `_wifi_psk_request`, `_wifi_share_create`
  /`_wifi_share_stop`, archivo 0600 en `$XDG_RUNTIME_DIR/gdtk/wifi-psk`, activación
  con `passwd-file` + `rm` en el mismo `sh`.
- `tests/neighborhood_hotspot_test.gd` (36 checks) + `tests/parse_check.gd` ok.
- Spec + fila en `catalog.md`.

## Próximos pasos

1. En la próxima sesión gdtk: recargar el shell y probar la UI (clic en la placa
   central, popup de clave, crear/apagar señal).
2. Decidir sobre Internet con uplink Wi-Fi: flujo honesto actual (señal sin
   Internet) vs. provisión root de `ap0` (script estilo governor + PolicyKit). El
   shell NO improvisa sudo.
3. Asociación de un cliente real desde su sesión local (polkit) para cerrar el e2e.
4. No commitear/deployar sin pedido.
