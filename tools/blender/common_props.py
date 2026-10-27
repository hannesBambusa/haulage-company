"""Shared helpers for prop builders (bpy, Blender 5.x).

Convention: Blender -Y is the asset "front" (exports to Godot +Z, Godot's model front).
Units are metres, origin at ground level centre unless a script says otherwise.
"""
import math
import os
import random

import bmesh
import bpy
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", ".."))
MODELS = os.path.join(PROJECT, "assets", "models")

# Palette (sRGB hex)
PAL = {
    "cardboard": "#C89A5E",
    "tape": "#B98A50",
    "pallet_wood": "#B08A5A",
    "rack_blue": "#2F4FA0",
    "rack_orange": "#E8822A",
    "wall_grey": "#A8ADB2",
    "wall_plinth": "#7E848A",
    "dock_black": "#2B2D30",
    "dock_yellow": "#F2C230",
    "roller_door": "#B9BDC1",
    "bollard_yellow": "#F2C230",
    "concrete": "#C9C6BE",
    "fence_post": "#8C9196",
    "fence_mesh": "#A0A5AA",
    "office_wall": "#D7D9DB",
    "office_roof": "#5A5F66",
    "glass": "#6E8799",
    "foliage": "#5F8F3A",
    "foliage_dark": "#4E7A2F",
    "trunk": "#6B4A2E",
    "lamp_post": "#50555B",
}


def _s2l(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_lin(h, factor=1.0):
    h = h.lstrip("#")
    rgb = [int(h[i:i + 2], 16) / 255.0 * factor for i in (0, 2, 4)]
    return tuple(_s2l(min(1.0, max(0.0, c))) for c in rgb) + (1.0,)


def mat(name, hexcol, rough=0.8, metal=0.0, emission=None, strength=0.0,
        alpha=1.0, factor=1.0, double_sided=False):
    """Get or create a Principled BSDF material (idempotent per name)."""
    m = bpy.data.materials.get(name)
    if m is not None:
        return m
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = hex_lin(hexcol, factor)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emission:
        bsdf.inputs["Emission Color"].default_value = hex_lin(emission)
        bsdf.inputs["Emission Strength"].default_value = strength
    if alpha < 1.0:
        bsdf.inputs["Alpha"].default_value = alpha
        if hasattr(m, "surface_render_method"):
            m.surface_render_method = "BLENDED"
        if hasattr(m, "blend_method"):
            try:
                m.blend_method = "BLEND"
            except Exception:
                pass
    m.use_backface_culling = not (double_sided or alpha < 1.0)
    m.diffuse_color = hex_lin(hexcol, factor)
    return m


def cardboard_mats(n=6):
    """n deterministic cardboard shades within +-6% of the base colour."""
    rnd = random.Random(1234)
    return [mat(f"cardboard_{i}", PAL["cardboard"], rough=0.9,
                factor=1.0 + rnd.uniform(-0.06, 0.06)) for i in range(n)]


def reset():
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras,
                 bpy.data.lights, bpy.data.images):
        for d in list(coll):
            coll.remove(d)


