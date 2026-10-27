import math, random

DOCK2_DX = 3.1
TREES = '[ExtResource("32_tree_cone_a"), ExtResource("33_tree_cone_b"), ExtResource("34_tree_round")]'


def run(g):
    remove, set_prop, xf, add, scene, script = g["remove"], g["set_prop"], g["xf"], g["add"], g["scene"], g["script"]
    shift_x, scale_node, vec3s, fmt, get_xf, put_xf = g["shift_x"], g["scale_node"], g["vec3s"], g["fmt"], g["get_xf"], g["put_xf"]

    # ---- camera ----------------------------------------------------------
    cam = CAM
    blk = g["blocks"]
    for i, b in enumerate(blk):
        if b.startswith('[sub_resource type="Resource" id="Resource_30"]'):
            blk[i] = ('[sub_resource type="Resource" id="Resource_30"]\nscript = ExtResource("4_camera_view")\n'
                      f"target = Vector3({fmt(cam[0])}, 0, {fmt(cam[1])})\nyaw_deg = {fmt(cam[2])}\n"
                      f"pitch_deg = {fmt(cam[3])}\ndistance = {fmt(cam[4])}\nfov_deg = {fmt(cam[5])}\n")
    set_prop("CameraRig/Camera3D", "fov", fmt(cam[5]))

    # ---- dock 2 moves right, wall between the docks ----------------------
    for p in ["Docks/DockDoor2", "Docks/Hazard2", "Docks/Canopy2", "Building/Corner3", "Building/BlockSide0",
              "Building/Corner4", "Site/Bollard2", "Site/Bollard3", "Site/Bollard4",
              "Interior/EX1", "Interior/EX2", "Interior/EX3"]:
        shift_x(p, DOCK2_DX)
    remove("Building/Corner2")
    gap0, gap1 = -2.35, -0.65 + (DOCK2_DX - 1.0)
    add("BetweenDocks", "Building", f"transform = {xf((gap0 + gap1) / 2, 0, 0, 0, 1, sx=(gap1 - gap0) / 4.0)}",
        instance="6_wall_segment")
    set_prop("Markings/DockLane1", "points", vec3s([(-1.5, 0, 1.4), (-1.5, 0, 13)]))
    set_prop("Markings/DockLane2", "points", vec3s([(3.6, 0, 1.4), (3.6, 0, 13)]))
    set_prop("Markings/DockStop2", "points", vec3s([(-0.4, 0, 2.6), (3.0, 0, 2.6)]))
    set_prop("Markings/BlockEdge", "points", vec3s([(4.3, 0, -6.8), (4.3, 0, 1.6)]))
    set_prop("Markings/LaneWhite1", "points", vec3s([(5.1, 0, 3), (5.1, 0, 15)]))
    set_prop("Ground/FloorMain", "transform", xf(-7.0, -0.06, -12))
    g["blocks"][g["find"]("Ground/FloorMain")] = g["blocks"][g["find"]("Ground/FloorMain")]
    # floor mesh 37 wider
    for i, b in enumerate(blk):
        if b.startswith('[sub_resource type="BoxMesh" id="BoxMesh_37"]'):
            blk[i] = '[sub_resource type="BoxMesh" id="BoxMesh_37"]\nsize = Vector3(22.4, 0.12, 24.4)\n'

    # ---- road out to the west (yard entrance, off-screen bottom left) -----
    remove("Ground/Curb3")
    for i, b in enumerate(blk):
        if b.startswith('[sub_resource type="PlaneMesh" id="PlaneMesh_33"]'):
            blk[i] = '[sub_resource type="PlaneMesh" id="PlaneMesh_33"]\nsize = Vector2(71.8, 7.1)\n'
    set_prop("Ground/Asphalt1", "transform", xf(-20.7, -0.02, 16.05))
    for i, b in enumerate(blk):
        if b.startswith('[sub_resource type="BoxMesh" id="BoxMesh_43"]'):
            blk[i] = '[sub_resource type="BoxMesh" id="BoxMesh_43"]\nsize = Vector3(71.8, 0.16, 0.25)\n'
    set_prop("Ground/Curb1", "transform", xf(-20.7, 0.03, 19.7))
    set_prop("Markings/LaneCentre", "points", vec3s([(-56, 0, 17.8), (14.8, 0, 17.8)]))

    # ---- sim + trucks ----------------------------------------------------
    remove("Vehicles/TruckRed")
    remove("Vehicles/PalletJack1")
    sim = script("res://scripts/sim/terminal_sim.gd")
    dock = script("res://scripts/sim/dock.gd")
    drv = script("res://scripts/level/truck_driver.gd")
    add("Sim", ".", f'script = ExtResource("{sim}")', typ="Node")
    add("Dock1", "Sim", f'script = ExtResource("{dock}")\ndock_id = 1', typ="Node")
    add("Dock2", "Sim", f'script = ExtResource("{dock}")\ndock_id = 2', typ="Node")
    d2x = 0.35 + DOCK2_DX
    for n, (dx, cab, radius, ref) in {1: (-4.35, "12_truck_cab_re", 5.2, True),
                                      2: (d2x, "14_truck_cab_bl", 4.0, False)}.items():
        add(f"TruckDriver{n}", "Vehicles", f"""script = ExtResource("{drv}")
dock_id = {n}
sim_path = NodePath("../../Sim")
dock_visual_path = NodePath("../../Docks/DockDoor{n}")
cab_scene = ExtResource("{cab}")
trailer_scene = ExtResource("13_trailer_box")
entry_points = {vec3s([(-62, 0, 16.8), (10, 0, 16.8)])}
reverse_points = {vec3s([(dx + radius, 0, 16.8), (dx, 0, 16.8), (dx, 0, 0.78)])}
exit_points = {vec3s([(dx, 0, 18.6), (-62, 0, 18.6)])}
corner_radius = {fmt(radius)}
handles_reference_state = {"true" if ref else "false"}""", typ="Node3D")

    # ---- unloading shuttle (dock 1 <-> INBOUND) ---------------------------
    sh = script("res://scripts/level/unload_shuttle.gd")
    add("Shuttle1", "Workers", f"""transform = {xf(3.6, 0, -16.0)}
script = ExtResource("{sh}")
dock_id = 1
dock_point = Vector3(-4.35, 0, -2.6)
drop_point = Vector3(3.6, 0, -16.0)
via_point = Vector3(-1.2, 0, -10.8)
speed = 1.5
load_path = NodePath("Load")
worker_path = NodePath("Pusher")
move_animation = &"Carry"
""", typ="Node3D")
    add("Jack", "Workers/Shuttle1", "", instance=scene("pallet_jack"))
    add("Load", "Workers/Shuttle1", f"transform = {xf(0, 0.09, -0.2, 90)}", instance="20_pallet_boxes")
    add("Pusher", "Workers/Shuttle1", f"transform = {xf(0, 0, 1.05, 0, 1.2)}", instance="37_worker")

    # ---- racks: open rack_bay + stock -------------------------------------
    for p in ["RackA1", "RackA2", "RackB1", "RackB2", "RackBack2", "RackBack3", "RackLeft1", "RackBack1",
              "RW1", "RW2", "RW3", "Box2", "PB13", "PB14", "PB5", "Box1"]:
        remove("Interior/" + p)
    rs = script("res://scripts/level/rack_stock.gd")
    racks = [  # three runs along Z, 5.4 m pitch = 4.3 m clear aisle in front of every face (r17)
        ("RackA", -20.6, [-11.0, -13.81], [["a.a", "a.c", "c.a"], ["c.a", "a.a", "a.c"]]),
        ("RackB", -15.2, [-11.0, -13.81], [["c.a", "a.c", "a.a"], ["a.a", "c.a", "a.."]]),
        ("RackMid", -9.8, [-16.4, -19.21], [["a.c", "c.a", "a.a"], ["a.a", "a.c", "c.."]]),
    ]
    seed = 3
    for name, x, zs, pats in racks:
        for k, (z, pat) in enumerate(zip(zs, pats)):
            seed += 1
            add(f"{name}{k + 1}", "Interior", f"""transform = {xf(x, 0, z, 90)}
script = ExtResource("{rs}")
levels = PackedStringArray({", ".join('"%s"' % s for s in pat)})
random_seed = {seed}""", instance="18_rack_bay")
    add("RackBack1", "Interior", f"""transform = {xf(-9.8, 0, -22.02, 90)}
script = ExtResource("{rs}")
levels = PackedStringArray("a.c", "c.a", "a.a")
random_seed = 40""", instance="18_rack_bay")
    set_prop("Markings/RackLineA", "points", vec3s([(-13.2, 0, -8.8), (-13.2, 0, -20.4)]))
    set_prop("Markings/RackLineB", "points", vec3s([(-7.1, 0, -13.4), (-7.1, 0, -19.4)]))

    # floor storage: first slot at the origin, columns +X, rows -Z, aisle on the +Z side (r17)
    add("FloorStorage", "Interior", f"transform = {xf(-13.0, 0, -5.7, 0)}", typ="Node3D")

    # ---- interior clutter -------------------------------------------------
    PB = {"a": "20_pallet_boxes", "b": "19_pallet_boxes", "c": "21_pallet_boxes", "e": "22_pallet_stack",
          "s": "23_box_single", "p": scene("pallet")}
    for p in ["IN1", "IN2", "IN3", "IN4", "IN5", "IN6", "OUT1", "OUT2", "OUT3", "OUT4", "OUT5"]:
        remove("Interior/" + p)
    n = [0]

    def put(prefix, kind, x, z, yaw=0.0, y=0.0):
        n[0] += 1
        add(f"{prefix}{n[0]}", "Interior", f"transform = {xf(x, y, z, yaw)}", instance=PB[kind])

    for kind, x, z, yaw in INBOUND:
        put("IN", kind, x, z, yaw)
    for kind, x, z, yaw in OUTBOUND:
        put("OUT", kind, x, z, yaw)
    for kind, x, z, yaw, y in CLUTTER:
        put("CL", kind, x, z, yaw, y)

    # ---- workers ----------------------------------------------------------
    for k in range(1, 7):
        scale_node(f"Workers/Worker{k}", 1.2)
    wa = "36_worker_actor"
    add("Worker7", "Workers", f"""transform = {xf(-13.6, 0, -4.4, 0, 1.2)}
script = ExtResource("{wa}")
walk_animation = &"Carry"
idle_animation = &"Carry"
phase = 0.35
pause_time = 0.8
patrol_points = {vec3s([(-13.6, 0, -4.4), (-11.2, 0, -7.6), (-12.2, 0, -9.4)])}""", instance="38_worker_blueh")
    add("CarryBox", "Workers/Worker7", f"transform = {xf(0, 1.0, -0.32, 0, 0.83)}", instance="23_box_single")
    add("Worker8", "Workers", f"""transform = {xf(2.4, 0, -6.6, 0, 1.2)}
script = ExtResource("{wa}")
phase = 0.6
patrol_points = {vec3s([(2.4, 0, -6.6), (3.4, 0, -10.4), (8.5, 0, -9.4)])}""", instance="37_worker")
    add("Worker9", "Workers", f"""transform = {xf(-6.4, 0, -23.2, 120, 1.2)}
script = ExtResource("{wa}")
phase = 0.15""", instance="38_worker_blueh")
    # pallet jack 2 + worker 5 read as one worker pushing a loaded jack
    put_xf("Vehicles/PalletJack2", [float(a) for a in xf(9.0, 0, -18.4, 60).split("(")[1].rstrip(")").split(",")])
    add("Jack2Load", "Vehicles/PalletJack2", f"transform = {xf(0, 0.09, -0.2, 90)}", instance="21_pallet_boxes")
    put_xf("Workers/Worker5", [float(a) for a in xf(9.9, 0, -17.88, 60, 1.2).split("(")[1].rstrip(")").split(",")])
    set_prop("Workers/Worker5", "idle_animation", '&"Carry"')

    # ---- shell tint, canopy ---------------------------------------------
    tint = script("res://scripts/level/material_tint.gd")
    for p in ["Building", "Docks"]:
        set_prop(p, "script", f'ExtResource("{tint}")')
        set_prop(p, "tint", "Color(%s, %s, %s, 1)" % WALL_TINT)
    for i, b in enumerate(blk):
        if b.startswith('[sub_resource type="Gradient" id="Gradient_16"]'):
            blk[i] = '[sub_resource type="Gradient" id="Gradient_16"]\ncolors = PackedColorArray(%s)\n' % GRASS
    v = get_xf("Docks/Canopy2")
    v[2] *= CANOPY_DEPTH; v[5] *= CANOPY_DEPTH; v[8] *= CANOPY_DEPTH
    put_xf("Docks/Canopy2", v)

    # ---- blue truck bay: a little right and back --------------------------
    set_prop("Vehicles/TruckBlue", "transform", "Transform3D(-1, 0, 0, 0, 1, 0, 0, 0, -1, 11, 0, -8.4)")
    set_prop("Markings/BayOutline", "points", vec3s([(8.0, 0, -8.6), (14.0, 0, -8.6), (14.0, 0, 10), (8.0, 0, 10)]))
    set_prop("Markings/BayInner1", "points", vec3s([(8.8, 0, -8.2), (8.8, 0, 9.6)]))
    set_prop("Markings/BayInner2", "points", vec3s([(13.2, 0, -8.2), (13.2, 0, 9.6)]))
    set_prop("Markings/LaneWhite2", "points", vec3s([(15.0, 0, -5), (15.0, 0, 13.4)]))
    shift_x("Site/Bollard5", 2.4)
    shift_x("Site/Bollard6", 1.8)
    for i, b in enumerate(blk):
        if b.startswith('[sub_resource type="Gradient" id="Gradient_2"]'):
            blk[i] = '[sub_resource type="Gradient" id="Gradient_2"]\ncolors = PackedColorArray(0.5294, 0.5020, 0.4588, 1, 0.5843, 0.5569, 0.5137, 1)\n'


    # ---- site edges -------------------------------------------------------
    EDGES(g)

    # ---- r11+: refit for the 5.2 m shell (see R11 below) ------------------
    R11(g)


