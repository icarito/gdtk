# SPEC — Vecindario: señal Wi-Fi que comparte Internet + asociarse a APs

Estado: implementado (corte 1, 2026-10-05). Repo: `gdtk`. Sólo scripts `.gd`; sin
cambios de motor. El experimento STA+AP de radio única se documenta al final y se
ejecuta con OK explícito del usuario.

## Objetivo

Desde el **Vecindario** (no desde el Frame), en **cualquier host con gdtk**
(bastion, tengu, cupid), la placa central «Este equipo» permite:

1. **Crear una señal Wi-Fi** (AP con NetworkManager, `ipv4.method shared` =
   DHCP+NAT con dnsmasq) que **siempre comparte el Internet** de ese host, con
   clave WPA pedida en un popup del shell.
2. **Asociarse a APs**: las redes abiertas conectan directo; las protegidas piden
   la clave en el mismo popup (antes caían en `nmtui`). Si NM ya tiene el perfil
   guardado, se activa sin pedir nada.
3. **Honestidad de estado**: señal activa con/sin Internet, APs alcanzables y los
   equipos que entran a la señal aparecen como vecinos (mDNS ya corre sobre la red
   compartida).

## Decisiones

| Decisión | Resultado |
|---|---|
| Gesto en el Frame | **No**: sólo en el Vecindario. El bloque del Frame sólo muestra y abre el Vecindario |
| Dónde | **Menú de «Este equipo»**: la placa central es clicable (área = círculo de radio `MAP.CENTER_HIT_RADIUS`), clic izq/der abren el mismo menú |
| Clave | **WPA con campo de texto** en un popup ImGui del shell → archivo 0600 efímero en `$XDG_RUNTIME_DIR/gdtk/wifi-psk` → `nmcli ... passwd-file <archivo>`. El secreto NUNCA en argv/logs/estado. Plan B si NM no acepta el psk por archivo: Terminal con `--ask` (patrón `nmtui`) |
| Perfil | El shell **recrea** el perfil estable **`Hotspot`** (SSID = hostname) en cada encendido: `nmcli con delete Hotspot; nmcli con add type wifi con-name Hotspot autoconnect no ssid <host> mode ap key-mgmt wpa-psk ipv4.method shared`. Así la clave tipeada es la autoritativa: nmcli no permite borrar un psk ya guardado y `con up` reutilizaría el viejo (verificado: `con modify ... psk ""` NO lo borra) |
| Canal | Mientras haya STA activa se fija **banda + canal** del AP al de la STA (`802-11-wireless.band bg|a` + `.channel`; el canal solo falla con «requiere band»). Sin STA, automático |
| Conteo de clientes | Fuera del corte 1 (contarlos pide root por `iw station dump`) |
| Ad-hoc IBSS | Descartado: sin NAT confiable de NM; los perfiles `Sugar Ad-hoc Network *` quedan sin tocar |

## Modelo puro — `shell/neighborhood_hotspot.gd`

`extends Reference`; `selftest()` y `run_selftest()`. Sin I/O, sin procesos:

- **Planes argv** (sin secretos): `create_plan(ssid)`, `up_plan(profile)`,
  `down_plan(profile)`, `ensure_wpa_plan(profile)`, `channel_plan(profile, chan)`.
- `passwd_file_text(psk)` → `802-11-wireless-security.psk:<clave>\n`, el formato
  documentado de `nmcli ... passwd-file` (`setting.propiedad:clave`). Ojo: `-P` NO
  es una opción global de nmcli; `passwd-file` es un argumento del subcomando
  (`connection up ... passwd-file <archivo>`).
- **Validación**: psk 8..63 (WPA), SSID 1..32, sin `\n`/`\r`/`\t`/NUL. La clave va
  por archivo, no por shell, así que no se restringe su alfabeto.
- **Parseo**: `parse_active(text, profile)` sobre
  `nmcli -t -f NAME,DEVICE,TYPE connection show --active` → `{active, device,
  profile}`; `parse_saved(text)` sobre `nmcli -t -f NAME connection show`;
  `parse_connectivity(text)` sobre `nmcli -t -f CONNECTIVITY general` (tolera
  forma bare `full` y `CLAVE:valor`; `""`/`unknown` → `sin_dato`).
- `internet_state(connectivity)`: `full`→«sí», `limited`/`portal`→«limitada»,
  `none`→«no», resto→«sin dato».

## Worker — `shell/neighborhood.gd`

