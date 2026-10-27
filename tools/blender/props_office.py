"""office_booth (4 x 3 x 3 m guard/office booth) and office_desk (desk, monitor, chair).

Front is -Y. Run: Blender -b --factory-startup --python tools/blender/props_office.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402

BW, BD, BH = 4.0, 3.0, 3.0
WALL_TOP = 2.78


def window(mb, face, u, z0, w, h, frame, glass):
    """Window on a booth face. face in '-Y','+Y','-X','+X'; u = offset along the face."""
    t = 0.04
    if face in ("-Y", "+Y"):
        s = -1 if face == "-Y" else 1
        y = s * (BD / 2)
        mb.box((w + 0.12, t * 2, h + 0.12), (u, y + s * t * 0.5, z0 + h / 2), frame)
        mb.box((w, t * 2, h), (u, y + s * t * 0.75, z0 + h / 2), glass)
        mb.box((0.05, t * 2, h), (u, y + s * t, z0 + h / 2), frame)
        mb.box((w + 0.2, 0.12, 0.05), (u, y + s * 0.06, z0 - 0.07), frame)
    else:
        s = -1 if face == "-X" else 1
        x = s * (BW / 2)
        mb.box((t * 2, w + 0.12, h + 0.12), (x + s * t * 0.5, u, z0 + h / 2), frame)
        mb.box((t * 2, w, h), (x + s * t * 0.75, u, z0 + h / 2), glass)
        mb.box((t * 2, 0.05, h), (x + s * t, u, z0 + h / 2), frame)
        mb.box((0.12, w + 0.2, 0.05), (x + s * 0.06, u, z0 - 0.07), frame)


def office_booth():
    C.reset()
    wall = C.mat("office_wall", C.PAL["office_wall"], rough=0.8)
    plinth = C.mat("wall_plinth", C.PAL["wall_plinth"], rough=0.85)
    roof = C.mat("office_roof", C.PAL["office_roof"], rough=0.7, metal=0.1)
    frame = C.mat("office_frame", "#3C4046", rough=0.5, metal=0.3)
    glass = C.mat("window_glass", C.PAL["glass"], rough=0.15, metal=0.3)
    door = C.mat("office_door", C.PAL["office_roof"], rough=0.6, metal=0.2)
    conc = C.mat("concrete", C.PAL["concrete"], rough=0.95)
    unit = C.mat("ac_unit", "#C3C6C9", rough=0.5, metal=0.3)
    mb = C.MB()
    mb.box((BW, BD, WALL_TOP), (0, 0, WALL_TOP / 2), wall, bevel=0.03, drop=("-Z",))
    mb.box((BW + 0.04, BD + 0.04, 0.3), (0, 0, 0.15), plinth, bevel=0.01, drop=("-Z",))
    # flat roof with slight overhang and a fascia
    ov = 0.18
    mb.box((BW + 2 * ov, BD + 2 * ov, 0.22), (0, 0, BH - 0.11), roof, bevel=0.02)
    mb.box((BW + 2 * ov - 0.2, BD + 2 * ov - 0.2, 0.03), (0, 0, BH + 0.005), roof, drop=("-Z",))
    mb.box((0.8, 0.6, 0.35), (-0.9, 0.5, BH + 0.175), unit, bevel=0.03, drop=("-Z",))
    # front: big window + door; sides: windows
    window(mb, "-Y", -0.75, 1.0, 1.6, 1.1, frame, glass)
    window(mb, "-X", 0.0, 1.0, 1.3, 1.1, frame, glass)
    window(mb, "+X", -0.3, 1.0, 1.0, 1.1, frame, glass)
    window(mb, "+Y", 0.6, 1.2, 1.2, 0.9, frame, glass)
    dx = 1.15
    mb.box((1.04, 0.05, 2.22), (dx, -BD / 2 - 0.02, 1.11 + 0.04), frame, drop=("-Z",))
    mb.box((0.9, 0.06, 2.1), (dx, -BD / 2 - 0.035, 1.05 + 0.1), door)
    mb.box((0.3, 0.06, 0.4), (dx + 0.15, -BD / 2 - 0.07, 1.6), glass)
    mb.box((0.12, 0.05, 0.03), (dx - 0.32, -BD / 2 - 0.09, 1.05), frame)
    mb.box((1.3, 0.5, 0.1), (dx, -BD / 2 - 0.25, 0.05), conc, bevel=0.01, drop=("-Z",))
    mb.box((1.3, 0.8, 0.06), (dx, -BD / 2 - 0.4, 2.55), roof, bevel=0.01)
    root = mb.to_object("OfficeBooth")
    C.col_box("OfficeBooth-col", (BW, BD, BH), (0, 0, BH / 2), root)
    C.export(root, "office_booth.glb")


def office_desk():
    """Desk 1.4 x 0.7, monitor facing -Y, chair on the -Y side."""
    C.reset()
    top = C.mat("desk_top", "#A9845A", rough=0.6)
    leg = C.mat("desk_frame", C.PAL["lamp_post"], rough=0.5, metal=0.4)
    black = C.mat("monitor_black", C.PAL["dock_black"], rough=0.4)
    screen = C.mat("monitor_screen", "#7FA3C2", rough=0.2, emission="#7FA3C2", strength=0.8)
    chair = C.mat("chair_fabric", "#33363B", rough=0.9)
    paper = C.mat("paper", "#EEEDE8", rough=0.9)
    mb = C.MB()
    mb.box((1.4, 0.7, 0.04), (0, 0, 0.73), top, bevel=0.01)
    for s in (-1, 1):
        mb.box((0.04, 0.64, 0.71), (s * 0.66, 0, 0.355), leg, drop=("-Z",))
    mb.box((1.28, 0.02, 0.35), (0, 0.3, 0.5), leg)
    mb.box((0.4, 0.6, 0.55), (0.42, 0.0, 0.3), leg, bevel=0.01, drop=("-Z",))
    # monitor
    mb.box((0.22, 0.16, 0.015), (0, 0.18, 0.758), black)
    mb.box((0.04, 0.03, 0.2), (0, 0.2, 0.86), black)
    mb.box((0.6, 0.04, 0.36), (0, 0.17, 1.08), black, bevel=0.008)
    mb.box((0.56, 0.005, 0.32), (0, 0.148, 1.08), screen, drop=("+Y",))
    mb.box((0.45, 0.15, 0.02), (0, -0.1, 0.76), black, bevel=0.004)
    mb.box((0.3, 0.22, 0.012), (-0.48, -0.05, 0.756), paper)
    # chair
    cy = -0.6
    for i in range(5):
        mb.box((0.04, 0.3, 0.04), (0, cy, 0.05), black,
               rot=C.rot_z(72 * i) @ C.Matrix.Translation((0, 0.13, 0)))
    mb.cyl(0.025, 0.36, (0, cy, 0.07), leg, segs=6, caps=False)
    mb.box((0.5, 0.48, 0.08), (0, cy, 0.47), chair, bevel=0.02)
    mb.box((0.46, 0.07, 0.52), (0, cy - 0.25, 0.8), chair, bevel=0.02, rot=C.rot_x(-8))
    root = mb.to_object("OfficeDesk")
    C.col_box("OfficeDesk-col", (1.4, 0.7, 0.75), (0, 0, 0.375), root)
    C.col_box("OfficeChair-col", (0.5, 0.54, 1.05), (0, -0.62, 0.525), root)
    C.export(root, "office_desk.glb")


def main():
    office_booth()
    office_desk()


if __name__ == "__main__":
    main()
