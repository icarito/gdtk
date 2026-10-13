# Sesión /polish 2026-10-11 — DPI Deskflow, barrera de apagados, grilla de apps

Modo despachador no disponible (sin listener Kilo :4096 ni `KILO_SERVER_PASSWORD`):
se implementó directo en el repo. **Nada sincronizado a `~/gdtk` ni recargado** (no
se pidió; el shell principal aloja VS Code/Kilo). Cambios sólo en el repo.

## Items de la tanda

### A — Velocidad del puntero (DPI) en clientes Deskflow
Pregunta: en pantallas chicas de alta resolución (Cupid, Redmi) el mouse se siente lento.
Hecho: **Deskflow 1.27 no tiene velocidad por cliente**. Lo único es la env var
`DESKFLOW_MOUSE_ADJUSTMENT=<double>` que lee el proceso **servidor** (global, afecta a
todos los clientes) + `xScrollScale`/`yScrollScale` por cliente para el scroll
(upstream: issues #8207, PR #9434 `CursorMovementScale`, todavía fuera de 1.27).
Decisión del usuario: multiplicador global por env.

- `settings/settings_model.gd`: `CONTROL_DEFAULT.mouse_scale = 1.0`; `deskflow()` lo
  clampea 0.1..10.0 (helper nuevo `num_value`).
- `shell/deskflow_mouse.gd` (nuevo, `Host.sc`): `adjust_text(scale)` (texto clampeado, con
  `.0` para que `String(1.0)` no salga "1") + selftest. **No** va en `deskflow_settings.gd`
  porque ese es `const preload` y no sobrevive al soft reload.
- `shell/shell.gd` `_apply_deskflow_settings`: `OS.set_environment("DESKFLOW_MOUSE_ADJUSTMENT",
  ...)` y el valor entra en `key` (`|ms=...`) ⇒ un cambio relanza Deskflow con el valor nuevo.
- `settings/pages/displays.gd`: slider "Multiplicador" 0.5..3.0 (escribe
  `settings["deskflow"].mouse_scale` vía `host.set_field`; persiste con Aplicar).
  **Ubicación a confirmar** con el usuario (la pusimos en Pantallas; podría ir a otro lado).

### B — Bloquear la barrera de hosts Deskflow apagados
Mecanismo ya existente: `_deskflow_capture_ranges()` (`shell.gd`) → `set_capture_ranges`
del portal InputCapture (EIS). Una dirección "disabled" queda 0..0 y el borde **no
captura**, así Deskflow no rapta el puntero hacia un equipo apagado. Antes `disabled`
sólo lo llenaban las sesiones gvd.

- Nuevo puro `shell/deskflow_presence.gd` (`absent_directions(layout, present_ids)`):
  direcciones de los contactos directos de la local cuyo `id` (hid) no está visto.
  Una pantalla por dirección (id menor), igual que `SCREEN_LAYOUT.local_links`.
  Sólo mira `settings["screens"]` (vecinos gdtk); los extremos externos
  (`deskflow_extra`, teléfonos) no pasan por acá y **nunca** se auto-bloquean.
- `shell/shell.gd`: `_deskflow_absent_directions()` (presentes = hosts `state=="visto"`,
  por `id`/`hid`); `_deskflow_capture_ranges` las suma a `disabled`;
  `_apply_capture_ranges` ahora **deduplica** (`_df_cap_ranges`) y sólo publica si cambió;
  se llama en cada cambio de `neighborhood.version` (`_nb_seen` evita bloquear antes del
  primer escaneo). Al reaparecer el vecino, el borde se reabre solo (sin reiniciar Deskflow).
- Test `tests/deskflow_presence_test.gd` (8 ok).

### C — Grilla de apps del Hogar (`apps_view`)- **C1 bloque proporcional** (`shell/apps.gd` draw): el bloque pasa de `ICON=64` fijo a
  `block = side - gap` (proporcional a la celda), con ícono/label/escala derivados. Antes
  la celda escalaba con la pantalla y el bloque no.
- **C2 sin costados en teléfono/chico** (`shell/shell.gd` `_draw_apps` + `_apps_margin`):
  margen = 0 en Android o `min(vp) < 700`; una celda en escritorio.
- **C3 feedback háptico** (`shell/frame.gd` `_touch_to_mouse`): `_haptic(40)` al entrar en
  modo 2 (mantener+arrastrar = "mover bloque") para distinguirlo del scroll (modo 1).
  Android: `Input.vibrate_handheld`; escritorio no-op.
- **C4 scroll de touchpad** (`shell/frame.gd`): el canvas ImGui del motor sólo scrollea
  con `BUTTON_WHEEL_*`, **no** entiende `InputEventPanGesture` (el scroll de dos dedos
  del touchpad). Por eso en desktop la grilla no scrolleaba (en Android el toque ya
  sintetiza rueda). Fix: con `shell.apps_view`, un `PanGesture` se traduce a rueda
  (`_pan_to_wheel`/`_emit_wheel`) y se consume. Pendiente confirmar el signo del delta
  contra el ajuste "Desplazamiento natural".

## Tanda 2026-10-12/13 — resolución al rotar, kind de tablet, fantasma en Grupo
Nuevos items y hallazgos (raíz):

**#2 Cupid debía verse tablet** — CAUSA: `_read_sysfs_line` usaba `File.get_as_text()`,
que devuelve "" en archivos de sysfs/procfs (st_size=0) aunque `open()` dé OK; el DMI se
leía vacío y `device_kind.detect` caía a la heurística de batería → "laptop". FIX: usar
`get_line()` (shell/_read_sysfs_line). Verificado: Cupid anuncia `kind=tablet`.
Regresión: `tests/sysfs_line_test.gd`.

**#1 Resolución Deskflow al rotar (portrait<->landscape)** — dos causas:
- Emisor: `_screen_size()` devolvía `screen_size` (var) que quedaba viejo. Con span
  desactivado `_span_tick` salía temprano y nunca lo limpiaba; al rotar NO se republicaba
  el `res=`. FIX: `_span_tick` limpia `screen_size` a ZERO cuando el span está apagado
  (vuelve a seguir el viewport en vivo). Verificado: Cupid republica `res=2160x1440`.
- Observador: aplicaba el `res` del peer recién en el rescan del Vecindario
  (`neighborhood.RESCAN_MS = 60 s`). Verificado: Bastion aplica a ~28 s. FIX: nuevo
  método peer `screen_res` (peer_link/peer_control) + el emisor avisa al Grupo en
  `_screens_resolution_tick` al detectar el cambio (`_peer_send_async(_group_targets(),
  "screen_res", {w,h})`) + handler `shell._peer_screen_res`. Latencia baja a ~1 frame,
  pero **requiere que el observador (Bastion) recargue** para tener el handler.
- Redmi (Android): no anuncia `res=` en su TXT (su gdtk parece viejo / NDA). Pendiente.

**#3 ID desconocido en el Grupo que no se deja quitar** — son pantallas "fantasma"
keyed por el hid (label==hid) que duplican a un vecino ya nombrado: Bastion tiene
`aa033bda2a7c6092` (tengu) junto a `tengu`; Tengu tiene `a1c509df21cec49a` (bastion)
junto a `bastion`. Se creaban cuando el host no estaba en el Vecindario
(`_peer_name_for` devolvía el hid). FIX: (a) `_screen_layout_host` no crea pantalla si el
nombre no es resoluble; (b) `_screens_resolution_tick` dropea la fantasma cuando el host
está visto y existe la pantalla con el nombre real. Requiere recarga.

**#4 Propagar el layout entre los hosts del Grupo** — no implementado. Hoy cada host
tiene su `settings["screens"]` local; no hay DTO canónico ni push. El `screen_res` es la
primera pieza (resolución). Falta un `layout_*` peer con posiciones/direcciones.

**BLOQUEANTE AJENO**: `shell/shell.gd:2092` llama `_multiview_draw()` (WIP multiview,
`multiview_on`) que no está definido en ninguna parte → `shell.gd` no compila (parse
error). Impide recargar/deployar. No se tocó (trabajo en curso del usuario).

## Verificación de esta tanda
- `sysfs_line_test` (nuevo), `device_kind_test`, `screen_layout_test`, `peer_control_test`
  (con casos `screen_res`), `peer_link_test`, `neighborhood_actions_test` — ok.
- Compilación de la copia de shell.gd sin la llamada WIP: OK (mis ediciones compilan).
- `gvd_launch_test` falla por el WIP multiview (ajeno; antes pasaba).
- En vivo: Cupid `kind=tablet`; res republica al rotar; Bastion aplica el `res` del peer
  (por mDNS ≤60 s). Deploy a cupid/tengu hecho para device_kind/span/screen_res.

**#4 Propagar el layout entre los hosts del Grupo** — IMPLEMENTADO.
- peer_link: método `layout` + validador `layout_screens` (átomos seguros, números
  acotados, ≤24 pantallas).
- peer_control: handler `layout` → `shell._peer_layout(hid, screens)`.
- shell: `_peer_layout` upserta la geometría (x/y/w/h/px) de los vecinos por id o por
  nombre, sin tocar la local ni re-difundir; `_maybe_broadcast_layout()` difunde el
  layout local (una vez por cambio, firma `_layout_sent_sig`) y se llama tras un cambio
  local (editor `_apply_settings`, colocación `_write_screen_layout`, drag `_layout_drag_release`).
- **Bug propio corregido**: `SCREEN_LAYOUT.screen_by_id()` normaliza y devuelve un dict de
  OTRA copia; mutar ese `target` no cambiaba el `lay` que se guardaba. Ahora busca el
  target dentro de `lay.screens`.
- Verificado en vivo: un `layout` de Cupid→Bastion cambió `x` de redmi y se restauró.

Verificado live (2026-10-13): Bastion screens `['tengu','cupid','redmi']` (fantasma
`aa033bda2a7c6092` eliminada); Tengu `['bastion']` (fantasma `a1c509df21cec49a`
eliminada); Cupid `kind=tablet res=1440x2160`; sin "recarga fallida" en Bastion. Tests
`peer_control_test` (layout/screen_res), `peer_link_test`, `screen_layout_test`,
`gvd_launch_test`, `neighborhood_actions_test`, `device_kind_test`, `sysfs_line_test`,
`deskflow_conf_test` — 0 FAIL.

## Redmi (Android) actualizado 2026-10-13
Acceso por `adb` (device `456afc8d`, Redmi Note 9 Pro, Android 14). El APK que corría
(`org.gdtk.shell`) era viejo: su `_android_publish` NO seteaba `identity["res"]` ni
tenía `_local_size_text`/`_screens_resolution_tick`, así que Redmi no publicaba su
resolución y no se le podía propagar nada.

Fix operativo (sin tooling de export Android en el repo): se parcheó el APK —
`assets/*.gd` reemplazados por los del repo (`shell/*.gd`, 83), re-firmado con el
`~/.android/debug.keystore` (el APK ya era debug; SHA-256 coincide: 9c50aebc…) y
`adb install -r`. Backup del APK original en `/tmp/kilo/redmi.apk`.
Verificado: logcat sin `Parse Error`/`SCRIPT ERROR`; Redmi anuncia ahora
`res=1080x2400 kind=mobile`; Bastion lo lee (`deskflow.txt.res=1080x2400`).
Procedimiento reproducible: stage de `shell/*.gd` en `assets/`, `zip` sobre el APK
(sin tocar `resources.arsc`), `zipalign -f 4`, `apksigner sign` (debug key),
`adb install -r`. Nota: el APK embebe `assets/project.binary`; se dejó intacto (los
autoloads `Host`/`DebugHud` no cambiaron). Si se cambia el proyecto o el engine, hay
que reconstruir el APK, no parchear.

## Redmi: franja derecha del mouse — límite del cliente Deskflow Android (2026-10-13)
Tras estabilizar el layout, el cursor cubre casi toda la pantalla salvo una franja derecha.
Medido con adb: display `2400x1080` (landscape, cutout a la IZQUIERDA 102px), área de app
= `2166x1080` (`nonDecorFrame=[102,0][2268,1080]`); a la derecha el sistema reserva
`2268..2400` (132px) como `mandatorySystemGestures`/`navigationBars` (sideHint=RIGHT).
`policy_control immersive.full=*` y `navigation_mode` (ya 0=3 botones) NO liberan esa
franja. El cliente es la app de terceros `org.tfv.deskflow` (v1.0.14, no debuggable): usa
el área segura (2166) como espacio de inyección mientras el display es 2400 → el tramo
derecho queda inalcanzable. NO es algo que gdtk pueda arreglar (el server Deskflow usa el
tamaño que reporta el cliente, no el `res=` de gdtk). Opciones: app Deskflow más nueva /
que inyecte en el display completo, o convivir con la franja.

## #4 layout — DESACTIVADO (2026-10-13)
La propagación absoluta de layout resultó INCORRECTA: cada host difunde su layout en SU
marco de coordenadas y el receptor lo aplicaba crudo (x/y de otro marco) → se
desacomodaban solos. `_peer_layout` quedó no-op y `_maybe_broadcast_layout` no difunde.
El layout se sincroniza por `screen_res` (resolución) y por el editor local. Propagación
correcta requeriría un marco canónico (relaciones de adyacencia), no coordenadas.
Redmi re-patcheado con esta versión (no difunde layout). Disposición del usuario
(cupid west, redmi debajo de cupid, tengu south) quedó estable y el server reiniciado.

## Redmi landscape / mismatch Deskflow — RESUELTO 2026-10-13
Con adb de nuevo (USB `456afc8d`): auto-rotate ON, ventana del app en landscape
(`cur=2400x1080 app=2166x1080`) y Redmi ahora anuncia `res=2400x1080` (antes 1080x2400
porque estaba en portrait y el APK viejo no publicaba res). Bastion actualizó su pantalla
`redmi` a `px 2400x1080`.

El "no pasa de 1/3 y salta a tengu" era la geometría descolgada: `redmi` había quedado
flotando (x -480..0, y 689..905, sin contacto) porque su `w/h` cambió con la resolución y
`apply_resolution` no tenía contacto para anclar (`dir==""` → sólo cambia el tamaño). El
conf de Deskflow lo dejaba sin vínculos. Se reposicionó `redmi` al **este** de bastion
(como el `.bak` previo: `bastion right=redmi`). Conf resultante:
`bastion: down=tengu, left=cupid, right=redmi`; `redmi: left=bastion`; sin bordes
compartidos. Direcciones: cupid west, tengu south, redmi east.

Pendiente/observación: `apply_resolution` con `dir==""` (sin contacto) deja la pantalla
donde estaba (sólo escala) — correcto, pero si un resize la despega no la re-ancla. No se
tocó.

## Tanda 2026-10-13 (tarde) — popup layout, Grupo stale, redmi landscape
- **#C popup de layout**: usaba `WINDOW_NO_BRING_TO_FRONT_ON_FOCUS` y se posicionaba
  pegado al mouse (arriba) → la barra del Frame lo tapaba (botones inalcanzables/ilegible).
  FIX: se quitó ese flag (sube al frente) y `_layout_confirm_place` clava `y >=
  frame_bar_h(vp)+8` (debajo de la barra).
- **#B Grupo no reflejaba Pantallas**: `host_directions` tiene DOS claves por host (nombre
  legacy + hid); la proyección del layout (`_sync_directions_from_screen_layout`) escribía
  la clave por NOMBRE, pero el Grupo indexa por HID → quedaba stale (y generaba bordes
  compartidos: redmi y tengu ambos "south" → el puntero cruzaba a tengu a 1/3). FIX:
  espeja la dirección a la otra clave (nombre<->hid) con `_host_hid_for_label`. Verificado:
  mover redmi a este en `settings.json` actualiza name y hid; al restaurar, ambos. Bastion
  quedó consistente: cupid west, redmi south, tengu east.
