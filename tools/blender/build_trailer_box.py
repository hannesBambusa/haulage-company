"""7.8 m box semi-trailer, 2 rear axles, hollow cargo box. Writes trailer_box.glb.

Blender: +Y forward (-> -Z in Godot). Root "Trailer"; children:
  Body            shell, chassis, rear door frame, cargo interior (bed, walls, roof)
  DoorL / DoorR   rear doors, origin on the outer vertical hinge line. In Godot,
                  rotation.y = -270 deg (DoorL) / +270 deg (DoorR) swings them out
                  flat against the trailer sides.
  Wheel_L1..R2    origin at axle centre
  Empties         Kingpin (coupling point), Slot_01..Slot_10 (EUR pallet bottom
                  centres on the bed, 01/02 at the nose, odd = left), RearEntry
                  (centre of the rear bed edge), InteriorLight (under the roof).
Every interior detail is embedded into the surface it sits on, so no faces are
coplanar (no z-fighting with the doors open).
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_vehicles as cv  # noqa: E402
from common_vehicles import mat  # noqa: E402
from mathutils import Vector  # noqa: E402

L = 7.8
HW = 1.275                     # outer half width
WALL_T = 0.06
IHW = HW - WALL_T              # inner half width (2.43 m inner)
SHELL_BOT = 1.13               # underside of the floor (= kingpin plate face)
WHEEL_R = 0.5
# the 12-sided tyres stand on a flat, so the whole trailer drops by this on export
GROUND = WHEEL_R * (1 - math.cos(math.pi / 12))
BED = 1.15 + GROUND            # cargo floor, 1.15 m above ground after export
IN_TOP = BED + 2.6             # inner roof
TOP = 4.0                      # outer roof
IN_FRONT = L - WALL_T          # inner face of the front wall
CH = 0.05                      # chamfer on the long box edges
AXLES = (1.25, 2.55)          # y from the rear face (rear = 0)
KINGPIN = (0.0, L - 1.3, 1.13)
LEG_Y = L - 2.8                    # landing gear
# Rear doors
DOOR_Z0, DOOR_Z1 = BED + 0.01, TOP - 0.05
HINGE_X, HINGE_Y = HW + 0.01, -0.11
# EUR pallets: 1.2 m along the trailer, 0.8 m across; 2 across, 5 rows from the nose
SLOT_X = (-0.45, 0.45)
SLOT_ROW0 = IN_FRONT - 0.1 - 0.6
SLOT_STEP = 1.3
# Fixed placement offset: keeps the Kingpin (and the whole trailer) where the
# previous closed-box version put it: y centred on its old extents, ground at z=0.
LEGACY_CY = (-0.095 + (L + 0.03)) / 2


def shell(b, white):
    """Outer skin: chamfered prism along Y, open at the rear, closed at the front."""
    prof = [(-HW, SHELL_BOT + CH), (-HW + CH, SHELL_BOT), (HW - CH, SHELL_BOT), (HW, SHELL_BOT + CH),
            (HW, TOP - CH), (HW - CH, TOP), (-HW + CH, TOP), (-HW, TOP - CH)]
    zc = (SHELL_BOT + TOP) / 2
    n = len(prof)
    for i in range(n):
        (x0, z0), (x1, z1) = prof[i], prof[(i + 1) % n]
        out = ((x0 + x1) / 2, 0, (z0 + z1) / 2 - zc)
        b.quad([(x0, 0, z0), (x1, 0, z1), (x1, L, z1), (x0, L, z0)], white, out)
    b.quad([(x, L, z) for x, z in prof], white, (0, 1, 0))


def interior(b):
    wall = mat("cargo_wall")
    rib = mat("cargo_rib")
    rail = mat("cargo_rail")
    planks = [mat("bed_plank_a"), mat("bed_plank_b"), mat("bed_plank_c")]
    y0 = 0.05                       # bed starts behind the rear sill
    # plank floor: 10 strips across, three shades, sharing edges (no overlaps)
    n = 10
    w = 2 * IHW / n
    for i in range(n):
        x0, x1 = -IHW + i * w, -IHW + (i + 1) * w
        b.quad([(x0, y0, BED), (x1, y0, BED), (x1, IN_FRONT, BED), (x0, IN_FRONT, BED)],
               planks[(i * 2) % 3], (0, 0, 1))
    for s in (-1, 1):
        x = s * IHW
        b.quad([(x, 0, BED), (x, IN_FRONT, BED), (x, IN_FRONT, IN_TOP), (x, 0, IN_TOP)], wall, (-s, 0, 0))
    b.quad([(-IHW, IN_FRONT, BED), (IHW, IN_FRONT, BED), (IHW, IN_FRONT, IN_TOP), (-IHW, IN_FRONT, IN_TOP)],
           wall, (0, -1, 0))
    b.quad([(-IHW, 0, IN_TOP), (IHW, 0, IN_TOP), (IHW, IN_FRONT, IN_TOP), (-IHW, IN_FRONT, IN_TOP)],
           wall, (0, 0, -1))
    # kick strips, two logistics rails per side, vertical wall ribs (all sunk into the wall)
    ln = IN_FRONT + 0.01 - y0
    yc = y0 + ln / 2
    for s in (-1, 1):
        b.box((0.03, ln, 0.17), (s * (IHW + 0.005), yc, BED + 0.075), rail)
        for z in (1.95, 2.85):
            b.box((0.035, ln, 0.1), (s * (IHW + 0.0025), yc, z), rail)
        for y in (1.3, 2.6, 3.9, 5.2, 6.5):
            b.box((0.026, 0.07, 2.35), (s * (IHW + 0.007), y, BED + 1.375), rib)
    # front wall: kick strip + one rail
    b.box((2 * IHW + 0.02, 0.03, 0.16), (0, IN_FRONT + 0.005, BED + 0.07), rail)
    b.box((2 * IHW + 0.02, 0.035, 0.1), (0, IN_FRONT + 0.0025, 2.4), rail)
    # roof bows + light strip
    for y in (1.3, 2.6, 5.2, 6.5):
        b.box((2 * IHW + 0.02, 0.06, 0.05), (0, y, IN_TOP - 0.015), rib)
    b.box((0.18, 1.2, 0.05), (0, L / 2, IN_TOP - 0.015), mat("interior_light"))


def rear_frame(b, grey, steel):
    zc = (SHELL_BOT + TOP) / 2
    for s in (-1, 1):  # corner posts, proud of the skin by 8 mm
        b.box((0.098, 0.07, TOP - SHELL_BOT + 0.02), (s * (HW - 0.041), 0.015, zc), grey)
    b.box((2 * HW + 0.016, 0.07, TOP + 0.01 - (IN_TOP - 0.03)), (0, 0.015, (TOP + 0.01 + IN_TOP - 0.03) / 2), grey)
    # rear sill: top flush with the bed, bed planks start where it ends (y=0.05)
    b.box((2 * HW + 0.016, 0.07, 0.04), (0, 0.015, BED - 0.02), steel)


def door(name, s, root, white, dark, chrome):
    """One rear door. s=-1 left, +1 right. Origin on the outer hinge line, at door bottom."""
    d = cv.MeshBuilder(name)
    dh = DOOR_Z1 - DOOR_Z0
    zc = (DOOR_Z0 + DOOR_Z1) / 2
    x_in, x_out = 0.006, HW - 0.01
    d.box((x_out - x_in, 0.04, dh), (s * (x_in + x_out) / 2, -0.045, zc), white, bevel=0.01)
    if s > 0:  # overlap strip over the centre gap
        d.box((0.03, 0.012, dh - 0.1), (0.006, -0.066, zc), dark)
    for z in (DOOR_Z0 + 0.3, DOOR_Z0 + 1.1, DOOR_Z0 + 1.9, DOOR_Z1 - 0.25):
        d.box((0.25, 0.027, 0.08), (s * (HW - 0.1), -0.0735, z), dark)            # strap
        d.box((0.05, 0.05, 0.11), (s * HINGE_X, HINGE_Y, z), dark)                # knuckle
    for x in (0.3, 0.9):
        d.cyl(0.0175, DOOR_Z1 - DOOR_Z0 - 0.12, (s * x, -0.0825, zc), chrome, segs=6)
        for z in (DOOR_Z0 + 0.09, DOOR_Z1 - 0.09):
            d.box((0.07, 0.04, 0.06), (s * x, -0.085, z), dark)                  # rod keeper
        d.box((0.05, 0.03, 0.3), (s * (x + 0.06), -0.1, 1.95), dark)               # handle
    return d.finish(root, origin=(s * HINGE_X, HINGE_Y, DOOR_Z0))


def build():
    cv.reset_scene()
    white = mat("trailer_white")
    dark = mat("chassis")
    grey = mat("rim")
    chrome = mat("chrome")
    root = cv.make_root("Trailer")
    b = cv.MeshBuilder("Body")

    shell(b, white)
    interior(b)
    rear_frame(b, grey, grey)
    for s in (-1, 1):  # roof edge rails
        b.box((0.05, L, 0.08), (s * (HW - 0.02), L / 2, TOP - 0.05), grey)
    # bottom side rails (dark band under the box), inner face hidden in the wall
    for s in (-1, 1):
        b.box((0.06, L - 0.1, 0.2), (s * (HW - 0.02), L / 2, SHELL_BOT - 0.02), dark)
    # main beams stop short of the kingpin plate (gooseneck clear for the fifth wheel)
    beam_y0, beam_y1 = 0.4, KINGPIN[1] - 1.0
    for s in (-1, 1):
        b.box((0.2, beam_y1 - beam_y0, 0.18), (s * 0.5, (beam_y0 + beam_y1) / 2, SHELL_BOT - 0.08), dark)
    for y in (0.6, 3.6, 5.3):
        b.box((2 * HW - 0.1, 0.12, 0.12), (0, y, SHELL_BOT - 0.05), dark)
    # kingpin plate + pin (plate face at kingpin height, top hidden under the bed)
    kx, ky, kz = KINGPIN
    b.box((1.6, 1.8, 0.02), (0, ky, kz + 0.005), dark)
    b.cyl(0.05, 0.1, (kx, ky, kz - 0.05), mat("mast"), segs=8)

    # landing gear (raised), tops sunk into the floor void
    for s in (-1, 1):
        b.box((0.12, 0.14, 0.87), (s * 0.75, LEG_Y, 0.705), dark)
        b.box((0.09, 0.1, 0.25), (s * 0.75, LEG_Y, 0.2), grey)
        b.box((0.26, 0.3, 0.05), (s * 0.75, LEG_Y, 0.08), dark)
    b.box((1.4, 0.06, 0.08), (0, LEG_Y, 0.75), dark)
    b.box((0.06, 0.06, 0.35), (0.95, LEG_Y, 0.65), grey)  # crank handle

    # axle group: mudguards + hangers
    for s in (-1, 1):
        b.box((0.52, 2.6, 0.05), (s * 1.02, (AXLES[0] + AXLES[1]) / 2, 1.1), dark, bevel=0.02)
        b.box((0.5, 0.03, 0.5), (s * 1.02, AXLES[0] - 0.62, 0.8), dark)
    for y in AXLES:
        b.box((1.6, 0.12, 0.12), (0, y, WHEEL_R), dark)
        b.box((0.16, 0.5, 0.6), (0, y, 0.84), dark)

    # side underrun guard: two grey rails on dark posts
    y0, y1 = AXLES[-1] + 0.75, LEG_Y - 0.35
    for s in (-1, 1):
        for z in (0.56, 0.86):
            b.box((0.05, y1 - y0, 0.1), (s * (HW - 0.07), (y0 + y1) / 2, z), grey, bevel=0.015)
        for y in (y0 + 0.2, (y0 + y1) / 2, y1 - 0.2):
            b.box((0.04, 0.08, 0.75), (s * (HW - 0.11), y, 0.83), dark)

    # rear: underride bar, light bar, tail lights (under the sill)
    b.box((2.35, 0.14, 0.16), (0, 0.35, 0.55), grey, bevel=0.02)
    for s in (-1, 1):
        b.box((0.08, 0.08, 0.7), (s * 0.7, 0.35, 0.88), dark)
    b.box((2 * HW - 0.05, 0.1, 0.17), (0, 0.06, 1.025), dark)
    for s in (-1, 1):
        b.box((0.34, 0.04, 0.12), (s * 0.95, 0.0, 1.025), mat("taillight"))
        b.box((0.1, 0.04, 0.09), (s * 0.6, 0.0, 1.025), mat("beacon"))

    # front: small marker lights at the top corners
    for s in (-1, 1):
        b.box((0.1, 0.04, 0.08), (s * (HW - 0.12), L + 0.01, TOP - 0.12), mat("beacon"))

    b.finish(root)
    door("DoorL", -1, root, white, dark, chrome)
    door("DoorR", 1, root, white, dark, chrome)

    for i, y in enumerate(AXLES, 1):
        cv.wheel(f"Wheel_L{i}", WHEEL_R, 0.42, (-1.02, y, WHEEL_R), -1, root, segs=12)
        cv.wheel(f"Wheel_R{i}", WHEEL_R, 0.42, (1.02, y, WHEEL_R), 1, root, segs=12)

    cv.make_empty("Kingpin", KINGPIN, root)
    for row in range(5):
        for col, x in enumerate(SLOT_X):
            cv.make_empty(f"Slot_{row * 2 + col + 1:02d}", (x, SLOT_ROW0 - row * SLOT_STEP, BED), root)
    cv.make_empty("RearEntry", (0.0, -0.02, BED), root)
    cv.make_empty("InteriorLight", (0.0, L / 2, IN_TOP - 0.15), root)

    lo, _hi = cv.world_bbox([o for o in root.children if o.type == "MESH"])
    off = Vector((0.0, -LEGACY_CY, -lo.z))
    for ch in root.children:
        ch.location += off
    cv.export_glb("trailer_box.glb")


build()
