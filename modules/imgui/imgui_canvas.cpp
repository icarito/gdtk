#include "imgui_canvas.h"

#include "core/class_db.h"
#include "core/image.h"
#include "core/os/input_event.h"
#include "core/os/keyboard.h"
#include "core/os/os.h"
#include "servers/visual_server.h"

#include "imgui.h"

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
		default:
			break;
	}
	if (p_key >= KEY_A && p_key <= KEY_Z) {
		return (ImGuiKey)(ImGuiKey_A + (p_key - KEY_A));
	}
	return ImGuiKey_None;
}

void ImGuiCanvas::_bind_methods() {
	ClassDB::bind_method(D_METHOD("begin", "title"), &ImGuiCanvas::begin);
	ClassDB::bind_method(D_METHOD("end"), &ImGuiCanvas::end);
	ClassDB::bind_method(D_METHOD("set_next_window_pos", "pos"), &ImGuiCanvas::set_next_window_pos);
	ClassDB::bind_method(D_METHOD("set_next_window_size", "size"), &ImGuiCanvas::set_next_window_size);
	ClassDB::bind_method(D_METHOD("text", "s"), &ImGuiCanvas::text);
	ClassDB::bind_method(D_METHOD("text_wrapped", "s"), &ImGuiCanvas::text_wrapped);
	ClassDB::bind_method(D_METHOD("button", "label"), &ImGuiCanvas::button);
	ClassDB::bind_method(D_METHOD("same_line"), &ImGuiCanvas::same_line);
	ClassDB::bind_method(D_METHOD("separator"), &ImGuiCanvas::separator);
	ClassDB::bind_method(D_METHOD("checkbox", "label", "value"), &ImGuiCanvas::checkbox);
	ClassDB::bind_method(D_METHOD("input_text", "label", "value"), &ImGuiCanvas::input_text);
	ClassDB::bind_method(D_METHOD("input_text_enter", "label", "value"), &ImGuiCanvas::input_text_enter);
	ClassDB::bind_method(D_METHOD("begin_child", "id", "size"), &ImGuiCanvas::begin_child);
	ClassDB::bind_method(D_METHOD("end_child"), &ImGuiCanvas::end_child);
	ClassDB::bind_method(D_METHOD("set_scroll_here_y", "ratio"), &ImGuiCanvas::set_scroll_here_y);

	ClassDB::bind_method(D_METHOD("set_imgui_scale", "scale"), &ImGuiCanvas::set_scale);
	ClassDB::bind_method(D_METHOD("get_imgui_scale"), &ImGuiCanvas::get_scale);
	ADD_PROPERTY(PropertyInfo(Variant::REAL, "imgui_scale"), "set_imgui_scale", "get_imgui_scale");

	ClassDB::bind_method(D_METHOD("_input", "event"), &ImGuiCanvas::_input);

	ADD_SIGNAL(MethodInfo("imgui_frame"));
}

RID ImGuiCanvas::_get_canvas_item(int p_index) {
	while (canvas_items.size() <= p_index) {
		canvas_items.push_back(VS::get_singleton()->canvas_item_create());
	}
	return canvas_items[p_index];
}

void ImGuiCanvas::_process_frame(float p_delta) {
	ImGui::SetCurrentContext(context);
	ImGuiIO &io = ImGui::GetIO();

	Size2 size = get_viewport_rect().size;
	io.DisplaySize = ImVec2(size.x, size.y);
	io.DeltaTime = p_delta > 0.0001f ? p_delta : 0.0001f;

	ImGui::NewFrame();
	emit_signal("imgui_frame");
	ImGui::Render();

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
			ImGui::SetCurrentContext(context);
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
			ImGui::GetStyle().ScaleAllSizes(scale);

			set_process(true);
			set_process_input(true);
		} break;

		case NOTIFICATION_PROCESS: {
			_process_frame(get_process_delta_time());
		} break;
	}
}

bool ImGuiCanvas::begin(const String &p_title) {
	ImGui::SetCurrentContext(context);
	return ImGui::Begin(p_title.utf8().get_data());
}
void ImGuiCanvas::end() {
	ImGui::SetCurrentContext(context);
	ImGui::End();
}

void ImGuiCanvas::set_next_window_pos(const Vector2 &p_pos) {
	ImGui::SetCurrentContext(context);
	ImGui::SetNextWindowPos(ImVec2(p_pos.x, p_pos.y), ImGuiCond_FirstUseEver);
}

void ImGuiCanvas::set_next_window_size(const Vector2 &p_size) {
	ImGui::SetCurrentContext(context);
	ImGui::SetNextWindowSize(ImVec2(p_size.x, p_size.y), ImGuiCond_FirstUseEver);
}

void ImGuiCanvas::text(const String &p_text) {
	ImGui::SetCurrentContext(context);
	ImGui::TextUnformatted(p_text.utf8().get_data());
}

void ImGuiCanvas::text_wrapped(const String &p_text) {
	ImGui::SetCurrentContext(context);
	ImGui::PushTextWrapPos(0.0f);
	ImGui::TextUnformatted(p_text.utf8().get_data());
	ImGui::PopTextWrapPos();
}

bool ImGuiCanvas::button(const String &p_label) {
	ImGui::SetCurrentContext(context);
	return ImGui::Button(p_label.utf8().get_data());
}

void ImGuiCanvas::same_line() {
	ImGui::SetCurrentContext(context);
	ImGui::SameLine();
}

void ImGuiCanvas::separator() {
	ImGui::SetCurrentContext(context);
	ImGui::Separator();
}

bool ImGuiCanvas::checkbox(const String &p_label, bool p_value) {
	ImGui::SetCurrentContext(context);
	bool value = p_value;
	ImGui::Checkbox(p_label.utf8().get_data(), &value);
	return value;
}

String ImGuiCanvas::input_text(const String &p_label, const String &p_value) {
	ImGui::SetCurrentContext(context);
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

Dictionary ImGuiCanvas::input_text_enter(const String &p_label, const String &p_value) {
	ImGui::SetCurrentContext(context);
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

bool ImGuiCanvas::begin_child(const String &p_id, const Vector2 &p_size) {
	ImGui::SetCurrentContext(context);
	return ImGui::BeginChild(p_id.utf8().get_data(), ImVec2(p_size.x, p_size.y));
}

void ImGuiCanvas::end_child() {
	ImGui::SetCurrentContext(context);
	ImGui::EndChild();
}

void ImGuiCanvas::set_scroll_here_y(float p_ratio) {
	ImGui::SetCurrentContext(context);
	ImGui::SetScrollHereY(p_ratio);
}

void ImGuiCanvas::set_scale(float p_scale) {
	scale = p_scale;
}

float ImGuiCanvas::get_scale() const {
	return scale;
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

	ImGuiIO &io = ImGui::GetIO();
	io.SetClipboardTextFn = _imgui_set_clipboard;
	io.GetClipboardTextFn = _imgui_get_clipboard;
	io.IniFilename = nullptr; // cwd is not writable on Android

	want_text_input = false;
	scale = 1.0f;
}

ImGuiCanvas::~ImGuiCanvas() {
	for (int i = 0; i < canvas_items.size(); i++) {
		VS::get_singleton()->free(canvas_items[i]);
	}
	canvas_items.clear();

	if (context != nullptr) {
		ImGui::SetCurrentContext(context);
		ImGui::DestroyContext(context);
		context = nullptr;
	}
}
