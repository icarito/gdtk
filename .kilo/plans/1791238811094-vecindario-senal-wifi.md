# Plan — Vecindario: señal Wi-Fi que comparte Internet + asociarse a APs

Repositorio: `/run/media/icarito/DATA/icarito/Proyectos/gdtk` (sólo scripts `.gd`;
**sin cambios de motor, sin commit, sin deploy salvo sync + recarga**).

## Objetivo

Desde el Vecindario (no desde el Frame — decisión del diseño), en **cualquier host
con gdtk** (bastion, tengu, cupid — la función es igual en todos):

1. **Crear señal Wi-Fi**: el host emite un AP (`NetworkManager`, modo `ap`,
   `ipv4.method shared` = DHCP+NAT con dnsmasq) que **siempre comparte el
   Internet** de ese host, con clave WPA pedida en un campo de texto del Vecindario.
2. **Asociarse a access points**: redes abiertas conectan directo (ya existe);
   redes WPA piden la clave en el mismo componente (hoy caen en `nmtui`;
   el usuario reportó que asociarse no queda cómodo: "ahorita sólo muestra").
3. **Honestidad de estado**: señal activa con/sin Internet, APs alcanzables, y
   los equipos que entran a la señal aparecen como vecinos (mDNS ya corre sobre
   la red compartida; para eso no hay que hacer nada).

## Hechos verificados (bastion, 2026-10-05)

- Una sola radio (`wlan0`) que HOY es el uplink (`Alvitos_Govista`, canal 5,
  `192.168.18.6`); ethernet `enp0s31f6` sin cable; wwan desconectado.
- El driver admite STA+AP concurrentes **sólo en el mismo canal**
  (`iw phy0 info` → `#{managed}<=1, #{AP}<=1, #channels<=1`).
- NM 1.58.1; polkit del usuario: `wifi.share.open/protected` y
  `settings.modify.system` = «sí» → todo alcanza desde el shell sin sudo.
  `dnsmasq` instalado (lo que usa `ipv4.method shared`).
- Ya existe el perfil **`Hotspot`** (SSID `bastion`, `mode ap`,
  `ipv4.method shared`, abierto, `autoconnect no`) — reutilizarlo como
  perfil/identidad de la señal.
- Perfiles `Sugar Ad-hoc Network 1/6/11` (mode adhoc, IP link-local): NO usarlos
  (IBSS no tiene NAT confiable de NM); dejarlos sin tocar.

## Decisiones tomadas (con el usuario)

| Decisión | Resultado |
|---|---|
| Gesto en el Frame | **No**: sólo en el Vecindario. La regla de spec («el bloque del Frame sólo muestra estado y abre el Vecindario») queda en pie |
| Dónde en el Vecindario | **Menú de «Este equipo»**: la placa central pasa a ser clicable, con hit área = círculo central |
| Clave de la señal | **WPA con campo de texto en el Vecindario** → archivo 0600 efímero en `$XDG_RUNTIME_DIR/gdtk/` → `nmcli --passwd-file`. El secreto NUNCA en argv/logs/estado. Si `nmcli -P` no alimenta el psk: plan B = pedir en Terminal (`alacritty -e nmcli ... --ask`, patrón `nmtui` actual) |
| Experimento radio única | **Sí, al final con OK del usuario**: activar `Hotspot` ~1 min con la STA viva; rollback inmediato `nmcli con up "Alvitos_Govista"`; si NM tira la STA → fallback del §Riesgos |
| Ad-hoc IBSS real | Descartado (ver hechos) |

Detalles fijados:

- **Perfil**: reutilizar `Hotspot` (id estable). Primera vez: si el perfil no
  existe → `nmcli con add type wifi ifname wlan0 con-name Hotspot autoconnect no
  ssid <hostname> mode ap 802-11-wireless-security.key-mgmt wpa-psk
  ipv4.method shared` (sin psk en argv); si existe abierto (como hoy) →
  `nmcli con modify Hotspot 802-11-wireless-security.key-mgmt wpa-psk`
  (no es secreto) y `con up` con el archivo de psk. Tras la activación NM guarda
  el psk en su store raíz: las activaciones siguientes no piden nada.
- **Canal**: mientras haya STA activa, fijar el canal de la señal al de la STA
  (mismo canal: requisito del driver). Sin STA (uplink ethernet/wwan) → canal
  automático. El experimento decide cuál variante queda por defecto.
- **Conteo de clientes**: first cut SIN conteo (contarlos necesitaría root por
  `iw station dump`); el detalle honesto es «los equipos que entran aparecen
  como vecinos».
