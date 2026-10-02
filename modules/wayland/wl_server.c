#define _GNU_SOURCE

#include "wl_server.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <drm_fourcc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>
#include <wlr/types/wlr_output.h>
#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/render/dmabuf.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_layer_shell_v1.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_primary_selection.h>
#include <wlr/types/wlr_primary_selection_v1.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_shm.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_text_input_v3.h>
#include <wlr/types/wlr_input_method_v2.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_xdg_foreign_registry.h>
#include <wlr/types/wlr_xdg_foreign_v1.h>
#include <wlr/types/wlr_xdg_foreign_v2.h>
#include <wlr/types/wlr_server_decoration.h>
#include <wlr/util/log.h>
#include <wlr/xwayland/xwayland.h>
#include <xkbcommon/xkbcommon.h>

struct wl_server;

// Una ventana: xdg (tl) o X11 vía Xwayland (xs); exactamente uno de los dos.
typedef struct toplevel {
	struct wl_list link;
	struct wl_server *server;
	int id;
	struct wlr_xdg_toplevel *tl;
	struct wlr_xwayland_surface *xs;
	bool added; // X: `added` se avisa en el primer map (antes no hay surface)
	bool mapped;
	bool want_focus;
	bool visible; // dibujado en el último frame del shell (ver wl_server_set_visible)

	struct wl_listener commit;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener destroy;
	struct wl_listener set_title;
	// se registra en ambas rutas (xdg y Xwayland)
	struct wl_listener request_minimize;
	// sólo X
	struct wl_listener associate;
	struct wl_listener dissociate;
	struct wl_listener request_configure;
} toplevel;

// Ventana X override-redirect (menú, tooltip): se dibuja como capa de su dueño, en
// coords del root X, que coinciden con las de la vista (las ventanas X van en 0,0).
typedef struct xor_surf {
	struct wl_list link;
	struct wl_server *server;
	struct wlr_xwayland_surface *xs;
	int owner;
	bool mapped;
	struct wl_listener associate;
	struct wl_listener dissociate;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener destroy;
} xor_surf;

// Estado por surface del arbol (raiz, subsurfaces, popups). Mantiene retenido
// con wlr_buffer_lock el ultimo buffer importado para que Godot pueda
// samplearlo; la identidad es el puntero de la surface (`key`).
typedef struct surface_state {
	struct wl_list link;
	struct wl_server *server;
	struct wlr_surface *surface;
	uint64_t key;
	int id;
	struct wlr_buffer *buffer;
	struct wl_listener commit;
	struct wl_listener destroy;
	struct wl_listener new_subsurface;
} surface_state;

// Un text-input-v3 de un cliente: el campo de texto que pide IME (text-input-v3).
// Vive en s->text_inputs; el relay le reenvia el preedit/commit del motor.
typedef struct text_input_relay {
	struct wl_list link;
	struct wl_server *server;
	struct wlr_text_input_v3 *input;
	struct wl_listener enable;
	struct wl_listener commit;
	struct wl_listener disable;
	struct wl_listener destroy;
} text_input_relay;

struct wl_server {
	struct wl_display *display;
	struct wl_event_loop *loop;
	struct wlr_backend *backend;
	struct wlr_output *output;
	struct wlr_compositor *compositor;
	struct wlr_subcompositor *subcompositor;
	struct wlr_data_device_manager *data_device_manager;
	struct wlr_xdg_shell *xdg_shell;
	struct wlr_seat *seat;
	struct wlr_keyboard keyboard;

	// xdg-foreign (v1/v2): deja que un cliente (el portal GTK del selector de
	// archivos) declare su ventana hija de la ventana de otra app. El parent que
	// marca wlroots hace que el shell lo trate como diálogo y lo flote sobre su
	// host en vez de como una ventana suelta (actividad/workspace nuevo).
	struct wlr_xdg_foreign_registry *foreign_registry;
	struct wlr_xdg_foreign_v1 *foreign_v1;
	struct wlr_xdg_foreign_v2 *foreign_v2;

	// IME (K14): text-input-v3 del cliente y el motor IME (fcitx5/ibus) por
	// input-method-v2. Relay minimo: activa el motor con el foco de text-input,
	// reenvia preedit/commit y le cede el teclado durante sus grabs.
	struct wlr_text_input_manager_v3 *text_input_manager;
	struct wlr_input_method_manager_v2 *input_method_manager;
	struct wlr_input_method_v2 *input_method;
	struct wlr_text_input_v3 *active_text_input;
	struct wlr_input_method_keyboard_grab_v2 *keyboard_grab;
	struct wl_list text_inputs; // text_input_relay.link
	struct wl_listener new_text_input;
	struct wl_listener new_input_method;
	struct wl_listener input_method_commit;
	struct wl_listener input_method_grab_keyboard;
	struct wl_listener input_method_destroy;
	struct wl_listener keyboard_grab_destroy;

	// Todo lo EGL/GL vive aqui y se resuelve con eglGetProcAddress: no se
	// linkea libGL/libGLES, solo egl.
	EGLDisplay egl_dpy;
	PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR;
	PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHR;
	PFNEGLQUERYDMABUFFORMATSEXTPROC eglQueryDmaBufFormatsEXT;
	PFNEGLQUERYDMABUFMODIFIERSEXTPROC eglQueryDmaBufModifiersEXT;
	PFNGLBINDTEXTUREPROC glBindTexture;
	PFNGLGETINTEGERVPROC glGetIntegerv;
	PFNGLTEXPARAMETERIPROC glTexParameteri;
	PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOES;
	bool dmabuf_enabled;
	const char *dmabuf_reason;
	struct wlr_linux_dmabuf_v1 *linux_dmabuf;

	wl_server_callbacks cb;
	struct wl_listener new_toplevel;
	struct wl_listener new_popup;
	struct wl_listener new_decoration;
	struct wl_listener new_layer;
	struct wl_listener request_activate;
	struct wl_listener request_set_selection;
	struct wl_listener request_set_primary_selection;
	struct wl_list toplevels;
	struct wl_list layers;
	struct wlr_xwayland *xwayland;
	struct wl_listener new_xsurface;
	struct wl_list xors;
	int x_focus_id; // última ventana X enfocada: dueña de los menús sin padre
	bool throttle; // true tras el primer wl_server_set_visible: frame callbacks sólo a lo visible
	int next_id;
	int default_w, default_h;

	// Estado por surface de todos los toplevels. Se recorre entero en cada
	// dispatch para reimportar buffers nuevos; se limpia en events.destroy.
	struct wl_list surfaces;

	const char *socket_name;
	struct wlr_surface *pointer_surface;
	int pointer_id;
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

static toplevel *toplevel_find_surface(struct wl_server *s, struct wlr_surface *surface) {
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if ((t->tl != NULL ? t->tl->base->surface : t->xs->surface) == surface) {
			return t;
		}
	}
	return NULL;
}

static surface_state *surface_state_find(struct wl_server *s, struct wlr_surface *surface) {
	surface_state *st;
	wl_list_for_each(st, &s->surfaces, link) {
		if (st->surface == surface) {
			return st;
		}
	}
	return NULL;
}

static surface_state *surface_state_find_key(struct wl_server *s, uint64_t key) {
	surface_state *st;
	wl_list_for_each(st, &s->surfaces, link) {
		if (st->key == key) {
			return st;
		}
	}
	return NULL;
}

static void surface_state_release_buffer(surface_state *st) {
	if (st->buffer != NULL) {
		wlr_buffer_unlock(st->buffer);
		st->buffer = NULL;
	}
}

static int surface_state_resolve_id(struct wl_server *s, struct wlr_surface *surface, int depth);

// Importa el buffer current de la surface si hay uno. Se llama desde el commit
// de la surface, unico momento en que wlroots deja valido current.buffer. Los
// commits sin buffer (ack de configure, frame callbacks) se ignoran para no
// soltar el ultimo buffer importado.
static void surface_state_import(surface_state *st) {
	struct wl_server *s = st->server;
	if (st->id <= 0) {
		st->id = surface_state_resolve_id(s, st->surface, 0);
	}
	if (st->id <= 0) {
		return;
	}
	struct wlr_buffer *buf = st->surface->current.buffer;
	if (buf == NULL) {
		return;
	}
	if (buf != st->buffer) {
		wlr_buffer_lock(buf);
		if (st->buffer != NULL) {
			wlr_buffer_unlock(st->buffer);
		}
		st->buffer = buf;
	}

	struct wlr_dmabuf_attributes attribs;
	if (s->dmabuf_enabled && wlr_buffer_get_dmabuf(buf, &attribs)) {
		if (s->cb.dmabuf != NULL) {
			s->cb.dmabuf(s->cb.ud, st->id, st->key, attribs.width, attribs.height);
		}
		return;
	}

	// Camino shm: puntero directo al buffer del cliente, sin copia en C.
	void *ptr = NULL;
	uint32_t format = 0;
	size_t stride = 0;
	if (!wlr_buffer_begin_data_ptr_access(buf, WLR_BUFFER_DATA_PTR_ACCESS_READ,
			&ptr, &format, &stride)) {
		return;
	}
	if (s->cb.frame != NULL) {
		s->cb.frame(s->cb.ud, st->id, st->key, (const unsigned char *)ptr, buf->width,
				buf->height, format, (int)stride);
	}
	wlr_buffer_end_data_ptr_access(buf);
}

static void handle_surface_commit(struct wl_listener *listener, void *data) {
	surface_state *st = wl_container_of(listener, st, commit);
	surface_state_import(st);
}

static void surface_state_acquire(struct wl_server *s, struct wlr_surface *surface, int id);

