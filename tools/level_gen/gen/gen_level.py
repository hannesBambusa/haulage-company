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

# ------------------------------------------------------------------- layout
DOCKS = [(-4.35, 1), (0.35, 2)]
CAMV = dict(target=(-1.0, 0.0, -4.0), yaw=35.0, pitch=42.0, distance=52.0, fov=30.0)

node("Level1", None, "Node3D")

node("WorldEnvironment", ".", "WorldEnvironment", props={
    "environment": res("res://assets/materials/terminal_env.tres", "Environment")})
node("Sun", ".", "DirectionalLight3D", props={
    "transform": xf((0, 30, 0), -100.0, 1, -44.0),
    "light_color": col("#FFD7A6"), "light_energy": "1.7", "light_angular_distance": "1.5",
    "shadow_enabled": "true", "shadow_bias": "0.03", "shadow_normal_bias": "1.2", "shadow_blur": "1.2",
    "directional_shadow_split_1": "0.08", "directional_shadow_split_2": "0.22", "directional_shadow_split_3": "0.5",
    "directional_shadow_blend_splits": "true", "directional_shadow_max_distance": "150.0"})

view = sub("Resource", 'script = %s\ntarget = %s\nyaw_deg = %s\npitch_deg = %s\ndistance = %s\nfov_deg = %s' % (
    script("res://scripts/camera/camera_view.gd"), v3(CAMV["target"]), f(CAMV["yaw"]), f(CAMV["pitch"]), f(CAMV["distance"]), f(CAMV["fov"])))
node("CameraRig", ".", "Node3D", props={"script": script("res://scripts/camera/camera_rig.gd"), "reference_view": view})
node("Camera3D", "CameraRig", "Camera3D", props={"current": "true", "fov": f(CAMV["fov"]), "near": "0.5", "far": "400.0"})

# ---- ground
G = node("Ground", ".", "Node3D")
plane("Grass", G, (0, -0.05, 0), (320, 320), M_GRASS)
for i, (x0, z0, x1, z1) in enumerate([(-15.6, -7.2, 15.2, 12.6), (-6.6, 12.5, 15.2, 19.6), (-24, -30, -18.1, 0.2), (-24, -30, 22, -23.9), (15.9, -30, 22, -6.9)]):
    plane("Asphalt%d" % i, G, ((x0 + x1) / 2, -0.02, (z0 + z1) / 2), (x1 - x0, z1 - z0), M_ASPHALT)
box("FloorMain", G, (-7.5, -0.06, -12.0), (21.4, 0.12, 24.4), M_FLOOR)
box("FloorRight", G, (9.6, -0.06, -15.5), (12.8, 0.12, 17.4), M_FLOOR)
box("ApronFront", G, (-12.3, -0.06, 1.4), (11.4, 0.12, 2.8), M_APRON)
box("ApronLeft", G, (-16.8, -0.06, 7.8), (2.4, 0.12, 10.0), M_APRON)
box("BoothPad", G, (19.0, -0.03, -2.0), (6.0, 0.1, 5.0), M_APRON)
for i, (c, sz) in enumerate([((-12.3, 0.03, 2.85), (11.4, 0.16, 0.25)), ((4.3, 0.03, 19.7), (21.8, 0.16, 0.25)), ((-11.1, 0.03, 12.75), (9.0, 0.16, 0.25)), ((-6.65, 0.03, 16.2), (0.25, 0.16, 7.2)),
                             ((15.3, 0.03, 6.3), (0.25, 0.16, 26.8)), ((-15.55, 0.03, 7.8), (0.25, 0.16, 10.0)),
                             ((-18.3, 0.03, -12), (0.25, 0.16, 24.4))]):
    box("Curb%d" % i, G, c, sz, M_CURB)

# ---- building shell (L-shaped: dock block at the front left, right hall recessed to z=-7)
B = node("Building", ".", "Node3D")
def wall(name, pos, yaw, sx=1.0):
    prop(name, "wall_segment", B, pos, yaw, (sx, 1, 1))
for i, x in enumerate([-16, -12, -8]):
    wall("FrontL%d" % i, (x, 0, 0), 0)
