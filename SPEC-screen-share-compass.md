# SPEC — Brújula de pantalla compartida en Vecindario

Estado: diseño, sin implementar. Refina la parte de pantalla de
`SPEC-sugar-neighborhood-host-actions.md` y usa el contrato real de
`~/Proyectos/gvd` y el ciclo de vida de `shell/shell.gd`. No reemplaza el flujo
Wi-Fi ni el modelo DNS-SD ya propuestos: los extiende con **dirección**.

## 0. Contrato duro: el hilo de render nunca espera

Regla de arquitectura del proyecto, no negociable para este feature: **el hilo de
render sólo dibuja estado ya disponible; nunca consulta.** `_process()`,
`_imgui_frame()`, `_draw()`/`draw()`, `refresh()` y todo callback del hilo
principal/render sólo leen snapshots atómicos. Cualquier cosa que pueda tardar vive
en workers con caché y TTL.

Prohibido en esos callbacks:

- `OS.execute(...)` con captura (`blocking=true`, el default en Godot 3),
  `OS.kill`, `pgrep`, `kill -0`;
- `bluetoothctl`, `nmcli`, `localectl`, `avahi-browse`, `avahi-publish-service`;
- discovery mDNS, `gvd caps`, arranque de procesos/SSH, Deskflow, lectura de `/sys`,
  timeouts y reintentos;
- `OS.delay*`, `Thread.wait_to_finish()`, `OS.get_ticks_msec()`-polling de procesos;
- leer disco o rasterizar SVG/GLB fuera de una caché.

Permitido en esos callbacks:

- copiar bajo `Mutex` un snapshot ya publicado y dibujarlo;
- matemática pura acotada (p. ej. `relax_capsules` con N limitado);
- crear nodos/texturas a partir de datos **ya cargados o cacheados**.

Patrón canónico ya vigente: `shell/neighborhood.gd` corre `_scan()` (nmcli +
avahi-browse) en un `Thread`, publica `{_nets,_hosts,_status,_version}` bajo
`Mutex` y `poll()` (`shell.gd:496`) sólo copia; la vista consume esa copia. El
feature de pantalla debe reusar ese patrón para `gvd caps`, la sesión y el
publicador, y **no** añadir consultas nuevas al frame.

### 0.1 Inventario: llamadas actuales que no pueden entrar en `_draw`/`draw()`/`refresh()`

| # | Llamada | Dónde corre hoy | Violación | Destino |
|---|---|---|---|---|
| 1 | `_service_running()` → `kill -0` (`shell.gd:2420`) y `pgrep` (`shell.gd:2440`) | dentro del dibujo: `_draw_home` (`shell.gd:1712`) y `_activity_state` (`shell.gd:2162`) | **bloqueo dentro de `draw()`** (la más grave) | cachear bool con TTL en worker; el dibujo lee el snapshot |
| 2 | `_toggle_service()` → `OS.execute("sh", [cmd + " & echo $!"], true, out)` (`shell.gd:2410`) | `_activate` (`shell.gd:2387`) desde click ImGui/ring | lanzamiento bloqueante en el frame | lanzar async o en worker; estado por snapshot |
| 3 | `_wifi_radio_on()` → `OS.execute("nmcli", ["radio","wifi","on"])` (`shell.gd:2652`) | botón en `neighborhood_ui.refresh` (`neighborhood_ui.gd:58`) | bloquea el frame en el click | worker + snapshot |
| 4 | `applet_bluetooth.refresh()` → `bluetoothctl show` con timeout 2 s (`applet_bluetooth.gd:38`) | `frame._process` cada 5 s (`frame.gd:683`) | main thread hasta 2 s | worker + caché TTL |
| 5 | `applet_keyboard.refresh()` → `localectl status` (`applet_keyboard.gd:147-149`) | `frame._process` (`frame.gd:685`) | main thread hasta 2 s | worker + caché TTL |
| 6 | `neighborhood_publish.detect_avahi()` → `sh -c command -v avahi-publish-service` (`neighborhood_publish.gd:18`) | aún no cableado | bloquearía si se llama en refresh | resolver el binario una vez fuera del frame |
| 7 | `apps.scan()` (`apps.gd:53`) | perezoso dentro de `_draw_home`/`_draw_apps` (`shell.gd:1822,1841,2261`) y `frame._process` (`frame.gd:286`) | escaneo recursivo de `*.desktop` en draw (una vez) | worker + caché; dibujar "cargando apps" |
| 8 | `apps._load_icon()` / `Image.load` (`apps.gd:288-289`, `shell.gd:2309`) | `_draw_apps` | rasteriza disco en draw | caché de texturas con TTL |
| 9 | `_sugar_svg_text` + raster SVG (`shell.gd:2133-2129,2102-2115`) | draw de íconos Sugar | lee disco y rasteriza en draw | caché por (nombre, color), fuera del frame |
| 10 | `neighborhood_ui._make_icon` / `Image.load` (`neighborhood_ui.gd:249-274`) | `neighborhood_ui.refresh` (`shell.gd:534`) | recrea y carga SVG en cada refresh | cachear texturas por (nombre, tamaño) |
| 11 | `neighborhood_ui._local_context()` → `File.file_exists` de candidatos gvd (`neighborhood_ui.gd:179-181`) | refresh | I/O de disco en render | resolver la ruta en worker/cache |
| 12 | `neighborhood_ui.refresh()` → `relax_capsules` O(N²·48) (`neighborhood_ui.gd:67`) | `_imgui_frame` (`shell.gd:534`) | acotado pero crece con N redes | limitar N o precalcular en worker |
| 13 | `_proc_name`/`_ppid` leen `/proc` (`shell.gd:3171-3187`) | callback del portal `_on_input_access` | barato, hoy aceptable | worker si crece |
| 14 | `sysmon.tick()` lee `/proc/stat`,`/proc/meminfo` (`sysmon.gd:33,47`) | `frame._process` | barato | mantener acotado |

