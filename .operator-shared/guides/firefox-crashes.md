# Firefox: diagnóstico y mitigación de crashes (2026-10-07)

## Evidencia y límite del diagnóstico

En bastion, 26 reportes locales de Firefox 157.0 (CachyOS x86_64_v4,
build `20260930001005`) repiten `libxul.so+0x4dd53a9` seguido de
`+0x858a539`. El último minidump identifica el hilo **Renderer** del proceso
padre, con `rax=0xe5e5e5e5e5e5e5e5` en `call *0x50(%rax)`: vtable de un
objeto liberado. Hay reportes con hasta 16,2 GiB de memoria física disponible;
no se puede explicar esta serie únicamente por falta de RAM.

El desensamblado, las relocaciones de GTK y el literal de logging identifican
`ScreenHelperGTK::GetGTKMonitorFractionalScaleFactor()`. Lee
`ScreenManager::CurrentScreenList()[0]->GetContentsScaleFactor()`; llega desde
`WaylandSurface::GetScale()` cuando la surface no tiene escala ni padre.
Es un UAF en el camino de escala/monitores de Firefox, **no evidencia de un
fallo del decoder de video ni de Gallium**. El origen exacto de la carrera
y el evento del compositor que la precipita aún no están aislados.

Fuentes primarias para contrastar el flujo (el main upstream puede cambiar):

- [ScreenHelperGTK.cpp](https://github.com/mozilla-firefox/firefox/blob/main/widget/gtk/ScreenHelperGTK.cpp)
- [WaylandSurface.cpp](https://github.com/mozilla-firefox/firefox/blob/main/widget/gtk/WaylandSurface.cpp)

Hay otra familia de reportes con `MozCrashReason` indicando pérdida del
compositor / tubería rota. Son distintos del UAF y se correlacionan por separado
con la vida del shell. El warning GTK de subsurfaces no prueba por sí solo la
causa de ninguna de las dos familias.

Los símbolos de este build no están disponibles en el servicio de Mozilla
(`found_modules=false` para libxul) ni en el endpoint de CachyOS (404). No enviar
minidumps completos para resolverlo: basta con build IDs y offsets para consultar
símbolos; los dumps contienen información privada.

## Reportes upstream: coincidencia pendiente

La búsqueda pública no identificó un ticket con esta firma exacta.
[Bug 2027302](https://bugzilla.mozilla.org/show_bug.cgi?id=2027302) documenta
un UAF de `Screen` por refcount concurrente desde Workers/OffscreenCanvas,
corregido en Firefox 151. Es antecedente, no identificación de este crash en
157 (hilo Renderer y getter de escala). No presentar los bugs de popups,
monitores de tamaño cero o tubería rota como el ticket de este UAF.

## Mitigación opt-in

`session/gdtk-firefox` selecciona `GDK_BACKEND=x11` y `MOZ_ENABLE_WAYLAND=0`
cuando `XDG_CURRENT_DESKTOP` contiene `gdtk`. Firefox usa el Xwayland embebido
que `WaylandCompositor.launch()` ya suministra mediante `DISPLAY`. Esto evita
la rama Wayland identificada. Conserva argumentos, perfil y preferencias de
WebRender/VA-API; la aceleración efectiva se verifica con `about:support`.
Fuera de gdtk deja intacto el entorno. No añade `--no-remote`: una instancia
nativa ya abierta debe cerrarse normalmente antes de cambiar de backend.

La instalación del helper por sí sola no modifica el launcher de Firefox.
En el host que opta por la mitigación, crear un override de `firefox.desktop`
en el directorio XDG del usuario, copiando el del sistema y sustituyendo sus
cuatro `Exec` por el helper instalado (incluidas sus acciones). Conservar icono,
MIME types, flags y localizaciones. Respaldar cualquier override previo.
No alterar el `.desktop` del sistema ni el perfil. `deploy.sh` distribuye el helper,
pero no aplica el override en otros hosts.

La grilla de apps del shell cachea los `.desktop`: un override nuevo entra en
el siguiente escaneo/recarga. Mientras tanto usar directamente el helper
instalado. No recargar la tanda de /polish ajena para aplicar este workaround.
`firefox` ejecutado directamente no pasa por este helper.

Para comparar con el backend original, ejecutar el helper con
`GDTK_FIREFOX_NATIVE_WAYLAND=1`. Para deshacer la política del icono, restaurar
el override previo o retirar sólo el override creado para esta mitigación.

## Activación: comprobación obligatoria

El crash del 2026-10-07 a las 21:38:25, posterior a instalar el override,
repite `+0x4dd53a9` y declara `IsWayland=1`. El proceso reabierto también
hereda `GDK_BACKEND=wayland`, sin `MOZ_ENABLE_WAYLAND=0`: el launcher usado
seguía siendo el nativo (compatible con el caché de la grilla). Este evento
no constituye una prueba de fallo de la mitigación por Xwayland.

Instalar el override no significa activarlo. Cerrar Firefox normalmente antes
de arrancar el helper desde una Terminal del compositor embebido o con el RPC
`launch` apuntando al helper. Verificar en el proceso principal real
`GDK_BACKEND=x11`, `MOZ_ENABLE_WAYLAND=0` y `DISPLAY` del Xwayland embebido.
Nunca imprimir el entorno completo ni cerrar el navegador durante una llamada.
Un launcher alternativo con ID distinto y nombre «Firefox (Xwayland)» permite
seleccionar el camino explícito después del próximo escaneo de apps.

El siguiente arranque solicitado por el usuario sí quedó verificado en el
proceso real: `GDK_BACKEND=x11`, `MOZ_ENABLE_WAYLAND=0`, `DISPLAY=:0`.
La mitigación está activada; todavía falta la observación de estabilidad prolongada.

## Verificación y siguiente paso

Pruebas del launcher: gdtk, escritorio ajeno, lista de escritorios, opt-out y
argumentos con espacios conservados; `sh -n` y `desktop-file-validate` pasan.
Prueba real en el compositor vivo con perfil temporal: canvas/WebGL y video
de `canvas.captureStream()` enviado por un par WebRTC local. No usa cámara,
micrófono, servidores de reuniones ni perfil del usuario. No reinicia el shell. El helper instalado pasó 90 s con 88 muestras continuas:
5.286 frames de canvas y 1.988 frames WebRTC decodificados, WebGL activo y
cero minidumps. Una prueba preliminar de otros 90 s tampoco tumbó el proceso.

Una prueba corta sin crash sólo verifica que el camino alternativo funciona;
no certifica estabilidad de reuniones largas, captura de pantalla ni VA-API.
Observar las siguientes sesiones y comparar nuevas firmas antes de declarar
resuelto. Para retomar el fix nativo, revisar la entrega de escala/`wl_surface.enter`
a surfaces tardías y los cambios de outputs, capturando sólo una instancia de
prueba con `MOZ_LOG=WidgetScreen:5,WidgetWayland:5` y, si hace falta, `WAYLAND_DEBUG=1`.
Los logs de protocolo deben quedar privados: pueden contener texto del usuario.
