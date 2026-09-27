#ifndef IMGUI_CANVAS_H
#define IMGUI_CANVAS_H

#include "core/color.h"
#include "core/list.h"
#include "core/math/vector2.h"
#include "core/math/vector3.h"
#include "core/pool_vector.h"
#include "core/set.h"
#include "scene/2d/node_2d.h"
#include "scene/resources/texture.h"

struct ImGuiContext;
struct ImPlotContext;
struct ImPlot3DContext;
class PieMenu;

class ImGuiCanvas : public Node2D {
	GDCLASS(ImGuiCanvas, Node2D);

	ImGuiContext *context;
	ImPlotContext *implot_context;
	ImPlot3DContext *implot3d_context;
	PieMenu *pie;

	Ref<ImageTexture> font_texture;
	RID font_texture_rid;
	Vector<RID> canvas_items;
	bool want_text_input;
	float scale;
	float frame_rounding;

	// Paso 12: el contenido del canvas puede armarse a una tasa propia en vez de
	// cada frame. update_hz <= 0 = cada frame (comportamiento historico); > 0 = solo
	// cuando toca por tiempo, cuando hubo input reciente (a input_hz) o cuando algo
	// llama a request_redraw(). Los eventos de input se encolan en ImGui y se
	// procesan en el siguiente NewFrame armado, sin perderse.
	float update_hz;
	float input_hz;
	uint64_t last_frame_usec;
	uint64_t last_input_usec;
	bool requested_redraw;
	// El atlas se construye en NOTIFICATION_READY; add_font() lo reconstruye y
	// vuelve a subir la textura si se agrega una fuente despues.
	bool atlas_ready;
	// Buffers TTF vivos mientras el atlas los use (FontDataOwnedByAtlas=false).
	Vector<PoolVector<uint8_t> > font_buffers;

	void _build_font_texture();

	// Teclas pulsadas desde el ultimo frame. El control remoto inyecta press y
	// release seguidos, y ImGui::IsKeyPressed puede perderse si ambos caen en el
	// mismo frame; con este latch is_key_pressed sigue detectando la pulsacion.
	Set<uint32_t> frame_pressed_keys;

	// Texturas de imagen vivas durante el frame (ImTextureID = puntero al RID).
	Vector<RID *> frame_texture_rids;
	List<Ref<Texture> > frame_textures;
	bool window_open;

	void _process_frame(float p_delta);
	RID _get_canvas_item(int p_index);
	void _set_contexts();

protected:
	static void _bind_methods();
	virtual void _notification(int p_what);

public:
	// Ventanas / layout
	bool begin(const String &p_title, int p_flags = 0, bool p_closable = false);
	void end();
	bool is_window_open() const;
	void set_next_window_pos(const Vector2 &p_pos, bool p_always = false);
	void set_next_window_size(const Vector2 &p_size, bool p_always = false);
	void set_next_window_bg_alpha(float p_alpha);
	void set_cursor_pos(const Vector2 &p_pos);
	void same_line(float p_offset = 0.0f, float p_spacing = -1.0f);
	void new_line();
	void spacing();
	void dummy(const Vector2 &p_size);
	void indent(float p_w = 0.0f);
	void unindent(float p_w = 0.0f);
	void separator();
	void separator_text(const String &p_label);
	void begin_group();
	void end_group();
	void push_id(const String &p_id);
	void pop_id();
	void push_item_width(float p_w);
	void pop_item_width();
	Vector2 get_content_region_avail();
	Vector2 get_window_size();
	Vector2 get_window_pos();
	bool begin_child(const String &p_id, const Vector2 &p_size);
	void end_child();
	void set_scroll_here_y(float p_ratio);

	// Texto
	void text(const String &p_text);
	void text_wrapped(const String &p_text);
	void text_colored(const Color &p_color, const String &p_text);
	void text_disabled(const String &p_text);
	void bullet_text(const String &p_text);
	void label_text(const String &p_label, const String &p_text);

