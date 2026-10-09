# Sesión gdtk — dependencias del autostart

`session/autostart.sh` (POSIX sh) lo invocan `gdtk-session-sway` y `gdtk-session-x11`
después de `portal.sh`; `gdtk-session` es un alias de la sesión sway. Arranca, si
están disponibles, el agente polkit, el llavero, el daemon de notificaciones y las
entradas de `~/.config/autostart/*.desktop`.

Todo es opcional y cada pieza que falte o falle sólo se anota en
`~/.local/state/gdtk/autostart.log`; nunca tumba la sesión. Es idempotente: no
relanza lo que ya corre.

## Paquetes (Debian/Ubuntu; nombres equivalentes en otras distros)

| Pieza | Paquete | Notas |
| --- | --- | --- |
| Agente polkit | `polkit-gnome` | Alternativas aceptadas: `lxqt-policykit`, `mate-polkit`, `xfce-polkit`. Sin ninguno, las apps que piden privilegios con PolicyKit no muestran diálogo. |
| Llavero | `gnome-keyring` | `gnome-keyring-daemon --start --components=secrets,pkcs11`. |
| API de secretos | `libsecret` | Lo usan las apps (no lo lanza el script); complemento del llavero. |
| Notificaciones | `python3-gi` (PyGObject + Gio) | Daemon `session/gdtk-notify serve` que posee `org.freedesktop.Notifications` y escribe `$XDG_RUNTIME_DIR/gdtk/notifications.json`; reemplaza a `mako`. Requiere `python3`. |
| Ejecutor de `.desktop` | `dex` | Opcional. Si está, el script lo usa para lanzar `~/.config/autostart` respetando `Hidden`/`OnlyShowIn`/`NotShowIn`; si no, hace el parseo y filtrado él mismo. |
| Publicación de entorno | `dbus` (`dbus-update-activation-environment`) | Necesario para que los servicios activados por D-Bus/systemd vean `GNOME_KEYRING_CONTROL` y `SSH_AUTH_SOCK`. |

## Sensores y rotación de pantalla (Surface Pro 3)

`session/sensor-hub.sh` (invocado por `gdtk-session-sway`) habilita los sensores
del Surface Pro 3 (acelerómetro, giroscopio, ALS, magnetómetro) sin reactivar el
táctil N-Trig dañado. En este equipo el sensor hub (`MSHW0030`) y el táctil
(`NTRG0001`) son ambos I2C-HID y `i2c_hid_acpi` los auto-enlaza; como cuelgan de
controladores I2C distintos, el script desbinda el controlador del táctil
(`INT33C3`, i2c-1) y recién entonces carga `i2c_hid_acpi` a mano, dejando sólo
`MSHW0030` (i2c-0). Requiere `i2c_hid`/`i2c_hid_acpi` blacklisteados (p. ej.
`/etc/modprobe.d/disable-touch.conf`) y `sudo -n`. Es idempotente y opcional.

`session/gdtk-rotate` aplica `swaymsg output '*' transform ...`: `next`/`set`
manual, `status`, y `auto` sigue `net.hadess.SensorProxy.AccelerometerOrientation`
(iio-sensor-proxy) con `hold` para pausar. `sway.conf` lo arranca en modo `auto`
sólo si hay acelerómetro. Si la orientación sale invertida, ajustar la matriz
`ACCEL_MOUNT_MATRIX` en `/etc/udev/hwdb.d/60-sensor.hwdb`.

## Compartir pantalla (Meet/Zoom) y pantallazos

`session/portal.sh` instala el routing (`~/.config/xdg-desktop-portal/gdtk-portals.conf`)
y la config del backend wlroots (`~/.config/xdg-desktop-portal-wlr/config`).
`session/sway.conf` publica `WAYLAND_DISPLAY` a los servicios D-Bus/systemd: sin eso
`xdg-desktop-portal-wlr` (xdpw) vería el compositor anidado de gdtk o un valor viejo,
no el sway donde corre el shell fullscreen.

| Pieza | Paquete | Notas |
| --- | --- | --- |
| Frontend de portales | `xdg-desktop-portal` | Necesario para todo portal. |
| Backend ScreenCast/Screenshot | `xdg-desktop-portal-wlr` | Habla `wlr-screencopy` / `ext-image-copy-capture` con sway. `ScreenCast=wlr` y `Screenshot=wlr` en `gdtk-portals.conf`. |
| Servidor multimedia | `pipewire` (+ `pipewire-pulse`) | El ScreenCast viaja por PipeWire. Debe estar corriendo. |
| Gestor de sesión PipeWire | `wireplumber` | Necesario para los nodos de PipeWire. |
| Captura CLI | `grim` (≥1.5) | `session/gdtk-screenshot` lo usa (ext-image-copy-capture con fallback a wlr-screencopy) y si falla cae al RPC `screenshot` del shell. |
| Copia de pantallazos | `wl-clipboard` (`wl-copy`) | `session/gdtk-screenshot copy` pone el PNG en el portapapeles del compositor embebido (pegable en las apps). |
| Selector de archivos | `xdg-desktop-portal-gtk` | Ya usado (`FileChooser=gtk`). |

PrintScreen lo atiende el shell (no depende del portal): abre el selector
(ventana/pantalla/selección) y guarda en `<Imágenes>/Pantallazos/` + copia al
portapapeles embebido. `Ctrl+PrintScreen` captura toda la pantalla directo.

## Governor de CPU (helper polkit)

Cambiar `scaling_governor` desde el DockApp de energía no usa shell privilegiada ni
`sh -c`. El shell invoca `pkexec --disable-internal-agent /usr/libexec/gdtk-set-governor
<governor>`; una action polkit dedicada (`org.gdtk.governor.set`, archivo
`session/org.gdtk.governor.policy`) autoriza implícitamente sólo a la sesión local
activa (`allow_active=yes`, `allow_any=no`, `allow_inactive=no`, sin `allow_gui`). El
helper revalida token y pertenencia a `scaling_available_governors` porque `pkexec` no
valida argumentos.

La provisión es **manual y por host** (no la hace `deploy.sh` ni el shell). El deploy
sólo copia `gdtk-governor-helper`, `gdtk-governor-provision` y `org.gdtk.governor.policy`
a `~/gdtk/session/`. Para activarla, con sudo:

```sh
sudo ~/gdtk/session/gdtk-governor-provision install   # helper 0755 root:root + policy 0644 root:root
~/gdtk/session/gdtk-governor-provision status         # sin root
sudo ~/gdtk/session/gdtk-governor-provision remove
```

Requiere `polkit` (y `pkexec`). Si el helper o la action no están instalados, el shell
no abre diálogo: informa que falta provisionar.

## Notas

- **Autologin y llavero**: con autologin el keyring **no** se desbloquea por PAM; la
  primera vez que una app pida un secreto, `gnome-keyring` pedirá la contraseña.
- **Sway**: el script corre antes de que exista el compositor, así que espera en
  segundo plano al socket `wayland-*` y recién entonces arranca polkit, mako y las
  entradas gráficas; no bloquea el arranque de la sesión.
- **Visibilidad**: los únicos nombres internos permitidos son los de este archivo
  (código/logs). La UI habla de Pantalla, Teclado y mouse, Portapapeles y Vecino.
