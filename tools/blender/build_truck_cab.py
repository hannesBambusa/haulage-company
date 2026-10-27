"""European cab-over 6x2 tractor. Writes truck_cab_red.glb and truck_cab_blue.glb.

Blender: +Y forward (-> -Z in Godot), Z up, origin at ground centre.
Children of root "TruckCab": Body (all static parts), Wheel_* (origin at axle
centre, spin around local X), Empty "FifthWheel" (coupling point for Kingpin).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_vehicles as cv  # noqa: E402
from common_vehicles import mat  # noqa: E402

HW = 1.25           # half width
CAB_REAR = 0.85
CAB_FRONT = 3.02
CAB_BOTTOM = 1.1
CAB_TOP = 3.62
FRONT_AXLE = 1.85
REAR_AXLES = (-0.95, -2.25)
WHEEL_R = 0.52
FIFTH_WHEEL = (0.0, -1.6, 1.16)


def front_y(z):
    """Front face leans back slightly above the grille."""
    if z <= 2.05:
        return CAB_FRONT
    return CAB_FRONT - 0.12 * (z - 2.05) / (CAB_TOP - 2.05)


def build(color):
    cv.reset_scene()
    paint = mat("truck_" + color)
    dark = mat("chassis")
    glass = mat("glass")
    chrome = mat("chrome")
    root = cv.make_root("TruckCab")
    b = cv.MeshBuilder("Body")

    # --- cab shell -------------------------------------------------------
    prof = [(CAB_REAR, CAB_BOTTOM), (CAB_FRONT, CAB_BOTTOM), (CAB_FRONT, 2.05),
            (front_y(CAB_TOP), CAB_TOP), (CAB_REAR, CAB_TOP)]
    b.prism(prof, -HW, HW, paint, bevel=0.07)
    # raised roof panel (low-roof sleeper step)
    b.prism([(CAB_REAR + 0.05, CAB_TOP - 0.05), (2.55, CAB_TOP - 0.05), (2.35, 3.88),
             (CAB_REAR + 0.05, 3.9)], -HW + 0.1, HW - 0.1, paint, bevel=0.05)
    # roof hatch
    b.box((0.7, 0.55, 0.06), (0, 1.55, 3.9), paint, bevel=0.02)

    # windscreen: dark frame + glass, follows the lean of the front face
    def lean_panel(z0, z1, half_w, out, m, bevel=0.0):
        y0, y1 = front_y(z0), front_y(z1)
        b.prism([(y0 - 0.04, z0), (y0 + out, z0), (y1 + out, z1), (y1 - 0.04, z1)],
                -half_w, half_w, m, bevel=bevel)
    lean_panel(1.98, 3.38, 1.235, 0.015, dark)
    lean_panel(2.03, 3.33, 1.2, 0.03, glass, bevel=0.01)
    # sun-visor lip over the windscreen
    lean_panel(3.41, 3.47, 1.2, 0.07, dark)

    # grille band with slats + badge
    b.box((1.9, 0.06, 0.34), (0, CAB_FRONT + 0.01, 1.66), dark, bevel=0.015)
    for z in (1.58, 1.68, 1.78):
        b.box((1.78, 0.04, 0.035), (0, CAB_FRONT + 0.045, z), mat("mast"))
    b.box((0.26, 0.03, 0.06), (0, CAB_FRONT + 0.03, 1.9), chrome)

    # bumper with headlights, indicators, plate, step cut-outs
    b.box((2.5, 0.3, 0.62), (0, CAB_FRONT - 0.05, 0.92), dark, bevel=0.05)
    for s in (-1, 1):
        b.box((0.46, 0.05, 0.2), (s * 0.9, CAB_FRONT + 0.1, 1.06), mat("headlight"),
              bevel=0.015)
        b.box((0.16, 0.05, 0.1), (s * 0.9, CAB_FRONT + 0.1, 0.82), mat("beacon"))
    b.box((0.52, 0.03, 0.12), (0, CAB_FRONT + 0.1, 0.8), mat("trailer_white"))

    # sides: windows, door seams, handles, mirrors, steps
    for s in (-1, 1):
        x = s * (HW + 0.005)
        # side glass runs to the front corner so the windscreen reads as wrapping
        b.box((0.03, 1.02, 1.05), (x, 2.47, 2.78), glass, bevel=0.01)
        b.box((0.03, 0.36, 0.6), (x, 1.2, 2.85), glass, bevel=0.01)
        for y in (1.62, 2.94):  # door seams
            b.box((0.02, 0.025, 2.2), (x, y, 2.25), dark)
        b.box((0.03, 0.18, 0.04), (x + s * 0.01, 1.8, 2.05), dark)
        # mirror arm + big mirror head near the A-pillar
        b.box((0.28, 0.05, 0.05), (s * (HW + 0.12), 2.86, 3.3), dark)
        b.box((0.05, 0.05, 0.5), (s * (HW + 0.25), 2.86, 3.08), dark)
        b.box((0.09, 0.2, 0.55), (s * (HW + 0.3), 2.84, 2.9), dark, bevel=0.02)
        b.box((0.09, 0.18, 0.2), (s * (HW + 0.3), 2.88, 2.48), dark, bevel=0.02)
        # entry steps under the door, behind the front wheel
        b.box((0.3, 0.6, 0.5), (s * (HW - 0.14), 1.03, 0.85), dark, bevel=0.03)
        for z in (0.68, 0.92):
            b.box((0.32, 0.5, 0.035), (s * (HW - 0.13), 1.03, z), mat("rim"))

    # --- chassis -----------------------------------------------------------
    for s in (-1, 1):
        b.box((0.18, 5.9, 0.3), (s * 0.45, -0.05, 0.87), dark)
    for y in (-2.6, -0.3, 2.2):
        b.box((0.75, 0.15, 0.2), (0, y, 0.85), dark)
    # rear mudguards and mud flaps
    for s in (-1, 1):
        b.box((0.66, 2.6, 0.06), (s * 1.0, -1.6, 1.12), dark, bevel=0.02)
        b.box((0.62, 0.03, 0.55), (s * 1.0, -2.88, 0.8), dark)
    # rear light bar + tail lights
    b.box((2.3, 0.1, 0.14), (0, -2.95, 0.98), dark)
    for s in (-1, 1):
        b.box((0.3, 0.04, 0.1), (s * 0.95, -3.01, 0.98), mat("taillight"))
    # fuel tank (right), battery / air box (left)
    b.cyl(0.3, 1.0, (0.86, 0.2, 0.7), chrome, axis="Y", segs=10, bevel=0.03)
    for y in (-0.15, 0.55):
        b.box((0.64, 0.05, 0.64), (0.86, y, 0.7), dark)
    b.box((0.5, 0.9, 0.55), (-0.9, 0.2, 0.72), dark, bevel=0.03)
    # exhaust stack behind the cab
    b.cyl(0.07, 2.8, (-0.95, CAB_REAR - 0.12, 2.4), chrome, segs=8)
    # cab rear wall detail: air lines
    b.box((0.9, 0.06, 0.06), (0.2, CAB_REAR - 0.05, 1.6), dark)
    # fifth wheel on its mounting plate
    fx, fy, fz = FIFTH_WHEEL
    b.box((0.95, 0.7, 0.1), (fx, fy, 1.07), dark)
    b.cyl(0.46, 0.06, (fx, fy, fz - 0.03), mat("mast"), segs=12, bevel=0.015)

    b.finish(root)

    # --- wheels --------------------------------------------------------
    cv.wheel("Wheel_FL", WHEEL_R, 0.34, (-1.06, FRONT_AXLE, WHEEL_R), -1, root)
    cv.wheel("Wheel_FR", WHEEL_R, 0.34, (1.06, FRONT_AXLE, WHEEL_R), 1, root)
    for i, y in enumerate(REAR_AXLES, 1):
        cv.wheel(f"Wheel_RL{i}", WHEEL_R, 0.52, (-0.99, y, WHEEL_R), -1, root)
        cv.wheel(f"Wheel_RR{i}", WHEEL_R, 0.52, (0.99, y, WHEEL_R), 1, root)

    cv.make_empty("FifthWheel", FIFTH_WHEEL, root)
    cv.center_on_ground(root)
    cv.export_glb(f"truck_cab_{color}.glb")


for c in ("red", "blue"):
    build(c)