Correcto y a preservar: `neighborhood._scan` (`neighborhood.gd:123`) sólo corre en
el `Thread` (`_work`, `neighborhood.gd:104`); `remote.gd:98` usa
`OS.execute(..., false)` (no bloqueante).

Backlog de desbloqueo por severidad: (1) sacar `_service_running` del dibujo;
(2) `_toggle_service` y `_wifi_radio_on` sin bloqueo; (3) workers/caché para los
applets bluetooth y keyboard; (4) caché de íconos; (5) `apps.scan` fuera del frame.
Cada punto es un cambio acotado y testeable, sin tocar los modelos puros.

## 1. Principio: la dirección es un acuerdo, no una capacidad

`mDNS` descubre equipos y capacidades; un servicio anunciado **no** expresa dónde
está físicamente el vecino. La dirección Norte/Sur/Este/Oeste es una relación
entre dos hosts, relativa a quien la declara, y por eso:

- **no va en TXT**: cada host publica sus capacidades, no la posición de terceros;
- **vive local**: `~/.config/gdtk/neighborhood-directions.json`, por `hid`;
- **se confirma por canal autorizado** (ssh o control JSON-RPC de `shell/remote.gd`),
  nunca por mDNS;
- sin confirmar, la dirección es sólo una pista visual y se muestra como tal.

Regla de perspectiva única para no confundir marcos: **toda dirección se guarda
tal como la ve este equipo**. "Tengu al Este de mí" significa que el ícono de
Tengu va a la derecha de mi pantalla; el inverso (yo al Oeste de Tengu) se deriva
con `inverse()`, no se guarda en dos lugares.

`inverse`: `north↔south`, `east↔west`, `none→none`.

## 2. Modelo de hosts (mDNS)

Se reutiliza tal cual el modelo de `shell/neighborhood_hosts.gd`: agrupación por
`hid`, estados `visto/guardado/conectado/perdido`, `degraded` sin `hid`.

Capacidades relevantes para esta SPEC:

| Servicio | TXT que habilita la brújula |
|---|---|
| `_gdtk-gvd._udp` | `role=recv` + `state=ready\|capable` + `cursor_port` |
| `_gdtk-deskflow._tcp` | `role=server\|client`, `clip=0\|1`, `tls=required`, `screen=edge` |

Se añade **una sola** clave TXT opcional, informativa y no secreta:

```text
layout=1        # acepto proponer/confirmar dirección de borde por canal autorizado
```

`layout` ausente equivale a `0`: el vecino funciona, pero la dirección queda
local y sin confirmar. No se anuncia nunca la dirección en sí.

## 3. El compás: Norte / Sur / Este / Oeste

Control en el objeto host del Vecindario: cuatro zonas alrededor del ícono
(estilo organizador de pantallas de Deskflow, pero cardinal en vez de grilla).
Un host tiene **una** dirección primaria hacia este equipo.

