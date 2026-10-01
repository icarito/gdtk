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
| Notificaciones | `mako` | Daemon de notificaciones layer-shell (Wayland). En X11 no aplica y se omite. |
| Ejecutor de `.desktop` | `dex` | Opcional. Si está, el script lo usa para lanzar `~/.config/autostart` respetando `Hidden`/`OnlyShowIn`/`NotShowIn`; si no, hace el parseo y filtrado él mismo. |
| Publicación de entorno | `dbus` (`dbus-update-activation-environment`) | Necesario para que los servicios activados por D-Bus/systemd vean `GNOME_KEYRING_CONTROL` y `SSH_AUTH_SOCK`. |

## Notas

- **Autologin y llavero**: con autologin el keyring **no** se desbloquea por PAM; la
  primera vez que una app pida un secreto, `gnome-keyring` pedirá la contraseña.
- **Sway**: el script corre antes de que exista el compositor, así que espera en
  segundo plano al socket `wayland-*` y recién entonces arranca polkit, mako y las
  entradas gráficas; no bloquea el arranque de la sesión.
- **Visibilidad**: los únicos nombres internos permitidos son los de este archivo
  (código/logs). La UI habla de Pantalla, Teclado y mouse, Portapapeles y Vecino.
