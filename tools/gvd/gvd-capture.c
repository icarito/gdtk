/*
 * gvd-capture.c - captura de un output wlroots (sway/gdtk) via wlr-screencopy,
 * como reemplazo de PipeWire/Mutter para el emisor de gvd.
 *
 * Escribe en stdout frames crudos (formato/fourcc, width, height y stride se
 * anuncian en una linea de cabecera por stderr). Uso:
 *
 *   gvd-capture --fps 30 [--output NOMBRE] [--overlay-cursor 0|1] [--once]
 *
 * Cabecera (stderr, una linea):  GVDCAP1 <fourcc> <width> <height> <stride>
 * fourcc: "XR24" (XRGB8888, memoria B,G,R,X) o "AR24" (ARGB8888). El consumidor
 * elige el formato GStreamer equivalente (BGRx / BGRA).
 *
 * Salida: termina con SIGTERM/SIGINT o si el pipe de stdout se cierra.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <wayland-client.h>

#include "wlr-screencopy-unstable-v1-client-protocol.h"

struct output {
	struct wl_output *wl;
	uint32_t name_tag;
	char name[128];
	int done;
};

struct state {
	struct wl_display *display;
	struct wl_registry *registry;
	struct wl_shm *shm;
	struct zwlr_screencopy_manager_v1 *manager;
	struct output outputs[16];
	int n_outputs;
	int overlay_cursor;
	const char *want_output;
	int once;

	int frame_done;   /* 1 = ready, -1 = failed */
	int have_buffer;
	uint32_t fmt, width, height, stride;
	uint32_t fourcc;
	void *data;
	size_t data_size;
	struct wl_buffer *buffer;
};

static volatile sig_atomic_t running = 1;

static void on_signal(int sig)
{
	(void)sig;
	running = 0;
}

/* ---- wl_output ---- */
static void output_geometry(void *d, struct wl_output *o, int32_t x, int32_t y,
			    int32_t pw, int32_t ph, int32_t subpixel,
			    const char *make, const char *model, int32_t transform)
{
	(void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)subpixel;
	(void)make; (void)model; (void)transform;
}

static void output_mode(void *d, struct wl_output *o, uint32_t flags,
			int32_t w, int32_t h, int32_t refresh)
{
	(void)d; (void)o; (void)flags; (void)w; (void)h; (void)refresh;
}

static void output_done(void *d, struct wl_output *o)
{
	(void)o;
	((struct output *)d)->done = 1;
}

static void output_scale(void *d, struct wl_output *o, int32_t factor)
{
	(void)d; (void)o; (void)factor;
}

static void output_name(void *d, struct wl_output *o, const char *name)
{
	(void)o;
	struct output *out = d;
	snprintf(out->name, sizeof(out->name), "%s", name ? name : "");
	out->name_tag = 1;
}

static void output_description(void *d, struct wl_output *o, const char *desc)
{
	(void)d; (void)o; (void)desc;
}

static const struct wl_output_listener output_listener = {
	.geometry = output_geometry,
	.mode = output_mode,
	.done = output_done,
	.scale = output_scale,
	.name = output_name,
	.description = output_description,
};

/* ---- wl_registry ---- */
static void registry_global(void *d, struct wl_registry *reg, uint32_t name,
			    const char *iface, uint32_t version)
{
	struct state *s = d;
	if (strcmp(iface, wl_shm_interface.name) == 0) {
		s->shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(iface, zwlr_screencopy_manager_v1_interface.name) == 0) {
		uint32_t v = version < 3 ? version : 3;
		s->manager = wl_registry_bind(reg, name,
			&zwlr_screencopy_manager_v1_interface, v);
	} else if (strcmp(iface, wl_output_interface.name) == 0 && s->n_outputs < 16) {
		uint32_t v = version < 4 ? version : 4;
		struct output *o = &s->outputs[s->n_outputs++];
		memset(o, 0, sizeof(*o));
		o->wl = wl_registry_bind(reg, name, &wl_output_interface, v);
		wl_output_add_listener(o->wl, &output_listener, o);
	}
}

