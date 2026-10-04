# SPEC — Identidad visual de Hogar (siguiente corte)

Estado: propuesta de diseño; sin implementación en el primer corte espacial.

## Propósito

Hogar debe reconocerse de un vistazo como el espacio de la persona. La captura actual
muestra botones rectangulares con texto sobre un fondo oscuro. Sugar Next ya probó un
anillo de favoritos, íconos XDG y fondo configurable; gdtk ya resuelve íconos XDG
en `shell/apps.gd`. Reusar esos comportamientos sin trasladar código GTK/Python.

## Comportamiento propuesto

- Centro: figura personal reconocible como Sugar, con su pareja de colores XO elegida
  por la persona; desde ella se accede a Diario, composición del Frame y sesión. `Salir` es
  una acción de sesión, no una actividad del anillo.
- Anillo: favoritos elegidos por la persona **más** actividades abiertas. Los íconos
  conservan identidad visual de cada app; estado cerrado, abierto y enfocado se
  diferencia por saturación/contorno, con texto legible y no sólo color. La grilla
  `Apps` sigue sirviendo para descubrir todas las aplicaciones e iniciar la búsqueda.
  Las instancias abiertas pueden mostrar una señal parcial de memoria siguiendo
  `SPEC-sugar-resource-ring.md`; su valor requiere atribución real por proceso.
- Fondo: imagen o color elegido por la persona, integrado con su pareja de colores XO;
  valor inicial sobrio si no hay imagen.
  El mismo fondo se reconoce al pasar de Hogar al exposé, con un velo que preserve
  contraste de tarjetas y texto. No usar una imagen como única señal de foco o estado.
- Escala: el ícono que se pulsa es el origen visual de la ventana (ya existe
  `pending_origin`); volver a Hogar debe dejar claro de dónde se salió. Mantener
  animaciones breves y una opción de movimiento reducido cuando se implemente.
- Deskflow puede fijarse como bloque del Frame si el usuario lo usa a diario; su
  estado de conexión pertenece también al Vecindario. Evitar confundir servicio con app.

## Criterio visual para el futuro prototipo

En 1280×720 y en la pantalla de baja resolución: reconocer persona, favoritos,
actividad enfocada y acceso a todas las apps sin leer una lista de nombres pequeños;
el wallpaper no reduce la legibilidad; el anillo no desborda con muchas apps.

Referencias locales: `shell/apps.gd`, `shell/shell.gd`,
`/home/icarito/Proyectos/SugarLabs/sugar-next/sugar_next/shell/pie_menu.py`,
`/home/icarito/Proyectos/SugarLabs/sugar-next/sugar_next/shell/icon_state.py`,
`/home/icarito/Proyectos/SugarLabs/sugar-next/HIG.md`.