// Resuelve el toplevel dueno de una surface subiendo por los popups: un popup
// no esta en el arbol de subsurfaces, su padre lo referencia xdg_popup.parent.
static int surface_state_resolve_id(struct wl_server *s, struct wlr_surface *surface, int depth) {
	if (surface == NULL || depth > 16) {
		return 0;
	}
	surface_state *st = surface_state_find(s, surface);
	if (st != NULL && st->id > 0) {
		return st->id;
	}
	struct wlr_xdg_surface *xdg = wlr_xdg_surface_try_from_wlr_surface(surface);
	if (xdg != NULL && xdg->role == WLR_XDG_SURFACE_ROLE_POPUP && xdg->popup != NULL) {
		return surface_state_resolve_id(s, xdg->popup->parent, depth + 1);
	}
	toplevel *t = toplevel_find_surface(s, wlr_surface_get_root_surface(surface));
	return t != NULL ? t->id : 0;
}

static void handle_new_subsurface(struct wl_listener *listener, void *data) {
	surface_state *st = wl_container_of(listener, st, new_subsurface);
	struct wlr_subsurface *sub = data;
	if (sub != NULL && sub->surface != NULL &&
			surface_state_find(st->server, sub->surface) == NULL) {
		surface_state_acquire(st->server, sub->surface, st->id);
	}
}

static void handle_surface_destroy(struct wl_listener *listener, void *data) {
	surface_state *st = wl_container_of(listener, st, destroy);
	wl_list_remove(&st->commit.link);
	wl_list_remove(&st->new_subsurface.link);
	wl_list_remove(&st->destroy.link);
	wl_list_remove(&st->link);
	surface_state_release_buffer(st);
	free(st);
}

static void surface_state_acquire(struct wl_server *s, struct wlr_surface *surface, int id) {
	surface_state *st = calloc(1, sizeof(*st));
	if (st == NULL) {
		return;
	}
	st->server = s;
	st->surface = surface;
	st->key = (uint64_t)(uintptr_t)surface;
	st->id = id;
	st->commit.notify = handle_surface_commit;
	wl_signal_add(&surface->events.commit, &st->commit);
	st->new_subsurface.notify = handle_new_subsurface;
	wl_signal_add(&surface->events.new_subsurface, &st->new_subsurface);
	st->destroy.notify = handle_surface_destroy;
	wl_signal_add(&surface->events.destroy, &st->destroy);
	wl_list_insert(s->surfaces.prev, &st->link);
}

// --- IME: relay text-input-v3 <-> input-method-v2 (K14) ---
// El motor IME (fcitx5/ibus) se conecta por input-method-v2; los clientes piden
// texto por text-input-v3. Aqui solo se enruta: foco de text-input al toplevel
// enfocado, ida de surrounding/content-type, vuelta de preedit/commit, y cesion
// del teclado mientras el motor tiene un grab. Sin procesos en el render: todo
// corre en el hilo de dispatch de Wayland.

static void handle_text_input_enable(struct wl_listener *listener, void *data);

static void handle_text_input_commit(struct wl_listener *listener, void *data);

static void handle_text_input_disable(struct wl_listener *listener, void *data);

static void handle_text_input_destroy(struct wl_listener *listener, void *data);

static void handle_new_text_input(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_text_input);
	struct wlr_text_input_v3 *input = data;
	text_input_relay *ti = calloc(1, sizeof(*ti));
	if (ti == NULL) {
		return;
	}
	ti->server = s;
	ti->input = input;
	ti->enable.notify = handle_text_input_enable;
	wl_signal_add(&input->events.enable, &ti->enable);
	ti->commit.notify = handle_text_input_commit;
	wl_signal_add(&input->events.commit, &ti->commit);
	ti->disable.notify = handle_text_input_disable;
	wl_signal_add(&input->events.disable, &ti->disable);
	ti->destroy.notify = handle_text_input_destroy;
	wl_signal_add(&input->events.destroy, &ti->destroy);
	wl_list_insert(&s->text_inputs, &ti->link);
}

// El cliente habilito su campo: activar el motor y mandarle el contexto.
static void handle_text_input_enable(struct wl_listener *listener, void *data) {
	text_input_relay *ti = wl_container_of(listener, ti, enable);
	struct wl_server *s = ti->server;
	if (s->input_method == NULL) {
		return;
	}
	s->active_text_input = ti->input;
	wlr_input_method_v2_send_activate(s->input_method);
	if ((ti->input->active_features & WLR_TEXT_INPUT_V3_FEATURE_SURROUNDING_TEXT) &&
			ti->input->current.surrounding.text != NULL) {
		wlr_input_method_v2_send_surrounding_text(s->input_method,
				ti->input->current.surrounding.text,
				ti->input->current.surrounding.cursor,
				ti->input->current.surrounding.anchor);
	}
	if (ti->input->active_features & WLR_TEXT_INPUT_V3_FEATURE_CONTENT_TYPE) {
		wlr_input_method_v2_send_content_type(s->input_method,
				ti->input->current.content_type.hint,
				ti->input->current.content_type.purpose);
	}
	wlr_input_method_v2_send_done(s->input_method);
}

// Reenvia el estado actual al motor para que refina su candidato.
static void handle_text_input_commit(struct wl_listener *listener, void *data) {
	text_input_relay *ti = wl_container_of(listener, ti, commit);
	struct wl_server *s = ti->server;
	if (s->input_method == NULL || s->active_text_input != ti->input) {
		return;
	}
	if ((ti->input->active_features & WLR_TEXT_INPUT_V3_FEATURE_SURROUNDING_TEXT) &&
			ti->input->current.surrounding.text != NULL) {
		wlr_input_method_v2_send_surrounding_text(s->input_method,
				ti->input->current.surrounding.text,
				ti->input->current.surrounding.cursor,
				ti->input->current.surrounding.anchor);
	}
	if (ti->input->active_features & WLR_TEXT_INPUT_V3_FEATURE_CONTENT_TYPE) {
		wlr_input_method_v2_send_content_type(s->input_method,
				ti->input->current.content_type.hint,
				ti->input->current.content_type.purpose);
	}
	wlr_input_method_v2_send_done(s->input_method);
}

static void handle_text_input_disable(struct wl_listener *listener, void *data) {
	text_input_relay *ti = wl_container_of(listener, ti, disable);
	struct wl_server *s = ti->server;
	if (s->active_text_input != ti->input) {
		return;
	}
	s->active_text_input = NULL;
	if (s->input_method != NULL) {
		wlr_input_method_v2_send_deactivate(s->input_method);
	}
}

static void handle_text_input_destroy(struct wl_listener *listener, void *data) {
	text_input_relay *ti = wl_container_of(listener, ti, destroy);
	struct wl_server *s = ti->server;
	if (s->active_text_input == ti->input) {
		s->active_text_input = NULL;
		if (s->input_method != NULL) {
			wlr_input_method_v2_send_deactivate(s->input_method);
		}
	}
	wl_list_remove(&ti->enable.link);
	wl_list_remove(&ti->commit.link);
	wl_list_remove(&ti->disable.link);
	wl_list_remove(&ti->destroy.link);
	wl_list_remove(&ti->link);
	free(ti);
}

// El toplevel enfocado manda en el foco de text-input. Como text-input-v3 es
// por cliente, se entra en los text-input del mismo cliente que la surface y se
// sale del resto.
static void text_input_relay_set_focus(struct wl_server *s, struct wlr_surface *surface) {
	if (s == NULL) {
		return;
	}
	text_input_relay *ti;
	wl_list_for_each(ti, &s->text_inputs, link) {
		struct wlr_text_input_v3 *input = ti->input;
		bool same_client = surface != NULL && input->resource != NULL &&
				wl_resource_get_client(input->resource) ==
				wl_resource_get_client(surface->resource);
		if (same_client) {
			if (input->focused_surface != surface) {
				if (input->focused_surface != NULL) {
					wlr_text_input_v3_send_leave(input);
				}
				wlr_text_input_v3_send_enter(input, surface);
			}
		} else if (input->focused_surface != NULL) {
			wlr_text_input_v3_send_leave(input);
		}
	}
}

static void handle_input_method_commit(struct wl_listener *listener, void *data);

static void handle_input_method_grab_keyboard(struct wl_listener *listener, void *data);

static void handle_input_method_destroy(struct wl_listener *listener, void *data);

static void handle_keyboard_grab_destroy(struct wl_listener *listener, void *data);

static void handle_new_input_method(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_input_method);
	struct wlr_input_method_v2 *im = data;
	if (s->input_method != NULL) {
		// Un solo motor IME a la vez: el segundo recibe unavailable.
		wlr_input_method_v2_send_unavailable(im);
		return;
	}
	s->input_method = im;
	s->input_method_commit.notify = handle_input_method_commit;
	wl_signal_add(&im->events.commit, &s->input_method_commit);
	s->input_method_grab_keyboard.notify = handle_input_method_grab_keyboard;
	wl_signal_add(&im->events.grab_keyboard, &s->input_method_grab_keyboard);
	s->input_method_destroy.notify = handle_input_method_destroy;
	wl_signal_add(&im->events.destroy, &s->input_method_destroy);
}

// El motor produjo texto: reenviar preedit/commit/delete al campo enfocado.
static void handle_input_method_commit(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, input_method_commit);
	struct wlr_input_method_v2 *im = data;
	struct wlr_text_input_v3 *input = s->active_text_input;
	if (input == NULL) {
		return;
	}
	if (im->current.preedit.text != NULL) {
		wlr_text_input_v3_send_preedit_string(input, im->current.preedit.text,
				im->current.preedit.cursor_begin, im->current.preedit.cursor_end);
	}
	if (im->current.commit_text != NULL) {
		wlr_text_input_v3_send_commit_string(input, im->current.commit_text);
	}
	if (im->current.delete.before_length > 0 || im->current.delete.after_length > 0) {
		wlr_text_input_v3_send_delete_surrounding_text(input,
				im->current.delete.before_length, im->current.delete.after_length);
	}
	wlr_text_input_v3_send_done(input);
}

