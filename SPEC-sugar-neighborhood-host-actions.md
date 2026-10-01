# SPEC — Vecindario: hosts y acciones compartidas

Estado: propuesta delegable. Extiende `SPEC-sugar-journal-neighborhood.md` sin
reemplazar su flujo Wi-Fi actual.

Contrato de arquitectura: **el hilo de render nunca espera.** `_draw`/`draw()`,
`refresh()` y `_process()` sólo leen snapshots ya publicados; discovery, procesos,
timeouts y reintentos viven en workers con caché y TTL. El inventario de llamadas
actuales a desbloquear está en `SPEC-screen-share-compass.md` §0.

## Intención

El Vecindario responde: **¿qué hay cerca y qué podemos hacer juntos?** En Sugar
clásico esa pregunta mezclaba, con semánticas distintas, redes Wi-Fi, personas
presentes y actividades compartidas. gdtk todavía no tiene XMPP/Salut ni actividades
colaborativas; por ahora debe mostrar **equipos** con capacidades reales:

- recibir una pantalla `gvd`;
- usar otro equipo como pantalla dedicada desde un emisor GNOME/gvd;
- compartir teclado, mouse y portapapeles con Deskflow;
- compartir portapapeles nativo más adelante.

No llamar a eso "actividad compartida" hasta que una app de gdtk tenga colaboración
propia. Un host descubierto no es una persona Sugar, y un servicio anunciado no es una
sesión autorizada.

## Modelo

El Vecindario conserva cuatro clases separadas:

- **Redes:** puntos de acceso Wi-Fi y conexión actual, como ya hace
  `shell/neighborhood.gd`.
- **Hosts:** equipos descubiertos o guardados.
- **Sesiones:** acciones activas entre este equipo y otro host.
- **Actividades compartidas:** reservado para colaboración real futura.

La vista puede agrupar capacidades bajo un objeto **host**, pero el modelo interno
mantiene registros por servicio. Esto evita un servidor local obligatorio sólo para
descubrir algo.

## Identidad local

Cada instalación genera una identidad no secreta:

```json
{
  "host_id": "b6f4e13b8a2f4d88",
  "label": "Tengu",
  "kind": "laptop",
  "color": "#7aa2ff"
}
```

Ruta propuesta: `~/.config/gdtk/host.json`.

`host_id` es opaco y puede regenerarse si la persona quiere desaparecer de hosts
recordados. No usar nombre de usuario, correo, hostname real ni dirección MAC como
identidad pública. Una identidad emparejada futura debe pinnear una clave del canal
autenticado, no confiar en mDNS.

## Discovery DNS-SD

Usar mDNS/DNS-SD sólo para descubrimiento en la LAN. Anunciar un servicio por función
y puerto; agruparlos en la UI por `hid`.

Reglas TXT:

- sin secretos, tokens ni rutas privadas;
- total ideal menor a 200 bytes;
- cada entrada menor a 255 bytes;
- claves cortas y versión explícita;
- cualquier dato crítico se confirma dentro del canal autenticado.

### TXT común

```text
v=1
hid=b6f4e13b8a2f4d88
name=Tengu
kind=laptop
icon=laptop
auth=ask
```

`kind`: `desktop`, `laptop`, `tablet`, `mobile`, `tv`, `unknown`.

`icon`: pista visual incorporada. No descargar iconos/modelos remotos desde TXT. La
customización vive localmente.

### Pantalla gvd

Servicio receptor/capacidad:

```text
_gdtk-gvd._udp
```

SRV apunta al host y puerto UDP de video, normalmente `5600`. Si el receptor ya está
escuchando, publicar `state=ready`; si gdtk sólo sabe lanzarlo bajo demanda, publicar
`state=capable` y requerir un canal explícito (`ssh` o control remoto gdtk) antes del
`send`.

TXT adicional:

```text
role=recv
state=ready
codec=h264
rtp=96
cursor=separate
cursor_port=+1
size=1280x800
```

Acciones ofrecidas desde el host remoto:

- **Usar como pantalla:** ejecutar `gvd.py send --host <host>` desde un emisor que
  soporte GNOME/Mutter ScreenCast. Esto crea un monitor virtual y lo coloca con
  `--position right|left|above|below`.
