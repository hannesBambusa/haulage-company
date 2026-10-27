"""Preview: trailer (doors open) backed onto dock_door, 4 pallets loaded. -> docs/previews/trailer_dock.png"""
import math, os, sys
import bpy
from mathutils import Vector, Quaternion
PROJ = "/Users/hannesalm/code/games/haulage-company"
MODELS = os.path.join(PROJ, "assets", "models")
OUT = os.path.join(PROJ, "docs", "previews", "trailer_dock.png")
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
SLOTS = argv[0].split(",") if argv else ["01", "02", "03", "04"]
CAM = [float(v) for v in argv[1].split(",")] if len(argv) > 1 else [3.2, 8.0, 4.4]
TGT = [float(v) for v in argv[2].split(",")] if len(argv) > 2 else [0.0, -3.0, 1.3]
out = argv[3] if len(argv) > 3 else OUT

bpy.ops.wm.read_factory_settings(use_empty=True)
scn = bpy.context.scene

def imp(name):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(MODELS, name + ".glb"))
    new = [o for o in bpy.data.objects if o not in before]
    for o in new:
        if "-col" in o.name:
            o.hide_render = True
    return [o for o in new if o.parent is None][0], {o.name.split(".")[0]: o for o in new}

def mat(name, rgb, rough=0.9):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]; b.inputs["Base Color"].default_value = (*rgb, 1); b.inputs["Roughness"].default_value = rough
    return m

dock, dk = imp("dock_door")
dk["Door"].scale.z = 0.06            # roller door open, as dock_visual.gd does
for x in (-4.0, 4.0, -8.0, 8.0):
    w, _ = imp("wall_segment"); w.location.x = x
tr, tk = imp("trailer_box")
tr.rotation_mode = "XYZ"; tr.rotation_euler.z = math.pi
bpy.context.view_layer.update()
re = tk["RearEntry"].matrix_world.translation
tr.location.y += -0.31 - re.y         # rear bed edge onto the bumper face
bpy.context.view_layer.update()
for nm, ang in (("DoorL", -270), ("DoorR", 270)):
    d = tk[nm]; d.rotation_mode = "QUATERNION"
    d.rotation_quaternion = Quaternion((0, 0, 1), math.radians(ang)) @ d.rotation_quaternion
bpy.context.view_layer.update()
for sid in SLOTS:
    e = tk["Slot_" + sid]
    p, _ = imp("pallet_boxes_a")
    p.rotation_mode = "XYZ"; p.rotation_euler.z = math.pi / 2  # 1.2 m side along the trailer
    p.location = e.matrix_world.translation
# forklift parked on the ramp top under the opening (clearance check); faces the trailer (-Y)
fk, _ = imp("forklift")
fk.rotation_mode = "XYZ"; fk.rotation_euler.z = math.pi
rt = dk["RampTop"].matrix_world.translation
fk.location = (0, rt.y - 0.3, rt.z)
bpy.context.view_layer.update()
print("RampTop", tuple(rt), "forklift bbox z", min((fk.matrix_world @ Vector(c)).z for c in fk.bound_box), "(root only)")
# floor
bpy.ops.mesh.primitive_plane_add(size=60, location=(0, 10, 0)); f = bpy.context.active_object
f.data.materials.append(mat("floor_in", (0.32, 0.32, 0.31)))
bpy.ops.mesh.primitive_plane_add(size=60, location=(0, -30.15, -0.002)); f2 = bpy.context.active_object
f2.data.materials.append(mat("yard", (0.18, 0.18, 0.18)))
# lights
sun = bpy.data.lights.new("Sun", "SUN"); sun.energy = 3.5; sun.color = (1, 0.93, 0.82); sun.angle = math.radians(3)
so = bpy.data.objects.new("Sun", sun); so.rotation_euler = (math.radians(45), 0, math.radians(150)); scn.collection.objects.link(so)
il = tk["InteriorLight"].matrix_world.translation
for dy in (-2.0, 0.0, 2.0):
    pl = bpy.data.lights.new("Int", "POINT"); pl.energy = 120; pl.shadow_soft_size = 0.3
    po = bpy.data.objects.new("Int", pl); po.location = il + Vector((0, dy, 0)); scn.collection.objects.link(po)
ar = bpy.data.lights.new("Hall", "AREA"); ar.energy = 1500; ar.size = 8
ao = bpy.data.objects.new("Hall", ar); ao.location = (0, 5, 7); scn.collection.objects.link(ao)
world = bpy.data.worlds.new("W"); scn.world = world
world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.62, 0.72, 1)
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.7
cam = bpy.data.cameras.new("Cam"); cam.lens = 24; cam.clip_end = 200
co = bpy.data.objects.new("Cam", cam); scn.collection.objects.link(co)
co.location = CAM
d = Vector(TGT) - Vector(CAM)
co.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
scn.camera = co
r = scn.render; r.resolution_x, r.resolution_y = 1600, 1000; r.engine = "BLENDER_EEVEE"
try:
    scn.view_settings.view_transform = "AgX"
except Exception:
    pass
r.filepath = out
os.makedirs(os.path.dirname(out), exist_ok=True)
bpy.ops.render.render(write_still=True)
print("WROTE", out)