Al final de `_scan()` (mientras nmcli exista) se leen el perfil activo, la
conectividad y los perfiles guardados, más el canal de la STA. Se publica un campo
`share` por el mismo Mutex que `nets/hosts/bt`, expuesto en `poll()` como
`hotspot`; `share_line()` devuelve el estado humano. Si no hay nmcli:
`{available:false}` sin salida cruda. Nada de I/O nmcli en el hilo de render.

## UI — `shell/neighborhood_ui.gd`

- `hit_center` (en `neighborhood_map.gd`) en `_on_mouse_button`, guardado por
  `mode == "neighborhood" and draw_center` → `_open_self_menu()` (título «Este
  equipo») con filas:
  - `Crear señal Wi-Fi (comparte Internet)` — deshabilitada con razón honesta si
    no hay nmcli («nmcli no disponible»), radio apagada («Wi-Fi apagado») o ya
    activa («ya está encendida»);
  - `Apagar señal` — visible si el perfil está activo;
  - fila informativa `Señal de <host> · Internet: sí|limitada|no` (o «Señal
    apagada»).
- Redes protegidas: la fila de conexión pasa a `wifi_connect_psk` →
  `shell._wifi_psk_request(ssid)`.

## Shell — `shell/shell.gd`

- `_wifi_psk_request(ssid)`: si el perfil ya está en la lista guardada del worker,
  `nmcli connection up id <ssid>` sin pedir nada; si no, abre el popup
  `##clave_wifi`.
- Popup ImGui (`##clave_wifi`, precedentes `##home_session`/`##wm_menu`): campo
  `input_text_enter` (ENTER confirma; el binding no expone máscara de password,
  aceptable en el corte 1), `Confirmar`/`Cancelar`.
- `_write_psk_file` (0600) + activación asincrónica vía
  `sh -c '... nmcli ... passwd-file "$f"; rc=$?; rm -f "$f"; exit $rc'` (el
  archivo se borra siempre, sin timer; la ruta es argv, nunca la clave).
- `_wifi_share_create` (asegura perfil WPA + canal de la STA + `con up`) y
  `_wifi_share_stop` (`con down`). Tras cada acción: `neighborhood.request_refresh()`.

## Estados honestos y códigos nmcli

Se mantienen los códigos de `SPEC-sugar-journal-neighborhood.md` (4 activación
fallida, 8 NM caído, 10 red inexistente). Como es fire-and-forget, el Estado real
lo refleja el worker en el próximo refresco; no quedan prompts colgados.

## Riesgos y fallbacks

- Si NM no alimenta el psk por archivo → Terminal `--ask` (patrón `nmtui`).
  **Verificado que sí lo alimenta** (perfil nuevo), así que no aplica al corte 1.
- **Confirmado**: NM tumba la STA al activar el AP en radio única, aun con
  banda+canal iguales. Salidas: (a) estado honesto «señal sin Internet» (la LAN
  sirve para colaboración; un uplink ethernet da Internet completo); (b) interfaz
  virtual `ap0` (`iw dev wlan0 interface add ap0 type __ap` + perfil `ifname ap0`),
  que **requiere root una vez** → script provisorio estilo governor + acción
  PolicyKit; **no improvisar sudo en el shell**; (c) solo-LAN.
- Si el perfil `Hotspot` se recrea con otro nombre, el shell busca siempre
  `Hotspot`; el estado muestra «apagada» y la acción lo recrea (idempotente).

## Verificación

- `tests/neighborhood_hotspot_test.gd` (puro) + `neighborhood_test`,
  `neighborhood_ui_test`, `neighborhood_spread_test`, etc.; `tools/verify_all.sh`
  mirando `ok/FAIL`.
- Parseo con binario instalado (`tests/parse_check.gd`) para
  `neighborhood_ui.gd`/`shell.gd`.
- e2e CLI (2026-10-05, ver experimento abajo): `passwd-file` aplica la clave,
  banda+canal de la STA, AP WPA en el aire; NM tumba la STA. Pendiente: UI viva
  (recarga transaccional) y asociación de cupid desde su sesión local por polkit.

## Experimento STA+AP — resultado (bastion, 2026-10-05)

Ejecutado por CLI con los mismos comandos que usa el shell, más un cliente
pre-programado en cupid y timers de rollback independientes. **Hechos:**

