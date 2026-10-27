"""Contact sheet of every worker action at its key pose, props attached, labelled.

Writes docs/previews/worker_actions.png (3/4 high ortho view) and
docs/previews/walk_cycle.png (8 frames of Walk, side view, plus Carry / PushJack rows).
Props are placed with Solver.prop_offset (the same grip matrix the build reports for
Godot), so a prop that floats here floats in game too.

Run: Blender -b --factory-startup --python tools/blender/render_worker_actions.py [-- only=Name,Name]
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_worker as bw  # noqa: E402
import build_worker_anims as wa  # noqa: E402
import common_vehicles as cv  # noqa: E402

PREV = os.path.join(cv.PROJECT, "docs", "previews")
ORDER = ["Idle", "Walk", "Carry", "PushJack", "Sweep", "Mop", "DrinkCoffee", "Talk", "Listen",
         "Laugh", "SitIdle", "Clipboard", "ScanPallet", "Inspect", "Stretch", "Wave", "PhoneCall",
         "Wrench"]
SHEET_VIEW = Vector((-0.35, 0.95, -0.95))     # camera look direction for the sheet
SHEET_YAW = 245.0                              # worker yaw: 3/4 front-side toward the camera
KEY = dict(wa.spec_key_frames, Idle=0.5)
SCENERY = {  # action: [(glb, location, z rotation deg, uniform scale)]
    "PushJack": [("pallet_jack.glb", (0, 1.05 / 1.2, 0), 0, 1 / 1.2)],
    "SitIdle": [("break_chair.glb", (0, 0, 0), 180, 1.0)],
    "Mop": [("prop_bucket.glb", (-0.75, 0.45, 0), 20, 1.0)],
    "ScanPallet": [("pallet_boxes_a.glb", (0.0, 1.35, 0), 0, 1.0)],
    "Inspect": [("pallet_boxes_a.glb", (0.0, 1.25, 0), 0, 1.0)],
    "Wrench": [("toolbox.glb", (-0.55, 0.3, 0), 15, 1.0)],
    "Carry": [],
}


def import_glb(name, loc=(0, 0, 0), rz=0.0, scale=1.0):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(cv.MODELS, name))
    new = [o for o in bpy.data.objects if o not in before]
    for o in new:
        if "-col" in o.name:
            o.hide_render = True
    roots = [o for o in new if o.parent is None]
    for r in roots:
        r.matrix_world = (Matrix.Translation(Vector(loc)) @ Matrix.Rotation(math.radians(rz), 4, "Z")
                          @ Matrix.Scale(scale, 4) @ r.matrix_world)
    return roots


def pose_copy(rig, mesh, action, frame, offset, yaw=0.0):
    """Duplicate rig + mesh at offset, posed at action/frame (static pose, no animation)."""
    rig.animation_data.action = bpy.data.actions[action]
    bpy.context.scene.frame_set(frame)
    basis = {pb.name: pb.matrix_basis.copy() for pb in rig.pose.bones}
    r2 = rig.copy()
    bpy.context.scene.collection.objects.link(r2)
    r2.animation_data_clear()
    r2.parent = None
    r2.matrix_world = Matrix.Translation(Vector(offset)) @ Matrix.Rotation(math.radians(yaw), 4, "Z")
    m2 = mesh.copy()
    bpy.context.scene.collection.objects.link(m2)
    m2.parent = r2
    m2.matrix_parent_inverse = Matrix.Identity(4)
    m2.matrix_world = r2.matrix_world.copy()
    m2.modifiers["Armature"].object = r2
    m2.hide_render = False
    for n, b in basis.items():
        r2.pose.bones[n].matrix_basis = b
    rig.animation_data.action = None
    bpy.context.view_layer.update()
    return r2


def attach(sv, r2, side, prop):
    roots = import_glb(prop + ".glb")
    bpy.context.view_layer.update()
    M = r2.matrix_world @ r2.pose.bones["Hand_" + side].matrix @ sv.prop_offset(side)
    for r in roots:
        r.matrix_world = M @ r.matrix_world
    return roots


def label(text, loc, cam_rot, size=0.2):
    cu = bpy.data.curves.new("L_" + text, "FONT")
    cu.body = text
    cu.size = size
    cu.align_x = "CENTER"
    ob = bpy.data.objects.new("L_" + text, cu)
    bpy.context.scene.collection.objects.link(ob)
    ob.location = loc
    ob.rotation_euler = cam_rot
    m = bpy.data.materials.get("label") or bpy.data.materials.new("label")
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (0.02, 0.02, 0.03, 1)
    b.inputs["Roughness"].default_value = 1.0
    cu.materials.append(m)
    return ob


def setup_world():
    scn = bpy.context.scene
    scn.render.engine = "BLENDER_EEVEE"
    scn.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.55, 0.62, 0.72, 1)
    bg.inputs["Strength"].default_value = 0.9
    scn.world = world
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 4.0
    sun.angle = math.radians(3)
    so = bpy.data.objects.new("Sun", sun)
    so.rotation_euler = (math.radians(45), 0, math.radians(200))
    scn.collection.objects.link(so)
    bpy.ops.mesh.primitive_plane_add(size=400, location=(0, 0, -0.001))
    g = bpy.context.active_object
    gm = bpy.data.materials.new("ground")
    gm.use_nodes = True
    gm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = cv.hex_rgba("#8E8C86")
    g.data.materials.append(gm)
    return scn, g


def camera(scn, view_dir, objs, res, margin=1.05):
    cam = bpy.data.cameras.new("Cam")
    cam.type = "ORTHO"
    co = bpy.data.objects.new("Cam", cam)
    scn.collection.objects.link(co)
    scn.camera = co
    d = Vector(view_dir).normalized()
    co.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    co.location = -d * 60
    cam.clip_end = 300
    scn.render.resolution_x, scn.render.resolution_y = res
    bpy.context.view_layer.update()
    inv = co.matrix_world.inverted()
    pts = []
    dg = bpy.context.evaluated_depsgraph_get()
    for o in objs:
        if o.type in ("MESH", "FONT") and not o.hide_render:
            oe = o.evaluated_get(dg)
            pts += [inv @ (oe.matrix_world @ Vector(c)) for c in oe.bound_box]
    xs, ys = [p.x for p in pts], [p.y for p in pts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    co.location = co.matrix_world @ Vector((cx, cy, 0))
    aspect = res[0] / res[1]
    cam.ortho_scale = max(max(xs) - min(xs), (max(ys) - min(ys)) * aspect) * margin
    return co


def render(path):
    scn = bpy.context.scene
    scn.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("WROTE", path)


def contact_sheet(rig, mesh, sv, only=None):
    names = [n for n in ORDER if not only or n in only]
    cols = 6
    gap_x, gap_y = 2.3, 3.3
    made = []
    for i, n in enumerate(names):
        c, r = i % cols, i // cols
        look = Vector((SHEET_VIEW.x, SHEET_VIEW.y, 0)).normalized()
        right = Vector((look.y, -look.x, 0))
        off = right * (c * gap_x) - look * (r * gap_y)
        frames = sv_frames(n)
        f = int(round(KEY.get(n, 0.5) * frames))
        # the camera sits at -Y/+X above (SHEET_VIEW); yaw 200 turns the worker 3/4 toward it
        r2 = pose_copy(rig, mesh, n, f, off, yaw=SHEET_YAW)
        made.append(r2)
        spec = sv_props(sv, n, f)
        for side, prop in spec.items():
            attach(sv, r2, side, prop)
        if n == "Carry":   # stand-in box between the hands (Godot supplies the real load)
            bpy.ops.mesh.primitive_cube_add(size=1)
            bx = bpy.context.active_object
            bx.scale = (0.3, 0.32, 0.26)
            bx.matrix_world = r2.matrix_world @ Matrix.Translation((0, 0.42, 1.18)) @ Matrix.Diagonal((0.3, 0.32, 0.26, 1))
            bm = bpy.data.materials.new("stand_in_box")
            bm.use_nodes = True
            bm.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = cv.hex_rgba("#C89A5E")
            bx.data.materials.append(bm)
        for glb, loc, rz, sc in SCENERY.get(n, []):
            L = r2.matrix_world @ Vector(loc)
            import_glb(glb, L, SHEET_YAW + rz, sc)
        lab_rot = math.atan2(-right.y, -right.x) + math.pi
        label(f"{n}  f{f}", off - look * 1.0 + Vector((0, 0, 0.02)), (0, 0, lab_rot), 0.2)
    return made


def sv_frames(n):
    if n == "Idle":
        return 48
    table = dict(wa.GAIT, **wa.ACTIONS)
    return table[n][0]


def sv_props(sv, n, f):
    if n == "Idle":
        return {}
    table = dict(wa.GAIT, **wa.ACTIONS)
    frames, fn, loop, _ = table[n]
    return fn(sv, f / frames).get("props", {})


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    only = None
    out = None
    which = "both"
    for a in argv:
        if a.startswith("view="):
            globals()["SHEET_VIEW"] = Vector([float(v) for v in a[5:].split(",")])
        if a.startswith("yaw="):
            globals()["SHEET_YAW"] = float(a[4:])
        if a.startswith("out="):
            out = a[4:]
        if a.startswith("only="):
            only = a[5:].split(",")
        if a in ("sheet", "walk"):
            which = a
    root, rig, mesh, sv = bw.build_scene("hat_yellow")
    root.hide_render = True
    mesh.hide_render = True
    scn, ground = setup_world()
    if which in ("both", "sheet"):
        made = contact_sheet(rig, mesh, sv, only)
        objs = [o for o in scn.objects if o not in (ground, mesh) and o.type in ("MESH", "FONT")
                and not o.hide_render]
        camera(scn, SHEET_VIEW, objs, (2600, 1500) if not only or len(only) > 3 else (900, 900))
        render(out or os.path.join(PREV, "worker_actions.png"))
        for o in list(scn.objects):
            if o not in (ground, rig, mesh, root) and o.type not in ("LIGHT", "CAMERA"):
                bpy.data.objects.remove(o)
        for o in [o for o in scn.objects if o.type == "CAMERA"]:
            bpy.data.objects.remove(o)
    if which in ("both", "walk"):
        ground.hide_render = True
        floor = bpy.data.materials["ground"]
        rows = [("Walk", 0.0), ("Carry", -2.3), ("PushJack", -4.6)]
        for n, zrow in rows:
            bpy.ops.mesh.primitive_plane_add(size=1, location=(0, 4.0, zrow - 0.001))
            pl = bpy.context.active_object
            pl.scale = (1.6, 10.5, 1)
            pl.data.materials.append(floor)
            for i in range(8):
                f = int(round(i * wa.GAIT_FRAMES / 8))
                off = Vector((0, 1.15 * i, zrow))
                r2 = pose_copy(rig, mesh, n, f, off)
                for side, prop in sv_props(sv, n, f).items():
                    attach(sv, r2, side, prop)
                if n == "PushJack":
                    import_glb("pallet_jack.glb", r2.matrix_world @ Vector((0, 1.05 / 1.2, 0)), 0, 1 / 1.2)
                label(f"{n} f{f}", off + Vector((0.5, 0, 1.95)), (math.radians(90), 0, math.radians(90)), 0.13)
        objs = [o for o in scn.objects if o not in (ground, mesh) and o.type in ("MESH", "FONT")
                and not o.hide_render]
        camera(scn, Vector((-1.0, 0.0, -0.12)), objs, (2600, 1500))
        render(os.path.join(PREV, "walk_cycle.png"))


if __name__ == "__main__":
    main()
