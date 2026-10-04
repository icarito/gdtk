---
name: iterative-list-hacking
description: Workflow de pulido iterativo de gdtk cuando Sebastián va soltando observaciones/items de a uno y no quiere listas largas. Usar cuando el pedido llegue como una lista incremental de observaciones ("otra cosa...", "una observación...", "sigamos con el polish"), cuando haya que planear antes de tocar código, o cuando haya que despachar varios items en paralelo a subagentes y desplegar a bastion/tengu/cupid. Cubre: consolidar el plan, preguntar solo lo que bloquea, anclar cada item a archivos reales, repartir por clusters sin solape (subagentes Kilo), sync a ~/gdtk + deploy.sh, y documentar el estado para retomar con contexto fresco.
---

# Iterative list hacking (gdtk)

> Copiado y adaptado de Odisea (`Odisea_Game/odisea-imgui/.agents/skills/iterative-list-hacking`).
> Reglas del repo en `AGENTS.md` (prevalecen).

Workflow para las sesiones de pulido en las que el usuario **no da una spec**: suelta observaciones
de a una, espera que las ordenes en un plan, que preguntes lo mínimo, y que ejecutes en tandas que
él prueba **en la sesión gdtk real (bastion, tengu, cupid)**. El usuario puede volver con **contexto fresco**, así que el
estado tiene que quedar documentado en disco, no en el chat.

## Regla de oro
Cada respuesta del usuario puede traer 1..N items nuevos **sin relación**. No implementes al bote:
**consolidá en un plan numerado (A, B1..Bn), anclá cada item a archivos reales, y recién ahí ejecutá.**
Si el usuario dice "modo planear", NO toques código: devolvé plan + decisiones abiertas.

## Ciclo
1. **Capturar**: transcribí cada observación como item con su síntoma/pedido, sin inferir la solución.
2. **Anclar**: `rg`/`read` para ubicar archivos, nodos, uniforms, funciones y tests reales. Nunca
   propongas cambios sin citar `archivo:línea`.
3. **Planear**: numerá (A, B1..), agrupá por afinidad de archivo y proponé enfoque + riesgo.
   Marcá las decisiones que **bloquean** y preguntalas (una sola pasada, con opciones).
4. **Repartir**: asigná cada cluster a un subagente **con archivos disjuntos**. Los items que tocan
   el mismo archivo van al mismo agente o se serializan. Documentá el ownership map.
5. **Verificar**: cada subagente corre solo sus tests puntuales (tests GDScript de AGENTS.md) y reporta
   archivos/diff/test/blocker. No commitear.
6. **Entregar** (sólo si el usuario lo pide): `rsync -a --exclude '.import' shell settings session ~/gdtk/`,
   `./deploy.sh` a tengu y cupid (+ bastion), verificar md5; commit sólo con pedido explícito.
7. **Documentar**: actualizar el doc de sesión (`.operator-shared/sessions/`) con hechos, estado y pasos
   exactos para retomar.

## Cuándo delegar (y cuándo no)
Delegar tiene costo (arranque en frío del subagente, más contexto, más ida y vuelta). **Hacelo vos**
cuando:
- es un **one-liner** o un fix de parámetro (p. ej. el `loop` de un `.ogg`, un umbral, un tinte);
- toca **1 archivo** y lo resolvés en un par de tool calls;
- es una edición puntual que ya sabés dónde va (no requiere anclaje/investigación).

**Delegá** cuando el item:
- toca **varios archivos/subsistemas** (o requiere el skill de bake);
- es **paralelizable** con otros (clusters con archivos disjuntos);
- necesita **investigación** o verificación extensa, o es un cambio grande con tests propios.

Regla: el subagente se justifica por aislamiento de contexto y paralelismo, **no por cada minucia**.
Y no dupliques: si ya lo asignaste a un agente, no lo hagas en paralelo.

## Modo despachador (preferencia de Sebastián, 2026-09-26)
Cuando la sesión arranca en este modo, el lead (Claude Opus) **casi no implementa**: planea, ancla,
escribe briefs y revisa. Solo hace él lo trivial (one-liners). Escalera de ejecutores:

| Dificultad | Ejecutor | Cómo |
|---|---|---|
| Simple / mecánico | subagente Sonnet | `Agent` con `subagent_type: executor` (o `model: sonnet`), en background |
| Normal, con plan claro | DeepSeek 4.1 Flash vía Kilo | `kilo run -m kilo/deepseek/deepseek-v4.1-flash --format json "<brief>"` |
| Difícil | GLM 5.3 Flash vía Kilo | `kilo run -m kilo/z-ai/glm-5.3-flash --format json "<brief>"` |

- A Kilo se le da un **buen plan**: archivos:línea, enfoque, lo ya descartado, criterio de hecho, y
  "no correr tests ni commitear". No pipear su salida por `tail`; que `kilo run` retorne no significa
  que terminó (la sesión sigue viva). Correrlo en background.
- **Sin tests mientras se mueve todo**: el objetivo de la sesión es avanzar muchos temas; no se corren
  tests por item. Cuando un tema queda **más o menos estable**, despachar un agente aparte (Sonnet)
  que lo deje listo para CI: correr sus tests puntuales, alinear/crear tests, y reportar.
- Gotchas de `kilo run`: (a) lanzar varios en el mismo segundo rompe su DB local (espaciar ~10 s);
  (b) en modo no interactivo rechaza leer fuera del repo y la corrida se corta: no referenciar
  archivos del scratchpad en el brief (copiar lo necesario dentro del repo o describirlo en el doc);
  (c) para retomar: `kilo run --session <id> "<seguimiento>"` (id en la primera línea del jsonl).
