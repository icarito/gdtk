#include "imgui_canvas.h"

#include "core/class_db.h"
#include "core/image.h"
#include "core/os/input_event.h"
#include "core/os/keyboard.h"
#include "core/os/os.h"
#include "pie_menu.h"
#include "servers/visual_server.h"

#include "imgui.h"
#ifdef IMGUI_MODULE_IMPLOT
#include "implot.h"
#endif
#ifdef IMGUI_MODULE_IMPLOT3D
#include "implot3d.h"
#endif

#include <string.h>

static CharString clipboard_buffer;

static const char *_imgui_get_clipboard(void *p_user_data) {
	clipboard_buffer = OS::get_singleton()->get_clipboard().utf8();
	return clipboard_buffer.get_data();
}

static void _imgui_set_clipboard(void *p_user_data, const char *p_text) {
	OS::get_singleton()->set_clipboard(String::utf8(p_text));
}

static ImGuiKey _godot_key_to_imgui(uint32_t p_key) {
	switch (p_key) {
		case KEY_TAB:
			return ImGuiKey_Tab;
		case KEY_LEFT:
			return ImGuiKey_LeftArrow;
		case KEY_RIGHT:
			return ImGuiKey_RightArrow;
		case KEY_UP:
			return ImGuiKey_UpArrow;
		case KEY_DOWN:
			return ImGuiKey_DownArrow;
		case KEY_HOME:
			return ImGuiKey_Home;
		case KEY_END:
			return ImGuiKey_End;
		case KEY_DELETE:
			return ImGuiKey_Delete;
		case KEY_BACKSPACE:
			return ImGuiKey_Backspace;
		case KEY_ENTER:
		case KEY_KP_ENTER:
			return ImGuiKey_Enter;
		case KEY_ESCAPE:
			return ImGuiKey_Escape;
		case KEY_F1:
			return ImGuiKey_F1;
		case KEY_F2:
			return ImGuiKey_F2;
		case KEY_F3:
			return ImGuiKey_F3;
		case KEY_F4:
			return ImGuiKey_F4;
		case KEY_F5:
			return ImGuiKey_F5;
		case KEY_F6:
			return ImGuiKey_F6;
		case KEY_F7:
			return ImGuiKey_F7;
		case KEY_F8:
			return ImGuiKey_F8;
		case KEY_F9:
			return ImGuiKey_F9;
		case KEY_F10:
			return ImGuiKey_F10;
		case KEY_F11:
			return ImGuiKey_F11;
		case KEY_F12:
			return ImGuiKey_F12;
		default:
			break;
	}
	if (p_key >= KEY_A && p_key <= KEY_Z) {
		return (ImGuiKey)(ImGuiKey_A + (p_key - KEY_A));
	}
	return ImGuiKey_None;
}

static ImVec2 _to_imvec2(const Vector2 &p_v) {
	return ImVec2(p_v.x, p_v.y);
}

static ImVec4 _to_imvec4(const Color &p_c) {
	return ImVec4(p_c.r, p_c.g, p_c.b, p_c.a);
}

static Color _from_imvec4(const ImVec4 &p_c) {
	return Color(p_c.x, p_c.y, p_c.z, p_c.w);
}

static void _build_char_ptrs(const PoolStringArray &p_items, Vector<CharString> &r_storage, Vector<const char *> &r_ptrs) {
	int n = p_items.size();
	r_storage.resize(n);
	r_ptrs.resize(n);
	for (int i = 0; i < n; i++) {
		r_storage.write[i] = p_items[i].utf8();
		r_ptrs.write[i] = r_storage[i].get_data();
	}
}