	// Botones / seleccion
	bool button(const String &p_label, const Vector2 &p_size = Vector2());
	bool small_button(const String &p_label);
	bool checkbox(const String &p_label, bool p_value);
	bool radio_button(const String &p_label, bool p_active);
	bool selectable(const String &p_label, bool p_selected = false, const Vector2 &p_size = Vector2());
	void progress_bar(float p_frac, const Vector2 &p_size = Vector2(-1, 0), const String &p_overlay = "");
	void image(const Ref<Texture> &p_texture, const Vector2 &p_size, const Color &p_tint = Color(1, 1, 1));
	bool image_button(const String &p_id, const Ref<Texture> &p_texture, const Vector2 &p_size);

	// Entrada
	float slider_float(const String &p_label, float p_v, float p_min, float p_max, const String &p_fmt = "%.3f");
	int slider_int(const String &p_label, int p_v, int p_min, int p_max);
	Vector2 slider_float2(const String &p_label, const Vector2 &p_v, float p_min, float p_max);
	Vector3 slider_float3(const String &p_label, const Vector3 &p_v, float p_min, float p_max);
	float drag_float(const String &p_label, float p_v, float p_speed = 1.0f, float p_min = 0.0f, float p_max = 0.0f);
	int drag_int(const String &p_label, int p_v, float p_speed = 1.0f, int p_min = 0, int p_max = 0);
	Vector2 drag_float2(const String &p_label, const Vector2 &p_v, float p_speed = 1.0f, float p_min = 0.0f, float p_max = 0.0f);
	Vector3 drag_float3(const String &p_label, const Vector3 &p_v, float p_speed = 1.0f, float p_min = 0.0f, float p_max = 0.0f);
	float input_float(const String &p_label, float p_v, float p_step = 0.0f, float p_step_fast = 0.0f);
	int input_int(const String &p_label, int p_v, int p_step = 1, int p_step_fast = 100);
	String input_text(const String &p_label, const String &p_value);
	Dictionary input_text_enter(const String &p_label, const String &p_value);
	void set_keyboard_focus_here();
	String input_text_multiline(const String &p_label, const String &p_value, const Vector2 &p_size);
	Color color_edit3(const String &p_label, const Color &p_color);
	Color color_edit4(const String &p_label, const Color &p_color);
	Color color_picker4(const String &p_label, const Color &p_color);
	int combo(const String &p_label, int p_current, const PoolStringArray &p_items);
	int list_box(const String &p_label, int p_current, const PoolStringArray &p_items, int p_height_items = -1);

	// Arboles / pestañas
	bool tree_node(const String &p_label, int p_flags = 0);
	void tree_pop();
	bool collapsing_header(const String &p_label, int p_flags = 0);
	bool begin_tab_bar(const String &p_id);
	void end_tab_bar();
	bool begin_tab_item(const String &p_label);
	void end_tab_item();

	// Tablas
	bool begin_table(const String &p_id, int p_columns, int p_flags = 0);
	void end_table();
	void table_setup_column(const String &p_label);
	void table_headers_row();
	void table_next_row();
	bool table_next_column();

	// Menus / popups
	bool begin_main_menu_bar();
	void end_main_menu_bar();
	bool begin_menu_bar();
	void end_menu_bar();
	bool begin_menu(const String &p_label);
	void end_menu();
	bool menu_item(const String &p_label, const String &p_shortcut = "", bool p_selected = false);
	void open_popup(const String &p_id);
	bool begin_popup(const String &p_id);
	bool begin_popup_modal(const String &p_title);
	void end_popup();
	void close_current_popup();
	bool begin_popup_context_item(const String &p_id = "");
	void set_tooltip(const String &p_text);
	void begin_tooltip();
	void end_tooltip();

	// Estado del item
	bool is_item_hovered();
	bool is_item_active();
	bool is_item_clicked(int p_button = 0);
	bool is_item_edited();
	bool is_mouse_clicked(int p_button);
	bool is_mouse_double_clicked();
	bool is_key_pressed(int p_key);
	Vector2 get_mouse_pos();

