#ifndef WL_SERVER_H
#define WL_SERVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wl_server wl_server;

typedef struct {
	void *ud;
	void (*added)(void *ud, int id);
	void (*removed)(void *ud, int id);
	// pixels del buffer shm en el FourCC DRM `format` con `stride` bytes por
	// linea. Apuntan a la memoria del cliente: validos SOLO durante la llamada.
	void (*frame)(void *ud, int id, const unsigned char *data, int w, int h, uint32_t format, int stride);
	// el toplevel tiene un buffer dmabuf: C++ asegura la ImageTexture del
	// tamano dado y llama wl_server_bind_dmabuf con su texid.
	void (*dmabuf)(void *ud, int id, int w, int h);
	void (*title)(void *ud, int id, const char *title);
} wl_server_callbacks;

wl_server *wl_server_create(wl_server_callbacks cb, int default_w, int default_h);
const char *wl_server_socket(wl_server *s);
void wl_server_dispatch(wl_server *s);
void wl_server_frame_done(wl_server *s);
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
void wl_server_bind_dmabuf(wl_server *s, int id, unsigned int texid);
void wl_server_destroy(wl_server *s);

#ifdef __cplusplus
}
#endif

#endif // WL_SERVER_H
