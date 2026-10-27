"""Low-poly terminal worker, 15-bone rig, Idle / Walk / Carry plus idle-time actions.

Writes worker.glb and worker_bluehat.glb. Blender: faces +Y (-> -Z in Godot), feet at
origin. Root "Worker" (empty) > "WorkerRig" (armature) > "WorkerMesh" (rigid-skinned,
one bone per part). Hand_L/R and Foot_L/R were added for prop attachment and foot
roll; they are identity in Idle, so Idle deforms exactly as before. Walk / Carry and
every other action come from build_worker_anims.py (24 fps, keyed per frame).
"""
import json
import math
import os
import struct
import sys

import bpy
from mathutils import Matrix, Quaternion, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_worker_anims as wa  # noqa: E402
import common_vehicles as cv  # noqa: E402
from common_vehicles import mat  # noqa: E402

FPS = wa.FPS

# bone: (head, tail, parent). Proportions: 1.78 m to the crown, head ~1/7 of height.
BONES = {
    "Hips": ((0, 0, 0.92), (0, 0, 1.02), None),
    "Spine": ((0, 0, 1.02), (0, 0, 1.44), "Hips"),
    "Head": ((0, 0, 1.48), (0, 0, 1.77), "Spine"),
}
for side, sx in (("L", -1), ("R", 1)):
    BONES[f"UpperArm_{side}"] = ((sx * 0.2, 0, 1.44), (sx * 0.205, 0, 1.17), "Spine")
    BONES[f"LowerArm_{side}"] = ((sx * 0.205, 0, 1.17), (sx * 0.21, 0, 0.93), f"UpperArm_{side}")
    BONES[f"UpperLeg_{side}"] = ((sx * 0.085, 0, 0.92), (sx * 0.085, 0, 0.5), "Hips")
    BONES[f"LowerLeg_{side}"] = ((sx * 0.085, 0, 0.5), (sx * 0.085, 0, 0.08), f"UpperLeg_{side}")
    # wrist -> knuckles along the forearm; ankle -> toe
    BONES[f"Hand_{side}"] = ((sx * 0.21, 0, 0.93), (sx * 0.2119, 0, 0.84), f"LowerArm_{side}")
    BONES[f"Foot_{side}"] = ((sx * 0.085, 0, 0.08), (sx * 0.085, 0.13, 0.08), f"LowerLeg_{side}")


def torso_profile(grow=0.0):
    """Front view (x, z) of the chest: waist, chest, sloped shoulders."""
    return [(-0.14 - grow, 1.0), (0.14 + grow, 1.0), (0.165 + grow, 1.3),
            (0.18 + grow, 1.43), (0.08, 1.5), (-0.08, 1.5), (-0.18 - grow, 1.43),
            (-0.165 - grow, 1.3)]


