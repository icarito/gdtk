#ifndef WAYLAND_COMPOSITOR_H
#define WAYLAND_COMPOSITOR_H

#include "core/dictionary.h"
#include "core/os/input_event.h"
#include "core/pool_vector.h"
#include "scene/main/node.h"
#include "scene/resources/texture.h"

#include <stdint.h>

struct wl_server;

class WaylandCompositor : public Node {
	GDCLASS(WaylandCompositor, Node);

	struct Toplevel {
		// Una textura por surface (clave = puntero de la surface como uint64).
		Dictionary textures;
		uint64_t root_key;
		String title;

		Toplevel() {
			root_key = 0;
		}
	};

	wl_server *server;
	Vector2 default_size;
	int commit_count;
	int dmabuf_commits;
	int shm_commits;
	Map<int, Toplevel> toplevels;

	static void _cb_added(void *p_ud, int p_id);
	static void _cb_removed(void *p_ud, int p_id);
	static void _cb_frame(void *p_ud, int p_id, uint64_t p_key, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride);
	static void _cb_dmabuf(void *p_ud, int p_id, uint64_t p_key, int p_w, int p_h);
	static void _cb_title(void *p_ud, int p_id, const char *p_title);

	void _on_added(int p_id);
	void _on_removed(int p_id);
	void _on_frame(int p_id, uint64_t p_key, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride);
	void _on_dmabuf(int p_id, uint64_t p_key, int p_w, int p_h);
	void _on_title(int p_id, const char *p_title);

	Map<int, Toplevel>::Element *_toplevel_entry(int p_id);

protected:
	static void _bind_methods();
	virtual void _notification(int p_what);

public:
	WaylandCompositor();
	~WaylandCompositor();

	String start();
	int launch(const String &p_cmd, const PoolStringArray &p_args = PoolStringArray());

	Ref<Texture> get_texture(int p_id) const;
	Array get_layers(int p_id);
	Rect2 get_geometry(int p_id) const;
	String get_title(int p_id) const;
	Array get_ids() const;

	void set_size(int p_id, const Vector2 &p_size);
	void close(int p_id);
	void focus(int p_id);
	void pointer_motion(int p_id, const Vector2 &p_pos);
	void pointer_button(int p_button_index, bool p_pressed);
	void pointer_axis(double p_dy);
	void key(const Ref<InputEventKey> &p_event);

	void set_default_size(const Vector2 &p_size);
	Vector2 get_default_size() const;
	int get_commit_count() const;
	int get_dmabuf_commits() const;
	int get_shm_commits() const;
	String get_dmabuf_state() const;
};

#endif // WAYLAND_COMPOSITOR_H
