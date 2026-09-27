#ifndef PIE_MENU_H
#define PIE_MENU_H

#include "core/ustring.h"
#include "core/variant.h"

// Menu radial propio dibujado con ImDrawList. Sin dependencias de ImGui en el
// header: la implementacion (pie_menu.cpp) hace el trabajo con el contexto vivo.
class PieMenu {
	bool open;
	String id;
	float center_x;
	float center_y;
	int hovered;

public:
	PieMenu();

	void open_menu(const String &p_id);
	bool is_open() const;
	int draw(const String &p_id, const PoolStringArray &p_items, float p_scale);
};

#endif // PIE_MENU_H
