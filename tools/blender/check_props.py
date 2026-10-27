"""Re-open every prop glb and print root, bbox dims (visual meshes), tri counts, budgets.

Run: Blender -b --factory-startup --python tools/blender/check_props.py
Exits 1 if a file is missing or over budget.
"""
import json
import os
import struct
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402

PROPS = [
    "pallet", "pallet_boxes_a", "pallet_boxes_b", "pallet_boxes_c", "box_single",
    "pallet_stack_empty", "rack_bay", "rack_bay_loaded", "wall_segment", "wall_corner",
    "dock_door", "dock_canopy", "bollard", "jersey_barrier", "fence_segment", "fence_post",
    "tree_cone_a", "tree_cone_b", "tree_round", "office_booth", "lamp_post", "cctv_pole",
    "office_desk",
    # props_handheld.py (worker hand props + mop bucket)
    "prop_broom", "prop_mop", "prop_bucket", "prop_coffee_cup", "prop_clipboard", "prop_scanner",
    "prop_phone", "prop_wrench",
    # props_break.py
    "coffee_machine", "break_table", "break_chair", "bench", "vending_machine", "water_cooler",
    "trash_bin", "wet_floor_sign", "toolbox",
]
BREAK = {"coffee_machine", "break_table", "break_chair", "bench", "vending_machine", "water_cooler",
         "trash_bin", "wet_floor_sign", "toolbox"}


def budget(name):
    if name.startswith("prop_"):
        return 200
    if name in BREAK:
        return 600
    if name == "rack_bay_loaded":
        return 6000
    if name.startswith("tree_"):
        return 600
    if name.startswith("pallet_boxes"):
        return 800
    return 1500


def glb_json(path):
    with open(path, "rb") as f:
        f.read(12)
        ln, _ = struct.unpack("<II", f.read(8))
        return json.loads(f.read(ln))


def main():
    fails = []
    print(f"{'file':24} {'root':18} {'dims x*y*z (m, Blender Z-up)':30} {'tris':>6} {'col':>4} budget  extra")
    for name in PROPS:
        path = os.path.join(C.MODELS, name + ".glb")
        if not os.path.exists(path):
            fails.append(f"{name}: missing")
            print(f"{name:24} MISSING")
            continue
        C.reset()
        bpy.ops.import_scene.gltf(filepath=path)
        objs = list(bpy.context.scene.objects)
        roots = [o for o in objs if o.parent is None]
        lo = Vector((1e9,) * 3)
        hi = Vector((-1e9,) * 3)
        tris = 0
        col = 0
        for o in objs:
            if o.type != "MESH":
                continue
            me = o.data
            me.calc_loop_triangles()
            if "-col" in o.name:
                col += len(me.loop_triangles)
                continue
            tris += len(me.loop_triangles)
            for v in me.vertices:
                w = o.matrix_world @ v.co
                lo = Vector(map(min, lo, w))
                hi = Vector(map(max, hi, w))
        d = hi - lo
        js = glb_json(path)
        extra = []
        blend = [m["name"] for m in js.get("materials", []) if m.get("alphaMode") == "BLEND"]
        if blend:
            extra.append("BLEND:" + ",".join(blend))
        kids = sorted(o.name for o in objs if o.parent is not None)
        extra.append("children:" + ",".join(kids))
        ok = tris < budget(name)
        if not ok:
            fails.append(f"{name}: {tris} tris >= {budget(name)}")
        print(f"{name:24} {','.join(o.name for o in roots):18} "
              f"{d.x:6.3f} x {d.y:6.3f} x {d.z:6.3f}        {tris:6d} {col:4d} "
              f"<{budget(name):<5} {'OK ' if ok else 'OVER'} {' '.join(extra)}")
    if fails:
        print("FAIL:", fails)
        sys.exit(1)
    print("ALL OK")


if __name__ == "__main__":
    main()