- Archivos disjuntos entre agentes concurrentes sigue siendo obligatorio (Kilo y subagentes comparten
  el árbol).

## Loop vivo mientras corren los agentes (no dormirse)
El usuario **no ve** a los subagentes: el chat es la única ventana. Delegar no es soltar y esperar;
es seguir conduciendo. Mientras corren:

- **Comentá en el chat** qué va haciendo/descubriendo cada agente, en updates cortos (qué archivo,
  qué hallazgo, qué blocker). No narres cada tool call ni repitas estado sin cambios.
- **Seguí recibiendo items**: cada observación nueva se captura, se ancla (`archivo:línea`) y se
  suma al plan sin cortar la tanda en curso. Re-evaluá el ownership map: si el item toca un archivo
  ya asignado, va al **mismo** agente o se serializa; si es archivo nuevo, cluster nuevo.
- **No bloquees el turno esperando**: los subagentes son background; avanzá con anchoring, con los
  items nuevos o con otro cluster mientras corren.
- **Reportá hitos**: agente terminó, test verde/rojo, descubrimiento que cambia el plan, blocker.
  Ajustá el plan y avisá; un blocker de un agente no frena a los demás (resolvelo o repartilo).
- Al cerrar la tanda: integrá diffs, corré los tests cruzados y contá qué quedó y qué falta.

## Devolución: lista breve de qué probar
Cada vez que cerrás una tanda, **cerrá con una lista corta y accionable de qué probar**. No es un
resumen del diff: es qué hacer con las manos y qué debería pasar. Formato sugerido, un ítem por
observación, con el estado en que se prueba:

- **Qué**: la acción concreta (p. ej. "START en pausa pasiva y dejar orbitar").
- **Dónde**: host (bastion / tengu / cupid), orientación (landscape/portrait), touchpad/teclado.
- **Esperado**: el comportamiento observable que confirma el fix.
- Marcá lo que **no** se puede validar headless (visual, feel, touch real, mando) para que el usuario
  lo pruebe él. Separalo por plataforma cuando aplique.

## Reglas gdtk (resumen de AGENTS.md)
- Editar sólo en el repo `~/Proyectos/gdtk`; `~/gdtk` es la instalación (se pisa con rsync).
- **No** recargar/reiniciar el shell principal mientras aloje VS Code/Kilo: tratarlo como destructivo.
  Probar en tengu/cupid o en instancia anidada aislada.
- Nunca `class_name` de una clase nativa (`RemoteInput`, …).
- Vocabulario visible: SPEC-ui-rework-2026-10 "Vocabulario de producto" (nunca gvd/deskflow/hid/…).
- Lógica pura en `extends Reference` + test `extends SceneTree`; nada de procesos/I/O en `_draw`/`_process`.

## Kilo en gdtk (preferencia del usuario)
- Delegar a Kilo `kilo/deepseek/deepseek-v4.1-flash`, **en paralelo**, adjuntando al servidor de la
  extensión de VS Code para que se vean en vivo: `kilo run --attach http://127.0.0.1:4096 --dir
  ~/Proyectos/gdtk --agent code -m kilo/deepseek/deepseek-v4.1-flash --auto --title "<item>" "<brief>"`
  (contraseña `KILO_SERVER_PASSWORD` del environ del listener :4096, sólo en memoria).
- Tareas chicas (las grandes cuelgan); vigilar `pgrep -af 'kilo run'` y matar colgados por PID.
- Atajo: `tools/kilo-launch.sh <titulo> <brief.txt> &` (lee la contraseña, valida que el server esté en el
  repo, agrega la nota anti-"board", log en /tmp/kilo-gdtk/<titulo>.jsonl). Briefs modelo: `.operator-shared/briefs/`.
- Kilo ofrece `board_read/board_post`: con `kilo run` cada sesión está sola como `main` y postear falla;
  decirle que no lo use.
- Los `kilo run` mueren si se cierra Claude Code: al retomar, verificar por tests + `git diff`.
- Sesión en curso más reciente: ver el último `.operator-shared/sessions/*.md`.

## Tests (local, puntual)
```sh
cd ~/Proyectos/gdtk
/home/icarito/Proyectos/godot3-box3d/godot-dev/bin/godot.frt.opt.tools.x86_64.gdtk \
  --no-window --path shell -s $PWD/tests/<test>.gd
tools/verify_all.sh
```
Scripts con clases nativas (`shell.gd`, `frame.gd`): validar parseo con `~/gdtk/bin/godot-gdtk`.

## Pitfalls aprendidos (Godot 3)
- `var x := <export/float>` falla: GDScript 1.x no infiere tipo desde un export. Usá `: float`/`: int`.
- Los `.tscn` tienen overrides heredados (`[node name="X" parent=... index="0"]`): si cambiás el tipo
  del nodo en la escena base, hay que **limpiar las props de las hijas** o el setter tira error.
- Componentes que exponen `emitting` (setget) mantienen compat con consumidores que hacían
  `node.emitting = ...` (ej. CPUParticles → haz).
- Al reemplazar un `CPUParticles` por un `Spatial`, guardá los flujos que setean props de partículas
  (`local_coords`, `randomness`, `spread`, `restart()`), p. ej. `if not (node is CPUParticles): return`.

## Docs
- Sesión: `.operator-shared/sessions/YYYY-MM-DD_<tema>.md` (estado, hechos, decisiones, próximos pasos).
- Specs: `SPEC-*.md` en la raíz; handoffs `HANDOFF-*.md`.