static void registry_remove(void *d, struct wl_registry *reg, uint32_t name)
{
	(void)d; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_remove,
};

/* ---- screencopy frame ---- */
static int make_shm_buffer(struct state *s);
static void free_shm_buffer(struct state *s);

static void frame_buffer(void *d, struct zwlr_screencopy_frame_v1 *f,
			 uint32_t format, uint32_t width, uint32_t height,
			 uint32_t stride)
{
	(void)f;
	struct state *s = d;
	s->fmt = format;
	s->width = width;
	s->height = height;
	s->stride = stride;
	s->fourcc = format; /* formato wl_shm (numerico) */
}

/* Tras anunciar los buffers (buffer + linux_dmabuf) se llama buffer_done: recien
 * ahi corresponde pedir `copy` con el buffer shm. */
static void frame_buffer_done(void *d, struct zwlr_screencopy_frame_v1 *f)
{
	struct state *s = d;
	if (s->have_buffer)
		free_shm_buffer(s);
	if (make_shm_buffer(s) < 0) {
		s->frame_done = -1;
		zwlr_screencopy_frame_v1_destroy(f);
		return;
	}
	zwlr_screencopy_frame_v1_copy(f, s->buffer);
}

static void frame_flags(void *d, struct zwlr_screencopy_frame_v1 *f, uint32_t flags)
{
	(void)d; (void)f; (void)flags;
}

static void frame_ready(void *d, struct zwlr_screencopy_frame_v1 *f,
			uint32_t hi, uint32_t lo, uint32_t nsec)
{
	(void)hi; (void)lo; (void)nsec;
	struct state *s = d;
	s->frame_done = 1;
	zwlr_screencopy_frame_v1_destroy(f);
}

static void frame_failed(void *d, struct zwlr_screencopy_frame_v1 *f)
{
	struct state *s = d;
	s->frame_done = -1;
	zwlr_screencopy_frame_v1_destroy(f);
}

static void frame_damage(void *d, struct zwlr_screencopy_frame_v1 *f,
			 uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
	(void)d; (void)f; (void)x; (void)y; (void)w; (void)h;
}

static void frame_linux_dmabuf(void *d, struct zwlr_screencopy_frame_v1 *f,
			       uint32_t format, uint32_t width, uint32_t height)
{
	(void)d; (void)f; (void)format; (void)width; (void)height;
}

static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
	.buffer = frame_buffer,
	.flags = frame_flags,
	.ready = frame_ready,
	.failed = frame_failed,
	.damage = frame_damage,
	.linux_dmabuf = frame_linux_dmabuf,
	.buffer_done = frame_buffer_done,
};

static int make_shm_buffer(struct state *s)
{
	size_t size = (size_t)s->stride * s->height;
	int fd = memfd_create("gvd-capture", MFD_CLOEXEC);
	if (fd < 0) {
		perror("memfd_create");
		return -1;
	}
	if (ftruncate(fd, (off_t)size) < 0) {
		perror("ftruncate");
		close(fd);
		return -1;
	}
	void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return -1;
	}
	struct wl_shm_pool *pool = wl_shm_create_pool(s->shm, fd, (int32_t)size);
	s->buffer = wl_shm_pool_create_buffer(pool, 0, (int32_t)s->width,
		(int32_t)s->height, (int32_t)s->stride, s->fmt);
	wl_shm_pool_destroy(pool);
	close(fd);
	s->data = p;
	s->data_size = size;
	s->have_buffer = 1;
	return 0;
}

static void free_shm_buffer(struct state *s)
{
	if (s->buffer) {
		wl_buffer_destroy(s->buffer);
		s->buffer = NULL;
	}
	if (s->data) {
		munmap(s->data, s->data_size);
		s->data = NULL;
	}
	s->have_buffer = 0;
}