CAM = (-0.03, -6.14, 36.92, 42.0, 64.18, 30.0)

INBOUND = [  # kind, x, z, yaw  (pad x -3.4..4.6, z -20.6..-15.0); text along the front-left edge
    ("b", 1.0, -16.6, 0), ("a", 2.4, -16.5, 4), ("c", 3.8, -16.7, -3),
    ("c", -0.4, -18.1, 3), ("b", 1.0, -18.0, -2), ("a", 2.4, -18.2, 0), ("b", 3.8, -18.1, 6),
    ("a", 1.0, -19.5, 2),
]
OUTBOUND = [  # pad x 10.4..16.6, z -20.6..-15.4
    ("c", 11.6, -17.8, 0), ("e", 13.0, -17.9, 3), ("a", 14.4, -17.7, -4), ("e", 15.7, -18.0, 2),
    ("e", 11.7, -19.3, -2), ("b", 13.1, -19.4, 0), ("e", 14.5, -19.3, 5),
]
CLUTTER = [  # kind, x, z, yaw, y
    # front-left stack by the left wall
    ("b", -22.9, -3.4, 90, 0), ("a", -22.9, -3.4, 92, 1.17), ("c", -22.9, -4.8, 90, 0), ("a", -21.6, -3.2, 0, 0),
    ("s", -21.0, -4.6, 20, 0), ("s", -20.7, -4.9, -15, 0), ("s", -20.9, -4.7, 35, 0.404),
    # empty pallet piles and stock along the left wall, beside the first rack run
    ("e", -23.0, -9.6, 90, 0), ("e", -23.0, -10.7, 92, 0), ("e", -23.0, -10.7, 86, 0.72),
    ("c", -23.0, -16.8, 90, 0), ("a", -23.0, -18.2, 90, 0), ("b", -23.0, -21.6, 90, 0),
    # back wall
    ("e", -17.0, -25.0, 0, 0), ("e", -17.0, -25.0, 4, 0.72), ("c", -14.4, -25.0, 0, 0), ("s", -12.6, -25.2, 10, 0),
    ("s", -12.2, -25.3, -20, 0), ("b", -3.4, -25.0, 0, 0), ("a", -2.0, -25.0, 3, 0), ("e", 0.6, -25.0, 0, 0),
    # loose groups mid floor, clear of the aisles
    ("e", -0.6, -9.6, 20, 0), ("e", -0.6, -9.6, 25, 0.72),
    ("s", -3.0, -4.8, 25, 0), ("s", -2.6, -5.1, -10, 0), ("p", 1.2, -6.6, 15, 0), ("s", 1.3, -6.6, 0, 0.144),
    # under the canopy, next to dock 2
    ("e", 8.3, -4.6, 90, 0), ("e", 8.3, -4.6, 88, 0.72),
    # right wing: stock behind OUTBOUND and along the right wall
    ("a", 12.4, -24.9, 0, 0), ("c", 13.8, -25.0, 0, 0), ("b", 15.2, -24.9, 2, 0), ("a", 16.6, -25.0, 0, 0),
    ("c", 12.5, -23.6, 3, 0), ("b", 13.9, -23.6, -2, 0),
    ("a", 21.0, -16.0, 90, 0), ("b", 21.0, -17.4, 90, 0), ("c", 21.0, -18.8, 90, 0), ("a", 21.0, -21.4, 90, 0),
    ("e", 19.6, -16.2, 90, 0),
]


