# SPEC — Instancia de desarrollo anidada y aislada

## Objetivo

Probar scripts y recargas del shell en una instancia descartable sin compartir
sockets, tokens, locks, estado, store, logs ni procesos con la sesión gdtk activa.
Sin este aislamiento, “probar” puede tomar el puerto 7777, publicar otro portal o
terminar servicios de la sesión del usuario.

## Interfaz

Nuevo lanzador `tools/run-isolated-shell.sh`:

```sh
tools/run-isolated-shell.sh [--keep] [--no-supervisor] -- [argumentos Godot]
```

Por defecto usa el binario dev documentado en `AGENTS.md`; `GDTK_GODOT` permite
sobrescribirlo. No instala, sincroniza, despliega ni toca `~/gdtk`.

## Aislamiento obligatorio

Cada corrida crea un directorio con `mktemp -d` y define dentro de él:

- `XDG_RUNTIME_DIR` con modo 0700;
- `XDG_STATE_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`;
- `GDTK_STORE`, logs, pidfiles y locks;
- `GDTK_CONTROL_PORT` y `GDTK_PEER_PORT` libres, distintos de 7777/7788;
- token y socket Wayland internos propios;
- `GDTK_ISOLATED=1` para que componentes con integración global puedan abstenerse.

No debe heredar archivos runtime de producción. El lanzador no usa `pkill`, no mata
procesos por nombre y sólo termina el process group/PIDs que creó.

## Integraciones globales

Con `GDTK_ISOLATED=1`:

- `Host` no registra el backend global de portal/EIS salvo opt-in explícito;
- los servicios automáticos (Deskflow, publicación LAN y similares) no arrancan;
- remote/peer pueden arrancar sólo en los puertos aislados;
- configuración y estado se leen de los XDG temporales, no del usuario.

El objetivo es probar UI, adopción de ventanas, parsing y recarga. Las pruebas de
portal/EIS requieren un modo e2e separado y explícito.

## Ciclo de vida

- Imprime al inicio directorio temporal, PID y puertos, sin imprimir tokens.
- Señales `INT`, `TERM` y `EXIT` limpian únicamente recursos propios.
- Por defecto elimina el árbol temporal al salir; `--keep` lo conserva y muestra su
  ruta para diagnóstico.
- Un segundo lanzador puede correr simultáneamente sin colisiones.

## Verificación

Un test shell debe usar dobles inocuos para comprobar:

1. dos preparaciones producen rutas y puertos distintos;
2. ninguna ruta resuelve al `XDG_RUNTIME_DIR` original;
3. permisos runtime son 0700;
4. cleanup no borra un archivo centinela exterior;
5. `--keep` conserva artefactos;
6. argumentos después de `--` llegan intactos al ejecutable doble.

La verificación automatizada no abre ventanas ni toca la sesión principal.

