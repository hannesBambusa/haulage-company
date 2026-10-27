"""Low-poly stylised trees: tree_cone_a (tiered pine), tree_cone_b (single faceted cone),
tree_round (deciduous). Two-tone flat-shaded foliage, seeded jitter.

Run: Blender -b --factory-startup --python tools/blender/props_trees.py
"""
import math
import os
import random
import sys

import bmesh

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402


def mats():
    return (C.mat("foliage", C.PAL["foliage"], rough=0.9),
            C.mat("foliage_dark", C.PAL["foliage_dark"], rough=0.9),
            C.mat("trunk", C.PAL["trunk"], rough=0.9))


def faceted_cone(mb, z0, height, rings, segs, band_mats, rnd, twist=0.0, jitter=0.08):
    """Cone made of stacked rings. rings = [(height_fraction, radius), ...] from the base up,
    apex added at z0+height. band_mats[i] colours the band above ring i."""
    bm = mb.bm
    ring_verts = []
    for k, (fz, r) in enumerate(rings):
        row = []
        off = twist * k
        for i in range(segs):
            a = 2 * math.pi * i / segs + off
            rr = r * (1 + rnd.uniform(-jitter, jitter))
            zz = z0 + fz * height + (rnd.uniform(-0.06, 0.06) if k else rnd.uniform(-0.1, 0.05))
            row.append(bm.verts.new((rr * math.cos(a), rr * math.sin(a), zz)))
        ring_verts.append(row)
    apex = bm.verts.new((rnd.uniform(-0.05, 0.05), rnd.uniform(-0.05, 0.05), z0 + height))
    cap = bm.faces.new(list(reversed(ring_verts[0])))
    cap.material_index = mb._mi(band_mats[0])
    for k in range(len(ring_verts) - 1):
        lo, hi = ring_verts[k], ring_verts[k + 1]
        mi = mb._mi(band_mats[k])
        for i in range(segs):
            j = (i + 1) % segs
            f = bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
            f.material_index = mi
    mi = mb._mi(band_mats[len(ring_verts) - 1])
    top = ring_verts[-1]
    for i in range(segs):
        f = bm.faces.new((top[i], top[(i + 1) % segs], apex))
        f.material_index = mi


def trunk(mb, h, r, m):
    mb.cyl(r, h, (0, 0, 0), m, segs=6, r2=r * 0.75, caps=False)


def tree_cone_a():
    C.reset()
    light, dark, bark = mats()
    rnd = random.Random(101)
    mb = C.MB()
    trunk(mb, 1.8, 0.16, bark)
    tiers = [(1.25, 2.7, 1.55), (2.6, 2.5, 1.2), (3.9, 2.5, 0.82)]
    for n, (z0, h, r) in enumerate(tiers):
        faceted_cone(mb, z0, h, [(0.0, r), (0.42, r * 0.58)], 9, [dark, dark, light], rnd,
                     twist=0.17 + n * 0.3)
    root = mb.to_object("TreeConeA")
    C.col_box("TreeConeATrunk", (0.4, 0.4, 2.5), (0, 0, 1.25), root)
    C.export(root, "tree_cone_a.glb")


def tree_cone_b():
    C.reset()
    light, dark, bark = mats()
    rnd = random.Random(202)
    mb = C.MB()
    trunk(mb, 1.4, 0.15, bark)
    faceted_cone(mb, 1.1, 4.8, [(0.0, 1.45), (0.3, 1.05), (0.62, 0.55)], 8,
                 [dark, dark, light, light], rnd, twist=0.2, jitter=0.1)
    root = mb.to_object("TreeConeB")
    C.col_box("TreeConeBTrunk", (0.4, 0.4, 2.5), (0, 0, 1.25), root)
    C.export(root, "tree_cone_b.glb")


def blob(mb, center, radius, light, dark, rnd, squash=0.85):
    bm = mb.bm
    before = set(bm.faces)
    res = bmesh.ops.create_icosphere(bm, subdivisions=1, radius=radius,
                                     matrix=Matrix.Translation(Vector(center)))
    for v in res["verts"]:
        d = v.co - Vector(center)
        d.z *= squash
        v.co = Vector(center) + d * (1 + rnd.uniform(-0.1, 0.1))
    li, di = mb._mi(light), mb._mi(dark)
    for f in bm.faces:
        if f not in before:
            f.normal_update()
            f.material_index = li if f.normal.z > 0.1 else di


def tree_round():
    C.reset()
    light, dark, bark = mats()
    rnd = random.Random(303)
    mb = C.MB()
    trunk(mb, 2.3, 0.17, bark)
    mb.box((0.09, 0.09, 0.9), (0.25, 0, 2.0), bark, rot=C.rot_y(35))
    blob(mb, (0, 0, 3.4), 1.55, light, dark, rnd)
    blob(mb, (0.75, 0.35, 3.0), 1.05, light, dark, rnd)
    blob(mb, (-0.6, -0.45, 3.05), 1.0, light, dark, rnd)
    blob(mb, (0.1, -0.2, 4.4), 0.9, light, dark, rnd)
    root = mb.to_object("TreeRound")
    C.col_box("TreeRoundTrunk", (0.4, 0.4, 2.5), (0, 0, 1.25), root)
    C.export(root, "tree_round.glb")


def main():
    tree_cone_a()
    tree_cone_b()
    tree_round()


if __name__ == "__main__":
    main()