def EDGES(g):
    add, xf, set_prop, vec3s, scene, fmt = g["add"], g["xf"], g["set_prop"], g["vec3s"], g["scene"], g["fmt"]
    # trees: clear the road band, then fill the frame corners
    set_prop("Trees/BottomLeft", "points", vec3s([(-3.5, 0, 20.8), (-40, 0, 20.8)]))
    set_prop("Trees/BottomLeft", "spacing", "2.8")
    set_prop("Trees/BottomLeft", "depth", "6")
    set_prop("Trees/BottomLeft", "points", vec3s([(-3.0, 0, 20.3), (-40, 0, 20.3)]))
    set_prop("Trees/BottomFar", "points", vec3s([(16, 0, 23.5), (-40, 0, 23.5)]))
    for name, pts, spacing, depth, seed in TREE_BANDS:
        add(name, "Trees", f"""script = ExtResource("35_tree_scatter")
tree_scenes = Array[PackedScene]({TREES})
points = {vec3s(pts)}
spacing = {spacing}
depth = {depth}
random_seed = {seed}""", typ="Node3D")
    # neighbouring building at the far left
    nb = NEIGHBOUR
    add("NeighbourBuilding", "Site", f"transform = {xf(nb[0], 0, nb[1], nb[2], nb[3])}", instance="30_office_booth")
    for k, (x, z) in enumerate(EXTRA_BARRIERS):
        add(f"BarrierX{k}", "Site", f"transform = {xf(x, 0, z, 90)}", instance="27_jersey_barri")
    for k, (x, z, yaw) in enumerate(EXTRA_LAMPS):
        add(f"LampX{k}", "Site", f"transform = {xf(x, 0, z, yaw)}", instance="28_lamp_post")
    for k, (x, z, yaw) in enumerate(EXTRA_CCTV):
        add(f"CctvX{k}", "Site", f"transform = {xf(x, 0, z, yaw)}", instance="29_cctv_pole")
    for k, pts in enumerate(EXTRA_FENCES):
        add(f"FenceX{k}", "Site", f'script = ExtResource("31_fence_run")\npoints = {vec3s(pts)}', typ="Node3D")
    set_prop("Site/Booth", "transform", xf(*BOOTH))
    set_prop("Ground/BoothPad", "transform", xf(BOOTH[0], -0.03, BOOTH[2]))
    set_prop("Site/Lamp3", "transform", xf(*LAMP3))
    set_prop("Trees/Left", "points", vec3s([(-26.5, 0, -7), (-26.5, 0, -40)]))
    set_prop("Trees/Left", "spacing", "2.6")
    for k, (x, z, sc, kind) in enumerate(SINGLE_TREES):
        add(f"Tree{k}", "Trees", f"transform = {xf(x, 0, z, k * 47.0, sc)}", instance=kind)


