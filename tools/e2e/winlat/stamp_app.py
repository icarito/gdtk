#!/usr/bin/env python3
"""Ventana de prueba para medir latencia de «ventana compartida» (banco e2e).

Corre en el EMISOR, dentro del compositor de gdtk (GDK_BACKEND=wayland). Dibuja el reloj de
pared en ms como 8 celdas de preámbulo + 36 bits (blanco/negro, 12 px por celda, robusto al
H.264) cada ~4 ms, y registra en /tmp/winlat-keys.log la hora de llegada de cada tecla
(`time_ns`), para medir la latencia de entrada. Hora de pared: los equipos deben tener NTP."""
import time
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib

PREAMBLE = [1, 0, 1, 0, 1, 1, 0, 0]
CELL, NBITS = 12, 36
W, H = CELL * (len(PREAMBLE) + NBITS), 48


def bits_now():
    ms = time.time_ns() // 1_000_000
    return PREAMBLE + [(ms >> (NBITS - 1 - i)) & 1 for i in range(NBITS)]


def on_draw(_w, cr):
    cr.set_source_rgb(0.5, 0.5, 0.5)
    cr.paint()
    for i, b in enumerate(bits_now()):
        cr.set_source_rgb(b, b, b)
        cr.rectangle(i * CELL, 0, CELL, 24)
        cr.fill()
    # eco de entrada: la celda se invierte con cada tecla
    cr.set_source_rgb(*(0, 0.8, 0) if state["keys"] % 2 else (0.6, 0, 0))
    cr.rectangle(0, 24, W, 24)
    cr.fill()


state = {"keys": 0}


def on_key(_w, ev):
    state["keys"] += 1
    with open("/tmp/winlat-keys.log", "a") as f:
        f.write("%d %d\n" % (ev.keyval, time.time_ns()))
    return True


win = Gtk.Window(title="winlat")
win.set_default_size(W, H)
win.set_resizable(False)
area = Gtk.DrawingArea()
area.set_size_request(W, H)
win.add(area)
area.connect("draw", on_draw)
win.connect("key-press-event", on_key)
win.connect("destroy", Gtk.main_quit)
win.show_all()
GLib.timeout_add(4, lambda: (area.queue_draw(), True)[1])
Gtk.main()
