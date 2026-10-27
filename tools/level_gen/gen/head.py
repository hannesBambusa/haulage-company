# Generates scenes/level_1.tscn. Dev-only generator; the .tscn is the artifact.
import math, sys
OUT = "/Users/hannesalm/code/games/haulage-company/scenes/level_1.tscn"

ext = {}   # path -> (id, type)
subs = []  # text blocks
nodes = []

def res(path, typ="PackedScene"):
    if path not in ext:
        ext[path] = ("%d_%s" % (len(ext) + 1, path.split("/")[-1].split(".")[0][:12]), typ)
    return 'ExtResource("%s")' % ext[path][0]

def model(n):
    return res("res://assets/models/%s.glb" % n)

def script(n):
    return res(n, "Script")

_sub_id = [0]
def sub(typ, body):
    _sub_id[0] += 1
    sid = "%s_%d" % (typ, _sub_id[0])
    subs.append('[sub_resource type="%s" id="%s"]\n%s\n' % (typ, sid, body.strip()))
    return 'SubResource("%s")' % sid

def f(v):
    s = "%.4f" % v
    s = s.rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s

def xf(pos=(0, 0, 0), yaw=0.0, scale=(1, 1, 1), pitch=0.0):
    if isinstance(scale, (int, float)):
        scale = (scale, scale, scale)
    c, s = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    # rotation about X first (pitch) then Y (yaw): B = Ry * Rx
    cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    # Rx columns
    rx = [(1, 0, 0), (0, cp, sp), (0, -sp, cp)]
    def ry(v):
        return (c * v[0] + s * v[2], v[1], -s * v[0] + c * v[2])
    cols = [ry(rx[i]) for i in range(3)]
    cols = [tuple(x * scale[i] for x in cols[i]) for i in range(3)]
    # Godot serialises the basis row by row
    vals = [cols[0][0], cols[1][0], cols[2][0], cols[0][1], cols[1][1], cols[2][1], cols[0][2], cols[1][2], cols[2][2], *pos]
    return "Transform3D(%s)" % ", ".join(f(v) for v in vals)

def v3(p):
    return "Vector3(%s, %s, %s)" % (f(p[0]), f(p[1]), f(p[2]))

def v3arr(pts):
    return "PackedVector3Array(%s)" % ", ".join("%s, %s, %s" % (f(p[0]), f(p[1]), f(p[2])) for p in pts)