wall("BlockSide0", (3.0, 0, -0.9), 90, 0.45)
wall("FrontR1", (15.0, 0, -7.0), 0, 0.5)
for i, z in enumerate([-2, -6, -10, -14, -18, -22]):
    wall("Left%d" % i, (-18, 0, z), -90)
for i, x in enumerate([-16, -12, -8, -4, 0, 4, 8, 12]):
    wall("Back%d" % i, (x, 0, -24), 180)
wall("Back8", (15.0, 0, -24), 180, 0.5)
for i, (z, sx) in enumerate([(-22, 1.0), (-18, 1.0), (-14, 1.0), (-9.5, 0.625)]):
    wall("Right%d" % i, (16, 0, z), 90, sx)
for i, (x, z, sx) in enumerate([(-18, 0, 1), (-6.35, 0, 1), (-2.0, 0, 1.2), (2.68, 0, 1.15), (3, -1.8, 1),
                                (14, -7, 1), (16, -7, 1), (-18, -24, 1), (16, -24, 1)]):
    prop("Corner%d" % i, "wall_corner", B, (x, 0, z), 0, (sx, 1, 1))

# ---- docks
D = node("Docks", ".", "Node3D")
for x, n in DOCKS:
    prop("DockDoor%d" % n, "dock_door", D, (x, 0, 0), 0, 1, {
        "script": script("res://scripts/level/dock_visual.gd"), "number": str(n),
        "open_amount": "1.0" if n == 1 else "0.0",
        "light_color": col("#3CFF5A") if n == 1 else col("#FFB020")})
    hazard("Hazard%d" % n, D, (x, -0.005, 1.0), (4.0, 0.6))
prop("Canopy2", "dock_canopy", D, (1.0, 1.45, 0.1), 180)

# ---- vehicles
V = node("Vehicles", ".", "Node3D")
for name, cab, pos, lights in [("TruckRed", "truck_cab_red", (-4.35, 0, 0.78), "true"),
                               ("TruckBlue", "truck_cab_blue", (8.6, 0, -6.6), "false")]:
    node(name, V, "Node3D", props={"transform": xf(pos, 180), "script": script("res://scripts/level/truck_rig.gd"),
                                   "cab_scene": model(cab), "trailer_scene": model("trailer_box"), "brake_lights": lights})
prop("Forklift", "forklift", V, (-7.4, 0, -7.4), 135)
prop("PalletJack1", "pallet_jack", V, (-2.7, 0, -8.8), -60)
prop("PalletJack2", "pallet_jack", V, (6.8, 0, -13.0), 120)

# ---- interior props
I = node("Interior", ".", "Node3D")
for n, x, z in [("RackA1", -13.0, -8.6), ("RackA2", -13.0, -11.41), ("RackB1", -6.6, -13.4), ("RackB2", -6.6, -16.21)]:
    prop(n, "rack_bay_loaded", I, (x, 0, z), 90)