void ImGuiCanvas::_bind_methods() {
	// Ventanas / layout
	ClassDB::bind_method(D_METHOD("begin", "title", "flags", "closable"), &ImGuiCanvas::begin, DEFVAL(0), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("end"), &ImGuiCanvas::end);
	ClassDB::bind_method(D_METHOD("is_window_open"), &ImGuiCanvas::is_window_open);
	ClassDB::bind_method(D_METHOD("set_next_window_pos", "pos", "always"), &ImGuiCanvas::set_next_window_pos, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("set_next_window_size", "size", "always"), &ImGuiCanvas::set_next_window_size, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("set_next_window_bg_alpha", "alpha"), &ImGuiCanvas::set_next_window_bg_alpha);
	ClassDB::bind_method(D_METHOD("set_cursor_pos", "pos"), &ImGuiCanvas::set_cursor_pos);
	ClassDB::bind_method(D_METHOD("same_line", "offset", "spacing"), &ImGuiCanvas::same_line, DEFVAL(0.0f), DEFVAL(-1.0f));
	ClassDB::bind_method(D_METHOD("new_line"), &ImGuiCanvas::new_line);
	ClassDB::bind_method(D_METHOD("spacing"), &ImGuiCanvas::spacing);
	ClassDB::bind_method(D_METHOD("dummy", "size"), &ImGuiCanvas::dummy);
	ClassDB::bind_method(D_METHOD("indent", "w"), &ImGuiCanvas::indent, DEFVAL(0.0f));
	ClassDB::bind_method(D_METHOD("unindent", "w"), &ImGuiCanvas::unindent, DEFVAL(0.0f));
	ClassDB::bind_method(D_METHOD("separator"), &ImGuiCanvas::separator);
	ClassDB::bind_method(D_METHOD("separator_text", "label"), &ImGuiCanvas::separator_text);
	ClassDB::bind_method(D_METHOD("begin_group"), &ImGuiCanvas::begin_group);
	ClassDB::bind_method(D_METHOD("end_group"), &ImGuiCanvas::end_group);
	ClassDB::bind_method(D_METHOD("push_id", "id"), &ImGuiCanvas::push_id);
	ClassDB::bind_method(D_METHOD("pop_id"), &ImGuiCanvas::pop_id);
	ClassDB::bind_method(D_METHOD("push_item_width", "w"), &ImGuiCanvas::push_item_width);
	ClassDB::bind_method(D_METHOD("pop_item_width"), &ImGuiCanvas::pop_item_width);
	ClassDB::bind_method(D_METHOD("get_content_region_avail"), &ImGuiCanvas::get_content_region_avail);
	ClassDB::bind_method(D_METHOD("get_window_size"), &ImGuiCanvas::get_window_size);
	ClassDB::bind_method(D_METHOD("get_window_pos"), &ImGuiCanvas::get_window_pos);
	ClassDB::bind_method(D_METHOD("begin_child", "id", "size"), &ImGuiCanvas::begin_child);
	ClassDB::bind_method(D_METHOD("end_child"), &ImGuiCanvas::end_child);
	ClassDB::bind_method(D_METHOD("set_scroll_here_y", "ratio"), &ImGuiCanvas::set_scroll_here_y);

	// Texto
	ClassDB::bind_method(D_METHOD("text", "s"), &ImGuiCanvas::text);
	ClassDB::bind_method(D_METHOD("text_wrapped", "s"), &ImGuiCanvas::text_wrapped);
	ClassDB::bind_method(D_METHOD("text_colored", "color", "s"), &ImGuiCanvas::text_colored);
	ClassDB::bind_method(D_METHOD("text_disabled", "s"), &ImGuiCanvas::text_disabled);
	ClassDB::bind_method(D_METHOD("bullet_text", "s"), &ImGuiCanvas::bullet_text);
	ClassDB::bind_method(D_METHOD("label_text", "label", "s"), &ImGuiCanvas::label_text);

	// Botones / seleccion
	ClassDB::bind_method(D_METHOD("button", "label", "size"), &ImGuiCanvas::button, DEFVAL(Vector2()));
	ClassDB::bind_method(D_METHOD("small_button", "label"), &ImGuiCanvas::small_button);
	ClassDB::bind_method(D_METHOD("checkbox", "label", "value"), &ImGuiCanvas::checkbox);
	ClassDB::bind_method(D_METHOD("radio_button", "label", "active"), &ImGuiCanvas::radio_button);
	ClassDB::bind_method(D_METHOD("selectable", "label", "selected", "size"), &ImGuiCanvas::selectable, DEFVAL(false), DEFVAL(Vector2()));
	ClassDB::bind_method(D_METHOD("progress_bar", "frac", "size", "overlay"), &ImGuiCanvas::progress_bar, DEFVAL(Vector2(-1, 0)), DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("image", "texture", "size", "tint"), &ImGuiCanvas::image, DEFVAL(Color(1, 1, 1)));
	ClassDB::bind_method(D_METHOD("image_button", "id", "texture", "size"), &ImGuiCanvas::image_button);

	// Entrada
	ClassDB::bind_method(D_METHOD("slider_float", "label", "v", "min", "max", "fmt"), &ImGuiCanvas::slider_float, DEFVAL("%.3f"));
	ClassDB::bind_method(D_METHOD("slider_int", "label", "v", "min", "max"), &ImGuiCanvas::slider_int);
	ClassDB::bind_method(D_METHOD("slider_float2", "label", "v", "min", "max"), &ImGuiCanvas::slider_float2);
	ClassDB::bind_method(D_METHOD("slider_float3", "label", "v", "min", "max"), &ImGuiCanvas::slider_float3);
	ClassDB::bind_method(D_METHOD("drag_float", "label", "v", "speed", "min", "max"), &ImGuiCanvas::drag_float, DEFVAL(1.0f), DEFVAL(0.0f), DEFVAL(0.0f));
	ClassDB::bind_method(D_METHOD("drag_int", "label", "v", "speed", "min", "max"), &ImGuiCanvas::drag_int, DEFVAL(1.0f), DEFVAL(0), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("drag_float2", "label", "v", "speed", "min", "max"), &ImGuiCanvas::drag_float2, DEFVAL(1.0f), DEFVAL(0.0f), DEFVAL(0.0f));
	ClassDB::bind_method(D_METHOD("drag_float3", "label", "v", "speed", "min", "max"), &ImGuiCanvas::drag_float3, DEFVAL(1.0f), DEFVAL(0.0f), DEFVAL(0.0f));
	ClassDB::bind_method(D_METHOD("input_float", "label", "v", "step", "step_fast"), &ImGuiCanvas::input_float, DEFVAL(0.0f), DEFVAL(0.0f));
	ClassDB::bind_method(D_METHOD("input_int", "label", "v", "step", "step_fast"), &ImGuiCanvas::input_int, DEFVAL(1), DEFVAL(100));
	ClassDB::bind_method(D_METHOD("input_text", "label", "value"), &ImGuiCanvas::input_text);
	ClassDB::bind_method(D_METHOD("input_text_enter", "label", "value"), &ImGuiCanvas::input_text_enter);
	ClassDB::bind_method(D_METHOD("set_keyboard_focus_here"), &ImGuiCanvas::set_keyboard_focus_here);
	ClassDB::bind_method(D_METHOD("input_text_multiline", "label", "value", "size"), &ImGuiCanvas::input_text_multiline);
	ClassDB::bind_method(D_METHOD("color_edit3", "label", "color"), &ImGuiCanvas::color_edit3);
	ClassDB::bind_method(D_METHOD("color_edit4", "label", "color"), &ImGuiCanvas::color_edit4);
	ClassDB::bind_method(D_METHOD("color_picker4", "label", "color"), &ImGuiCanvas::color_picker4);
	ClassDB::bind_method(D_METHOD("combo", "label", "current", "items"), &ImGuiCanvas::combo);
	ClassDB::bind_method(D_METHOD("list_box", "label", "current", "items", "height_items"), &ImGuiCanvas::list_box, DEFVAL(-1));

	// Arboles / pestañas
	ClassDB::bind_method(D_METHOD("tree_node", "label", "flags"), &ImGuiCanvas::tree_node, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("tree_pop"), &ImGuiCanvas::tree_pop);
	ClassDB::bind_method(D_METHOD("collapsing_header", "label", "flags"), &ImGuiCanvas::collapsing_header, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("begin_tab_bar", "id"), &ImGuiCanvas::begin_tab_bar);
	ClassDB::bind_method(D_METHOD("end_tab_bar"), &ImGuiCanvas::end_tab_bar);
	ClassDB::bind_method(D_METHOD("begin_tab_item", "label"), &ImGuiCanvas::begin_tab_item);
	ClassDB::bind_method(D_METHOD("end_tab_item"), &ImGuiCanvas::end_tab_item);

	// Tablas
	ClassDB::bind_method(D_METHOD("begin_table", "id", "columns", "flags"), &ImGuiCanvas::begin_table, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("end_table"), &ImGuiCanvas::end_table);
	ClassDB::bind_method(D_METHOD("table_setup_column", "label"), &ImGuiCanvas::table_setup_column);
	ClassDB::bind_method(D_METHOD("table_headers_row"), &ImGuiCanvas::table_headers_row);
	ClassDB::bind_method(D_METHOD("table_next_row"), &ImGuiCanvas::table_next_row);
	ClassDB::bind_method(D_METHOD("table_next_column"), &ImGuiCanvas::table_next_column);

	// Menus / popups
	ClassDB::bind_method(D_METHOD("begin_main_menu_bar"), &ImGuiCanvas::begin_main_menu_bar);
	ClassDB::bind_method(D_METHOD("end_main_menu_bar"), &ImGuiCanvas::end_main_menu_bar);
	ClassDB::bind_method(D_METHOD("begin_menu_bar"), &ImGuiCanvas::begin_menu_bar);
	ClassDB::bind_method(D_METHOD("end_menu_bar"), &ImGuiCanvas::end_menu_bar);
	ClassDB::bind_method(D_METHOD("begin_menu", "label"), &ImGuiCanvas::begin_menu);
	ClassDB::bind_method(D_METHOD("end_menu"), &ImGuiCanvas::end_menu);
	ClassDB::bind_method(D_METHOD("menu_item", "label", "shortcut", "selected"), &ImGuiCanvas::menu_item, DEFVAL(String()), DEFVAL(false));
	ClassDB::bind_method(D_METHOD("open_popup", "id"), &ImGuiCanvas::open_popup);
	ClassDB::bind_method(D_METHOD("begin_popup", "id"), &ImGuiCanvas::begin_popup);
	ClassDB::bind_method(D_METHOD("begin_popup_modal", "title"), &ImGuiCanvas::begin_popup_modal);
	ClassDB::bind_method(D_METHOD("end_popup"), &ImGuiCanvas::end_popup);
	ClassDB::bind_method(D_METHOD("close_current_popup"), &ImGuiCanvas::close_current_popup);
	ClassDB::bind_method(D_METHOD("begin_popup_context_item", "id"), &ImGuiCanvas::begin_popup_context_item, DEFVAL(String()));
	ClassDB::bind_method(D_METHOD("set_tooltip", "s"), &ImGuiCanvas::set_tooltip);
	ClassDB::bind_method(D_METHOD("begin_tooltip"), &ImGuiCanvas::begin_tooltip);
	ClassDB::bind_method(D_METHOD("end_tooltip"), &ImGuiCanvas::end_tooltip);

	// Estado del item
	ClassDB::bind_method(D_METHOD("is_item_hovered"), &ImGuiCanvas::is_item_hovered);
	ClassDB::bind_method(D_METHOD("is_item_active"), &ImGuiCanvas::is_item_active);
	ClassDB::bind_method(D_METHOD("is_item_clicked", "button"), &ImGuiCanvas::is_item_clicked, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("is_item_edited"), &ImGuiCanvas::is_item_edited);
	ClassDB::bind_method(D_METHOD("is_mouse_clicked", "button"), &ImGuiCanvas::is_mouse_clicked);
	ClassDB::bind_method(D_METHOD("is_mouse_double_clicked"), &ImGuiCanvas::is_mouse_double_clicked);
	ClassDB::bind_method(D_METHOD("is_key_pressed", "key"), &ImGuiCanvas::is_key_pressed);
	ClassDB::bind_method(D_METHOD("get_mouse_pos"), &ImGuiCanvas::get_mouse_pos);

	// Graficos nativos
	ClassDB::bind_vararg_method(METHOD_FLAGS_DEFAULT, "plot_lines", &ImGuiCanvas::_plot_lines_vararg, MethodInfo("plot_lines"));
	ClassDB::bind_vararg_method(METHOD_FLAGS_DEFAULT, "plot_histogram", &ImGuiCanvas::_plot_histogram_vararg, MethodInfo("plot_histogram"));

	// Estilo
	ClassDB::bind_method(D_METHOD("style_colors_dark"), &ImGuiCanvas::style_colors_dark);
	ClassDB::bind_method(D_METHOD("style_colors_light"), &ImGuiCanvas::style_colors_light);
	ClassDB::bind_method(D_METHOD("style_colors_classic"), &ImGuiCanvas::style_colors_classic);
	ClassDB::bind_method(D_METHOD("push_style_color", "idx", "color"), &ImGuiCanvas::push_style_color);
	ClassDB::bind_method(D_METHOD("pop_style_color", "n"), &ImGuiCanvas::pop_style_color, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("push_style_var_float", "idx", "v"), &ImGuiCanvas::push_style_var_float);
	ClassDB::bind_method(D_METHOD("push_style_var_vec2", "idx", "v"), &ImGuiCanvas::push_style_var_vec2);
	ClassDB::bind_method(D_METHOD("pop_style_var", "n"), &ImGuiCanvas::pop_style_var, DEFVAL(1));

	// Demos
#ifdef IMGUI_MODULE_DEMOS
	ClassDB::bind_method(D_METHOD("show_demo_window"), &ImGuiCanvas::show_demo_window);
#endif
	ClassDB::bind_method(D_METHOD("show_metrics_window"), &ImGuiCanvas::show_metrics_window);
#if defined(IMGUI_MODULE_DEMOS) && defined(IMGUI_MODULE_IMPLOT)
	ClassDB::bind_method(D_METHOD("implot_show_demo_window"), &ImGuiCanvas::implot_show_demo_window);
#endif
#if defined(IMGUI_MODULE_DEMOS) && defined(IMGUI_MODULE_IMPLOT3D)
	ClassDB::bind_method(D_METHOD("implot3d_show_demo_window"), &ImGuiCanvas::implot3d_show_demo_window);
#endif

	// ImPlot
#ifdef IMGUI_MODULE_IMPLOT
	ClassDB::bind_method(D_METHOD("implot_begin_plot", "title", "size", "flags"), &ImGuiCanvas::implot_begin_plot, DEFVAL(Vector2(-1, 0)), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("implot_end_plot"), &ImGuiCanvas::implot_end_plot);
	ClassDB::bind_method(D_METHOD("implot_setup_axes", "x_label", "y_label", "x_flags", "y_flags"), &ImGuiCanvas::implot_setup_axes, DEFVAL(0), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("implot_setup_axis_limits", "axis", "min", "max", "cond_always"), &ImGuiCanvas::implot_setup_axis_limits, DEFVAL(false));
	ClassDB::bind_method(D_METHOD("implot_plot_line", "label", "xs", "ys"), &ImGuiCanvas::implot_plot_line);
	ClassDB::bind_method(D_METHOD("implot_plot_scatter", "label", "xs", "ys"), &ImGuiCanvas::implot_plot_scatter);
	ClassDB::bind_method(D_METHOD("implot_plot_bars", "label", "values", "bar_size"), &ImGuiCanvas::implot_plot_bars, DEFVAL(0.67f));
	ClassDB::bind_method(D_METHOD("implot_plot_shaded", "label", "xs", "ys", "y_ref"), &ImGuiCanvas::implot_plot_shaded, DEFVAL(0.0f));
	ClassDB::bind_vararg_method(METHOD_FLAGS_DEFAULT, "implot_plot_heatmap", &ImGuiCanvas::_implot_plot_heatmap_vararg, MethodInfo("implot_plot_heatmap"));
#endif

	// ImPlot3D
#ifdef IMGUI_MODULE_IMPLOT3D
	ClassDB::bind_method(D_METHOD("implot3d_begin_plot", "title", "size", "flags"), &ImGuiCanvas::implot3d_begin_plot, DEFVAL(Vector2(-1, 0)), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("implot3d_end_plot"), &ImGuiCanvas::implot3d_end_plot);
	ClassDB::bind_method(D_METHOD("implot3d_setup_axes", "x", "y", "z"), &ImGuiCanvas::implot3d_setup_axes);
	ClassDB::bind_method(D_METHOD("implot3d_setup_axes_flags", "x", "y", "z", "flags"), &ImGuiCanvas::implot3d_setup_axes_flags);
	ClassDB::bind_method(D_METHOD("implot3d_plot_line", "label", "xs", "ys", "zs"), &ImGuiCanvas::implot3d_plot_line);
	ClassDB::bind_method(D_METHOD("implot3d_plot_scatter", "label", "xs", "ys", "zs"), &ImGuiCanvas::implot3d_plot_scatter);
	ClassDB::bind_vararg_method(METHOD_FLAGS_DEFAULT, "implot3d_plot_surface", &ImGuiCanvas::_implot3d_plot_surface_vararg, MethodInfo("implot3d_plot_surface"));
#endif

	// Menu radial
	ClassDB::bind_method(D_METHOD("open_pie_menu", "id"), &ImGuiCanvas::open_pie_menu);
	ClassDB::bind_method(D_METHOD("pie_menu", "id", "items"), &ImGuiCanvas::pie_menu);

	ClassDB::bind_method(D_METHOD("set_imgui_scale", "scale"), &ImGuiCanvas::set_scale);
	ClassDB::bind_method(D_METHOD("get_imgui_scale"), &ImGuiCanvas::get_scale);
	ADD_PROPERTY(PropertyInfo(Variant::REAL, "imgui_scale"), "set_imgui_scale", "get_imgui_scale");

	ClassDB::bind_method(D_METHOD("set_frame_rounding", "rounding"), &ImGuiCanvas::set_frame_rounding);
	ClassDB::bind_method(D_METHOD("get_frame_rounding"), &ImGuiCanvas::get_frame_rounding);
	ADD_PROPERTY(PropertyInfo(Variant::REAL, "frame_rounding"), "set_frame_rounding", "get_frame_rounding");

	ClassDB::bind_method(D_METHOD("_input", "event"), &ImGuiCanvas::_input);

	// Flags de ventana
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_NO_DECORATION", ImGuiWindowFlags_NoDecoration);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_NO_BACKGROUND", ImGuiWindowFlags_NoBackground);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_NO_MOVE", ImGuiWindowFlags_NoMove);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_NO_SAVED_SETTINGS", ImGuiWindowFlags_NoSavedSettings);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_NO_BRING_TO_FRONT_ON_FOCUS", ImGuiWindowFlags_NoBringToFrontOnFocus);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_NO_TITLE_BAR", ImGuiWindowFlags_NoTitleBar);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_NO_RESIZE", ImGuiWindowFlags_NoResize);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_NO_SCROLLBAR", ImGuiWindowFlags_NoScrollbar);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_NO_COLLAPSE", ImGuiWindowFlags_NoCollapse);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_ALWAYS_AUTO_RESIZE", ImGuiWindowFlags_AlwaysAutoResize);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "WINDOW_MENU_BAR", ImGuiWindowFlags_MenuBar);

	// Arboles / tablas
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "TREE_NODE_DEFAULT_OPEN", ImGuiTreeNodeFlags_DefaultOpen);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "TABLE_BORDERS", ImGuiTableFlags_Borders);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "TABLE_ROW_BG", ImGuiTableFlags_RowBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "TABLE_RESIZABLE", ImGuiTableFlags_Resizable);

	// Colores de estilo
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TEXT", ImGuiCol_Text);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TEXT_DISABLED", ImGuiCol_TextDisabled);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_WINDOW_BG", ImGuiCol_WindowBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_CHILD_BG", ImGuiCol_ChildBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_POPUP_BG", ImGuiCol_PopupBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_BORDER", ImGuiCol_Border);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_BORDER_SHADOW", ImGuiCol_BorderShadow);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_FRAME_BG", ImGuiCol_FrameBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_FRAME_BG_HOVERED", ImGuiCol_FrameBgHovered);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_FRAME_BG_ACTIVE", ImGuiCol_FrameBgActive);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TITLE_BG", ImGuiCol_TitleBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TITLE_BG_ACTIVE", ImGuiCol_TitleBgActive);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TITLE_BG_COLLAPSED", ImGuiCol_TitleBgCollapsed);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_MENU_BAR_BG", ImGuiCol_MenuBarBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_SCROLLBAR_BG", ImGuiCol_ScrollbarBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_SCROLLBAR_GRAB", ImGuiCol_ScrollbarGrab);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_CHECK_MARK", ImGuiCol_CheckMark);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_SLIDER_GRAB", ImGuiCol_SliderGrab);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_BUTTON", ImGuiCol_Button);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_BUTTON_HOVERED", ImGuiCol_ButtonHovered);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_BUTTON_ACTIVE", ImGuiCol_ButtonActive);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_HEADER", ImGuiCol_Header);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_HEADER_HOVERED", ImGuiCol_HeaderHovered);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_HEADER_ACTIVE", ImGuiCol_HeaderActive);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_SEPARATOR", ImGuiCol_Separator);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TAB", ImGuiCol_Tab);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TAB_HOVERED", ImGuiCol_TabHovered);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TAB_ACTIVE", ImGuiCol_TabSelected);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_PLOT_LINES", ImGuiCol_PlotLines);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_PLOT_HISTOGRAM", ImGuiCol_PlotHistogram);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TABLE_HEADER_BG", ImGuiCol_TableHeaderBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TABLE_BORDER_STRONG", ImGuiCol_TableBorderStrong);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TABLE_ROW_BG", ImGuiCol_TableRowBg);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "COL_TEXT_SELECTED_BG", ImGuiCol_TextSelectedBg);

	// Variables de estilo
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "STYLE_VAR_FRAME_ROUNDING", ImGuiStyleVar_FrameRounding);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "STYLE_VAR_WINDOW_ROUNDING", ImGuiStyleVar_WindowRounding);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "STYLE_VAR_FRAME_PADDING", ImGuiStyleVar_FramePadding);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "STYLE_VAR_ITEM_SPACING", ImGuiStyleVar_ItemSpacing);

	// ImPlot
