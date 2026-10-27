"""Warehouse shell pieces: wall_segment, wall_corner, dock_door, dock_canopy.

Exterior side is -Y (Godot +Z). Walls are 0.3 m thick centred on y=0.
Run: Blender -b --factory-startup --python tools/blender/props_shell.py
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

WALL_W, WALL_H, WALL_T = 4.0, 5.2, 0.3
CORNER_H = 5.2  # body; cap adds 0.1 -> 5.3 total
PLINTH_H = 0.5
RIB_XS = [-1.25 + 0.5 * i for i in range(7)]  # clear of the pilaster at x=-2..-1.65
PIL_W, PIL_D, PIL_X = 0.35, 0.4, -WALL_W / 2 + 0.175
WALL_HEX, PLINTH_HEX, PIL_HEX = "#B4B6B4", "#80858A", "#9EA2A6"


def mats():
    return dict(
        wall=C.mat("wall_panel", WALL_HEX, rough=0.7, metal=0.1),
        rib=C.mat("wall_rib", WALL_HEX, rough=0.6, metal=0.15, factor=1.06),
        plinth=C.mat("wall_plinth", PLINTH_HEX, rough=0.85),
        cap=C.mat("wall_cap", PLINTH_HEX, rough=0.6, metal=0.2, factor=0.9),
        pil=C.mat("wall_pilaster", PIL_HEX, rough=0.65, metal=0.1),
        black=C.mat("dock_black", C.PAL["dock_black"], rough=0.8),
        yellow=C.mat("dock_yellow", C.PAL["dock_yellow"], rough=0.5),
        door=C.mat("roller_door", C.PAL["roller_door"], rough=0.5, metal=0.3),
        door_slat=C.mat("roller_door_slat", C.PAL["roller_door"], rough=0.5, metal=0.3, factor=0.88),
        steel=C.mat("leveler_steel", "#5E636A", rough=0.5, metal=0.6),
        plate=C.mat("leveler_plate", "#4A4D52", rough=0.45, metal=0.6),
        tread=C.mat("leveler_tread", "#4A4D52", rough=0.35, metal=0.6, factor=1.22),
        dock_face=C.mat("dock_face", "#3A3D41", rough=0.6, metal=0.4),
        rubber=C.mat("bumper_rubber", "#18191B", rough=0.9),
    )


def ribs(mb, m, x_list, z0, z1, sides=(-1, 1)):
    for s in sides:
        for x in x_list:
            mb.box((0.07, 0.035, z1 - z0), (x, s * (WALL_T / 2 + 0.0175), (z0 + z1) / 2), m["rib"],
                   drop=("-Z", "+Z"))


def pilaster(mb, m):
    """Slightly proud post at the -X edge, full height under the cap, with a plinth foot."""
    h = WALL_H - 0.12
    mb.box((PIL_W, PIL_D, h), (PIL_X, 0, h / 2), m["pil"], drop=("-Z", "+Z"))
    mb.box((PIL_W + 0.06, PIL_D + 0.06, PLINTH_H), (PIL_X, 0, PLINTH_H / 2), m["plinth"], drop=("-Z",))


def wall_segment():
    C.reset()
    m = mats()
    mb = C.MB()
    core_h = WALL_H - 0.1  # top hidden under the cap (avoids coplanar z-fighting)
    mb.box((WALL_W, WALL_T, core_h), (0, 0, core_h / 2), m["wall"], drop=("-Z", "+Z"))
    mb.box((WALL_W, WALL_T + 0.06, PLINTH_H), (0, 0, PLINTH_H / 2), m["plinth"], drop=("-Z",))
    mb.box((WALL_W, WALL_T + 0.08, 0.12), (0, 0, WALL_H - 0.06), m["cap"])
    ribs(mb, m, RIB_XS, PLINTH_H, WALL_H - 0.12)
    pilaster(mb, m)
    root = mb.to_object("WallSegment")
    C.col_box("WallSegment-col", (WALL_W, WALL_T, WALL_H), (0, 0, WALL_H / 2), root)
    C.export(root, "wall_segment.glb")


def wall_corner():
    C.reset()
    m = mats()
    mb = C.MB()
    s = 0.5
    WALL_H = CORNER_H
    mb.box((s, s, WALL_H), (0, 0, WALL_H / 2), m["wall"], bevel=0.02, drop=("-Z",))
    mb.box((s + 0.06, s + 0.06, PLINTH_H), (0, 0, PLINTH_H / 2), m["plinth"], bevel=0.01, drop=("-Z",))
    mb.box((s + 0.08, s + 0.08, 0.12), (0, 0, WALL_H + 0.04), m["cap"], bevel=0.01)
    root = mb.to_object("WallCorner")
    C.col_box("WallCorner-col", (s, s, WALL_H + 0.1), (0, 0, (WALL_H + 0.1) / 2), root)
    C.export(root, "wall_corner.glb")


OPEN_W, OPEN_H = 3.0, 4.0  # 4.0 - LEV_H 1.15 = 2.85 m clearance over RampTop
FRAME_D = 0.4
FRAME_TOP = 4.2
# Dock leveler: ramp from the warehouse floor (y=LEV_BOT_Y, z=0) up to the threshold
# (y=LEV_TOP_Y, just inside the roller door, z=LEV_H = trailer bed height).
LEV_H = 1.15
LEV_BOT_Y, LEV_TOP_Y = 3.2, 0.08
LEV_W = 2.4                    # plate width; yellow guard curbs overhang to +-1.22
LIP_W, LIP_T = 1.8, 0.025
LIP_END_Y = -0.75              # lip reaches ~0.44 m past the bumpers onto the bed
BUMPER_Y = -0.31               # bumper face = where the trailer rear stops


def _face(mb, pts, m, normal):
    """One planar polygon, wound so it faces `normal` (materials cull back faces)."""
    p = [Vector(v) for v in pts]
    if (p[1] - p[0]).cross(p[2] - p[0]).dot(Vector(normal)) < 0:
        p.reverse()
    mb.poly(p, [tuple(range(len(p)))], m)


def _slope_box(mb, x0, x1, u0, u1, h0, h1, m, bottom=False):
    """Box lying on the ramp plane: x across, u metres up the slope from the toe,
    h along the slope normal. Bottom face only if asked (strips are sunk into the plate)."""
    run = LEV_BOT_Y - LEV_TOP_Y
    sl = math.hypot(run, LEV_H)
    d = Vector((0, -run / sl, LEV_H / sl))
    n = Vector((0, LEV_H / sl, run / sl))
    a = Vector((0, LEV_BOT_Y, 0))

    def p(x, u, h):
        return Vector((x, 0, 0)) + a + d * u + n * h

    c = {(i, j, k): p((x0, x1)[i], (u0, u1)[j], (h0, h1)[k]) for i in (0, 1) for j in (0, 1) for k in (0, 1)}
    _face(mb, [c[0, 0, 1], c[1, 0, 1], c[1, 1, 1], c[0, 1, 1]], m, n)
    _face(mb, [c[0, 0, 0], c[1, 0, 0], c[1, 0, 1], c[0, 0, 1]], m, -d)
    _face(mb, [c[0, 1, 0], c[1, 1, 0], c[1, 1, 1], c[0, 1, 1]], m, d)
    _face(mb, [c[0, 0, 0], c[0, 1, 0], c[0, 1, 1], c[0, 0, 1]], m, (-1, 0, 0))
    _face(mb, [c[1, 0, 0], c[1, 1, 0], c[1, 1, 1], c[1, 0, 1]], m, (1, 0, 0))
    if bottom:
        _face(mb, [c[0, 0, 0], c[1, 0, 0], c[1, 1, 0], c[0, 1, 0]], m, -n)
    return sl


def leveler(root, m):
    """Child "Leveler" (origin on the floor hinge, tilts about X) with child "LevelerLip"
    (origin on the lip hinge at the threshold), plus RampBottom / RampTop empties."""
    hinge = Vector((0, LEV_BOT_Y, 0))
    lv = C.MB()
    lv.xform = Matrix.Translation(-hinge)
    rw = LEV_W / 2
    yt, h = LEV_TOP_Y, LEV_H
    # solid wedge, no bottom face (sits on the warehouse floor)
    for s in (-1, 1):
        _face(lv, [(s * rw, LEV_BOT_Y, 0), (s * rw, yt, h), (s * rw, yt, 0)], m["plate"], (s, 0, 0))
    _face(lv, [(-rw, LEV_BOT_Y, 0), (rw, LEV_BOT_Y, 0), (rw, yt, h), (-rw, yt, h)], m["plate"], (0, 1, 1))
    _face(lv, [(-rw, yt, 0), (rw, yt, 0), (rw, yt, h), (-rw, yt, h)], m["plate"], (0, -1, 0))
    sl = math.hypot(LEV_BOT_Y - yt, h)
    # yellow guard curbs (overhang the plate edge so no side faces are coplanar)
    for s in (-1, 1):
        xa, xb = sorted((s * (rw - 0.12), s * (rw + 0.02)))
        _slope_box(lv, xa, xb, 0.3, sl, -0.02, 0.1, m["yellow"], bottom=True)
    # yellow toe and threshold edge stripes, then a staggered raised tread pattern
    _slope_box(lv, -rw + 0.12, rw - 0.12, 0.02, 0.2, -0.005, 0.006, m["yellow"])
    _slope_box(lv, -rw + 0.12, rw - 0.12, sl - 0.16, sl - 0.02, -0.005, 0.006, m["yellow"])
    u, row = 0.4, 0
    while u < sl - 0.3:
        xs = (-0.7, 0.0, 0.7) if row % 2 == 0 else (-0.35, 0.35)
        for x in xs:
            _slope_box(lv, x - 0.22, x + 0.22, u, u + 0.06, -0.005, 0.012, m["tread"])
        u += 0.28
        row += 1
    # hazard edge on the exterior end face, just under the threshold
    lv.box((LEV_W - 0.1, 0.02, 0.08), (0, yt - 0.005, h - 0.045), m["yellow"], drop=("+Y",))
    lev = lv.to_object("Leveler", parent=root, loc=tuple(hinge))

    # lip: hinge barrel + plate with a yellow tapered nose, resting on the trailer bed
    lh = Vector((0, yt, h))
    lp = C.MB()
    lp.xform = Matrix.Translation(-lh)
    hw = LIP_W / 2
    nose = LIP_END_Y + 0.12
    lp.prism_x([(yt, h), (nose, h), (nose, h + LIP_T), (yt, h + LIP_T)][::-1], LIP_W, (0, 0, 0), m["plate"])
    lp.prism_x([(nose, h), (LIP_END_Y, h), (LIP_END_Y + 0.05, h + LIP_T - 0.002), (nose, h + LIP_T - 0.002)][::-1],
               LIP_W - 0.002, (0, 0, 0), m["yellow"])
    lp.cyl(0.03, LIP_W + 0.04, (-hw - 0.02, yt, h), m["steel"], segs=8, rot=C.rot_y(90))
    lp.to_object("LevelerLip", parent=lev, loc=tuple(lh - hinge))

    C.empty("RampBottom", (0, LEV_BOT_Y, 0), root)
    C.empty("RampTop", (0, LEV_TOP_Y, LEV_H), root)


def dock_door():
    C.reset()
    m = mats()
    mb = C.MB()
    ext = -WALL_T / 2  # exterior wall face y
    pier_w = (WALL_W - OPEN_W) / 2
    for s in (-1, 1):
        x = s * (OPEN_W / 2 + pier_w / 2)
        mb.box((pier_w, WALL_T, WALL_H - 0.1), (x, 0, (WALL_H - 0.1) / 2), m["wall"], drop=("-Z", "+Z"))
        mb.box((pier_w, WALL_T + 0.06, PLINTH_H), (x, 0, PLINTH_H / 2), m["plinth"], drop=("-Z",))
    hh = WALL_H - OPEN_H
    mb.box((OPEN_W, WALL_T, hh - 0.1), (0, 0, OPEN_H + (hh - 0.1) / 2), m["wall"], drop=("+Z",))
    mb.box((WALL_W, WALL_T + 0.08, 0.12), (0, 0, WALL_H - 0.06), m["cap"])
    pilaster(mb, m)
    # ribs: exterior only above the shelter, interior full height outside the opening
    ribs(mb, m, RIB_XS, FRAME_TOP, WALL_H - 0.12, sides=(-1,))
    ribs(mb, m, [x for x in RIB_XS if abs(x) > OPEN_W / 2 and x > -1.6], PLINTH_H, WALL_H - 0.12, sides=(1,))
    ribs(mb, m, [x for x in RIB_XS if abs(x) < OPEN_W / 2], OPEN_H, WALL_H - 0.12, sides=(1,))
    # interior door guides
    for s in (-1, 1):
        mb.box((0.08, 0.1, OPEN_H), (s * (OPEN_W / 2 - 0.04), 0.08, OPEN_H / 2), m["steel"], drop=("-Z",))
    # black dock shelter frame on the exterior
    fy = ext - FRAME_D / 2
    side_w = 0.5
    for s in (-1, 1):
        sh = OPEN_H + 0.1  # sides end inside the top bar
        mb.box((side_w, FRAME_D, sh), (s * (OPEN_W / 2 - 0.05 + side_w / 2), fy, sh / 2),
               m["black"], bevel=0.03, drop=("-Z",))
    top_h = FRAME_TOP - OPEN_H
    mb.box((OPEN_W - 0.1 + 2 * side_w, FRAME_D, top_h), (0, fy, OPEN_H + top_h / 2), m["black"], bevel=0.03)
    # yellow bumper posts
    front = ext - FRAME_D
    for s in (-1, 1):
        mb.box((0.14, 0.14, 1.3), (s * (OPEN_W / 2 + 0.02), front - 0.07, 0.65), m["yellow"],
               bevel=0.015, drop=("-Z",))
    # dock face plate under the lip, exterior of the roller door, carrying the rubber
    # bumpers the trailer rear backs onto (bumper face at y=BUMPER_Y, 1.0-1.3 m high)
    mb.box((OPEN_W + 0.04, 0.06, LEV_H - 0.03), (0, ext + 0.02, (LEV_H - 0.03) / 2),
           m["dock_face"], drop=("-Z",))
    for s in (-1, 1):
        mb.box((0.22, ext - BUMPER_Y, 0.3), (s * 1.12, (ext + BUMPER_Y) / 2, 1.15), m["rubber"], bevel=0.02)
    # yellow vertical guide stripes on the shelter face
    for s in (-1, 1):
        mb.box((0.08, 0.01, 1.8), (s * (OPEN_W / 2 + 0.17), front - 0.005, 2.3), m["yellow"],
               drop=("-Z", "+Y"))
    root = mb.to_object("DockDoor")
    leveler(root, m)

    # roller door child: origin at top of the opening so Godot can scale/translate it up
    dm = C.MB()
    dm.box((OPEN_W - 0.04, 0.06, OPEN_H), (0, 0, -OPEN_H / 2), m["door"])
    for i in range(1, 8):
        dm.box((OPEN_W - 0.04, 0.02, 0.05), (0, -0.04, -i * 0.5 + 0.1), m["door_slat"], drop=("+Y",))
    dm.box((OPEN_W - 0.04, 0.08, 0.28), (0, 0, -OPEN_H + 0.14), m["yellow"])
    dm.to_object("Door", parent=root, loc=(0, 0, OPEN_H))

    sl = C.MB()
    light = C.mat("status_light", "#3BE05A", rough=0.3, emission="#3BE05A", strength=4.0)
    sl.box((0.4, 0.05, 0.12), (0, 0, 0), light, bevel=0.01)
    sl.to_object("StatusLight", parent=root, loc=(0, front - 0.025, OPEN_H + 0.12))

    C.empty("NumberAnchor", (0, front - 0.02, 4.68), root)  # 0.8 m digits span 4.28..5.08: 0.08 above frame (4.2), under the cap (5.08)

    for s, tag in ((-1, "L"), (1, "R")):
        x0 = s * OPEN_W / 2
        x1 = s * WALL_W / 2
        C.col_box(f"DockDoor{tag}-col", (abs(x1 - x0), WALL_T / 2 - front, WALL_H),
                  ((x0 + x1) / 2, (WALL_T / 2 + front) / 2, WALL_H / 2), root)
    C.col_box("DockDoorTop-col", (OPEN_W, WALL_T, WALL_H - OPEN_H), (0, 0, OPEN_H + (WALL_H - OPEN_H) / 2), root)
    # walkable leveler: a slab under the ramp plate (top face = ramp surface) + the lip
    run, ang = LEV_BOT_Y - LEV_TOP_Y, math.atan2(LEV_H, LEV_BOT_Y - LEV_TOP_Y)
    sl = math.hypot(run, LEV_H)
    t = 0.2
    mid_y = (LEV_BOT_Y + LEV_TOP_Y) / 2 - t / 2 * math.sin(ang)
    mid_z = LEV_H / 2 - t / 2 * math.cos(ang)
    C.col_box("LevelerRamp-col", (LEV_W, sl, t), (0, mid_y, mid_z), root, rot=C.rot_x(-math.degrees(ang)))
    C.col_box("LevelerLipPlate-col", (LIP_W, LEV_TOP_Y - LIP_END_Y, LIP_T),
              (0, (LEV_TOP_Y + LIP_END_Y) / 2, LEV_H + LIP_T / 2), root)
    C.export(root, "dock_door.glb")


def dock_canopy():
    """Sloped canopy 4.5 W x 3 D. Origin at ground under the back (wall) edge; extends to -Y.
    Low edge 4.9 m, high edge 5.2 m at the wall (shallow so it clears dock NumberAnchor), two posts at the front corners."""
    C.reset()
    roof = C.mat("canopy_roof", "#3E4248", rough=0.7, metal=0.3)
    rib = C.mat("canopy_rib", "#4B5057", rough=0.6, metal=0.3)
    edge = C.mat("dock_black", C.PAL["dock_black"], rough=0.8)
    steel = C.mat("lamp_post", C.PAL["lamp_post"], rough=0.5, metal=0.5)
    mb = C.MB()
    w, d = 4.5, 3.0
    z_back, z_front = WALL_H, 4.9
    ang = math.degrees(math.atan2(z_back - z_front, d))
    mb.xform = Matrix.Translation((0, -d / 2, (z_back + z_front) / 2)) @ C.rot_x(ang)
    mb.box((w, d, 0.12), (0, 0, 0), roof, bevel=0.01)
    for i in range(11):
        x = -w / 2 + 0.25 + i * (w - 0.5) / 10
        mb.box((0.05, d - 0.06, 0.05), (x, 0, 0.085), rib, drop=("-Z",))
    mb.box((w + 0.06, 0.08, 0.32), (0, -d / 2 - 0.04, -0.04), edge, bevel=0.01)
    for s in (-1, 1):
        mb.box((0.08, d, 0.24), (s * (w / 2 + 0.03), 0, -0.02), edge)
    mb.xform = Matrix.Identity(4)
    # wall flashing strip and tie rods
    mb.box((w, 0.08, 0.2), (0, -0.04, z_back + 0.12), edge)
    # two slim grey posts at the outer (front) corners, down to the ground
    post = C.mat("canopy_post", "#50555B", rough=0.6, metal=0.3)
    ph = z_front  # tops tuck just into the roof underside
    px, py = w / 2 - 0.1, -d + 0.15
    for s in (-1, 1):
        mb.box((0.15, 0.15, ph), (s * px, py, ph / 2), post)
    root = mb.to_object("DockCanopy")
    for i, s in enumerate((-1, 1)):
        C.col_box(f"CanopyPost{'LR'[i]}", (0.15, 0.15, ph), (s * px, py, ph / 2), root)
    C.export(root, "dock_canopy.glb")


def main():
    wall_segment()
    wall_corner()
    dock_door()
    dock_canopy()


if __name__ == "__main__":
    main()
