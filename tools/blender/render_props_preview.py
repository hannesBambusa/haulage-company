"""Render a lineup of all prop glbs (Eevee, warm sun, high 3/4 ortho) to docs/previews/props.png.

Run: Blender -b --factory-startup --python tools/blender/render_props_preview.py
"""
import math
import os
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402

OUT = os.path.join(C.PROJECT, "docs", "previews", "props.png")

ROWS = [
    ["wall_segment", "wall_corner", "dock_door", "dock_canopy", "office_booth", "lamp_post",
     "cctv_pole"],
    ["rack_bay", "rack_bay_loaded", "tree_cone_a", "tree_cone_b", "tree_round", "fence_segment",
     "fence_post"],
    ["pallet", "pallet_boxes_a", "pallet_boxes_b", "pallet_boxes_c", "box_single",
     "pallet_stack_empty", "bollard", "jersey_barrier", "office_desk"],
]
GAP = 1.0


def import_glb(name):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(C.MODELS, name + ".glb"))
    new = [o for o in bpy.data.objects if o not in before]
    roots = [o for o in new if o.parent is None]
    for o in new:
        if "-col" in o.name:
            o.hide_render = True
    lo = Vector((1e9,) * 3)
    hi = Vector((-1e9,) * 3)
    bpy.context.view_layer.update()
    for o in new:
        if o.type == "MESH" and "-col" not in o.name:
            for c in o.bound_box:
                w = o.matrix_world @ Vector(c)
                lo = Vector(map(min, lo, w))
                hi = Vector(map(max, hi, w))
    return roots, lo, hi


def main():
    C.reset()
    scn = bpy.context.scene
    y = 0.0
    all_lo = Vector((1e9,) * 3)
    all_hi = Vector((-1e9,) * 3)
    for row in ROWS:
        x = 0.0
        depth = 0.0
        for name in row:
            roots, lo, hi = import_glb(name)
            off = Vector((x - lo.x, y - hi.y, 0))
            for r in roots:
                r.location += off
            x += (hi.x - lo.x) + GAP
            depth = max(depth, hi.y - lo.y)
            all_lo = Vector(map(min, all_lo, lo + off))
            all_hi = Vector(map(max, all_hi, hi + off))
        y -= depth + GAP * 1.5
    # ground
    bpy.ops.mesh.primitive_plane_add(size=1, location=((all_lo.x + all_hi.x) / 2,
                                                       (all_lo.y + all_hi.y) / 2, -0.001))
    g = bpy.context.active_object
    g.scale = (all_hi.x - all_lo.x + 120, all_hi.y - all_lo.y + 120, 1)
    g.data.materials.append(C.mat("preview_ground", "#8E8C86", rough=0.95))
    # sun
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 4.0
    sun.color = (1.0, 0.9, 0.75)
    sun.angle = math.radians(3)
    so = bpy.data.objects.new("Sun", sun)
    so.rotation_euler = (math.radians(50), 0, math.radians(-35))
    scn.collection.objects.link(so)
    world = bpy.data.worlds.new("W") if not scn.world else scn.world
    scn.world = world
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (0.55, 0.62, 0.72, 1)
    bg.inputs["Strength"].default_value = 0.9
    # camera: ortho, high 3/4 from front-left
    cam = bpy.data.cameras.new("Cam")
    cam.type = "ORTHO"
    co = bpy.data.objects.new("Cam", cam)
    scn.collection.objects.link(co)
    center = (all_lo + all_hi) / 2
    center.z = 1.5
    d = Vector((-0.32, -1.0, 1.0)).normalized()
    co.location = center + d * 80
    co.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    cam.clip_end = 300
    scn.camera = co
    r = scn.render
    r.resolution_x, r.resolution_y = 2400, 1350
    # fit: project every visible bbox corner into camera space, recentre and size the ortho box
    bpy.context.view_layer.update()
    inv = co.matrix_world.inverted()
    pts = []
    for o in scn.objects:
        if o.type == "MESH" and o is not g and not o.hide_render:
            pts += [inv @ (o.matrix_world @ Vector(c)) for c in o.bound_box]
    xs = [p.x for p in pts]
    ys = [p.y for p in pts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    co.location = co.matrix_world @ Vector((cx, cy, 0))
    aspect = r.resolution_x / r.resolution_y
    cam.ortho_scale = max(max(xs) - min(xs), (max(ys) - min(ys)) * aspect) * 1.04
    r.engine = "BLENDER_EEVEE"
    r.film_transparent = False
    scn.view_settings.view_transform = "AgX" if "AgX" in [
        i.identifier for i in scn.view_settings.bl_rna.properties["view_transform"].enum_items] else "Standard"
    try:
        scn.eevee.use_shadows = True
        scn.eevee.use_gtao = True
    except AttributeError:
        pass
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    r.filepath = OUT
    bpy.ops.render.render(write_still=True)
    print("[props] preview", OUT)


if __name__ == "__main__":
    main()
