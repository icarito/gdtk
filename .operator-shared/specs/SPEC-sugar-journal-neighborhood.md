# SPEC — Diario y Vecindario (dirección de producto)

Estado: propuesta para iteraciones posteriores. Ambos conceptos completan las escalas
de Sugar Labs alrededor del shell actual. No son parte del primer corte espacial.

## Diario: profundidad temporal

Pregunta que debe responder: **¿qué estaba haciendo y cómo vuelvo a ello?** Desde
la persona en Hogar y desde el Frame se llega a una cronología de trabajos,
documentos y sesiones compartidas, con búsqueda por fecha, actividad y participante.
Una entrada distingue «abrir la app» de «reanudar este objeto»; si una app no ofrece
reanudar, no prometerlo. El Diario no es otra pantalla en la fila de workspaces.

Sugar Next tiene `examples/extensions/journal.py`: registra apertura y cierre en
SQLite, útil como prueba de hooks, pero todavía no guarda objetos ni ofrece una vista
para reanudar. La HIG propone un Diario transversal a las apps. Investigar Zeitgeist
como fuente existente de eventos de escritorio vía D-Bus; su log de eventos puede
alimentar la cronología, pero por sí solo no guarda el estado de una app ni un
documento. En este entorno no se encontró `zeitgeist-daemon`, así que la integración
depende de instalarlo y comprobar qué productores de eventos hay realmente.
Evitar llevar dos historiales paralelos sin una razón observada.

Primer prototipo futuro: consultar eventos recientes reales y mostrar una línea de
tiempo; incluir una entrada de gdtk con hora, actividad y recurso cuando se conozca.
Validar que una entrada pueda volver al recurso antes de llamar «Diario» al registro.

## Vecindario: amplitud social

Pregunta que debe responder: **¿quién o qué está cerca y qué podemos hacer juntos?**
La vista mantiene separadas, sin fundirlas en una sola lista, cuatro clases de cosa:
**personas** (avatares, como en Sugar), **equipos** (máquinas vinculadas), **redes
Wi-Fi** (infraestructura, no personas) y **actividades compartidas** (una app con
sesión colaborativa). Que algo esté cerca no lo vuelve persona, y que un equipo esté
bajo control no crea una colaboración Sugar.

Como en el Sugar original, las redes Wi-Fi deben ser **visibles y elegibles desde el
Vecindario**: se listan los puntos de acceso al alcance y el usuario elige uno. La
wiki de Sugar describe ese flujo con círculos que representan puntos de acceso; al
tocar uno aparece una paleta con **Connect**, una paleta secundaria fija el tipo de
cifrado y pide la contraseña si la red está protegida, y una conexión lograda muestra
los frentes de onda. gdtk conserva esa idea de «red visible → elegir → credencial →
confirmación visible», sin copiar los glifos XO ni suponer redes ad hoc/olpc-mesh,
que no están verificadas en Tengu. El vínculo a otra máquina se representa en el borde
que corresponda a la disposición real, si esa disposición está disponible; sin datos,
mostrar sólo «conectado» o «desconectado».

**Deskflow** ya aporta paso de teclado, mouse y portapapeles entre computadoras. gdtk
lo arranca como servicio y recibe input por portal/libei. Es el primer vínculo real
que el Vecindario debe hacer visible: equipo conocido, estado de conexión/control y
acción explícita para activar o detener. Deskflow **muestra un equipo conectado y su
control; no equivale a colaboración Sugar** ni informa por sí mismo qué personas están
presentes ni convierte una app en sesión compartida. Para eso, Sugar Next plantea
hooks de presencia y XMPP; el `peer-chat.py` del repo es sólo una prueba de concepto
sin UI, no una base de producción.

**Bluetooth no es persona ni red Wi-Fi.** Es un transporte de dispositivos y debe
representarse aparte: su propio applet en el Frame, con estado propio (encendido,
apagado, emparejado) y sin mezclarse con la lista de redes del Vecindario.

### Flujo Wi-Fi básico (NetworkManager; aún sin API propia)