- **#1 Redmi portrait/landscape + mismatch Deskflow**: pendiente de diagnóstico en vivo —
  el `adb` de Redmi se desconectó. Manifiesto = `fullUser` (debería rotar); Redmi anuncia
  `res=1080x2400` (portrait) aunque físicamente esté landscape → probable auto-rotate
  apagado o `_screen_size()` no siguiendo la rotación. Sin adb no se puede confirmar.

## Verificación 1º tanda (hecha, verde)
- Puros con binario dev: `deskflow_presence_test` (nuevo), `deskflow_settings_test`,
  `settings_model_test`, `deskflow_watch_test`, `neighborhood_hosts_test`,
  `screen_layout_test`, `gvd_session_test`, `gvd_launch_test`, `deskflow_conf_test`,
  `deskflow_layout_editor_test` — sin FAIL.
- Parseo con `~/gdtk/bin/godot-gdtk`: `parse_check.gd` (se agregaron `apps.gd` y
  `deskflow_presence.gd`) y un check de `settings/pages/{displays,page}.gd`,
  `settings_model.gd`, `main.gd` — todo ok.

## Pendiente / a probar a mano (no validable headless)
1. **A**: subir el multiplicador en Configuración → Pantallas y Aplicar; apuntar el mouse a
   Cupid/Redmi y sentir la velocidad (debería relanzar Deskflow al cambiar). Impacta a
   TODOS los clientes.
