# SPEC — Continuidad de sesión, recarga transaccional y salud

## Propósito

Permitir iterar sobre el shell sin cerrar las aplicaciones del usuario y hacer que la
recuperación automática distinga un proceso vivo de una sesión sana. Esta spec no
promete que las aplicaciones sobrevivan a un cambio del binario: hoy el compositor
Wayland embebido y la UI comparten el proceso `godot-gdtk`.

## Garantías y límites

| Cambio o fallo | Garantía requerida |
|---|---|
| Error de parseo/compilación GDScript | El shell anterior continúa visible y usable. |
| Error al construir el shell candidato | El shell anterior continúa; se registra diagnóstico. |
| Recarga GDScript exitosa | Se conservan compositor, ventanas, layout seguro y servicios. |
| Cuelgue del event loop | El supervisor lo detecta por falta de progreso; no lo promueve. |
| Crash de GDScript/proceso | El supervisor relanza y puede usar `last_good_content`. |
| Cambio/crash del motor o `modules/` | Requiere corte controlado; fuera de esta fase. |

“Recargar” nunca significa reiniciar `godot-gdtk`. “Reiniciar” sí destruye el
compositor embebido y las conexiones de sus clientes.

## C1 — Recarga transaccional

`main.gd` mantiene dos referencias durante el handoff: `shell` (activo) y un candidato
local. El orden es obligatorio:

1. Compilar `res://shell.gd` con `Host.sc()` sin tocar el shell activo.
2. Si no compila, devolver fallo y conservar íntegro el shell activo.
3. Instanciar el candidato sin reemplazar la referencia activa.
4. Si no se puede instanciar, conservar el activo y liberar lo que corresponda.
5. Recién con candidato válido: pedir al activo `_save_layout()`, copiar
   `service_pids`, marcar `Host.live_reload`, retirar el activo, agregar el candidato,
   recablear `remote`/`peer_control` y terminar el handoff.
6. Si el handoff falla después de retirar el activo, intentar restaurarlo antes de
   considerar un reinicio del proceso.
7. Destruir el shell anterior sólo cuando el candidato fue agregado y cableado.

El resultado de `reload_shell()` debe ser `bool`. Un fallo esperado de compilación no
usa `get_tree().quit(75)`. Debe dejar un error visible/logueado y permitir corregir el
archivo para volver a intentar.

### Invariantes

- Nunca evaluar `.new()` sobre el resultado de `Host.sc()` sin comprobar `null`.
- Una recarga fallida no cambia `Host.layout`, `service_pids` ni bindings activos.
- `Host.live_reload` vuelve a `false` en todas las salidas.
- No se crean un segundo `WaylandCompositor` ni un segundo `RemoteInput`.
- La recarga sólo toma módulos declarados recargables mediante `Host.sc`; los
  `preload` de modelos puros siguen estables hasta reiniciar el proceso.

### Estados observables

`Host.reload_status` contiene al menos:

```gdscript
{"generation": 7, "state": "ready", "error": "", "changed_ms": 123456}
```

Estados: `idle`, `compiling`, `constructing`, `swapping`, `ready`, `failed`. Cada
intento incrementa `generation`. Esto es diagnóstico; no debe incluir secretos.

## C2 — Salud semántica

El shell publica un archivo atómico bajo
`$XDG_RUNTIME_DIR/gdtk/health.json`. Se escribe a un temporal y se renombra; nunca se
expone JSON parcial. Contrato mínimo:

```json
{"pid":1234,"generation":7,"sequence":91,"monotonic_ms":123456,"reload":"ready"}
```

- `sequence` sólo aumenta cuando el event loop procesa un tick de salud.
- El productor limita escrituras a una frecuencia baja (objetivo: 1 Hz).
- Al arrancar una nueva corrida se reemplaza el archivo; al salir no es necesario
  borrarlo porque el consumidor valida `pid` y frescura.
- El supervisor nunca interpreta sólo la existencia del archivo como salud.

### Promoción de contenido

`last_good` pasa a llamarse conceptualmente `last_good_content`: no certifica el
binario. Para promover el árbol vivo deben cumplirse todas:

1. El PID supervisado sigue vivo.
2. El heartbeat pertenece a ese PID.
3. `sequence` avanzó en al menos dos observaciones separadas.
4. `reload == "ready"`.
5. El contenido supera `gdtk-preflight`; `autogood` no usa `--no-check`.

Si falta heartbeat se conserva compatibilidad temporal: no se mata el proceso, pero
no se promueve automáticamente. Un proceso vivo sin progreso durante el timeout se
reporta como `hung`; la política de terminarlo queda detrás de
`GDTK_HEALTH_KILL_HUNG=1` hasta tener suficiente experiencia operativa.

Defaults configurables para pruebas: `GDTK_HEALTH_INTERVAL=1`,
`GDTK_HEALTH_TIMEOUT=8`. El supervisor debe usar intervalos cortos sólo cuando los
tests los inyecten.

## C3 — Runtime y contenido

El store actual versiona contenido pero ejecuta siempre `$BIN`. Los mensajes y
comandos deben evitar llamar “versión buena” al conjunto completo. Una fase posterior
introducirá un manifiesto de release:

```json
{"content_id":"…","runtime_id":"…","native_abi":"…","settings_schema":1}
```

Hasta entonces:

- rollback automático sólo cubre scripts/configuración;
- símbolos nativos ausentes son error de preflight para contenido que los requiere,
  no una advertencia silenciosa;
- ningún snapshot puede afirmar que recupera una regresión del motor.

## C4 — Frontera futura de procesos

La dirección deseada, si se exige sobrevivir a un crash del motor/UI, es separar:

```text
session-kernel estable: compositor + input/portal + lifecycle de clientes
shell UI reemplazable: Hogar + Grupo + Vecindario + Frame + políticas visuales
```

No se implementa sin una spec propia de IPC que cubra surfaces, buffers/DMA-BUF,
input, foco, geometría y reconexión. Antes de abrir esa fase se medirán los fallos que
no resuelven C1–C3 y se comparará contra la alternativa de usar sway como compositor
directo de las aplicaciones.

## Verificación

- Test de recarga: candidato inválido conserva el shell activo; candidato válido lo
  reemplaza una sola vez y deja `Host.live_reload == false`.
- Test de supervisor: PID vivo sin avance no se promueve; heartbeat que avanza sí.
- `tests/version_store_test.sh` usa sólo temporales y no toca la sesión real.
- Ninguna prueba recarga, reinicia o mata el shell principal.

