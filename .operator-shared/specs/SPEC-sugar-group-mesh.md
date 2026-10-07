# SPEC — Mesh Wi-Fi automático del Grupo

Estado: **en curso**. Decisiones tomadas con el operador (2026-10-06): mesh
**abierto** (sin clave) y host **automático** = el miembro del Grupo que comparte
teclado y mouse (servidor Deskflow) y tiene radio spare.

## Objetivo

Cuando un equipo del Grupo comparte teclado y mouse y detecta que puede hospedar
una red dedicada de baja latencia, la levanta; los demás equipos del Grupo se unen
solos, con la menor latencia posible (mesh antes que la red de casa), y si algo
falla **revienten a la red conocida** y lo reportan en la vista Grupo.

## Roles

- **Host del mesh**: miembro del Grupo con rol **servidor Deskflow**
  (`_group_input_on` / TXT `role=server`) **y** una radio wifi spare
  (`session/gdtk-mesh` la detecta). Sólo él hospeda.
- **Miembros**: el resto del Grupo (`group_model.members`).

## Flujo

1. **Host**: al volverse servidor Deskflow del Grupo con spare → `gdtk-mesh up`
   (AP `gdtk-mesh`, `ipv4.method shared` = DHCP+NAT de NM). El AP es **abierto**.
2. **Aviso (sin secreto)**: publica por mDNS un flag `mesh=<SSID>` (y `mesh_hid=<hid>`)
   en su anuncio. `neighborhood_publish.gd` prohíbe secretos/slash en TXT: acá no hay
   clave, así que alcanza.
3. **Unión automática**: los miembros ya tienen el perfil cliente **abierto** del
   SSID con `autoconnect` y prioridad alta (`gdtk-mesh join`); NetworkManager los
   une en cuanto aparece el AP y los devuelve a la red conocida cuando desaparece.
   El mesh es la red de menor latencia (dedicada, 5 GHz si se puede), así que gana
   por prioridad frente a la red de casa.
4. **Fallback + reporte**: si no asocian o el AP cae, NM reverte al perfil conocido;
   la vista Grupo/Vecindario muestra el estado del mesh por equipo
   (`mesh activo` / `conectado` / `sin Internet` / `revertido`).

## Capas y archivos

- `session/gdtk-mesh` (**hecho**): `auto|up|down|join|status`. `auto` = host si hay
  spare, baja si no. `join` = asegura el perfil cliente abierto (provisiona un
  miembro). Genérico (sin nombres de interfaz/SSID/subnet fijos).
- `session/gdtk-mesh-provision` (**hecho**): servicio+timer systemd + udev que corren
  `auto`; `ip_forward`; config.
- `neighborhood_publish.gd` (**hecho**): campo TXT `mesh=<SSID>` (sin secreto) en el
  anuncio cuando el equipo hospeda; `neighborhood_hosts.gd` lo parsea a `host.mesh`
  (validado: sólo un átomo seguro de SSID).
- `shell.gd` (**hecho en el árbol**): `_mesh_sync()` escribe/borra
  `$XDG_RUNTIME_DIR/gdtk/mesh-role` = `host` **ssi `_deskflow_role == "server"`** y
  corre `gdtk-mesh auto`; al cambiar el rol república el mDNS para agregar/quitar
  `mesh=`.
- `neighborhood_ui.gd` (**hecho**): la vista Grupo muestra `Red propia del Grupo
  (mesh): activa` si este equipo hospeda, o `Red propia disponible en <nombre>` si
  un vecino la anuncia; cada nodo con `host.mesh` lleva la etiqueta `red propia`.

## Seguridad

- AP **abierto** por decisión del operador: es una LAN de confianza; el mesh da NAT
  a Internet. La clave WPA queda para más adelante (la infra existe:
  `neighborhood_hotspot.gd`, `passwd-file` sin argv).
- **Nunca** la clave por TXT mDNS/argv/logs. El firewall del mesh y el `~/.ssh/config`
  (host keys) los administra `gdtk-mesh` en runtime con la subnet real.

## Pendiente de coordinación

El wiring en `shell.gd` cae sobre archivos que otra sesión está editando
(popup-layout-grupo). Se hará cuando esa rama de trabajo libere esos archivos.