2. **B**: con un vecino del Grupo apagado, cruzar el puntero hacia su borde: no debe
   quedar atrapado/oculto. Encenderlo y confirmar que el borde vuelve a funcionar sin
   reiniciar nada.
3. **C1/C2**: en teléfono (Redmi) abrir Hogar → Grilla: bloques del mismo tamaño relativo,
   sin franjas muertas a los costados. Comparar en escritorio (debe conservar el margen).
4. **C3**: en teléfono, mantener sobre una app sin moverse y luego arrastrar → debe vibrar
   al entrar en modo mover; un desliz rápido no debe vibrar (es scroll).

## Entrega
Falta (sólo si el usuario lo pide): `rsync -a --exclude '.import' shell settings ~/gdtk/`
+ recarga transaccional (o deploy a tengu/cupid). No commitear sin pedido.

## Deploy 2026-10-12 (cupid + tengu, pedido del usuario)
Se sincronizaron scripts (shell/addons/settings/mcp/tools) y se hizo **soft reload** por
el RPC de control (`127.0.0.1:7777`, `{"method":"reload_shell"}`) — PID y ventanas intactos
(cupid 976, tengu 2958). No se recompiló: los tres hosts corren el mismo binario `06be9aaac`
(deploy.sh reconstruye; acá era innecesario).

