# Blackboard: Vecindario, Hogar y Frame

## Vecindario

El Vecindario usa `shell/neighborhood.gd` como modelo de Wi-Fi y una vista
`Control` (`shell/neighborhood_ui.gd`) con anillos dibujados por `CanvasItem`,
botones nativos para las redes y SVG para sus estados. No tiene sidebar: una
selección muestra sólo el nombre y la acción «Conectar».

**Slug:** el motor del fork en `aaf46b877` aporta SlugHorn y `SlugVector2D`.
Slug dibuja los iconos SVG en GLES3; `Control` conserva layout, foco y gestos.
En GLES2 la vista rasteriza los mismos SVG. No duplicar la interacción dentro
de Slug.

Los cuatro SVG pasan la prueba de `SlugVector`, y la vista se comprobó en
GLES3 a 1024×600. La capa de Frame ImGui permanece superpuesta a la vista nativa.

## Hogar y Frame

- Hogar: actividades en órbita alrededor de una computadora, con Apps como
  catálogo. La computadora indica el equipo propio, no una persona.
- Frame: un solo bloque de recursos con historial CPU, MEM y SWP; reloj con
  esfera y hora. Deskflow y Bluetooth quedan fuera del selector de applets por
  ahora. Sin bloque XO sin acción.
- Apps: un bloque del catálogo se arrastra al borde superior o al dock inferior.
  La misma tesela con bisel permite moverlo de borde, activarlo o quitarlo
  arrastrándolo fuera. Los IDs XDG se guardan en `frame-applets.json` bajo
  `top` y `dock`; el orden de ventanas sigue saliendo de `shell._units()`.
- Al arrastrar una app o un widget, la tesela completa sigue el cursor y deja
  vacío su lugar de origen hasta soltarla.
- El catálogo usa celdas cuadradas de 1,5 unidades de rejilla y deja una unidad
  libre a cada lado y arriba y abajo de la zona desplazable.

Pendiente de comprobación visual en el shell real: caída de iconos, saturación
de las órbitas con muchas actividades y ancho disponible al llenar el dock.