1. **`passwd-file` SÍ alimenta el psk** y queda en el store de NM con la clave
   tipeada: perfil nuevo `con add ... key-mgmt wpa-psk` + `con up ... passwd-file`
   → `nmcli -s ... 802-11-wireless-security.psk` = la clave del archivo. (Resuelve
   la incógnita del plan; el plan B `--ask` no hizo falta.)
2. **El psk guardado no se puede borrar** con `con modify ... psk ""` (sigue el
   viejo). De ahí que el shell **recrea** el perfil en cada encendido.
3. **`con modify ... channel` solo falla**: «802-11-wireless.band: channel requiere
   la propiedad band». Con `band bg` + `channel 5` el AP sube en el canal 5.
4. **Radio única: activar el AP DESCONECTA la STA**, aun con banda+canal iguales a
   los de la STA. `nmcli connection show --active` pasa de `Alvitos_Govista` a
   `Hotspot`, `CONNECTIVITY general` cae a `limited` y el AP queda en 10.42.0.1/24
   sin uplink. El driver reporta `#{managed}<=1, #{AP}<=1, #channels<=1`, pero NM
   (wpa_supplicant AP) no mantiene STA+AP concurrentes acá.
5. **Cliente**: cupid ve el AP `bastion` con `WPA2 WPA3` señal 100. No se pudo
   completar la asociación por ssh porque el polkit de cupid deniega
   `settings.modify.system` en sesión no local (`Insufficient privileges`); desde
   la sesión gráfica local de cupid (o con `wifi.connect`) debería permitirse. La
   clave correcta del AP queda en el store de NM.

**Conclusión:** el corte 1 funciona (AP WPA con la clave tipeada, en el canal de la
STA, estado honesto) pero **no comparte Internet con uplink Wi-Fi** porque NM
tumba la STA. Fallbacks, en orden: (a) estado honesto «señal sin Internet» (la LAN
sirve para colaboración; un uplink ethernet da Internet completo); (b) interfaz
virtual `ap0` (`iw dev wlan0 interface add ap0 type __ap` + perfil `ifname ap0`) —
**requiere root una vez**, no lo hace el shell: script provisorio estilo governor +
acción PolicyKit; (c) aceptar solo-LAN. Rollback del experimento: `nmcli con up
"Alvitos_Govista"` (verificado, conectividad `full` restaurada).

## Fuera de alcance

Editor de SSID/canal desde la UI; conteo de clientes; IBSS/Sugar-mesh real; gesto
en el Frame; autoconnect; IPv6 finetuning; GNOME hotspot con `--ask` manual.

## Research HW (2026-10-06) — capacidad real de AP

- **bastion, Wi-Fi interno**: Intel **AX201** (`iwlwifi`, `phy0` **self-managed**, `country BR: DFS-UNSET`).
  - 5 GHz **`no IR`** (no puede iniciar radiación) → AP sólo en **2.4 GHz**; `iw reg set` se
    ignora (self-managed) y **no** hay `lar_disable`.
  - Anuncia `managed<=1, AP<=1, #channels<=1`, pero **AP+STA concurrente NO está soportado** en
    AX2xx (doc iwlwifi); verificado: subir el AP **tira la STA** (`CONNECTIVITY limited`, AP
    `10.42.0.1/24` sin uplink). Sin knob que lo habilite (`bt_coex_active` no aplica).
- **bastion, USB**: Ralink **MT7601U** (`148f:7601`, driver `mt7601u`): sólo `managed`+`monitor`,
  **sin AP/P2P/IBSS** (NM `WIFI-PROPERTIES.AP: no`). No sirve para hospedar.
- **cupid, Wi-Fi interno**: soporta **AP** (+P2P-GO) → **puede hospedar**.
- **tengu** (`wls1`, iwlwifi): `managed`+`monitor` (sin AP); sí `IBSS`.

**Conclusión**: para un AP usable hay que **hospedar en cupid** (o un dongle con driver mainline
AP-capable: AR9271/`ath9k_htc`, RT5370/`rt2800usb`, MT7610U/MT7612U/`mt76`, RTL8812AU/DKMS).
“Compartir Internet” requiere que el host del AP tenga **uplink no-Wi-Fi** (o NAT hacia su STA).

**Pendiente de código**: en `shell/shell.gd` **no existen** `_wifi_share_create`, `_wifi_share_stop`
ni `_wifi_psk_request` (ni el popup `##clave_wifi`); la UI del menú «Este equipo» es **inerte** hoy
(las llamadas están guardadas con `has_method`). El spec/sesión los dan por hechos: corregir.