- **Compartir mi pantalla:** misma acción si el equipo local es emisor `gvd`; en gdtk
  como emisor queda fase tardía.
- **Ver pantalla:** reservado hasta que exista `role=send` o un canal de invitación.

Contrato observado en `~/Proyectos/gvd`: `send` crea un monitor virtual GNOME,
codifica H.264 constrained-baseline y lo envía por RTP/UDP; `recv` escucha UDP,
decodifica con GStreamer y puede mover cursor nativo de sway con datagramas en
`port+1`. El launcher actual de gdtk abre el receptor con `python3
"$HOME/gvd/gvd.py" recv --sink wayland`; al integrar, resolver la ruta real
(`~/Proyectos/gvd` en desarrollo, instalación futura en `~/gvd` o PATH).

`gvd` no cifra ni autentica el stream. Usarlo sólo en LAN de confianza o detrás de una
red segura; mDNS no cambia esa condición.

### Deskflow

Servicio anunciado:

```text
_gdtk-deskflow._tcp
```

TXT adicional:

```text
role=server
clip=1
tls=required
screen=edge
```

`role=server` significa "acepto clientes Deskflow". `role=client` significa "puedo
conectarme a un servidor". Si la configuración real de Deskflow no coincide, no
publicar el servicio.

Acciones:

- **Compartir teclado y mouse:** conectar este host como cliente al servidor remoto.
- **Usar mi teclado y mouse aquí:** publicar/activar servidor local, si existe.
- **Compartir portapapeles:** aparece como subtoggle sólo si `clip=1`.

gdtk ya tiene Deskflow como servicio. Reusar `_toggle_service()`, `_service_running()`
y `service_pids`; no crear un segundo ciclo de vida.

### Portapapeles nativo futuro

Reservado:

```text
_gdtk-clip._tcp
```

No implementarlo hasta tener canal autenticado y consentimiento separado. El
portapapeles puede contener secretos; nunca debe compartirse por aparecer en mDNS.

## UI del Vecindario

Cada host tiene un objeto visual con:

- icono por `kind` o customización local;
- nombre legible;
- estado: `visto`, `guardado`, `emparejado`, `conectado`, `perdido`;
- badges pequeños: pantalla, entrada, portapapeles;
- menú de acciones disponibles.

Submenú sugerido:

```text
Tengu
  Compartir mi pantalla
  Usar como pantalla
  Compartir teclado y mouse
  Compartir portapapeles
  Editar icono...
  Olvidar host
```

Estados de acción:

- `disponible`: servicio anunciado y no conectado;
- `pendiente`: proceso lanzado, esperando ventana/conexión;
- `activo`: sesión viva y revocable desde el mismo menú;
- `falló`: error traducido, con reintentar;
- `no confiable`: requiere emparejar o confirmar identidad.

No autoconectar entrada ni portapapeles. Pantalla sin interacción puede pedir menos
fricción, pero sigue siendo acción explícita.

## Iconos y modelos

El host remoto sólo propone `kind` e `icon`. La persona puede sobrescribirlo:

Ruta propuesta: `~/.config/gdtk/neighborhood-hosts.json`.

```json
{
  "b6f4e13b8a2f4d88": {
    "label": "ThinkPad de taller",
    "kind": "laptop",
    "icon": "laptop",
    "model": "/home/icarito/.local/share/gdtk/hosts/thinkpad.glb"
  }
}
```

Primer corte: iconos 2D incorporados. GLB queda como campo futuro; no cargar modelos
remotos ni ejecutar rutas anunciadas por otro host.

## Seguridad

- mDNS descubre; no autentica.
- TXT informa; no autoriza.
- Teclado, mouse, pantalla y portapapeles son permisos separados.
- Toda sesión activa debe verse y poder cortarse desde Vecindario.
- No guardar secretos en Diario ni logs.
- No pasar contraseñas, tokens ni claves por argumentos de proceso.
- Si un `hid` conocido aparece con otro nombre o dirección, mostrarlo como sospechoso
  hasta confirmar.

## Delegación Kilo

