#ifndef GDTK_SCANOUT_H
#define GDTK_SCANOUT_H

// Puente dmabuf zero-copy hacia el compositor anfitrion (sway) — P4 opcion B.
//
// El compositor embebido (wlroots headless, dentro del proceso Godot) importa el
// buffer de cada app y lo deja como textura, de modo que cada frame de la app pasa
// por la escena de Godot antes de que sway componga. Este puente toma el dmabuf del
// cliente (que wl_server ya tiene retenido) y lo adjunta a una wl_subsurface de la
// ventana de Godot en sway. El contenido de la app deja de pasar por Godot.
//
// La plataforma (platform/frt) entrega el wl_display y el wl_surface de la ventana
// de SDL; aca se abre una cola privada sobre esa misma conexion y se crea la
// subsurface + el wl_buffer dmabuf del lado cliente de sway.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct wlr_dmabuf_attributes;

// La plataforma entrega los punteros opacos de la ventana (struct wl_display*,
// struct wl_surface*). Se declaran void* para no obligar a incluir wayland-client
// en platform/frt (SDL_syswm.h arrastra X11 y rompe los nombres de Godot).
void gdtk_scanout_set_host_surface(void *display, void *surface);

// Activa el puente (flag GDTK_SCANOUT_DIRECT). Sin esto, available() es 0.
void gdtk_scanout_set_enabled(int enabled);

// 1 si hay candidatos posibles (flag activo y host surface recibida).
int gdtk_scanout_available(void);

// Presenta el dmabuf de la surface `id` como subsurface de la ventana. `x,y,w,h`
// en coords de la superficie del shell, `scale` entero del shell. `token` identifica
// el buffer retenido en wl_server para avisar su liberacion cuando sway la suelte.
void gdtk_scanout_present(int id, const struct wlr_dmabuf_attributes *attribs,
		int x, int y, int w, int h, int scale, uint64_t token);

// Quita la subsurface de `id` (detach + commit); vuelve al camino Godot.
void gdtk_scanout_hide(int id);

// Despacha sin bloquear la cola privada del host (release de wl_buffers, etc).
void gdtk_scanout_dispatch(void);

// Aviso de liberacion de un buffer presentado: (ud, id, token).
void gdtk_scanout_set_release_callback(void (*cb)(void *ud, int id, uint64_t token), void *ud);

// Estado/motivo para diagnostico ("on", "no host surface", ...).
const char *gdtk_scanout_state(void);

#ifdef __cplusplus
}
#endif

#endif // GDTK_SCANOUT_H
