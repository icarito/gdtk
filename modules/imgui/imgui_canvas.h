#ifndef IMGUI_CANVAS_H
#define IMGUI_CANVAS_H

#include "scene/2d/node_2d.h"
#include "scene/resources/texture.h"

struct ImGuiContext;

class ImGuiCanvas : public Node2D {
	GDCLASS(ImGuiCanvas, Node2D);

	ImGuiContext *context;
	Ref<ImageTexture> font_texture;
	RID font_texture_rid;
	Vector<RID> canvas_items;
	bool want_text_input;
	float scale;

	void _process_frame(float p_delta);
	RID _get_canvas_item(int p_index);

protected:
	static void _bind_methods();
	virtual void _notification(int p_what);

public:
	bool begin(const String &p_title);
	void end();
	void set_next_window_pos(const Vector2 &p_pos);
	void set_next_window_size(const Vector2 &p_size);
	void text(const String &p_text);
	void text_wrapped(const String &p_text);
	bool button(const String &p_label);
	void same_line();
	void separator();
	bool checkbox(const String &p_label, bool p_value);
	String input_text(const String &p_label, const String &p_value);
	Dictionary input_text_enter(const String &p_label, const String &p_value);
	bool begin_child(const String &p_id, const Vector2 &p_size);
	void end_child();
	void set_scroll_here_y(float p_ratio);

	void set_scale(float p_scale);
	float get_scale() const;

	void _input(const Ref<InputEvent> &p_event);

	ImGuiCanvas();
	~ImGuiCanvas();
};

#endif // IMGUI_CANVAS_H
