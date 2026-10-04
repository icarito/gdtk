# SPEC — Frame de bloques cuadrados Sugar / NeXT

Estado: dirección visual para el siguiente prototipo. Sólo diseño; sin implementación
en esta entrega. No reemplaza el primer corte de numeración y orden de
`SPEC-sugar-spatial.md`; el layout sigue saliendo de `shell._units()` y el Frame no
guarda una segunda copia.

## Idea

El Frame actual es una barra de títulos. Aquí pasa a ser una retícula de bloques
cuadrados, superpuesta y retráctil. Window Maker/NeXT aporta el bloque compacto
(ícono, identidad, estado y lugar; su «Clip» es un dock propio del workspace con
pager). Sugar aporta los cuatro bordes con función y la activación por esquina.
Un bloque comunica identidad y estado aunque el título no quepa; el nombre completo
aparece al enfocar o pasar el puntero. La retícula nunca cubre la actividad de forma
permanente.

## Dos clases de bloque

| Clase | Representa | Al arrastrar | Al soltar | Teclado |
|---|---|---|---|---|
| **Bloque de ventana** | Una ventana concreta | Mueve **su** ventana por el workspace (reordena la franja de pantallas) | Sobre otro bloque de ventana: agrupa en una pantalla partida. En un hueco: reordena. Fuera del grupo: le devuelve una pantalla | Mismas operaciones: mover, agrupar, separar |
| **Bloque de control/applet** | Un control del propio Frame | Cambia su **orden** o su **borde**; nunca mueve ventanas | Se reubica en el borde señalado | Mover, fijar, ocultar, reordenar |

Un grupo tileado se mueve entero sólo con una acción explícita sobre su marca de
pantalla; arrastrar una caja mueve **la ventana elegida**, no las demás.

## Los cuatro bordes y la activación

- **Arriba — lugares/escala:** Actividad, Hogar y, más adelante, Grupos y Vecindario.
  El lugar actual queda marcado; la fila de pantallas dentro de Actividad conserva
  su numeración.
- **Izquierda — objetos/memoria:** Portapapeles y Diario; un recurso reciente viaja
  entre actividades.
- **Derecha — personas/equipos:** colores XO para personas; Deskflow como equipo
  conectado (nunca como persona).
- **Abajo — acciones:** actividades abiertas o fijadas, invitaciones y avisos.
- **Esquina activa:** superior izquierda + borde superior revelan el Frame; la
  esquina no lleva botones. Se oculta con Esc; F6/Super alternan como hoy. El foco de
  teclado recorre las celdas en orden predecible y no queda atrapado.

## Controles y applets

- La persona puede **fijar, ocultar y ordenar** cada control (menú contextual del
  bloque y equivalente por teclado); un control oculto no ocupa celda.
- **CPU y memoria:** applets **optativos** con medición global ya disponible en
  `shell/sysmon.gd`. El anillo de Hogar puede mostrar memoria por instancia cuando
  exista atribución real (`SPEC-sugar-resource-ring.md`). Sin dato, marca explícita.
- **Wi-Fi:** se explora en Vecindario; en el Frame sólo un enlace de **estado**
  (conectado / sin red), no la lista de redes.
- **Bluetooth y teclado:** controles del Frame (encender/apagar; distribución y
  atajos), no ventanas.

## Reglas de gestos

1. Arrastrar un bloque de ventana **mueve su ventana**; se marca el destino y se
   previsualiza el resultado.
2. Soltar sobre otro bloque de ventana **agrupa** (tile); soltar en un hueco
   **reordena**; sacar del grupo **separa**.
3. Arrastrar un bloque de control **reordena o cambia de borde**; no mueve ventanas.
4. **Esc cancela** el arrastre; soltar fuera de un destino válido conserva el layout.
5. Dentro de un grupo tileado se arrastra la ventana elegida; el grupo entero sólo
   con su marca de pantalla.
6. Clic derecho u homólogo de teclado abre el menú del bloque: fijar, ocultar,
   reordenar, y en ventanas: cerrar, minimizar, agrupar.

## Mockup textual a validar

800×600 (Tengu), celda cuadrada ≈56 px, Frame revelado:

```
┌──────────────────────────────────────────────────────────────────┐
│ ▒▒ esquina activa (libre)                                        │
│ [⌂ Hogar] [✱ Actividad•] [◍ Vecindario]     [1][2][3] ◀▶ «tarea» │ ← arriba: lugares
│                                                                  │
│ [⎘ Portapapeles]                      [◑ Iván]  [◑ Ana]          │ ← izq: objetos
│ [▤ Diario ⌐ informe.txt]              [▣ Tengu · Deskflow ✓]     │   der: personas/equipos
│                                       [📶 Red: Vecindario ▸]     │
│                                                                  │
│      ┌────────────────┐ ┌────────────────┐                       │
│      │ ▪1  Terminal   │ │ ▪1  Navegador  │  pantalla 1 tileada   │
│      └────────────────┘ └────────────────┘                       │
│      ┌──────────────────────────────────────┐                    │
│      │ ▪2  Editor                           │  pantalla 2        │
│      └──────────────────────────────────────┘                    │
│                                                                  │
│ [▤ Terminal] [▤ Navegador] [▤ Editor] [✉1]    [⚙ Bluetooth][⌨]   │ ← abajo: acciones
│                                                [◔ CPU][▥ RAM]    │   applets optativos
└──────────────────────────────────────────────────────────────────┘
```

Controles elegidos: pager `1 2 3` (+ nombre del workspace) arriba a la derecha;
`Wifi: estado` en el borde derecho; `Bluetooth`, `Teclado`, `CPU` y `RAM` abajo a la
derecha (CPU/RAM optativos, hoy ocultables). Tres ventanas: Terminal y Navegador
comparten la pantalla **1**; Editor vive en la **2**. Deskflow aparece como equipo
conectado y `informe.txt` es la entrada reciente del Diario.

## Aceptación visual

- Sin leer texto, se distingue: qué bloque lleva a Hogar, qué dos comparten pantalla,
  qué equipo está conectado y dónde se recupera el trabajo.
- Arrastrar una caja entre dos pantallas mueve su ventana al lugar señalado;
  soltarla sobre otra muestra ambas en la misma pantalla; Esc restaura el orden.
- Un control se fija, se oculta y se reordena, y eso persiste; el oculto no deja
  hueco ni desplaza la retícula.
- Las celdas siguen cuadradas (no se estiran), la esquina queda libre y el Frame no
  tapa la actividad de forma permanente.
- Cerrar y minimizar siguen siendo claros; el bloque de ventana refleja ambos estados.
- Probar con mouse, teclado y a 800×600 (Tengu) y 1280×720 antes de declararla lista.
  Las pruebas automáticas sólo validan estado.

## Límites de este corte

Sin implementación. No tocar otros archivos ni código. Conservar las modificaciones
existentes del árbol. No hacer commit ni push.

Referencias: [Sugar HIG: The Frame](https://wiki.sugarlabs.org/go/Human_Interface_Guidelines/The_Laptop_Experience/The_Frame),
[Window Maker: Clip](https://www.windowmaker.org/docs/guidedtour/clip.html),
`SPEC-sugar-spatial.md`, `SPEC-sugar-resource-ring.md`, `shell/frame.gd`.