| Brújula (mi vista) | `gvd --position` | DeskFlow (yo servidor) |
|---|---|---|
| Norte | `above` | peer arriba de mi pantalla |
| Sur | `below` | peer abajo |
| Este | `right` | peer a la derecha |
| Oeste | `left` | peer a la izquierda |

- La grilla multi-pantalla fina de Deskflow queda **fuera de alcance**: el shell
  ordena en una fila, y cuatro bordes cubren extend y links 1:1.
- Una dirección por vínculo. Si dos hosts reclaman el mismo borde, la UI marca
  **conflicto de borde** y no genera config de Deskflow hasta resolver.
- Calibración opcional: para Deskflow (que sí mueve input) el usuario prueba
  cruzando el borde y confirma; para gvd la dirección es sólo colocación visual
  y no necesita prueba de cruce.

## 4. Extender vs duplicar (extend vs mirror)

Distinción central y hoy mal nombrada por "Compartir mi pantalla":

| | Extend (extender) | Mirror (duplicar) |
|---|---|---|
| Semántica | espacio **adicional**; no duplica | **misma** imagen en ambos |
| gvd | **soportado**: `send` crea un monitor virtual `Meta-*` y lo ancla con `--position` | **no soportado**: `send` captura el monitor virtual, no una salida real |
| Privacidad | baja: sólo lo que el usuario arrastre a esa pantalla | alta: todo lo visible en la salida espejada |
| Input | no atraviesa (gvd `recv` no reenvía input) | igual |
| Fase | MVP | tardía o no ofrecer; exige consentimiento explícito |

Consecuencia honesta: la acción actual **"Compartir mi pantalla"** debe renombrarse
**"Extender mi escritorio a <host>"**; gvd no espeja el escritorio real. `mirror`
queda reservado y jamás se ofrece por defecto.

"Vista dedicada" y "pantalla compartida" describen el mismo stream desde dos
lados: en el **receptor** es una superficie a pantalla completa (vista dedicada,
como `recv --sink wayland` hoy); en el **emisor** es un monitor extra del span
(pantalla compartida), cuya arista determina la dirección y el arrastre de
ventanas. No son dos modos distintos del cable.

## 5. Acciones por host

`gvd` (sólo si `role=recv`):

- **Extender mi escritorio a <host>** (`send --host <peer> --position <dir>`);
- **Recibir pantalla aquí** (`recv --sink wayland`, actividad "Pantalla");
- **Mirror** — no ofrecer.

DeskFlow (si hay capacidad):

- **Compartir teclado y mouse** (cliente local → servidor remoto);
- **Usar mi teclado y mouse aquí** (servidor local, si `deskflow_server`);
- **Compartir portapapeles** — subtoggle sólo si `clip=1` y la sesión está
  activa; nunca implícito ni automático.

Portapapeles nativo (`_gdtk-clip._tcp`) sigue reservado y no se implementa.

## 6. Cómo DeskFlow usa la dirección

Deskflow es el caso donde la dirección **tiene efecto real de input**:

- Si **este equipo es el servidor**, la dirección define los `links` del layout:
  el peer se coloca en la arista indicada y el cursor cruza hacia él al tocar el
  borde. Se genera config explícita y reversible, p. ej. peer al Este:
  `local: right = peer` y `peer: left = local`.
- Si **el peer es el servidor**, no se puede imponer la dirección: se **propone**
  por el canal autorizado (`layout=1`) y la UI indica "confirmado por el par" o
  "propuesta pendiente".
- Cliente Deskflow local (`use_remote_input`) usa el layout del servidor remoto;
  el compás local sólo alimenta la pista visual y la propuesta.
- Reutilizar `_toggle_service()`, `_service_running()` y `service_pids` con la
  actividad "Deskflow"; la config se regenera de forma determinista antes del
  toggle y es borrable. No crear un segundo ciclo de vida.
- El portapapeles viaja por el mismo vínculo pero es permiso aparte (`clip`).

## 7. Cómo gvd usa la dirección

- `send --position` toma la dirección del compás (Norte→`above`, etc.). `right`
  es el default de Mutter y `left/above/below` re-anclan el layout del emisor
  (`move_virtual()` en `gvd.py`).
- El receptor **no necesita la dirección** para decodificar: sólo muestra el
  stream. La dirección sirve al emisor para ampliar el span y a la UI para
  dibujar el mapa mental.