// El motor toma el teclado (composición/preedit): se le da el keymap y los
// modificadores; wl_server_key le reenvia las teclas mientras dure el grab.
static void handle_input_method_grab_keyboard(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, input_method_grab_keyboard);
	struct wlr_input_method_keyboard_grab_v2 *grab = data;
	if (s->keyboard_grab != NULL) {
		wl_list_remove(&s->keyboard_grab_destroy.link);
		wlr_input_method_keyboard_grab_v2_destroy(s->keyboard_grab);
		s->keyboard_grab = NULL;
	}
	s->keyboard_grab = grab;
	wlr_input_method_keyboard_grab_v2_set_keyboard(grab, &s->keyboard);
	wlr_input_method_keyboard_grab_v2_send_modifiers(grab, &s->keyboard.modifiers);
	s->keyboard_grab_destroy.notify = handle_keyboard_grab_destroy;
	wl_signal_add(&grab->events.destroy, &s->keyboard_grab_destroy);
}

static void handle_keyboard_grab_destroy(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, keyboard_grab_destroy);
	wl_list_remove(&s->keyboard_grab_destroy.link);
	wl_list_init(&s->keyboard_grab_destroy.link);
	s->keyboard_grab = NULL;
}

static void handle_input_method_destroy(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, input_method_destroy);
	s->active_text_input = NULL;
	wl_list_remove(&s->input_method_commit.link);
	wl_list_remove(&s->input_method_grab_keyboard.link);
	wl_list_remove(&s->input_method_destroy.link);
	s->input_method = NULL;
}

// Atributos EGL de import por plano (hasta 4, como WLR_DMABUF_MAX_PLANES).
static const EGLint dmabuf_plane_fd[4] = {
	EGL_DMA_BUF_PLANE0_FD_EXT, EGL_DMA_BUF_PLANE1_FD_EXT,
	EGL_DMA_BUF_PLANE2_FD_EXT, EGL_DMA_BUF_PLANE3_FD_EXT,
};
static const EGLint dmabuf_plane_offset[4] = {
	EGL_DMA_BUF_PLANE0_OFFSET_EXT, EGL_DMA_BUF_PLANE1_OFFSET_EXT,
	EGL_DMA_BUF_PLANE2_OFFSET_EXT, EGL_DMA_BUF_PLANE3_OFFSET_EXT,
};
static const EGLint dmabuf_plane_pitch[4] = {
	EGL_DMA_BUF_PLANE0_PITCH_EXT, EGL_DMA_BUF_PLANE1_PITCH_EXT,
	EGL_DMA_BUF_PLANE2_PITCH_EXT, EGL_DMA_BUF_PLANE3_PITCH_EXT,
};
static const EGLint dmabuf_plane_mod_lo[4] = {
	EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_LO_EXT,
	EGL_DMA_BUF_PLANE2_MODIFIER_LO_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_LO_EXT,
};
static const EGLint dmabuf_plane_mod_hi[4] = {
	EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE1_MODIFIER_HI_EXT,
	EGL_DMA_BUF_PLANE2_MODIFIER_HI_EXT, EGL_DMA_BUF_PLANE3_MODIFIER_HI_EXT,
};

// Arma la lista EGL de import de un dmabuf (todos sus planos). En esta GPU
// (Intel Iris Xe) Mesa asigna XRGB8888/ARGB8888 con modificadores con planos
// auxiliares CCS, por eso no alcanza con aceptar n_planes == 1.
static void dmabuf_egl_attrs(const struct wlr_dmabuf_attributes *attribs, EGLint *attrs) {
	int i = 0;
	attrs[i++] = EGL_WIDTH;
	attrs[i++] = attribs->width;
	attrs[i++] = EGL_HEIGHT;
	attrs[i++] = attribs->height;
	attrs[i++] = EGL_LINUX_DRM_FOURCC_EXT;
	attrs[i++] = (EGLint)attribs->format;
	int n = attribs->n_planes;
	if (n > 4) {
		n = 4;
	}
	for (int p = 0; p < n; p++) {
		attrs[i++] = dmabuf_plane_fd[p];
		attrs[i++] = attribs->fd[p];
		attrs[i++] = dmabuf_plane_offset[p];
		attrs[i++] = (EGLint)attribs->offset[p];
		attrs[i++] = dmabuf_plane_pitch[p];
		attrs[i++] = (EGLint)attribs->stride[p];
		if (attribs->modifier != DRM_FORMAT_MOD_INVALID) {
			attrs[i++] = dmabuf_plane_mod_lo[p];
			attrs[i++] = (EGLint)(attribs->modifier & 0xffffffffu);
			attrs[i++] = dmabuf_plane_mod_hi[p];
			attrs[i++] = (EGLint)(attribs->modifier >> 32);
		}
	}
	attrs[i++] = EGL_NONE;
}

// Solo aceptamos dmabuf que EGL pueda importar. Si falla, el cliente recibe
// `failed` y cae a shm.
static bool check_dmabuf(struct wlr_dmabuf_attributes *attribs, void *data) {
	struct wl_server *s = data;
	if (s->eglCreateImageKHR == NULL || attribs->n_planes < 1 || attribs->n_planes > 4) {
		return false;
	}
	EGLint attrs[64];
	dmabuf_egl_attrs(attribs, attrs);
	EGLImageKHR image = s->eglCreateImageKHR(s->egl_dpy, EGL_NO_CONTEXT,
			EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
	if (image == EGL_NO_IMAGE_KHR) {
		return false;
	}
	s->eglDestroyImageKHR(s->egl_dpy, image);
	return true;
}

// Llena `set` con los format+modifier que EGL puede importar; omite los
// external_only y usa DRM_FORMAT_MOD_INVALID cuando no hay modifiers.
static bool fill_formats(struct wl_server *s, struct wlr_drm_format_set *set) {
	EGLint num_formats = 0;
	if (!s->eglQueryDmaBufFormatsEXT(s->egl_dpy, 0, NULL, &num_formats) ||
			num_formats <= 0) {
		return false;
	}
	EGLint *formats = malloc((size_t)num_formats * sizeof(EGLint));
	if (formats == NULL) {
		return false;
	}
	if (!s->eglQueryDmaBufFormatsEXT(s->egl_dpy, num_formats, formats, &num_formats)) {
		free(formats);
		return false;
	}

	bool any = false;
	for (EGLint i = 0; i < num_formats; i++) {
		EGLint num_mods = 0;
		if (!s->eglQueryDmaBufModifiersEXT(s->egl_dpy, formats[i], 0, NULL, NULL, &num_mods)) {
			num_mods = 0;
		}
		if (num_mods <= 0) {
			if (wlr_drm_format_set_add(set, (uint32_t)formats[i], DRM_FORMAT_MOD_INVALID)) {
				any = true;
			}
			continue;
		}
		EGLuint64KHR *mods = malloc((size_t)num_mods * sizeof(EGLuint64KHR));
		EGLBoolean *external_only = malloc((size_t)num_mods * sizeof(EGLBoolean));
		if (mods == NULL || external_only == NULL) {
			free(mods);
			free(external_only);
			continue;
		}
		if (s->eglQueryDmaBufModifiersEXT(s->egl_dpy, formats[i], num_mods, mods,
				external_only, &num_mods)) {
			for (EGLint j = 0; j < num_mods; j++) {
				if (external_only[j]) {
					continue;
				}
				if (wlr_drm_format_set_add(set, (uint32_t)formats[i], (uint64_t)mods[j])) {
					any = true;
				}
			}
		}
		free(mods);
		free(external_only);
	}
	free(formats);
	return any;
}

// Anuncia linux-dmabuf con feedback armado a mano (main_device = render node).
// Si falta EGL, extensiones, funciones o el render node: solo shm, con motivo.
static void setup_dmabuf(struct wl_server *s) {
	s->dmabuf_enabled = false;
	s->dmabuf_reason = "sin EGL (GLX/x11)";

	if (getenv("GDTK_FORCE_SHM") != NULL) {
		s->dmabuf_reason = "forzado";
		return;
	}

	s->egl_dpy = eglGetCurrentDisplay();
	if (s->egl_dpy == EGL_NO_DISPLAY) {
		return;
	}

	const char *exts = eglQueryString(s->egl_dpy, EGL_EXTENSIONS);
	if (exts == NULL ||
			strstr(exts, "EGL_EXT_image_dma_buf_import") == NULL ||
			strstr(exts, "EGL_EXT_image_dma_buf_import_modifiers") == NULL) {
		s->dmabuf_reason = "sin EGL_EXT_image_dma_buf_import(_modifiers)";
		return;
	}

	s->eglCreateImageKHR = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
	s->eglDestroyImageKHR = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
	s->eglQueryDmaBufFormatsEXT = (PFNEGLQUERYDMABUFFORMATSEXTPROC)eglGetProcAddress("eglQueryDmaBufFormatsEXT");
	s->eglQueryDmaBufModifiersEXT = (PFNEGLQUERYDMABUFMODIFIERSEXTPROC)eglGetProcAddress("eglQueryDmaBufModifiersEXT");
	s->glBindTexture = (PFNGLBINDTEXTUREPROC)eglGetProcAddress("glBindTexture");
	s->glGetIntegerv = (PFNGLGETINTEGERVPROC)eglGetProcAddress("glGetIntegerv");
	s->glTexParameteri = (PFNGLTEXPARAMETERIPROC)eglGetProcAddress("glTexParameteri");
	s->glEGLImageTargetTexture2DOES = (PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
	if (s->eglCreateImageKHR == NULL || s->eglDestroyImageKHR == NULL ||
			s->eglQueryDmaBufFormatsEXT == NULL || s->eglQueryDmaBufModifiersEXT == NULL ||
			s->glBindTexture == NULL || s->glGetIntegerv == NULL ||
			s->glTexParameteri == NULL || s->glEGLImageTargetTexture2DOES == NULL) {
		s->dmabuf_reason = "faltan funciones EGL/GL";
		return;
	}

	const char *node = getenv("GDTK_DRM_RENDER_NODE");
	if (node == NULL) {
		node = "/dev/dri/renderD128";
	}
	struct stat st;
	if (stat(node, &st) != 0) {
		s->dmabuf_reason = "sin render node";
		return;
	}

	struct wlr_linux_dmabuf_feedback_v1 feedback = {0};
	struct wlr_linux_dmabuf_feedback_v1_tranche *tranche =
			wlr_linux_dmabuf_feedback_add_tranche(&feedback);
	if (tranche == NULL) {
		s->dmabuf_reason = "sin memoria (feedback)";
		return;
	}
	feedback.main_device = st.st_rdev;
	tranche->target_device = st.st_rdev;
	if (!fill_formats(s, &tranche->formats)) {
		wlr_linux_dmabuf_feedback_v1_finish(&feedback);
		s->dmabuf_reason = "sin formatos dmabuf";
		return;
	}

	// wlr_linux_dmabuf_v1_create copia el feedback; finish libera nuestros
	// wlr_drm_format_set (no volver a llamar wlr_drm_format_set_finish: double free).
	s->linux_dmabuf = wlr_linux_dmabuf_v1_create(s->display, 4, &feedback);
	wlr_linux_dmabuf_feedback_v1_finish(&feedback);
	if (s->linux_dmabuf == NULL) {
		s->dmabuf_reason = "wlr_linux_dmabuf_v1_create fallo";
		return;
	}
	wlr_linux_dmabuf_v1_set_check_dmabuf_callback(s->linux_dmabuf, check_dmabuf, s);

	s->dmabuf_enabled = true;
	s->dmabuf_reason = "on";
}

static void handle_toplevel_set_title(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, set_title);
	if (t->added && t->server->cb.title != NULL) {
		const char *title = t->tl != NULL ? t->tl->title : t->xs->title;
		t->server->cb.title(t->server->cb.ud, t->id, title != NULL ? title : "");
	}
}

static void toplevel_apply_focus(toplevel *t) {
	struct wl_server *s = t->server;
	struct wlr_surface *surface;
	if (t->tl != NULL) {
		if (!t->tl->base->initialized) {
			return;
		}
		wlr_xdg_toplevel_set_activated(t->tl, true);
		surface = t->tl->base->surface;
	} else {
		if (t->xs->surface == NULL) {
			return;
		}
		wlr_xwayland_surface_activate(t->xs, true);
		wlr_xwayland_surface_restack(t->xs, NULL, XCB_STACK_MODE_ABOVE);
		s->x_focus_id = t->id;
		surface = t->xs->surface;
	}
	if (t->mapped) {
		wlr_seat_keyboard_notify_enter(s->seat, surface,
				s->keyboard.keycodes, s->keyboard.num_keycodes, &s->keyboard.modifiers);
		text_input_relay_set_focus(s, surface);
	}
}

static void handle_toplevel_commit(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, commit);
	struct wl_server *s = t->server;

	if (t->tl->base->initial_commit) {
		// ponytail: sin este configure inicial el cliente espera para siempre y nunca mapea
		wlr_xdg_toplevel_set_size(t->tl, s->default_w, s->default_h);
		return;
	}
	// La importacion de buffers la hace el listener de commit por surface
	// (surface_state); aqui solo se resuelve el configure inicial.
}