prop("RackBack1", "rack_bay_loaded", I, (-1.0, 0, -23.2), 0)
prop("RackBack2", "rack_bay", I, (-15.5, 0, -23.2), 0)
prop("RackBack3", "rack_bay_loaded", I, (-12.3, 0, -23.2), 0)
prop("RackLeft1", "rack_bay_loaded", I, (-17.2, 0, -16.0), 90)
pallets = [
    ("PB1", "pallet_boxes_b", (-16.6, -2.2), 0), ("PB2", "pallet_boxes_a", (-15.2, -2.2), 0),
    ("PB3", "pallet_boxes_c", (-16.6, -3.4), 0), ("PB4", "pallet_boxes_a", (-15.0, -3.6), 10),
    ("PB5", "pallet_stack_empty", (-13.4, -2.3), 0),
    ("PB6", "pallet_boxes_b", (-9.6, -5.3), 45), ("PB7", "pallet_boxes_a", (-8.6, -4.4), 45),
    ("PB8", "pallet_boxes_c", (-6.2, -4.6), 0), ("PB8b", "pallet_boxes_a", (-6.2, -3.5), 0),
    ("PB9", "pallet_stack_empty", (0.2, -8.6), 15),
    ("IN1", "pallet_boxes_b", (-0.8, -15.8), 0), ("IN2", "pallet_boxes_a", (0.6, -15.8), 0),
    ("IN3", "pallet_boxes_c", (-0.8, -14.7), 0), ("IN4", "pallet_boxes_b", (0.6, -14.7), 0),
    ("IN5", "pallet_boxes_a", (2.0, -15.2), 90), ("IN6", "pallet_boxes_c", (-2.2, -15.3), 0),
    ("OUT1", "pallet_stack_empty", (9.0, -13.6), 0), ("OUT2", "pallet_boxes_c", (10.4, -13.6), 0),
    ("OUT3", "pallet_stack_empty", (11.6, -15.6), 90), ("OUT4", "pallet_boxes_a", (9.2, -15.4), 0),
    ("OUT5", "pallet_boxes_b", (12.0, -12.6), 0),
    ("RW1", "pallet_boxes_a", (15.2, -11.0), 90), ("RW2", "pallet_boxes_b", (15.2, -12.4), 90),
    ("RW3", "pallet_boxes_c", (15.2, -15.0), 90),
    ("PB13", "pallet_boxes_b", (-8.8, -22.8), 0), ("PB14", "pallet_boxes_a", (-4.4, -22.8), 0),
    ("EX1", "pallet_stack_empty", (4.0, -1.4), 90), ("EX2", "pallet_stack_empty", (4.0, -2.4), 90),
    ("EX3", "pallet_stack_empty", (4.0, -3.4), 90),
]
for n, m, (x, z), yaw in pallets:
    prop(n, m, I, (x, 0, z), yaw)
prop("Box1", "box_single", I, (-14.0, 0, -3.0), 20)
prop("Box2", "box_single", I, (7.4, 0, -12.6), -30)

# ---- office corner (back right)
O = node("Office", ".", "Node3D")
for n, x, sx in [("PartitionA", 5.0, 1.0), ("PartitionB", 11.25, 0.875), ("PartitionC", 14.5, 0.75)]:
    prop(n, "wall_segment", O, (x, 0, -18.5), 0, (sx, 0.5, 1))
prop("PartitionD", "wall_segment", O, (3.0, 0, -21.25), 90, (1.375, 0.5, 1))
prop("PartitionPost", "wall_corner", O, (3.0, 0, -18.5), 0, (1, 0.5, 1))
prop("Desk1", "office_desk", O, (6.0, 0, -22.6), 0)
prop("Desk2", "office_desk", O, (11.0, 0, -22.6), 0)

# ---- markings
MK = node("Markings", ".", "Node3D")
BLUE, YELLOW, WHITE = "#3F74E0", "#F0BE2A", "#EDEDE8"
plane("InboundFill", MK, (-0.25, 0.006, -15.25), (7.5, 5.5), flat_mat("#86878B", 0.8))
line("InboundOutline", MK, rect_pts(-4.0, -18.0, 3.5, -12.5), BLUE, 0.35, closed=True, h=0.014)
floor_text("InboundText", MK, "INBOUND", (-2.3, 0.016, -13.2), 0)
plane("OutboundFill", MK, (10.0, 0.006, -14.0), (6.4, 6.4), flat_mat("#C8A55C", 0.8))
line("OutboundOutline", MK, rect_pts(6.8, -17.2, 13.2, -10.8), YELLOW, 0.3, closed=True, h=0.014)
floor_text("OutboundText", MK, "OUTBOUND", (10.4, 0.016, -11.5), 0)
for n, pts in [("WalkwayA", [(-17.5, 0, -6.0), (-4.5, 0, -6.0)]), ("WalkwayB", [(-10.2, 0, -7.0), (-10.2, 0, -21.0)]),
               ("WalkwayC", [(-4.6, 0, -11.2), (5.5, 0, -11.2)]), ("WalkwayD", [(5.2, 0, -8.0), (5.2, 0, -17.8)])]:
    line(n, MK, pts, YELLOW, 0.12, 0.9, 0.6, h=0.012)