#ifdef IMGUI_MODULE_IMPLOT
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_AXIS_X1", ImAxis_X1);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_AXIS_Y1", ImAxis_Y1);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_AXIS_AUTOFIT", ImPlotAxisFlags_AutoFit);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_AXIS_NO_DECORATIONS", ImPlotAxisFlags_NoDecorations);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_FLAGS_NONE", ImPlotFlags_None);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_FLAGS_NO_TITLE", ImPlotFlags_NoTitle);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_FLAGS_NO_LEGEND", ImPlotFlags_NoLegend);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_FLAGS_NO_MOUSE_TEXT", ImPlotFlags_NoMouseText);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_FLAGS_NO_INPUTS", ImPlotFlags_NoInputs);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_FLAGS_NO_MENUS", ImPlotFlags_NoMenus);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_FLAGS_NO_BOX_SELECT", ImPlotFlags_NoBoxSelect);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_FLAGS_NO_FRAME", ImPlotFlags_NoFrame);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT_FLAGS_CANVAS_ONLY", ImPlotFlags_CanvasOnly);
#endif
#ifdef IMGUI_MODULE_IMPLOT3D
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT3D_AXIS_NONE", ImPlot3DAxisFlags_None);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT3D_AXIS_AUTOFIT", ImPlot3DAxisFlags_AutoFit);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT3D_FLAGS_NONE", ImPlot3DFlags_None);
	ClassDB::bind_integer_constant(get_class_static(), StringName(), "IMPLOT3D_FLAGS_NO_CLIP", ImPlot3DFlags_NoClip);
#endif

	ClassDB::bind_method(D_METHOD("has_feature", "feature"), &ImGuiCanvas::has_feature);

	ADD_SIGNAL(MethodInfo("imgui_frame"));
}