def build_mesh(root, hat_key):
    vest, strip, skin = mat("vest"), mat("vest_strip"), mat("skin")
    pants, shirt, hat, boots = mat("trousers"), mat("shirt"), mat(hat_key), mat("boots")
    b = cv.MeshBuilder("WorkerMesh")
    # pelvis
    b.prism([(-0.14, 0.86), (0.14, 0.86), (0.145, 1.03), (-0.145, 1.03)], -0.095, 0.095,
            pants, axis="Y", bevel=0.015, group="Hips")
    # shirt torso, vest over it (shirt shows at the shoulders), reflective strips
    b.prism(torso_profile(), -0.1, 0.1, shirt, axis="Y", bevel=0.02, group="Spine")
    b.prism([(-0.15, 0.99), (0.15, 0.99), (0.172, 1.3), (0.13, 1.45), (-0.13, 1.45),
             (-0.172, 1.3)], -0.108, 0.108, vest, axis="Y", bevel=0.015, group="Spine")
    for z in (1.1, 1.22):
        w = 0.15 + 0.022 * (z - 0.99) / 0.31 + 0.006
        b.prism([(-w, z - 0.018), (w, z - 0.018), (w + 0.003, z + 0.018), (-w - 0.003, z + 0.018)],
                -0.114, 0.114, strip, axis="Y", group="Spine")
    for s in (-1, 1):  # vertical strips over the shoulders, front and back
        for y in (-0.112, 0.112):
            b.box((0.035, 0.006, 0.2), (s * 0.085, y, 1.34), strip, group="Spine")
    # neck + head + hard hat
    b.cyl(0.045, 0.1, (0, 0, 1.51), skin, segs=6, group="Head")
    b.box((0.17, 0.2, 0.23), (0, 0.005, 1.655), skin, bevel=0.03, group="Head")
    b.box((0.03, 0.025, 0.045), (0, 0.115, 1.64), skin, group="Head")  # nose
    b.cyl(0.115, 0.1, (0, 0.0, 1.775), hat, segs=10, r_top=0.08, bevel=0.02, group="Head")
    b.cyl(0.13, 0.02, (0, 0.015, 1.73), hat, segs=10, group="Head")
    for side, sx in (("L", -1), ("R", 1)):
        b.cyl(0.04, 0.28, (sx * 0.203, 0, 1.31), shirt, segs=6, r_top=0.047,
              group=f"UpperArm_{side}")
        b.cyl(0.032, 0.24, (sx * 0.208, 0, 1.05), shirt, segs=6, r_top=0.039,
              group=f"LowerArm_{side}")
        b.box((0.055, 0.075, 0.09), (sx * 0.21, 0.005, 0.89), skin, bevel=0.01,
              group=f"Hand_{side}")
        b.cyl(0.056, 0.44, (sx * 0.085, 0, 0.71), pants, segs=6, r_top=0.072,
              group=f"UpperLeg_{side}")
        b.cyl(0.045, 0.42, (sx * 0.085, 0, 0.3), pants, segs=6, r_top=0.055,
              group=f"LowerLeg_{side}")
        b.box((0.1, 0.22, 0.09), (sx * 0.085, 0.035, 0.045), boots, bevel=0.02,
              group=f"Foot_{side}")
    return b.finish(root)


def build_rig(root):
    arm_data = bpy.data.armatures.new("WorkerRig")
    rig = bpy.data.objects.new("WorkerRig", arm_data)
    bpy.context.scene.collection.objects.link(rig)
    rig.parent = root
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    for name, (h, t, p) in BONES.items():
        eb = arm_data.edit_bones.new(name)
        eb.head, eb.tail, eb.roll = Vector(h), Vector(t), 0.0
        if p:
            eb.parent = arm_data.edit_bones[p]
            eb.use_connect = (Vector(arm_data.edit_bones[p].tail) - Vector(h)).length < 1e-4
    bpy.ops.object.mode_set(mode="OBJECT")
    return rig


# --- animation ---------------------------------------------------------
# Angles are "swing forward" degrees: positive moves a hanging limb toward +Y
# (forward), positive on Spine/Head pitches the top forward. The sign per bone is
# derived from the bone's local X axis so the convention holds for every bone.

def swing_sign(rig, bone):
    x_axis = rig.data.bones[bone].matrix_local.to_3x3().col[0]
    y_axis = rig.data.bones[bone].matrix_local.to_3x3().col[1]
    # rotation about local X by +a moves local Y toward local Z; forward = +world Y
    z_axis = rig.data.bones[bone].matrix_local.to_3x3().col[2]
    return 1.0 if z_axis.y > 0 else -1.0


def key_pose(rig, frame, angles, hips_up=0.0, roll=None):
    roll = roll or {}
    for name in BONES:
        pb = rig.pose.bones[name]
        pb.rotation_mode = "XYZ"
        a = math.radians(angles.get(name, 0.0)) * swing_sign(rig, name)
        pb.rotation_euler = (a, 0.0, math.radians(roll.get(name, 0.0)))
        pb.location = (0.0, hips_up if name == "Hips" else 0.0, 0.0)
        pb.keyframe_insert("rotation_euler", frame=frame)
        pb.keyframe_insert("location", frame=frame)


def new_action(rig, name):
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    rig.animation_data.action = act
    return act


def push_nla(rig, act, start):
    tr = rig.animation_data.nla_tracks.new()
    tr.name = act.name
    tr.strips.new(act.name, start, act)
    tr.mute = True
    rig.animation_data.action = None


def foot_verts(mesh):
    """Boot vertices per side, relative to the ankle (Foot bone head)."""
    out = {}
    for side, sx in (("L", -1), ("R", 1)):
        gi = mesh.vertex_groups[f"Foot_{side}"].index
        ankle = Vector(BONES[f"Foot_{side}"][0])
        out[side] = [v.co - ankle for v in mesh.data.vertices
                     if any(g.group == gi for g in v.groups)]
    return out