CANOPY_DEPTH = 0.7
WALL_TINT = (1.0, 0.98, 0.94)
GRASS = "0.3255, 0.4706, 0.1725, 1, 0.3922, 0.5294, 0.2196, 1"
BOOTH = (23.2, 0, -8.4)
LAMP3 = (19.8, 0, -12.6, -90)
A, B, R = "32_tree_cone_a", "33_tree_cone_b", "34_tree_round"
SINGLE_TREES = [  # x, z, scale, scene
    (0.8, 20.9, 0.9, A), (-2.2, 20.6, 0.85, B), (3.2, 21.6, 0.9, R), (-5.0, 21.2, 0.85, A),
    (-22.0, 21.0, 0.9, R), (-25.0, 21.6, 1.0, A),
    (21.6, -4.0, 0.62, A), (24.0, -1.9, 0.6, R), (21.4, 3.0, 0.65, A), (22.4, 3.6, 0.7, B), (25.6, 2.6, 0.62, R), (21.6, 7.4, 0.68, R), (24.0, 8.2, 0.65, A),
    (-8.0, 20.7, 1.0, B), (-10.6, 20.9, 1.1, A), (-13.4, 20.6, 0.95, R),
]
TREE_BANDS = [  # name, polyline, spacing, depth, seed
]
NEIGHBOUR = (-37.0, 3.0, 90, 1.6)  # x, z, yaw, scale
EXTRA_BARRIERS = [(-13.4, 4.2)]
EXTRA_LAMPS = []
EXTRA_CCTV = [(17.6, 10.5, -90)]
EXTRA_FENCES = []


# =========================================================================
# r11+: refit for the 5.2 m shell (new Blender walls, dock_door, canopy).
# Runs after everything above; rebuilds the shell, ground and markings for a
# longer building (left wall at XL, back wall at ZB) and the wider dock pair.
# =========================================================================
XL, XR, ZB = -24.0, 22.0, -26.0   # left wall x, right wall x, back wall z
ZN = -14.0                       # front of the right wing (blue truck notch)
XS = 6.9                         # side wall right of dock 2 (canopy hangs on it)
XW = 19.0                        # left end of the right-wing front wall
SIDE_LEN = 6.4                   # side wall length back from the front
D1, D2 = -4.35, 0.35 + DOCK2_DX
WALL_H, PART_H = 5.2, 3.0
YEL = "0.902, 0.745, 0.322, 1"    # softer, warmer paint yellow
WHT = "0.886, 0.886, 0.867, 1"
BLU = "0.204, 0.42, 0.878, 1"
BAY = (9.7, 15.9, -12.6, 0.4)   # blue bay outline x0, x1, z0, z1
BLUE_TRUCK = (12.8, -11.8)       # trailer rear (rig origin)