RID ImGuiCanvas::_get_canvas_item(int p_index) {
	while (canvas_items.size() <= p_index) {
		canvas_items.push_back(VS::get_singleton()->canvas_item_create());
	}
	return canvas_items[p_index];
}

void ImGuiCanvas::_set_contexts() {
	ImGui::SetCurrentContext(context);
#ifdef IMGUI_MODULE_IMPLOT
	ImPlot::SetCurrentContext(implot_context);
#endif
#ifdef IMGUI_MODULE_IMPLOT3D
	ImPlot3D::SetCurrentContext(implot3d_context);
#endif
}

bool ImGuiCanvas::has_feature(const String &p_feature) const {
#ifdef IMGUI_MODULE_IMPLOT
	if (p_feature == "implot") {
		return true;
	}
#endif
#ifdef IMGUI_MODULE_IMPLOT3D
	if (p_feature == "implot3d") {
		return true;
	}
#endif
#ifdef IMGUI_MODULE_DEMOS
	if (p_feature == "demos") {
		return true;
	}
#endif
	if (p_feature == "log") {
		return true;
	}
	return false;
}

void ImGuiCanvas::_process_frame(float p_delta) {
	_set_contexts();
	ImGuiIO &io = ImGui::GetIO();

	for (int i = 0; i < frame_texture_rids.size(); i++) {
		memdelete(frame_texture_rids[i]);
	}
	frame_texture_rids.clear();
	frame_textures.clear();

	Size2 size = get_viewport_rect().size;
	io.DisplaySize = ImVec2(size.x, size.y);
	io.DeltaTime = p_delta > 0.0001f ? p_delta : 0.0001f;

	ImGui::NewFrame();
	emit_signal("imgui_frame");
	ImGui::Render();

	// El latch de teclas solo vale para el frame en que se pulso (is_key_pressed
	// ya se consulto en imgui_frame).
	frame_pressed_keys.clear();

	if (io.WantTextInput != want_text_input) {
		want_text_input = io.WantTextInput;
		if (want_text_input) {
			OS::get_singleton()->show_virtual_keyboard("");
		} else {
			OS::get_singleton()->hide_virtual_keyboard();
		}
	}

	ImDrawData *draw_data = ImGui::GetDrawData();
	if (draw_data == nullptr) {
		return;
	}

	int draw_index = 0;
	int used = 0;

	VisualServer *vs = VisualServer::get_singleton();

	for (int i = 0; i < draw_data->CmdListsCount; i++) {
		ImDrawList *cmd_list = draw_data->CmdLists[i];
		if (cmd_list == nullptr) {
			continue;
		}

		// Vertices are shared by every cmd of the list; Vector is COW so passing them per cmd is free.
		int vtx_count = cmd_list->VtxBuffer.Size;
		Vector<Point2> points;
		Vector<Point2> uvs;
		Vector<Color> colors;
		points.resize(vtx_count);
		uvs.resize(vtx_count);
		colors.resize(vtx_count);
		Point2 *points_ptr = points.ptrw();
		Point2 *uvs_ptr = uvs.ptrw();
		Color *colors_ptr = colors.ptrw();
		for (int v = 0; v < vtx_count; v++) {
			const ImDrawVert &vert = cmd_list->VtxBuffer[v];
			points_ptr[v] = Point2(vert.pos.x, vert.pos.y);
			uvs_ptr[v] = Point2(vert.uv.x, vert.uv.y);
			ImU32 c = vert.col;
			colors_ptr[v] = Color(
					((c >> IM_COL32_R_SHIFT) & 0xFF) / 255.0f,
					((c >> IM_COL32_G_SHIFT) & 0xFF) / 255.0f,
					((c >> IM_COL32_B_SHIFT) & 0xFF) / 255.0f,
					((c >> IM_COL32_A_SHIFT) & 0xFF) / 255.0f);
		}

		for (int j = 0; j < cmd_list->CmdBuffer.Size; j++) {
			const ImDrawCmd &cmd = cmd_list->CmdBuffer[j];
			if (cmd.UserCallback != nullptr || cmd.ElemCount == 0) {
				continue;
			}

			RID ci = _get_canvas_item(used++);
			vs->canvas_item_set_parent(ci, get_canvas_item());
			vs->canvas_item_clear(ci);

			Rect2 clip(cmd.ClipRect.x, cmd.ClipRect.y, cmd.ClipRect.z - cmd.ClipRect.x, cmd.ClipRect.w - cmd.ClipRect.y);
			vs->canvas_item_set_custom_rect(ci, true, clip);
			vs->canvas_item_set_clip(ci, true);
			vs->canvas_item_set_draw_index(ci, draw_index++);

			Vector<int> indices;
			indices.resize(cmd.ElemCount);
			int *indices_ptr = indices.ptrw();
			for (unsigned int k = 0; k < cmd.ElemCount; k++) {
				indices_ptr[k] = (int)cmd_list->IdxBuffer[cmd.IdxOffset + k];
			}

			RID texture;
			if (cmd.GetTexID() != 0) {
				texture = *(RID *)(intptr_t)cmd.GetTexID();
			}

			vs->canvas_item_add_triangle_array(ci, indices, points, colors, uvs, Vector<int>(), Vector<float>(), texture);
		}
	}

	for (int i = used; i < canvas_items.size(); i++) {
		vs->canvas_item_clear(canvas_items[i]);
	}
}

void ImGuiCanvas::_notification(int p_what) {
	Node2D::_notification(p_what);

	switch (p_what) {
		case NOTIFICATION_READY: {
			_set_contexts();
			ImGuiIO &io = ImGui::GetIO();

			unsigned char *pixels = nullptr;
			int width = 0;
			int height = 0;
			io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);

			PoolVector<uint8_t> data;
			data.resize(width * height * 4);
			{
				PoolVector<uint8_t>::Write w = data.write();
				memcpy(w.ptr(), pixels, width * height * 4);
			}

			Ref<Image> image = memnew(Image(width, height, false, Image::FORMAT_RGBA8, data));
			font_texture.instance();
			font_texture->create_from_image(image, 0);
			font_texture_rid = font_texture->get_rid();
			io.Fonts->SetTexID((ImTextureID)(intptr_t)&font_texture_rid);

			io.FontGlobalScale = scale;
			ImGui::GetStyle().FrameRounding = frame_rounding;
			ImGui::GetStyle().ScaleAllSizes(scale);

			set_process(true);
			set_process_input(true);
		} break;

		case NOTIFICATION_PROCESS: {
			_process_frame(get_process_delta_time());
		} break;
	}
}

// --- Ventanas / layout ---

bool ImGuiCanvas::begin(const String &p_title, int p_flags, bool p_closable) {
	_set_contexts();
	if (!p_closable) {
		window_open = true;
	}
	return ImGui::Begin(p_title.utf8().get_data(), p_closable ? &window_open : nullptr, (ImGuiWindowFlags)p_flags);
}

void ImGuiCanvas::end() {
	_set_contexts();
	ImGui::End();
}

bool ImGuiCanvas::is_window_open() const {
	return window_open;
}

void ImGuiCanvas::set_next_window_pos(const Vector2 &p_pos, bool p_always) {
	_set_contexts();
	ImGui::SetNextWindowPos(ImVec2(p_pos.x, p_pos.y), p_always ? ImGuiCond_Always : ImGuiCond_FirstUseEver);
}

void ImGuiCanvas::set_next_window_size(const Vector2 &p_size, bool p_always) {
	_set_contexts();
	ImGui::SetNextWindowSize(ImVec2(p_size.x, p_size.y), p_always ? ImGuiCond_Always : ImGuiCond_FirstUseEver);
}

void ImGuiCanvas::set_next_window_bg_alpha(float p_alpha) {
	_set_contexts();
	ImGui::SetNextWindowBgAlpha(p_alpha);
}

void ImGuiCanvas::set_cursor_pos(const Vector2 &p_pos) {
	_set_contexts();
	ImGui::SetCursorPos(ImVec2(p_pos.x, p_pos.y));
}

void ImGuiCanvas::same_line(float p_offset, float p_spacing) {
	_set_contexts();
	ImGui::SameLine(p_offset, p_spacing);
}

void ImGuiCanvas::new_line() {
	_set_contexts();
	ImGui::NewLine();
}

void ImGuiCanvas::spacing() {
	_set_contexts();
	ImGui::Spacing();
}

void ImGuiCanvas::dummy(const Vector2 &p_size) {
	_set_contexts();
	ImGui::Dummy(ImVec2(p_size.x, p_size.y));
}

void ImGuiCanvas::indent(float p_w) {
	_set_contexts();
	ImGui::Indent(p_w);
}

void ImGuiCanvas::unindent(float p_w) {
	_set_contexts();
	ImGui::Unindent(p_w);
}

void ImGuiCanvas::separator() {
	_set_contexts();
	ImGui::Separator();
}

void ImGuiCanvas::separator_text(const String &p_label) {
	_set_contexts();
	ImGui::SeparatorText(p_label.utf8().get_data());
}

void ImGuiCanvas::begin_group() {
	_set_contexts();
	ImGui::BeginGroup();
}

void ImGuiCanvas::end_group() {
	_set_contexts();
	ImGui::EndGroup();
}

void ImGuiCanvas::push_id(const String &p_id) {
	_set_contexts();
	ImGui::PushID(p_id.utf8().get_data());
}

void ImGuiCanvas::pop_id() {
	_set_contexts();
	ImGui::PopID();
}

