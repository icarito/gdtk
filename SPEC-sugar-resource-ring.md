# SPEC — Anillo de recursos de Hogar

Estado: propuesta de diseño. No implementa código en el prototipo actual. Extiende
`SPEC-sugar-home-visual.md` (anillo = favoritos + actividades abiertas). Sólo se
dibuja consumo cuando exista una medición real atribuible; si no, estado «sin dato».

## Idea recuperada de Sugar

La HIG original asignaba a cada instancia abierta un segmento cuyo tamaño
expresaba su consumo de memoria. El segmento no era decorativo: codificaba
recursos. gdtk hoy
dibuja botones de tamaño fijo (`shell/shell.gd:_draw_home`) y sólo mide CPU/RAM/swap
del sistema en el Frame (`shell/sysmon.gd`, desde `/proc`). Esta spec reintroduce la
señal de recursos **por instancia de actividad**, de forma modesta y honesta.

## Dos clases de entrada en el anillo

- **Favorito cerrado**: app fijada sin ventana ni proceso vivos. No hay nada que
  medir. Segmento base fijo; se distingue por contorno/atenuación, nunca por barra.
- **Instancia abierta**: actividad viva (ventana Wayland o script con estado en
  `script_instances`). Única candidata a segmento variable.
- La HIG habla de «each instance»: dos terminales abiertas deberían ser dos
  entradas. Hoy el anillo indexa por nombre de actividad (`wayland_ids`, clave =
  `name`), así que varias instancias de la misma app colapsan en una. Si se quiere
  fidelidad a la HIG, hay que separar por instancia; hasta entonces, documentar el
  límite y no sumar sus memorias como si fuera una sola.

## Medición: qué sí está disponible

- **Atribución**: el shell conserva sólo el último PID lanzado (`last_launch_pid`)
  y los PIDs de servicio (`service_pids`); `wayland_ids` asocia nombre a ventana,
  sin un mapa persistente de ventana a proceso. `_ppid` consulta el padre de un
  proceso para el permiso remoto. Antes de dibujar memoria por instancia hace
  falta una asociación estable entre ventana y PID y, si corresponde, recorrer
  sus descendientes sin contar un proceso dos veces.
- **Ventanas no lanzadas por el shell** (`unmanaged`): el PID puede no conocerse. Se
  marca «sin dato»; no se adivina ni se reparte la memoria global.
- **Memoria**: preferir **PSS** (`/proc/<pid>/smaps_rollup`), que reparte memoria
  compartida y evita doble conteo entre apps. **RSS** sólo como respaldo, sabiendo
  que sobrecuenta librerías compartidas. Nunca sumar PSS y RSS a la vez.
- **CPU (opcional)**: delta de `utime+stime` de `/proc/<pid>/stat` sobre el mismo
  periodo que ya usa `sysmon` (1 s). Si se usa, es un canal secundario (p. ej.
  grosor o pulso), nunca sustituye a la memoria y sólo aparece si fue medida.

## Reglas anti-ficción

- Sin medición → segmento base + marca explícita de desconocido. Prohibido dibujar
  una barra inventada o «estimar» a partir de la memoria total del sistema.
- No prometer consumo por app si no hay PID atribuible.
- No duplicar el monitoreo global del Frame; el anillo es relativo y local.

## Visual y estabilidad

- Mantener las posiciones y áreas pulsables de los íconos. Detrás de cada
  instancia abierta, un arco interior ocupa una fracción de su sector fijo según
  la memoria medida respecto de un presupuesto de referencia explícito (por
  ejemplo, la RAM física). Mostrar el valor al enfocar. Así se recupera la pista
  visual del anillo original sin que un cambio de consumo desplace otras apps.
  El arco tiene un tope; si se satura, indicar el exceso en texto.
- **Estabilidad**: muestrear al periodo del Frame (1 s), no por frame; redondear,
  suavizar con paso bajo y umbral mínimo de cambio para evitar parpadeo. La
  **posición** de cada entrada no cambia con el tamaño: sólo varía su largo.
- **Estado legible sin color**: cerrado/abierto/enfocado se distinguen por contorno,
  saturación y texto (ya pedido en `SPEC-sugar-home-visual.md`); el recurso es una
  señal extra, nunca la única que carga identidad o foco.
- **Accesibilidad/movimiento**: opción de movimiento reducido, diferencias que no
  dependan de píxeles finos y valor textual («≈ 120 MB») al enfocar o pasar el
  puntero, no sólo la barra.
- **Privacidad**: señal estrictamente local y relativa. No exponer nombres de
  procesos ni tamaños al Vecindario ni a la red; no registrarlos más de lo
  necesario para dibujar.

## Comprobación

- Varias apps a la vez: dos terminales (misma app, dos instancias), una app pesada
  (GTK) y una liviana; verificar segmentos distintos y, si aplica, el caso
  «misma app colapsada» documentado.
- **RAM libre escasa**: con poca memoria disponible, comprobar que la señal
  mantiene su escala declarada y que texto/contorno siguen legibles.
- **Sin dato**: abrir una ventana no gestionada cuyo PID se desconoce → estado
  desconocido, sin barra falsa.
- **Estabilidad**: observar una app activa ~60 s sin oscilación ni redibujo continuo.
- Resolución 1280×720 y equipo de baja resolución; teclado y movimiento reducido.
- Las pruebas automáticas sólo pueden validar el muestreo/atribución; la validación
  visual es manual, con capturas antes de declararla terminada.

## Límites de este corte

Sin implementación. No tocar `/proc` de otros usuarios ni introducir privilegios.
Conservar las modificaciones existentes del árbol. No hacer commit ni push.

## Referencias

- [Sugar HIG — The Laptop Experience (Home / Zoom Metaphor)](https://wiki.sugarlabs.org/go/Human_Interface_Guidelines/The_Laptop_Experience)
  (descripción del anillo y la memoria, verificada en la fuente oficial).
- Locales: `SPEC-sugar-home-visual.md`, `shell/shell.gd` (`_draw_home`, `_ppid`),
  `shell/sysmon.gd` (patrón `/proc` a 1 s), `shell/apps.gd`,
  `/home/icarito/Proyectos/SugarLabs/sugar-next/sugar_next/shell/ring_layout.py`,
  `.../app_state.py` (abierto/enfocado), `.../app_ordering.py` (favoritos vs. activos),
  `/home/icarito/Proyectos/SugarLabs/sugar-next/HIG.md`.
