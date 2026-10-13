#ifndef SCREENCAST_H
#define SCREENCAST_H

// Fuente PipeWire del multiview (SPEC-multiview-portal §9 N1): backend nativo de
// org.freedesktop.impl.portal.ScreenCast. Exporta un nodo Video/Source
// (media.category=Capture, role=Screen) al que el shell empuja RGBA8; el frontend
// del portal entrega el fd via OpenPipeWireRemote y el cliente (OBS/Meet/Zoom)
// conecta y recibe los frames. Corre en su propio hilo (pw_thread_loop): el hilo de
// render nunca espera; screencast_push_rgba solo copia y dispara el proceso.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct screencast screencast;

// Crea el bucle PipeWire + stream de salida (RGBA8, width x height @ fps) y lo
// arranca. Devuelve NULL si no hay PipeWire o falla la conexión.
screencast *screencast_new(int width, int height, int fps);
// Id del nodo PipeWire (0 si aún no está) y serial a reportar al portal.
uint32_t screencast_node_id(screencast *sc);
uint64_t screencast_serial(screencast *sc);
// Copia el frame RGBA8 mas nuevo (se descarta si no coincide con la config) y pide
// al bucle que lo empuje. Nunca bloquea de forma significativa; acepta NULL.
void screencast_push_rgba(screencast *sc, const uint8_t *data, int w, int h, int stride);
// 1 mientras el stream está conectado.
int screencast_active(screencast *sc);
// Detiene el bucle y libera stream/context/core/loop. Acepta NULL.
void screencast_free(screencast *sc);

#ifdef __cplusplus
}
#endif

#endif // SCREENCAST_H
