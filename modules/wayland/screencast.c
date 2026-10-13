// Fuente PipeWire del multiview (SPEC-multiview-portal §9 N1). Productor minimo,
// patron de src/examples/video-src.c de PipeWire: pw_thread_loop + pw_stream de
// salida con buffers mapeados; on_process volca el ultimo frame y encola. Sin
// libpipewire el modulo no compila: SCsub la agrega.
#define _GNU_SOURCE
#include "screencast.h"

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/param/video/raw-utils.h>
#include <spa/param/buffers.h>
#include <spa/pod/builder.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <spa/utils/defs.h>

struct screencast {
	struct pw_thread_loop *loop;
	struct pw_context *context;
	struct pw_core *core;
	struct pw_stream *stream;
	struct spa_hook stream_listener;

	pthread_mutex_t lock;
	uint8_t *frame; // RGBA8 apretado (stride = width * 4)
	int have_frame;
	int active;

	uint32_t node_id;
	uint64_t serial;
	int width, height, fps;

	int format_set;
	struct spa_video_info_raw format;
};

static void on_process(void *userdata) {
	struct screencast *sc = userdata;
	struct pw_buffer *b = pw_stream_dequeue_buffer(sc->stream);
	if (b == NULL) {
		return;
	}
	struct spa_data *d = &b->buffer->datas[0];
	uint8_t *dst = d->data;

	int w = sc->width;
	int h = sc->height;
	if (sc->format_set) {
		if (sc->format.size.width > 0) {
			w = (int)sc->format.size.width;
		}
		if (sc->format.size.height > 0) {
			h = (int)sc->format.size.height;
		}
	}
	uint32_t stride = (uint32_t)w * 4;
	if (stride > 0 && (uint64_t)stride * h > d->maxsize) {
		h = d->maxsize / stride; // cliente mas chico: no desbordar
	}

	if (dst && stride > 0 && h > 0) {
		pthread_mutex_lock(&sc->lock);
		if (sc->have_frame && sc->frame) {
			for (int y = 0; y < h; y++) {
				memcpy(dst + (size_t)y * stride, sc->frame + (size_t)y * sc->width * 4, stride);
			}
		} else {
			// Sin frame todavia: negro opaco (no dejar basura del allocator).
			memset(dst, 0, (size_t)stride * h);
			for (int y = 0; y < h; y++) {
				uint8_t *row = dst + (size_t)y * stride;
				for (int x = 0; x < w; x++) {
					row[x * 4 + 3] = 0xff;
				}
			}
		}
		pthread_mutex_unlock(&sc->lock);
	} else {
		stride = 0;
		h = 0;
	}

	d->chunk->offset = 0;
	d->chunk->flags = 0;
	d->chunk->stride = (int32_t)stride;
	d->chunk->size = stride * (uint32_t)h;
	pw_stream_queue_buffer(sc->stream, b);
}

static void on_param_changed(void *userdata, uint32_t id, const struct spa_pod *param) {
	struct screencast *sc = userdata;
	if (param == NULL || id != SPA_PARAM_Format) {
		return;
	}
	if (spa_format_video_raw_parse(param, &sc->format) == 0) {
		sc->format_set = 1;
	}
	// Los buffers los asigna PipeWire: MemFd (preferido) o MemPtr; MAP_BUFFERS los mapea.
	uint8_t buffer[1024];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
	struct spa_pod *params[1];
	params[0] = spa_pod_builder_add_object(&b,
			SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
			SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(8, 2, 32),
			SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
			SPA_PARAM_BUFFERS_size, SPA_POD_Int(sc->width * sc->height * 4),
			SPA_PARAM_BUFFERS_stride, SPA_POD_Int(sc->width * 4),
			SPA_PARAM_BUFFERS_align, SPA_POD_Int(16),
			SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
	pw_stream_update_params(sc->stream, (const struct spa_pod **)params, 1);
}

static void on_state_changed(void *userdata, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
	(void)userdata;
	(void)old;
	if (state == PW_STREAM_STATE_ERROR || state == PW_STREAM_STATE_UNCONNECTED) {
		fprintf(stderr, "[screencast] stream %s%s%s\n", pw_stream_state_as_string(state), error ? ": " : "", error ? error : "");
	}
}

static const struct pw_stream_events stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = on_state_changed,
	.param_changed = on_param_changed,
	.process = on_process,
};

