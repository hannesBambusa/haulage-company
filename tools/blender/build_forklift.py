"""Counterbalance forklift with seated driver. Writes forklift.glb.

Blender: +Y forward (forks side, -> -Z in Godot). Root "Forklift"; children Body,
Forks (origin at the fork heel, raise along Godot +Y), Driver, Wheel_FL/FR/RL/RR.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_vehicles as cv  # noqa: E402
from common_vehicles import mat  # noqa: E402

HW = 0.55
FRONT_AXLE, REAR_AXLE = 0.2, -0.72
FR, RR = 0.33, 0.27
MAST_Y = 0.66
HEEL = (0.0, MAST_Y + 0.13, 0.06)
SEAT = (0.0, -0.32, 1.0)


def body(root):
    y = mat("forklift_yellow")
    dk = mat("mast")
    ch = mat("chassis")
    b = cv.MeshBuilder("Body")
    # lower chassis between the wheels
    b.box((0.9, 1.6, 0.4), (0, -0.25, 0.38), y)
    # main body: hood/dash at front, low operator floor in the middle
    b.prism([(-0.45, 0.3), (0.58, 0.3), (0.58, 0.88), (0.5, 1.02), (0.3, 1.02),
             (0.26, 0.7), (-0.45, 0.7), (-0.45, 0.3)], -HW, HW, y, bevel=0.04)
    # counterweight: big rounded rear block
    b.prism([(-1.08, 0.24), (-0.4, 0.24), (-0.4, 1.12), (-0.62, 1.22), (-0.95, 1.2),
             (-1.08, 1.04), (-1.12, 0.6)], -HW, HW, y, bevel=0.05)
    b.box((2 * HW + 0.02, 0.14, 0.26), (0, -1.12, 0.36), ch, bevel=0.02)
    # wheel-arch shadows (dark side panels behind the wheels)
    for s in (-1, 1):
        for yy, r in ((FRONT_AXLE, FR), (REAR_AXLE, RR)):
            b.box((0.02, 2 * r + 0.1, r + 0.1), (s * (HW + 0.005), yy, 0.36 + r * 0.1), ch)
    # seat base + seat
    b.box((0.7, 0.45, 0.3), (0, SEAT[1], 0.85), y, bevel=0.03)
    b.box((0.5, 0.45, 0.1), (0, SEAT[1], SEAT[2] + 0.02), ch, bevel=0.03)
    b.box((0.52, 0.12, 0.62), (0, SEAT[1] - 0.26, SEAT[2] + 0.36), ch, bevel=0.03, rx=-10)
    # steering column + wheel
    b.box((0.06, 0.06, 0.4), (0, 0.32, 1.15), dk, rx=-25)
    b.cyl(0.15, 0.04, (0, 0.24, 1.36), ch, segs=10, rx=-35)
    # overhead guard: 4 posts, frame, solid roof plate
    gz = 2.12
    for s in (-1, 1):
        b.box((0.07, 0.07, gz - 0.95), (s * (HW - 0.05), -0.62, (gz + 0.95) / 2), ch)
        b.box((0.07, 0.07, gz - 0.95), (s * (HW - 0.05), 0.48, (gz + 0.95) / 2), ch, rx=-5)
        b.box((0.08, 1.24, 0.08), (s * (HW - 0.05), -0.07, gz), ch)
    b.box((2 * HW, 1.24, 0.05), (0, -0.07, gz + 0.04), ch, bevel=0.015)
    # mast: outer channels, inner channels, crossbars, lift + tilt cylinders
    mz0, mz1 = 0.08, 2.45
    for s in (-1, 1):
        b.box((0.1, 0.14, mz1 - mz0), (s * 0.36, MAST_Y, (mz0 + mz1) / 2), ch, bevel=0.015)
        b.box((0.07, 0.1, mz1 - mz0 - 0.1), (s * 0.26, MAST_Y + 0.03, (mz0 + mz1) / 2 - 0.03), dk)
        b.cyl(0.04, 0.32, (s * 0.36, MAST_Y - 0.2, 0.75), dk, axis="Y", segs=8)
    for z in (mz1 - 0.05, 1.3, 0.2):
        b.box((0.82, 0.1, 0.1), (0, MAST_Y, z), ch)
    b.cyl(0.045, 1.9, (0, MAST_Y - 0.05, 1.15), mat("chrome"), segs=8)
    # lights
    for s in (-1, 1):
        b.box((0.1, 0.05, 0.08), (s * (HW - 0.05), 0.53, 1.95), mat("headlight"))
        b.box((0.1, 0.04, 0.1), (s * 0.4, -1.13, 1.0), mat("taillight"))
    b.finish(root)


def forks(root):
    ch = mat("chassis")
    b = cv.MeshBuilder("Forks")
    hx, hy, hz = HEEL
    # carriage plate + load backrest
    b.box((0.92, 0.06, 0.45), (0, hy - 0.04, hz + 0.3), ch, bevel=0.01)
    for x in (-0.42, -0.14, 0.14, 0.42):
        b.box((0.04, 0.04, 0.6), (x, hy - 0.04, hz + 0.82), ch)
    b.box((0.88, 0.04, 0.05), (0, hy - 0.04, hz + 1.12), ch)
    # two L forks: shank + blade
    for s in (-1, 1):
        b.box((0.11, 0.05, 0.5), (s * 0.25, hy + 0.02, hz + 0.25), ch)
        b.prism([(hy, hz - 0.02), (hy + 1.06, hz - 0.02), (hy + 1.1, hz + 0.0),
                 (hy + 1.06, hz + 0.03), (hy, hz + 0.03)],
                s * 0.25 - 0.055, s * 0.25 + 0.055, ch)
    b.finish(root, origin=HEEL)


def driver(root):
    vest, strip, skin = mat("vest"), mat("vest_strip"), mat("skin")
    pants, shirt, hat, boots = mat("trousers"), mat("shirt"), mat("hat_yellow"), mat("boots")
    sx, sy, sz = SEAT
    b = cv.MeshBuilder("Driver")
    b.box((0.36, 0.44, 0.15), (0, sy + 0.15, sz + 0.12), pants, bevel=0.02)   # thighs
    for s in (-1, 1):
        b.box((0.13, 0.13, 0.36), (s * 0.1, sy + 0.38, sz - 0.1), pants)    # shins
        b.box((0.13, 0.24, 0.08), (s * 0.1, sy + 0.44, 0.74), boots)        # boots
    b.box((0.4, 0.25, 0.5), (0, sy - 0.04, sz + 0.42), vest, bevel=0.03)      # torso
    for z in (sz + 0.3, sz + 0.44):
        b.box((0.41, 0.26, 0.04), (0, sy - 0.04, z), strip)
    for s in (-1, 1):
        b.box((0.11, 0.11, 0.3), (s * 0.25, sy - 0.0, sz + 0.5), shirt, rx=25)      # upper arm
        b.box((0.09, 0.3, 0.09), (s * 0.24, sy + 0.2, sz + 0.34), shirt, rx=-15)    # forearm
        b.box((0.08, 0.08, 0.08), (s * 0.2, sy + 0.37, sz + 0.37), skin)          # hand
    b.box((0.1, 0.1, 0.06), (0, sy - 0.04, sz + 0.7), skin)                         # neck
    b.box((0.22, 0.24, 0.25), (0, sy - 0.03, sz + 0.84), skin, bevel=0.03)          # head
    b.cyl(0.15, 0.13, (0, sy - 0.03, sz + 0.98), hat, segs=10, r_top=0.1, bevel=0.02)
    b.cyl(0.17, 0.025, (0, sy - 0.01, sz + 0.925), hat, segs=10)
    b.finish(root, origin=SEAT)


def build():
    cv.reset_scene()
    root = cv.make_root("Forklift")
    body(root)
    forks(root)
    driver(root)
    for name, x, y, r, w, s in (("Wheel_FL", -0.45, FRONT_AXLE, FR, 0.24, -1),
                                ("Wheel_FR", 0.45, FRONT_AXLE, FR, 0.24, 1),
                                ("Wheel_RL", -0.45, REAR_AXLE, RR, 0.2, -1),
                                ("Wheel_RR", 0.45, REAR_AXLE, RR, 0.2, 1)):
        cv.wheel(name, r, w, (x, y, r), s, root, segs=12, rim_frac=0.55, rim_mat="chassis")
    cv.center_on_ground(root)
    cv.export_glb("forklift.glb")


build()
