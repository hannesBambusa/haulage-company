"""Shared helpers for the vehicle / character build scripts.

Conventions (Blender side, before glTF +Y-up export):
  1 BU = 1 m, Z up, vehicles face +Y (exports to -Z in Godot), X = right.
  Origin at ground level, centred on the asset's bounding box.
Everything is built through MeshBuilder (bmesh, no operators) so runs are
deterministic and rerunnable.
"""
import math
import os

import bmesh
import bpy
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, "..", ".."))
MODELS = os.path.join(PROJECT, "assets", "models")

# name: (sRGB hex, roughness, metallic, emission hex or None, emission strength)
PALETTE = {
    "truck_red": ("#C8322A", 0.45, 0.0, None, 0.0),
    "truck_blue": ("#2A5FB8", 0.45, 0.0, None, 0.0),
    "trailer_white": ("#E9E9E6", 0.6, 0.0, None, 0.0),
    "chassis": ("#2A2B2E", 0.7, 0.1, None, 0.0),
    "tyre": ("#1E1F21", 0.9, 0.0, None, 0.0),
    "rim": ("#9A9DA2", 0.4, 0.6, None, 0.0),
    "forklift_yellow": ("#F2C230", 0.5, 0.0, None, 0.0),
    "mast": ("#3A3B3E", 0.6, 0.3, None, 0.0),
    "jack_orange": ("#E8822A", 0.5, 0.0, None, 0.0),
    "jack_fork": ("#F0A030", 0.5, 0.0, None, 0.0),
    "vest": ("#D7F03A", 0.6, 0.0, None, 0.0),
    "vest_strip": ("#CFCFCF", 0.3, 0.2, None, 0.0),
    "skin": ("#E0B48F", 0.7, 0.0, None, 0.0),
    "trousers": ("#2B3550", 0.8, 0.0, None, 0.0),
    "hat_yellow": ("#F2C230", 0.4, 0.0, None, 0.0),
    "hat_white": ("#EDEDED", 0.4, 0.0, None, 0.0),
    "hat_blue": ("#2F5FB0", 0.4, 0.0, None, 0.0),
    "boots": ("#2A2420", 0.8, 0.0, None, 0.0),
    # not in the brief palette: dark long-sleeve shirt seen on the reference workers
    "shirt": ("#3C4A4A", 0.8, 0.0, None, 0.0),
    "chrome": ("#C9CDD2", 0.25, 0.9, None, 0.0),
    "glass": ("#26303B", 0.08, 0.1, None, 0.0),
    "headlight": ("#FFF6E0", 0.2, 0.0, "#FFF1D6", 3.0),
    "taillight": ("#C01010", 0.3, 0.0, "#FF1A10", 3.0),
    "beacon": ("#F29A1A", 0.3, 0.0, "#FF9A10", 3.0),
    # trailer cargo box interior
    "cargo_wall": ("#CFCFCB", 0.8, 0.0, None, 0.0),
    "cargo_rib": ("#B9BAB5", 0.7, 0.1, None, 0.0),
    "cargo_rail": ("#55585C", 0.6, 0.4, None, 0.0),
    "bed_plank_a": ("#46433E", 0.85, 0.0, None, 0.0),
    "bed_plank_b": ("#3B3935", 0.85, 0.0, None, 0.0),
    "bed_plank_c": ("#4F4B45", 0.85, 0.0, None, 0.0),
    "interior_light": ("#F4F4EE", 0.3, 0.0, "#FFF8E6", 2.0),
}


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_rgba(h):
    h = h.lstrip("#")
    return tuple(srgb_to_linear(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4)) + (1.0,)


def reset_scene(fps=30):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scn = bpy.context.scene
    scn.unit_settings.system = "METRIC"
    scn.unit_settings.scale_length = 1.0
    scn.render.fps = fps
    return scn


def mat(name):
    """Principled BSDF material from PALETTE, created once per scene."""
    key = "M_" + name
    m = bpy.data.materials.get(key)
    if m:
        return m
    base, rough, metal, emis, strength = PALETTE[name]
    m = bpy.data.materials.new(key)
    m.use_nodes = True
    bsdf = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = hex_rgba(base)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if emis:
        bsdf.inputs["Emission Color"].default_value = hex_rgba(emis)
        bsdf.inputs["Emission Strength"].default_value = strength
    m.diffuse_color = hex_rgba(base)
    return m