static void handle_toplevel_map(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, map);
	t->mapped = true;
	if (!t->added) {
		t->added = true;
		if (t->server->cb.added != NULL) {
			t->server->cb.added(t->server->cb.ud, t->id);
		}
		handle_toplevel_set_title(&t->set_title, NULL);
	}
	if (t->want_focus) {
		toplevel_apply_focus(t);
	}
}

static void handle_toplevel_unmap(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, unmap);
	t->mapped = false;
}

// El cliente pide minimizarse: xdg_toplevel.set_minimized (CSD, p.ej. GTK/LibreWolf)
// o iconify de una ventana X11. La minimización real la decide el shell (cb.minimize);
// para xdg hay que devolver un configure (aunque no cambie el estado) o es violación
// de protocolo.
static void handle_toplevel_request_minimize(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, request_minimize);
	if (t->tl != NULL) {
		wlr_xdg_surface_schedule_configure(t->tl->base);
	} else {
		// Xwayland emite el evento también al des-iconificar (minimize=false): no es
		// un pedido de minimizar.
		struct wlr_xwayland_minimize_event *ev = data;
		if (ev != NULL && !ev->minimize) {
			return;
		}
	}
	if (t->server->cb.minimize != NULL) {
		t->server->cb.minimize(t->server->cb.ud, t->id);
	}
}

static void toplevel_unlink(toplevel *t) {
	struct wl_listener *all[] = { &t->commit, &t->map, &t->unmap, &t->destroy, &t->set_title,
		&t->request_minimize, &t->associate, &t->dissociate, &t->request_configure };
	for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
		wl_list_remove(&all[i]->link);
		wl_list_init(&all[i]->link);
	}
	wl_list_remove(&t->link);
}

static void xsurface_orphan(struct wl_server *s, struct wlr_surface *surface);

static void handle_toplevel_destroy(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, destroy);
	struct wl_server *s = t->server;

	toplevel_unlink(t);
	bool added = t->added;
	if (t->xs != NULL) {
		xsurface_orphan(s, t->xs->surface);
	}

	if (s->pointer_id == t->id) {
		s->pointer_id = 0;
		s->pointer_surface = NULL;
	}

	if (s->x_focus_id == t->id) {
		s->x_focus_id = 0;
	}
	int id = t->id;
	free(t);

	if (added && s->cb.removed != NULL) {
		s->cb.removed(s->cb.ud, id);
	}
}

// Popups (tooltips, menús): sólo se configuran, no se dibujan todavía.
// Sin el configure inicial GTK4 espera el popup para siempre y su frame clock
// (compartido con la ventana) congela también la ventana principal.
// Popups (tooltips, menus): se configuran en su commit inicial y se dibujan
// como una capa mas via wl_server_layers (wlr_xdg_surface_for_each_surface).
// Sin el configure inicial GTK4 espera el popup para siempre y su frame clock
// (compartido con la ventana) congela tambien la ventana principal.
typedef struct popup {
	struct wl_server *s;
	struct wlr_xdg_popup *p;
	struct wl_listener commit;
	struct wl_listener reposition;
	struct wl_listener destroy;
} popup;

// Reubica el popup dentro de lo visible (reglas del xdg_positioner). La caja va en coords
// de la surface raíz del toplevel: el contenido visible arranca en su geometry (las sombras
// CSD quedan fuera) y mide lo que la vista (default_w x default_h).
static void popup_unconstrain(popup *pp) {
	struct wlr_xdg_surface *xs = wlr_xdg_surface_try_from_wlr_surface(pp->p->parent);
	while (xs != NULL && xs->role == WLR_XDG_SURFACE_ROLE_POPUP && xs->popup != NULL) {
		xs = wlr_xdg_surface_try_from_wlr_surface(xs->popup->parent);
	}
	if (xs == NULL || xs->role != WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
		return;
	}
	struct wlr_box box = { xs->geometry.x, xs->geometry.y, pp->s->default_w, pp->s->default_h };
	wlr_xdg_popup_unconstrain_from_box(pp->p, &box);
}

static void handle_popup_commit(struct wl_listener *listener, void *data) {
	popup *pp = wl_container_of(listener, pp, commit);
	if (pp->p->base->initial_commit) {
		popup_unconstrain(pp);
		wlr_xdg_surface_schedule_configure(pp->p->base);
	}
}

static void handle_popup_reposition(struct wl_listener *listener, void *data) {
	popup *pp = wl_container_of(listener, pp, reposition);
	popup_unconstrain(pp);
}

static void handle_popup_destroy(struct wl_listener *listener, void *data) {
	popup *pp = wl_container_of(listener, pp, destroy);
	surface_state *st = surface_state_find(pp->s, pp->p->base->surface);
	if (st != NULL && st->id > 0 && pp->s->cb.damage != NULL) {
		pp->s->cb.damage(pp->s->cb.ud, st->id);
	}
	wl_list_remove(&pp->commit.link);
	wl_list_remove(&pp->reposition.link);
	wl_list_remove(&pp->destroy.link);
	free(pp);
}

