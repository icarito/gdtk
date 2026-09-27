#!/usr/bin/env python3
"""Inyeccion real de teclado por XTest (sin xdotool), para la verificacion del
Paso 9 (SPEC-keys.md).

Usa ctypes sobre libX11.so.6 y libXtst.so.6: abre el display, traduce keysyms a
keycodes con el keymap que tenga el servidor (es con setxkbmap), averigua que
modificadores hacen falta con XkbLookupKeySym/XGetModifierMapping y emite las
pulsaciones/releases con XTestFakeKeyEvent.

Cada argumento es un token:
  text:STRING          teclea STRING caracter a caracter (deduce Shift/AltGr)
  Mod+Mod+Keysym       acorde: mantiene los modificadores, pulsa Keysym y suelta
                       (p.ej. Return, Control_L+c, ISO_Level3_Shift+at)

Ejemplos:
  xtest_keys.py --display :97 text:'echo a-b_c@d' Return
  xtest_keys.py --display :97 text:'sleep 30' Return Control_L+c
  xtest_keys.py --display :97 text:hola-mundo
"""

import argparse
import ctypes
import ctypes.util
import sys
import time

KeySym = ctypes.c_ulong
KeyCode = ctypes.c_ubyte

# Orden de preferencia de combinaciones de modificadores al resolver un caracter
# (Shift=1, Mod1=8, Mod3=32, Mod4=64, Mod5=128; Mod5 suele ser AltGr con xkb).
SHIFT = 1 << 0
MOD1 = 1 << 3
MOD3 = 1 << 5
MOD4 = 1 << 6
MOD5 = 1 << 7
CANDIDATE_MASKS = [0, SHIFT, MOD5, SHIFT | MOD5, MOD3, SHIFT | MOD3, MOD1, SHIFT | MOD1]


class XModifierKeymap(ctypes.Structure):
    _fields_ = [("max_keypermod", ctypes.c_int),
                ("modifiermap", ctypes.POINTER(KeyCode))]


class XTestError(Exception):
    pass


class XTest:
    def __init__(self, display_name):
        x11_name = ctypes.util.find_library("X11") or "libX11.so.6"
        xtst_name = ctypes.util.find_library("Xtst") or "libXtst.so.6"
        self.x11 = ctypes.CDLL(x11_name)
        self.xtst = ctypes.CDLL(xtst_name)

        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.x11.XStringToKeysym.argtypes = [ctypes.c_char_p]
        self.x11.XStringToKeysym.restype = KeySym
        self.x11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, KeySym]
        self.x11.XKeysymToKeycode.restype = KeyCode
        self.x11.XkbLookupKeySym.argtypes = [
            ctypes.c_void_p, KeyCode, ctypes.c_uint,
            ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(KeySym)
        ]
        self.x11.XkbLookupKeySym.restype = ctypes.c_int
        self.x11.XGetModifierMapping.argtypes = [ctypes.c_void_p]
        self.x11.XGetModifierMapping.restype = ctypes.POINTER(XModifierKeymap)
        self.x11.XFreeModifiermap.argtypes = [ctypes.POINTER(XModifierKeymap)]
        self.x11.XFlush.argtypes = [ctypes.c_void_p]

        self.xtst.XTestFakeKeyEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong
        ]
        self.xtst.XTestFakeKeyEvent.restype = ctypes.c_int

        name = display_name.encode("utf-8") if display_name else None
        self.display = self.x11.XOpenDisplay(name)
        if not self.display:
            raise XTestError("no se pudo abrir el display %r" % (display_name,))
        self.modifier_codes = self._read_modifier_map()

    def close(self):
        if self.display:
            self.x11.XFlush(self.display)
            self.x11.XCloseDisplay(self.display)
            self.display = None

    def _read_modifier_map(self):
        """mask (1<<i) -> keycode del primer modificador de ese indice."""
        result = {}
        modmap = self.x11.XGetModifierMapping(self.display)
        if not modmap:
            return result
        try:
            mm = modmap.contents
            per = mm.max_keypermod
            for i in range(8):
                for j in range(per):
                    code = mm.modifiermap[i * per + j]
                    if code:
                        result[1 << i] = code
                        break
        finally:
            self.x11.XFreeModifiermap(modmap)
        return result

    def keysym(self, name):
        sym = self.x11.XStringToKeysym(name.encode("utf-8"))
        if sym == 0:
            raise XTestError("keysym desconocido: %s" % name)
        return sym

    def keycode(self, sym):
        code = self.x11.XKeysymToKeycode(self.display, sym)
        if code == 0:
            raise XTestError("sin keycode para el keysym 0x%x" % sym)
        return code

    def resolve_mask(self, code, sym):
        """Combinacion de modificadores (mascara X) que hace que `code` de `sym`."""
        for mask in CANDIDATE_MASKS:
            rtrn = ctypes.c_uint(0)
            found = KeySym(0)
            if self.x11.XkbLookupKeySym(self.display, code, mask,
                                        ctypes.byref(rtrn), ctypes.byref(found)):
                if found.value == sym:
                    return mask
        raise XTestError("no se pudo resolver U+%04X (keysym 0x%x)" % (sym, sym))

    def _key(self, code, pressed, delay):
        if self.xtst.XTestFakeKeyEvent(self.display, code, 1 if pressed else 0, 0) == 0:
            raise XTestError("XTestFakeKeyEvent fallo (keycode %d)" % code)
        self.x11.XFlush(self.display)
        time.sleep(delay)

    def chord_codes(self, mod_codes, main_code, delay):
        for code in mod_codes:
            self._key(code, True, delay)
        self._key(main_code, True, delay)
        self._key(main_code, False, delay)
        for code in reversed(mod_codes):
            self._key(code, False, delay)

    def chord(self, mod_names, main_sym, delay):
        mod_codes = [self.keycode(self.keysym(name)) for name in mod_names]
        self.chord_codes(mod_codes, self.keycode(main_sym), delay)

    def _mask_codes(self, mask):
        codes = [self.modifier_codes[1 << i] for i in range(8)
                 if (mask & (1 << i)) and (1 << i) in self.modifier_codes]
        if len(codes) != bin(mask).count("1"):
            raise XTestError("modificador 0x%x sin keycode en el servidor" % mask)
        return codes

    def type_char(self, ch, delay):
        cp = ord(ch)
        if not (0x20 <= cp <= 0x7E or 0xA0 <= cp <= 0xFF):
            raise XTestError("caracter no tipable por XTest (U+%04X)" % cp)
        code = self.keycode(cp)
        mask = self.resolve_mask(code, cp)
        self.chord_codes(self._mask_codes(mask), code, delay)


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tokens", nargs="+",
                        help="text:STRING o Mod+Mod+Keysym")
    parser.add_argument("--display", default=None,
                        help="display X (default: $DISPLAY)")
    parser.add_argument("--delay", type=float, default=0.03,
                        help="pausa entre eventos, en segundos (default 0.03)")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    xt = XTest(args.display)
    try:
        for token in args.tokens:
            if token.startswith("text:"):
                for ch in token[len("text:"):]:
                    xt.type_char(ch, args.delay)
            else:
                parts = token.split("+")
                main_sym = xt.keysym(parts[-1])
                xt.chord(parts[:-1], main_sym, args.delay)
    except XTestError as exc:
        print("xtest_keys: %s" % exc, file=sys.stderr)
        return 1
    finally:
        xt.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