def col(hexs, a=1.0):
    hexs = hexs.lstrip("#")
    r, g, b = (int(hexs[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return "Color(%s, %s, %s, %s)" % (f(r), f(g), f(b), f(a))

def node(name, parent=".", typ=None, inst=None, props=None):
    head = '[node name="%s"' % name
    if typ:
        head += ' type="%s"' % typ
    if parent is not None:
        head += ' parent="%s"' % parent
    if inst:
        head += " instance=%s" % inst
    head += "]"
    lines = [head]
    for k, v in (props or {}).items():
        lines.append("%s = %s" % (k, v))
    nodes.append("\n".join(lines) + "\n")
    return name if parent in (".", None) else parent + "/" + name

def prop(name, mdl, parent, pos, yaw=0.0, scale=1.0, extra=None):
    p = {"transform": xf(pos, yaw, scale)}
    if extra:
        p.update(extra)
    return node(name, parent, inst=model(mdl), props=p)

# ---------------------------------------------------------------- materials
def noise_tex(c0, c1, freq=0.02, seed=0, size=512):
    noise = sub("FastNoiseLite", "seed = %d\nfrequency = %s\nfractal_octaves = 4" % (seed, f(freq)))
    grad = sub("Gradient", "colors = PackedColorArray(%s, %s)" % (col(c0)[6:-1], col(c1)[6:-1]))
    return sub("NoiseTexture2D", "width = %d\nheight = %d\nseamless = true\nnoise = %s\ncolor_ramp = %s" % (size, size, noise, grad))

def ground_mat(c0, c1, r0, r1, uv=0.08, seed=0, freq=0.02):
    alb = noise_tex(c0, c1, freq, seed)
    rough = noise_tex(r0, r1, freq * 2.3, seed + 7)
    return sub("StandardMaterial3D", "\n".join([
        "albedo_texture = %s" % alb,
        "roughness_texture = %s" % rough,
        "uv1_scale = Vector3(%s, %s, %s)" % (f(uv), f(uv), f(uv)),
        "uv1_triplanar = true",
        "uv1_world_triplanar = true",
    ]))

def flat_mat(c, rough=0.9):
    return sub("StandardMaterial3D", "albedo_color = %s\nroughness = %s" % (col(c), f(rough)))

M_FLOOR = ground_mat("#928D84", "#A19C93", "#B8B8B8", "#F0F0F0", 0.06, 1)
M_ASPHALT = ground_mat("#45484D", "#505358", "#D0D0D0", "#FFFFFF", 0.05, 2, 0.03)
M_GRASS = ground_mat("#6A9238", "#7BA144", "#E0E0E0", "#FFFFFF", 0.03, 3, 0.03)
M_APRON = ground_mat("#9E9A92", "#ABA79F", "#C8C8C8", "#F0F0F0", 0.08, 4)
M_CURB = flat_mat("#B4B1AA", 0.9)

def box(name, parent, center, size, mat, shadow=True):
    mesh = sub("BoxMesh", "size = %s" % v3(size))
    p = {"transform": xf(center), "mesh": mesh, "surface_material_override/0": mat}
    if not shadow:
        p["cast_shadow"] = "0"
    return node(name, parent, "MeshInstance3D", props=p)

def plane(name, parent, center, size, mat):
    mesh = sub("PlaneMesh", "size = Vector2(%s, %s)" % (f(size[0]), f(size[1])))
    return node(name, parent, "MeshInstance3D", props={
        "transform": xf(center), "mesh": mesh, "surface_material_override/0": mat, "cast_shadow": "0"})

def rect_pts(x0, z0, x1, z1):
    return [(x0, 0, z0), (x1, 0, z0), (x1, 0, z1), (x0, 0, z1)]

def line(name, parent, pts, color, width=0.15, dash=0.0, gap=1.0, closed=False, y=0.0, h=0.012):
    p = {"transform": xf((0, y, 0)), "script": script("res://scripts/level/marking_line.gd"),
         "points": v3arr(pts), "width": f(width), "color": col(color), "height": f(h)}
    if closed:
        p["closed"] = "true"
    if dash > 0:
        p["dash_length"] = f(dash)
        p["gap_length"] = f(gap)
    return node(name, parent, "MeshInstance3D", props=p)

HAZARD_SHADER = res("res://assets/materials/hazard_stripes.gdshader", "Shader")
def hazard(name, parent, center, size, yaw=0.0):
    mat = sub("ShaderMaterial", "render_priority = 0\nshader = %s\nshader_parameter/quad_size = Vector2(%s, %s)" % (HAZARD_SHADER, f(size[0]), f(size[1])))
    mesh = sub("PlaneMesh", "size = Vector2(%s, %s)" % (f(size[0]), f(size[1])))
    return node(name, parent, "MeshInstance3D", props={
        "transform": xf(center, yaw), "mesh": mesh, "surface_material_override/0": mat, "cast_shadow": "0"})

FONT = res("res://ui/fonts/Inter-Bold.ttf", "FontFile")
def floor_text(name, parent, text, pos, yaw=0.0, color="#F2F2F0", alpha=0.92, px=0.0075, size=96):
    return node(name, parent, "Label3D", props={
        "transform": xf(pos, yaw, 1, -90),
        "pixel_size": f(px), "shaded": "true", "alpha_cut": "1", "texture_filter": "5",
        "modulate": col(color, alpha), "outline_size": "0", "text": '"%s"' % text,
        "font": FONT, "font_size": str(size)})

