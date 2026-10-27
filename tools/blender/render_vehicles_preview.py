"""Preview renders of the vehicle/character glbs (Eevee, sun, 3/4 top view).

Writes docs/previews/vehicles.png (line-up) and docs/previews/compare_vehicles.png
(per-asset close-up on the left, matching crop of the reference on the right).
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_vehicles as cv  # noqa: E402

PREV = os.path.join(cv.PROJECT, "docs", "previews")
REF = os.path.join(cv.PROJECT, "docs", "reference", "gameplay-target.png")
TMP = os.path.join(PREV, "vehicles_closeups")
# camera looks from front-left, elevated like the reference
VIEW_DIR = Vector((0.62, -0.78, -0.95)).normalized()


def setup_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.render.engine = "BLENDER_EEVEE"
    scn.render.film_transparent = False
    scn.view_settings.view_transform = "Standard"  # closest to Godot defaults
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.55, 0.62, 0.72, 1)
    bg.inputs["Strength"].default_value = 0.9
    scn.world = world
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 4.0
    sun.color = (1.0, 0.94, 0.85)
    sun.angle = math.radians(3)
    so = bpy.data.objects.new("Sun", sun)
    so.rotation_euler = (math.radians(50), 0, math.radians(-35))
    scn.collection.objects.link(so)
    bpy.ops.mesh.primitive_plane_add(size=200)
    g = bpy.context.active_object
    gm = bpy.data.materials.new("ground")
    gm.use_nodes = True
    n = gm.node_tree.nodes["Principled BSDF"]
    n.inputs["Base Color"].default_value = cv.hex_rgba("#8C8984")
    n.inputs["Roughness"].default_value = 0.9
    g.data.materials.append(gm)
    cam = bpy.data.cameras.new("Cam")
    cam.type = "ORTHO"
    co = bpy.data.objects.new("Cam", cam)
    scn.collection.objects.link(co)
    scn.camera = co
    return scn, co


def load(name, offset=(0, 0, 0), rot_z=0.0):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(cv.MODELS, name))
    new = [o for o in bpy.data.objects if o not in before]
    for o in [o for o in new if o.name.startswith("Icosphere")]:  # importer bone shape
        new.remove(o)
        bpy.data.objects.remove(o)
    roots = [o for o in new if o.parent is None]
    for r in roots:
        r.location = Vector(offset)
        r.rotation_euler = (0, 0, math.radians(rot_z))
    bpy.context.view_layer.update()
    return roots[0], new


def couple(cab_root, trailer_root):
    """Move the trailer so its Kingpin sits on the cab's FifthWheel."""
    bpy.context.view_layer.update()
    fw = next(o for o in cab_root.children if o.name.startswith("FifthWheel"))
    kp = next(o for o in trailer_root.children if o.name.startswith("Kingpin"))
    trailer_root.location += fw.matrix_world.translation - kp.matrix_world.translation
    bpy.context.view_layer.update()


def pose(objs, action_key, frame):
    for o in objs:
        if o.type == "ARMATURE":
            act = next(a for a in bpy.data.actions if action_key in a.name)
            o.animation_data_create()
            o.animation_data.action = act
            if act.slots:
                o.animation_data.action_slot = act.slots[0]
    bpy.context.scene.frame_set(frame)


def frame_camera(cam, objs, res, margin=1.12):
    bpy.context.view_layer.update()
    pts = []
    for o in objs:
        if o.type == "MESH":
            pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
    center = sum(pts, Vector()) / len(pts)
    cam.location = center - VIEW_DIR * 60
    cam.rotation_euler = VIEW_DIR.to_track_quat("-Z", "Y").to_euler()
    bpy.context.view_layer.update()
    inv = cam.matrix_world.inverted()
    loc = [inv @ p for p in pts]
    w = max(p.x for p in loc) - min(p.x for p in loc)
    h = max(p.y for p in loc) - min(p.y for p in loc)
    cam.data.ortho_scale = max(w, h * res[0] / res[1]) * margin
    cam.data.clip_end = 200


def render(path, res):
    scn = bpy.context.scene
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.resolution_percentage = 100
    scn.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("RENDERED", path)