class MB:
    """Mesh builder: accumulates primitives into one bmesh with per-face materials.

    `xform` is applied to every primitive, so builders can be reused at an offset.
    """

    def __init__(self):
        self.bm = bmesh.new()
        self.mats = []
        self.xform = Matrix.Identity(4)

    def _mi(self, m):
        if m not in self.mats:
            self.mats.append(m)
        return self.mats.index(m)

    def _tag(self, before, m):
        mi = self._mi(m)
        new = [f for f in self.bm.faces if f not in before]
        for f in new:
            f.material_index = mi
        return new

    def box(self, size, loc, m, bevel=0.0, rot=None, drop=()):
        """Axis box. size=(x,y,z), loc=centre. drop: face dirs to delete, e.g. ('-Z',)."""
        bm = self.bm
        before = set(bm.faces)
        M = Matrix.Translation(Vector(loc))
        if rot is not None:
            M = M @ rot
        M = self.xform @ M @ Matrix.Diagonal((size[0], size[1], size[2], 1.0))
        res = bmesh.ops.create_cube(bm, size=1.0, matrix=M)
        verts = res["verts"]
        if bevel > 0:
            edges = list({e for v in verts for e in v.link_edges})
            bmesh.ops.bevel(bm, geom=edges + list(verts), offset=bevel, segments=1,
                            affect="EDGES", profile=0.5, clamp_overlap=True)
        new = self._tag(before, m)
        if drop:
            # Direction in world space after xform/rot.
            R = (self.xform @ (rot if rot is not None else Matrix.Identity(4))).to_3x3()
            dirs = {"+X": (1, 0, 0), "-X": (-1, 0, 0), "+Y": (0, 1, 0),
                    "-Y": (0, -1, 0), "+Z": (0, 0, 1), "-Z": (0, 0, -1)}
            kill = []
            for d in drop:
                dv = (R @ Vector(dirs[d])).normalized()
                for f in new:
                    if f.is_valid and f.normal.dot(dv) > 0.999:
                        kill.append(f)
            bmesh.ops.delete(bm, geom=list(set(kill)), context="FACES_ONLY")
        return self

    def cyl(self, r, h, loc, m, segs=8, r2=None, caps=True, rot=None):
        """Cylinder/cone standing on loc (loc = centre of the bottom cap)."""
        bm = self.bm
        before = set(bm.faces)
        M = Matrix.Translation(Vector(loc))
        if rot is not None:
            M = M @ rot
        M = self.xform @ M @ Matrix.Translation((0, 0, h / 2))
        bmesh.ops.create_cone(bm, cap_ends=caps, cap_tris=False, segments=segs,
                              radius1=r, radius2=(r if r2 is None else r2), depth=h, matrix=M)
        self._tag(before, m)
        return self

    def poly(self, verts, faces, m):
        """Raw geometry in local coords (xform applied). faces = index tuples."""
        bm = self.bm
        bv = [bm.verts.new(self.xform @ Vector(v)) for v in verts]
        mi = self._mi(m)
        for f in faces:
            face = bm.faces.new([bv[i] for i in f])
            face.material_index = mi
        return self

    def prism_x(self, profile_yz, length, loc, m):
        """Extrude a closed YZ profile (CCW seen from +X) along X, centred on loc."""
        n = len(profile_yz)
        x0, x1 = -length / 2, length / 2
        lx, ly, lz = loc
        verts = [(lx + x0, ly + y, lz + z) for y, z in profile_yz] + \
                [(lx + x1, ly + y, lz + z) for y, z in profile_yz]
        faces = [tuple(reversed(range(n))), tuple(range(n, 2 * n))]
        for i in range(n):
            j = (i + 1) % n
            faces.append((i, j, n + j, n + i))
        return self.poly(verts, faces, m)

    def to_object(self, name, parent=None, loc=(0, 0, 0)):
        bm = self.bm
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        for m in self.mats:
            me.materials.append(m)
        for p in me.polygons:
            p.use_smooth = False
        ob = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(ob)
        ob.location = loc
        if parent is not None:
            ob.parent = parent
        return ob


# Godot import hint suffix. "-col" keeps the box mesh VISIBLE and adds a StaticBody3D;
# "-colonly" drops the mesh and keeps only the collision shape, which is what a hidden
# helper box needs. Change here if the Godot side wants plain "-col".
COL_SUFFIX = "-colonly"


def col_box(name, size, loc, parent, rot=None):
    """Collision box child (no material). `name` is given without suffix or with '-col'.
    `rot` (optional 4x4 rotation) tilts the box about its centre, e.g. for ramps."""
    if name.endswith("-col"):
        name = name[:-4]
    name += COL_SUFFIX
    mb = MB()
    M = Matrix.Translation(Vector(loc))
    if rot is not None:
        M = M @ rot
    bmesh.ops.create_cube(mb.bm, size=1.0, matrix=M @ Matrix.Diagonal((size[0], size[1], size[2], 1.0)))
    return mb.to_object(name, parent=parent)


def empty(name, loc, parent, size=0.25):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = "PLAIN_AXES"
    e.empty_display_size = size
    e.location = loc
    e.parent = parent
    bpy.context.scene.collection.objects.link(e)
    return e


def export(root, filename):
    """Export root + descendants to assets/models/<filename> as GLB, Y-up."""
    os.makedirs(MODELS, exist_ok=True)
    path = os.path.join(MODELS, filename)
    for o in bpy.context.scene.objects:
        o.select_set(False)
    for o in [root] + list(root.children_recursive):
        o.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLB", use_selection=True, export_apply=True,
        export_yup=True, export_animations=False, export_materials="EXPORT",
        export_extras=False, export_cameras=False, export_lights=False)
    print(f"[props] exported {path}")
    return path


def rot_x(deg):
    return Matrix.Rotation(math.radians(deg), 4, "X")


def rot_y(deg):
    return Matrix.Rotation(math.radians(deg), 4, "Y")


def rot_z(deg):
    return Matrix.Rotation(math.radians(deg), 4, "Z")