def R11(g):
    add, xf, set_prop, vec3s, scene, fmt = g["add"], g["xf"], g["set_prop"], g["vec3s"], g["scene"], g["fmt"]
    blk, added, node_name = g["blocks"], g["added"], g["node_name"]
    nsub = [0]

    def kill(path):
        try:
            g["remove"](path)
            return
        except KeyError:
            pass
        parent, name = (path.rsplit("/", 1) + [None])[:2] if "/" in path else (".", path)
        for i, (p, b) in enumerate(added):
            if p == parent and b.startswith(f'[node name="{name}"'):
                del added[i]
                return
        raise KeyError(path)

    def sub(typ, body):
        nsub[0] += 1
        sid = f"{typ}_r{nsub[0]}"
        i = next(k for k, b in enumerate(blk) if b.startswith("[node"))
        blk.insert(i, f'[sub_resource type="{typ}" id="{sid}"]\n{body.strip()}\n')
        return f'SubResource("{sid}")'

    def mat(color, rough=0.85, extra=""):
        return sub("StandardMaterial3D", f"albedo_color = Color({color})\nroughness = {rough}\n{extra}")

    def box(sx, sy, sz):
        return sub("BoxMesh", f"size = Vector3({fmt(sx)}, {fmt(sy)}, {fmt(sz)})")

    def plane(sx, sz):
        return sub("PlaneMesh", f"size = Vector2({fmt(sx)}, {fmt(sz)})")

    def mesh(name, parent, pos, m, material, yaw=0.0, shadow=True):
        body = f"transform = {xf(*pos, yaw)}\nmesh = {m}\nsurface_material_override/0 = {material}"
        if not shadow:
            body += "\ncast_shadow = 0"
        add(name, parent, body, typ="MeshInstance3D")

    def line(path, pts, width, color, dash=0.0, gap=1.0, closed=False, y=None):
        set_prop(path, "points", vec3s(pts))
        set_prop(path, "width", fmt(width))
        set_prop(path, "color", f"Color({color})")
        set_prop(path, "dash_length", fmt(dash))
        set_prop(path, "gap_length", fmt(gap))
        if closed:
            set_prop(path, "closed", "true")
        if y is not None:
            set_prop(path, "transform", xf(0, y, 0))

    def new_line(name, pts, width, color, dash=0.0, gap=1.0, closed=False, y=0.0, h=0.012):
        body = (f'transform = {xf(0, y, 0)}\nscript = ExtResource("25_marking_line")\npoints = {vec3s(pts)}\n'
                f"width = {fmt(width)}\ncolor = Color({color})\nheight = {fmt(h)}")
        if dash:
            body += f"\ndash_length = {fmt(dash)}\ngap_length = {fmt(gap)}"
        if closed:
            body += "\nclosed = true"
        add(name, "Markings", body, typ="MeshInstance3D")

    # ---- shell: rebuild every wall piece ---------------------------------
    for b in list(blk):
        n = node_name(b)
        if n and n.startswith("Building/"):
            g["remove"](n)
    kill("Building/BetweenDocks")

    walls = []  # (name, x0, z0, x1, z1, outward yaw)

    def run_wall(prefix, x0, z0, x1, z1, yaw, h=1.0, parent="Building"):
        ln = math.hypot(x1 - x0, z1 - z0)
        n = max(1, round(ln / 4.0))
        sx = ln / (n * 4.0)
        for k in range(n):
            t = (k + 0.5) / n
            x, z = x0 + (x1 - x0) * t, z0 + (z1 - z0) * t
            c, s_ = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
            r = [c * sx, 0, s_, 0, h, 0, -s_ * sx, 0, c]
            add(f"{prefix}{k}", parent, "transform = Transform3D(" + ", ".join(fmt(a) for a in r + [x, 0, z]) + ")",
                instance="6_wall_segment")

    run_wall("FrontL", XL, 0, D1 - 2.0, 0, 0)
    run_wall("BetweenDocks", D1 + 2.0, 0, D2 - 2.0, 0, 0)
    run_wall("FrontR", D2 + 2.0, 0, XS, 0, 0)
    run_wall("BlockSide", XS, 0, XS, -SIDE_LEN, 90)
    run_wall("WingFront", XW, ZN, XR, ZN, 0)
    run_wall("Left", XL, ZB, XL, 0, -90)
    run_wall("Back", XR, ZB, XL, ZB, 180)
    run_wall("Right", XR, ZN, XR, ZB, 90)
    for k, (x, z) in enumerate([(XL, 0), (XL, ZB), (XR, ZB), (XR, ZN), (XW, ZN), (XS, 0), (XS, -SIDE_LEN)]):
        add(f"Corner{k}", "Building", f"transform = {xf(x, 0, z)}", instance="7_wall_corner")
    # window in the long front-left wall (target: left of dock 1)
    glass = mat("0.22, 0.29, 0.35, 1", 0.15, "metallic = 0.4\nmetallic_specular = 0.8")
    frame = mat("0.62, 0.64, 0.66, 1", 0.6)
    for k, x in enumerate([-11.4, -17.8]):
        mesh(f"WindowFrame{k}", "Building", (x, 2.35, 0.2), box(1.5, 1.6, 0.08), frame)
        mesh(f"WindowGlass{k}", "Building", (x, 2.35, 0.25), box(1.25, 1.35, 0.04), glass)
    # side door in the front-left wall
    door_mat = mat("0.36, 0.38, 0.41, 1", 0.6, "metallic = 0.3")
    mesh("SideDoor", "Building", (-14.6, 1.1, 0.2), box(1.1, 2.2, 0.08), door_mat)

    # ---- docks: dark surround so each bay reads as a separate black frame --
    dark = mat("0.15, 0.16, 0.17, 1", 0.8)
    band = mat("0.95, 0.76, 0.19, 1", 0.5)
    for n_, x in ((1, D1), (2, D2)):
        set_prop(f"Docks/DockDoor{n_}", "transform", xf(x, 0, 0))
        mesh(f"Surround{n_}Top", "Docks", (x, 4.6, 0.33), box(5.4, 1.16, 0.36), dark)   # opening top 4.0 .. just under wall top 5.2
        for s in (-1, 1):
            mesh(f"Surround{n_}{'LR'[(s + 1) // 2]}", "Docks", (x + s * 2.32, 2.59, 0.33), box(0.76, 5.18, 0.36), dark)
        set_prop(f"Docks/Hazard{n_}", "transform", xf(x, 0.004, 1.05))
        # broad yellow band on the roller door; child of Door so it rolls up with it
        mesh(f"DoorBand", f"Docks/DockDoor{n_}/DockDoor/Door", (0, -2.0, 0.06), box(2.9, 0.42, 0.02), band, shadow=False)
    # canopy hangs on the side wall right of dock 2, facing +X, clear of the "2"
    set_prop("Docks/Canopy2", "transform", "Transform3D(0, 0, 0.72, 0, 1, 0, -1, 0, 0, %s, 0, %s)" % (
        fmt(XS + 0.16), fmt(-SIDE_LEN / 2)))

    # ---- ground -----------------------------------------------------------
    # asphalt about 17 % lighter, a bit more variation
    for b_i, b in enumerate(blk):
        if b.startswith('[sub_resource type="Gradient" id="Gradient_9"]'):
            blk[b_i] = ('[sub_resource type="Gradient" id="Gradient_9"]\noffsets = PackedFloat32Array(0, 0.55, 1)\n'
                        "colors = PackedColorArray(0.305, 0.318, 0.338, 1, 0.345, 0.357, 0.376, 1, 0.38, 0.388, 0.402, 1)\n")
        if b.startswith('[sub_resource type="Gradient" id="Gradient_2"]'):  # interior concrete
            blk[b_i] = ('[sub_resource type="Gradient" id="Gradient_2"]\noffsets = PackedFloat32Array(0, 0.5, 1)\n'
                        "colors = PackedColorArray(0.47, 0.452, 0.42, 1, 0.52, 0.5, 0.466, 1, 0.555, 0.535, 0.5, 1)\n")
    asp = 'SubResource("StandardMaterial3D_14")'
    con = 'SubResource("StandardMaterial3D_7")'
    side = 'SubResource("StandardMaterial3D_28")'
    kerb = 'SubResource("StandardMaterial3D_29")'
    for p in ["Asphalt0", "Asphalt2", "Asphalt3", "Asphalt4", "FloorMain", "FloorRight", "ApronFront", "ApronLeft",
              "BoothPad", "Curb0", "Curb1", "Curb2", "Curb4", "Curb5", "Curb6"]:
        g["remove"]("Ground/" + p)
    set_prop("Ground/Asphalt1", "transform", xf(-17.3, -0.02, 16.05))
    for b_i, b in enumerate(blk):
        if b.startswith('[sub_resource type="PlaneMesh" id="PlaneMesh_33"]'):
            blk[b_i] = '[sub_resource type="PlaneMesh" id="PlaneMesh_33"]\nsize = Vector2(78.6, 7.1)\n'

    def pad(name, x0, x1, z0, z1, material, y=-0.02, kind="plane", shadow=False):
        cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
        m = plane(x1 - x0, z1 - z0) if kind == "plane" else box(x1 - x0, 0.12, z1 - z0)
        mesh(name, "Ground", (cx, y, cz), m, material, shadow=shadow)

    pad("Asphalt0", -14.6, XW, ZN, 12.55, asp)             # front yard + blue notch
    pad("AsphaltL", -30.0, -14.6, ZN, 7.6, asp)            # left yard, grass beyond
    pad("Asphalt2", -30.0, XL, -31.0, 0.0, asp)            # left lane
    pad("Asphalt3", -30.0, 28.0, -31.0, ZB, asp)           # back road
    pad("Asphalt4", XR, 28.0, ZB, ZN, asp)                 # right lane
    pad("FloorMain", XL, XS, ZB, 0.0, con, -0.06, "box", True)
    pad("FloorRight", XS, XR, ZB, ZN, con, -0.06, "box", True)
    pad("FloorNotch", XS, BAY[0] - 0.35, ZN, -0.2, con, -0.06, "box", True)   # under the canopy
    pad("ApronFront", XL, D1 - 2.8, 0.0, 2.7, side, -0.06, "box", True)       # walkway along the front
    pad("BoothPad", BOOTH[0] - 2.5, BOOTH[0] + 2.5, BOOTH[2] - 2.3, BOOTH[2] + 2.5, side, -0.03, "box", True)
    # kerbs between asphalt and grass
    for name, x, z, sx, sz in [
            ("Curb0", (XL + D1 - 2.8) / 2, 2.78, D1 - 2.8 - XL, 0.25),
            ("Curb1", -17.3, 19.7, 78.6, 0.3),
            ("Curb2", -30.15, -9.2, 0.3, 43.5),
            ("Curb4", XW + 0.15, -0.7, 0.3, 26.6),
            ("Curb5", 28.15, -22.5, 0.3, 17.0),
            ("Curb6", 25.0, ZN + 0.15, 6.3, 0.3),
            ("Curb7", -22.3, 7.75, 15.4, 0.3),
            ("Curb8", -14.75, 10.1, 0.3, 4.9)]:
        mesh(name, "Ground", (x, 0.03, z), box(sx, 0.16, sz), kerb)
    # wear and oil stains on the floor and apron (radial decals)
    stain_grad = sub("Gradient", "offsets = PackedFloat32Array(0, 0.55, 1)\n"
                     "colors = PackedColorArray(0.16, 0.15, 0.14, 0.55, 0.2, 0.19, 0.17, 0.25, 0.25, 0.24, 0.22, 0)")
    stain_tex = sub("GradientTexture2D", f"gradient = {stain_grad}\nfill = 1\nfill_from = Vector2(0.5, 0.5)\n"
                    "fill_to = Vector2(1, 0.5)\nwidth = 128\nheight = 128")
    for k, (x, z, sx, sz, op) in enumerate([
            (D1, -2.4, 2.6, 3.4, 0.6), (D2, -2.0, 2.4, 2.6, 0.45), (-9.5, -8.0, 3.0, 2.2, 0.35),
            (-17.3, -16.0, 2.0, 3.2, 0.35), (-6.0, -14.0, 2.4, 1.8, 0.3), (5.2, -12.0, 2.8, 2.2, 0.35),
            (12.0, -24.0, 2.2, 1.6, 0.3), (D1, 5.5, 2.2, 3.0, 0.5), (D2 + 0.4, 4.4, 1.8, 2.4, 0.45),
            (12.4, -6.0, 1.8, 2.6, 0.45), (-3.0, -24.0, 2.6, 1.6, 0.3), (-13.0, -21.5, 2.0, 2.0, 0.3)]):
        add(f"Stain{k}", "Ground", f"transform = {xf(x, 0.0, z, k * 37.0)}\nsize = Vector3({fmt(sx)}, 0.6, {fmt(sz)})\n"
            f"texture_albedo = {stain_tex}\nmodulate = Color(1, 1, 1, {fmt(op)})\ncull_mask = 1", typ="Decal")

    # ---- interior office (back right), refit to 3.0 m partitions ------------
    for p in ["PartitionA", "PartitionB", "PartitionC", "PartitionD", "PartitionPost", "Desk1", "Desk2"]:
        g["remove"]("Office/" + p)
    OX0, OX1, OZ = 3.6, 10.6, -21.6       # office front wall along z=OZ, side wall at x=OX0
    hs = PART_H / WALL_H

    def part(name, x0, z0, x1, z1, yaw, h=hs, y=0.0):
        ln = math.hypot(x1 - x0, z1 - z0)
        sx = ln / 4.0
        c, s_ = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
        r = [c * sx, 0, s_, 0, h, 0, -s_ * sx, 0, c]
        add(name, "Office", "transform = Transform3D(" + ", ".join(fmt(a) for a in r + [(x0 + x1) / 2, y, (z0 + z1) / 2]) + ")",
            instance="6_wall_segment")

    # front wall: solid | door gap 1.0 | solid | window 2.2 | solid
    part("PartitionA", OX0, OZ, 5.0, OZ, 0)
    part("PartitionB", 6.0, OZ, 7.0, OZ, 0)
    part("PartitionC", 9.2, OZ, OX1, OZ, 0)
    part("WindowSill", 7.0, OZ, 9.2, OZ, 0, h=1.0 / WALL_H)
    part("WindowHead", 7.0, OZ, 9.2, OZ, 0, h=0.6 / WALL_H, y=2.4)
    part("DoorHead", 5.0, OZ, 6.0, OZ, 0, h=0.8 / WALL_H, y=2.2)
    part("PartitionD", OX0, ZB, OX0, OZ, -90)
    add("PartitionPost", "Office", f"transform = {xf(OX0, 0, OZ, 0, 1)}\n" + "", instance="7_wall_corner")
    set_post = blk  # noqa
    mesh("OfficeGlass", "Office", (8.1, 1.7, OZ), box(2.2, 1.4, 0.05), glass, shadow=False)
    mesh("OfficeDoor", "Office", (5.5, 1.1, OZ + 0.02), box(0.96, 2.2, 0.07), mat("0.55, 0.4, 0.26, 1", 0.7))
    add("Desk1", "Office", f"transform = {xf(6.4, 0, -24.6)}", instance="24_office_desk")
    add("Desk2", "Office", f"transform = {xf(9.2, 0, -24.6)}", instance="24_office_desk")
    add("Cabinet", "Office", f"transform = {xf(4.3, 0, -23.4, 90)}", instance="23_box_single")
    mesh("OfficeFloor", "Office", ((OX0 + OX1) / 2, 0.003, (OZ + ZB) / 2), plane(OX1 - OX0, OZ - ZB),
         mat("0.6, 0.6, 0.6, 1", 0.9), shadow=False)
    # small fire-hose box and a sign on the back wall (wall-top items refit to 5.2 m)
    mesh("FireBox", "Office", (-1.0, 1.6, ZB + 0.3), box(0.6, 0.8, 0.2), mat("0.75, 0.12, 0.1, 1", 0.5))

    # ---- markings -----------------------------------------------------------
    # zones: INBOUND centre-left, OUTBOUND right (both fully clear of walls)
    INB = (-3.4, 4.6, -20.6, -15.0)
    OUTB = (10.4, 16.6, -20.6, -15.4)
    for b_i, b in enumerate(blk):
        if b.startswith('[sub_resource type="PlaneMesh" id="PlaneMesh_54"]'):
            blk[b_i] = f'[sub_resource type="PlaneMesh" id="PlaneMesh_54"]\nsize = Vector2({fmt(INB[1] - INB[0])}, {fmt(INB[3] - INB[2])})\n'
        if b.startswith('[sub_resource type="PlaneMesh" id="PlaneMesh_56"]'):
            blk[b_i] = f'[sub_resource type="PlaneMesh" id="PlaneMesh_56"]\nsize = Vector2({fmt(OUTB[1] - OUTB[0])}, {fmt(OUTB[3] - OUTB[2])})\n'
        if b.startswith('[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_53"]'):
            blk[b_i] = '[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_53"]\nalbedo_color = Color(0.43, 0.435, 0.45, 1)\nroughness = 0.8\n'
        if b.startswith('[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_55"]'):
            blk[b_i] = '[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_55"]\nalbedo_color = Color(0.78, 0.62, 0.33, 1)\nroughness = 0.8\n'
    set_prop("Markings/InboundFill", "transform", xf((INB[0] + INB[1]) / 2, 0.006, (INB[2] + INB[3]) / 2))
    line("Markings/InboundOutline", [(INB[0], 0, INB[2]), (INB[1], 0, INB[2]), (INB[1], 0, INB[3]), (INB[0], 0, INB[3])],
         0.42, BLU, closed=True)
    set_prop("Markings/InboundText", "transform", "Transform3D(1, 0, 0, 0, 0, 1, 0, -1, 0, %s, 0.016, %s)" % (
        fmt(INB[0] + 1.8), fmt(INB[3] - 0.7)))
    set_prop("Markings/OutboundFill", "transform", xf((OUTB[0] + OUTB[1]) / 2, 0.006, (OUTB[2] + OUTB[3]) / 2))
    line("Markings/OutboundOutline", [(OUTB[0], 0, OUTB[2]), (OUTB[1], 0, OUTB[2]), (OUTB[1], 0, OUTB[3]), (OUTB[0], 0, OUTB[3])],
         0.3, YEL, closed=True)
    set_prop("Markings/OutboundText", "transform", "Transform3D(1, 0, 0, 0, 0, 1, 0, -1, 0, %s, 0.016, %s)" % (
        fmt((OUTB[0] + OUTB[1]) / 2 + 1.0), fmt(OUTB[3] - 0.75)))
    for p in ["InboundText", "OutboundText"]:
        set_prop("Markings/" + p, "outline_size", "0")
        set_prop("Markings/" + p, "pixel_size", "0.0064")
    # interior: solid painted edge strips instead of dashed walkways
    line("Markings/WalkwayA", [(XL + 0.6, 0, -6.4), (-6.8, 0, -6.4)], 0.14, YEL)            # front aisle edge
    line("Markings/WalkwayB", [(-12.5, 0, -8.6), (-12.5, 0, -22.8)], 0.14, YEL)              # rack block edge
    line("Markings/WalkwayC", [(-5.2, 0, -12.4), (6.4, 0, -12.4)], 0.14, YEL)                 # cross aisle
    line("Markings/WalkwayD", [(8.6, 0, -14.6), (8.6, 0, -24.6)], 0.14, YEL)                  # office/outbound edge
    line("Markings/RackLineA", [(-21.0, 0, -8.9), (-14.0, 0, -8.9)], 0.12, YEL)
    line("Markings/RackLineB", [(-12.0, 0, -13.4), (-4.4, 0, -13.4)], 0.12, YEL)
    # exterior: yellow ~40 % thinner, warmer; dock lanes for the wider pair
    ext_y = -0.02
    line("Markings/DockLane0", [(D1 - 3.05, 0, 1.6), (D1 - 3.05, 0, 13)], 0.13, YEL, y=ext_y)
    line("Markings/DockLane1", [((D1 + D2) / 2, 0, 1.6), ((D1 + D2) / 2, 0, 13)], 0.13, YEL, y=ext_y)
    line("Markings/DockLane2", [(D2 + 3.05, 0, 1.6), (D2 + 3.05, 0, 13)], 0.13, YEL, y=ext_y)
    line("Markings/DockStop1", [(D1 - 1.7, 0, 2.7), (D1 + 1.7, 0, 2.7)], 0.18, YEL, y=ext_y)
    line("Markings/DockStop2", [(D2 - 1.7, 0, 2.7), (D2 + 1.7, 0, 2.7)], 0.18, YEL, y=ext_y)
    line("Markings/ParkLine0", [(-8.8, 0, 4.4), (-8.8, 0, 11.0)], 0.11, YEL, y=ext_y)
    line("Markings/ParkLine1", [(-11.8, 0, 4.4), (-11.8, 0, 11.0)], 0.11, YEL, y=ext_y)
    line("Markings/ParkEdge", [(-12.6, 0, 4.4), (-7.6, 0, 4.4)], 0.11, YEL, y=ext_y)
    line("Markings/BayOutline", [(BAY[0], 0, BAY[2]), (BAY[1], 0, BAY[2]), (BAY[1], 0, BAY[3]), (BAY[0], 0, BAY[3])],
         0.42, BLU, closed=True, y=ext_y)
    line("Markings/BayInner1", [(BAY[0] + 0.75, 0, BAY[2] + 0.5), (BAY[0] + 0.75, 0, BAY[3] - 0.4)], 0.1, WHT, y=ext_y)
    line("Markings/BayInner2", [(BAY[1] - 0.75, 0, BAY[2] + 0.5), (BAY[1] - 0.75, 0, BAY[3] - 0.4)], 0.1, WHT, y=ext_y)
    line("Markings/YardEdge", [(-8.0, 0, 15.6), (XW - 0.2, 0, 15.6)], 0.12, YEL, y=ext_y)
    line("Markings/LaneCentre", [(-56, 0, 17.8), (XW + 4, 0, 17.8)], 0.1, WHT, 1.8, 1.8, y=ext_y)
    line("Markings/LaneLeft", [(-27.0, 0, -29.0), (-27.0, 0, -1.0)], 0.1, WHT, 2.0, 2.0, y=ext_y)
    line("Markings/LaneBack", [(-28.0, 0, -28.5), (26.0, 0, -28.5)], 0.1, WHT, 2.0, 2.0, y=ext_y)
    line("Markings/LaneWhite1", [(BAY[0] - 0.9, 0, 0.6), (BAY[0] - 0.9, 0, 14.6)], 0.1, WHT, y=ext_y)
    line("Markings/LaneWhite2", [(XW - 0.5, 0, -12.0), (XW - 0.5, 0, 14.0)], 0.1, WHT, 1.8, 1.8, y=ext_y)
    line("Markings/LaneWhite3", [(-24.0, 0, 6.4), (-16.0, 0, 6.4)], 0.1, WHT, 1.5, 1.5, y=ext_y)
    line("Markings/BlockEdge", [(XS + 0.2, 0, ZN), (XW, 0, ZN)], 0.16, YEL, y=0.0)   # notch edge at the floor
    new_line("ApronEdge", [(XL + 0.2, 0, 2.5), (D1 - 2.9, 0, 2.5)], 0.12, YEL)
    new_line("NotchEdge", [(BAY[0] - 0.45, 0, -0.4), (BAY[0] - 0.45, 0, ZN + 0.3)], 0.12, YEL)

    # ---- site ---------------------------------------------------------------
    bol = [(D1 - 2.85, 0.75), (D1 + 2.85, 0.75), (D2 - 2.85, 0.75), (D2 + 2.85, 0.75),
           (BAY[0] - 0.4, -0.6), (BAY[0] - 0.4, ZN + 0.6), (BAY[1] + 0.5, ZN + 0.6),
           (-9.4, 2.35), (-13.2, 2.35), (-17.0, 2.35), (-20.8, 2.35),
           (BAY[1] + 0.5, -6.0), (BAY[1] + 0.5, -3.0), (BAY[1] + 0.5, -0.4)]
    for k, (x, z) in enumerate(bol):
        set_prop(f"Site/Bollard{k}", "transform", xf(x, 0, z))
    add("Bollard14", "Site", f"transform = {xf(XS + 2.35, 0, -0.5)}", instance="26_bollard")
    for k, z in enumerate([6.4, 8.6, 10.8]):
        set_prop(f"Site/Barrier{k}", "transform", xf(-13.4, 0, z, 90))
    set_prop("Site/Lamp0", "transform", xf(-22.6, 0, 4.2, 90))
    set_prop("Site/Lamp1", "transform", xf(-18.4, 0, 10.0, 90))
    set_prop("Site/Lamp2", "transform", xf(-26.6, 0, -12.0, 90))
    set_prop("Site/Lamp4", "transform", xf(-26.0, 0, -28.2))
    set_prop("Site/Cctv1", "transform", xf(XW + 0.9, 0, -1.4, -90))
    set_prop("Site/Booth", "transform", xf(*BOOTH))
    # fences: left yard with a corner, right side with a corner toward the booth
    set_prop("Site/FenceLeft", "points", vec3s([(-30.8, 0, 8.3), (-15.3, 0, 8.3), (-15.3, 0, 12.2)]))
    set_prop("Site/FenceLeftOuter", "points", vec3s([(-30.8, 0, 12.0), (-30.8, 0, -31.4)]))
    set_prop("Site/FenceBack", "points", vec3s([(-30.8, 0, -31.6), (28.6, 0, -31.6)]))
    set_prop("Site/FenceFar", "points", vec3s([(28.6, 0, -31.6), (28.6, 0, -1.0)]))
    set_prop("Site/FenceRight", "points", vec3s([(XW + 1.3, 0, ZN + 0.4), (XW + 1.3, 0, 0.6), (28.6, 0, 0.6)]))
    set_prop("Site/FenceBooth", "points", vec3s([(XR + 0.4, 0, ZN - 0.2), (28.6, 0, ZN - 0.2)]))
    # blue truck inside its outline, rear short of the OUTBOUND label
    set_prop("Vehicles/TruckBlue", "transform", "Transform3D(-1, 0, 0, 0, 1, 0, 0, 0, -1, %s, 0, %s)" % (
        fmt(BLUE_TRUCK[0]), fmt(BLUE_TRUCK[1])))
    set_prop("Vehicles/Forklift", "transform", xf(-8.8, 0, -9.6, -135))

    # ---- trees: foreground ones smaller, frame edges filled ----------------
    set_prop("Trees/Left", "points", vec3s([(-33.0, 0, -6.0), (-33.0, 0, -40.0)]))
    set_prop("Trees/LeftNear", "points", vec3s([(-32.0, 0, 10.0), (-32.0, 0, -4.0)]))
    set_prop("Trees/LeftFront", "points", vec3s([(-17.0, 0, 9.4), (-30.0, 0, 9.4)]))
    set_prop("Trees/LeftFront", "depth", "2.0")
    set_prop("Trees/Back", "points", vec3s([(-31.0, 0, -34.0), (34.0, 0, -34.0)]))
    set_prop("Trees/Right", "points", vec3s([(31.0, 0, -36.0), (31.0, 0, -2.0)]))
    set_prop("Trees/BottomRight", "points", vec3s([(21.6, 0, 3.0), (21.6, 0, 34.0)]))
    set_prop("Trees/BottomRight", "scale_range", "Vector2(0.6, 0.75)")
    set_prop("Trees/BottomRight", "spacing", "4.2")
    set_prop("Trees/BottomRight", "depth", "12")
    # ---- workers refit to the new floor plan ------------------------------
    for name, pos, yaw, pts in [
            ("Worker1", (-14.6, -3.9), 0, [(-14.6, -3.9), (-9.0, -4.4)]),
            ("Worker2", (-17.5, -12.4), 100, None),
            ("Worker3", (-8.2, -14.6), 0, [(-8.2, -14.6), (-8.2, -21.8)]),
            ("Worker4", (6.0, -8.2), 0, [(6.0, -8.2), (6.2, -14.8)]),
            ("Worker6", (-1.0, -4.0), 60, [(-2.6, -3.2), (1.8, -5.2)])]:
        set_prop("Workers/" + name, "transform", xf(pos[0], 0, pos[1], yaw, 1.2))
        if pts:
            set_prop("Workers/" + name, "patrol_points", vec3s([(x, 0, z) for x, z in pts]))
    # ---- light: crisper, slightly lower sun so shadows read like the target
    set_prop("Sun", "transform", "Transform3D(-0.1739, -0.6844, 0.7080, 0.0000, 0.7190, 0.6950, -0.9848, 0.1208, -0.1250, 0, 30, 0)")  # sun from +X, a little from behind
    set_prop("Sun", "light_energy", "1.55")
    set_prop("Sun", "shadow_bias", "0.04")
    set_prop("Sun", "shadow_normal_bias", "1.6")
    set_prop("Sun", "shadow_blur", "1.6")
    set_prop("Sun", "directional_shadow_max_distance", "110.0")
    set_prop("Sun", "directional_shadow_split_1", "0.1")
    set_prop("Sun", "directional_shadow_split_2", "0.25")
