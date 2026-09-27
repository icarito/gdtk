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
#include <wlr/interfaces/wlr_keyboard.h>
#include <wlr/render/dmabuf.h>
#include <wlr/render/drm_format_set.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_shm.h>
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

	// buffer dmabuf/shm vigente, retenido con wlr_buffer_lock mientras Godot lo
	// samplea; se suelta al llegar uno nuevo o en destroy.
	struct wlr_buffer *buffer;

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
	struct wlr_compositor *compositor;
	struct wlr_subcompositor *subcompositor;
	struct wlr_data_device_manager *data_device_manager;
	struct wlr_xdg_shell *xdg_shell;
	struct wlr_seat *seat;
	struct wlr_keyboard keyboard;

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
	struct wl_list toplevels;
	int next_id;
	int default_w, default_h;

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

	// current.buffer != NULL solo cuando este commit trae buffer nuevo. El
	// handler de commit corre antes de que wlroots lo suelte (ver wlr_surface.c),
	// asi que es valido leerlo aqui.
	struct wlr_buffer *buf = surface->current.buffer;
	if (buf == NULL) {
		return;
	}

	if (buf != t->buffer) {
		wlr_buffer_lock(buf);
		if (t->buffer != NULL) {
			wlr_buffer_unlock(t->buffer);
		}
		t->buffer = buf;
	}

	struct wlr_dmabuf_attributes attribs;
	if (s->dmabuf_enabled && wlr_buffer_get_dmabuf(buf, &attribs)) {
		if (s->cb.dmabuf != NULL) {
			s->cb.dmabuf(s->cb.ud, t->id, attribs.width, attribs.height);
		}
		return;
	}

	// Camino shm: puntero directo al buffer del cliente, sin copia en C. El C++
	// convierte a RGBA8 durante la llamada.
	void *ptr = NULL;
	uint32_t format = 0;
	size_t stride = 0;
	if (!wlr_buffer_begin_data_ptr_access(buf, WLR_BUFFER_DATA_PTR_ACCESS_READ,
			&ptr, &format, &stride)) {
		return;
	}
	if (s->cb.frame != NULL) {
		s->cb.frame(s->cb.ud, t->id, (const unsigned char *)ptr, buf->width, buf->height,
				format, (int)stride);
	}
	wlr_buffer_end_data_ptr_access(buf);
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

static void toplevel_release_buffer(toplevel *t) {
	if (t->buffer != NULL) {
		wlr_buffer_unlock(t->buffer);
		t->buffer = NULL;
	}
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

	toplevel_release_buffer(t);

	int id = t->id;
	free(t);

	if (s->cb.removed != NULL) {
		s->cb.removed(s->cb.ud, id);
	}
}

// Popups (tooltips, menús): sólo se configuran, no se dibujan todavía.
// Sin el configure inicial GTK4 espera el popup para siempre y su frame clock
// (compartido con la ventana) congela también la ventana principal.
// ponytail: popups invisibles; dibujarlos = componer su surface en popup->current.geometry.
typedef struct popup {
	struct wlr_xdg_popup *p;
	struct wl_listener commit;
	struct wl_listener destroy;
} popup;

static void handle_popup_commit(struct wl_listener *listener, void *data) {
	popup *pp = wl_container_of(listener, pp, commit);
	if (pp->p->base->initial_commit) {
		wlr_xdg_surface_schedule_configure(pp->p->base);
	}
}

static void handle_popup_destroy(struct wl_listener *listener, void *data) {
	popup *pp = wl_container_of(listener, pp, destroy);
	wl_list_remove(&pp->commit.link);
	wl_list_remove(&pp->destroy.link);
	free(pp);
}

static void handle_new_popup(struct wl_listener *listener, void *data) {
	struct wlr_xdg_popup *p = data;
	popup *pp = calloc(1, sizeof(*pp));
	if (pp == NULL) {
		return;
	}
	pp->p = p;
	pp->commit.notify = handle_popup_commit;
	wl_signal_add(&p->base->surface->events.commit, &pp->commit);
	pp->destroy.notify = handle_popup_destroy;
	wl_signal_add(&p->events.destroy, &pp->destroy);
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
	s->egl_dpy = EGL_NO_DISPLAY;
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

	// ponytail: sin renderer en wlroots (NULL); los clientes usan la GPU y
	// nosotros leemos el buffer. wl_shm explicito con los dos formatos que
	// sabemos convertir.
	s->compositor = wlr_compositor_create(s->display, 5, NULL);
	s->subcompositor = wlr_subcompositor_create(s->display);
	s->data_device_manager = wlr_data_device_manager_create(s->display);
	s->xdg_shell = wlr_xdg_shell_create(s->display, 3);
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

	s->new_toplevel.notify = handle_new_toplevel;
	wl_signal_add(&s->xdg_shell->events.new_toplevel, &s->new_toplevel);
	s->new_popup.notify = handle_new_popup;
	wl_signal_add(&s->xdg_shell->events.new_popup, &s->new_popup);

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
		if (t->mapped) {
			// Todo el árbol (subsurfaces y popups): un frame callback sin respuesta
			// en cualquiera de ellos congela el frame clock de GTK4.
			wlr_xdg_surface_for_each_surface(t->tl->base, send_frame_done_iter, &now);
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

int wl_server_dmabuf_enabled(wl_server *s) {
	return s != NULL && s->dmabuf_enabled;
}

const char *wl_server_dmabuf_reason(wl_server *s) {
	if (s == NULL || s->dmabuf_reason == NULL) {
		return "sin servidor";
	}
	return s->dmabuf_reason;
}

void wl_server_bind_dmabuf(wl_server *s, int id, unsigned int texid) {
	if (s == NULL || !s->dmabuf_enabled || s->egl_dpy == EGL_NO_DISPLAY) {
		return;
	}
	toplevel *t = toplevel_find(s, id);
	if (t == NULL || t->buffer == NULL) {
		return;
	}
	struct wlr_dmabuf_attributes attribs;
	if (!wlr_buffer_get_dmabuf(t->buffer, &attribs)) {
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
		toplevel_release_buffer(t);
		free(t);
	}

	if (s->backend != NULL) {
		wlr_backend_destroy(s->backend);
	}
	if (s->display != NULL) {
		wl_display_destroy(s->display);
	}

	free(s);
}