void ImGuiCanvas::push_item_width(float p_w) {
	_set_contexts();
	ImGui::PushItemWidth(p_w);
}

void ImGuiCanvas::pop_item_width() {
	_set_contexts();
	ImGui::PopItemWidth();
}

Vector2 ImGuiCanvas::get_content_region_avail() {
	_set_contexts();
	ImVec2 v = ImGui::GetContentRegionAvail();
	return Vector2(v.x, v.y);
}

Vector2 ImGuiCanvas::get_window_size() {
	_set_contexts();
	ImVec2 v = ImGui::GetWindowSize();
	return Vector2(v.x, v.y);
}

Vector2 ImGuiCanvas::get_window_pos() {
	_set_contexts();
	ImVec2 v = ImGui::GetWindowPos();
	return Vector2(v.x, v.y);
}

bool ImGuiCanvas::begin_child(const String &p_id, const Vector2 &p_size) {
	_set_contexts();
	return ImGui::BeginChild(p_id.utf8().get_data(), ImVec2(p_size.x, p_size.y));
}

void ImGuiCanvas::end_child() {
	_set_contexts();
	ImGui::EndChild();
}

void ImGuiCanvas::set_scroll_here_y(float p_ratio) {
	_set_contexts();
	ImGui::SetScrollHereY(p_ratio);
}

// --- Texto ---

void ImGuiCanvas::text(const String &p_text) {
	_set_contexts();
	ImGui::TextUnformatted(p_text.utf8().get_data());
}

void ImGuiCanvas::text_wrapped(const String &p_text) {
	_set_contexts();
	ImGui::PushTextWrapPos(0.0f);
	ImGui::TextUnformatted(p_text.utf8().get_data());
	ImGui::PopTextWrapPos();
}

void ImGuiCanvas::text_colored(const Color &p_color, const String &p_text) {
	_set_contexts();
	ImGui::TextColored(_to_imvec4(p_color), "%s", p_text.utf8().get_data());
}

void ImGuiCanvas::text_disabled(const String &p_text) {
	_set_contexts();
	ImGui::TextDisabled("%s", p_text.utf8().get_data());
}

void ImGuiCanvas::bullet_text(const String &p_text) {
	_set_contexts();
	ImGui::BulletText("%s", p_text.utf8().get_data());
}

void ImGuiCanvas::label_text(const String &p_label, const String &p_text) {
	_set_contexts();
	ImGui::LabelText(p_label.utf8().get_data(), "%s", p_text.utf8().get_data());
}

// --- Botones / seleccion ---

bool ImGuiCanvas::button(const String &p_label, const Vector2 &p_size) {
	_set_contexts();
	return ImGui::Button(p_label.utf8().get_data(), ImVec2(p_size.x, p_size.y));
}

bool ImGuiCanvas::small_button(const String &p_label) {
	_set_contexts();
	return ImGui::SmallButton(p_label.utf8().get_data());
}

bool ImGuiCanvas::checkbox(const String &p_label, bool p_value) {
	_set_contexts();
	bool value = p_value;
	ImGui::Checkbox(p_label.utf8().get_data(), &value);
	return value;
}

bool ImGuiCanvas::radio_button(const String &p_label, bool p_active) {
	_set_contexts();
	return ImGui::RadioButton(p_label.utf8().get_data(), p_active);
}

bool ImGuiCanvas::selectable(const String &p_label, bool p_selected, const Vector2 &p_size) {
	_set_contexts();
	return ImGui::Selectable(p_label.utf8().get_data(), p_selected, 0, ImVec2(p_size.x, p_size.y));
}

void ImGuiCanvas::progress_bar(float p_frac, const Vector2 &p_size, const String &p_overlay) {
	_set_contexts();
	ImGui::ProgressBar(p_frac, ImVec2(p_size.x, p_size.y), p_overlay == "" ? nullptr : p_overlay.utf8().get_data());
}

void ImGuiCanvas::image(const Ref<Texture> &p_texture, const Vector2 &p_size, const Color &p_tint) {
	_set_contexts();
	if (p_texture.is_null()) {
		return;
	}
	frame_textures.push_back(p_texture);
	RID *rid = memnew(RID(p_texture->get_rid()));
	frame_texture_rids.push_back(rid);
	ImGui::ImageWithBg((ImTextureID)(intptr_t)rid, ImVec2(p_size.x, p_size.y), ImVec2(0, 0), ImVec2(1, 1), ImVec4(0, 0, 0, 0), _to_imvec4(p_tint));
}

bool ImGuiCanvas::image_button(const String &p_id, const Ref<Texture> &p_texture, const Vector2 &p_size) {
	_set_contexts();
	if (p_texture.is_null()) {
		return false;
	}
	frame_textures.push_back(p_texture);
	RID *rid = memnew(RID(p_texture->get_rid()));
	frame_texture_rids.push_back(rid);
	return ImGui::ImageButton(p_id.utf8().get_data(), (ImTextureID)(intptr_t)rid, ImVec2(p_size.x, p_size.y));
}

// --- Entrada ---

float ImGuiCanvas::slider_float(const String &p_label, float p_v, float p_min, float p_max, const String &p_fmt) {
	_set_contexts();
	float value = p_v;
	ImGui::SliderFloat(p_label.utf8().get_data(), &value, p_min, p_max, p_fmt.utf8().get_data());
	return value;
}

int ImGuiCanvas::slider_int(const String &p_label, int p_v, int p_min, int p_max) {
	_set_contexts();
	int value = p_v;
	ImGui::SliderInt(p_label.utf8().get_data(), &value, p_min, p_max);
	return value;
}

Vector2 ImGuiCanvas::slider_float2(const String &p_label, const Vector2 &p_v, float p_min, float p_max) {
	_set_contexts();
	float values[2] = { p_v.x, p_v.y };
	ImGui::SliderFloat2(p_label.utf8().get_data(), values, p_min, p_max);
	return Vector2(values[0], values[1]);
}

Vector3 ImGuiCanvas::slider_float3(const String &p_label, const Vector3 &p_v, float p_min, float p_max) {
	_set_contexts();
	float values[3] = { p_v.x, p_v.y, p_v.z };
	ImGui::SliderFloat3(p_label.utf8().get_data(), values, p_min, p_max);
	return Vector3(values[0], values[1], values[2]);
}

float ImGuiCanvas::drag_float(const String &p_label, float p_v, float p_speed, float p_min, float p_max) {
	_set_contexts();
	float value = p_v;
	ImGui::DragFloat(p_label.utf8().get_data(), &value, p_speed, p_min, p_max);
	return value;
}

int ImGuiCanvas::drag_int(const String &p_label, int p_v, float p_speed, int p_min, int p_max) {
	_set_contexts();
	int value = p_v;
	ImGui::DragInt(p_label.utf8().get_data(), &value, p_speed, p_min, p_max);
	return value;
}

Vector2 ImGuiCanvas::drag_float2(const String &p_label, const Vector2 &p_v, float p_speed, float p_min, float p_max) {
	_set_contexts();
	float values[2] = { p_v.x, p_v.y };
	ImGui::DragFloat2(p_label.utf8().get_data(), values, p_speed, p_min, p_max);
	return Vector2(values[0], values[1]);
}

Vector3 ImGuiCanvas::drag_float3(const String &p_label, const Vector3 &p_v, float p_speed, float p_min, float p_max) {
	_set_contexts();
	float values[3] = { p_v.x, p_v.y, p_v.z };
	ImGui::DragFloat3(p_label.utf8().get_data(), values, p_speed, p_min, p_max);
	return Vector3(values[0], values[1], values[2]);
}

float ImGuiCanvas::input_float(const String &p_label, float p_v, float p_step, float p_step_fast) {
	_set_contexts();
	float value = p_v;
	ImGui::InputFloat(p_label.utf8().get_data(), &value, p_step, p_step_fast);
	return value;
}

int ImGuiCanvas::input_int(const String &p_label, int p_v, int p_step, int p_step_fast) {
	_set_contexts();
	int value = p_v;
	ImGui::InputInt(p_label.utf8().get_data(), &value, p_step, p_step_fast);
	return value;
}

String ImGuiCanvas::input_text(const String &p_label, const String &p_value) {
	_set_contexts();
	char buffer[1024];
	CharString value = p_value.utf8();
	int len = value.length();
	if (len > 1023) {
		len = 1023;
	}
	if (len > 0) {
		memcpy(buffer, value.get_data(), len);
	}
	buffer[len] = 0;
	ImGui::InputText(p_label.utf8().get_data(), buffer, sizeof(buffer));
	return String::utf8(buffer);
}

void ImGuiCanvas::set_keyboard_focus_here() {
	_set_contexts();
	ImGui::SetKeyboardFocusHere();
}

Dictionary ImGuiCanvas::input_text_enter(const String &p_label, const String &p_value) {
	_set_contexts();
	char buffer[1024];
	CharString value = p_value.utf8();
	int len = value.length();
	if (len > 1023) {
		len = 1023;
	}
	if (len > 0) {
		memcpy(buffer, value.get_data(), len);
	}
	buffer[len] = 0;
	bool submitted = ImGui::InputText(p_label.utf8().get_data(), buffer, sizeof(buffer), ImGuiInputTextFlags_EnterReturnsTrue);
	Dictionary result;
	result["text"] = String::utf8(buffer);
	result["submitted"] = submitted;
	return result;
}