static void handle_new_popup(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_popup);
	struct wlr_xdg_popup *p = data;
	popup *pp = calloc(1, sizeof(*pp));
	if (pp == NULL) {
		return;
	}
	pp->s = s;
	pp->p = p;
	pp->commit.notify = handle_popup_commit;
	wl_signal_add(&p->base->surface->events.commit, &pp->commit);
	pp->reposition.notify = handle_popup_reposition;
	wl_signal_add(&p->events.reposition, &pp->reposition);
	pp->destroy.notify = handle_popup_destroy;
	wl_signal_add(&p->events.destroy, &pp->destroy);

	// El popup pertenece al toplevel de su surface padre: hereda el id para
	// que sus buffers se agrupen como una capa mas de ese toplevel.
	if (surface_state_find(s, p->base->surface) == NULL) {
		int id = 0;
		surface_state *parent = surface_state_find(s, p->parent);
		if (parent != NULL) {
			id = parent->id;
		} else if (p->parent != NULL) {
			toplevel *t = toplevel_find_surface(s, wlr_surface_get_root_surface(p->parent));
			if (t != NULL) {
				id = t->id;
			}
		}
		surface_state_acquire(s, p->base->surface, id);
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
	t->added = true;
	wl_list_init(&t->associate.link);
	wl_list_init(&t->dissociate.link);
	wl_list_init(&t->request_configure.link);

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
	t->request_minimize.notify = handle_toplevel_request_minimize;
	wl_signal_add(&tl->events.request_minimize, &t->request_minimize);

	wl_list_insert(s->toplevels.prev, &t->link);

	// Estado de la surface raiz; las subsurfaces se descubren por el signal
	// new_subsurface de cada surface. Los buffers se importan en su commit.
	surface_state_acquire(s, surface, t->id);

	if (s->cb.added != NULL) {
		s->cb.added(s->cb.ud, t->id);
	}
}

// Decoraciones: pedimos server-side a todos y no dibujamos ninguna (la barra la pone el
// shell). Así alacritty/SDL/Qt no dibujan su propia barra de título. GTK4 lo ignora (CSD siempre).
typedef struct decoration {
	struct wlr_xdg_toplevel_decoration_v1 *d;
	struct wl_listener request_mode;
	struct wl_listener commit;
	struct wl_listener destroy;
} decoration;

static void decoration_apply(decoration *dd) {
	if (dd->d->toplevel->base->initialized) {
		wlr_xdg_toplevel_decoration_v1_set_mode(dd->d, WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
	}
}

static void handle_decoration_request_mode(struct wl_listener *listener, void *data) {
	decoration *dd = wl_container_of(listener, dd, request_mode);
	decoration_apply(dd);
}

static void handle_decoration_commit(struct wl_listener *listener, void *data) {
	decoration *dd = wl_container_of(listener, dd, commit);
	// set_mode agenda un configure: sólo válido desde el commit inicial en adelante.
	if (dd->d->toplevel->base->initial_commit) {
		decoration_apply(dd);
	}
}

static void handle_decoration_destroy(struct wl_listener *listener, void *data) {
	decoration *dd = wl_container_of(listener, dd, destroy);
	wl_list_remove(&dd->request_mode.link);
	wl_list_remove(&dd->commit.link);
	wl_list_remove(&dd->destroy.link);
	free(dd);
}

static void handle_new_decoration(struct wl_listener *listener, void *data) {
	struct wlr_xdg_toplevel_decoration_v1 *d = data;
	decoration *dd = calloc(1, sizeof(*dd));
	if (dd == NULL) {
		return;
	}
	dd->d = d;
	dd->request_mode.notify = handle_decoration_request_mode;
	wl_signal_add(&d->events.request_mode, &dd->request_mode);
	dd->commit.notify = handle_decoration_commit;
	wl_signal_add(&d->toplevel->base->surface->events.commit, &dd->commit);
	dd->destroy.notify = handle_decoration_destroy;
	wl_signal_add(&d->events.destroy, &dd->destroy);
	decoration_apply(dd);
}

// --- wlr-layer-shell: notificaciones, OSDs, docks. El shell las dibuja encima de todo en
// su rect (ancla + márgenes sobre la vista). ponytail: sin exclusive zone ni foco de
// teclado (keyboard_interactivity); alcanza para notificaciones.
typedef struct layer_surf {
	struct wl_list link;
	struct wl_server *s;
	int id;
	struct wlr_layer_surface_v1 *ls;
	bool mapped;
	int x, y, w, h;
	struct wl_listener commit;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener destroy;
} layer_surf;

static layer_surf *layer_find(struct wl_server *s, int id) {
	layer_surf *l;
	wl_list_for_each(l, &s->layers, link) {
		if (l->id == id) {
			return l;
		}
	}
	return NULL;
}

// Tamaño y posición según ancla y márgenes; reconfigura si cambió el tamaño.
static void layer_arrange(layer_surf *l, bool force) {
	struct wl_server *s = l->s;
	struct wlr_layer_surface_v1_state *st = &l->ls->current;
	int W = s->default_w, H = s->default_h;
	bool left = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
	bool right = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;
	bool top = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
	bool bottom = st->anchor & ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
	int w = st->desired_width > 0 ? (int)st->desired_width : W - st->margin.left - st->margin.right;
	int h = st->desired_height > 0 ? (int)st->desired_height : H - st->margin.top - st->margin.bottom;
	if (w < 1) {
		w = 1;
	}
	if (h < 1) {
		h = 1;
	}
	// Ancla a un solo lado: pegado a ese borde; a ambos o ninguno: centrado entre márgenes.
	if (left == right) {
		l->x = st->margin.left + (W - st->margin.left - st->margin.right - w) / 2;
	} else {
		l->x = left ? st->margin.left : W - w - st->margin.right;
	}
	if (top == bottom) {
		l->y = st->margin.top + (H - st->margin.top - st->margin.bottom - h) / 2;
	} else {
		l->y = top ? st->margin.top : H - h - st->margin.bottom;
	}
	if (force || w != l->w || h != l->h) {
		l->w = w;
		l->h = h;
		wlr_layer_surface_v1_configure(l->ls, (uint32_t)w, (uint32_t)h);
	}
}

static void handle_layer_commit(struct wl_listener *listener, void *data) {
	layer_surf *l = wl_container_of(listener, l, commit);
	if (l->ls->initialized) {
		layer_arrange(l, l->ls->initial_commit);
	}
}

static void handle_layer_map(struct wl_listener *listener, void *data) {
	layer_surf *l = wl_container_of(listener, l, map);
	l->mapped = true;
	if (l->s->cb.layer != NULL) {
		l->s->cb.layer(l->s->cb.ud, l->id, 1);
	}
}

static void handle_layer_unmap(struct wl_listener *listener, void *data) {
	layer_surf *l = wl_container_of(listener, l, unmap);
	l->mapped = false;
	if (l->s->cb.layer != NULL) {
		l->s->cb.layer(l->s->cb.ud, l->id, 0);
	}
}

static void layer_free(layer_surf *l) {
	wl_list_remove(&l->commit.link);
	wl_list_remove(&l->map.link);
	wl_list_remove(&l->unmap.link);
	wl_list_remove(&l->destroy.link);
	wl_list_remove(&l->link);
	free(l);
}

static void handle_layer_destroy(struct wl_listener *listener, void *data) {
	layer_surf *l = wl_container_of(listener, l, destroy);
	struct wl_server *s = l->s;
	int id = l->id;
	if (s->pointer_id == id) {
		s->pointer_id = 0;
		s->pointer_surface = NULL;
	}
	layer_free(l);
	if (s->cb.layer != NULL) {
		s->cb.layer(s->cb.ud, id, -1);
	}
}

static void handle_new_layer(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_layer);
	struct wlr_layer_surface_v1 *ls = data;
	if (ls->output == NULL) {
		if (s->output == NULL) {
			wlr_layer_surface_v1_destroy(ls);
			return;
		}
		ls->output = s->output;
	}
	layer_surf *l = calloc(1, sizeof(*l));
	if (l == NULL) {
		wlr_layer_surface_v1_destroy(ls);
		return;
	}
	l->s = s;
	l->ls = ls;
	// Mismo espacio de ids que los toplevels: las texturas se guardan igual en C++.
	l->id = s->next_id++;
	l->commit.notify = handle_layer_commit;
	wl_signal_add(&ls->surface->events.commit, &l->commit);
	l->map.notify = handle_layer_map;
	wl_signal_add(&ls->surface->events.map, &l->map);
	l->unmap.notify = handle_layer_unmap;
	wl_signal_add(&ls->surface->events.unmap, &l->unmap);
	l->destroy.notify = handle_layer_destroy;
	wl_signal_add(&ls->events.destroy, &l->destroy);
	wl_list_insert(s->layers.prev, &l->link);
	surface_state_acquire(s, ls->surface, l->id);
}

// xdg-activation: sin validar el token (cualquier cliente puede pedir el frente).
static void handle_request_activate(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, request_activate);
	struct wlr_xdg_activation_v1_request_activate_event *ev = data;
	toplevel *t = toplevel_find_surface(s, ev->surface);
	if (t != NULL && s->cb.activate != NULL) {
		s->cb.activate(s->cb.ud, t->id);
	}
}

// Portapapeles: wlroots sólo cambia la selección si el compositor acepta el pedido.
static void handle_request_set_selection(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, request_set_selection);
	struct wlr_seat_request_set_selection_event *ev = data;
	wlr_seat_set_selection(s->seat, ev->source, ev->serial);
}

static void handle_request_set_primary_selection(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, request_set_primary_selection);
	struct wlr_seat_request_set_primary_selection_event *ev = data;
	wlr_seat_set_primary_selection(s->seat, ev->source, ev->serial);
}

// --- Xwayland (perezoso: el X arranca con el primer cliente X). Las ventanas X normales
// van en 0,0 del root con el tamaño de la vista, como las xdg; los diálogos, centrados
// (así los ve el shell); los override-redirect son capas de su dueño.
// ponytail: sin decoraciones, sin mover/redimensionar por el cliente, sin ventanas X
// fuera de la vista.

static toplevel *toplevel_find_xs(struct wl_server *s, struct wlr_xwayland_surface *xs) {
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->xs == xs) {
			return t;
		}
	}
	return NULL;
}

