#define _GNU_SOURCE

#include "wl_server.h"

#include <drm_fourcc.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/render/pixman.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

struct wl_server;

typedef struct toplevel {
	struct wl_list link;
	struct wl_server *server;
	int id;
	struct wlr_xdg_toplevel *tl;
	bool mapped;
	bool want_focus;

	struct wl_listener commit;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener destroy;
	struct wl_listener set_title;
} toplevel;

struct wl_server {
	struct wl_display *display;
	struct wl_event_loop *loop;
	struct wlr_backend *backend;
	struct wlr_renderer *renderer;
	struct wlr_compositor *compositor;
	struct wlr_subcompositor *subcompositor;
	struct wlr_data_device_manager *data_device_manager;
	struct wlr_xdg_shell *xdg_shell;
	struct wlr_seat *seat;
	struct wlr_keyboard keyboard;

	wl_server_callbacks cb;
	struct wl_listener new_toplevel;
	struct wl_list toplevels;
	int next_id;
	int default_w, default_h;

	const char *socket_name;
	struct wlr_surface *pointer_surface;
	int pointer_id;

	unsigned char *frame_buf;
	size_t frame_cap;
};

static toplevel *toplevel_find(struct wl_server *s, int id) {
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->id == id) {
			return t;
		}
	}
	return NULL;
}

static void handle_toplevel_set_title(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, set_title);
	if (t->server->cb.title != NULL) {
		t->server->cb.title(t->server->cb.ud, t->id, t->tl->title != NULL ? t->tl->title : "");
	}
}

static void toplevel_apply_focus(toplevel *t) {
	struct wl_server *s = t->server;
	if (!t->tl->base->initialized) {
		return;
	}
	wlr_xdg_toplevel_set_activated(t->tl, true);
	if (t->mapped) {
		wlr_seat_keyboard_notify_enter(s->seat, t->tl->base->surface,
				s->keyboard.keycodes, s->keyboard.num_keycodes, &s->keyboard.modifiers);
	}
}

static void handle_toplevel_commit(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, commit);
	struct wl_server *s = t->server;
	struct wlr_surface *surface = t->tl->base->surface;

	if (t->tl->base->initial_commit) {
		// ponytail: sin este configure inicial el cliente espera para siempre y nunca mapea
		wlr_xdg_toplevel_set_size(t->tl, s->default_w, s->default_h);
		return;
	}
	if (!t->mapped) {
		return;
	}

	struct wlr_texture *tex = wlr_surface_get_texture(surface);
	if (tex == NULL) {
		return;
	}
	int w = (int)tex->width;
	int h = (int)tex->height;
	if (w <= 0 || h <= 0) {
		return;
	}

	size_t need = (size_t)w * (size_t)h * 4;
	if (need > s->frame_cap) {
		unsigned char *nb = realloc(s->frame_buf, need);
		if (nb == NULL) {
			return;
		}
		s->frame_buf = nb;
		s->frame_cap = need;
	}

	struct wlr_texture_read_pixels_options opts = {
		.data = s->frame_buf,
		.format = DRM_FORMAT_ABGR8888,
		.stride = (uint32_t)(w * 4),
		.dst_x = 0,
		.dst_y = 0,
		.src_box = { 0, 0, 0, 0 },
	};
	if (wlr_texture_read_pixels(tex, &opts) && s->cb.frame != NULL) {
		s->cb.frame(s->cb.ud, t->id, s->frame_buf, w, h);
	}
}

static void handle_toplevel_map(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, map);
	t->mapped = true;
	if (t->want_focus) {
		toplevel_apply_focus(t);
	}
}

static void handle_toplevel_unmap(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, unmap);
	t->mapped = false;
}

static void handle_toplevel_destroy(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, destroy);
	struct wl_server *s = t->server;

	wl_list_remove(&t->commit.link);
	wl_list_remove(&t->map.link);
	wl_list_remove(&t->unmap.link);
	wl_list_remove(&t->set_title.link);
	wl_list_remove(&t->destroy.link);
	wl_list_remove(&t->link);

	if (s->pointer_id == t->id) {
		s->pointer_id = 0;
		s->pointer_surface = NULL;
	}

	int id = t->id;
	free(t);

	if (s->cb.removed != NULL) {
		s->cb.removed(s->cb.ud, id);
	}
}