EXTRA_ACTIONS = ["Walk", "Carry"] + list(wa.ACTIONS)


def build_actions(rig, mesh, store=None):
    rig.animation_data_create()
    # Idle: 2 s breathing loop (unchanged pose curve, keys rescaled from 30 to 24 fps)
    act = new_action(rig, "Idle")
    for f, t in ((0, 0.0), (FPS, 1.0), (2 * FPS, 0.0)):
        key_pose(rig, f, {"Spine": -1.5 * t, "Head": 1.0 * t,
                              "UpperArm_L": 2 + 2 * t, "UpperArm_R": 2 + 2 * t,
                              "LowerArm_L": 6, "LowerArm_R": 6},
                 hips_up=0.006 * t,
                 roll={"UpperArm_L": 2 + t, "UpperArm_R": -(2 + t)})
    push_nla(rig, act, 0)
    return wa.build_actions(rig, foot_verts(mesh), EXTRA_ACTIONS, store=store)


def build_scene(hat_key, store=None):
    cv.reset_scene(fps=FPS)
    root = cv.make_root("Worker")
    rig = build_rig(root)
    mesh = build_mesh(root, hat_key)
    mesh.parent = rig
    mod = mesh.modifiers.new("Armature", "ARMATURE")
    mod.object = rig
    sv = build_actions(rig, mesh, store=store)
    return root, rig, mesh, sv


# Blender Z-up -> glTF Y-up (x, y, z) -> (x, z, -y)
TO_GLTF = Matrix(((1, 0, 0, 0), (0, 0, 1, 0), (0, -1, 0, 0), (0, 0, 0, 1)))
PROP_HANDS = {"prop_broom": "R", "prop_mop": "R", "prop_coffee_cup": "R", "prop_clipboard": "L",
              "prop_scanner": "R", "prop_phone": "R", "prop_wrench": "R"}


def _gltf_globals(path):
    with open(path, "rb") as f:
        f.read(12)
        ln, _ = struct.unpack("<II", f.read(8))
        nodes = json.loads(f.read(ln))["nodes"]
    parent = {c: i for i, n in enumerate(nodes) for c in n.get("children", [])}

    def local(n):
        if "matrix" in n:
            m = n["matrix"]
            return Matrix([m[0:4], m[4:8], m[8:12], m[12:16]]).transposed()
        t = Vector(n.get("translation", (0, 0, 0)))
        q = n.get("rotation", (0, 0, 0, 1))
        sc = n.get("scale", (1, 1, 1))
        return (Matrix.Translation(t) @ Quaternion((q[3], q[0], q[1], q[2])).to_matrix().to_4x4()
                @ Matrix.Diagonal((sc[0], sc[1], sc[2], 1)))

    def glob(i):
        m = local(nodes[i])
        while i in parent:
            i = parent[i]
            m = local(nodes[i]) @ m
        return m
    return {n.get("name"): glob(i) for i, n in enumerate(nodes)}


def report_prop_offsets(rig, sv, path):
    """Prop transform relative to the Hand_* bone as Godot sees it (BoneAttachment3D child)."""
    G = _gltf_globals(path)
    for side in ("R", "L"):
        bone = "Hand_" + side
        B = rig.matrix_world @ rig.data.bones[bone].matrix_local
        T = G[bone].inverted() @ TO_GLTF @ B @ sv.prop_offset(side) @ TO_GLTF.inverted()
        b, o = T.to_3x3(), T.translation
        cols = ", ".join(f"{b.col[i].x:.4f}, {b.col[i].y:.4f}, {b.col[i].z:.4f}" for i in range(3))
        e = b.to_euler("ZXY")   # = Godot's default YXZ order
        props = [p for p, h in PROP_HANDS.items() if h == side]
        print(f"PROP OFFSET {bone}: Transform3D({cols}, {o.x:.4f}, {o.y:.4f}, {o.z:.4f})"
              f"  rotation_degrees=({math.degrees(e.x):.2f}, {math.degrees(e.y):.2f}, {math.degrees(e.z):.2f})"
              f"  for {', '.join(props)}")


def build(hat_key, filename):
    _root, rig, _mesh, sv = build_scene(hat_key)
    path = cv.export_glb(filename, animations=True)
    report_prop_offsets(rig, sv, path)
    return sv


if __name__ == "__main__":
    build("hat_yellow", "worker.glb")
    build("hat_blue", "worker_bluehat.glb")