Tengu ya trae NetworkManager con `nmcli` y `nmtui` instalados y el daemon en
ejecución (verificado: `nmcli` 1.58.1). El primer prototipo puede cubrir el flujo
llamando a `nmcli` por proceso; esto **no constituye todavía una API** de red de gdtk
y no debe congelarse como tal. El Vecindario sólo presenta estado y acciones, sin
exponer salida cruda ni secretos.

- **Ver red actual.** Estado y perfil activo: `nmcli -t -f STATE general`,
  `nmcli connection show --active`, `nmcli device status`. Mostrar el SSID actual y,
  si se conoce, la señal; si no hay, «sin conexión». Una conexión cableada activa se
  trata como red actual, aunque no exija elección.
- **Escanear.** `nmcli device wifi list --rescan yes` (o `nmcli device wifi rescan`
  seguido de `list`). Listar SSID, seguridad (abierta/WPA) y señal. No revelar
  contraseñas; prohibido `--show-secrets`.
- **Conectar con credencial.** Un perfil guardado se puede activar mediante
  `nmcli connection up` usando su identificador. Para una red nueva, el primer
  prototipo abre desde Vecindario `nmtui connect` en Terminal;
  la paleta propia llegará con un agente de secretos o un canal seguro equivalente.
  No pasar contraseñas en argumentos de proceso, logs ni Diario.
- **Desconectar.** `nmcli connection down id "$PERFIL"` deja el dispositivo listo
  para reconectar; `nmcli device down "$IFACE"` además bloquea la reconexión
  automática. La acción debe decir cuál de las dos intenciones ofrece.
- **Error.** Distinguir por el código de salida de `nmcli` (4 activación fallida,
  8 NetworkManager no corre, 10 red inexistente) y por el estado del dispositivo.
  Ofrecer reintentar, elegir otra red o ver la radio; traducir el mensaje, no volcar
  el inglés de `stderr`.
- **Radio apagada.** `nmcli radio wifi` informa encendida/apagada; si está apagada,
  mostrar «Wi-Fi apagado» con una acción explícita a `nmcli radio wifi on`, sin
  encenderla en silencio. Antes de operaciones privilegiadas, consultar
  `nmcli general permissions`.

**Bloque opcional de Frame.** Si el Vecindario se representa con un bloque en el
Frame, ese bloque **sólo muestra estado** (red actual, o «Wi-Fi apagado», o
«desconectado») y **abre el Vecindario** al activarse. No escanea, no pide
credenciales y no conecta desde el Frame; toda la operación Wi-Fi vive en el
Vecindario, igual que en Sugar.

### Primer prototipo futuro

Presentar en Hogar/Vecindario el equipo Deskflow realmente conectado y su estado,
junto a la lista de redes Wi-Fi leída de NetworkManager con el flujo anterior. Sólo
añadir presencia de personas e invitaciones cuando exista una fuente fiable. Toda
acción de compartir/controlar debe ser legible y revocable desde la misma vista.

### Criterios de aceptación

- **Red ausente.** Sin hardware Wi-Fi o sin puntos de acceso al alcance: el Vecindario
  muestra un estado vacío legible («no hay redes») sin error ni bloqueo, y conserva la
  red actual si existe. Ninguna acción de conectar queda colgada.
- **Offline.** Con radio apagada o sin conectividad: el estado se muestra con
  honestidad, el trabajo local y el Diario siguen funcionando, y no se promete
  colaboración ni presencia que no exista.
- En ambos casos, si `nmcli` no responde o falta permiso, la vista muestra un estado
  degradado en lugar de fallar.

Referencias: [Sugar: cómo conectarse a Internet](https://wiki.sugarlabs.org/go/Tutorials/Connecting_to_the_Internet),
[NetworkManager: nmcli](https://networkmanager.dev/docs/api/latest/nmcli.html),
[Sugar Journal](https://help.sugarlabs.org/journal.html),
[Sugar colaboración](https://help.sugarlabs.org/collaborating.html),
[Zeitgeist](https://zeitgeist.freedesktop.org/),
[Deskflow](https://github.com/deskflow/deskflow),
`/home/icarito/Proyectos/SugarLabs/sugar-next/HIG.md`.