static void handle_new_toplevel(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_toplevel);
	struct wlr_xdg_toplevel *tl = data;

	toplevel *t = calloc(1, sizeof(*t));
	if (t == NULL) {
		return;
	}
	t->server = s;
	t->tl = tl;
	t->id = s->next_id++;
	t->mapped = false;

	struct wlr_surface *surface = tl->base->surface;

	t->commit.notify = handle_toplevel_commit;
	wl_signal_add(&surface->events.commit, &t->commit);
	t->map.notify = handle_toplevel_map;
	wl_signal_add(&surface->events.map, &t->map);
	t->unmap.notify = handle_toplevel_unmap;
	wl_signal_add(&surface->events.unmap, &t->unmap);
	t->destroy.notify = handle_toplevel_destroy;
	wl_signal_add(&tl->events.destroy, &t->destroy);
	t->set_title.notify = handle_toplevel_set_title;
	wl_signal_add(&tl->events.set_title, &t->set_title);

	wl_list_insert(s->toplevels.prev, &t->link);

	if (s->cb.added != NULL) {
		s->cb.added(s->cb.ud, t->id);
	}
}

wl_server *wl_server_create(wl_server_callbacks cb, int default_w, int default_h) {
	struct wl_server *s = calloc(1, sizeof(*s));
	if (s == NULL) {
		return NULL;
	}
	s->cb = cb;
	s->default_w = default_w > 0 ? default_w : 1024;
	s->default_h = default_h > 0 ? default_h : 700;
	s->next_id = 1;
	s->pointer_id = 0;
	s->pointer_surface = NULL;
	wl_list_init(&s->toplevels);

	s->display = wl_display_create();
	if (s->display == NULL) {
		goto fail;
	}
	s->loop = wl_display_get_event_loop(s->display);

	s->backend = wlr_headless_backend_create(s->loop);
	if (s->backend == NULL) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo crear el backend headless");
		goto fail;
	}

	// ponytail: pixman, no gles2; el renderer GL de wlroots hace eglMakeCurrent en
	// el hilo principal y rompe el contexto GL de Godot.
	s->renderer = wlr_pixman_renderer_create();
	if (s->renderer == NULL) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo crear el renderer pixman");
		goto fail;
	}

	s->compositor = wlr_compositor_create(s->display, 5, s->renderer);
	s->subcompositor = wlr_subcompositor_create(s->display);
	s->data_device_manager = wlr_data_device_manager_create(s->display);
	s->xdg_shell = wlr_xdg_shell_create(s->display, 3);
	if (s->compositor == NULL || s->subcompositor == NULL ||
			s->data_device_manager == NULL || s->xdg_shell == NULL) {
		wlr_log(WLR_ERROR, "wl_server: fallo al crear globals de wlroots");
		goto fail;
	}
	if (!wlr_renderer_init_wl_shm(s->renderer, s->display)) {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_renderer_init_wl_shm");
		goto fail;
	}

	s->seat = wlr_seat_create(s->display, "seat0");
	if (s->seat == NULL) {
		goto fail;
	}

	static const struct wlr_keyboard_impl keyboard_impl = {
		.name = "gdtk-virtual-keyboard",
		.led_update = NULL,
	};
	wlr_keyboard_init(&s->keyboard, &keyboard_impl, "gdtk-virtual-keyboard");
	struct xkb_context *xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	struct xkb_keymap *keymap = NULL;
	if (xkb_ctx != NULL) {
		keymap = xkb_keymap_new_from_names(xkb_ctx, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
	}
	if (keymap != NULL) {
		wlr_keyboard_set_keymap(&s->keyboard, keymap);
		xkb_keymap_unref(keymap);
	} else {
		wlr_log(WLR_ERROR, "wl_server: no se pudo compilar el keymap xkb");
	}
	if (xkb_ctx != NULL) {
		xkb_context_unref(xkb_ctx);
	}
	wlr_seat_set_keyboard(s->seat, &s->keyboard);
	wlr_seat_set_capabilities(s->seat,
			WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD);

	s->new_toplevel.notify = handle_new_toplevel;
	wl_signal_add(&s->xdg_shell->events.new_toplevel, &s->new_toplevel);

	s->socket_name = wl_display_add_socket_auto(s->display);
	if (s->socket_name == NULL) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo crear el socket wayland");
		goto fail;
	}

	if (!wlr_backend_start(s->backend)) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo arrancar el backend");
		goto fail;
	}

	return s;

fail:
	wl_server_destroy(s);
	return NULL;
}

const char *wl_server_socket(wl_server *s) {
	if (s == NULL || s->socket_name == NULL) {
		return "";
	}
	return s->socket_name;
}

