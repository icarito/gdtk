# SPEC — Rediseño Vecindario, Configuración y modo ventanas (2026-10)

Origen: prueba real del usuario en un VT de su laptop (gdtk aparte de GNOME).
Críticas: UI confusa; botón "Distribución" suelto; hosts en una fila abajo-izquierda
en vez de en el mapa 2D; los nombres internos "gvd"/"deskflow" se muestran; la
conexión activa debería ser un BlockApp; los menús popup estilo WindowMaker salen con
clic izquierdo (deben salir con el derecho; el izquierdo no hace nada en ellos).

Reglas transversales (todas las tareas): Godot 3.6 GDScript (no Godot 4); lógica pura en
`extends Reference` con test `extends SceneTree`; nada de I/O ni procesos en `_draw`/
`refresh`/`_process` (snapshots con TTL, Threads); sin secretos en args/logs; sin commit,
sin deploy, sin ssh; no revertir cambios ajenos. Tests: ver AGENTS.md. Un `kilo run` a la vez.

## Vocabulario de producto (obligatorio en TODA cadena visible al usuario)
Nunca mostrar: gvd, deskflow, role, hid, kind, mDNS, DNS-SD, "recv", "server/client", puertos.
Usar: **Pantalla** (ver/compartir pantalla), **Teclado y mouse** (compartir control),
**Portapapeles**, **Vecino/Equipo**, **Norte/Sur/Este/Oeste** o "arriba/abajo/derecha/izquierda".
Los nombres internos viven sólo en código/logs/tooltips de depuración (GDTK_DEBUG).

## K9 — Menús popup: sólo clic derecho
Los popups ImGui estilo WindowMaker (frame.gd `open_popup` ~l.1236/1252, shell.gd ~l.1778 y
cualquier otro) se abren hoy con clic izquierdo. Deben abrirse con **clic derecho** y el
izquierdo no debe hacer nada sobre el menú/bloque (salvo la acción propia ya definida del
bloque, p.ej. abrir una actividad; no abrir menú). Mantener equivalente de teclado existente.
Write set: shell/frame.gd, shell/shell.gd (sólo la lógica de apertura), tests relacionados.

## K10a — Vecindario: un solo mapa 2D
Quitar: botón "Distribución", compás N/S/E/O flotante, fila "Vecinos" abajo-izquierda,
badges "gvd deskflow", panel de acciones arriba-derecha.
Nuevo `shell/neighborhood_ui.gd` (rediseño; helpers puros en `shell/neighborhood_map.gd`):
- Centro: "Este equipo" (nombre local) con ícono monitor.
- Vecinos como nodos circulares grandes (ícono + nombre) **ubicados en el mapa por su
  dirección**: norte arriba, sur abajo, este derecha, oeste izquierda, pegados al anillo
  medio. Sin dirección: en el anillo exterior, repartidos uniformemente, atenuados.
- Wi-Fi es infraestructura: puntos pequeños y discretos en los anillos + una línea de texto
  "Red: <SSID>"; no compite visualmente con los equipos.
- Arrastrar un vecino hacia un lado lo "imanta" a esa dirección (la guarda en
  host_directions como confirmada; misma fuente que usan Pantalla y Teclado y mouse).
- Clic izquierdo = seleccionar (resalta y muestra un rótulo corto con estado en español).
- **Clic derecho** sobre un vecino = menú popup estilo WindowMaker (menu_style.gd) con
  acciones en lenguaje humano: "Ver su pantalla aquí", "Compartir mi pantalla con él",
  "Compartir teclado y mouse", "Compartir portapapeles", separador, "Colocar al Norte/Sur/
  Este/Oeste", "Quitar de la disposición". Las no disponibles aparecen deshabilitadas con la
  razón en una línea ("no tiene el receptor de pantalla", "falta confirmar la posición").
- Estado vacío claro: "Buscando equipos cercanos…" / "No hay otros equipos" (sin jerga).
- Los ítems de depuración (nombres internos) sólo con GDTK_DEBUG=1.
Write set: shell/neighborhood_ui.gd, shell/neighborhood_map.gd (+test), tests/neighborhood_ui_test.gd.
Conservar las APIs puras ya testeadas (acciones, directions, hosts) y sus tests.

## K10b — BlockApp "Compartido" en el Frame
Cuando hay sesiones activas (ver pantalla, compartir pantalla, teclado y mouse, portapapeles)
aparece un bloque de control (bloque de applet, SPEC-sugar-frame-blocks.md) por sesión o uno
agrupado: ícono del equipo + insignia del tipo (pantalla / teclado / portapapeles) y estado
(conectando / activo / error). Clic derecho = menú: "Detener", "Ver detalles". El bloque
desaparece al cortar. Se alimenta de snapshots cacheados (host_session_state y
service_pids ya existentes), sin procesos en el hilo de render. Lógica pura en
`shell/shared_block.gd` (+test). Write set: shell/frame.gd (sólo registrar/dibujar el applet),
shell/shared_block.gd, tests.