- **Vista dedicada** (receptor gdtk): `recv --sink wayland` como cliente Wayland
  fullscreen dentro del compositor, sin input cruzando.
- **Pantalla compartida** (emisor): el monitor virtual aparece como salida extra
  en la dirección elegida; arrastrar una ventana hacia esa arista la envía al
  vecino. Cursor separado sigue por `port+1` (`cursor=separate`), pero es cursor
  *del propio escritorio del emisor*, no input remoto.
- Ruta de `gvd.py`: `resolve_gvd_path()` (`~/Proyectos/gvd` desarrollo, `~/gvd`,
  PATH). Stream sin cifrar ni autenticar: sólo LAN de confianza o VPN.

## 8. Flujos

- **Push desde el emisor (MVP):** A elige B y la dirección; A abre el receptor de
  B por canal autorizado (`ssh` o JSON-RPC) y lanza `send --position`; al detener,
  SIGTERM a `send` y cierre del `recv` remoto.
- **Pull desde el receptor:** B lanza `recv` local; A elige B y extiende. No hay
  descubrimiento de emisor sin canal: `role=send` sigue reservado.
- **Input (Deskflow):** el servidor aplica el layout; el cliente conecta; el
  portapapeles es subtoggle.

## 9. Permisos y confirmación en ambos hosts

| Acción | Emisor / servidor | Receptor / cliente |
|---|---|---|
| gvd extend | confirma que crea y expone un **monitor virtual** (no la pantalla física) y a qué host | recv abierto por el dueño o por canal autorizado; sin canal, `state=capable` no habilita |
| gvd recv local | — | acción explícita "Recibir pantalla aquí" |
| Deskflow input | servidor acepta clientes (`role=server`) | cliente conecta; puede requerir aprobación de acceso (`remote_input.access_requested`) |
| Portapapeles | permiso separado (`clip=1`) | subtoggle explícito, nunca automático |

Nunca autoconectar input ni portapapeles. La pantalla es menos sensible (monitor
virtual) pero sigue siendo acción explícita y revocable. mDNS descubre; no autoriza.

## 10. Estados UI

Host (ya definidos): `visto`, `guardado`, `perdido`, `degradado`.

Vínculo/pantalla, por dirección:

- `sin dirección`: no hay compás; se ofrece calcular o extender al borde default
  con aviso;
- `propuesta`: dirección enviada al par, esperando confirmación;
- `confirmada`: ambos lados coinciden; extender y links Deskflow habilitados;
- `activa`: sesión viva (gvd o Deskflow), revocable desde el mismo menú;
- `detenida`: sesión terminada limpiamente;
- `conflicto`: dos hosts en el mismo borde o dirección contradictoria.

Acciones: `disponible`, `pendiente`, `activo`, `falló`, `no confiable` (reusa la
SPEC de host-actions). La brújula es un control del objeto host con badges de
pantalla, entrada y portapapeles.

## 11. Errores y recuperación

| Error | Detección | Recuperación |
|---|---|---|
| peer sin `_gdtk-gvd` | modelo sin capacidad | no ofrecer extender; reintentar discovery |
| peer `state=capable` | TXT | pedir abrir recv por canal autorizado; si no hay, deshabilitar |
| A sin emisor | `gvd_sender=false` | "Extender" deshabilitado, no ocultar |
| ruta gvd inválida | `resolve_gvd_path` | re-resolver; mostrar candidatos |
| sin frames RTP | timeout en receptor | cortar, avisar, reintentar (keyframe a pedido es futuro) |
| dirección sin confirmar | sin eco del par | permitir extender con aviso; bloquear solo links Deskflow |
| conflicto de borde | dos direcciones iguales | no generar config; pedir resolver |
| auth ssh/token | código de salida | mostrar error traducido; reintentar o cancelar |
| Deskflow TLS/rol | config vs anuncio | no publicar servicio si no coincide; corregir config |
| sin avahi | `detect_avahi` degradado | Vecindario sigue con Wi-Fi y hosts degradados |

Toda sesión activa debe verse y poder cortarse desde Vecindario. No guardar
secretos en Diario ni logs; no pasar credenciales por argumentos.

## 12. Persistencia

`~/.config/gdtk/neighborhood-directions.json`, separado de
`neighborhood-hosts.json`:

```json
{
  "b6f4e13b8a2f4d88": {
    "direction": "east",
    "confirm": "confirmed",
    "mode": "extend",
    "link": "deskflow+gvd",
    "updated": 1759270000
  }
}
```

`confirm`: `unconfirmed|proposed|confirmed`. `mode`: `extend` (default);
`mirror` reservado y no persistible en este corte. Sin secretos.

## 13. No-goals

- No mirror de escritorio real.
- No grilla multi-monitor; sólo cuatro bordes.
- No emisor gdtk (fase tardía); gdtk hoy recibe y organiza.
- No portapapeles nativo ni `_gdtk-clip`.
- No dirección en TXT ni descubrimiento de emisor sin canal autorizado.

## 14. Contrato duro: el hilo de render/UI nunca se bloquea

Regla no negociable y común a todo gdtk (Frame, applets, Vecindario, compás,
orquestación de sesiones): el hilo que dibuja —`shell.gd` (`_process`, `_input`,
`imgui_frame`), `frame.gd` (`_process`, `draw`), `neighborhood_ui.gd` (`refresh`,
`_draw`)— **no ejecuta trabajo con latencia ni I/O de duración variable**. Toda
operación así corre fuera del hilo de UI (worker/sesión dedicada) y la UI sólo
consume un **snapshot** ya calculado, o el último snapshot válido sujeto a **TTL**.

Alcance explícito del trabajo que **debe** ir por worker/cache/snapshot/TTL:

| Trabajo | Ejemplos | Camino permitido |
|---|---|---|
| Discovery mDNS | `avahi-browse -rtp`, `avahi-publish-service`, `detect_avahi()` | worker + snapshot versionado |
| gvd | `caps --json`, `send`, `recv`, resolución de ruta y orquestación | worker/session manager + snapshot |
| Control remoto | ssh, JSON-RPC de `shell/remote.gd`, handshake de dirección | worker + snapshot |
| Deskflow | toggle, `pgrep`, `kill -0`, config server/cliente, TLS/rol | worker + snapshot |
| Red / Bluetooth | `nmcli`, `bluetoothctl` | worker/adaptador con TTL |
| Sensores y procesos | `/sys`, `/proc`, `pgrep`, `kill` | worker con TTL |
| Archivos | lectura pesada de `/proc`, escaneo `.desktop`/íconos, JSONs locales | worker/cache |

Reglas vinculantes:

- **Prohibido** `OS.execute(..., true)` (con captura) y cualquier `OS.execute` de un
  binario externo desde el hilo de UI. `OS.execute(..., false)` (lanzar y olvidar)
  sólo vale para abrir apps/toplevels, nunca para consultar estado.
- La UI no llama en el draw a `_service_running()`, `_service_processes()`,
  `_toggle_service()`, `detect_avahi()` ni equivalentes: lee snapshots.
- Ningún `File.file_exists`/lectura de archivo en bucle dentro del dibujo (hosts,
  íconos, apps): cache con TTL o snapshot.
- Snapshot = diccionario inmutable con `version`/`updated`/`state`/`error`; la UI
  compara versión y sólo pide `request_redraw()` si cambió. Nunca `Thread.wait` en el
  frame: copia bajo `Mutex` como ya hace `neighborhood.gd`.
- TTL explícito por dato; al vencer → `sin_dato`/`degradado`, nunca un valor viejo
  presentado como fresco ni una espera bloqueante.
- Timeout corto en todo subproceso (patrón `timeout` de los `applet_*.gd`), pero el
  timeout no legitima la llamada: si hace falta, es que corría en el hilo equivocado.
- El trabajo con secreto (ssh, token, JSON-RPC) corre en el worker; el snapshot no
  lleva credenciales y la UI nunca las ve.

Modelo de referencia ya correcto en el repo: `shell/neighborhood.gd` (hilo + `Mutex`
+ `version`), `neighborhood_hosts.gd` y `neighborhood_actions.gd` (puros, sin I/O),
`neighborhood_actions.gd` sólo describe `send`/`recv`/Deskflow como *plan* sin
ejecutarlos, y `applet_keyboard.gd:choose()` escribe de forma atómica.

### 14.1 Puntos bloqueantes detectados (auditoría de código, 2026-09-30)

