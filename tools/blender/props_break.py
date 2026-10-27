"""Break-area props: coffee_machine (on a counter), break_table, break_chair, bench,
vending_machine, water_cooler, trash_bin, wet_floor_sign, toolbox.

Front is -Y, origin on the floor at the footprint centre, flat shaded, one
"-colonly" box per prop (common_props.COL_SUFFIX).
SitIdle: seat tops are at SEAT_H (0.45 m), matching the worker's SitIdle at scale 1.
Run: Blender -b --factory-startup --python tools/blender/props_break.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402

SEAT_H = 0.45


def frame_mat():
    return C.mat("break_frame", C.PAL["lamp_post"], rough=0.5, metal=0.4)


def coffee_machine():
    C.reset()
    cab = C.mat("counter_cabinet", "#D7D9DB", rough=0.7)
    top = C.mat("counter_top", "#7E848A", rough=0.5)
    handle = C.mat("counter_handle", "#3C4046", rough=0.4, metal=0.5)
    body = C.mat("coffee_body", "#2B2D30", rough=0.4)
    steel = C.mat("coffee_steel", "#B9BDC1", rough=0.3, metal=0.8)
    screen = C.mat("coffee_screen", "#7FC2A3", rough=0.2, emission="#7FC2A3", strength=0.8)
    cup = C.mat("cup_paper", "#F4F3EE", rough=0.8)
    mb = C.MB()
    w, d, h = 1.2, 0.6, 0.88
    mb.box((w, d - 0.04, h - 0.1), (0, 0.02, 0.1 + (h - 0.1) / 2), cab, drop=("-Z",))
    mb.box((w - 0.04, d - 0.08, 0.1), (0, 0.04, 0.05), handle, drop=("-Z",))   # toe kick
    mb.box((w + 0.02, d + 0.02, 0.04), (0, 0, h + 0.02), top, bevel=0.005)
    for x in (-0.3, 0.3):
        mb.box((0.003, 0.01, 0.62), (x, -d / 2 + 0.005, 0.5), handle)          # door gaps
        mb.box((0.12, 0.02, 0.02), (x + (0.08 if x < 0 else -0.08), -d / 2 - 0.005, 0.78), handle)
    z = h + 0.04
    mx = -0.22
    mb.box((0.36, 0.42, 0.52), (mx, 0.04, z + 0.26), body, bevel=0.015)
    mb.box((0.3, 0.06, 0.16), (mx, -0.19, z + 0.36), body, bevel=0.01)          # spout hood
    mb.box((0.2, 0.004, 0.08), (mx + 0.0, -0.172, z + 0.455), screen)
    mb.box((0.26, 0.14, 0.02), (mx, -0.15, z + 0.03), steel)                    # drip tray
    mb.cyl(0.012, 0.04, (mx, -0.17, z + 0.24), steel, segs=6)
    mb.cyl(0.03, 0.1, (mx, -0.15, z + 0.04), cup, segs=8, r2=0.038)
    # paper cup stack and a sugar box
    mb.cyl(0.038, 0.22, (0.18, -0.05, z), cup, segs=8, r2=0.042)
    mb.box((0.14, 0.1, 0.08), (0.38, 0.05, z + 0.04), C.mat("sugar_box", "#C8322A", rough=0.8))
    root = mb.to_object("CoffeeMachine")
    C.col_box("CoffeeMachine-col", (w + 0.02, d + 0.02, h + 0.04), (0, 0, (h + 0.04) / 2), root)
    C.export(root, "coffee_machine.glb")


def break_table():
    C.reset()
    top = C.mat("table_top", "#EDEDED", rough=0.5)
    edge = C.mat("table_edge", "#5A5F66", rough=0.5)
    leg = frame_mat()
    mb = C.MB()
    r, h = 0.4, 0.75
    mb.cyl(r, 0.03, (0, 0, h - 0.03), top, segs=16)
    mb.cyl(r + 0.005, 0.012, (0, 0, h - 0.042), edge, segs=16, caps=False)
    mb.cyl(0.035, h - 0.06, (0, 0, 0.03), leg, segs=8, caps=False)
    mb.cyl(0.08, 0.04, (0, 0, h - 0.08), leg, segs=8)
    for i in range(4):
        mb.box((0.56, 0.06, 0.03), (0, 0, 0.015), leg, rot=C.rot_z(45 + 90 * i) @ C.Matrix.Translation((0.14, 0, 0)))
    root = mb.to_object("BreakTable")
    C.col_box("BreakTable-col", (2 * r, 2 * r, h), (0, 0, h / 2), root)
    C.export(root, "break_table.glb")


def break_chair():
    """Seat centre at the origin, backrest at +Y, front -Y. Seat top at SEAT_H."""
    C.reset()
    shell = C.mat("chair_shell", "#E8822A", rough=0.6)
    leg = frame_mat()
    mb = C.MB()
    s = 0.44
    mb.box((s, s, 0.04), (0, 0, SEAT_H - 0.02), shell, bevel=0.012)
    mb.box((s, 0.035, 0.36), (0, s / 2 - 0.01, SEAT_H + 0.22), shell, bevel=0.012, rot=C.rot_x(-8))
    for x in (-1, 1):
        for y in (-1, 1):
            mb.box((0.025, 0.025, SEAT_H - 0.04), (x * (s / 2 - 0.03), y * (s / 2 - 0.03), (SEAT_H - 0.04) / 2),
                   leg, drop=("-Z",))
        mb.box((0.02, 0.02, 0.4), (x * (s / 2 - 0.03), s / 2 - 0.02, SEAT_H + 0.15), leg, rot=C.rot_x(-8))
    mb.box((s - 0.06, 0.02, 0.02), (0, -(s / 2 - 0.03), 0.12), leg)
    root = mb.to_object("BreakChair")
    C.col_box("BreakChair-col", (s, s, SEAT_H), (0, 0, SEAT_H / 2), root)
    C.col_box("BreakChairBack-col", (s, 0.06, 0.42), (0, s / 2 - 0.02, SEAT_H + 0.21), root)
    C.export(root, "break_chair.glb")


def bench():
    C.reset()
    wood = C.mat("bench_wood", "#B08A5A", rough=0.75)
    leg = frame_mat()
    mb = C.MB()
    L, dpt = 1.5, 0.4
    for i in range(3):
        mb.box((L, 0.115, 0.035), (0, -dpt / 2 + 0.065 + i * 0.135, SEAT_H - 0.0175), wood, bevel=0.006)
    for x in (-1, 1):
        mb.box((0.05, dpt - 0.04, 0.04), (x * (L / 2 - 0.15), 0, SEAT_H - 0.055), leg)
        for y in (-1, 1):
            mb.box((0.05, 0.05, SEAT_H - 0.075), (x * (L / 2 - 0.15), y * (dpt / 2 - 0.06), (SEAT_H - 0.075) / 2),
                   leg, drop=("-Z",))
    mb.box((L - 0.3, 0.03, 0.03), (0, 0, 0.14), leg)
    root = mb.to_object("Bench")
    C.col_box("Bench-col", (L, dpt, SEAT_H), (0, 0, SEAT_H / 2), root)
    C.export(root, "bench.glb")


def vending_machine():
    C.reset()
    body = C.mat("vend_body", "#C8322A", rough=0.5)
    dark = C.mat("vend_dark", "#2B2D30", rough=0.5)
    glass = C.mat("vend_glass", "#8FB4C8", rough=0.1, emission="#CFE6F0", strength=0.35)
    shelf = C.mat("vend_shelf", "#B9BDC1", rough=0.4, metal=0.6)
    items = [C.mat(f"vend_item_{i}", c, rough=0.6) for i, c in
             enumerate(("#F2C230", "#2F5FB0", "#5F8F3A", "#E8822A", "#EDEDED"))]
    mb = C.MB()
    w, d, h = 0.9, 0.8, 1.85
    mb.box((w, d, h), (0, 0, h / 2), body, bevel=0.02, drop=("-Z",))
    gx, gw, gz0, gh = -0.08, 0.6, 0.55, 1.15
    fy = -d / 2                                       # front face; the display sits proud of it
    mb.box((gw + 0.06, 0.09, gh + 0.06), (gx, fy - 0.04, gz0 + gh / 2), dark)     # frame
    mb.box((gw, 0.01, gh), (gx, fy - 0.09, gz0 + gh / 2), glass)                  # lit back
    for r in range(4):
        z = gz0 + 0.06 + r * 0.28
        mb.box((gw - 0.02, 0.07, 0.012), (gx, fy - 0.125, z), shelf)
        for k in range(5):
            mb.box((0.08, 0.05, 0.13), (gx - 0.22 + k * 0.11, fy - 0.125, z + 0.071), items[(r + k) % 5])
    mb.box((0.18, 0.02, 0.5), (0.32, -d / 2 - 0.01, 1.3), dark)                 # keypad panel
    mb.box((0.5, 0.03, 0.16), (gx, -d / 2 - 0.01, 0.28), dark)                  # pickup flap
    mb.box((0.95, 0.02, 0.14), (0, -d / 2 - 0.006, h - 0.1), C.mat("vend_sign", "#F4F3EE", rough=0.6,
                                                                        emission="#FFFFFF", strength=0.4))
    root = mb.to_object("VendingMachine")
    C.col_box("VendingMachine-col", (w, d + 0.14, h), (0, -0.07, h / 2), root)
    C.export(root, "vending_machine.glb")


def water_cooler():
    C.reset()
    body = C.mat("cooler_body", "#EDEDED", rough=0.6)
    dark = C.mat("cooler_dark", "#5A5F66", rough=0.5)
    water = C.mat("cooler_bottle", "#5AA0D8", rough=0.1, metal=0.0)
    tap_r = C.mat("cooler_tap_hot", "#C8322A", rough=0.5)
    tap_b = C.mat("cooler_tap_cold", "#2F5FB0", rough=0.5)
    mb = C.MB()
    s, h = 0.32, 1.0
    mb.box((s, s, h), (0, 0, h / 2), body, bevel=0.015, drop=("-Z",))
    mb.box((0.2, 0.02, 0.14), (0, -s / 2 - 0.005, 0.8), dark)
    mb.box((0.03, 0.03, 0.04), (-0.05, -s / 2 - 0.02, 0.78), tap_r)
    mb.box((0.03, 0.03, 0.04), (0.05, -s / 2 - 0.02, 0.78), tap_b)
    mb.box((0.2, 0.08, 0.02), (0, -s / 2 - 0.03, 0.66), dark)
    mb.cyl(0.13, 0.32, (0, 0, h), water, segs=10)
    mb.cyl(0.13, 0.06, (0, 0, h + 0.32), water, segs=10, r2=0.05)
    root = mb.to_object("WaterCooler")
    C.col_box("WaterCooler-col", (s, s, h + 0.38), (0, 0, (h + 0.38) / 2), root)
    C.export(root, "water_cooler.glb")


def trash_bin():
    C.reset()
    body = C.mat("bin_body", "#5F8F3A", rough=0.6)
    lid = C.mat("bin_lid", "#3C4046", rough=0.5)
    mb = C.MB()
    r, h = 0.22, 0.7
    mb.cyl(r * 0.9, h, (0, 0, 0), body, segs=12, r2=r)
    mb.cyl(r + 0.015, 0.05, (0, 0, h), lid, segs=12, r2=r)
    mb.cyl(r * 0.85, 0.08, (0, 0, h + 0.05), lid, segs=12, r2=r * 0.5)
    mb.box((0.12, 0.02, 0.02), (0, 0, h + 0.135), lid)
    root = mb.to_object("TrashBin")
    C.col_box("TrashBin-col", (2 * r, 2 * r, h + 0.13), (0, 0, (h + 0.13) / 2), root)
    C.export(root, "trash_bin.glb")


def wet_floor_sign():
    C.reset()
    yel = C.mat("sign_yellow", "#F2C230", rough=0.45, double_sided=True)
    black = C.mat("sign_black", "#2B2D30", rough=0.6)
    mb = C.MB()
    w, h, tilt = 0.3, 0.62, 14
    for s in (-1, 1):
        M = C.Matrix.Translation((0, s * h * 0.2419, 0)) @ C.rot_x(s * tilt)
        mb.xform = M
        mb.box((w, 0.012, h), (0, 0, h / 2), yel, bevel=0.004)
        # warning triangle + text bar on the outside face
        mb.poly([(-0.08, s * 0.007, 0.3), (0.08, s * 0.007, 0.3), (0.0, s * 0.007, 0.44)],
                [(2, 1, 0) if s > 0 else (0, 1, 2)], black)
        mb.box((0.2, 0.004, 0.035), (0, s * 0.008, 0.2), black)
        mb.box((0.16, 0.004, 0.025), (0, s * 0.008, 0.14), black)
    mb.xform = C.Matrix.Identity(4)
    mb.box((0.04, 0.05, 0.03), (0, 0, h * 0.975), yel)
    root = mb.to_object("WetFloorSign")
    C.col_box("WetFloorSign-col", (w, 0.32, h), (0, 0, h / 2), root)
    C.export(root, "wet_floor_sign.glb")


def toolbox():
    C.reset()
    red = C.mat("toolbox_red", "#C8322A", rough=0.45, metal=0.2)
    dark = C.mat("toolbox_dark", "#2B2D30", rough=0.5)
    steel = C.mat("toolbox_steel", "#B9BDC1", rough=0.3, metal=0.8)
    mb = C.MB()
    w, d, h = 0.5, 0.22, 0.2
    mb.box((w, d, h * 0.7), (0, 0, h * 0.35), red, bevel=0.008, drop=("-Z",))
    mb.box((w + 0.006, d + 0.006, h * 0.3), (0, 0, h * 0.85), red, bevel=0.008)
    mb.box((w + 0.008, d + 0.008, 0.008), (0, 0, h * 0.7), dark)
    for x in (-0.17, 0.17):
        mb.box((0.04, 0.012, 0.04), (x, -d / 2 - 0.006, h * 0.7), steel)
    for x in (-0.12, 0.12):
        mb.box((0.02, 0.02, 0.05), (x, 0, h + 0.025), dark)
    mb.box((0.28, 0.03, 0.025), (0, 0, h + 0.06), dark, bevel=0.006)
    root = mb.to_object("Toolbox")
    C.col_box("Toolbox-col", (w, d, h), (0, 0, h / 2), root)
    C.export(root, "toolbox.glb")


def main():
    for f in (coffee_machine, break_table, break_chair, bench, vending_machine, water_cooler,
              trash_bin, wet_floor_sign, toolbox):
        f()


if __name__ == "__main__":
    main()
