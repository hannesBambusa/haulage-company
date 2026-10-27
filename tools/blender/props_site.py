"""Yard props: bollard, jersey_barrier, fence_segment, fence_post, lamp_post, cctv_pole.

Run: Blender -b --factory-startup --python tools/blender/props_site.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402

FENCE_H = 2.0
FENCE_L = 3.0


def bollard():
    C.reset()
    y = C.mat("bollard_yellow", C.PAL["bollard_yellow"], rough=0.45)
    k = C.mat("bollard_black", C.PAL["dock_black"], rough=0.6)
    mb = C.MB()
    r, segs = 0.15, 12
    bands = [(0.0, 0.62, y), (0.62, 0.72, k), (0.72, 0.8, y), (0.8, 0.9, k)]
    for z0, z1, m in bands:
        mb.cyl(r, z1 - z0, (0, 0, z0), m, segs=segs, caps=False)
    mb.cyl(r, 0.05, (0, 0, 0.9), y, segs=segs, r2=r * 0.92, caps=False)
    mb.cyl(r * 0.92, 0.05, (0, 0, 0.95), y, segs=segs, r2=r * 0.6, caps=True)
    root = mb.to_object("Bollard")
    C.col_box("Bollard-col", (0.3, 0.3, 1.0), (0, 0, 0.5), root)
    C.export(root, "bollard.glb")


def jersey_barrier():
    C.reset()
    c = C.mat("concrete", C.PAL["concrete"], rough=0.95)
    cd = C.mat("concrete_dark", C.PAL["concrete"], rough=0.95, factor=0.86)
    mb = C.MB()
    prof = [(-0.3, 0.0), (0.3, 0.0), (0.3, 0.075), (0.19, 0.26), (0.08, 0.81),
            (-0.08, 0.81), (-0.19, 0.26), (-0.3, 0.075)]
    mb.prism_x(prof, 1.96, (0, 0, 0), c)
    # end joint caps (slightly darker, give the classic segmented read when lined up)
    for s in (-1, 1):
        mb.prism_x([(y * 0.97, z) for y, z in prof[:2]] + [(y * 0.97, z * 0.99) for y, z in prof[2:]],
                   0.02, (s * 0.99, 0, 0), cd)
    # fork-lift slots at the bottom of each face
    for s in (-1, 1):
        mb.box((0.35, 0.01, 0.06), (s * 0.55, -0.3 - 0.004, 0.035), cd, drop=("-Z", "+Y"))
        mb.box((0.35, 0.01, 0.06), (s * 0.55, 0.3 + 0.004, 0.035), cd, drop=("-Z", "-Y"))
    root = mb.to_object("JerseyBarrier")
    C.col_box("JerseyBarrier-col", (2.0, 0.6, 0.81), (0, 0, 0.405), root)
    C.export(root, "jersey_barrier.glb")


def _post(mb, x, post, cap, foot=None, h=FENCE_H + 0.05):
    if foot is not None:
        mb.cyl(0.09, 0.08, (x, 0, 0), foot, segs=8)
    mb.cyl(0.035, h, (x, 0, 0), post, segs=8, caps=False)
    mb.cyl(0.045, 0.04, (x, 0, h), cap, segs=8)


def _fence_mats():
    return (C.mat("fence_post", C.PAL["fence_post"], rough=0.5, metal=0.5),
            C.mat("fence_mesh", C.PAL["fence_mesh"], rough=0.6, metal=0.3, alpha=0.35),
            C.mat("fence_post_dark", C.PAL["fence_post"], rough=0.5, metal=0.5, factor=0.75),
            C.mat("concrete", C.PAL["concrete"], rough=0.95))


def fence_segment():
    """3 m chain-link span, posts at both ends (x=+-1.5), barbed outrigger leaning to -Y."""
    C.reset()
    post, mesh, dark, conc = _fence_mats()
    mb = C.MB()
    hl = FENCE_L / 2
    for x in (-hl, hl):
        _post(mb, x, post, dark)
        # outrigger arm leaning outward (-Y)
        mb.box((0.03, 0.4, 0.03), (x, -0.16, FENCE_H + 0.15), post, rot=C.rot_x(-40))
    for z in (0.06, FENCE_H - 0.02):
        mb.cyl(0.022, FENCE_L, (-hl, 0, z), post, segs=6, caps=False, rot=C.rot_y(90))
    for (yy, zz) in ((-0.15, FENCE_H + 0.13), (-0.3, FENCE_H + 0.26)):
        mb.box((FENCE_L, 0.012, 0.012), (0, yy, zz), dark)
    mb.poly([(-hl, 0, 0.06), (hl, 0, 0.06), (hl, 0, FENCE_H - 0.02), (-hl, 0, FENCE_H - 0.02)],
            [(0, 1, 2, 3)], mesh)
    # sparse diagonal chain-link lattice: single double-sided quads just off the mesh plane
    wire = C.mat("fence_wire", C.PAL["fence_post"], rough=0.5, metal=0.4, factor=0.8, double_sided=True)
    z0, z1 = 0.06, FENCE_H - 0.02
    hgt = z1 - z0
    step = 0.3
    ww = 0.006
    k = -hgt
    while k < FENCE_L:
        for sgn in (1, -1):
            # line x = k + t*hgt (sgn=1) or mirrored, clipped to the panel
            xa, xb = -hl + k, -hl + k + hgt
            ta, tb = 0.0, 1.0
            if xa < -hl:
                ta = (-hl - xa) / hgt
            if xb > hl:
                tb = (hl - xa) / hgt
            if tb > ta:
                pa = (xa + ta * hgt, z0 + ta * hgt)
                pb = (xa + tb * hgt, z0 + tb * hgt)
                if sgn < 0:
                    pa, pb = (-pa[0], pa[1]), (-pb[0], pb[1])
                mb.poly([(pa[0] - ww, -0.004, pa[1]), (pa[0] + ww, -0.004, pa[1]),
                         (pb[0] + ww, -0.004, pb[1]), (pb[0] - ww, -0.004, pb[1])],
                        [(0, 1, 2, 3)], wire)
        k += step
    root = mb.to_object("FenceSegment")
    C.col_box("FenceSegment-col", (FENCE_L, 0.08, FENCE_H), (0, 0, FENCE_H / 2), root)
    C.export(root, "fence_segment.glb")


def fence_post():
    C.reset()
    post, _mesh, dark, conc = _fence_mats()
    mb = C.MB()
    _post(mb, 0, post, dark, foot=conc)
    mb.box((0.03, 0.4, 0.03), (0, -0.16, FENCE_H + 0.15), post, rot=C.rot_x(-40))
    root = mb.to_object("FencePost")
    C.col_box("FencePost-col", (0.1, 0.1, FENCE_H), (0, 0, FENCE_H / 2), root)
    C.export(root, "fence_post.glb")


def lamp_post():
    """7 m street light, arm reaching to -Y. Child empty 'LightAnchor' under the head."""
    C.reset()
    pole = C.mat("lamp_post", C.PAL["lamp_post"], rough=0.5, metal=0.5)
    conc = C.mat("concrete", C.PAL["concrete"], rough=0.95)
    head = C.mat("lamp_head", C.PAL["dock_black"], rough=0.6, metal=0.3)
    glow = C.mat("lamp_light", "#FFF1C8", rough=0.3, emission="#FFE7B0", strength=6.0)
    mb = C.MB()
    mb.box((0.4, 0.4, 0.3), (0, 0, 0.15), conc, bevel=0.02, drop=("-Z",))
    mb.cyl(0.1, 6.7, (0, 0, 0.3), pole, segs=8, r2=0.065, caps=False)
    mb.cyl(0.07, 0.06, (0, 0, 7.0), pole, segs=8)
    arm_l = 1.5
    mb.box((0.07, arm_l, 0.07), (0, -arm_l / 2 + 0.03, 6.92), pole, rot=C.rot_x(-4))
    hy = -arm_l + 0.05
    mb.box((0.32, 0.65, 0.12), (0, hy, 6.86), head, bevel=0.02)
    mb.box((0.26, 0.55, 0.01), (0, hy, 6.795), glow, drop=("+Z",))
    root = mb.to_object("LampPost")
    C.empty("LightAnchor", (0, hy, 6.7), root)
    C.col_box("LampPost-col", (0.4, 0.4, 7.0), (0, 0, 3.5), root)
    C.export(root, "lamp_post.glb")


def cctv_pole():
    C.reset()
    pole = C.mat("lamp_post", C.PAL["lamp_post"], rough=0.5, metal=0.5)
    conc = C.mat("concrete", C.PAL["concrete"], rough=0.95)
    housing = C.mat("cctv_housing", "#E4E6E8", rough=0.4, metal=0.1)
    lens = C.mat("cctv_lens", "#15171A", rough=0.2, metal=0.2)
    mb = C.MB()
    h = 4.5
    mb.box((0.3, 0.3, 0.25), (0, 0, 0.125), conc, bevel=0.02, drop=("-Z",))
    mb.cyl(0.07, h - 0.25, (0, 0, 0.25), pole, segs=8, r2=0.055, caps=False)
    mb.cyl(0.06, 0.05, (0, 0, h), pole, segs=8)
    mb.box((0.05, 0.45, 0.05), (0, -0.2, h - 0.12), pole)
    rot = C.rot_x(-20)
    mb.box((0.16, 0.42, 0.16), (0, -0.48, h - 0.25), housing, bevel=0.02, rot=rot)
    mb.box((0.2, 0.46, 0.02), (0, -0.48 + 0.0, h - 0.15), housing, rot=rot)
    mb.box((0.1, 0.02, 0.1), (0, -0.7, h - 0.33), lens, rot=rot)
    # junction box on the pole
    mb.box((0.18, 0.1, 0.25), (0, 0.11, 1.4), housing, bevel=0.01)
    root = mb.to_object("CctvPole")
    C.col_box("CctvPole-col", (0.3, 0.3, h), (0, 0, h / 2), root)
    C.export(root, "cctv_pole.glb")


def main():
    bollard()
    jersey_barrier()
    fence_segment()
    fence_post()
    lamp_post()
    cctv_pole()


if __name__ == "__main__":
    main()