def rot(rx=0.0, ry=0.0, rz=0.0):
    """Rotation matrix from degrees (XYZ euler)."""
    return (Matrix.Rotation(math.radians(rz), 4, "Z")
            @ Matrix.Rotation(math.radians(ry), 4, "Y")
            @ Matrix.Rotation(math.radians(rx), 4, "X"))


def trs(loc=(0, 0, 0), rx=0.0, ry=0.0, rz=0.0):
    return Matrix.Translation(Vector(loc)) @ rot(rx, ry, rz)


class MeshBuilder:
    """Accumulates flat-shaded parts into one mesh with material slots."""

    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()
        self.mats = []
        self.groups = []      # vertex-group name per part (optional)
        self.vgroup_of = []   # per vertex: group index or -1

    def _mi(self, m):
        if m not in self.mats:
            self.mats.append(m)
        return self.mats.index(m)

    def _merge(self, tmp, m, matrix, bevel, bevel_angle=30.0, group=None):
        if bevel > 0:
            tmp.normal_update()
            edges = [e for e in tmp.edges if e.is_manifold
                     and e.calc_face_angle(0.0) > math.radians(bevel_angle)]
            if edges:
                bmesh.ops.bevel(tmp, geom=edges, offset=bevel, offset_type="OFFSET",
                                segments=1, profile=0.5, affect="EDGES",
                                clamp_overlap=True)
        bmesh.ops.transform(tmp, matrix=matrix, verts=tmp.verts)
        mi = self._mi(m)
        gi = -1
        if group is not None:
            if group not in self.groups:
                self.groups.append(group)
            gi = self.groups.index(group)
        vmap = {}
        for v in tmp.verts:
            vmap[v] = self.bm.verts.new(v.co)
            self.vgroup_of.append(gi)
        for f in tmp.faces:
            nf = self.bm.faces.new([vmap[v] for v in f.verts])
            nf.material_index = mi
            nf.smooth = False
        tmp.free()

    def box(self, size, loc, m, bevel=0.0, rx=0.0, ry=0.0, rz=0.0, xform=None, group=None):
        tmp = bmesh.new()
        bmesh.ops.create_cube(tmp, size=1.0)
        for v in tmp.verts:
            v.co = Vector((v.co.x * size[0], v.co.y * size[1], v.co.z * size[2]))
        mtx = trs(loc, rx, ry, rz)
        if xform is not None:
            mtx = xform @ mtx
        self._merge(tmp, m, mtx, bevel, group=group)

    def cyl(self, r, depth, loc, m, axis="Z", segs=12, r_top=None, bevel=0.0,
            rx=0.0, ry=0.0, rz=0.0, xform=None, group=None):
        tmp = bmesh.new()
        bmesh.ops.create_cone(tmp, cap_ends=True, cap_tris=False, segments=segs,
                              radius1=r, radius2=r if r_top is None else r_top,
                              depth=depth)
        base = {"Z": Matrix.Identity(4),
                "X": Matrix.Rotation(math.radians(90), 4, "Y"),
                "Y": Matrix.Rotation(math.radians(-90), 4, "X")}[axis]
        # half-segment twist so flat faces sit at the bottom/top
        twist = Matrix.Rotation(math.pi / segs, 4, "Z")
        mtx = trs(loc, rx, ry, rz) @ base @ twist
        if xform is not None:
            mtx = xform @ mtx
        self._merge(tmp, m, mtx, bevel, group=group)

    def prism(self, profile, a0, a1, m, axis="X", bevel=0.0, xform=None, group=None):
        """Extrude a 2D profile along an axis.

        axis 'X': profile points are (y, z), extruded from x=a0 to x=a1.
        axis 'Y': profile points are (x, z), extruded from y=a0 to y=a1.
        axis 'Z': profile points are (x, y), extruded from z=a0 to z=a1.
        """
        def p3(p, a):
            if axis == "X":
                return Vector((a, p[0], p[1]))
            if axis == "Y":
                return Vector((p[0], a, p[1]))
            return Vector((p[0], p[1], a))

        tmp = bmesh.new()
        ring0 = [tmp.verts.new(p3(p, a0)) for p in profile]
        ring1 = [tmp.verts.new(p3(p, a1)) for p in profile]
        tmp.faces.new(ring0)
        tmp.faces.new(list(reversed(ring1)))
        n = len(profile)
        for i in range(n):
            j = (i + 1) % n
            tmp.faces.new([ring0[i], ring0[j], ring1[j], ring1[i]])
        bmesh.ops.recalc_face_normals(tmp, faces=tmp.faces)
        self._merge(tmp, m, xform if xform is not None else Matrix.Identity(4),
                    bevel, group=group)

    def poly(self, verts, faces, m, group=None):
        """Raw faces from a vertex list; faces are index tuples (winding = normal)."""
        tmp = bmesh.new()
        vs = [tmp.verts.new(Vector(v)) for v in verts]
        for f in faces:
            tmp.faces.new([vs[i] for i in f])
        self._merge(tmp, m, Matrix.Identity(4), 0.0, group=group)

    def quad(self, pts, m, normal, group=None):
        """One planar polygon; winding flipped if needed so it faces `normal`."""
        p = [Vector(v) for v in pts]
        n = (p[1] - p[0]).cross(p[2] - p[0])
        if n.dot(Vector(normal)) < 0:
            p.reverse()
        self.poly(p, [tuple(range(len(p)))], m, group=group)

    def finish(self, parent=None, origin=(0, 0, 0)):
        origin = Vector(origin)
        bmesh.ops.translate(self.bm, vec=-origin, verts=self.bm.verts)
        mesh = bpy.data.meshes.new(self.name)
        self.bm.to_mesh(mesh)
        self.bm.free()
        for m in self.mats:
            mesh.materials.append(m)
        obj = bpy.data.objects.new(self.name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        obj.location = origin
        if parent is not None:
            obj.parent = parent
        if self.groups:
            vgs = [obj.vertex_groups.new(name=g) for g in self.groups]
            for vi, gi in enumerate(self.vgroup_of):
                if gi >= 0:
                    vgs[gi].add([vi], 1.0, "REPLACE")
        return obj


def make_root(name):
    root = bpy.data.objects.new(name, None)
    root.empty_display_type = "PLAIN_AXES"
    bpy.context.scene.collection.objects.link(root)
    return root


def make_empty(name, loc, parent):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = "ARROWS"
    e.empty_display_size = 0.3
    bpy.context.scene.collection.objects.link(e)
    e.location = loc
    e.parent = parent
    return e


def wheel(name, r, width, loc, side, parent, segs=14, rim_frac=0.6, hub=True,
          rim_mat="rim"):
    """Tyre + rim as one object, origin at the axle centre, axle along X.

    side = -1 for left (outer face at -X), +1 for right.
    """
    mb = MeshBuilder(name)
    c = Vector(loc)
    mb.cyl(r, width, c, mat("tyre"), axis="X", segs=segs, bevel=min(0.06, r * 0.12))
    rim_r = r * rim_frac
    mb.cyl(rim_r, 0.04, c + Vector((side * (width / 2 - 0.005), 0, 0)), mat(rim_mat),
           axis="X", segs=10)
    if hub:
        mb.cyl(rim_r * 0.35, 0.06, c + Vector((side * (width / 2 + 0.02), 0, 0)),
               mat("chrome"), axis="X", segs=6)
    return mb.finish(parent, origin=c)


def _mesh_descendants(obj):
    out = []
    for ch in obj.children_recursive:
        if ch.type == "MESH":
            out.append(ch)
    return out


def world_bbox(objs):
    bpy.context.view_layer.update()
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        mw = o.matrix_world
        for v in o.data.vertices:
            w = mw @ v.co
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    return lo, hi


def center_on_ground(root):
    """Shift root's direct children so bbox is centred in XY with min Z = 0."""
    lo, hi = world_bbox(_mesh_descendants(root))
    off = Vector((-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z))
    for ch in root.children:
        ch.location += off
    bpy.context.view_layer.update()
    return off


def export_glb(filename, animations=False):
    os.makedirs(MODELS, exist_ok=True)
    path = os.path.join(MODELS, filename)
    kw = dict(filepath=path, export_format="GLB", export_yup=True, export_apply=True,
              use_selection=False, export_materials="EXPORT", export_cameras=False,
              export_lights=False, export_extras=False,
              export_animations=animations, export_skins=animations)
    if animations:
        kw.update(export_animation_mode="ACTIONS", export_force_sampling=True,
                  export_frame_range=False)
    bpy.ops.export_scene.gltf(**kw)
    print("EXPORTED", path)
    return path
