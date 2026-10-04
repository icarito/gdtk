# Migrar bastion a gdtk

bastion (máquina principal, GNOME Wayland) pasa a gdtk como sesión diaria sólo
cuando no quede ningún bloqueante. GNOME sigue disponible en GDM durante el piloto.

## Veredicto (review 2026-10-01)

**NO-GO como sesión única; GO condicional para piloto.**

## Bloqueantes

- Bloqueo de pantalla / idle; sin bloqueo al reanudar.
- Suspender: tapa (logind) y botón de poder (falta `HandlePowerKey=suspend`).
- polkit / keyring.
- Historial de portapapeles: applet `portapapeles` hecho (captura + último ítem, 2026-10-04);
  falta instalar el motor con `ext-data-control-v1`, elegir/reinsertar ítems viejos y el
  puente con el portapapeles de sway (`plans/tech-debt.md`).
- Multi-monitor (HiDPI ya anda con la escala global de Configuración, que también va a las apps).
- ScreenCast (portal).
- IME en los campos del propio shell (las apps ya lo tienen: relay text-input-v3/input-method-v2, `SPEC-ime.md`).
- `/run/media/.../DATA` no está en fstab: la sesión debe correr desde `~/gdtk`
  instalado (`deploy.sh`), nunca desde el repo.

Resueltos desde entonces: batería (en la dockapp térmica), volumen/brillo (OSD), servidor Deskflow vía portal
InputCapture (ver `AGENTS.md`).
