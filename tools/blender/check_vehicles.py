"""Re-import each vehicle/character glb and print nodes, dims, tri counts, actions.

Worker files also get a per-action foot-contact check on the re-imported, evaluated
mesh: boot penetration below the floor, planted-boot slide against the expected
treadmill speed (FOOT_SPEED), and the hips height for SitIdle.

Usage: Blender -b --factory-startup --python check_vehicles.py [-- file.glb ...]
"""
import json
import math
import os
import struct
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_vehicles as cv  # noqa: E402

FILES = {
    "truck_cab_red.glb": 4000, "truck_cab_blue.glb": 4000, "trailer_box.glb": 3000,
    "forklift.glb": 3000, "pallet_jack.glb": 800, "worker.glb": 1500, "worker_bluehat.glb": 1500,
}


# m/s the planted foot moves backward (Godot moves the root at this speed); others 0
FOOT_SPEED = {"Walk": 1.3, "Carry": 1.3, "PushJack": 1.3, "Sweep": 0.2}
FPS = 24
SLIDE_TOL = 0.004     # m per frame
SINK_TOL = -0.004     # m below the floor
CONTACT_Z = 0.002     # a boot vertex this close to the floor counts as planted


def assign(arm, act):
    arm.animation_data.action = act
    ad = arm.animation_data
    if hasattr(ad, "action_slot") and ad.action_slot is None and len(act.slots):
        ad.action_slot = act.slots[0]


def foot_check(js):
    """Evaluate every action on the imported armature and measure the boots."""
    arm = next((o for o in bpy.context.scene.objects if o.type == "ARMATURE"), None)
    mesh = next((o for o in bpy.context.scene.objects if o.type == "MESH" and o.vertex_groups), None)
    if arm is None or mesh is None or "Foot_L" not in mesh.vertex_groups:
        return True
    arm.animation_data_create()
    groups = {s: mesh.vertex_groups["Foot_" + s].index for s in "LR"}
    vidx = {s: [v.index for v in mesh.data.vertices if any(g.group == gi for g in v.groups)]
            for s, gi in groups.items()}
    ok = True
    scn = bpy.context.scene
    scn.render.fps = FPS
    print("  foot contact (sink = lowest boot vertex, slide = planted boot drift per frame vs expected):")
    for a in js.get("animations", []):
        name = a["name"]
        act = bpy.data.actions.get(name) or next((x for x in bpy.data.actions if x.name.startswith(name)), None)
        if act is None:
            print(f"    {name:12s} action not found after import")
            ok = False
            continue
        assign(arm, act)
        f0, f1 = (int(round(x)) for x in act.frame_range)
        expect = FOOT_SPEED.get(name, 0.0) / FPS
        prev = {}
        sink, slide, planted = 0.0, 0.0, 0
        hips_z = []
        for f in range(f0, f1 + 1):
            scn.frame_set(f)
            dg = bpy.context.evaluated_depsgraph_get()
            me = mesh.evaluated_get(dg).to_mesh()
            mw = mesh.matrix_world
            for s in "LR":
                pts = [mw @ me.vertices[i].co for i in vidx[s]]
                low = min(p.z for p in pts)
                sink = min(sink, low)
                cur = {i: p for i, p in zip(vidx[s], pts) if p.z < CONTACT_Z}
                if s in prev and cur:
                    common = [i for i in cur if i in prev[s]]
                    if common:
                        planted += 1
                        for i in common:
                            d = cur[i] - prev[s][i]
                            slide = max(slide, math.hypot(d.x, d.y + expect))
                prev[s] = cur
            mesh.evaluated_get(dg).to_mesh_clear()
            hb = arm.pose.bones.get("Hips")
            if hb:
                hips_z.append((arm.matrix_world @ hb.head).z)
        good = sink > SINK_TOL and slide < SLIDE_TOL
        ok &= good
        extra = f" hips z {min(hips_z):.3f}..{max(hips_z):.3f}" if hips_z else ""
        print(f"    {name:12s} {(f1 - f0) / FPS:5.3f} s  sink={sink * 1000:+5.1f} mm  slide={slide * 1000:4.1f} mm/f"
              f" (expect {FOOT_SPEED.get(name, 0.0):.1f} m/s) planted-pairs={planted:3d}{extra}"
              f"  {'OK' if good else 'FAIL'}")
    return ok


def glb_json(path):
    with open(path, "rb") as f:
        f.read(12)
        ln, _typ = struct.unpack("<II", f.read(8))
        return json.loads(f.read(ln))


def check(name, budget):
    path = os.path.join(cv.MODELS, name)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    bpy.context.view_layer.update()
    js = glb_json(path)
    node_names = {n.get("name") for n in js["nodes"]}
    # the importer adds helper meshes (bone shapes) that are not in the file
    for o in list(bpy.context.scene.objects):
        if o.name not in node_names:
            bpy.data.objects.remove(o)
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    tris = 0
    print(f"=== {name}")
    for o in sorted(bpy.context.scene.objects, key=lambda o: o.name):
        par = o.parent.name if o.parent else "-"
        line = f"  {o.type:8s} {o.name:22s} parent={par:12s} loc=({o.matrix_world.translation.x:+.2f},{o.matrix_world.translation.y:+.2f},{o.matrix_world.translation.z:+.2f})"
        if o.type == "MESH":
            t = sum(len(p.vertices) - 2 for p in o.data.polygons)
            tris += t
            lo_o, hi_o = cv.world_bbox([o])
            line += f" tris={t} zmin={lo_o.z:.3f}"
        print(line)
    lo, hi = cv.world_bbox(meshes)
    d = hi - lo
    print(f"  bbox Blender  W(x)={d.x:.2f} L(y)={d.y:.2f} H(z)={d.z:.2f}  min=({lo.x:.2f},{lo.y:.2f},{lo.z:.2f})")
    # glTF / Godot terms: x, y=up, z=-blender_y. Front should be at most negative z.
    print(f"  Godot  z range [{-hi.y:.2f}, {-lo.y:.2f}]  (front = {-hi.y:.2f}, toward -Z)")
    # where are the headlights? (front check)
    for o in meshes:
        for i, m in enumerate(o.data.materials):
            if m and "headlight" in m.name:
                ys = [(o.matrix_world @ o.data.vertices[v].co).y
                      for p in o.data.polygons if p.material_index == i for v in p.vertices]
                if ys:
                    print(f"  headlights Godot z ~ {-sum(ys) / len(ys):+.2f}")
    print("  glTF scene roots:", [js["nodes"][n]["name"] for n in js["scenes"][0]["nodes"]])
    anims = [a["name"] for a in js.get("animations", [])]
    if anims:
        print("  glTF animations:", anims)
        print("  imported actions:", sorted(a.name for a in bpy.data.actions))
    if js.get("skins"):
        print("  skin joints:", [js["nodes"][j]["name"] for j in js["skins"][0]["joints"]])
    ok = tris < budget
    if js.get("skins") and anims:
        ok = foot_check(js) and ok
    print(f"  TRIS total={tris} budget<{budget} -> {'OK' if ok else 'OVER'}")
    return ok


argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
names = argv or list(FILES)
results = [check(n, FILES.get(n, 10 ** 9)) for n in names]
print("ALL OK" if all(results) else "SOME OVER BUDGET OR FOOT CHECK FAILED")
sys.exit(0 if all(results) else 1)