- **SSID**: el del perfil (hoy `bastion` = hostname). Sin editor de SSID en el
  primer corte.
- Tras cada acción: `neighborhood.request_refresh()` (patrón existente).

## Tareas (orden)

1. **Modelo puro `shell/neighborhood_hotspot.gd`** (`extends Reference`,
   `selftest()` como en `neighborhood.gd`):
   - Planes argv (sin secretos): `create_plan(ssid)` (perfiles de arriba),
     `up_plan(profile)`, `down_plan(profile)`, `ensure_wpa_plan(profile)` (con
     modify key-mgmt), `channel_plan(profile, chan)`.
   - `passwd_file_text(psk)` → línea `802-11-wireless-security.psk <clave>`
     (formato documentado de `nmcli -P`: prefijo `setting.prop` opcional).
   - Validaciones: psk 8..63 chars (WPA), SSID ≤ 32, sin `\n`/`\r`/`\t`/NUL,
     seguro para argv puro (sin shell).
   - Parse de estado: `parse_active(text)` sobre
     `nmcli -t -f NAME,DEVICE,TYPE connection show --active` →
     `{"active": bool, "device": str}` para el perfil del señal y
     `parse_connectivity(text)` sobre `nmcli -t -f CONNECTIVITY general`
     (`full/limited/none/""`). Sin I/O.
2. **Worker del Vecindario (`shell/neighborhood.gd` `_scan()`)**: al final de
   `_scan()` leer esas 2 ejecuciones y publicar un campo `share`
   (por el mismo Mutex de `nets/hosts/bt`), expuesto en `poll()` (`var hotspot`)
   con un `share_line()` tipo `status_line()`. El refresh del span de 20 s
   tolera 2 ejecuciones más; `no_nmcli` reuse del estado existente.
3. **UI del Vecindario (`shell/neighborhood_ui.gd`)**:
   - Hit de la placa central en `_on_mouse_button` (círculo ~34 px; clic
     izquierdo y derecho abren el mismo menú) → `_open_self_menu()` con el
     patrón existente (`_menu_is_self = true`, título «Este equipo»): filas:
     - Crear señal Wi-Fi (comparte Internet) — disabled con razón honesta si
       no hay `nmcli`, radio apagada o el otro flujo falló;
     - Apagar señal — visible si el perfil está activo;
     - fila informativa del estado (`Señal de bastion · Internet: sí|no`)
       como `reason` sin acción;
     - separator + nada más (sin extras).
   - **Conectar AP con seguridad**: `_wifi_menu_items()` cambia la fila
     `wifi_connect` para `security ≠ --/""` a `wifi_connect_psk` →
     `shell._wifi_psk_request(ssid)` (nuevo). Si el perfil ya está guardado,
     la acción primero intenta `nmcli con up <ssid>` (psk ya en la store NM;
     sin pedir nada); sólo si no existe perfil → pedir clave. Abiertas: hoy igual.
4. **Campo de clave (ImGui, `shell/shell.gd`)**:
   - popup `##clave_wifi` (precedentes `##home_session` en shell.gd:4242 y
     `ui.input_text` en apps.gd:388): título «Clave de <target>»,
     `input_text`, Confirmar/Cancelar, ENTER = confirmar. Masking si el binding
     de ImGui lo exporta; si no, texto plano (aceptable first cut).
   - Al confirmar: escribir `passwd_file_text(psk)` en
     `$XDG_RUNTIME_DIR/gdtk/wifi-psk` (0600, tmpfs de sesión; patrón
     Portapapeles que ya escribe secretos en `$XDG_RUNTIME_DIR/gdtk/`) y correr
     asincrónicamente `sh -c 'nmcli -t -P "$1" <subcmd>; rm -f "$1"' sh <archivo> <subcmd>`:
     el archivo se borra SIEMPRE al terminar el comando (no requiere un timer).
     El PATH del archivo es argv, no el secreto. Nunca loggear contenido;
     el Estado le mide el worker (fire-and-forget como `_wifi_connect` hoy).
   - Dos usos del mismo popup: crear señal (target = perfil Hotspot) y
     conectarse a un AP (target = SSID).
5. **`tests/neighborhood_hotspot_test.gd`** (estilo `neighborhood_test.gd`,
   `extends SceneTree`, `check()`, `OS.exit_code`): planes argv, psk/ssid
   válidos e inválidos, contenido del passwd-file, parseo de conexiones
   activas/conectividad con muestras nmcli reales de bastion.
   Verificar si `tools/verify_all.sh` necesita alta explícita (mirar cómo lista los
   tests) y agregarlo; `tests/parse_check.gd` para el parseo con binario
   instalado de `neighborhood_ui.gd`/`shell.gd` (ver el patrón del archivo).