**Pitfall encontrado**: `deskflow_settings.gd` es `const preload` en el shell; al recargar,
Godot 3 sirve el script cacheado y un método nuevo NO existe → `Nonexistent function
'mouse_adjust_text'`. Se movió el helper a `shell/deskflow_mouse.gd` cargado por `Host.sc`
(igual que `deskflow_presence.gd`). Regla: **no agregar métodos a scripts `const preload`**
del shell si tienen que sobrevivir a un soft reload.

Verificado: `peers` de Bastion devuelve cupid, redmi y tengu (descubrimiento OK).

## gvd a Cupid fallaba — diagnóstico 2026-10-12
Síntoma: en `shell.log` de Bastion, cada `gvd_meta`/`gvd_size`/`gvd_stop` a cupid
(`61950c8964e60e15`) volvía `unauthorized`, y `pantalla: el vecino no abrió el receptor
(unauthorized)`; el emisor local salía con `gst rc=2`.

Causa: **desincronización de tokens TOFU** del canal peer (`peer-tokens.json`).
- Bastion NO tenía `cli:61950c8964e60e15` (el token que debe presentar a cupid), así que
  presentaba vacío; cupid sí tenía un `srv:<bastion>` en memoria → `unauthorized`.
- Peor: la **memoria** de `peer_control` de cupid no coincidía con su propio archivo
  (ni con ningún valor persistido). Comprobado con `ping` (`paired:true`) + `gvd_status`
  con cada token persistido → todos `unauthorized`. Un hid centinela de prueba SÍ cargaba,
  así que `_load_tokens` lee bien el archivo: eran tokens viejos los que quedaron en memoria.

