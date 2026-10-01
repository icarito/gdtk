# gvd en gdtk — diseño de integración (borrador)

## Principios
1. **El cable manda, no los programas.** El contrato es RTP/H.264/UDP (README). Un emisor GNOME (`gvd.py send`) y un receptor gdtk tienen que poder hablar entre sí, y viceversa.
2. **gdtk llama a gvd como proceso externo**, igual que `neighborhood.gd` llama a `nmcli`: sin librerías nuevas en el motor, sin secretos en argumentos. gvd no depende de gdtk.
3. **Sin autenticación nueva en el MVP:** el emisor lanza el receptor por **ssh** (mismas llaves y la misma filosofía que `remote.gd`, que ya asume ssh + token local).
4. **La dirección la decide quien está sentado:** el host potente (emisor) elige un vecino y le "extiende" la pantalla.

## Piezas
| Pieza | Dónde | Estado |
|---|---|---|
| `gvd send` (GNOME/Mutter) | gvd.py | PoC hecho |
| `gvd recv` | gvd.py | PoC hecho (`--sink wayland`) |
| **Receptor en gdtk** | gdtk **ya es compositor Wayland** (`modules/wayland`): `gvd recv --sink wayland` es un cliente Wayland más, gdtk lo compone como cualquier app. Coste de integración ≈ 0. | por probar |
| **Emisor en gdtk** (un gdtk que comparte pantalla) | wlroots: salida headless + captura (screencopy/dmabuf) o readback del Viewport de Godot (lento en GLES2/GM45, aceptable en el host fuerte) | diseño pendiente, fase tardía |
| **Descubrimiento** | hoy el Vecindario sólo ve `ip neigh` (sin capacidades). Camino barato: sondeo por ssh de `gvd caps --json`; más adelante anuncio mDNS `_gvd._udp` (si hay avahi) con TXT `schema=gvd.caps.v1 port=5600 codec=h264 size=1280x800 role=recv`. | `caps --json` hecho; mDNS pendiente |
| **UI en Vecindario** | acción "Extender pantalla aquí" sobre un nodo host (`neighborhood_ui.gd`); estado y botón detener | pendiente |

## Flujo "extender pantalla a un vecino" (host A potente → B)
1. En el Vecindario de A (gdtk) o en una CLI en GNOME, el usuario elige B.
2. A ejecuta `ssh B gvd recv --sink wayland` con el entorno de la sesión de B (si B es gdtk, vía su control remoto JSON-RPC para abrirlo como app, no con variables a mano).
3. A ejecuta `gvd send --host B --position <lado>`.
4. Detener: SIGTERM al `send` (cierra el monitor) y al `recv` por ssh.

Un solo comando para ambos lados: `gvd extend B [--position right]` que hace los pasos 2–4 (nuevo, no existe todavía). Vecindario puede arrancar con `recv`/`send` directos y usar `caps --json`; `extend` sólo vale si después reduce duplicación real.

## Compatibilidad con GNOME
- `gvd extend` funciona igual desde GNOME (hoy es el único emisor) y no necesita gdtk en ninguno de los lados: B sólo necesita GStreamer y una sesión gráfica.
- Un gdtk como receptor es un caso particular (cliente Wayland en su propio compositor).
- Un gdtk como emisor sería la fase tardía; hasta entonces un host gdtk puede *recibir* de uno GNOME pero no *compartir*.

## Contrato mínimo para Vecindario
- Encontrar gvd: preferir `$GVD_PATH`; si no existe, probar `~/Proyectos/gvd/gvd.py` y después `~/gvd/gvd.py`.
- Detectar capacidades: `python3 <gvd.py> caps --json`. El JSON usa `schema=gvd.caps.v1`, no abre streams y reporta defaults, puertos, sinks, encoders y dependencias locales.
- Recibir en gdtk: `python3 <gvd.py> recv --sink wayland --port 5600`. gvd aparece como un cliente Wayland más.
- Enviar desde GNOME: `python3 <gvd.py> send --host <vecino> --port 5600 --position right`.
- Puertos: video UDP 5600 por defecto; cursor separado UDP 5601 (`port+1`).
- Seguridad: sin cifrado/autenticación en RTP/UDP; exponer sólo a vecinos de confianza o a una red/VPN ya protegida.

## Decisiones abiertas
1. Descubrimiento: empezar con sondeo por ssh de `caps --json`; mDNS con avahi queda para cuando Vecindario necesite presencia sin SSH.
2. TCP vs UDP: UDP (Wi-Fi). Falta añadir recuperación de pérdidas: pedir keyframe al ver un hueco requiere un canal de retorno mínimo; hoy sólo hay keyframes periódicos.
3. Si el emisor gdtk existe, ¿tiles por daño en vez de H.264? (el decode en tengu no es el cuello; ver `SPEC-gvd-0a-results.md`).
4. Cifrado: ssh como túnel UDP no sirve; si hace falta, WireGuard por fuera.

## Fases propuestas (cada una un SPEC para Kilo)
1. **recv dentro de gdtk:** probar `gvd recv --sink wayland` como app en gdtk en tengu (fullscreen, foco, input no se envía). Salida: captura.
2. **`gvd extend`**: orquestación por ssh y limpieza si Vecindario empieza a duplicar demasiado los comandos directos.
3. **Vecindario:** acción en el nodo host que lanza `gvd extend`, estado en la UI. Descubrimiento según decisión 1.
4. **Robustez:** keyframe a pedido, recuperación tras pérdida de red, medición por Wi-Fi.
5. **Emisor gdtk** (tardío).