static struct output *pick_output(struct state *s)
{
	if (s->n_outputs == 0)
		return NULL;
	if (s->want_output && *s->want_output) {
		for (int i = 0; i < s->n_outputs; i++) {
			if (strcmp(s->outputs[i].name, s->want_output) == 0)
				return &s->outputs[i];
		}
		fprintf(stderr, "[!] output '%s' no existe; uso el primero\n",
			s->want_output);
	}
	return &s->outputs[0];
}

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void sleep_ns(uint64_t ns)
{
	struct timespec ts = { ns / 1000000000ull, ns % 1000000000ull };
	while (nanosleep(&ts, &ts) < 0 && errno == EINTR)
		;
}

int main(int argc, char **argv)
{
	double fps = 30.0;
	struct state s;
	memset(&s, 0, sizeof(s));
	s.overlay_cursor = 0;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc) {
			fps = atof(argv[++i]);
		} else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
			s.want_output = argv[++i];
		} else if (strcmp(argv[i], "--overlay-cursor") == 0 && i + 1 < argc) {
			s.overlay_cursor = atoi(argv[++i]);
		} else if (strcmp(argv[i], "--once") == 0) {
			s.once = 1;
		}
	}
	if (fps <= 0.0)
		fps = 30.0;

	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGPIPE, SIG_IGN);

	s.display = wl_display_connect(NULL);
	if (!s.display) {
		fprintf(stderr, "[!] no pude conectar a WAYLAND_DISPLAY\n");
		return 1;
	}
	s.registry = wl_display_get_registry(s.display);
	wl_registry_add_listener(s.registry, &registry_listener, &s);
	wl_display_roundtrip(s.display);
	wl_display_roundtrip(s.display); /* nombres de output */

	if (!s.manager || !s.shm) {
		fprintf(stderr, "[!] el compositor no expone wlr-screencopy/wl_shm\n");
		return 1;
	}
	struct output *out = pick_output(&s);
	if (!out) {
		fprintf(stderr, "[!] sin outputs\n");
		return 1;
	}
	fprintf(stderr, "[*] capturando output '%s' (overlay_cursor=%d)\n",
		out->name[0] ? out->name : "?", s.overlay_cursor);

	int announced = 0;
	uint64_t period = (uint64_t)(1000000000.0 / fps);
	uint64_t next = now_ns();

	while (running) {
		s.frame_done = 0;
		s.have_buffer = 0;
		struct zwlr_screencopy_frame_v1 *frame =
			zwlr_screencopy_manager_v1_capture_output(s.manager,
				s.overlay_cursor, out->wl);
		zwlr_screencopy_frame_v1_add_listener(frame, &frame_listener, &s);

		while (s.frame_done == 0 && running) {
			if (wl_display_dispatch(s.display) < 0) {
				fprintf(stderr, "[!] wl_display_dispatch: %s\n",
					strerror(errno));
				running = 0;
				break;
			}
		}
		if (!running)
			break;
		if (s.frame_done < 0) {
			fprintf(stderr, "[!] frame failed; reintento\n");
			free_shm_buffer(&s);
			continue;
		}

		if (!announced) {
			const char *fourcc =
				s.fmt == WL_SHM_FORMAT_XRGB8888 ? "XR24" :
				s.fmt == WL_SHM_FORMAT_ARGB8888 ? "AR24" : "????";
			fprintf(stderr, "GVDCAP1 %s %u %u %u\n", fourcc,
				s.width, s.height, s.stride);
			fflush(stderr);
			announced = 1;
		}

		if (fwrite(s.data, 1, s.data_size, stdout) != s.data_size) {
			fprintf(stderr, "[!] stdout cerrado\n");
			running = 0;
			break;
		}
		fflush(stdout);
		free_shm_buffer(&s);

		if (s.once)
			break;

		next += period;
		uint64_t t = now_ns();
		if (next > t)
			sleep_ns(next - t);
		else
			next = t; /* nos atrasamos: no acumular */
	}

	return 0;
}