String ImGuiCanvas::input_text_multiline(const String &p_label, const String &p_value, const Vector2 &p_size) {
	_set_contexts();
	static char buffer[16384];
	CharString value = p_value.utf8();
	int len = value.length();
	if (len > 16383) {
		len = 16383;
	}
	if (len > 0) {
		memcpy(buffer, value.get_data(), len);
	}
	buffer[len] = 0;
	ImGui::InputTextMultiline(p_label.utf8().get_data(), buffer, sizeof(buffer), ImVec2(p_size.x, p_size.y));
	return String::utf8(buffer);
}

Color ImGuiCanvas::color_edit3(const String &p_label, const Color &p_color) {
	_set_contexts();
	float values[3] = { p_color.r, p_color.g, p_color.b };
	ImGui::ColorEdit3(p_label.utf8().get_data(), values);
	return Color(values[0], values[1], values[2], p_color.a);
}

Color ImGuiCanvas::color_edit4(const String &p_label, const Color &p_color) {
	_set_contexts();
	float values[4] = { p_color.r, p_color.g, p_color.b, p_color.a };
	ImGui::ColorEdit4(p_label.utf8().get_data(), values);
	return _from_imvec4(ImVec4(values[0], values[1], values[2], values[3]));
}

Color ImGuiCanvas::color_picker4(const String &p_label, const Color &p_color) {
	_set_contexts();
	float values[4] = { p_color.r, p_color.g, p_color.b, p_color.a };
	ImGui::ColorPicker4(p_label.utf8().get_data(), values);
	return _from_imvec4(ImVec4(values[0], values[1], values[2], values[3]));
}

int ImGuiCanvas::combo(const String &p_label, int p_current, const PoolStringArray &p_items) {
	_set_contexts();
	int current = p_current;
	Vector<CharString> storage;
	Vector<const char *> ptrs;
	_build_char_ptrs(p_items, storage, ptrs);
	if (ptrs.size() > 0) {
		ImGui::Combo(p_label.utf8().get_data(), &current, ptrs.ptr(), ptrs.size());
	}
	return current;
}

int ImGuiCanvas::list_box(const String &p_label, int p_current, const PoolStringArray &p_items, int p_height_items) {
	_set_contexts();
	int current = p_current;
	Vector<CharString> storage;
	Vector<const char *> ptrs;
	_build_char_ptrs(p_items, storage, ptrs);
	if (ptrs.size() > 0) {
		ImGui::ListBox(p_label.utf8().get_data(), &current, ptrs.ptr(), ptrs.size(), p_height_items);
	}
	return current;
}

// --- Arboles / pestañas ---

bool ImGuiCanvas::tree_node(const String &p_label, int p_flags) {
	_set_contexts();
	return ImGui::TreeNodeEx(p_label.utf8().get_data(), (ImGuiTreeNodeFlags)p_flags);
}

void ImGuiCanvas::tree_pop() {
	_set_contexts();
	ImGui::TreePop();
}

bool ImGuiCanvas::collapsing_header(const String &p_label, int p_flags) {
	_set_contexts();
	return ImGui::CollapsingHeader(p_label.utf8().get_data(), (ImGuiTreeNodeFlags)p_flags);
}

bool ImGuiCanvas::begin_tab_bar(const String &p_id) {
	_set_contexts();
	return ImGui::BeginTabBar(p_id.utf8().get_data());
}

void ImGuiCanvas::end_tab_bar() {
	_set_contexts();
	ImGui::EndTabBar();
}

bool ImGuiCanvas::begin_tab_item(const String &p_label) {
	_set_contexts();
	return ImGui::BeginTabItem(p_label.utf8().get_data());
}

void ImGuiCanvas::end_tab_item() {
	_set_contexts();
	ImGui::EndTabItem();
}

// --- Tablas ---

bool ImGuiCanvas::begin_table(const String &p_id, int p_columns, int p_flags) {
	_set_contexts();
	return ImGui::BeginTable(p_id.utf8().get_data(), p_columns, (ImGuiTableFlags)p_flags);
}

void ImGuiCanvas::end_table() {
	_set_contexts();
	ImGui::EndTable();
}

void ImGuiCanvas::table_setup_column(const String &p_label) {
	_set_contexts();
	ImGui::TableSetupColumn(p_label.utf8().get_data());
}

void ImGuiCanvas::table_headers_row() {
	_set_contexts();
	ImGui::TableHeadersRow();
}

void ImGuiCanvas::table_next_row() {
	_set_contexts();
	ImGui::TableNextRow();
}

bool ImGuiCanvas::table_next_column() {
	_set_contexts();
	return ImGui::TableNextColumn();
}

// --- Menus / popups ---

bool ImGuiCanvas::begin_main_menu_bar() {
	_set_contexts();
	return ImGui::BeginMainMenuBar();
}

void ImGuiCanvas::end_main_menu_bar() {
	_set_contexts();
	ImGui::EndMainMenuBar();
}

bool ImGuiCanvas::begin_menu_bar() {
	_set_contexts();
	return ImGui::BeginMenuBar();
}

void ImGuiCanvas::end_menu_bar() {
	_set_contexts();
	ImGui::EndMenuBar();
}

bool ImGuiCanvas::begin_menu(const String &p_label) {
	_set_contexts();
	return ImGui::BeginMenu(p_label.utf8().get_data());
}

void ImGuiCanvas::end_menu() {
	_set_contexts();
	ImGui::EndMenu();
}

bool ImGuiCanvas::menu_item(const String &p_label, const String &p_shortcut, bool p_selected) {
	_set_contexts();
	return ImGui::MenuItem(p_label.utf8().get_data(), p_shortcut == "" ? nullptr : p_shortcut.utf8().get_data(), p_selected);
}

void ImGuiCanvas::open_popup(const String &p_id) {
	_set_contexts();
	ImGui::OpenPopup(p_id.utf8().get_data());
}

bool ImGuiCanvas::begin_popup(const String &p_id) {
	_set_contexts();
	return ImGui::BeginPopup(p_id.utf8().get_data());
}

bool ImGuiCanvas::begin_popup_modal(const String &p_title) {
	_set_contexts();
	return ImGui::BeginPopupModal(p_title.utf8().get_data(), nullptr);
}

void ImGuiCanvas::end_popup() {
	_set_contexts();
	ImGui::EndPopup();
}

void ImGuiCanvas::close_current_popup() {
	_set_contexts();
	ImGui::CloseCurrentPopup();
}

bool ImGuiCanvas::begin_popup_context_item(const String &p_id) {
	_set_contexts();
	return ImGui::BeginPopupContextItem(p_id == "" ? nullptr : p_id.utf8().get_data());
}

void ImGuiCanvas::set_tooltip(const String &p_text) {
	_set_contexts();
	ImGui::SetTooltip("%s", p_text.utf8().get_data());
}

void ImGuiCanvas::begin_tooltip() {
	_set_contexts();
	ImGui::BeginTooltip();
}

void ImGuiCanvas::end_tooltip() {
	_set_contexts();
	ImGui::EndTooltip();
}

// --- Estado del item ---

bool ImGuiCanvas::is_item_hovered() {
	_set_contexts();
	return ImGui::IsItemHovered();
}

bool ImGuiCanvas::is_item_active() {
	_set_contexts();
	return ImGui::IsItemActive();
}

bool ImGuiCanvas::is_item_clicked(int p_button) {
	_set_contexts();
	return ImGui::IsItemClicked(p_button);
}

bool ImGuiCanvas::is_item_edited() {
	_set_contexts();
	return ImGui::IsItemEdited();
}

bool ImGuiCanvas::is_mouse_clicked(int p_button) {
	_set_contexts();
	return ImGui::IsMouseClicked(p_button);
}

bool ImGuiCanvas::is_mouse_double_clicked() {
	_set_contexts();
	return ImGui::IsMouseDoubleClicked(0);
}

bool ImGuiCanvas::is_key_pressed(int p_key) {
	_set_contexts();
	if (frame_pressed_keys.has((uint32_t)p_key)) {
		return true;
	}
	ImGuiKey key = _godot_key_to_imgui((uint32_t)p_key);
	if (key == ImGuiKey_None) {
		return false;
	}
	return ImGui::IsKeyPressed(key);
}

Vector2 ImGuiCanvas::get_mouse_pos() {
	_set_contexts();
	ImVec2 v = ImGui::GetIO().MousePos;
	return Vector2(v.x, v.y);
}

// --- Graficos nativos ---

void ImGuiCanvas::plot_lines(const String &p_label, const PoolRealArray &p_values, const String &p_overlay, float p_min, float p_max, const Vector2 &p_size) {
	_set_contexts();
	PoolRealArray::Read r = p_values.read();
	ImGui::PlotLines(p_label.utf8().get_data(), r.ptr(), p_values.size(), 0, p_overlay == "" ? nullptr : p_overlay.utf8().get_data(), p_min, p_max, ImVec2(p_size.x, p_size.y));
}

void ImGuiCanvas::plot_histogram(const String &p_label, const PoolRealArray &p_values, const String &p_overlay, float p_min, float p_max, const Vector2 &p_size) {
	_set_contexts();
	PoolRealArray::Read r = p_values.read();
	ImGui::PlotHistogram(p_label.utf8().get_data(), r.ptr(), p_values.size(), 0, p_overlay == "" ? nullptr : p_overlay.utf8().get_data(), p_min, p_max, ImVec2(p_size.x, p_size.y));
}

