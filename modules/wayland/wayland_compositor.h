#ifndef WAYLAND_COMPOSITOR_H
#define WAYLAND_COMPOSITOR_H

#include "core/os/input_event.h"
#include "core/pool_vector.h"
#include "scene/main/node.h"
#include "scene/resources/texture.h"

struct wl_server;

class WaylandCompositor : public Node {
	GDCLASS(WaylandCompositor, Node);

	struct Toplevel {
		Ref<ImageTexture> texture;
		String title;
	};

	wl_server *server;
	Vector2 default_size;
	int commit_count;
	Map<int, Toplevel> toplevels;

	static void _cb_added(void *p_ud, int p_id);
	static void _cb_removed(void *p_ud, int p_id);
	static void _cb_frame(void *p_ud, int p_id, const unsigned char *p_rgba, int p_w, int p_h);
	static void _cb_title(void *p_ud, int p_id, const char *p_title);

	void _on_added(int p_id);
	void _on_removed(int p_id);
	void _on_frame(int p_id, const unsigned char *p_rgba, int p_w, int p_h);
	void _on_title(int p_id, const char *p_title);

protected:
	static void _bind_methods();
	virtual void _notification(int p_what);

public:
	WaylandCompositor();
	~WaylandCompositor();

	String start();
	int launch(const String &p_cmd, const PoolStringArray &p_args = PoolStringArray());

	Ref<Texture> get_texture(int p_id) const;
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
};

#endif // WAYLAND_COMPOSITOR_H
