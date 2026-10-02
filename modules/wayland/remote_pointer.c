// Puntero remoto por wlr_virtual_pointer (sway, cage): abre su propia conexión Wayland
// al host (el motor ya tiene la de SDL) y sólo manda requests; el host mueve su cursor
// nativo y entrega el evento al shell como input local. No se leen eventos del host, así
// que no hace falta despachar: se hace flush por request (y el registro con roundtrip al
// crear). Sin el protocolo (p.ej. X11 o un host sin wlroots), create() devuelve NULL.
#define _GNU_SOURCE
#include "remote_pointer.h"

#include "wlr-virtual-pointer-unstable-v1-protocol.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

struct remote_pointer {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_seat *seat;
	struct zwlr_virtual_pointer_manager_v1 *manager;
	struct zwlr_virtual_pointer_v1 *pointer;
};

static void registry_global(void *ud, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
	struct remote_pointer *p = ud;
	if (strcmp(iface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
		p->manager = wl_registry_bind(r, name, &zwlr_virtual_pointer_manager_v1_interface, 1);
	} else if (strcmp(iface, wl_seat_interface.name) == 0 && p->seat == NULL) {
		p->seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
	}
}

static void registry_global_remove(void *ud, struct wl_registry *r, uint32_t name) {
	(void)ud;
	(void)r;
	(void)name;
}

static const struct wl_registry_listener registry_listener = { registry_global, registry_global_remove };

static uint32_t now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

remote_pointer *remote_pointer_create(void) {
	const char *wayland = getenv("WAYLAND_DISPLAY");
	if (wayland == NULL || *wayland == '\0') {
		return NULL;
	}
	struct remote_pointer *p = calloc(1, sizeof(*p));
	p->display = wl_display_connect(NULL);
	if (p->display == NULL) {
		free(p);
		return NULL;
	}
	p->registry = wl_display_get_registry(p->display);
	wl_registry_add_listener(p->registry, &registry_listener, p);
	wl_display_roundtrip(p->display);
	if (p->manager == NULL) {
		remote_pointer_destroy(p);
		return NULL;
	}
	p->pointer = zwlr_virtual_pointer_manager_v1_create_virtual_pointer(p->manager, p->seat);
	wl_display_flush(p->display);
	return p;
}

int remote_pointer_ready(remote_pointer *p) {
	return p != NULL && p->pointer != NULL;
}

void remote_pointer_motion_abs(remote_pointer *p, int x, int y, int w, int h) {
	if (!remote_pointer_ready(p) || w <= 0 || h <= 0) {
		return;
	}
	if (x < 0) {
		x = 0;
	}
	if (y < 0) {
		y = 0;
	}
	if (x > w) {
		x = w;
	}
	if (y > h) {
		y = h;
	}
	zwlr_virtual_pointer_v1_motion_absolute(p->pointer, now_ms(), (uint32_t)x, (uint32_t)y, (uint32_t)w, (uint32_t)h);
	zwlr_virtual_pointer_v1_frame(p->pointer);
	wl_display_flush(p->display);
}

void remote_pointer_button(remote_pointer *p, uint32_t evdev_button, int pressed) {
	if (!remote_pointer_ready(p)) {
		return;
	}
	zwlr_virtual_pointer_v1_button(p->pointer, now_ms(), evdev_button,
			pressed ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED);
	zwlr_virtual_pointer_v1_frame(p->pointer);
	wl_display_flush(p->display);
}

void remote_pointer_scroll(remote_pointer *p, double dx, double dy) {
	if (!remote_pointer_ready(p)) {
		return;
	}
	uint32_t t = now_ms();
	zwlr_virtual_pointer_v1_axis_source(p->pointer, WL_POINTER_AXIS_SOURCE_WHEEL);
	if (dy != 0.0) {
		zwlr_virtual_pointer_v1_axis_discrete(p->pointer, t, WL_POINTER_AXIS_VERTICAL_SCROLL,
				wl_fixed_from_double(dy), dy > 0.0 ? 1 : -1);
	}
	if (dx != 0.0) {
		zwlr_virtual_pointer_v1_axis_discrete(p->pointer, t, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
				wl_fixed_from_double(dx), dx > 0.0 ? 1 : -1);
	}
	zwlr_virtual_pointer_v1_frame(p->pointer);
	wl_display_flush(p->display);
}

void remote_pointer_destroy(remote_pointer *p) {
	if (p == NULL) {
		return;
	}
	if (p->pointer != NULL) {
		zwlr_virtual_pointer_v1_destroy(p->pointer);
	}
	if (p->manager != NULL) {
		zwlr_virtual_pointer_manager_v1_destroy(p->manager);
	}
	if (p->seat != NULL) {
		wl_seat_destroy(p->seat);
	}
	if (p->registry != NULL) {
		wl_registry_destroy(p->registry);
	}
	if (p->display != NULL) {
		wl_display_flush(p->display);
		wl_display_disconnect(p->display);
	}
	free(p);
}