static bool _check_vararg(const Variant **p_args, int p_index, Variant::Type p_type, Variant::CallError &r_error) {
	if (!Variant::can_convert(p_args[p_index]->get_type(), p_type)) {
		r_error.error = Variant::CallError::CALL_ERROR_INVALID_ARGUMENT;
		r_error.argument = p_index;
		r_error.expected = p_type;
		return false;
	}
	return true;
}

static bool _check_vararg_count(int p_argcount, int p_min, int p_max, Variant::CallError &r_error) {
	if (p_argcount < p_min) {
		r_error.error = Variant::CallError::CALL_ERROR_TOO_FEW_ARGUMENTS;
		r_error.argument = p_min;
		return false;
	}
	if (p_argcount > p_max) {
		r_error.error = Variant::CallError::CALL_ERROR_TOO_MANY_ARGUMENTS;
		r_error.argument = p_max;
		return false;
	}
	return true;
}

Variant ImGuiCanvas::_plot_lines_vararg(const Variant **p_args, int p_argcount, Variant::CallError &r_error) {
	r_error.error = Variant::CallError::CALL_OK;
	if (!_check_vararg_count(p_argcount, 2, 6, r_error) ||
			!_check_vararg(p_args, 0, Variant::STRING, r_error) ||
			!_check_vararg(p_args, 1, Variant::POOL_REAL_ARRAY, r_error)) {
		return Variant();
	}
	String label = *p_args[0];
	PoolRealArray values = *p_args[1];
	String overlay = p_argcount > 2 ? (String)*p_args[2] : String();
	float min_value = p_argcount > 3 ? (float)*p_args[3] : 3.402823466e+38F;
	float max_value = p_argcount > 4 ? (float)*p_args[4] : 3.402823466e+38F;
	Vector2 size = p_argcount > 5 ? (Vector2)*p_args[5] : Vector2();
	plot_lines(label, values, overlay, min_value, max_value, size);
	return Variant();
}

Variant ImGuiCanvas::_plot_histogram_vararg(const Variant **p_args, int p_argcount, Variant::CallError &r_error) {
	r_error.error = Variant::CallError::CALL_OK;
	if (!_check_vararg_count(p_argcount, 2, 6, r_error) ||
			!_check_vararg(p_args, 0, Variant::STRING, r_error) ||
			!_check_vararg(p_args, 1, Variant::POOL_REAL_ARRAY, r_error)) {
		return Variant();
	}
	String label = *p_args[0];
	PoolRealArray values = *p_args[1];
	String overlay = p_argcount > 2 ? (String)*p_args[2] : String();
	float min_value = p_argcount > 3 ? (float)*p_args[3] : 3.402823466e+38F;
	float max_value = p_argcount > 4 ? (float)*p_args[4] : 3.402823466e+38F;
	Vector2 size = p_argcount > 5 ? (Vector2)*p_args[5] : Vector2();
	plot_histogram(label, values, overlay, min_value, max_value, size);
	return Variant();
}

// --- Estilo ---

void ImGuiCanvas::style_colors_dark() {
	_set_contexts();
	ImGui::StyleColorsDark();
}

void ImGuiCanvas::style_colors_light() {
	_set_contexts();
	ImGui::StyleColorsLight();
}

void ImGuiCanvas::style_colors_classic() {
	_set_contexts();
	ImGui::StyleColorsClassic();
}

void ImGuiCanvas::push_style_color(int p_idx, const Color &p_color) {
	_set_contexts();
	ImGui::PushStyleColor(p_idx, _to_imvec4(p_color));
}

void ImGuiCanvas::pop_style_color(int p_n) {
	_set_contexts();
	ImGui::PopStyleColor(p_n);
}

void ImGuiCanvas::push_style_var_float(int p_idx, float p_v) {
	_set_contexts();
	ImGui::PushStyleVar(p_idx, p_v);
}

void ImGuiCanvas::push_style_var_vec2(int p_idx, const Vector2 &p_v) {
	_set_contexts();
	ImGui::PushStyleVar(p_idx, _to_imvec2(p_v));
}

void ImGuiCanvas::pop_style_var(int p_n) {
	_set_contexts();
	ImGui::PopStyleVar(p_n);
}

// --- Demos ---

#ifdef IMGUI_MODULE_DEMOS
void ImGuiCanvas::show_demo_window() {
	_set_contexts();
	ImGui::ShowDemoWindow();
}
#endif

void ImGuiCanvas::show_metrics_window() {
	_set_contexts();
	ImGui::ShowMetricsWindow();
}

#if defined(IMGUI_MODULE_DEMOS) && defined(IMGUI_MODULE_IMPLOT)
void ImGuiCanvas::implot_show_demo_window() {
	_set_contexts();
	ImPlot::ShowDemoWindow();
}
#endif

#if defined(IMGUI_MODULE_DEMOS) && defined(IMGUI_MODULE_IMPLOT3D)
void ImGuiCanvas::implot3d_show_demo_window() {
	_set_contexts();
	ImPlot3D::ShowDemoWindow();
}
#endif

// --- ImPlot ---

#ifdef IMGUI_MODULE_IMPLOT

bool ImGuiCanvas::implot_begin_plot(const String &p_title, const Vector2 &p_size, int p_flags) {
	_set_contexts();
	return ImPlot::BeginPlot(p_title.utf8().get_data(), ImVec2(p_size.x, p_size.y), (ImPlotFlags)p_flags);
}

void ImGuiCanvas::implot_end_plot() {
	_set_contexts();
	ImPlot::EndPlot();
}

void ImGuiCanvas::implot_setup_axes(const String &p_x_label, const String &p_y_label, int p_x_flags, int p_y_flags) {
	_set_contexts();
	ImPlot::SetupAxes(p_x_label.utf8().get_data(), p_y_label.utf8().get_data(), (ImPlotAxisFlags)p_x_flags, (ImPlotAxisFlags)p_y_flags);
}

void ImGuiCanvas::implot_setup_axis_limits(int p_axis, float p_min, float p_max, bool p_cond_always) {
	_set_contexts();
	ImPlot::SetupAxisLimits(p_axis, p_min, p_max, p_cond_always ? ImPlotCond_Always : ImPlotCond_Once);
}

void ImGuiCanvas::implot_plot_line(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys) {
	_set_contexts();
	PoolRealArray::Read xs = p_xs.read();
	PoolRealArray::Read ys = p_ys.read();
	int count = MIN(p_xs.size(), p_ys.size());
	ImPlot::PlotLine(p_label.utf8().get_data(), xs.ptr(), ys.ptr(), count);
}

void ImGuiCanvas::implot_plot_scatter(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys) {
	_set_contexts();
	PoolRealArray::Read xs = p_xs.read();
	PoolRealArray::Read ys = p_ys.read();
	int count = MIN(p_xs.size(), p_ys.size());
	ImPlot::PlotScatter(p_label.utf8().get_data(), xs.ptr(), ys.ptr(), count);
}

void ImGuiCanvas::implot_plot_bars(const String &p_label, const PoolRealArray &p_values, float p_bar_size) {
	_set_contexts();
	PoolRealArray::Read values = p_values.read();
	ImPlot::PlotBars(p_label.utf8().get_data(), values.ptr(), p_values.size(), p_bar_size);
}

void ImGuiCanvas::implot_plot_shaded(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys, float p_y_ref) {
	_set_contexts();
	PoolRealArray::Read xs = p_xs.read();
	PoolRealArray::Read ys = p_ys.read();
	int count = MIN(p_xs.size(), p_ys.size());
	ImPlot::PlotShaded(p_label.utf8().get_data(), xs.ptr(), ys.ptr(), count, p_y_ref);
}

void ImGuiCanvas::implot_plot_heatmap(const String &p_label, const PoolRealArray &p_values, int p_rows, int p_cols, float p_min, float p_max) {
	_set_contexts();
	PoolRealArray::Read values = p_values.read();
	ImPlot::PlotHeatmap(p_label.utf8().get_data(), values.ptr(), p_rows, p_cols, p_min, p_max);
}

Variant ImGuiCanvas::_implot_plot_heatmap_vararg(const Variant **p_args, int p_argcount, Variant::CallError &r_error) {
	r_error.error = Variant::CallError::CALL_OK;
	if (!_check_vararg_count(p_argcount, 4, 6, r_error) ||
			!_check_vararg(p_args, 0, Variant::STRING, r_error) ||
			!_check_vararg(p_args, 1, Variant::POOL_REAL_ARRAY, r_error)) {
		return Variant();
	}
	String label = *p_args[0];
	PoolRealArray values = *p_args[1];
	int rows = (int)*p_args[2];
	int cols = (int)*p_args[3];
	float min_value = p_argcount > 4 ? (float)*p_args[4] : 0.0f;
	float max_value = p_argcount > 5 ? (float)*p_args[5] : 0.0f;
	implot_plot_heatmap(label, values, rows, cols, min_value, max_value);
	return Variant();
}

#endif // IMGUI_MODULE_IMPLOT

// --- ImPlot3D ---

#ifdef IMGUI_MODULE_IMPLOT3D

bool ImGuiCanvas::implot3d_begin_plot(const String &p_title, const Vector2 &p_size, int p_flags) {
	_set_contexts();
	return ImPlot3D::BeginPlot(p_title.utf8().get_data(), ImVec2(p_size.x, p_size.y), (ImPlot3DFlags)p_flags);
}

