// Puente dmabuf zero-copy hacia sway (P4 opcion B). Ver scanout.h.
//
// Todo corre en el hilo principal de Godot, en la conexion Wayland de SDL
// (host); se usa una cola privada para no pisar los eventos de SDL. La
// subsurface es hija de la ventana de Godot y recibe el dmabuf del cliente del
// compositor embebido; el input lo sigue recibiendo la superficie de Godot.

#define _GNU_SOURCE
#include "scanout.h"

#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>

#include <wlr/render/dmabuf.h>
#include <wlr/types/wlr_buffer.h>

#include "linux-dmabuf-v1-client-protocol.h"

typedef struct scanout_buffer {
	struct wl_list link;
	struct wl_buffer *buffer;
	uint64_t token;
} scanout_buffer;

typedef struct scanout_surface {
	struct wl_list link;
	int id;
	struct wl_surface *surface;
	struct wl_subsurface *subsurface;
	struct wl_list buffers; // scanout_buffer.link (los no liberados por sway)
	int x, y, w, h, scale;
} scanout_surface;

typedef struct scanout_params {
	struct scanout_surface *ss;
	uint64_t token;
} scanout_params;

static struct {
	int inited;
	int list_ready;
	int enabled;
	const char *state;
	struct wl_display *display;
	struct wl_surface *parent;
	struct wl_event_queue *queue;
	struct wl_registry *registry;
	struct wl_compositor *compositor;
	struct wl_subcompositor *subcompositor;
	struct zwp_linux_dmabuf_v1 *dmabuf;
	struct wl_list surfaces; // scanout_surface.link
	void (*release_cb)(void *, int, uint64_t);
	void *release_ud;
} g;

static void scanout_surface_destroy(scanout_surface *ss) {
	scanout_buffer *b, *tmp;
	wl_list_for_each_safe(b, tmp, &ss->buffers, link) {
		wl_buffer_destroy(b->buffer);
		wl_list_remove(&b->link);
		free(b);
	}
	if (ss->subsurface != NULL) {
		wl_subsurface_destroy(ss->subsurface);
	}
	if (ss->surface != NULL) {
		wl_surface_destroy(ss->surface);
	}
	wl_list_remove(&ss->link);
	free(ss);
}

static scanout_surface *scanout_surface_get(int id, int create) {
	scanout_surface *ss;
	wl_list_for_each(ss, &g.surfaces, link) {
		if (ss->id == id) {
			return ss;
		}
	}
	if (!create || g.compositor == NULL || g.subcompositor == NULL || g.parent == NULL) {
		return NULL;
	}
	ss = calloc(1, sizeof(*ss));
	ss->id = id;
	wl_list_init(&ss->buffers);
	ss->surface = wl_compositor_create_surface(g.compositor);
	if (ss->surface == NULL) {
		free(ss);
		return NULL;
	}
	ss->subsurface = wl_subcompositor_get_subsurface(g.subcompositor, ss->surface, g.parent);
	if (ss->subsurface == NULL) {
		wl_surface_destroy(ss->surface);
		free(ss);
		return NULL;
	}
	// Desincronizada: se actualiza por su cuenta aunque el padre no commitee UI.
	wl_subsurface_set_desync(ss->subsurface);
	// El contenido de la app no recibe input: la superficie padre (Godot) lo captura.
	struct wl_region *region = wl_compositor_create_region(g.compositor);
	wl_surface_set_input_region(ss->surface, region);
	wl_region_destroy(region);
	// Arriba del padre (MVP app-mode: la app cubre el hueco; el Frame se oculta aparte).
	wl_subsurface_place_above(ss->subsurface, g.parent);
	wl_list_insert(&g.surfaces, &ss->link);
	return ss;
}