// Hit-test de una ventana X: primero sus menús (arriba), después la ventana.
static struct wlr_surface *xwayland_surface_at(toplevel *t, double x, double y, double *sx, double *sy) {
	xor_surf *o;
	wl_list_for_each_reverse(o, &t->server->xors, link) {
		if (o->mapped && o->owner == t->id && o->xs->surface != NULL) {
			double ox = x - (o->xs->x - t->xs->x);
			double oy = y - (o->xs->y - t->xs->y);
			struct wlr_surface *hit = wlr_surface_surface_at(o->xs->surface, ox, oy, sx, sy);
			if (hit != NULL) {
				return hit;
			}
		}
	}
	return t->xs->surface != NULL ? wlr_surface_surface_at(t->xs->surface, x, y, sx, sy) : NULL;
}

// Normales: toda la vista en 0,0. Diálogos (con padre): su tamaño, centrados.
static void xtoplevel_configure(toplevel *t, int w, int h) {
	struct wl_server *s = t->server;

	if (t->xs->parent == NULL) {
		wlr_xwayland_surface_configure(t->xs, 0, 0, (uint16_t)s->default_w, (uint16_t)s->default_h);
		return;
	}
	if (w <= 0 || h <= 0) {
		w = t->xs->width > 0 ? t->xs->width : s->default_w / 2;
		h = t->xs->height > 0 ? t->xs->height : s->default_h / 2;
	}
	wlr_xwayland_surface_configure(t->xs, (int16_t)((s->default_w - w) / 2),
			(int16_t)((s->default_h - h) / 2), (uint16_t)w, (uint16_t)h);
}

// Antes de asociar la surface el padre (WM_TRANSIENT_FOR) puede no estar leído: se
// concede lo pedido y la política se aplica al asociar.
static void handle_xtoplevel_request_configure(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, request_configure);
	struct wlr_xwayland_surface_configure_event *ev = data;
	if (t->xs->surface == NULL) {
		wlr_xwayland_surface_configure(t->xs, ev->x, ev->y, ev->width, ev->height);
		return;
	}
	xtoplevel_configure(t, ev->width, ev->height);
}

static void handle_xtoplevel_associate(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, associate);
	struct wlr_surface *surface = t->xs->surface;
	wl_signal_add(&surface->events.map, &t->map);
	wl_signal_add(&surface->events.unmap, &t->unmap);
	if (surface_state_find(t->server, surface) == NULL) {
		surface_state_acquire(t->server, surface, t->id);
	}
	xtoplevel_configure(t, 0, 0);
	if (surface->mapped) {
		handle_toplevel_map(&t->map, NULL);
	}
}

// La wl_surface de Xwayland puede sobrevivir a la ventana X: sus commits ya no son de nadie.
static void xsurface_orphan(struct wl_server *s, struct wlr_surface *surface) {
	surface_state *st = surface != NULL ? surface_state_find(s, surface) : NULL;
	if (st != NULL) {
		st->id = 0;
	}
}

static void handle_xtoplevel_dissociate(struct wl_listener *listener, void *data) {
	toplevel *t = wl_container_of(listener, t, dissociate);
	xsurface_orphan(t->server, t->xs->surface);
	wl_list_remove(&t->map.link);
	wl_list_init(&t->map.link);
	wl_list_remove(&t->unmap.link);
	wl_list_init(&t->unmap.link);
	t->mapped = false;
}

static void handle_xor_map(struct wl_listener *listener, void *data);

static void handle_xor_associate(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, associate);
	wl_signal_add(&o->xs->surface->events.map, &o->map);
	wl_signal_add(&o->xs->surface->events.unmap, &o->unmap);
	if (o->xs->surface->mapped) {
		handle_xor_map(&o->map, NULL);
	}
}

static void handle_xor_dissociate(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, dissociate);
	xsurface_orphan(o->server, o->xs->surface);
	wl_list_remove(&o->map.link);
	wl_list_init(&o->map.link);
	wl_list_remove(&o->unmap.link);
	wl_list_init(&o->unmap.link);
	o->mapped = false;
}

// Dueño: la ventana X padre si la hay; si no, la última ventana X enfocada.
static void handle_xor_map(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, map);
	struct wl_server *s = o->server;
	toplevel *p = NULL;
	for (struct wlr_xwayland_surface *x = o->xs->parent; x != NULL && p == NULL; x = x->parent) {
		p = toplevel_find_xs(s, x);
	}
	o->owner = p != NULL ? p->id : s->x_focus_id;
	o->mapped = true;
	// El map llega dentro del commit del primer buffer: se importa ya (un menú quieto no
	// vuelve a commitear).
	surface_state *st = surface_state_find(s, o->xs->surface);
	if (st == NULL) {
		surface_state_acquire(s, o->xs->surface, o->owner);
		st = surface_state_find(s, o->xs->surface);
	}
	if (st != NULL) {
		st->id = o->owner;
		surface_state_import(st);
	}
}

static void handle_xor_unmap(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, unmap);
	o->mapped = false;
	if (o->server->cb.damage != NULL) {
		o->server->cb.damage(o->server->cb.ud, o->owner);
	}
}

static void xor_free(xor_surf *o) {
	struct wl_listener *all[] = { &o->associate, &o->dissociate, &o->map, &o->unmap, &o->destroy };
	for (size_t i = 0; i < sizeof(all) / sizeof(all[0]); i++) {
		wl_list_remove(&all[i]->link);
	}
	wl_list_remove(&o->link);
	free(o);
}

static void handle_xor_destroy(struct wl_listener *listener, void *data) {
	xor_surf *o = wl_container_of(listener, o, destroy);
	xor_free(o);
}

static void handle_new_xsurface(struct wl_listener *listener, void *data) {
	struct wl_server *s = wl_container_of(listener, s, new_xsurface);
	struct wlr_xwayland_surface *xs = data;
	if (xs->override_redirect) {
		xor_surf *o = calloc(1, sizeof(*o));
		if (o == NULL) {
			return;
		}
		o->server = s;
		o->xs = xs;
		o->associate.notify = handle_xor_associate;
		wl_signal_add(&xs->events.associate, &o->associate);
		o->dissociate.notify = handle_xor_dissociate;
		wl_signal_add(&xs->events.dissociate, &o->dissociate);
		o->map.notify = handle_xor_map;
		wl_list_init(&o->map.link);
		o->unmap.notify = handle_xor_unmap;
		wl_list_init(&o->unmap.link);
		o->destroy.notify = handle_xor_destroy;
		wl_signal_add(&xs->events.destroy, &o->destroy);
		wl_list_insert(s->xors.prev, &o->link);
		return;
	}
	toplevel *t = calloc(1, sizeof(*t));
	if (t == NULL) {
		return;
	}
	t->server = s;
	t->xs = xs;
	t->id = s->next_id++;
	wl_list_init(&t->commit.link);
	t->map.notify = handle_toplevel_map;
	wl_list_init(&t->map.link);
	t->unmap.notify = handle_toplevel_unmap;
	wl_list_init(&t->unmap.link);
	t->destroy.notify = handle_toplevel_destroy;
	wl_signal_add(&xs->events.destroy, &t->destroy);
	t->set_title.notify = handle_toplevel_set_title;
	wl_signal_add(&xs->events.set_title, &t->set_title);
	t->request_minimize.notify = handle_toplevel_request_minimize;
	wl_signal_add(&xs->events.request_minimize, &t->request_minimize);
	t->associate.notify = handle_xtoplevel_associate;
	wl_signal_add(&xs->events.associate, &t->associate);
	t->dissociate.notify = handle_xtoplevel_dissociate;
	wl_signal_add(&xs->events.dissociate, &t->dissociate);
	t->request_configure.notify = handle_xtoplevel_request_configure;
	wl_signal_add(&xs->events.request_configure, &t->request_configure);
	wl_list_insert(s->toplevels.prev, &t->link);
}