def read_px(path):
    im = bpy.data.images.load(path)
    w, h = im.size
    px = np.array(im.pixels[:], dtype=np.float32).reshape(h, w, 4)[::-1]
    bpy.data.images.remove(im)
    return px


def fit(px, h):
    """Nearest-neighbour resize to height h."""
    sh, sw = px.shape[:2]
    w = max(1, int(sw * h / sh))
    yi = (np.arange(h) * sh / h).astype(int)
    xi = (np.arange(w) * sw / w).astype(int)
    return px[yi][:, xi]


def write_px(px, path):
    h, w = px.shape[:2]
    im = bpy.data.images.new("out", w, h, alpha=True)
    im.pixels[:] = px[::-1].ravel()
    im.filepath_raw = path
    im.file_format = "PNG"
    im.save()
    print("WROTE", path)


# per-asset close-ups: (label, loader, ref crop box x0,y0,x1,y1 in reference px)
def red_rig():
    c, a = load("truck_cab_red.glb")
    t, b = load("trailer_box.glb")
    couple(c, t)
    return a + b


def blue_rig():
    c, a = load("truck_cab_blue.glb")
    t, b = load("trailer_box.glb")
    couple(c, t)
    return a + b


def fork_rig():
    return load("forklift.glb")[1]


def jack_rig():
    return load("pallet_jack.glb")[1]


def worker_rig(name="worker.glb"):
    objs = load(name)[1]
    pose(objs, "Walk", 8)
    return objs


def bluehat_rig():
    return worker_rig("worker_bluehat.glb")


def red_cab():
    return load("truck_cab_red.glb")[1]


def blue_cab():
    return load("truck_cab_blue.glb")[1]


CLOSEUPS = [
    ("red_cab", red_cab, (225, 630, 365, 785)),
    ("blue_cab", blue_cab, (970, 600, 1110, 775)),
    ("red", red_rig, (220, 480, 600, 790)),
    ("blue", blue_rig, (960, 470, 1220, 780)),
    ("forklift", fork_rig, (590, 270, 700, 390)),
    ("jack", jack_rig, (770, 340, 860, 420)),
    ("worker", worker_rig, (950, 190, 1000, 265)),
    ("worker_bluehat", bluehat_rig, (1010, 440, 1100, 530)),
]


def main():
    os.makedirs(TMP, exist_ok=True)
    # line-up
    scn, cam = setup_scene()
    side = Vector((0.78, 0.62, 0))  # perpendicular to the view, left to right
    objs = []
    objs += red_rig()
    cab, b = load("truck_cab_blue.glb", side * 6.5)
    objs += b
    for name, d in (("forklift.glb", 11.0), ("pallet_jack.glb", 13.5)):
        objs += load(name, side * d - Vector((0, 6, 0)))[1]
    objs += load("trailer_box.glb", side * 6.5 - Vector((0, 11, 0)))[1]
    w = load("worker.glb", side * 15.5 - Vector((0, 6, 0)))[1]
    pose(w, "Walk", 8)
    objs += w
    w = load("worker_bluehat.glb", side * 16.5 - Vector((0, 6, 0)))[1]
    pose(w, "Walk", 20)
    objs += w
    frame_camera(cam, objs, (1600, 900), margin=1.05)
    render(os.path.join(PREV, "vehicles.png"), (1600, 900))

    # comparison sheet
    ref = read_px(REF)
    rows = []
    H = 360
    for label, rig, (x0, y0, x1, y1) in CLOSEUPS:
        scn, cam = setup_scene()
        o = rig()
        frame_camera(cam, o, (480, 400))
        p = os.path.join(TMP, f"{label}.png")
        render(p, (480, 400))
        left = fit(read_px(p), H)
        right = fit(ref[y0:y1, x0:x1], H)
        gap = np.ones((H, 8, 4), dtype=np.float32)
        rows.append(np.concatenate([left, gap, right], axis=1))
    width = max(r.shape[1] for r in rows)
    pad = [np.concatenate([r, np.ones((H, width - r.shape[1], 4), np.float32)], axis=1)
           for r in rows]
    sheet = np.concatenate([np.concatenate([r, np.ones((8, width, 4), np.float32)])
                            for r in pad])
    write_px(sheet, os.path.join(PREV, "compare_vehicles.png"))


main()
