# SPEC — Governor de CPU desde el DockApp de energía

## Problema

El DockApp hoy intenta escribir `scaling_governor` y, si falla, ejecuta
`pkexec sh -c 'echo … > sysfs'`. Eso tiene tres defectos:

- abre un diálogo de autenticación en el compositor anfitrión, inaccesible desde
  Deskflow en algunos equipos;
- entrega una shell a un camino privilegiado;
- la UI afirma éxito antes de volver a leer el estado real.

Cambiar el governor es una acción explícita del usuario, pero no debe requerir una
interacción fuera del shell ni aceptar comandos arbitrarios.

## Modelo de autorización

Se instala un helper root-owned, pequeño y auditable, en una ruta absoluta estable.
Una acción PolicyKit dedicada referencia exactamente esa ruta con
`org.freedesktop.policykit.exec.path`.

Defaults:

```xml
<allow_any>no</allow_any>
<allow_inactive>no</allow_inactive>
<allow_active>yes</allow_active>
```

Así sólo una sesión local activa obtiene autorización implícita. La action no usa
`allow_gui`. El cliente invoca `pkexec --disable-internal-agent`, de modo que una
configuración ausente o una sesión no autorizada falla sin abrir diálogo gráfico o
agente textual.

PolicyKit selecciona la acción por la ruta del programa, pero `pkexec` no valida sus
argumentos. Por eso toda la seguridad de parámetros vive también en el helper.

## Helper privilegiado

Interfaz única:

```sh
/usr/libexec/gdtk-set-governor <governor>
```

Contratos:

1. Exactamente un argumento; token ASCII estricto `[A-Za-z0-9_-]+`.
2. El valor debe aparecer como palabra completa en al menos un
   `scaling_available_governors` del kernel.
3. Escribe cada `/sys/devices/system/cpu/cpufreq/policy*/scaling_governor`; si no
   existen policies usa `cpu0/cpufreq/scaling_governor`.
4. No usa `eval`, `sh -c`, globs derivados del argumento ni rutas suministradas por el
   usuario.
5. Verifica cada escritura leyendo el valor. Una policy que falle produce rc no cero;
   no se anuncia éxito parcial.
6. Diagnóstico corto por stderr, sin secretos ni contenido arbitrario.

Para tests, una variable de root sysfs sólo se acepta cuando el helper detecta un modo
de prueba explícito y no está ejecutándose privilegiado. En ejecución root siempre usa
`/sys` real.

## Cliente y estados

`sysmon.gd` no cambia `governor` anticipadamente. El resultado visible es una máquina
de estados:

```text
idle → applying → verified
                 ↘ error | unavailable | not_provisioned
```

- `applying`: se lanzó el helper y se espera observación.
- `verified`: el muestreo posterior leyó el governor solicitado.
- `error`: el proceso terminó/fue observable pero sysfs no alcanzó el valor dentro del
  timeout.
- `not_provisioned`: no existe helper/policy instalada; mostrar instrucción accionable.
- `unavailable`: el kernel no ofrece governors.

La UI sólo muestra check sobre el valor leído de sysfs. La acción es no bloqueante y el
muestreo normal resuelve éxito/error; nunca se espera dentro del frame.

## Predeterminado

“Predeterminado” significa el governor observado al iniciar el módulo en esa sesión,
no un nombre inventado. Si deja de estar disponible, la opción se deshabilita. El menú
ofrece todos y sólo los governors publicados por el kernel, normalmente incluyendo
`powersave`, `schedutil` y/o `performance` según el driver.

## Provisión

Un script explícito instala, con `sudo`, helper 0755 root:root y policy 0644 root:root.
Ni `deploy.sh` ni el shell lo ejecutan automáticamente. El deploy sólo copia artefactos
a `~/gdtk/session/`; el operador decide provisionar cada host.

El provisionador soporta `status`, `install` y `remove`; `status` no requiere cambiar
estado. Tras instalar valida la action con `pkaction` si está disponible.

## Verificación

- Modelo puro: allowlist, argv y transiciones `applying/verified/error`.
- Helper sobre sysfs falso no privilegiado: rechaza inyección y governor ausente,
  actualiza todas las policies y falla ante escritura parcial.
- Ningún test ejecuta `pkexec`, `sudo`, escribe `/sys` real ni abre un agente.
- Parseo de `sysmon.gd` con Godot 3.

## Fuentes primarias

- PolicyKit `pkexec(1)`: selección de action por `exec.path`, ausencia de validación de
  argumentos y `--disable-internal-agent`.
- PolicyKit `polkit(8)`: actions, `allow_any`, `allow_inactive`, `allow_active` y valores
  de autorización implícita.

