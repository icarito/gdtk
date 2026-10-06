# HANDOFF — Vecindario: Señal Wi-Fi (AP que comparte Internet + asociarse a APs)

Estado: **WIP ajeno, sin commitear**. Retomar en sesión nueva. Autosuficiente.
Fuentes: `SPEC-sugar-senal-wifi.md` (spec), `sessions/2026-10-05_senal-wifi.md`.

## Objetivo
Desde el Vecindario (placa «Este equipo»): crear una señal Wi-Fi (AP con NM, `ipv4.method
shared`) que comparte el Internet del host con clave WPA; y asociarse a APs (abiertos directo,
protegidos pidiendo clave).

## BLOQUEANTE REAL (código incompleto)
`shell.gd` **no tiene** la API que la UI invoca:
- Faltan: `_wifi_share_create`, `_wifi_share_stop`, `_wifi_psk_request`, popup `##clave_wifi`
  (archivo psk 0600 en `$XDG_RUNTIME_DIR/gdtk/wifi-psk`, activación `nmcli ... passwd-file`, `rm`).
- `shell/neighborhood_ui.gd:1084,1111` llama esas funciones **con guardas `has_method(...)`** →
  las filas del menú **no hacen nada** (no crashean, pero la feature es inerte). No está en ningún
  worktree (`.kilo/` ni `.claude/`). **Sin esto no hay nada que probar de UI.**
- La spec/sesión los dan por hechos: **corregir**.
- Ya existen en `shell.gd` (~9214): `_wifi_radio_on`, `_wifi_connect`, `_wifi_disconnect` (base).

## Lo que SÍ está (WIP sin commitear)
- `shell/neighborhood_hotspot.gd` — modelo puro (planes argv `create_plan/up_plan/down_plan`,
  `ensure_wpa_plan`, `channel_plan`, `passwd_file_text`, validación psk 8..63/SSID≤32, parsers
  `parse_active/parse_saved/parse_connectivity`, `internet_state`, `band_arg`). Sin I/O.
- `tests/neighborhood_hotspot_test.gd` — **36 ok, 0 fail** (corre con el binario dev).
- `shell/neighborhood.gd` — worker: publica `hotspot`/`share`/`share_line()` (nmcli en `_scan()`).
- `shell/neighborhood_map.gd` — `hit_center` (placa «Este equipo»).
- `shell/neighborhood_ui.gd` — menú «Este equipo» (crear/apagar señal, info) y `wifi_connect_psk`.
- `SPEC-sugar-senal-wifi.md` — **research HW ya agregado** (commit `8e8fe0a`).

## Capacidad de hardware (medido 2026-10-06)
| host | radio | AP | AP+STA | notas |
|---|---|---|---|---|
| bastion | Intel AX201 (`iwlwifi`, phy0 `self-managed`, country BR DFS-UNSET) | sólo **2.4 GHz** (5 GHz `no IR`) | **no** | subir AP tira la STA → `CONNECTIVITY limited`, AP `10.42.0.1/24` sin uplink. Sin `lar_disable`. |
| bastion USB | Ralink **MT7601U** (`148f:7601`, `mt7601u`) | **no** (managed+monitor) | — | NM `WIFI-PROPERTIES.AP: no`. |
| **cupid** | interna | **sí** (+P2P-GO) | single-radio (riesgo) | puede hospedar. |
| tengu | `wls1` iwlwifi | no (managed+monitor) | — | sí IBSS. |

Conclusión: **no hay AP usable en bastion**. “Comparte Internet” sólo con uplink **no-Wi-Fi**.
Para AP real: **hospedar en cupid** o usar un dongle con driver mainline AP-capable
(AR9271/`ath9k_htc`, RT5370/`rt2800usb`, MT7610U/MT7612U/`mt76`, RTL8812AU/DKMS).

## Topología viable (a probar)
**cupid = AP** (2.4 GHz) ← tengu (STA, `wls1`) y bastion (STA, dongle MT7601U).
= enlace Wi-Fi directo bastion↔cupid↔tengu.

## RIESGO (importante)
- Cupid es **radio única**: levantar el AP probablemente **tire su STA** (misma limitación
  iwlwifi). Si el SSH a cupid va por esa Wi-Fi, **se pierde el acceso** y no se puede revertir por
  red. Hacerlo con **acceso local a cupid** (o Ethernet/serial de respaldo), confirmando cada paso.
- No tocar la red de los hosts sin OK explícito.

## Cómo aplicar/testear
- Scripts: `rsync shell/... → ~/gdtk/shell/`, preflight
  (`GDTK_GODOT=~/gdtk/bin/godot-gdtk ~/gdtk/session/gdtk-preflight ~/gdtk`), **soft reload** por RPC
  `reload_shell` (OJO: tumba el listener RPC ~20 s).
- Tests modelo: `godot-dev ... --no-window --path shell -s tests/neighborhood_hotspot_test.gd`.
- AP en cupid (posible, con cuidado):
  `nmcli con delete Hotspot; nmcli con add type wifi con-name Hotspot autoconnect no ssid <host>
   mode ap key-mgmt wpa-psk ipv4.method shared band bg channel <n>; nmcli con up Hotspot passwd-file <f>`.
- Cliente: `nmcli device wifi connect <SSID> password <psk> [ifname wlanX]`.
- Verificar estado: `nmcli -t -f CONNECTIVITY general`, `iw dev <if> link`, IP del AP `10.42.0.1/24`.

## Reglas
- Editar/commitear sólo en el repo; **no** commitear/deployar este WIP sin pedido.
- El secreto NUNCA en argv/logs/TXT (por archivo 0600). Ver spec.
- No revertir WIP ajeno (`shell/neighborhood*`, spec/sesión).

## Referencias
- Spec `SPEC-sugar-senal-wifi.md` (decisiones + research HW `8e8fe0a`); sesión `2026-10-05_senal-wifi.md`.
- `shell/neighborhood_ui.gd:1084,1111` (llamadas); `shell/neighborhood_hotspot.gd` (modelo);
  `tests/neighborhood_hotspot_test.gd`.

## Arranque sugerido
1. Completar `shell.gd`: `_wifi_share_create/_stop/_wifi_psk_request` + popup (`##clave_wifi`),
   siguiendo los planes del modelo; preflight; reload.
2. Con acceso local a cupid: probar **cupid=AP**; conectar bastion (dongle)/tengu como STA.
3. Si cupid no puede AP+STA: decidir “señal sin Internet” o dongle AP-capable.