| # | Archivo:línea · función | Qué bloquea | Severidad |
|---|---|---|---|
| B1 | `shell/shell.gd:2393` `_toggle_service()` | `OS.execute("sh", [... "& echo $!"], true)` en el clic del servicio | alta |
| B2 | `shell/shell.gd:2419` `_service_running()` | `kill -0` por `sh` + `pgrep` síncronos; lo llaman UI y `_from_service` | alta |
| B3 | `shell/shell.gd:2430` `_service_processes()` | `pgrep -u … -f -x` síncrono | alta |
| B4 | `shell/shell.gd:3160/3171/3181` `_from_service()` · `_ppid()` · `_proc_name()` | camina hasta 32 `/proc/<pid>/stat` + `_service_running` por nivel desde el portal de input | alta |
| B5 | `shell/shell.gd:2651` `_wifi_radio_on()` | `OS.execute("nmcli", ["radio","wifi","on"])` síncrono desde botón | media |
| B6 | `shell/applet_keyboard.gd:141` `_localectl_layout()` (vía `refresh()` en `frame.gd:685 _process`) | `localectl status` con `timeout 2` en el hilo de UI cada ~5 s | media |
| B7 | `shell/applet_bluetooth.gd:38,103` `refresh()` · `toggle_power()` | `bluetoothctl show`/`power` con `timeout 2` síncronos (al cablearse al Frame) | media |
| B8 | `shell/sysmon.gd:27` `tick()` | lee `/proc/stat` y `/proc/meminfo` en `frame.gd:_process` (1 Hz) | baja |
| B9 | `shell/shell.gd:2260/2283` `_activity_tex()` · `_window_icon()` · `_sugar_icon_for()` + `frame.gd:286 _pinned_app()` | `apps.scan()` (recorrido recursivo de `.desktop`) y lecturas de archivo dentro del draw | media |
| B10 | `shell/neighborhood_ui.gd:169,207` `_local_context()` · `_host_icon()` | `File.file_exists` en bucle dentro de `refresh()` (UI) | baja |
| B11 | `shell/neighborhood_publish.gd:16` `detect_avahi()` | `OS.execute("sh", ["-c","command -v avahi-publish-service"], true)` síncrono | media |

Notas: `applet_bluetooth.gd` aún no está en `frame.gd:APPLETS`, pero cae en este
contrato al integrarse. `neighborhood_ui.gd:_run_host_action()` hoy sólo imprime el
plan (correcto); al ejecutarlo de verdad debe hacerlo por worker vía snapshot.

### 14.2 Subagentes Kilo sugeridos (corrección posterior, fuera de este corte)

Reglas de `AGENTS.md`: un `kilo run` por vez, `--agent code` para cambios acotados,
`--agent ask` para mapeo, `-m kilo/deepseek/deepseek-v4.1-flash`, write set
explícito, sin commit, sin deploy, sin tocar sesión ni el motor.

- **Kilo W1 — servicio Deskflow no bloqueante.** `shell/shell.gd`: mover
  `_toggle_service`/`_service_running`/`_service_processes` a worker con snapshot
  `{state, pid, err, updated}`; la UI sólo lee el snapshot. Cubre B1–B3.
- **Kilo W2 — permiso de input sin `/proc` en el portal.** `shell/shell.gd`
  `_on_input_access`/`_from_service`/`_ppid`/`_proc_name`: resolver PPIDs y árbol de
  servicios en worker/cache. Cubre B4.
- **Kilo W3 — snapshots de applets.** `shell/applet_keyboard.gd`,
  `shell/applet_bluetooth.gd`, `shell/sysmon.gd`: `refresh()`/`tick()` dejan de llamar
  `OS.execute`/leer `/proc` en el hilo de UI (worker + TTL + último valor). Cubre
  B6–B8.
- **Kilo W4 — catálogo de apps/íconos cacheado.** `shell/apps.gd` + `shell/shell.gd`
  `_activity_tex`/`_window_icon`/`_sugar_icon_for` + `frame.gd:286`: escanear y cargar
  en worker/cache; el draw sólo usa lo ya cargado. Cubre B9.
- **Kilo W5 — publisher y gvd.** `shell/neighborhood_publish.gd` `detect_avahi` y el
  futuro `gvd caps --json`/ssh/JSON-RPC: adaptador con worker/snapshot; la UI nunca
  consulta binarios ni abre canal. Cubre B5 y B11, y prepara la orquestación de §7/§8.

## 15. Tareas delegables a subagentes