line("RackLineA", MK, [(-14.4, 0, -7.0), (-14.4, 0, -13.0)], YELLOW, 0.1, h=0.012)
line("RackLineB", MK, [(-8.0, 0, -11.8), (-8.0, 0, -17.8)], YELLOW, 0.1, h=0.012)

EY = -0.02
for i, x in enumerate([-6.6, -2.0, 2.6]):
    line("DockLane%d" % i, MK, [(x, 0, 1.4), (x, 0, 13.0)], YELLOW, 0.22, y=EY)
line("DockStop1", MK, [(-6.0, 0, 2.6), (-2.6, 0, 2.6)], YELLOW, 0.3, y=EY)
line("DockStop2", MK, [(-1.4, 0, 2.6), (2.0, 0, 2.6)], YELLOW, 0.3, y=EY)
for i, x in enumerate([-10.0, -13.0]):
    line("ParkLine%d" % i, MK, [(x, 0, 4.0), (x, 0, 11.0)], YELLOW, 0.18, y=EY)
line("ParkEdge", MK, [(-15.2, 0, 4.0), (-7.4, 0, 4.0)], YELLOW, 0.18, y=EY)
line("BayOutline", MK, rect_pts(5.6, -6.8, 11.6, 10.0), BLUE, 0.4, closed=True, y=EY)
line("BayInner1", MK, [(6.4, 0, -6.4), (6.4, 0, 9.6)], WHITE, 0.15, y=EY)
line("BayInner2", MK, [(10.8, 0, -6.4), (10.8, 0, 9.6)], WHITE, 0.15, y=EY)
line("YardEdge", MK, [(-6.2, 0, 15.8), (14.8, 0, 15.8)], YELLOW, 0.2, y=EY)
line("LaneCentre", MK, [(-6.2, 0, 17.8), (14.8, 0, 17.8)], WHITE, 0.16, 1.8, 1.8, y=EY)
line("LaneLeft", MK, [(-21.0, 0, -29.0), (-21.0, 0, -1.0)], WHITE, 0.15, 2.0, 2.0, y=EY)
line("LaneBack", MK, [(-23.0, 0, -27.0), (21.0, 0, -27.0)], WHITE, 0.15, 2.0, 2.0, y=EY)
line("LaneWhite1", MK, [(4.1, 0, 3.0), (4.1, 0, 15.0)], WHITE, 0.16, y=EY)
line("LaneWhite2", MK, [(13.6, 0, -5.0), (13.6, 0, 15.0)], WHITE, 0.16, 1.8, 1.8, y=EY)
line("LaneWhite3", MK, [(-14.4, 0, 12.0), (-14.4, 0, 3.4)], WHITE, 0.14, 1.5, 1.5, y=EY)
line("BlockEdge", MK, [(3.3, 0, -6.8), (3.3, 0, 1.6)], YELLOW, 0.18, y=EY)

# ---- site props
S = node("Site", ".", "Node3D")
bollards = [(-6.75, 1.0), (-2.0, 1.0), (2.75, 1.0), (3.4, 0.9), (3.4, -0.3), (5.3, -6.4), (11.9, -6.4),
            (-7.6, 2.5), (-10.8, 2.5), (-14.0, 2.5), (-17.4, 2.5), (14.8, -5.0), (14.8, -3.6), (14.8, 10.0)]
for i, (x, z) in enumerate(bollards):
    prop("Bollard%d" % i, "bollard", S, (x, 0, z))
for i, z in enumerate([6.6, 8.8, 11.0]):
    prop("Barrier%d" % i, "jersey_barrier", S, (-14.6, 0, z), 90)
for i, (x, z, yaw) in enumerate([(-16.8, 4.5, 90), (-16.8, 11.0, 90), (-20.5, -12.0, 90), (14.6, 12.0, -90), (-19.6, -26.0, 0)]):
    prop("Lamp%d" % i, "lamp_post", S, (x, 0, z), yaw)