	// Graficos nativos
	void plot_lines(const String &p_label, const PoolRealArray &p_values, const String &p_overlay = "", float p_min = 3.402823466e+38F, float p_max = 3.402823466e+38F, const Vector2 &p_size = Vector2());
	void plot_histogram(const String &p_label, const PoolRealArray &p_values, const String &p_overlay = "", float p_min = 3.402823466e+38F, float p_max = 3.402823466e+38F, const Vector2 &p_size = Vector2());

	// Estilo
	void style_colors_dark();
	void style_colors_light();
	void style_colors_classic();
	void push_style_color(int p_idx, const Color &p_color);
	void pop_style_color(int p_n = 1);
	void push_style_var_float(int p_idx, float p_v);
	void push_style_var_vec2(int p_idx, const Vector2 &p_v);
	void pop_style_var(int p_n = 1);

	// Demos
	void show_demo_window();
	void show_metrics_window();
	void implot_show_demo_window();
	void implot3d_show_demo_window();

	// ImPlot
	bool implot_begin_plot(const String &p_title, const Vector2 &p_size = Vector2(-1, 0), int p_flags = 0);
	void implot_end_plot();
	void implot_setup_axes(const String &p_x_label, const String &p_y_label, int p_x_flags = 0, int p_y_flags = 0);
	void implot_setup_axis_limits(int p_axis, float p_min, float p_max, bool p_cond_always = false);
	void implot_plot_line(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys);
	void implot_plot_scatter(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys);
	void implot_plot_bars(const String &p_label, const PoolRealArray &p_values, float p_bar_size = 0.67f);
	void implot_plot_shaded(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys, float p_y_ref = 0.0f);
	void implot_push_style_color(int p_idx, const Color &p_color);
	void implot_pop_style_color(int p_n = 1);
	void implot_plot_heatmap(const String &p_label, const PoolRealArray &p_values, int p_rows, int p_cols, float p_min = 0.0f, float p_max = 0.0f);

	// ImPlot3D
	bool implot3d_begin_plot(const String &p_title, const Vector2 &p_size = Vector2(-1, 0), int p_flags = 0);
	void implot3d_end_plot();
	void implot3d_setup_axes(const String &p_x, const String &p_y, const String &p_z);
	void implot3d_setup_axes_flags(const String &p_x, const String &p_y, const String &p_z, int p_flags);
	void implot3d_plot_line(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys, const PoolRealArray &p_zs);
	void implot3d_plot_scatter(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys, const PoolRealArray &p_zs);
	void implot3d_plot_surface(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys, const PoolRealArray &p_zs, int p_x_count, int p_y_count);

	// Menu radial
	void open_pie_menu(const String &p_id);
	int pie_menu(const String &p_id, const PoolStringArray &p_items);

	// El binder de metodos de Godot 3 acepta como maximo 5 argumentos; estas
	// funciones van por bind_vararg_method para conservar la firma completa.
	Variant _plot_lines_vararg(const Variant **p_args, int p_argcount, Variant::CallError &r_error);
	Variant _plot_histogram_vararg(const Variant **p_args, int p_argcount, Variant::CallError &r_error);
	Variant _implot_plot_heatmap_vararg(const Variant **p_args, int p_argcount, Variant::CallError &r_error);
	Variant _implot3d_plot_surface_vararg(const Variant **p_args, int p_argcount, Variant::CallError &r_error);

	void set_scale(float p_scale);
	float get_scale() const;

	// Indica si el modulo se compilo con una capacidad opcional (implot,
	// implot3d, demos). Los metodos de la capacidad ausente no se bindean.
	bool has_feature(const String &p_feature) const;

	void set_frame_rounding(float p_rounding);
	float get_frame_rounding() const;

	// Paso 12: tasa de actualizacion y fuentes.
	void set_update_hz(float p_hz);
	float get_update_hz() const;
	void set_input_hz(float p_hz);
	float get_input_hz() const;
	void request_redraw();

	int add_font(const String &p_path, float p_size_px);
	void push_font(int p_idx);
	void pop_font();
	void set_default_font(int p_idx);

	Vector2 get_cursor_screen_pos();

	void _input(const Ref<InputEvent> &p_event);

	ImGuiCanvas();
	~ImGuiCanvas();
};

#endif // IMGUI_CANVAS_H