void wl_server_dispatch(wl_server *s) {
	if (s == NULL) {
		return;
	}
	wl_event_loop_dispatch(s->loop, 0);
	wl_display_flush_clients(s->display);
}

void wl_server_frame_done(wl_server *s) {
	if (s == NULL) {
		return;
	}
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->mapped && t->tl->base->surface != NULL) {
			wlr_surface_send_frame_done(t->tl->base->surface, &now);
		}
	}
}

void wl_server_set_size(wl_server *s, int id, int w, int h) {
	if (s == NULL || w <= 0 || h <= 0) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->tl->base->initialized) {
		wlr_xdg_toplevel_set_size(t->tl, w, h);
	}
}

void wl_server_set_default_size(wl_server *s, int w, int h) {
	if (s == NULL) {
		return;
	}
	if (w > 0) {
		s->default_w = w;
	}
	if (h > 0) {
		s->default_h = h;
	}
}

void wl_server_close(wl_server *s, int id) {
	if (s == NULL) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->tl->base->initialized) {
		wlr_xdg_toplevel_send_close(t->tl);
	}
}

void wl_server_focus(wl_server *s, int id) {
	if (s == NULL) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t == NULL) {
		return;
	}
	t->want_focus = true;
	toplevel_apply_focus(t);
}

void wl_server_pointer_motion(wl_server *s, int id, double x, double y, uint32_t time_ms) {
	if (s == NULL) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t == NULL) {
		return;
	}
	struct wlr_surface *surface = t->tl->base->surface;
	if (s->pointer_surface != surface) {
		s->pointer_surface = surface;
		s->pointer_id = id;
		wlr_seat_pointer_notify_enter(s->seat, surface, x, y);
	}
	wlr_seat_pointer_notify_motion(s->seat, time_ms, x, y);
	wlr_seat_pointer_notify_frame(s->seat);
}

void wl_server_pointer_button(wl_server *s, uint32_t time_ms, uint32_t evdev_button, int pressed) {
	if (s == NULL) {
		return;
	}
	wlr_seat_pointer_notify_button(s->seat, time_ms, evdev_button,
			pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
	wlr_seat_pointer_notify_frame(s->seat);
}

void wl_server_pointer_axis(wl_server *s, uint32_t time_ms, double dy) {
	if (s == NULL) {
		return;
	}
	wlr_seat_pointer_notify_axis(s->seat, time_ms, WL_POINTER_AXIS_VERTICAL_SCROLL,
			dy, (int32_t)(dy * 10.0), WL_POINTER_AXIS_SOURCE_WHEEL,
			WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
	wlr_seat_pointer_notify_frame(s->seat);
}

void wl_server_key(wl_server *s, uint32_t time_ms, uint32_t evdev_key, int pressed) {
	if (s == NULL) {
		return;
	}
	struct wlr_keyboard_key_event ev = {
		.time_msec = time_ms,
		.keycode = evdev_key,
		.update_state = true,
		.state = pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED,
	};
	wlr_keyboard_notify_key(&s->keyboard, &ev);
	wlr_seat_keyboard_notify_modifiers(s->seat, &s->keyboard.modifiers);
	wlr_seat_keyboard_notify_key(s->seat, time_ms, evdev_key, ev.state);
}

void wl_server_destroy(wl_server *s) {
	if (s == NULL) {
		return;
	}

	// Evitar callbacks hacia Godot mientras se desmonta la escena.
	memset(&s->cb, 0, sizeof(s->cb));

	if (s->xdg_shell != NULL) {
		wl_list_remove(&s->new_toplevel.link);
	}

	if (s->display != NULL) {
		wl_display_destroy_clients(s->display);
	}

	// Red de seguridad: los toplevels normalmente ya se liberaron en destroy.
	toplevel *t, *tmp;
	wl_list_for_each_safe(t, tmp, &s->toplevels, link) {
		wl_list_remove(&t->commit.link);
		wl_list_remove(&t->map.link);
		wl_list_remove(&t->unmap.link);
		wl_list_remove(&t->set_title.link);
		wl_list_remove(&t->destroy.link);
		wl_list_remove(&t->link);
		free(t);
	}

	if (s->backend != NULL) {
		wlr_backend_destroy(s->backend);
	}
	if (s->renderer != NULL) {
		wlr_renderer_destroy(s->renderer);
	}
	if (s->display != NULL) {
		wl_display_destroy(s->display);
	}

	free(s->frame_buf);
	free(s);
}