Reglas comunes (AGENTS.md): un `kilo run` por vez, `--agent code` para cambios
acotados y `--agent ask` para mapeo, `-m kilo/deepseek/deepseek-v4.1-flash`,
write set explícito, sin commit, sin deploy, sin revertir cambios ajenos, sin
tocar sesión ni el motor.

- **Kilo A — modelo de compás (puro).** `shell/neighborhood_directions.gd`:
  parseo/serialización JSON, `inverse()`, validación de enum, fusión con overrides.
  Test `tests/neighborhood_directions_test.gd` con inversa y conflicto de borde.
- **Kilo B — TXT `layout=1`.** Extender `build_gvd_txt`/`build_deskflow_txt` en
  `shell/neighborhood_publish.gd` y sus tests; sin secretos, respetando límites
  de bytes.
- **Kilo C — planes de acción con dirección.** `shell/neighborhood_actions.gd`:
  mapear dirección→`--position`, habilitar/serializar config Deskflow, marcar
  "no confiable"/"conflicto". Test `tests/neighborhood_actions_test.gd`.
- **Kilo D — generador de links Deskflow.** Función pura en
  `shell/deskflow_layout.gd` que produce config server / cliente desde el compás,
  determinista y reversible; test propio.
- **Kilo E — UI del compás.** `shell/neighborhood_ui.gd`: cuatro zonas por host,
  estados `sin dirección/propuesta/confirmada/conflicto`, badges; test de estado
  en `tests/neighborhood_ui_test.gd`.
- **Kilo F — sesión gvd extend.** Orquestación (lanzar `recv` remoto por canal
  autorizado + `send` local, reflejar estado, cortar) reusando el ciclo de vida;
  sin duplicar `_toggle_service()`.
- **Kilo G — handshake de dirección.** Proponer/aceptar por ssh o control
  JSON-RPC en `shell/neighborhood_handshake.gd`; test puro con respuestas simuladas.
- **Kilo R — desbloquear el hilo de render.** Sin features nuevas: mover
  `_service_running` a caché con TTL, lanzar `_toggle_service`/`_wifi_radio_on` sin
  bloquear, y encolar applets/íconos/`apps.scan` en workers; tests puros donde
  aplique (estado cacheado, sin ejecutar procesos reales). Es requisito previo a
  conectar las acciones de pantalla.

## 16. Criterios de aceptación

- El compás por host expone N/S/E/O y se mapea a `gvd --position` correctamente.
- Extender sólo se ofrece si el peer anuncia `role=recv`; `mirror` nunca.
- La dirección no aparece en TXT ni en mDNS, sólo local + canal autorizado.
- Con dirección sin confirmar, la pista visual aparece y Deskflow queda bloqueado.
- Con conflicto de borde, no se genera config de Deskflow y la UI lo explica.
- Si Deskflow es el servidor remoto, la dirección se propone, no se impone.
- Toda sesión activa (gvd o Deskflow) se corta desde el mismo host.
- Sin avahi, el Vecindario sigue mostrando Wi-Fi y hosts en estado degradado.
- El hilo de render no ejecuta procesos ni consultas: `_draw`/`draw()`/`refresh()`
  y `_process()` sólo leen snapshots cacheados (§0).
- Ninguna operación de discovery, gvd, control remoto, Deskflow, red, Bluetooth,
  sensores o archivos se ejecuta en el hilo de render/UI: la UI sólo consume
  snapshots con TTL (§14).

## 17. Referencias

- `SPEC-sugar-neighborhood-host-actions.md`
- `SPEC-sugar-spatial.md`, `SPEC-sugar-journal-neighborhood.md`
- `SPEC-sugar-frame-applets.md` (§ Muestreo, coste y fallos: mismo contrato §14)
- `shell/neighborhood_hosts.gd`, `shell/neighborhood_actions.gd`,
  `shell/neighborhood_publish.gd`, `shell/neighborhood_ui.gd`, `shell/remote.gd`,
  `shell/shell.gd` (`_toggle_service`, `_service_running`, `apps.scan`),
  `shell/frame.gd` (`_process`), `shell/sysmon.gd`, `shell/applet_keyboard.gd`,
  `shell/applet_bluetooth.gd`, `shell/apps.gd`
- `~/Proyectos/gvd/README.md`, `~/Proyectos/gvd/DESIGN.md`,
  `~/Proyectos/gvd/SPEC-gvd-2-results.md`, `~/Proyectos/gvd/gvd.py`
- Deskflow: <https://github.com/deskflow/deskflow>
