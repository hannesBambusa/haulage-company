"""Pallet, loaded pallets (a/b/c), single carton, empty pallet stack.

Run: Blender -b --factory-startup --python tools/blender/props_pallets.py
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402
from mathutils import Matrix  # noqa: E402

PALLET_H = 0.144
BOARD = 0.022
BLOCK = 0.078


def build_pallet(mb, wood=None):
    """EUR pallet 1.2 (X) x 0.8 (Y) x 0.144, base at z=0. Hidden faces dropped."""
    w = wood or C.mat("pallet_wood", C.PAL["pallet_wood"], rough=0.85)
    wd = C.mat("pallet_wood_dark", C.PAL["pallet_wood"], rough=0.9, factor=0.82)
    # bottom boards along X at the three block rows
    for y, bw in ((-0.35, 0.1), (0.0, 0.145), (0.35, 0.1)):
        mb.box((1.2, bw, BOARD), (0, y, BOARD / 2), w, drop=("-Z",))
    # blocks
    z = BOARD + BLOCK / 2
    for x in (-0.5275, 0.0, 0.5275):
        for y, bw in ((-0.35, 0.1), (0.0, 0.145), (0.35, 0.1)):
            mb.box((0.145, bw, BLOCK), (x, y, z), wd, drop=("-Z", "+Z"))
    # cross boards along Y
    z = BOARD + BLOCK + BOARD / 2
    for x in (-0.5275, 0.0, 0.5275):
        mb.box((0.145, 0.8, BOARD), (x, 0, z), w, drop=("-Z",))
    # top deck: 5 boards along X
    z = BOARD * 2 + BLOCK + BOARD / 2
    for y, bw in ((-0.3275, 0.145), (-0.17, 0.1), (0.0, 0.145), (0.17, 0.1), (0.3275, 0.145)):
        mb.box((1.2, bw, BOARD), (0, y, z), w, drop=("-Z",))


def build_carton(mb, size, loc, m, tape, yaw=0.0):
    """Carton with a tape strip over the top along its X axis. loc = bottom centre."""
    sx, sy, sz = size
    base = mb.xform
    mb.xform = base @ Matrix.Translation(loc) @ C.rot_z(yaw)
    mb.box(size, (0, 0, sz / 2), m, bevel=min(0.015, sz * 0.05), drop=("-Z",))
    t = 0.004  # offset off the surface
    tw = min(0.07, sy * 0.25) / 2
    drop_len = min(0.12, sz * 0.4)
    hx, top = sx / 2 + t, sz + t
    verts = [(-hx, -tw, top), (hx, -tw, top), (hx, tw, top), (-hx, tw, top),
             (hx, -tw, top - drop_len), (hx, tw, top - drop_len),
             (-hx, -tw, top - drop_len), (-hx, tw, top - drop_len)]
    faces = [(0, 1, 2, 3), (1, 4, 5, 2), (0, 3, 7, 6)]
    mb.poly(verts, faces, tape)
    mb.xform = base


def build_load(mb, variant):
    """Boxes on a pallet. variant in 'a' (neat 2-layer), 'b' (tall 3-layer), 'c' (messy)."""
    cards = C.cardboard_mats()
    tape = C.mat("tape", C.PAL["tape"], rough=0.6)
    rnd = random.Random({"a": 11, "b": 22, "c": 33}[variant])
    z0 = PALLET_H
    g = 0.012  # gap between cartons
    if variant == "a":
        sx, sy, sz = 0.4 - g, 0.4 - g, 0.38
        for layer in range(2):
            for ix in range(3):
                for iy in range(2):
                    loc = (-0.4 + ix * 0.4, -0.2 + iy * 0.4, z0 + layer * sz)
                    build_carton(mb, (sx, sy, sz), loc, rnd.choice(cards), tape)
    elif variant == "b":
        sx, sy, sz = 0.6 - g, 0.4 - g, 0.34
        for layer in range(3):
            # alternate the tape direction per layer for a stacked look
            for ix in range(2):
                for iy in range(2):
                    loc = (-0.3 + ix * 0.6, -0.2 + iy * 0.4, z0 + layer * sz)
                    build_carton(mb, (sx, sy, sz), loc, rnd.choice(cards), tape)
    else:
        sz = 0.36
        spots = [(-0.4, -0.2), (0.0, -0.2), (0.4, -0.2), (-0.4, 0.2), (0.0, 0.2), (0.4, 0.2)]
        layer0 = spots[:]
        layer0.pop(2)  # front right missing
        for x, y in layer0:
            loc = (x + rnd.uniform(-0.015, 0.015), y + rnd.uniform(-0.015, 0.015), z0)
            build_carton(mb, (0.38, 0.38, sz), loc, rnd.choice(cards), tape,
                         yaw=rnd.uniform(-0.06, 0.06))
        for x, y in [(-0.4, 0.2), (0.0, 0.2), (-0.4, -0.2)]:
            loc = (x + rnd.uniform(-0.03, 0.03), y + rnd.uniform(-0.03, 0.03), z0 + sz)
            build_carton(mb, (0.36, 0.36, 0.3), loc, rnd.choice(cards), tape,
                         yaw=rnd.uniform(-0.15, 0.15))
        # a small loose carton on top
        build_carton(mb, (0.3, 0.24, 0.2), (-0.38, 0.18, z0 + sz + 0.3), rnd.choice(cards),
                     tape, yaw=0.35)


LOAD_H = {"a": PALLET_H + 2 * 0.38, "b": PALLET_H + 3 * 0.34, "c": PALLET_H + 0.36 + 0.5}


def build_pallet_boxes(mb, variant):
    build_pallet(mb)
    build_load(mb, variant)


def main():
    # 1. pallet
    C.reset()
    mb = C.MB()
    build_pallet(mb)
    root = mb.to_object("Pallet")
    C.export(root, "pallet.glb")

    # 2. loaded pallets
    for v in "abc":
        C.reset()
        mb = C.MB()
        build_pallet_boxes(mb, v)
        root = mb.to_object(f"PalletBoxes{v.upper()}")
        h = LOAD_H[v]
        C.col_box(f"PalletBoxes{v.upper()}-col", (1.2, 0.8, h), (0, 0, h / 2), root)
        C.export(root, f"pallet_boxes_{v}.glb")

    # 3. single carton 0.5 x 0.4 x 0.4
    C.reset()
    mb = C.MB()
    build_carton(mb, (0.5, 0.4, 0.4), (0, 0, 0), C.cardboard_mats()[0],
                 C.mat("tape", C.PAL["tape"], rough=0.6))
    root = mb.to_object("BoxSingle")
    C.export(root, "box_single.glb")

    # 4. stack of 5 empty pallets, slightly jittered
    C.reset()
    mb = C.MB()
    rnd = random.Random(5)
    for i in range(5):
        mb.xform = Matrix.Translation((rnd.uniform(-0.02, 0.02), rnd.uniform(-0.02, 0.02),
                                       i * PALLET_H)) @ C.rot_z(rnd.uniform(-1.5, 1.5))
        build_pallet(mb)
    mb.xform = Matrix.Identity(4)
    root = mb.to_object("PalletStackEmpty")
    C.export(root, "pallet_stack_empty.glb")


if __name__ == "__main__":
    main()
