#ifndef WAYLAND_COMPOSITOR_H
#define WAYLAND_COMPOSITOR_H

#include "core/dictionary.h"
#include "core/os/input_event.h"
#include "core/pool_vector.h"
#include "core/set.h"
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
	// Ids de layer surfaces (comparten espacio con los toplevels pero no son ventanas).
	Set<int> layer_ids;
	// Ids dibujados (get_layers) en el frame en curso y en el último terminado (end_frame).
	Set<int> drawn_collect;
	Set<int> drawn;
	bool throttle;
	// InputCapture activo: corta en la frontera nativa cualquier reenvío hacia
	// clientes locales, aunque el evento se filtre por otra ruta de Godot.
	bool local_pointer_enabled;
	// Drag and drop nativo: textura (shm) del icono que dibuja el cliente y si hay
	// un drag en curso. El shell dibuja la textura pegada al puntero y usa
	// is_dragging() para seguir reenviando el boton aunque el cursor salga de toda
	// ventana (soltar sobre el escritorio cancela el drop).
	// Último cursor por surface emitido (para no repetir señales idénticas).
	PoolVector<uint8_t> cursor_image_data;
	Vector2 cursor_image_hotspot;
	Ref<ImageTexture> drag_icon_texture;
	// Hotspot del icono: top-left = puntero + drag_icon_offset (offset del
	// wl_surface del icono).
	Vector2 drag_icon_offset;
	bool drag_active;
	// Procesos lanzados que todavía no se recogieron con waitpid.
	Vector<int> children;

	static void _cb_added(void *p_ud, int p_id);
	static void _cb_removed(void *p_ud, int p_id);
	static void _cb_frame(void *p_ud, int p_id, uint64_t p_key, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride);
	static void _cb_dmabuf(void *p_ud, int p_id, uint64_t p_key, int p_w, int p_h);
	static void _cb_title(void *p_ud, int p_id, const char *p_title);
	static void _cb_layer(void *p_ud, int p_id, int p_state);
	static void _cb_activate(void *p_ud, int p_id);
	static void _cb_minimize(void *p_ud, int p_id);
	static void _cb_maximize(void *p_ud, int p_id, int p_maximized);
	static void _cb_fullscreen(void *p_ud, int p_id, int p_fullscreen);
	static void _cb_move(void *p_ud, int p_id);
	static void _cb_resize(void *p_ud, int p_id, int p_edges);
	static void _cb_damage(void *p_ud, int p_id);
	static void _cb_pointer_lock(void *p_ud, int p_id, int p_locked);
	static void _cb_cursor_hidden(void *p_ud, int p_hidden);
	static void _cb_cursor_shape(void *p_ud, int p_shape);
	static void _cb_cursor_image(void *p_ud, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride, int p_hx, int p_hy);
	static void _cb_drag_icon(void *p_ud, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride, int p_dx, int p_dy);
	static void _cb_drag_state(void *p_ud, int p_active);
	static void _cb_output_added(void *p_ud, int p_id);
	static void _cb_output_changed(void *p_ud, int p_id);
	static void _cb_output_removed(void *p_ud, int p_id);
	static void _cb_toplevel_output_changed(void *p_ud, int p_toplevel_id, int p_output_id);

	void _on_added(int p_id);
	void _on_removed(int p_id);
	void _on_frame(int p_id, uint64_t p_key, const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride);
	void _on_dmabuf(int p_id, uint64_t p_key, int p_w, int p_h);
	void _on_cursor_image(const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride, int p_hx, int p_hy);
	void _on_drag_icon(const unsigned char *p_data, int p_w, int p_h, uint32_t p_format, int p_stride, int p_dx, int p_dy);
	void _on_title(int p_id, const char *p_title);
	void _count_commit(int p_id);
	void _reap_children();

	Map<int, Toplevel>::Element *_toplevel_entry(int p_id);
	Dictionary _output_dict(int p_output_id) const;

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
	int get_parent_id(int p_id) const;
	String get_app_id(int p_id) const;
	bool is_csd(int p_id) const;
	Array get_ids() const;
	Array get_layer_surfaces();
	Ref<Texture> get_drag_icon_texture() const;
	Vector2 get_drag_icon_offset() const;
	bool is_dragging() const;
	void end_frame();
	// Sólo manda los frame callbacks a lo visible, sin tocar la visibilidad. Se usa en el
	// camino "present-only" del shell: re-muestra el contenido de una ventana sin rearmar
	// la UI ImGui (SPEC-rendimiento-compositor P1).
	void send_frame_callbacks();

	void set_size(int p_id, const Vector2 &p_size);
	void set_maximized(int p_id, bool p_maximized);
	void set_popup_bounds(int p_id, const Rect2 &p_box);
	void set_fullscreen(int p_id, bool p_fullscreen);
	void close(int p_id);
	// Saca el toplevel a la fuerza (ventana residual sin cliente que responda).
	void forget(int p_id);
	void focus(int p_id, bool p_raise = true);
	void pointer_motion(int p_id, const Vector2 &p_pos);
	void pointer_motion_relative(const Vector2 &p_delta);
	void pointer_clear_focus();
	bool pointer_has_focus() const;
	bool client_cursor_hidden() const;
	void set_local_pointer_enabled(bool p_enabled);
	void pointer_button(int p_button_index, bool p_pressed);
	void pointer_axis(double p_dy);
	void pointer_axis_h(double p_dx);
void pointer_axis_finger(Vector2 p_delta);
void pointer_axis_stop();
	void gesture_pinch(int p_phase, int p_fingers, double p_scale);
	void key(const Ref<InputEventKey> &p_event);
	bool set_keymap(const String &p_layout, const String &p_variant);

	void set_default_size(const Vector2 &p_size);
	Vector2 get_default_size() const;
	int get_commit_count() const;
	int get_dmabuf_commits() const;
	int get_shm_commits() const;
	String get_dmabuf_state() const;
	String get_explicit_sync_state() const;
	// Scanout directo (P4 opcion B): diagnostico del puente dmabuf hacia sway.
	bool scanout_enabled() const;
	String scanout_state() const;
	// Pausa/reanuda el scanout directo. El shell lo pausa mientras dibuja un overlay
	// encima (Frame/OSD/expose/vecindario) para que no quede tapado por el host.
	void set_scanout_suspended(bool p_suspended);
	bool scanout_suspended() const;
	// Motivo (diagnóstico) del último rechazo/aceptación del scanout.
	String scanout_reason() const;

	// Salidas logicas (multi-output). `p_rect` es la geometria logica global;
	// `p_scale` se redondea a un entero >=1. add_output devuelve el id (>0) o 0.
	int add_output(const String &p_name, const Rect2 &p_rect, float p_scale = 1.0, bool p_primary = false);
	bool configure_output(int p_output_id, const Rect2 &p_rect, float p_scale = 1.0);
	void remove_output(int p_output_id);
	void set_toplevel_output(int p_toplevel_id, int p_output_id);
	int get_toplevel_output(int p_toplevel_id) const;
	Array get_outputs() const;
	Dictionary get_output(int p_output_id) const;
	int get_primary_output_id() const;
};

#endif // WAYLAND_COMPOSITOR_H