static void buffer_handle_release(void *data, struct wl_buffer *wl_buffer) {
	scanout_buffer *b = data;
	(void)wl_buffer;
	// Avisar antes de destruir: wl_server suelta el wlr_buffer retenido.
	if (g.release_cb != NULL) {
		int id = -1;
		scanout_surface *ss;
		wl_list_for_each(ss, &g.surfaces, link) {
			scanout_buffer *it;
			wl_list_for_each(it, &ss->buffers, link) {
				if (it == b) {
					id = ss->id;
				}
			}
		}
		g.release_cb(g.release_ud, id, b->token);
	}
	wl_buffer_destroy(b->buffer);
	wl_list_remove(&b->link);
	free(b);
}

static const struct wl_buffer_listener buffer_listener = { buffer_handle_release };

static void params_handle_created(void *data, struct zwp_linux_buffer_params_v1 *params,
		struct wl_buffer *wl_buffer) {
	(void)data;
	(void)params;
	(void)wl_buffer;
}

static void params_handle_failed(void *data, struct zwp_linux_buffer_params_v1 *params) {
	(void)params;
	scanout_params *p = data;
	// El formato/modifier no lo acepta sway: liberar el buffer embebido y volver.
	if (g.release_cb != NULL) {
		g.release_cb(g.release_ud, p->ss != NULL ? p->ss->id : -1, p->token);
	}
	g.state = "dmabuf rechazado por el host";
}