prop("Cctv1", "cctv_pole", S, (15.0, 0, -1.8), -90)
prop("Booth", "office_booth", S, (19.0, 0, -2.0), 0)

fence = script("res://scripts/level/fence_run.gd")
for n, pts in [("FenceRight", [(15.7, 0, 19.0), (15.7, 0, -6.4)]),
               ("FenceBooth", [(16.0, 0, 3.0), (32.0, 0, 3.0)]),
               ("FenceLeft", [(-15.8, 0, 3.4), (-15.8, 0, 12.9), (-8.6, 0, 12.9)]),
               ("FenceLeftOuter", [(-24.6, 0, 3.0), (-24.6, 0, -30.0)]),
               ("FenceBack", [(-24.6, 0, -30.6), (22.6, 0, -30.6)]),
               ("FenceFar", [(22.6, 0, -30.6), (22.6, 0, -7.0)])]:
    node(n, S, "Node3D", props={"script": fence, "points": v3arr(pts)})

# ---- trees
T = node("Trees", ".", "Node3D")
trees = "[%s, %s, %s]" % (model("tree_cone_a"), model("tree_cone_b"), model("tree_round"))
scatter = script("res://scripts/level/tree_scatter.gd")
for n, pts, spacing, depth, seed in [
        ("BottomLeft", [(-7.5, 0, 14.0), (-40, 0, 14.0)], 3.2, 8.0, 11),
        ("BottomFar", [(16, 0, 22.0), (-40, 0, 22.0)], 4.0, 8.0, 17),
        ("LeftFront", [(-19.8, 0, 13), (-19.8, 0, 2)], 3.6, 6.0, 16),
        ("BottomRight", [(17.5, 0, 6), (17.5, 0, 34)], 4.6, 16.0, 12),
        ("Left", [(-26.5, 0, 3), (-26.5, 0, -40)], 3.0, 12.0, 13),
        ("LeftNear", [(-24.0, 0, 2.0), (-24.0, 0, -22.0)], 5.0, 2.0, 18),
        ("Back", [(-27, 0, -33), (30, 0, -33)], 4.0, 8.0, 14),
        ("Right", [(24.5, 0, -36), (24.5, 0, 2)], 4.5, 10.0, 15)]:
    node(n, T, "Node3D", props={"script": scatter, "tree_scenes": 'Array[PackedScene](%s)' % trees,
                                "points": v3arr(pts), "spacing": f(spacing), "depth": f(depth), "random_seed": str(seed)})

# ---- workers
W = node("Workers", ".", "Node3D")
wscript = script("res://scripts/level/worker_actor.gd")
workers = [
    ("Worker1", "worker", (-12.9, 0, -3.9), 0, [(-12.9, 0, -3.9), (-9.0, 0, -4.4)], 0.1),
    ("Worker2", "worker_bluehat", (-10.0, 0, -12.5), 100, [], 0.3),
    ("Worker3", "worker", (-3.0, 0, -19.5), 0, [(-5.0, 0, -19.5), (1.5, 0, -19.6)], 0.5),
    ("Worker4", "worker_bluehat", (5.0, 0, -8.2), 0, [(4.4, 0, -8.0), (4.6, 0, -16.0)], 0.2),
    ("Worker5", "worker", (6.0, 0, -13.7), -60, [], 0.7),
    ("Worker6", "worker_bluehat", (-1.0, 0, -4.0), 60, [(-2.6, 0, -3.2), (1.8, 0, -5.2)], 0.45),
]
for n, m, pos, yaw, path, phase in workers:
    p = {"script": wscript, "phase": f(phase)}
    if path:
        p["patrol_points"] = v3arr(path)
    prop(n, m, W, pos, yaw, 1, p)

# ------------------------------------------------------------------- write
out = ['[gd_scene load_steps=%d format=3]\n' % (len(ext) + len(subs) + 1)]
for path, (rid, typ) in ext.items():
    out.append('[ext_resource type="%s" path="%s" id="%s"]' % (typ, path, rid))
out.append("")
out += subs
out += nodes
open(OUT, "w").write("\n".join(out))
print("wrote", OUT, len(nodes), "nodes")
