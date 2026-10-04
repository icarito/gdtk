# Guía — Iterar, recargar y recuperar sin perder ventanas

Esta guía operacionaliza `SPEC-session-continuity.md`. **Recargar** reemplaza la UI
GDScript dentro del proceso actual. **Reiniciar** termina `godot-gdtk`, destruye el
compositor embebido y desconecta sus aplicaciones.

## Qué operación corresponde

| Cambio | Operación | Conserva apps internas |
|---|---|---|
| `shell.gd`, `frame.gd`, applets y módulos con `Host.sc` | sync + *Recargar el shell* | Sí, tras activar C1 una vez |
| `main.gd`, `host.gd`, `project.godot`/autoloads | sync + próximo login/corte controlado | No durante la primera activación |
| `modules/`, fork Godot o binario | recompilar + corte controlado | No |
| scripts `session/` consumidos por procesos nuevos | sync; entran en el próximo arranque | N/A |

Nunca usar `restart_shell`, `recovery.restart()`, matar Godot o reiniciar sway para un
cambio GDScript ordinario. El supervisor recupera fallos; no es el bucle de desarrollo.

## Flujo seguro de scripts

1. Editar y probar sólo en `~/Proyectos/gdtk`.
2. Correr los tests del área.
3. Para prueba visual usar `tools/run-isolated-shell.sh`, tras confirmar que los
   consumidores relevantes honran `GDTK_ISOLATED=1`. El lanzador aísla XDG, store,
   puertos, D-Bus y neutraliza el `pkill` global del supervisor.
4. Sincronizar:

   ```sh
   cd ~/Proyectos/gdtk
   rsync -a --delete --exclude '.import' --exclude '*crash*' shell settings ~/gdtk/
   rsync -a session ~/gdtk/
   ```

   No copiar `tools/` completo a mano: `deploy.sh` excluye/recompila helpers gvd según
   la ISA del host. Las herramientas de desarrollo se ejecutan desde el repo.

5. Si sólo cambió UI recargable y la instalación ya incluye C1, usar una sola vez menú
   central → *Recargar el shell*. El candidato se compila e instancia antes de retirar
   el activo; un error conserva la UI anterior.
6. Si cambió `Host`, `main.gd` o el motor, no activar desde una sesión que aloja el
   editor/agente. Guardar y cerrar clientes; activar en el próximo login o corte.

## Salud y rollback

`Host` escribe `$XDG_RUNTIME_DIR/gdtk/health.json` aproximadamente a 1 Hz. El
supervisor sólo promueve `last_good` si observa el PID correcto, `reload=ready` y al
menos dos avances de `sequence`; un PID meramente vivo no cuenta como sano.

```sh
~/gdtk/session/gdtk-version status
~/gdtk/session/gdtk-health probe "$(cat "$XDG_RUNTIME_DIR/gdtk-shell.pid")"
```

Estados `absent`, `wrongpid`, `stale` o `invalid` no promueven. Por defecto un cuelgue
sólo se reporta; matarlo automáticamente requiere `GDTK_HEALTH_KILL_HUNG=1` en el
entorno del supervisor. `last_good` protege contenido, no el binario.

## Governor de energía sin diálogo

Se provisiona una vez por host:

```sh
sudo ~/gdtk/session/gdtk-governor-provision install
~/gdtk/session/gdtk-governor-provision status
```

La action permite únicamente una sesión local activa; el helper valida el governor y
escribe todas las policies. El shell usa `--disable-internal-agent`: si falta provisión
o autorización, falla sin abrir un diálogo incontrolable. El menú muestra `aplicando`
hasta observar el valor real.

Para retirar la integración:

```sh
sudo ~/gdtk/session/gdtk-governor-provision remove
```

## Diagnóstico

- Logs: `~/.local/state/gdtk/{supervisor.log,shell.log,shell.prev.log}`.
- Contenido: `~/gdtk/session/gdtk-version status`.
- Policy: `pkaction --action-id org.gdtk.governor.set --verbose`.
- No probar recuperación contra la sesión viva: `tests/version_store_test.sh` usa
  runtime temporal y un `pkill` falso para no tocar Deskflow.
