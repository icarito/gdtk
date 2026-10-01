/*
 * gvd-cursor.c — lee SPA_META_Cursor del node PipeWire del monitor virtual.
 *
 * Se engancha como segundo consumidor del node (Mutter/PipeWire permiten
 * varios). Imprime a stdout, a cada cambio, una linea:
 *     x y id
 * con x/y en pixeles del stream (coordenadas del monitor virtual).
 *
 * Compilar:
 *   gcc -O2 -o gvd-cursor gvd-cursor.c $(pkg-config --cflags --libs libpipewire-0.3)
 *
 * Uso:  ./gvd-cursor <node_id>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/buffer/meta.h>
#include <spa/debug/pod.h>

struct state {
	struct pw_main_loop *loop;
	struct pw_context *context;
	struct pw_core *core;
	struct pw_stream *stream;
	struct spa_hook stream_listener;
	int last_x;
	int last_y;
	unsigned last_id;
	int printed;
	unsigned long buffers;
	int debug;
};

static void on_process(void *userdata)
{
	struct state *s = userdata;
	struct pw_buffer *b;
	struct spa_buffer *buf;
	struct spa_meta_cursor *cur = NULL;

	while ((b = pw_stream_dequeue_buffer(s->stream)) != NULL) {
		buf = b->buffer;
		for (uint32_t i = 0; i < buf->n_metas; i++) {
			if (buf->metas[i].type == SPA_META_Cursor) {
				cur = spa_buffer_find_meta_data(
					buf, SPA_META_Cursor, sizeof(*cur));
				break;
			}
		}
		s->buffers++;
		if (s->debug && s->buffers <= 3) {
			fprintf(stderr, "[dbg] buffer %lu n_metas=%u:",
				s->buffers, buf->n_metas);
			for (uint32_t k = 0; k < buf->n_metas; k++)
				fprintf(stderr, " type=%u/size=%u",
					buf->metas[k].type, buf->metas[k].size);
			fprintf(stderr, "\n");
		}
		if (cur != NULL && spa_meta_cursor_is_valid(cur)) {
			int x = cur->position.x;
			int y = cur->position.y;
			if (!s->printed || x != s->last_x || y != s->last_y ||
			    cur->id != s->last_id) {
				printf("%d %d %u\n", x, y, cur->id);
				fflush(stdout);
				s->last_x = x;
				s->last_y = y;
				s->last_id = cur->id;
				s->printed = 1;
			}
		}
		pw_stream_queue_buffer(s->stream, b);
	}
}

static void on_state_changed(void *userdata, enum pw_stream_state old,
			     enum pw_stream_state state, const char *error)
{
	struct state *s = userdata;
	fprintf(stderr, "[dbg] state %s -> %s%s%s\n",
		pw_stream_state_as_string(old), pw_stream_state_as_string(state),
		error ? ": " : "", error ? error : "");
}

static void on_param_changed(void *userdata, uint32_t id,
			     const struct spa_pod *param)
{
	struct state *s = userdata;
	uint8_t buffer[1024];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
	struct spa_pod *params[1];

	if (param == NULL || id != SPA_PARAM_Format)
		return;
	fprintf(stderr, "[dbg] param_changed id=%u\n", id);

	params[0] = spa_pod_builder_add_object(
		&b,
		SPA_TYPE_OBJECT_Format, SPA_PARAM_Buffers,
		SPA_PARAM_BUFFERS_dataType,
		SPA_POD_CHOICE_FLAGS_Int(
			(1 << SPA_DATA_MemFd) | (1 << SPA_DATA_MemPtr)));
	pw_stream_update_params(s->stream, (const struct spa_pod **)params, 1);
}

static const struct pw_stream_events stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.state_changed = on_state_changed,
	.process = on_process,
	.param_changed = on_param_changed,
};

static void on_signal(void *userdata, int signal_number)
{
	struct state *s = userdata;
	printf("# signal %d\n", signal_number);
	fflush(stdout);
	pw_main_loop_quit(s->loop);
}

int main(int argc, char *argv[])
{
	struct state s = {0};
	struct pw_properties *props;
	struct pw_stream *stream;
	struct pw_main_loop *loop;
	uint32_t target;
	uint8_t buffer[1024];
	struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
	struct spa_pod *params[2];
	struct spa_video_info_raw info;
	int info_width, info_height;

	if (argc < 2) {
		fprintf(stderr, "uso: %s <node_id> [width height] [--debug]\n",
			argv[0]);
		return 2;
	}
	target = (uint32_t)strtoul(argv[1], NULL, 10);
	s.last_x = s.last_y = -1;
	info_width = argc > 3 ? atoi(argv[2]) : 1280;
	info_height = argc > 3 ? atoi(argv[3]) : 800;
	for (int i = 2; i < argc; i++)
		if (strcmp(argv[i], "--debug") == 0)
			s.debug = 1;

	pw_init(&argc, &argv);
	s.loop = loop = pw_main_loop_new(NULL);
	s.context = pw_context_new(pw_main_loop_get_loop(loop), NULL, 0);
	if (s.context == NULL) {
		fprintf(stderr, "[gvd-cursor] sin contexto pipewire\n");
		return 1;
	}
	s.core = pw_context_connect(s.context, NULL, 0);
	if (s.core == NULL) {
		fprintf(stderr, "[gvd-cursor] no pude conectar a pipewire\n");
		return 1;
	}
	pw_loop_add_signal(pw_main_loop_get_loop(loop), SIGINT, on_signal, &s);
	pw_loop_add_signal(pw_main_loop_get_loop(loop), SIGTERM, on_signal, &s);

	props = pw_properties_new(
		PW_KEY_MEDIA_TYPE, "Video",
		PW_KEY_MEDIA_CATEGORY, "Capture",
		PW_KEY_MEDIA_ROLE, "Screen",
		PW_KEY_APP_NAME, "gvd-cursor",
		NULL);
	s.stream = stream = pw_stream_new(s.core, "gvd-cursor", props);
	pw_stream_add_listener(stream, &s.stream_listener, &stream_events, &s);

	memset(&info, 0, sizeof(info));
	info.format = SPA_VIDEO_FORMAT_BGRA;
	info.size = SPA_RECTANGLE(info_width, info_height);
	info.framerate = SPA_FRACTION(0, 1);
	params[0] = spa_format_video_raw_build(&b, SPA_PARAM_EnumFormat, &info);
	params[1] = spa_pod_builder_add_object(
		&b,
		SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
		SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Cursor),
		SPA_PARAM_META_size, SPA_POD_Int(
			sizeof(struct spa_meta_cursor) +
			sizeof(struct spa_meta_bitmap) +
			4 * 384 * 384));
	if (s.debug)
		spa_debug_pod(0, NULL, params[0]);

	fprintf(stderr, "[gvd-cursor] node=%u\n", target);
	fflush(stderr);

	if (pw_stream_connect(stream, PW_DIRECTION_INPUT, target,
			      PW_STREAM_FLAG_AUTOCONNECT |
			      PW_STREAM_FLAG_MAP_BUFFERS |
			      PW_STREAM_FLAG_RT_PROCESS,
			      (const struct spa_pod **)params, 2) < 0) {
		fprintf(stderr, "[gvd-cursor] pw_stream_connect fallo\n");
		return 1;
	}

	pw_main_loop_run(loop);

	pw_stream_destroy(stream);
	pw_core_disconnect(s.core);
	pw_context_destroy(s.context);
	pw_main_loop_destroy(loop);
	pw_deinit();
	return 0;
}