6. **Spec + catálogo**: nueva
   `.operator-shared/specs/SPEC-sugar-senal-wifi.md` (decisiones, topología,
   experimento + rollback, fallbacks, estados honestos, códigos nmcli 4/8/10
   del flujo Wi-Fi de la spec vigente) y fila en `.operator-shared/catalog.md`.
7. **Rollout**:
   - Tests: `binario dev --no-window --path shell -s $PWD/tests/neighborhood_hotspot_test.gd`
     + los tests de vecindario previos (neighborhood, hosts, publish, actions,
     ui) + `tools/verify_all.sh` (mirar `ok/FAIL`, no rc).
   - Sync (AGENTS): `rsync -a --delete --exclude .import --exclude '*crash*' shell settings ~/gdtk/`.
   - **Recarga transaccional del shell** en bastion (permitida con VS Code
     abierto según AGENTS; comprobar PID/ventanas y `state` respondiendo).
8. **Experimento final STA+AP (con OK del usuario, ventana ~1 min)**:
   a. Capturar Estado inicial (`nmcli -t -f CONNECTIVITY general`, conexiones
      activas, canal actual de la STA).
   b. Crear la señal DESDE EL VECINDARIO (con clave: verifica la ruta
      `--passwd-file` completa).
   c. ~15 s → leer conexiones activas, conectividad, `iw dev` (¿AP en el aire?),
      ping/fqDN check, y conectar tengu/cupid desde SU Vecindario (SSID
      `bastion`, con la misma clave) y probar Internet desde ellos.
   d. Si NM tumbó la STA: `nmcli con up "Alvitos_Govista"` YA, decidir fallback
      (§Riesgos) y registrar el resultado en el spec + `sessions/`.

## Riesgos y fallbacks

- `nmcli -P` no alimenta el psk (hotspot o `device wifi connect`) → Plan B:
  pedir en Terminal con `--ask` (patrón `nmtui` actual). El popup ya usable
  queda para un corte 2 con el binding si exista.
- NM tumbe la STA al activar el AP (radio única): fallback escalonado:
  1. Fijar el canal del perfil al canal actual de la STA y reintentar (si el
     AP sólo falla por el canal).
  2. Interfaz virtual `ap0` en el mismo canal (`iw dev wlan0 interface add ap0
     type __ap` + perfil `ifname ap0`, `ipv4.method shared`): necesita raíz UNA
     vez → script provisorio estilo governor (`session/gdtk-wifi-ap-provision`
     + acción PolicyKit dedicada). **No improvisar sudo dentro del shell.**
  3. Si nada de eso: Estado honesto «señal sin Internet». La LAN entre todos
     sigue sirviendo para la colaboración (Vecindario/Deskflow/gvd); apuntar en
     el spec que un uplink ethernet (cable) da Internet completo.
- Clave mal tipeada: fire-and-forget como el flujo actual de conexión — el
  refresh del worker refleja el Estado real (NM exit 4 = activación fallida)
  y no quedan prompts colgados.
- Avahi: verificar que anuncia sobre la interfaz del hotspot (el default de
  avahi escucha en todas las interfaces; `allow-interfaces` sólo si acaso).
- NM puede recrear el perfil `Hotspot` si alguien corre `nmcli device wifi
  hotspot` a mano: el shell SIEMPRE busca por nombre fijo `Hotspot`; si el
  nombre cambia, el Estado muestra «perfil no encontrado» con razón y se
  recrea con la acción (idempotente).

## Verificación

- `tests/neighborhood_hotspot_test.gd` (nuevo, puro) + todos los de vecindario
  previos (Test, hosts, publish, actions, ui) + `tools/verify_all.sh`
  revisando `ok/FAIL`.
- Parseo con binario instalado (`tests/parse_check.gd`) para
  `neighborhood_ui.gd`/`shell.gd` (usan clases nativas).
- e2e tras la recarga: crear señal → tengu y cupid dentro (DHCP, aparecen
  como vecinos, navegan por Internet) → apagar señal → la LAN desaparece
  limpio y el Estado vuelve a «apagada» sin artefactos.
- **No commit/deploy** de más; `git status` limpio de archivos ajenos.

## Fuera de alcance

- Editor de SSID/canal desde la UI; conteo de clientes (camino raíz `iw`);
  IBSS/Sugar-mesh real; gesto en el Frame; autoconnect; IPv6 finetuning;
  copy/°configs de otros entornos (GNOME hotspot con `--ask` manual).