Causa raíz: `~/.config/gdtk/peer-tokens.json` lo escriben **dos** subsistemas con
read-modify-write del archivo ENTERO: el shell (`_peer_token_set`, claves `cli:`) y
`peer_control._save_tokens` (claves `srv:`). Una actualización perdida deja un `cli:`
sin escribir (o un `srv:` pisado por un snapshot viejo) y, como el par ya tiene `srv:`,
no hay TOFU de nuevo → `unauthorized` permanente (sin auto-sanación).

Arreglo aplicado (operativo, no código): se reseteó el par y se fijó un token conocido
en ambos lados (cupid `srv:bastion` + bastion `cli:cupid`) con reinicio del shell de cupid
para que su memoria cargue el valor. Ahora `ping -> paired:true` y `gvd_status -> ok:true`.
Cupid cambió de IP (ahora `192.168.18.30`); el destino del emisor es correcto.

Nota: el shell de cupid crashea al salir (`rc=134/139`) pero el supervisor lo relanza.

### Fix durable IMPLEMENTADO 2026-10-12
- **`shell/peer_control.gd` = ÚNICO dueño de `peer-tokens.json`**: `_load_tokens` carga
  `srv:` y `cli:`; `_save_tokens` escribe el dict en memoria completo (sin
  read-modify-write cruzado). Métodos nuevos: `token_for(hid)`, `set_client_token(hid,tok)`,
  `token_forget(hid)`, `token_hids()`. El comentario de las "dos escrituras" quedó actualizado.