static void output_set_size(struct wl_server *s) {
	struct wlr_output_state state;
	wlr_output_state_init(&state);
	wlr_output_state_set_enabled(&state, true);
	wlr_output_state_set_custom_mode(&state, s->default_w, s->default_h, 60000);
	if (!wlr_output_commit_state(s->output, &state)) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo configurar el output %dx%d", s->default_w, s->default_h);
	}
	wlr_output_state_finish(&state);
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
	s->egl_dpy = EGL_NO_DISPLAY;
	wl_list_init(&s->toplevels);
	wl_list_init(&s->surfaces);
	wl_list_init(&s->layers);
	wl_list_init(&s->xors);
	wl_list_init(&s->text_inputs);

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

	// ponytail: sin renderer en wlroots (NULL); los clientes usan la GPU y
	// nosotros leemos el buffer. wl_shm explicito con los dos formatos que
	// sabemos convertir.
	s->compositor = wlr_compositor_create(s->display, 5, NULL);
	s->subcompositor = wlr_subcompositor_create(s->display);
	s->data_device_manager = wlr_data_device_manager_create(s->display);
	s->xdg_shell = wlr_xdg_shell_create(s->display, 3);

	// xdg-foreign v1 (GTK3: Firefox, xdg-desktop-portal-gtk) y v2 (GTK4): el
	// selector de archivos del portal es otro cliente y sin esto no puede
	// hacerse transient de la ventana que lo pidió; quedaría huérfano.
	s->foreign_registry = wlr_xdg_foreign_registry_create(s->display);
	if (s->foreign_registry != NULL) {
		s->foreign_v1 = wlr_xdg_foreign_v1_create(s->display, s->foreign_registry);
		s->foreign_v2 = wlr_xdg_foreign_v2_create(s->display, s->foreign_registry);
	} else {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_xdg_foreign_registry_create");
	}

	// Un wl_output del tamaño de la vista: GTK3 (Firefox) limita los popups al área del
	// monitor, y sin ningún output los configuraba a 1x1 y los descartaba.
	s->output = wlr_headless_add_output(s->backend, s->default_w, s->default_h);
	if (s->output != NULL) {
		output_set_size(s);
		wlr_output_create_global(s->output, s->display);
		// xdg-output (tamaño lógico del monitor: Qt/GTK/SDL lo piden) necesita un layout.
		struct wlr_output_layout *layout = wlr_output_layout_create(s->display);
		if (layout != NULL && wlr_output_layout_add_auto(layout, s->output) != NULL) {
			wlr_xdg_output_manager_v1_create(s->display, layout);
		}
	}
	if (s->compositor == NULL || s->subcompositor == NULL ||
			s->data_device_manager == NULL || s->xdg_shell == NULL) {
		wlr_log(WLR_ERROR, "wl_server: fallo al crear globals de wlroots");
		goto fail;
	}

	static const uint32_t shm_formats[] = {
		DRM_FORMAT_ARGB8888,
		DRM_FORMAT_XRGB8888,
	};
	if (wlr_shm_create(s->display, 2, shm_formats, 2) == NULL) {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_shm_create");
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

	// IME (K14): text-input-v3 para los clientes y input-method-v2 para el motor.
	// Si no hay motor conectado, text-input queda anunciado pero inactivo.
	s->text_input_manager = wlr_text_input_manager_v3_create(s->display);
	if (s->text_input_manager != NULL) {
		s->new_text_input.notify = handle_new_text_input;
		wl_signal_add(&s->text_input_manager->events.new_text_input, &s->new_text_input);
	} else {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_text_input_manager_v3_create");
	}
	s->input_method_manager = wlr_input_method_manager_v2_create(s->display);
	if (s->input_method_manager != NULL) {
		s->new_input_method.notify = handle_new_input_method;
		wl_signal_add(&s->input_method_manager->events.new_input_method, &s->new_input_method);
	} else {
		wlr_log(WLR_ERROR, "wl_server: fallo wlr_input_method_manager_v2_create");
	}

	s->new_toplevel.notify = handle_new_toplevel;
	wl_signal_add(&s->xdg_shell->events.new_toplevel, &s->new_toplevel);
	s->new_popup.notify = handle_new_popup;
	wl_signal_add(&s->xdg_shell->events.new_popup, &s->new_popup);

	struct wlr_xdg_decoration_manager_v1 *deco_mgr = wlr_xdg_decoration_manager_v1_create(s->display);
	if (deco_mgr != NULL) {
		s->new_decoration.notify = handle_new_decoration;
		wl_signal_add(&deco_mgr->events.new_toplevel_decoration, &s->new_decoration);
	}
	struct wlr_layer_shell_v1 *layer_shell = wlr_layer_shell_v1_create(s->display, 4);
	if (layer_shell != NULL) {
		s->new_layer.notify = handle_new_layer;
		wl_signal_add(&layer_shell->events.new_surface, &s->new_layer);
	}
	struct wlr_xdg_activation_v1 *activation = wlr_xdg_activation_v1_create(s->display);
	if (activation != NULL) {
		s->request_activate.notify = handle_request_activate;
		wl_signal_add(&activation->events.request_activate, &s->request_activate);
	}
	wlr_primary_selection_v1_device_manager_create(s->display);
	s->request_set_selection.notify = handle_request_set_selection;
	wl_signal_add(&s->seat->events.request_set_selection, &s->request_set_selection);
	s->request_set_primary_selection.notify = handle_request_set_primary_selection;
	wl_signal_add(&s->seat->events.request_set_primary_selection, &s->request_set_primary_selection);

	struct wlr_server_decoration_manager *kde_deco = wlr_server_decoration_manager_create(s->display);
	if (kde_deco != NULL) {
		wlr_server_decoration_manager_set_default_mode(kde_deco, WLR_SERVER_DECORATION_MANAGER_MODE_SERVER);
	}

	// GDTK_NO_XWAYLAND=1: sin X (las apps sólo X11 no abren).
	if (getenv("GDTK_NO_XWAYLAND") == NULL) {
		s->xwayland = wlr_xwayland_create(s->display, s->compositor, true);
		if (s->xwayland != NULL) {
			wlr_xwayland_set_seat(s->xwayland, s->seat);
			s->new_xsurface.notify = handle_new_xsurface;
			wl_signal_add(&s->xwayland->events.new_surface, &s->new_xsurface);
			wlr_log(WLR_INFO, "wl_server: Xwayland (perezoso) en %s", s->xwayland->display_name);
		}
	}

	s->socket_name = wl_display_add_socket_auto(s->display);
	if (s->socket_name == NULL) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo crear el socket wayland");
		goto fail;
	}

	if (!wlr_backend_start(s->backend)) {
		wlr_log(WLR_ERROR, "wl_server: no se pudo arrancar el backend");
		goto fail;
	}

	setup_dmabuf(s);
	wlr_log(WLR_INFO, "wl_server: dmabuf %s", s->dmabuf_reason);

	return s;

fail:
	wl_server_destroy(s);
	return NULL;
}

const char *wl_server_xdisplay(wl_server *s) {
	return s != NULL && s->xwayland != NULL && s->xwayland->display_name != NULL ? s->xwayland->display_name : "";
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

static void send_frame_done_iter(struct wlr_surface *surface, int sx, int sy, void *data) {
	wlr_surface_send_frame_done(surface, data);
}

void wl_server_frame_done(wl_server *s) {
	if (s == NULL) {
		return;
	}
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		if (t->mapped && (t->visible || !s->throttle)) {
			// Todo el árbol (subsurfaces y popups): un frame callback sin respuesta
			// en cualquiera de ellos congela el frame clock de GTK4.
			if (t->tl != NULL) {
				wlr_xdg_surface_for_each_surface(t->tl->base, send_frame_done_iter, &now);
			} else if (t->xs->surface != NULL) {
				wlr_surface_for_each_surface(t->xs->surface, send_frame_done_iter, &now);
			}
		}
	}
	layer_surf *l;
	wl_list_for_each(l, &s->layers, link) {
		if (l->mapped) {
			wlr_layer_surface_v1_for_each_surface(l->ls, send_frame_done_iter, &now);
		}
	}
	xor_surf *o;
	wl_list_for_each(o, &s->xors, link) {
		if (o->mapped && o->xs->surface != NULL) {
			wlr_surface_for_each_surface(o->xs->surface, send_frame_done_iter, &now);
		}
	}
}

void wl_server_set_visible(wl_server *s, const int *ids, int n) {
	if (s == NULL) {
		return;
	}
	s->throttle = true;
	toplevel *t;
	wl_list_for_each(t, &s->toplevels, link) {
		t->visible = false;
		for (int i = 0; i < n; i++) {
			if (ids[i] == t->id) {
				t->visible = true;
				break;
			}
		}
	}
}

void wl_server_set_size(wl_server *s, int id, int w, int h) {
	if (s == NULL || w <= 0 || h <= 0) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->tl != NULL && t->tl->base->initialized) {
		wlr_xdg_toplevel_set_size(t->tl, w, h);
	} else if (t != NULL && t->xs != NULL) {
		wlr_xwayland_surface_configure(t->xs, 0, 0, (uint16_t)w, (uint16_t)h);
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
	if (s->output != NULL && (s->output->width != s->default_w || s->output->height != s->default_h)) {
		output_set_size(s);
		layer_surf *l;
		wl_list_for_each(l, &s->layers, link) {
			if (l->ls->initialized) {
				layer_arrange(l, false);
			}
		}
	}
}

void wl_server_close(wl_server *s, int id) {
	if (s == NULL) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->tl != NULL && t->tl->base->initialized) {
		wlr_xdg_toplevel_send_close(t->tl);
	} else if (t != NULL && t->xs != NULL) {
		wlr_xwayland_surface_close(t->xs);
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
	// Hit-test sobre todo el arbol (popups primero). x,y llegan relativos a la
	// raiz; sub_x,sub_y quedan en coords locales de la surface elegida.
	double sub_x = 0.0;
	double sub_y = 0.0;
	struct wlr_surface *surface = NULL;
	toplevel *t = toplevel_find(s, id);
	layer_surf *l = t == NULL ? layer_find(s, id) : NULL;
	if (t != NULL && t->tl != NULL) {
		surface = wlr_xdg_surface_surface_at(t->tl->base, x, y, &sub_x, &sub_y);
	} else if (t != NULL) {
		surface = xwayland_surface_at(t, x, y, &sub_x, &sub_y);
	} else if (l != NULL && l->mapped) {
		surface = wlr_layer_surface_v1_surface_at(l->ls, x, y, &sub_x, &sub_y);
	} else {
		return;
	}
	if (surface == NULL) {
		if (s->pointer_surface != NULL) {
			s->pointer_surface = NULL;
			s->pointer_id = 0;
			wlr_seat_pointer_notify_clear_focus(s->seat);
		}
		return;
	}
	if (s->pointer_surface != surface) {
		s->pointer_surface = surface;
		s->pointer_id = id;
		wlr_seat_pointer_notify_enter(s->seat, surface, sub_x, sub_y);
	}
	wlr_seat_pointer_notify_motion(s->seat, time_ms, sub_x, sub_y);
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
	// IME (K14): con un grab activo el motor procesa la tecla (composicion) y
	// decide que reenviar; no llega directo al cliente.
	if (s->keyboard_grab != NULL) {
		wlr_keyboard_notify_key(&s->keyboard, &ev);
		wlr_input_method_keyboard_grab_v2_send_key(s->keyboard_grab, time_ms,
				evdev_key, ev.state);
		wlr_input_method_keyboard_grab_v2_send_modifiers(s->keyboard_grab,
				&s->keyboard.modifiers);
		return;
	}
	wlr_keyboard_notify_key(&s->keyboard, &ev);
	wlr_seat_keyboard_notify_modifiers(s->seat, &s->keyboard.modifiers);
	wlr_seat_keyboard_notify_key(s->seat, time_ms, evdev_key, ev.state);
}

