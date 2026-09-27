# Distribución de teclado para la sesión (lo sourcean gdtk-session y gdtk-session-x11).
# Se toma de ~/.config/gdtk/keyboard si existe, p.ej.:
#   XKB_DEFAULT_LAYOUT=latam
#   XKB_DEFAULT_VARIANT=
#   XKB_DEFAULT_OPTIONS=terminate:ctrl_alt_bksp
# y si no, de la configuración del sistema (localectl). cage, el compositor embebido y sus
# apps leen XKB_DEFAULT_*; en X11 además se aplica con setxkbmap para el propio Godot.
KB="${XDG_CONFIG_HOME:-$HOME/.config}/gdtk/keyboard"
if [ -f "$KB" ]; then
	. "$KB"
else
	eval "$(localectl status 2>/dev/null | sed -n \
		-e 's/^ *X11 Layout: */XKB_DEFAULT_LAYOUT=/p' -e 's/^ *X11 Variant: */XKB_DEFAULT_VARIANT=/p' \
		-e 's/^ *X11 Model: */XKB_DEFAULT_MODEL=/p' -e 's/^ *X11 Options: */XKB_DEFAULT_OPTIONS=/p')"
fi
for v in XKB_DEFAULT_LAYOUT XKB_DEFAULT_VARIANT XKB_DEFAULT_MODEL XKB_DEFAULT_OPTIONS; do
	eval "[ -n \"\$$v\" ] && export $v || unset $v"
done