screencast *screencast_new(int width, int height, int fps) {
	if (width <= 0 || height <= 0) {
		return NULL;
	}
	struct screencast *sc = calloc(1, sizeof(*sc));
	if (sc == NULL) {
		return NULL;
	}
	pthread_mutex_init(&sc->lock, NULL);
	sc->node_id = SPA_ID_INVALID;
	sc->width = width;
	sc->height = height;
	sc->fps = fps > 0 ? fps : 30;
	sc->frame = calloc(1, (size_t)width * height * 4);
	if (sc->frame == NULL) {
		pthread_mutex_destroy(&sc->lock);
		free(sc);
		return NULL;
	}

	pw_init(NULL, NULL);
	int locked = 0;
	sc->loop = pw_thread_loop_new("gdtk-multiview", NULL);
	if (sc->loop == NULL) {
		goto fail;
	}
	pw_thread_loop_lock(sc->loop);
	locked = 1;
	sc->context = pw_context_new(pw_thread_loop_get_loop(sc->loop), NULL, 0);
	if (sc->context == NULL) {
		goto fail;
	}
	sc->core = pw_context_connect(sc->context, NULL, 0);
	if (sc->core == NULL) {
		goto fail;
	}
	struct pw_properties *props = pw_properties_new(
			PW_KEY_MEDIA_TYPE, "Video",
			PW_KEY_MEDIA_CATEGORY, "Capture",
			PW_KEY_MEDIA_ROLE, "Screen",
			PW_KEY_APP_NAME, "gdtk",
			PW_KEY_NODE_NAME, "gdtk-multiview",
			NULL);
	sc->stream = pw_stream_new(sc->core, "gdtk-multiview", props);
	if (sc->stream == NULL) {
		goto fail;
	}
	pw_stream_add_listener(sc->stream, &sc->stream_listener, &stream_events, sc);

	uint8_t buffer[1024];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
	struct spa_pod *params[1];
	struct spa_video_info_raw info;
	memset(&info, 0, sizeof(info));
	info.format = SPA_VIDEO_FORMAT_RGBA;
	info.size = SPA_RECTANGLE(width, height);
	info.framerate = SPA_FRACTION(sc->fps, 1);
	params[0] = spa_format_video_raw_build(&b, SPA_PARAM_EnumFormat, &info);

	// Fuente que marca su propio ritmo: DRIVER (como video-src) + MAP_BUFFERS.
	int r = pw_stream_connect(sc->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
			PW_STREAM_FLAG_DRIVER | PW_STREAM_FLAG_MAP_BUFFERS, (const struct spa_pod **)params, 1);
	if (r < 0) {
		goto fail;
	}
	pw_thread_loop_unlock(sc->loop);
	locked = 0;
	if (pw_thread_loop_start(sc->loop) < 0) {
		goto fail;
	}
	// El node id sólo es válido tras el bound con el servidor (roundtrip): leerlo
	// justo después de connect devuelve SPA_ID_INVALID y el portal entrega un id
	// inválido, con lo que el cliente no puede engancharse al stream. Esperar
	// acotado a que el loop reporte el id real (o fallar).
	for (int i = 0; i < 400 && (sc->node_id == SPA_ID_INVALID || sc->node_id == 0); i++) {
		pw_thread_loop_lock(sc->loop);
		sc->node_id = pw_stream_get_node_id(sc->stream);
		pw_thread_loop_unlock(sc->loop);
		if (sc->node_id != SPA_ID_INVALID && sc->node_id != 0) {
			break;
		}
		usleep(5000);
	}
	if (sc->node_id == SPA_ID_INVALID || sc->node_id == 0) {
		goto fail;
	}
	sc->serial = sc->node_id;
	sc->active = 1;
	return sc;

fail:
	if (sc->stream != NULL) {
		pw_stream_destroy(sc->stream);
		sc->stream = NULL;
	}
	if (sc->core != NULL) {
		pw_core_disconnect(sc->core);
		sc->core = NULL;
	}
	if (sc->context != NULL) {
		pw_context_destroy(sc->context);
		sc->context = NULL;
	}
	if (locked) {
		pw_thread_loop_unlock(sc->loop);
		locked = 0;
	}
	if (sc->loop != NULL) {
		pw_thread_loop_destroy(sc->loop);
		sc->loop = NULL;
	}
	pw_deinit();
	pthread_mutex_destroy(&sc->lock);
	free(sc->frame);
	free(sc);
	return NULL;
}

uint32_t screencast_node_id(screencast *sc) {
	return sc != NULL ? sc->node_id : 0;
}

uint64_t screencast_serial(screencast *sc) {
	return sc != NULL ? sc->serial : 0;
}

void screencast_push_rgba(screencast *sc, const uint8_t *data, int w, int h, int stride) {
	if (sc == NULL || data == NULL || !sc->active) {
		return;
	}
	// Solo la geometria configurada: no se escala (ver SPEC §9 N1).
	if (w != sc->width || h != sc->height) {
		return;
	}
	if (stride <= 0) {
		stride = w * 4;
	}
	size_t row = (size_t)w * 4;
	pthread_mutex_lock(&sc->lock);
	for (int y = 0; y < h; y++) {
		memcpy(sc->frame + (size_t)y * row, data + (size_t)y * stride, row);
	}
	sc->have_frame = 1;
	pthread_mutex_unlock(&sc->lock);
	pw_stream_trigger_process(sc->stream);
}

int screencast_active(screencast *sc) {
	return sc != NULL && sc->active;
}

void screencast_free(screencast *sc) {
	if (sc == NULL) {
		return;
	}
	sc->active = 0;
	if (sc->loop != NULL) {
		pw_thread_loop_stop(sc->loop);
	}
	if (sc->stream != NULL) {
		pw_stream_destroy(sc->stream);
	}
	if (sc->core != NULL) {
		pw_core_disconnect(sc->core);
	}
	if (sc->context != NULL) {
		pw_context_destroy(sc->context);
	}
	if (sc->loop != NULL) {
		pw_thread_loop_destroy(sc->loop);
	}
	pw_deinit();
	pthread_mutex_destroy(&sc->lock);
	free(sc->frame);
	free(sc);
}
