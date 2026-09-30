# SPEC — Orientación espacial del shell Sugar

Estado: primer corte implementable. El shell actual ya abre actividades y ventanas Wayland,
ordena las pantallas horizontalmente, permite agrupar ventanas en una pantalla partida y
tiene Frame y exposé. Este spec añade señales para que ese orden se pueda leer sin cambiar
el modelo de navegación. La presentación en botones alargados del Frame es transitoria;
`SPEC-sugar-frame-blocks.md` define la dirección visual posterior.

## Modelo

- **Dentro de Actividad**, izquierda y derecha recorren las pantallas existentes. Dos
  ventanas tileadas comparten una pantalla. El foco es una ventana dentro de ella.
- **Hogar** es el lugar propio, con la persona en el centro, y además la ranura extra
  al final de la fila de pantallas (`units.size()`): se llega scrolleando a la derecha
  desde la última pantalla y se vuelve con la izquierda a la que tuvo el foco.
- **Vecindario** amplía la escala hacia otras personas/equipos; **Diario** recorre el
  tiempo. Sus propuestas están en `SPEC-sugar-journal-neighborhood.md`.
- La misma secuencia de pantallas debe leerse en el cambio lateral, el Frame y el exposé.
  El orden y los grupos salen de `shell._units()`; no se inventa otro estado de layout.

## Primer corte

1. **Frame (`shell/frame.gd`)**. Mostrar las ventanas visibles en el orden de las
   pantallas; las de una pantalla partida quedan juntas. Cada entrada visible lleva
   un número pequeño de pantalla compartido por sus miembros. Las actividades
   internas siguen identificadas por nombre; las ventanas minimizadas se listan
   después, atenuadas y sin fingir que ocupan una pantalla. El foco actual conserva
   el resaltado existente. Esto también alinea Alt+Tab con el mapa visual.
2. **Exposé (`shell/tiles_ui.gd`)**. Mantener sus tarjetas y navegación actuales.
   Dibujar bajo ellas un indicador por pantalla, abarcando todas las tarjetas de
   un grupo, con índice y total. La selección de una ventana no debe hacer parecer
   que las demás ventanas de su pantalla viven en otro lugar.
3. Respetar `fullscreen`, Home, ventanas internas y el caso sin ventanas: no mostrar
   indicadores de pantallas inexistentes. No alterar tamaño, input ni cierre de apps.
4. **Hogar en la fila**. El Hogar es la ranura `units.size()` (también sin ventanas):
   `_focus_dir`, `_pan_by`/`_snap_pan` y Super+rueda lo alcanzan y el paneo lo dibuja
   deslizándose junto a las ventanas. Minimizar deja bloque atenuado + anillo punteado.

## Comprobación

- Con tres ventanas: orden `1, 2, 3` igual en Frame, exposé y navegación lateral.
- Al tilear dos: ambas muestran `1`; la tercera pasa a `2`; exposé indica el grupo.
- Minimizar una: aparece en el Frame como minimizada, fuera de la secuencia visible;
  restaurarla recupera un número. Alt+Tab sigue activando cada ventana.
- Home y una actividad interna no muestran un falso número de pantalla.
- Probar al menos una captura con tres ventanas y otra tras agrupar dos. Inspeccionar
  visualmente legibilidad a 1280×720 y en el equipo de baja resolución antes de
  declarar terminada la validación visual. Las pruebas automáticas sólo prueban estado.

## Límites del corte

No crear workspaces persistentes, nueva vista de Grupos, nuevos atajos, wallpapers,
Diario ni Vecindario en esta entrega. Conservar las modificaciones existentes del
árbol: hay archivos sin confirmar que pertenecen al usuario. No hacer commit ni push.

Referencias: [Sugar HIG](https://wiki.sugarlabs.org/go/Human_Interface_Guidelines/The_Laptop_Experience/Zoom_Metaphor),
[GNOME Shell UX](https://blogs.gnome.org/shell-dev/2020/12/18/gnome-shell-ux-plans-for-gnome-40/).
