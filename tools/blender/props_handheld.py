"""Handheld worker props + the mop bucket. Each prop is its own small glb.

Grip convention (shared with build_worker_anims.Solver.prop_offset):
  origin  = centre of the fist (the worker's hand box centre)
  +Y (Blender) = grip axis, out of the pinky side of the fist   -> Godot -Z
  +Z (Blender) = along the hand, wrist -> knuckles               -> Godot +Y
  +X = Y x Z: the back of the right hand / the palm of the left hand.
Attach to BoneAttachment3D(Hand_R or Hand_L) with the offsets printed by
build_worker.py ("PROP OFFSET ...").

prop_bucket is a floor prop (origin at the floor, front -Y like the other props).
Run: Blender -b --factory-startup --python tools/blender/props_handheld.py
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402

AXIS_Y = C.rot_x(-90)   # cylinders are built along +Z; this turns them to +Y


def shaft(mb, r, y0, y1, m, segs=6):
    mb.cyl(r, y1 - y0, (0, y0, 0), m, segs=segs, rot=AXIS_Y)


def broom():
    C.reset()
    wood = C.mat("broom_handle", "#3A7BC8", rough=0.5)
    head = C.mat("broom_head", "#2B2D30", rough=0.7)
    bristle = C.mat("broom_bristle", "#D9A441", rough=0.9)
    mb = C.MB()
    shaft(mb, 0.014, -0.14, 1.07, wood)
    # push-broom head: wide block across the shaft (along X), bristles below
    mb.box((0.36, 0.05, 0.07), (0, 1.07, 0), head, bevel=0.006)
    mb.box((0.34, 0.07, 0.06), (0, 1.13, 0), bristle)
    # brace from the shaft to the block
    mb.box((0.012, 0.1, 0.012), (0.07, 1.02, 0), head, rot=C.rot_z(-35))
    mb.box((0.012, 0.1, 0.012), (-0.07, 1.02, 0), head, rot=C.rot_z(35))
    root = mb.to_object("PropBroom")
    C.export(root, "prop_broom.glb")


def mop():
    C.reset()
    pole = C.mat("mop_handle", "#C9CDD2", rough=0.35, metal=0.6)
    clamp = C.mat("mop_clamp", "#2F5FB0", rough=0.5)
    yarn = C.mat("mop_yarn", "#EDEBE4", rough=0.95)
    mb = C.MB()
    shaft(mb, 0.013, -0.13, 1.0, pole)
    mb.cyl(0.03, 0.05, (0, 0.98, 0), clamp, segs=8, rot=AXIS_Y)
    # strands: a flared skirt and a squashed bottom ring
    mb.cyl(0.04, 0.09, (0, 1.02, 0), yarn, segs=8, r2=0.11, caps=False, rot=AXIS_Y)
    mb.cyl(0.11, 0.025, (0, 1.105, 0), yarn, segs=8, r2=0.095, rot=AXIS_Y)
    root = mb.to_object("PropMop")
    C.export(root, "prop_mop.glb")


def coffee_cup():
    C.reset()
    paper = C.mat("cup_paper", "#F4F3EE", rough=0.8)
    sleeve = C.mat("cup_sleeve", "#A87443", rough=0.9)
    lid = C.mat("cup_lid", "#EDEDED", rough=0.5)
    mb = C.MB()
    cx = -0.052          # beside the palm (right hand palm faces -X)
    # cup axis along Y: bottom at +Y (pinky side), lid at -Y (thumb side)
    mb.cyl(0.032, 0.11, (cx, 0.05, 0), paper, segs=10, r2=0.042, rot=C.rot_x(90))
    mb.cyl(0.0385, 0.04, (cx, 0.015, 0), sleeve, segs=10, r2=0.0415, caps=False, rot=C.rot_x(90))
    mb.cyl(0.045, 0.012, (cx, -0.06, 0), lid, segs=10, r2=0.04, rot=C.rot_x(90))
    root = mb.to_object("PropCoffeeCup")
    C.export(root, "prop_coffee_cup.glb")


def clipboard():
    """Left hand: board rests on the forearm (toward -Z), face up = palm side (+X)."""
    C.reset()
    board = C.mat("clip_board", "#9C6B3C", rough=0.7)
    paper = C.mat("paper", "#EEEDE8", rough=0.9)
    clip = C.mat("clip_metal", "#C9CDD2", rough=0.3, metal=0.8)
    ink = C.mat("clip_ink", "#4A5160", rough=0.9)
    mb = C.MB()
    bx = 0.034
    mb.box((0.01, 0.23, 0.31), (bx, 0, -0.135), board)
    mb.box((0.003, 0.2, 0.26), (bx + 0.0065, 0, -0.15), paper)
    for i in range(4):
        mb.box((0.002, 0.14 - 0.03 * (i % 2), 0.008), (bx + 0.009, 0.0, -0.08 - 0.045 * i), ink)
    mb.box((0.02, 0.1, 0.035), (bx + 0.012, 0, -0.012), clip, bevel=0.004)
    root = mb.to_object("PropClipboard")
    C.export(root, "prop_clipboard.glb")


def scanner():
    """Pistol-grip barcode scanner: handle in the fist, nose along +Z, top at -Y."""
    C.reset()
    body = C.mat("scanner_body", "#2B2D30", rough=0.5)
    accent = C.mat("scanner_yellow", "#F2C230", rough=0.45)
    lens = C.mat("scanner_lens", "#E0302A", rough=0.2, emission="#FF3020", strength=2.0)
    mb = C.MB()
    mb.box((0.032, 0.11, 0.042), (0, 0.005, -0.004), body, bevel=0.006)
    mb.box((0.046, 0.05, 0.17), (0, -0.07, 0.04), accent, bevel=0.008)
    mb.box((0.05, 0.06, 0.03), (0, -0.07, 0.135), body, bevel=0.006)
    mb.box((0.036, 0.04, 0.004), (0, -0.07, 0.151), lens)
    mb.box((0.012, 0.012, 0.03), (0, -0.033, 0.035), body)   # trigger
    root = mb.to_object("PropScanner")
    C.export(root, "prop_scanner.glb")


def phone():
    """Right hand at the ear: long axis on the grip axis, screen toward the palm (-X)."""
    C.reset()
    case = C.mat("phone_case", "#1E1F21", rough=0.4)
    screen = C.mat("phone_screen", "#3F6E9A", rough=0.15, emission="#3F6E9A", strength=0.6)
    mb = C.MB()
    mb.box((0.011, 0.15, 0.072), (-0.034, 0.012, 0.012), case, bevel=0.004)
    mb.box((0.002, 0.13, 0.062), (-0.0405, 0.012, 0.012), screen)
    root = mb.to_object("PropPhone")
    C.export(root, "prop_phone.glb")


def wrench():
    """Handle along Y, open-end head beyond the thumb (-Y), flat in the YZ plane."""
    C.reset()
    steel = C.mat("wrench_steel", "#B9BDC1", rough=0.3, metal=0.85)
    grip = C.mat("wrench_grip", "#C8322A", rough=0.7)
    mb = C.MB()
    mb.box((0.012, 0.22, 0.026), (0, -0.04, 0), steel, bevel=0.003)
    mb.box((0.02, 0.11, 0.034), (0, 0.02, 0), grip, bevel=0.005)
    # open-end head: a ring segment from boxes around a 0.03 gap
    hy = -0.19
    mb.box((0.014, 0.03, 0.075), (0, hy + 0.035, 0), steel)
    for s in (-1, 1):
        mb.box((0.014, 0.05, 0.022), (0, hy - 0.005, s * 0.027), steel, rot=C.rot_x(s * 12))
    root = mb.to_object("PropWrench")
    C.export(root, "prop_wrench.glb")


def bucket():
    """Yellow mop bucket on castors with a grey wringer. Floor prop, front -Y."""
    C.reset()
    yel = C.mat("bucket_yellow", "#F2C230", rough=0.45)
    tub = C.mat("bucket_tub", "#F2C230", rough=0.45, double_sided=True)
    grey = C.mat("bucket_wringer", "#5A5F66", rough=0.5, metal=0.2)
    water = C.mat("bucket_water", "#7C9AA6", rough=0.1)
    tyre = C.mat("tyre", "#1E1F21", rough=0.9)
    mb = C.MB()
    w, d, h, z0 = 0.44, 0.34, 0.3, 0.07
    # tapered tub (open top)
    prof = [(-d / 2, 0.0), (d / 2, 0.0), (d / 2 + 0.02, h), (-d / 2 - 0.02, h)]
    verts = []
    for x in (-w / 2, w / 2):
        for y, z in prof:
            k = 1.0 + 0.06 * z / h
            verts.append((x * k, y, z0 + z))
    # 0..3 at -x, 4..7 at +x ; faces: bottom, sides, ends (no top)
    faces = [(0, 1, 5, 4), (1, 2, 6, 5), (3, 0, 4, 7), (0, 3, 2, 1), (4, 5, 6, 7)]
    mb.poly(verts, faces, tub)
    mb.box((w * 1.02, d * 1.02, 0.02), (0, 0, z0 + h * 0.62), water)
    mb.box((w + 0.06, d + 0.06, 0.03), (0, 0, z0 + h - 0.01), yel, drop=("-Z",))
    # wringer box on the +X end, handle bar on the -X end
    mb.box((0.17, d * 0.9, 0.2), (w / 2 - 0.08, 0, z0 + h + 0.09), grey, bevel=0.01)
    mb.box((0.03, 0.03, 0.32), (w / 2 - 0.03, 0, z0 + h + 0.33), grey)
    mb.box((0.03, 0.03, 0.22), (-w / 2 + 0.02, -d / 2 + 0.02, z0 + h + 0.1), yel)
    mb.box((0.03, 0.03, 0.22), (-w / 2 + 0.02, d / 2 - 0.02, z0 + h + 0.1), yel)
    mb.box((0.03, d, 0.03), (-w / 2 + 0.02, 0, z0 + h + 0.21), yel)
    for sx in (-1, 1):
        for sy in (-1, 1):
            mb.cyl(0.03, 0.025, (sx * (w / 2 - 0.05) - 0.0125, sy * (d / 2 - 0.04), 0.03), tyre,
                   segs=5, rot=C.rot_y(90))
    root = mb.to_object("PropBucket")
    C.col_box("PropBucket-col", (w + 0.06, d + 0.06, 0.62), (0, 0, 0.31), root)
    C.export(root, "prop_bucket.glb")


def main():
    for f in (broom, mop, coffee_cup, clipboard, scanner, phone, wrench, bucket):
        f()


if __name__ == "__main__":
    main()