void ImGuiCanvas::implot3d_end_plot() {
	_set_contexts();
	ImPlot3D::EndPlot();
}

void ImGuiCanvas::implot3d_setup_axes(const String &p_x, const String &p_y, const String &p_z) {
	_set_contexts();
	ImPlot3D::SetupAxes(p_x.utf8().get_data(), p_y.utf8().get_data(), p_z.utf8().get_data());
}

void ImGuiCanvas::implot3d_setup_axes_flags(const String &p_x, const String &p_y, const String &p_z, int p_flags) {
	_set_contexts();
	ImPlot3DAxisFlags flags = (ImPlot3DAxisFlags)p_flags;
	ImPlot3D::SetupAxes(p_x.utf8().get_data(), p_y.utf8().get_data(), p_z.utf8().get_data(), flags, flags, flags);
}

void ImGuiCanvas::implot3d_plot_line(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys, const PoolRealArray &p_zs) {
	_set_contexts();
	PoolRealArray::Read xs = p_xs.read();
	PoolRealArray::Read ys = p_ys.read();
	PoolRealArray::Read zs = p_zs.read();
	int count = MIN(MIN(p_xs.size(), p_ys.size()), p_zs.size());
	ImPlot3D::PlotLine(p_label.utf8().get_data(), xs.ptr(), ys.ptr(), zs.ptr(), count);
}

void ImGuiCanvas::implot3d_plot_scatter(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys, const PoolRealArray &p_zs) {
	_set_contexts();
	PoolRealArray::Read xs = p_xs.read();
	PoolRealArray::Read ys = p_ys.read();
	PoolRealArray::Read zs = p_zs.read();
	int count = MIN(MIN(p_xs.size(), p_ys.size()), p_zs.size());
	ImPlot3D::PlotScatter(p_label.utf8().get_data(), xs.ptr(), ys.ptr(), zs.ptr(), count);
}

void ImGuiCanvas::implot3d_plot_surface(const String &p_label, const PoolRealArray &p_xs, const PoolRealArray &p_ys, const PoolRealArray &p_zs, int p_x_count, int p_y_count) {
	_set_contexts();
	PoolRealArray::Read xs = p_xs.read();
	PoolRealArray::Read ys = p_ys.read();
	PoolRealArray::Read zs = p_zs.read();
	ImPlot3D::PlotSurface(p_label.utf8().get_data(), xs.ptr(), ys.ptr(), zs.ptr(), p_x_count, p_y_count);
}

Variant ImGuiCanvas::_implot3d_plot_surface_vararg(const Variant **p_args, int p_argcount, Variant::CallError &r_error) {
	r_error.error = Variant::CallError::CALL_OK;
	if (!_check_vararg_count(p_argcount, 6, 6, r_error) ||
			!_check_vararg(p_args, 0, Variant::STRING, r_error) ||
			!_check_vararg(p_args, 1, Variant::POOL_REAL_ARRAY, r_error) ||
			!_check_vararg(p_args, 2, Variant::POOL_REAL_ARRAY, r_error) ||
			!_check_vararg(p_args, 3, Variant::POOL_REAL_ARRAY, r_error)) {
		return Variant();
	}
	String label = *p_args[0];
	PoolRealArray xs = *p_args[1];
	PoolRealArray ys = *p_args[2];
	PoolRealArray zs = *p_args[3];
	int x_count = (int)*p_args[4];
	int y_count = (int)*p_args[5];
	implot3d_plot_surface(label, xs, ys, zs, x_count, y_count);
	return Variant();
}

#endif // IMGUI_MODULE_IMPLOT3D

// --- Menu radial ---

void ImGuiCanvas::open_pie_menu(const String &p_id) {
	_set_contexts();
	pie->open_menu(p_id);
}

int ImGuiCanvas::pie_menu(const String &p_id, const PoolStringArray &p_items) {
	_set_contexts();
	return pie->draw(p_id, p_items, scale);
}

void ImGuiCanvas::set_scale(float p_scale) {
	scale = p_scale;
}

float ImGuiCanvas::get_scale() const {
	return scale;
}

void ImGuiCanvas::set_frame_rounding(float p_rounding) {
	frame_rounding = p_rounding;
}

float ImGuiCanvas::get_frame_rounding() const {
	return frame_rounding;
}

void ImGuiCanvas::_input(const Ref<InputEvent> &p_event) {
	if (context == nullptr || p_event.is_null()) {
		return;
	}

	ImGui::SetCurrentContext(context);
	ImGuiIO &io = ImGui::GetIO();

	Ref<InputEventMouseMotion> mm = p_event;
	if (mm.is_valid()) {
		io.AddMousePosEvent(mm->get_position().x, mm->get_position().y);
	}

	Ref<InputEventMouseButton> mb = p_event;
	if (mb.is_valid()) {
		int button = mb->get_button_index();
		float factor = mb->get_factor() > 0.0f ? mb->get_factor() : 1.0f;
		if (button == BUTTON_WHEEL_UP) {
			io.AddMouseWheelEvent(0.0f, factor);
		} else if (button == BUTTON_WHEEL_DOWN) {
			io.AddMouseWheelEvent(0.0f, -factor);
		} else {
			int index = -1;
			if (button == BUTTON_LEFT) {
				index = 0;
			} else if (button == BUTTON_RIGHT) {
				index = 1;
			} else if (button == BUTTON_MIDDLE) {
				index = 2;
			}
			if (index >= 0) {
				io.AddMousePosEvent(mb->get_position().x, mb->get_position().y);
				io.AddMouseButtonEvent(index, mb->is_pressed());
			}
		}
	}

	Ref<InputEventScreenTouch> st = p_event;
	if (st.is_valid() && st->get_index() == 0) {
		io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
		io.AddMousePosEvent(st->get_position().x, st->get_position().y);
		io.AddMouseButtonEvent(0, st->is_pressed());
	}

	Ref<InputEventScreenDrag> sd = p_event;
	if (sd.is_valid() && sd->get_index() == 0) {
		io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
		io.AddMousePosEvent(sd->get_position().x, sd->get_position().y);
	}

	Ref<InputEventKey> k = p_event;
	if (k.is_valid()) {
		uint32_t key = k->get_scancode();
		if (k->is_pressed() && !k->is_echo()) {
			frame_pressed_keys.insert(key);
		}
		if (key == KEY_CONTROL) {
			io.AddKeyEvent(ImGuiMod_Ctrl, k->is_pressed());
		} else if (key == KEY_SHIFT) {
			io.AddKeyEvent(ImGuiMod_Shift, k->is_pressed());
		} else if (key == KEY_ALT) {
			io.AddKeyEvent(ImGuiMod_Alt, k->is_pressed());
		} else {
			ImGuiKey imgui_key = _godot_key_to_imgui(key);
			if (imgui_key != ImGuiKey_None) {
				io.AddKeyEvent(imgui_key, k->is_pressed());
			}
		}
		if (k->is_pressed() && k->get_unicode() >= 32) {
			io.AddInputCharacter(k->get_unicode());
		}
	}

	if (io.WantCaptureMouse || io.WantCaptureKeyboard) {
		get_tree()->set_input_as_handled();
	}
}

ImGuiCanvas::ImGuiCanvas() {
	IMGUI_CHECKVERSION();
	context = ImGui::CreateContext();
	ImGui::SetCurrentContext(context);

	implot_context = nullptr;
	implot3d_context = nullptr;
#ifdef IMGUI_MODULE_IMPLOT
	implot_context = ImPlot::CreateContext();
	ImPlot::SetCurrentContext(implot_context);
#endif
#ifdef IMGUI_MODULE_IMPLOT3D
	implot3d_context = ImPlot3D::CreateContext();
	ImPlot3D::SetCurrentContext(implot3d_context);
#endif
	ImGui::SetCurrentContext(context);

	ImGuiIO &io = ImGui::GetIO();
	io.SetClipboardTextFn = _imgui_set_clipboard;
	io.GetClipboardTextFn = _imgui_get_clipboard;
	io.IniFilename = nullptr; // cwd is not writable on Android

	want_text_input = false;
	scale = 1.0f;
	frame_rounding = 0.0f;
	window_open = true;
	pie = memnew(PieMenu);
}

ImGuiCanvas::~ImGuiCanvas() {
	for (int i = 0; i < frame_texture_rids.size(); i++) {
		memdelete(frame_texture_rids[i]);
	}
	frame_texture_rids.clear();
	frame_textures.clear();

	for (int i = 0; i < canvas_items.size(); i++) {
		VS::get_singleton()->free(canvas_items[i]);
	}
	canvas_items.clear();

	if (pie != nullptr) {
		memdelete(pie);
		pie = nullptr;
	}

	ImGui::SetCurrentContext(context);
#ifdef IMGUI_MODULE_IMPLOT
	if (implot_context != nullptr) {
		ImPlot::SetCurrentContext(implot_context);
		ImPlot::DestroyContext(implot_context);
		implot_context = nullptr;
	}
#endif
#ifdef IMGUI_MODULE_IMPLOT3D
	if (implot3d_context != nullptr) {
		ImPlot3D::SetCurrentContext(implot3d_context);
		ImPlot3D::DestroyContext(implot3d_context);
		implot3d_context = nullptr;
	}
#endif
	if (context != nullptr) {
		ImGui::SetCurrentContext(context);
		ImGui::DestroyContext(context);
		context = nullptr;
	}
}
