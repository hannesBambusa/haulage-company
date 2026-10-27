"""Pallet rack bay (empty and loaded). Bay 2.8 W (X) x 1.1 D (Y) x 4.5 H.

Run: Blender -b --factory-startup --python tools/blender/props_rack.py
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402
import props_pallets as P  # noqa: E402
from mathutils import Matrix  # noqa: E402

W, D, H = 2.8, 1.1, 4.5
POST_X, POST_Y = 0.09, 0.09
LEVELS = (0.2, 1.6, 3.0)  # beam top heights
BEAM_Z, BEAM_D = 0.14, 0.07
DECK_T = 0.025


def build_rack(mb):
    blue = C.mat("rack_blue", C.PAL["rack_blue"], rough=0.45, metal=0.3)
    orange = C.mat("rack_orange", C.PAL["rack_orange"], rough=0.45, metal=0.2)
    plate = C.mat("rack_plate", C.PAL["dock_black"], rough=0.6, metal=0.4)
    deck = C.mat("rack_deck", C.PAL["pallet_wood"], rough=0.85, factor=1.05)
    px = W / 2 - POST_X / 2
    py = D / 2 - POST_Y / 2
    for sx in (-1, 1):
        x = sx * px
        for sy in (-1, 1):
            mb.box((POST_X, POST_Y, H), (x, sy * py, H / 2), blue, bevel=0.008, drop=("-Z",))
            mb.box((0.1, 0.13, 0.012), (x, sy * py, 0.006), plate, drop=("-Z",))
        # frame bracing in the YZ plane between front and back posts
        inner = py - POST_Y / 2
        zs = [0.15, 1.1, 2.05, 3.0, 3.95, 4.4]
        for z in (zs[0], zs[-1]):
            mb.box((0.03, 2 * inner, 0.04), (x, 0, z), blue)
        for i in range(len(zs) - 1):
            za, zb = zs[i], zs[i + 1]
            ya, yb = (-inner, inner) if i % 2 == 0 else (inner, -inner)
            dy, dz = yb - ya, zb - za
            ln = math.hypot(dy, dz)
            ang = math.degrees(math.atan2(dz, dy))
            mb.box((0.025, ln, 0.035), (x, (ya + yb) / 2, (za + zb) / 2), blue, rot=C.rot_x(ang))
    span = W - 2 * POST_X
    by = D / 2 - 0.04
    for lz in LEVELS:
        for sy in (-1, 1):
            mb.box((span, BEAM_D, BEAM_Z), (0, sy * by, lz - BEAM_Z / 2), orange, bevel=0.008)
        n = 9
        pw = 0.13
        step = (span - pw) / (n - 1)
        for i in range(n):
            mb.box((pw, D - 0.06, DECK_T), (-span / 2 + pw / 2 + i * step, 0, lz + DECK_T / 2),
                   deck, drop=("-Z",))


def make(loaded):
    C.reset()
    mb = C.MB()
    build_rack(mb)
    if loaded:
        cards = C.cardboard_mats()
        tape = C.mat("tape", C.PAL["tape"], rough=0.6)
        # per pallet: list of (size, local x, local y, z offset above pallet top)
        layouts = [
            [((0.55, 0.7, 0.5), -0.3, 0, 0), ((0.55, 0.7, 0.5), 0.3, 0, 0)],
            [((0.5, 0.7, 0.45), -0.36, 0, 0), ((0.5, 0.7, 0.45), 0.0, 0, 0),
             ((0.5, 0.7, 0.45), 0.36, 0, 0)],
            [((0.55, 0.7, 0.45), -0.3, 0, 0), ((0.55, 0.7, 0.45), 0.3, 0, 0),
             ((0.5, 0.6, 0.35), 0.3, 0, 0.47)],
        ]
        k = 0
        for li, lz in enumerate(LEVELS):
            for pi, x in enumerate((-0.68, 0.68)):
                mb.xform = Matrix.Translation((x, 0, lz + DECK_T)) @ C.rot_z(90)
                P.build_pallet(mb)
                for size, cx, cy, dz in layouts[(li + pi) % 3]:
                    P.build_carton(mb, size, (cx, cy, P.PALLET_H + dz), cards[k % len(cards)], tape)
                    k += 1
        mb.xform = Matrix.Identity(4)
    name = "RackLoaded" if loaded else "Rack"
    root = mb.to_object(name)
    C.col_box(name + "-col", (W, D, H), (0, 0, H / 2), root)
    C.export(root, "rack_bay_loaded.glb" if loaded else "rack_bay.glb")


def main():
    make(False)
    make(True)


if __name__ == "__main__":
    main()