### Kilo A — modelo de discovery

Objetivo: agregar un modelo puro de hosts/capacidades sin tocar UI.

Entradas:

- salida de `avahi-browse -rtp` o fuente equivalente;
- registros TXT de ejemplo;
- hosts guardados en JSON.

Entregables:

- parser de servicios DNS-SD;
- agregación por `hid`;
- estados `visto/guardado/conectado/perdido`;
- autoprueba pequeña con dos hosts, dos servicios y un servicio vencido.

No hacer: daemon nuevo, emparejamiento, UI.

### Kilo B — publisher mínimo

Objetivo: publicar las capacidades locales reales.

Primer corte aceptable:

- usar `avahi-publish-service` si existe;
- publicar sólo servicios que estén activos y alcanzables;
- apagar el anuncio al detener el proceso.

No hacer: inventar un servidor gdtk permanente.

### Kilo C — UI de host

Objetivo: extender `shell/neighborhood_ui.gd` para dibujar hosts además de Wi-Fi.

Reglas:

- no mezclar hosts con puntos de acceso;
- usar iconos por `kind`;
- menú de acciones por host;
- el Frame sigue siendo sólo entrada al Vecindario.

### Kilo D — acciones gvd

Objetivo: conectar acciones de pantalla a lo que ya existe.

Acciones:

- receptor local: reutilizar la actividad `Pantalla`, corrigiendo la ruta de `gvd.py`
  según el host;
- enviar a host: lanzar `gvd.py send --host <host>` sólo si el peer anuncia
  `_gdtk-gvd._udp role=recv`;
- si el peer anuncia `state=capable`, abrir primero el receptor por el canal ya
  autorizado (`ssh` o control remoto gdtk); si no existe ese canal, mostrar la acción
  deshabilitada;
- reflejar `pendiente/activo/falló`.

No hacer: prometer `Ver pantalla` sin `role=send` o invitación.

### Kilo E — acciones Deskflow

Objetivo: exponer Deskflow desde el host, no duplicar el servicio.

Reglas:

- reusar `_toggle_service()`, `_service_running()` y `service_pids`;
- si hace falta cambiar destino, generar/configurar el archivo de Deskflow de forma
  explícita y reversible;
- portapapeles como subtoggle, no implícito.

### Kilo F — customización de host

Objetivo: persistir overrides de icono/nombre.

Primer corte:

- `neighborhood-hosts.json`;
- `kind` e icono 2D;
- validación de rutas locales para `model`, sin cargar GLB todavía.

## Criterios de aceptación

- Dos servicios del mismo `hid` aparecen como un host con dos acciones.
- Un servicio sin `hid` aparece degradado y no se empareja automáticamente.
- Al caer el anuncio, el host pasa a `perdido` sin desaparecer de golpe si estaba
  guardado o conectado.
- Deskflow activo se refleja desde el proceso real, no desde el último click.
- gvd no muestra acciones de envío si el receptor no está anunciado.
- La UI permite cortar cualquier sesión activa desde el mismo host.
- Sin Avahi/mDNS disponible, el Vecindario sigue mostrando Wi-Fi y un estado
  degradado para hosts.

## Referencias

- `SPEC-screen-share-compass.md` (dirección N/S/E/O, extend vs mirror)
- `SPEC-sugar-journal-neighborhood.md`
- `shell/neighborhood.gd`
- `shell/neighborhood_ui.gd`
- `shell/shell.gd`
- `~/Proyectos/gvd/README.md`
- Sugar Labs HIG: <https://wiki.sugarlabs.org/go/Human_Interface_Guidelines/The_Laptop_Experience>
- Sugar Labs Wi-Fi: <https://wiki.sugarlabs.org/go/Documentation_Team/User_Manual/Connecting_to_the_Internet>
- Sugar Labs colaboración: <https://help.sugarlabs.org/collaborating.html>
- RFC 6762 mDNS: <https://www.rfc-editor.org/rfc/rfc6762.html>
- RFC 6763 DNS-SD: <https://www.rfc-editor.org/rfc/rfc6763.html>
- Deskflow: <https://github.com/deskflow/deskflow>
