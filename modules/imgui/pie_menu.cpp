#include "pie_menu.h"

#include "imgui_internal.h"

#include <math.h>

#define PIE_INNER_RADIUS 30.0f
#define PIE_OUTER_RADIUS 110.0f

PieMenu::PieMenu() {
	open = false;
	center_x = 0.0f;
	center_y = 0.0f;
	hovered = -1;
}

void PieMenu::open_menu(const String &p_id) {
	ImGuiIO &io = ImGui::GetIO();
	open = true;
	id = p_id;
	center_x = io.MousePos.x;
	center_y = io.MousePos.y;
	hovered = -1;
}

bool PieMenu::is_open() const {
	return open;
}

static ImVec2 _pie_polar(float p_cx, float p_cy, float p_angle, float p_radius) {
	return ImVec2(p_cx + cosf(p_angle) * p_radius, p_cy + sinf(p_angle) * p_radius);
}

int PieMenu::draw(const String &p_id, const PoolStringArray &p_items, float p_scale) {
	if (!open || p_id != id) {
		return -1;
	}

	int count = p_items.size();
	if (count <= 0) {
		open = false;
		return -1;
	}

	ImGuiIO &io = ImGui::GetIO();
	float inner = PIE_INNER_RADIUS * p_scale;
	float outer = PIE_OUTER_RADIUS * p_scale;

	float dx = io.MousePos.x - center_x;
	float dy = io.MousePos.y - center_y;
	float dist = sqrtf(dx * dx + dy * dy);

	hovered = -1;
	if (dist >= inner && dist <= outer) {
		float rel = atan2f(dy, dx) - (-IM_PI * 0.5f);
		float step = (IM_PI * 2.0f) / (float)count;
		while (rel < 0.0f) {
			rel += IM_PI * 2.0f;
		}
		while (rel >= IM_PI * 2.0f) {
			rel -= IM_PI * 2.0f;
		}
		hovered = (int)(rel / step);
		if (hovered >= count) {
			hovered = count - 1;
		}
	}

	ImDrawList *draw_list = ImGui::GetForegroundDrawList();
	ImU32 col_idle = ImGui::GetColorU32(ImGuiCol_Button);
	ImU32 col_hover = ImGui::GetColorU32(ImGuiCol_ButtonHovered);
	ImU32 col_text = ImGui::GetColorU32(ImGuiCol_Text);

	float step = (IM_PI * 2.0f) / (float)count;
	for (int i = 0; i < count; i++) {
		float a0 = -IM_PI * 0.5f + step * (float)i;
		float a1 = a0 + step;
		ImU32 col = (i == hovered) ? col_hover : col_idle;

		draw_list->PathLineTo(_pie_polar(center_x, center_y, a0, outer));
		draw_list->PathArcTo(ImVec2(center_x, center_y), outer, a0, a1, 32);
		draw_list->PathLineTo(_pie_polar(center_x, center_y, a1, inner));
		draw_list->PathArcTo(ImVec2(center_x, center_y), inner, a1, a0, 32);
		draw_list->PathFillConvex(col);

		float mid_angle = (a0 + a1) * 0.5f;
		ImVec2 mid = _pie_polar(center_x, center_y, mid_angle, (inner + outer) * 0.5f);
		CharString label = p_items[i].utf8();
		ImVec2 text_size = ImGui::CalcTextSize(label.get_data());
		draw_list->AddText(ImVec2(mid.x - text_size.x * 0.5f, mid.y - text_size.y * 0.5f), col_text, label.get_data());
	}

	draw_list->AddCircle(ImVec2(center_x, center_y), outer, col_text, 64, 1.0f);

	if (ImGui::IsMouseReleased(0) || ImGui::IsMouseReleased(1)) {
		int result = hovered;
		open = false;
		hovered = -1;
		return result;
	}

	return -1;
}