int wl_server_dmabuf_enabled(wl_server *s) {
	return s != NULL && s->dmabuf_enabled;
}

const char *wl_server_dmabuf_reason(wl_server *s) {
	if (s == NULL || s->dmabuf_reason == NULL) {
		return "sin servidor";
	}
	return s->dmabuf_reason;
}

// --- Layout por surface (todo el arbol del toplevel) ---

struct layer_data {
	wl_server_layer *out;
	int max;
	int count;
};

static void layer_iterator(struct wlr_surface *surface, int sx, int sy, void *data) {
	struct layer_data *d = data;
	if (d->count >= d->max) {
		return;
	}
	wl_server_layer *l = &d->out[d->count++];
	l->key = (uint64_t)(uintptr_t)surface;
	l->x = sx;
	l->y = sy;
	l->w = surface->current.width;
	l->h = surface->current.height;
}

int wl_server_geometry(wl_server *s, int id, int *x, int *y, int *w, int *h) {
	toplevel *t = s != NULL ? toplevel_find(s, id) : NULL;
	if (t != NULL && t->xs != NULL) {
		*x = 0;
		*y = 0;
		*w = t->xs->width;
		*h = t->xs->height;
		return t->xs->surface != NULL;
	}
	if (t == NULL || !t->tl->base->initialized) {
		return 0;
	}
	struct wlr_box *g = &t->tl->base->geometry;
	*x = g->x;
	*y = g->y;
	*w = g->width;
	*h = g->height;
	return 1;
}

int wl_server_parent(wl_server *s, int id) {
	if (s == NULL) {
		return 0;
	}
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->xs != NULL) {
		toplevel *p = t->xs->parent != NULL ? toplevel_find_xs(s, t->xs->parent) : NULL;
		return p != NULL ? p->id : 0;
	}
	if (t == NULL || t->tl->parent == NULL) {
		return 0;
	}
	// El parent puede ser un toplevel todavia vivo: se busca por su surface raiz.
	toplevel *p = toplevel_find_surface(s, t->tl->parent->base->surface);
	return p != NULL ? p->id : 0;
}

const char *wl_server_app_id(wl_server *s, int id) {
	if (s == NULL) {
		return "";
	}
	toplevel *t = toplevel_find(s, id);
	const char *app_id = t == NULL ? NULL : t->tl != NULL ? t->tl->app_id : t->xs->class;
	return app_id != NULL ? app_id : "";
}

int wl_server_layers(wl_server *s, int id, wl_server_layer *out, int max) {
	if (s == NULL || out == NULL || max <= 0) {
		return 0;
	}
	struct layer_data d = { out, max, 0 };
	toplevel *t = toplevel_find(s, id);
	if (t != NULL && t->mapped && t->tl != NULL) {
		// Orden raiz -> hojas, que es el orden de dibujo de wlroots.
		wlr_xdg_surface_for_each_surface(t->tl->base, layer_iterator, &d);
		return d.count;
	}
	if (t != NULL && t->mapped && t->xs->surface != NULL) {
		wlr_surface_for_each_surface(t->xs->surface, layer_iterator, &d);
		// Menús/tooltips X encima, relativos a la ventana dueña.
		xor_surf *o;
		wl_list_for_each(o, &s->xors, link) {
			if (o->mapped && o->owner == id && o->xs->surface != NULL) {
				int base = d.count;
				wlr_surface_for_each_surface(o->xs->surface, layer_iterator, &d);
				for (int i = base; i < d.count; i++) {
					d.out[i].x += o->xs->x - t->xs->x;
					d.out[i].y += o->xs->y - t->xs->y;
				}
			}
		}
		return d.count;
	}
	layer_surf *l = t == NULL ? layer_find(s, id) : NULL;
	if (l != NULL && l->mapped) {
		wlr_layer_surface_v1_for_each_surface(l->ls, layer_iterator, &d);
	}
	return d.count;
}

int wl_server_layer_surfaces(wl_server *s, wl_server_layer_surface *out, int max) {
	if (s == NULL || out == NULL) {
		return 0;
	}
	int n = 0;
	for (int layer = 0; layer <= ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY; layer++) {
		layer_surf *l;
		wl_list_for_each(l, &s->layers, link) {
			if (n < max && l->mapped && (int)l->ls->current.layer == layer) {
				out[n++] = (wl_server_layer_surface){ l->id, layer, l->x, l->y, l->w, l->h };
			}
		}
	}
	return n;
}

void wl_server_bind_dmabuf(wl_server *s, uint64_t key, unsigned int texid) {
	if (s == NULL || !s->dmabuf_enabled || s->egl_dpy == EGL_NO_DISPLAY) {
		return;
	}
	surface_state *st = surface_state_find_key(s, key);
	if (st == NULL || st->buffer == NULL) {
		return;
	}
	struct wlr_dmabuf_attributes attribs;
	if (!wlr_buffer_get_dmabuf(st->buffer, &attribs)) {
		return;
	}

	EGLint attrs[64];
	dmabuf_egl_attrs(&attribs, attrs);
	EGLImageKHR image = s->eglCreateImageKHR(s->egl_dpy, EGL_NO_CONTEXT,
			EGL_LINUX_DMA_BUF_EXT, NULL, attrs);
	if (image == EGL_NO_IMAGE_KHR) {
		return;
	}

	GLint prev = 0;
	s->glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev);
	s->glBindTexture(GL_TEXTURE_2D, (GLuint)texid);
	s->glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)image);
	// El camino shm recibe estos parametros en texture_set_data; al importar el
	// EGLImage hay que ponerlos a mano o el filtro minimo por defecto
	// (mipmap-incomplete, sin mipmaps) devuelve negro.
	s->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	s->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	s->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	s->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	s->glBindTexture(GL_TEXTURE_2D, (GLuint)prev);
	s->eglDestroyImageKHR(s->egl_dpy, image);
	// ponytail: sync implicita (Mesa/Intel); explicit sync (linux-drm-syncobj) si hay tearing.
}

void wl_server_destroy(wl_server *s) {
	if (s == NULL) {
		return;
	}

	// Evitar callbacks hacia Godot mientras se desmonta la escena.
	memset(&s->cb, 0, sizeof(s->cb));

	if (s->new_toplevel.notify != NULL) {
		wl_list_remove(&s->new_toplevel.link);
	}
	if (s->new_popup.notify != NULL) {
		wl_list_remove(&s->new_popup.link);
	}
	if (s->new_decoration.notify != NULL) {
		wl_list_remove(&s->new_decoration.link);
	}
	struct wl_listener *extra[] = { &s->new_layer, &s->request_activate,
		&s->request_set_selection, &s->request_set_primary_selection, &s->new_xsurface,
		&s->new_text_input, &s->new_input_method };
	for (size_t i = 0; i < sizeof(extra) / sizeof(extra[0]); i++) {
		if (extra[i]->notify != NULL) {
			wl_list_remove(&extra[i]->link);
		}
	}

	if (s->xwayland != NULL) {
		wlr_xwayland_destroy(s->xwayland);
		s->xwayland = NULL;
	}
	if (s->display != NULL) {
		wl_display_destroy_clients(s->display);
	}

	// IME (K14): los text-input y el input-method normalmente ya murieron con
	// sus clientes (events.destroy). Red de seguridad.
	s->active_text_input = NULL;
	if (s->input_method != NULL) {
		wl_list_remove(&s->input_method_commit.link);
		wl_list_remove(&s->input_method_grab_keyboard.link);
		wl_list_remove(&s->input_method_destroy.link);
		s->input_method = NULL;
	}
	if (s->keyboard_grab != NULL) {
		wl_list_remove(&s->keyboard_grab_destroy.link);
		s->keyboard_grab = NULL;
	}
	text_input_relay *ti, *titmp;
	wl_list_for_each_safe(ti, titmp, &s->text_inputs, link) {
		wl_list_remove(&ti->enable.link);
		wl_list_remove(&ti->commit.link);
		wl_list_remove(&ti->disable.link);
		wl_list_remove(&ti->destroy.link);
		wl_list_remove(&ti->link);
		free(ti);
	}

	// Red de seguridad: los toplevels normalmente ya se liberaron en destroy.
	toplevel *t, *tmp;
	wl_list_for_each_safe(t, tmp, &s->toplevels, link) {
		toplevel_unlink(t);
		free(t);
	}
	xor_surf *o, *otmp;
	wl_list_for_each_safe(o, otmp, &s->xors, link) {
		xor_free(o);
	}

	layer_surf *l, *ltmp;
	wl_list_for_each_safe(l, ltmp, &s->layers, link) {
		layer_free(l);
	}

	// Red de seguridad: las surface_state normalmente ya se liberaron en
	// events.destroy al destruir los clientes.
	surface_state *st, *stmp;
	wl_list_for_each_safe(st, stmp, &s->surfaces, link) {
		wl_list_remove(&st->commit.link);
		wl_list_remove(&st->new_subsurface.link);
		wl_list_remove(&st->destroy.link);
		wl_list_remove(&st->link);
		surface_state_release_buffer(st);
		free(st);
	}

	if (s->backend != NULL) {
		wlr_backend_destroy(s->backend);
	}
	if (s->display != NULL) {
		wl_display_destroy(s->display);
	}

	free(s);
}
