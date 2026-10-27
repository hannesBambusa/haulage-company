"""Manual pallet jack, handle tilted back. Writes pallet_jack.glb.

Blender: forks point +Y (-> -Z in Godot), handle at the rear. Root "PalletJack",
single child mesh "Body".
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_vehicles as cv  # noqa: E402
from common_vehicles import mat, trs  # noqa: E402

FORK_LEN = 1.08
TILT = 9.0   # handle lean back from vertical, degrees


def build():
    cv.reset_scene()
    org, dk, ty = mat("jack_orange"), mat("chassis"), mat("tyre")
    fork = mat("jack_fork")
    root = cv.make_root("PalletJack")
    b = cv.MeshBuilder("Body")
    # forks with tapered tips + load rollers
    for s in (-1, 1):
        x0, x1 = s * 0.27 - 0.08, s * 0.27 + 0.08
        b.prism([(0.05, 0.03), (FORK_LEN, 0.03), (FORK_LEN + 0.06, 0.05),
                 (FORK_LEN + 0.03, 0.085), (0.05, 0.085)], x0, x1, fork, bevel=0.01)
        b.cyl(0.03, 0.12, (s * 0.27, FORK_LEN - 0.08, 0.03), ty, axis="X", segs=8)
    # cross member joining the forks
    b.box((0.7, 0.16, 0.14), (0, 0.0, 0.1), fork, bevel=0.015)
    # pump housing: tall trapezoid cover, wider at the bottom
    b.prism([(-0.16, 0.1), (0.2, 0.1), (0.04, 0.62), (-0.12, 0.62)], -0.19, 0.19, org,
            bevel=0.02)
    # steer wheels under the housing
    for s in (-1, 1):
        b.cyl(0.09, 0.07, (s * 0.13, -0.15, 0.09), ty, axis="X", segs=10)
        b.cyl(0.045, 0.08, (s * 0.13, -0.15, 0.09), mat("rim"), axis="X", segs=6)
    # handle: shaft + loop grip, built upright then tilted about the pivot
    piv = trs((0, -0.1, 0.55), rx=TILT)
    b.box((0.05, 0.05, 0.75), (0, 0, 0.375), dk, xform=piv)
    b.box((0.06, 0.06, 0.12), (0, 0, 0.06), dk, xform=piv)
    for s in (-1, 1):
        b.box((0.04, 0.04, 0.2), (s * 0.12, 0, 0.88), dk, xform=piv, rz=0)
        b.box((0.1, 0.04, 0.04), (s * 0.07, 0, 0.78), dk, xform=piv)
    b.box((0.28, 0.05, 0.05), (0, 0, 0.98), dk, bevel=0.01, xform=piv)
    b.box((0.04, 0.03, 0.12), (0.06, 0.03, 0.82), org, xform=piv)  # release lever
    b.finish(root)
    cv.center_on_ground(root)
    cv.export_glb("pallet_jack.glb")


build()