static const struct zwp_linux_buffer_params_v1_listener params_listener = {
	params_handle_created,
	params_handle_failed,
};

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
		const char *iface, uint32_t version) {
	(void)data;
	if (strcmp(iface, wl_compositor_interface.name) == 0) {
		g.compositor = wl_registry_bind(registry, name, &wl_compositor_interface, version < 4 ? version : 4);
	} else if (strcmp(iface, wl_subcompositor_interface.name) == 0) {
		g.subcompositor = wl_registry_bind(registry, name, &wl_subcompositor_interface, 1);
	} else if (strcmp(iface, zwp_linux_dmabuf_v1_interface.name) == 0) {
		g.dmabuf = wl_registry_bind(registry, name, &zwp_linux_dmabuf_v1_interface, version < 3 ? version : 3);
	}
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = { registry_global, registry_global_remove };

static int scanout_init(void) {
	if (g.inited) {
		return g.compositor != NULL && g.subcompositor != NULL && g.dmabuf != NULL;
	}
	g.inited = 1;
	if (!g.list_ready) {
		wl_list_init(&g.surfaces);
		g.list_ready = 1;
	}
	g.state = "sin host surface";
	if (g.display == NULL || g.parent == NULL) {
		return 0;
	}
	g.queue = wl_display_create_queue(g.display);
	if (g.queue == NULL) {
		g.state = "sin event queue";
		return 0;
	}
	struct wl_display *wrapper = (struct wl_display *)wl_proxy_create_wrapper(g.display);
	wl_proxy_set_queue((struct wl_proxy *)wrapper, g.queue);
	g.registry = wl_display_get_registry(wrapper);
	wl_proxy_wrapper_destroy(wrapper);
	if (g.registry == NULL) {
		g.state = "sin registry";
		return 0;
	}
	wl_registry_add_listener(g.registry, &registry_listener, NULL);
	wl_display_roundtrip_queue(g.display, g.queue);
	if (g.compositor == NULL || g.subcompositor == NULL || g.dmabuf == NULL) {
		g.state = "host sin compositor/subcompositor/dmabuf";
		return 0;
	}
	g.state = "on";
	return 1;
}

void gdtk_scanout_set_host_surface(void *display, void *surface) {
	g.display = (struct wl_display *)display;
	g.parent = (struct wl_surface *)surface;
	// ya inicializado: no rehacer (SDL no re crea la ventana en esta sesion).
	if (g.inited && g.parent != NULL) {
		g.inited = 0;
	}
}

int gdtk_scanout_available(void) {
	return g.enabled && g.display != NULL && g.parent != NULL;
}

void gdtk_scanout_set_release_callback(void (*cb)(void *, int, uint64_t), void *ud) {
	g.release_cb = cb;
	g.release_ud = ud;
}

void gdtk_scanout_present(int id, const struct wlr_dmabuf_attributes *attribs,
		int x, int y, int w, int h, int scale, uint64_t token) {
	if (!gdtk_scanout_available() || attribs == NULL || attribs->n_planes <= 0) {
		if (g.release_cb != NULL) {
			g.release_cb(g.release_ud, id, token);
		}
		return;
	}
	if (!scanout_init()) {
		if (g.release_cb != NULL) {
			g.release_cb(g.release_ud, id, token);
		}
		return;
	}
	scanout_surface *ss = scanout_surface_get(id, 1);
	if (ss == NULL) {
		g.state = "no se pudo crear la subsurface";
		if (g.release_cb != NULL) {
			g.release_cb(g.release_ud, id, token);
		}
		return;
	}
	scanout_params *p = calloc(1, sizeof(*p));
	p->ss = ss;
	p->token = token;
	struct zwp_linux_buffer_params_v1 *params = zwp_linux_dmabuf_v1_create_params(g.dmabuf);
	zwp_linux_buffer_params_v1_add_listener(params, &params_listener, p);
	for (int i = 0; i < attribs->n_planes; i++) {
		zwp_linux_buffer_params_v1_add(params, attribs->fd[i], i, attribs->offset[i],
				attribs->stride[i], (uint32_t)(attribs->modifier >> 32), (uint32_t)(attribs->modifier & 0xffffffff));
	}
	struct wl_buffer *buffer = zwp_linux_buffer_params_v1_create_immed(params, attribs->width,
			attribs->height, attribs->format, 0);
	zwp_linux_buffer_params_v1_destroy(params);

	scanout_buffer *b = calloc(1, sizeof(*b));
	b->buffer = buffer;
	b->token = token;
	wl_buffer_add_listener(buffer, &buffer_listener, b);
	wl_list_insert(&ss->buffers, &b->link);

	ss->x = x;
	ss->y = y;
	ss->w = w;
	ss->h = h;
	ss->scale = scale > 0 ? scale : 1;
	wl_surface_set_buffer_scale(ss->surface, ss->scale);
	wl_subsurface_set_position(ss->subsurface, x, y);
	wl_surface_attach(ss->surface, buffer, 0, 0);
	wl_surface_damage_buffer(ss->surface, 0, 0, attribs->width, attribs->height);
	wl_surface_commit(ss->surface);
	wl_display_flush(g.display);
}

void gdtk_scanout_hide(int id) {
	if (!g.inited) {
		return;
	}
	scanout_surface *ss = scanout_surface_get(id, 0);
	if (ss == NULL) {
		return;
	}
	wl_surface_attach(ss->surface, NULL, 0, 0);
	wl_surface_commit(ss->surface);
	wl_display_flush(g.display);
	scanout_surface_destroy(ss);
}

void gdtk_scanout_dispatch(void) {
	if (!g.inited || g.queue == NULL || g.display == NULL) {
		return;
	}
	while (wl_display_prepare_read_queue(g.display, g.queue) != 0) {
		wl_display_dispatch_queue_pending(g.display, g.queue);
	}
	wl_display_flush(g.display);
	struct pollfd pfd = { wl_display_get_fd(g.display), POLLIN, 0 };
	if (poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN)) {
		wl_display_read_events(g.display);
	} else {
		wl_display_cancel_read(g.display);
	}
	wl_display_dispatch_queue_pending(g.display, g.queue);
}

const char *gdtk_scanout_state(void) {
	return g.state != NULL ? g.state : "off";
}

// Habilitado por el flag de entorno GDTK_SCANOUT_DIRECT (lo lee wl_server al
// arrancar y lo fija aca). Sin el, gdtk_scanout_available() es 0.
void gdtk_scanout_set_enabled(int enabled) {
	g.enabled = enabled;
}