## K11a — Aplicación de Configuración (proceso aparte)
Proyecto Godot propio `settings/` (project.godot + escenas por código) lanzado por el shell
como cualquier app (actividad "Configuración", binario `godot-gdtk --path settings`), así no
recarga ni bloquea el shell. Estado compartido en `~/.config/gdtk/settings.json` (escritura
atómica tmp+rename; el shell lo relee con Thread y TTL ~3 s y aplica en vivo). Páginas:
1. Teclado: distribución (es, latam, us, …; `~/.config/gdtk/keyboard` que ya lee
   session/keyboard.sh) — avisar "se aplica al reiniciar la sesión" si no es en vivo.
2. Idioma: `~/.config/gdtk/locale` (LANG) con lista corta (es_PE, es_ES, en_US, …).
3. Color de acento: selector de paleta (8 colores + personalizado hex); el shell lo usa en
   resaltados/selección.
4. Fondo de pantalla: imagen (ruta y miniaturas de ~/Pictures y ~/.config/gdtk/wallpapers),
   modo (rellenar/ajustar/centrar) o color sólido; el shell lo dibuja detrás del Home.
5. Pantallas (K11b).
Modelo puro en `settings/settings_model.gd` (+test) y `shell/settings_bridge.gd` (lectura
no bloqueante + aplicar). Diseño visual coherente con el shell (paleta de menu_style.gd).
Write set: settings/*, shell/settings_bridge.gd, shell/shell.gd (sólo cableado mínimo y
actividad), tests.

## K11b — Página "Pantallas" (diseño de pantallas)
Reemplaza el panel "Distribución". Modelo puro `shell/screen_layout.gd` (+test):
- Pantallas = rectángulos con tamaño real/virtual (local = viewport; vecinos = 1280x800 por
  defecto o el tamaño anunciado), con posición (x,y) en un plano.
- Interacción tipo GNOME: arrastrar libremente; al soltar se **imanta** para quedar siempre
  **pegada** por un borde a otra (sin solaparse, contacto mínimo de borde > 0 para que el
  mouse pase); permitir desplazamiento a lo largo del borde (alineación arbitraria, no sólo
  centrada), mostrando el tramo de contacto. Número de pantallas general (>2) pero sólo
  la disposición local-vecinos hoy; diseñarlo para generalizar a multimonitor.
- Salida: por cada vecino {direction (borde de contacto con la pantalla local o con la
  cadena), offset en px/porcentaje del borde}. Se persiste en host_directions (misma fuente
  única de Pantalla y Teclado y mouse) y se regenera la config del compartir teclado/mouse
  con las aristas y, si el offset importa, con el campo de alineación que el formato admita.
- Botones "Aplicar" y "Revertir"; conflictos/solapes imposibles por construcción.
Write set: shell/screen_layout.gd, settings/pages/displays.gd (o equivalente), tests.

## K12 — Ventanas por defecto en el hueco central del Frame
Ventanas, diálogos, popups y ventanas hijas deben ocupar **por defecto** el espacio que deja
el Frame en el centro de la pantalla, quitando un bloque por lado (izquierda, derecha,
arriba y abajo), no sólo arriba y abajo. Revisar cómo se calcula el área de contenido
(shell.gd `_units`/layout de tiles y configure del compositor en modules/wayland/ si aplica
sólo vía el shell) y centralizar en una función pura `content_rect(viewport, block, frame_edges)`
con test. Diálogos/hijas se centran dentro de ese rect y se limitan a él.
Write set: shell/shell.gd (área de contenido y colocación), tests.

## K15 — polkit, keyring y autostart de sesión
Crear `session/autostart.sh` (POSIX sh) invocado desde gdtk-session, gdtk-session-sway y
gdtk-session-x11 (tras portal.sh): arranca (si existen en PATH o rutas conocidas) un agente
polkit (`/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1`, o lxqt-policykit-agent,
o mate/xfce), `gnome-keyring-daemon --start --components=secrets,pkcs11` exportando
SSH_AUTH_SOCK/GNOME_KEYRING_CONTROL vía `dbus-update-activation-environment --systemd`, un
daemon de notificaciones layer-shell (mako) y las entradas `~/.config/autostart/*.desktop`
respetando OnlyShowIn/NotShowIn (gdtk) y Hidden. Idempotente y con logs en
~/.local/state/gdtk/autostart.log; cada pieza opcional y que falle no tumba la sesión. Documentar
en `session/DEPS.md` paquetes (polkit-gnome, gnome-keyring, libsecret, mako, dex) y la
nota: con autologin el keyring no se desbloquea por PAM (pedirá la contraseña la primera vez).
Además `deploy.sh` debe rsyncear el nuevo script. Write set: session/*, deploy.sh (sólo rsync).

## K13 — Modo ventanas tradicional (WindowMaker) — primero DISEÑO
> **Actualizado**: la premisa de "modo global" quedó superada por
> `SPEC-hybrid-windows.md` (K13g/K13h): modo **por ventana** + flotantes ancladas a su
> pantalla + unidades con eje + ranura Escritorio. El BlockApp "Ventanas" se retiró.
Escribir `SPEC-wm-mode.md` (no código todavía) tras leer SPEC-windows.md,
SPEC-sugar-frame-blocks.md, shell.gd, frame.gd, tiles_ui.gd y modules/wayland/wl_server.c:
- Modo **flotante por defecto** (ventanas libres con barra de título estilo WindowMaker: texto
  centrado, botón izquierdo minimizar y derecho cerrar, bisel fino, foco resaltado), y modo
  **tiled** como alternativa; el modo se controla desde un BlockApp ("Ventanas") del Frame.
- Arrastrar una ventana tileada o maximizada fuera de su celda/al desmaximizar la
  convierte en flotante bajo el cursor; arrastrar de vuelta sobre un borde/bloque la reincorpora.
- Los bloques del Frame **sin espacios intermedios** (como el clip/dock de WindowMaker).
- A primera vista indistinguible de WindowMaker (mockup ASCII + paleta + medidas en px).
- Lista de tareas implementables y delegables (K13a.. ) con write sets y tests.

## K14 — IME (Input Method Editor) y teclado en pantalla
IME = componente que convierte teclas en texto complejo: composición de chino/japonés/
coreano, teclas muertas avanzadas, emoji, predicción y teclados en pantalla (la X200 Tablet).
En Wayland se implementa con los protocolos `text-input-v3` (el cliente pide texto) e
`input-method-v2` (el motor IME: fcitx5/ibus). Para es_PE las teclas muertas de XKB ya bastan;
el IME importa para CJK, emoji y tablet. Tarea: en modules/wayland/wl_server.c crear
`wlr_text_input_manager_v3` y `wlr_input_method_manager_v2` y el relay mínimo (foco de
text-input al toplevel enfocado, enviar preedit/commit; grabs de teclado del input-method),
comprobable sin hardware con un test del módulo si existe, o al menos compila contra
wlroots 0.20. Requiere recompilar el motor (deploy.sh / scons): NO desplegar; sólo entregar
el parche y notas de prueba en `SPEC-ime.md`. Write set: modules/wayland/*, SPEC-ime.md.

## Orden de ejecución (serie)
K9 → K10a → K10b → K11a → K11b → K12 → K15 → K13 (diseño) → K14.

## Decisiones 2026-10-01 (tarde) — tras probar gvd bastion→tengu
- Dos verbos de producto, no mezclar: **"Extender mi escritorio a X"** (gvd: la pantalla virtual es parte de
  mi escritorio; la entrada sigue siendo mía) y **"Controlar X con mi teclado y mouse"** (Deskflow: el
  escritorio propio de X). Se pueden combinar si el video de gvd es una **ventana/tile** en el shell de X
  (no pantalla completa) y Deskflow usa otro borde. No se reemplaza Deskflow por ahora (servidor propio =
  InputCapture + transporte a EIS + portapapeles: fase futura).
- **El portapapeles no es una opción.** Se quita la acción "Compartir portapapeles" (neighborhood_actions
  `share_clipboard`, `host_clipboard` en shell.gd, ítem del menú). Con "Controlar" se asume compartido
  (`clipboardSharing=true` siempre en los ajustes/layout generados). Con "Extender" se asume compartido vía
  un puente (`wl-paste --watch` → canal ssh/buzón → `wl-copy`) como tarea posterior.
- Al elegir "Extender" hacia un vecino con dirección D: gvd `--position` = D y se desactiva temporalmente
  el vínculo Deskflow hacia ese vecino en esa dirección (guardar y restaurar al cortar).

## K16 — Quitar portapapeles como opción + verbos nuevos
Implementar lo anterior en neighborhood_actions.gd, shell.gd (host_clipboard), neighborhood_ui.gd (menú),
deskflow_settings/deskflow_conf (clipboardSharing siempre true) y sus tests. Vocabulario de menú:
"Extender mi escritorio a él", "Ver su escritorio aquí", "Controlarlo con mi teclado y mouse",
"Usar su teclado y mouse aquí". Write set: esos archivos y tests. Verificar con tools/verify_all.sh.

## K17 — gvd como tile + automatización
El shell lanza/corta gvd (emisor local si es GNOME, receptor remoto por buzón ssh), abre el receptor en un
tile (no fullscreen), usa `--position` según el mapa, `--cursor sway` si hay SWAYSOCK, y gestiona el
vínculo Deskflow del punto anterior. Reutilizar _toggle_service/_launch_tracked, nada bloqueante.

## K18 — Pantalla compartida como ventana normal + resistente a cambios de layout
Pedido del usuario (2026-10-01): el receptor de gvd debe comportarse como una **ventana normal** del shell,
no pantalla completa: por defecto ocupa sólo la **franja entre el frame superior e inferior** (el hueco
central de K12) y tiene un botón/gesto para **maximizar** (y restaurar). Además debe aguantar que el usuario
cambie tamaño/posición/escala de la pantalla virtual desde "Pantallas" de GNOME: hoy, al cambiar el layout,
la sesión ScreenCast de Mutter termina (`Session.Stop: object does not exist`), el emisor se queda sin
fuente y el receptor gst de tengu se cuelga.
Tareas:
1. Receptor (`tools/gvd/gvd.py recv`): sink no fullscreen, título de ventana fijo ("Pantalla compartida"),
   `app_id` estable; sin forzar tamaño. El shell la trata como actividad dinámica normal (SPEC-windows.md)
   y la coloca en el rect de K12; botón maximizar en su bloque/ventana (reutiliza la lógica de maximizar
   existente). Watchdog en el receptor: si no llegan paquetes decodificados en ~5 s o cambia el tamaño del
   video, reiniciar sólo su pipeline gst (no el proceso) y reescalar el cursor (`--video-size` dinámico).
2. Emisor: escuchar `org.gnome.Mutter.DisplayConfig.MonitorsChanged` y el fin de la sesión ScreenCast;
   al ocurrir, releer el tamaño del monitor virtual (Meta-*) y **recrear sesión + pipeline** automáticamente
   (reconectar sin que el usuario relance nada), respetando `--position` sólo en la primera creación (no
   pisar el layout que el usuario acaba de ajustar). Backoff 1→5 s, máx. 5 intentos y avisar por stderr/log.
   Si el tamaño cambió, mandar al receptor el nuevo tamaño (primer paquete UDP de control en el puerto
   del cursor o reinicio del pipeline por keyframe con SPS nuevo).
3. Lógica pura probable (decidir si hay que reiniciar, cálculo de backoff, parsing de tamaño) en
   `tools/gvd/gvd_util.py` con test `tests/gvd_resize_test.py` ejecutable con python3, sin Mutter.
Write set: tools/gvd/*, shell/shell.gd (sólo colocación/maximizar de esa ventana por título), tests.
No tocar el comportamiento de otras ventanas. Verificar con tools/verify_all.sh y python3 tests/gvd_resize_test.py.

## K19 — Pin / autohide de las barras del Frame
Pedido del usuario (2026-10-01): cada barra (superior e inferior) tiene un feature de
**pin** (autohide). Con autohide la barra se muestra al acercar el mouse pero se
**superpone** a las ventanas: la ventana usa todo el espacio disponible que deja la
barra respectiva y **no se redimensiona** cuando la barra aparece. Con pin la barra
queda siempre visible y **reserva** su franja: las ventanas no se colocan debajo ni
encima de ella. Por defecto ambas barras van con autohide, **sincronizado**.
Tareas:
1. `shell/content_layout.gd`: la ventana (top-level) y los diálogos usan
   `content_rect(viewport, block, frame_edges)` con sólo los lados que el Frame
   reserva. Sin lados (autohide) -> viewport completo; barra fijada -> reserva su
   franja. Eliminar el seguimiento del deslizamiento (el autohide no reflowea).
2. `shell/frame.gd`: estado y persistencia por barra en `frame-applets.json`
   (`"pin": {"top": bool, "bottom": bool}`, default false/false), deslizamiento por
   barra, `reserved_edges()`, `toggle_pin(key)`, botón chincheta en cada barra y en el
   menú de Controles, y atajos Super+P / Super+Shift+P.
3. `shell/shell.gd`: `_tile_rect` = `content_rect` con los lados reservados; quitar
   `frame_follow`/`_frame_slide`.
4. Ajuste fino ideal (paso siguiente): si cambia el tamaño del tile del receptor gvd,
   avisar al emisor para redimensionar acá el monitor virtual (receptor -> emisor), de
   modo que la ventana y el video sigan 1:1 sin escalar.

Write set: shell/content_layout.gd, shell/frame.gd, shell/shell.gd, tests/content_rect_test.gd.
Verificar con tools/verify_all.sh y e2e remoto (pin por barra cambia la geometría del tile).
