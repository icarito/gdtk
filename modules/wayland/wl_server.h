#ifndef WL_SERVER_H
#define WL_SERVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wl_server wl_server;

// Una capa del arbol de un toplevel: la surface raiz, una subsurface o un
// popup. `key` es la identidad estable de la surface (su puntero). x,y son
// relativos a la raiz y w,h el tamano logico de la surface, en orden de dibujo.
typedef struct {
	uint64_t key;
	int x, y, w, h;
} wl_server_layer;

typedef struct {
	void *ud;
	void (*added)(void *ud, int id);
	void (*removed)(void *ud, int id);
	// pixels del buffer shm en el FourCC DRM `format` con `stride` bytes por
	// linea. Apuntan a la memoria del cliente: validos SOLO durante la llamada.
	void (*frame)(void *ud, int id, uint64_t key, const unsigned char *data, int w, int h, uint32_t format, int stride);
	// la surface `key` tiene un buffer dmabuf: C++ asegura la ImageTexture del
	// tamano dado y llama wl_server_bind_dmabuf con su texid.
	void (*dmabuf)(void *ud, int id, uint64_t key, int w, int h);
	void (*title)(void *ud, int id, const char *title);
	// Superficie layer-shell `id`: 1 mapeada, 0 desmapeada, -1 destruida.
	void (*layer)(void *ud, int id, int state);
	// xdg-activation: el toplevel `id` pide pasar al frente.
	void (*activate)(void *ud, int id);
	// El cliente pide minimizarse (xdg_toplevel.set_minimized o iconify X11).
	void (*minimize)(void *ud, int id);
	// El cliente pide maximizar/desmaximizar (xdg_toplevel.set_maximized). `maximized`
	// es el estado pedido (1/0); el borde ya lo confirmo en el configure y el shell
	// decide como acomodar la ventana en su workspace.
	void (*maximize)(void *ud, int id, int maximized);
	// El cliente pide pantalla completa (xdg_toplevel.set_fullscreen o X11
	// _NET_WM_STATE_FULLSCREEN). `fullscreen` es el estado pedido (1/0).
	void (*fullscreen)(void *ud, int id, int fullscreen);
	// Algo del árbol de `id` desapareció sin commit (menú X o popup cerrado): redibujar.
	void (*damage)(void *ud, int id);
} wl_server_callbacks;

// Superficie layer-shell mapeada: rect en coords del output (la vista), capa 0..3
// (background, bottom, top, overlay).
typedef struct {
	int id, layer;
	int x, y, w, h;
} wl_server_layer_surface;

wl_server *wl_server_create(wl_server_callbacks cb, int default_w, int default_h);
const char *wl_server_socket(wl_server *s);
// DISPLAY del Xwayland embebido ("" si no hay).
const char *wl_server_xdisplay(wl_server *s);
void wl_server_dispatch(wl_server *s);
void wl_server_frame_done(wl_server *s);
// Toplevels dibujados en el último frame: sólo ellos reciben frame callbacks desde ahora
// (las layer surfaces mapeadas, siempre).
void wl_server_set_visible(wl_server *s, const int *ids, int n);
void wl_server_set_size(wl_server *s, int id, int w, int h);
void wl_server_set_default_size(wl_server *s, int w, int h);
void wl_server_close(wl_server *s, int id);
void wl_server_focus(wl_server *s, int id);
void wl_server_pointer_motion(wl_server *s, int id, double x, double y, uint32_t time_ms);
void wl_server_pointer_button(wl_server *s, uint32_t time_ms, uint32_t evdev_button, int pressed);
void wl_server_pointer_axis(wl_server *s, uint32_t time_ms, double dy);
void wl_server_key(wl_server *s, uint32_t time_ms, uint32_t evdev_key, int pressed);
// dmabuf: 1 si se anuncio linux-dmabuf con feedback propio; estado/motivo para el reporte.
int wl_server_dmabuf_enabled(wl_server *s);
const char *wl_server_dmabuf_reason(wl_server *s);
void wl_server_bind_dmabuf(wl_server *s, uint64_t key, unsigned int texid);
// Llena hasta `max` capas del arbol del toplevel (o layer surface) `id` en orden de dibujo;
// devuelve cuantas escribio (0 si el id no existe o no esta mapeado).
int wl_server_layers(wl_server *s, int id, wl_server_layer *out, int max);
// Geometría de la ventana (contenido sin sombras CSD) relativa a la surface raíz; 0 si no hay.
int wl_server_geometry(wl_server *s, int id, int *x, int *y, int *w, int *h);
// id del toplevel que es `parent` del toplevel `id` (0 si no tiene).
int wl_server_parent(wl_server *s, int id);
// app_id del toplevel `id` ("" si no tiene).
const char *wl_server_app_id(wl_server *s, int id);
// Layer surfaces mapeadas, de la capa mas baja a la mas alta; devuelve cuantas.
int wl_server_layer_surfaces(wl_server *s, wl_server_layer_surface *out, int max);
void wl_server_destroy(wl_server *s);

#ifdef __cplusplus
}
#endif

#endif // WL_SERVER_H