- **Auto-sanación** en `_handle`: ante token que no coincide, si el par está **confirmado**
  se re-emite token (y se devuelve) en vez de `unauthorized`; un hid NO confirmado sigue
  `unconfirmed`/`unauthorized`. No amplía la confianza (un confirmado ya hacía TOFU).
- **`shell/shell.gd`**: `_peer_token_get/set/forget/hids` delegan en `Host.peer_control`
  (fallback a archivo si el canal no está). Así el shell deja de escribir el archivo.
- Tests: `tests/peer_control_test.gd` actualizado (re-emparo en vez de unauthorized;
  token_for/set/forget/hids; guardar escribe srv: y cli:). Pasan `peer_control_test`,
  `peer_call_test`, `peer_link_test`, `gvd_launch_test`, `neighborhood_*_test`,
  `audio_send_test`, y `parse_check` (shell.gd, peer_control.gd).
- Desplegado: sync+recarga a **cupid** y **tengu**; verificado en vivo que un token
  incorrecto **re-emite** y luego autentica. Sync a **bastion** (`~/gdtk`) sin recargar su
  sesión viva: el fix de auto-sanación del par ya cubre a Bastion aunque corra código viejo
  (guarda el token que devuelve el par); su parte de escritor único se activa en la próxima
  recarga.
