"""Pose solver and worker actions (gait + idle-time activities). Imported by build_worker.py.

Everything is in armature space = model space: Blender Z up, the worker faces +Y,
metres, feet at the origin. Each action is a pose function of time; it is keyed on
every frame at 24 fps (linear), so IK contacts (planted feet, hands on props, the
second hand on a broom) hold on every frame, not only on keys.

Limbs are solved as two-bone IK (hinge axis from a pole), feet roll heel -> flat ->
toe with the ground contact point locked, hands are oriented by a grip axis.

Hand / prop convention (see PROP_* below and the build report):
  prop local +Y (Blender) = grip axis = glTF/Godot -Z, out of the pinky side of the fist
  prop local +Z (Blender) = along the hand bone, toward the knuckles = Godot +Y
  origin = centre of the fist (the hand box centre).
"""
import math

import bpy
from mathutils import Matrix, Vector

FPS = 24
UP = Vector((0, 0, 1))

# Gait shared by Walk, Carry and PushJack (treadmill: the root is moved by Godot).
GAIT_FRAMES = 26                     # 1.0833 s per cycle (two steps)
GAIT_SPEED = 1.3                     # m/s, model units (WorkerActor.anim_speed)
GAIT_STRIDE = GAIT_SPEED * GAIT_FRAMES / FPS   # 1.4083 m per cycle, 0.704 m per step
SWEEP_SPEED = 0.2                    # m/s root speed for Sweep


def rx(deg):
    return Matrix.Rotation(math.radians(deg), 3, "X")


def ry(deg):
    return Matrix.Rotation(math.radians(deg), 3, "Y")


def rz(deg):
    return Matrix.Rotation(math.radians(deg), 3, "Z")


def body_rot(pitch=0.0, roll=0.0, yaw=0.0):
    """pitch>0 tips the top forward (+Y), roll>0 tips it right (+X), yaw>0 turns left."""
    return rz(yaw) @ ry(roll) @ rx(-pitch)


def V(*a):
    return Vector(a)


def lerp(a, b, t):
    return a + (b - a) * t


def smooth(t):
    t = min(1.0, max(0.0, t))
    return t * t * (3 - 2 * t)


def track(t, keys, loop=True):
    """Catmull-Rom through (time, value) keys; value float or tuple/Vector.

    loop: t in [0,1), keys span 0..1 with first == last value (period 1).
    """
    ts = [k[0] for k in keys]
    vs = [Vector(k[1]) if not isinstance(k[1], (int, float)) else k[1] for k in keys]
    n = len(keys)
    if loop:
        t = t % 1.0
    else:
        t = min(max(t, ts[0]), ts[-1])
    i = 0
    while i < n - 2 and t >= ts[i + 1]:
        i += 1
    t0, t1 = ts[i], ts[i + 1]
    s = 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)

    def at(j):
        if loop:
            m = n - 1
            return vs[j % m]
        return vs[min(max(j, 0), n - 1)]
    p0, p1, p2, p3 = at(i - 1), at(i), at(i + 1), at(i + 2)
    if not loop and i == 0:
        p0 = p1
    if not loop and i + 1 == n - 1:
        p3 = p2
    s2, s3 = s * s, s * s * s
    return 0.5 * ((2 * p1) + (-p0 + p2) * s + (2 * p0 - 5 * p1 + 4 * p2 - p3) * s2
                  + (-p0 + 3 * p1 - 3 * p2 + p3) * s3)


def ease(t, keys, loop=True):
    """Like track() but smoothstep between neighbouring keys: holds stay flat, no overshoot."""
    t = t % 1.0 if loop else min(max(t, keys[0][0]), keys[-1][0])
    for (t0, v0), (t1, v1) in zip(keys, keys[1:]):
        if t <= t1:
            k = smooth((t - t0) / (t1 - t0)) if t1 > t0 else 1.0
            return v0 + (v1 - v0) * k
    return keys[-1][1]


def orth(v, axis):
    """v with its component along axis removed, normalised."""
    a = axis.normalized()
    w = v - a * v.dot(a)
    return w.normalized() if w.length > 1e-6 else w


def frame_from(y_axis, x_axis):
    """3x3 with columns (x, y, z), y exact, x orthogonalised against y."""
    y = y_axis.normalized()
    x = orth(x_axis, y)
    z = x.cross(y)
    return Matrix((x, y, z)).transposed()


class Solver:
    def __init__(self, rig, foot_verts):
        self.rig = rig
        bones = rig.data.bones
        self.rest = {b.name: b.matrix_local.copy() for b in bones}
        self.rrot = {n: m.to_3x3().normalized() for n, m in self.rest.items()}
        self.par = {b.name: (b.parent.name if b.parent else None) for b in bones}
        self.length = {b.name: b.length for b in bones}
        self.order = []
        todo = [b.name for b in bones]
        while todo:
            for n in list(todo):
                if self.par[n] is None or self.par[n] in self.order:
                    self.order.append(n)
                    todo.remove(n)
        self.foot_verts = foot_verts          # side -> [Vector rel. to ankle]
        self.warn = []
        # grip point (hand box centre) and the rest pinky axis in hand-bone space
        self.grip_local, self.pinky_local = {}, {}
        for s, sx in (("L", -1), ("R", 1)):
            hb = "Hand_" + s
            inv = self.rrot[hb].inverted()
            head = self.rest[hb].translation
            self.grip_local[s] = inv @ (V(sx * 0.21, 0.005, 0.89) - head)
            self.pinky_local[s] = orth(inv @ V(0, -1, 0), V(0, 1, 0))

    # ---- prop attachment ------------------------------------------------
    def prop_offset(self, side):
        """4x4 prop matrix in Hand_<side> bone space (Blender bone frame, at bone head)."""
        yl = V(0, 1, 0)
        pl = self.pinky_local[side]
        x = pl.cross(yl)
        rot = Matrix((x, pl, yl)).transposed()
        m = rot.to_4x4()
        m.translation = self.grip_local[side]
        return m

    # ---- helpers on a pose (P: bone -> 4x4 armature-space matrix) --------
    def base(self, P, name):
        p = self.par[name]
        if p is None:
            return self.rest[name].copy()
        return P[p] @ self.rest[p].inverted() @ self.rest[name]

    def body(self, P, name):
        """Accumulated body rotation of a posed bone (identity at rest)."""
        return P[name].to_3x3() @ self.rrot[name].inverted()

    def place(self, P, name, rot3, head=None):
        h = self.base(P, name).translation if head is None else head
        m = rot3.normalized().to_4x4()
        m.translation = h
        P[name] = m

    def to_space(self, P, frame, point=None, direction=None):
        """Model-space rest coords expressed relative to a posed bone ('root' = as is)."""
        if frame == "root":
            return point if point is not None else direction
        M = P[frame] @ self.rest[frame].inverted()
        if point is not None:
            return M @ point
        return (M.to_3x3() @ direction).normalized()

    def limb_rot(self, name, d, n, sign):
        """Bone rotation with Y along d and the rest hinge axis (world X * sign) along n."""
        inv = self.rrot[name].inverted()
        yl = V(0, 1, 0)
        hl = orth(inv @ V(sign, 0, 0), yl)
        world = frame_from(d, n)
        local = frame_from(yl, hl)
        return world @ local.transposed()

    def two_bone(self, root, target, l1, l2, pole, tag):
        d = target - root
        dist = d.length
        reach = (l1 + l2) * 0.9995
        if dist > reach:
            if dist > reach + 0.004:
                self.warn.append((tag, "over-reach m", dist - reach))
            dist = reach
        dist = max(dist, abs(l1 - l2) + 1e-3)
        dn = d.normalized()
        a = (l1 * l1 - l2 * l2 + dist * dist) / (2 * dist)
        h = math.sqrt(max(0.0, l1 * l1 - a * a))
        p = orth(pole, dn)
        mid = root + dn * a + p * h
        end = root + dn * dist
        n = p.cross(dn).normalized()
        return mid, end, n

    # ---- the solve -------------------------------------------------------
    def solve(self, spec, tag=""):
        P = {}
        hips_pos = spec.get("hips", V(0, 0, 0.92))
        self.place(P, "Hips", body_rot(*spec.get("hrot", (0, 0, 0))) @ self.rrot["Hips"],
                   head=hips_pos)
        B = self.body(P, "Hips")
        self.place(P, "Spine", B @ body_rot(*spec.get("spine", (0, 0, 0))) @ self.rrot["Spine"])
        B = self.body(P, "Spine")
        self.place(P, "Head", B @ body_rot(*spec.get("head", (0, 0, 0))) @ self.rrot["Head"])
        # legs
        for s in ("L", "R"):
            ankle, pitch, yaw = spec["feet"][s]
            pole = spec.get("knee", {}).get(s) or (rz(yaw) @ V(0, 1, 0.0))
            ul, ll = "UpperLeg_" + s, "LowerLeg_" + s
            hip = self.base(P, ul).translation
            knee, end, n = self.two_bone(hip, ankle, self.length[ul], self.length[ll],
                                         pole, f"{tag} leg {s}")
            self.place(P, ul, self.limb_rot(ul, knee - hip, n, -1))
            self.place(P, ll, self.limb_rot(ll, end - knee, n, -1))
            self.place(P, "Foot_" + s, rz(yaw) @ rx(pitch) @ self.rrot["Foot_" + s])
        # arms (an arm spec may be a callable of the partial pose, e.g. a hand on a knee)
        arms = spec["arms"]
        for s in spec.get("arm_order", ("R", "L")):
            a = arms[s]
            if callable(a):
                a = a(P)
            self.solve_arm(P, s, a, tag)
        return P

    def arm_fk(self, P, side, swing, abd, elbow, frame="Spine"):
        """Hanging-arm angles -> grip spec (in the given frame)."""
        sx = -1 if side == "L" else 1
        B = self.body(P, frame) if frame != "root" else Matrix.Identity(3)
        S = self.base(P, "UpperArm_" + side).translation
        r1 = B @ ry(-sx * abd) @ rx(swing)
        r2 = r1 @ rx(elbow)
        d1, d2 = r1 @ V(0, 0, -1), r2 @ V(0, 0, -1)
        w = S + d1 * self.length["UpperArm_" + side] + d2 * self.length["LowerArm_" + side]
        g = r2 @ V(0, -1, 0)
        grip = w + d2 * 0.04 + g * -0.005
        return dict(grip=grip, g=g, hint=d2, pole=r1 @ V(0, -1, 0) - d1 * 0.2, frame="root")

    def solve_arm(self, P, s, a, tag):
        if "fk" in a:
            a = self.arm_fk(P, s, *a["fk"])
        frame = a.get("frame", "root")
        grip = self.to_space(P, frame, point=Vector(a["grip"]))
        g = self.to_space(P, frame, direction=Vector(a["g"]))
        hint = a.get("hint")
        hint = self.to_space(P, frame, direction=Vector(hint)) if hint is not None else None
        pole = self.to_space(P, frame, direction=Vector(a.get("pole", (0.4 if s == "R" else -0.4, -1, -0.2))))
        ua, la, hb = "UpperArm_" + s, "LowerArm_" + s, "Hand_" + s
        S = self.base(P, ua).translation
        l1, l2 = self.length[ua], self.length[la]
        hand_y = hint if hint is not None else (grip - S)
        hand_y = orth(hand_y, g)
        rot = None
        for _ in range(4):
            # hand world rotation: maps local (pinky -> g, Y -> hand_y)
            g = orth(g, hand_y)
            Lb = Matrix((self.pinky_local[s], V(0, 1, 0), self.pinky_local[s].cross(V(0, 1, 0)))).transposed()
            Wb = Matrix((g.normalized(), hand_y, g.normalized().cross(hand_y))).transposed()
            rot = Wb @ Lb.inverted()
            wrist = grip - rot @ self.grip_local[s]
            elbow, end, n = self.two_bone(S, wrist, l1, l2, pole, f"{tag} arm {s}")
            if hint is None:
                hand_y = orth(end - elbow, g)
        self.place(P, ua, self.limb_rot(ua, elbow - S, n, 1))
        self.place(P, la, self.limb_rot(la, end - elbow, n, 1))
        self.place(P, hb, rot)
        if (end - wrist).length > 0.01:
            self.warn.append((f"{tag} arm {s}", "hand misses grip m", (end - wrist).length))
        bend = math.degrees((end - elbow).normalized().angle(hand_y))
        if bend > 65:
            self.warn.append((f"{tag} arm {s}", "wrist bend deg", bend))

    # ---- feet ---------------------------------------------------------------
    def foot_rot(self, pitch, yaw):
        return rz(yaw) @ rx(pitch)

    def ankle_on_floor(self, side, x, y, pitch=0.0, yaw=0.0, z_extra=0.0):
        R = self.foot_rot(pitch, yaw)
        mz = min((R @ v).z for v in self.foot_verts[side])
        return V(x, y, z_extra - mz)

    def ankle_from_contact(self, side, cy, cx, pitch, yaw, which):
        """Ankle placing the boot's heel or toe edge on ground point (cx, cy).

        The pivot is the sharp bounding-box corner of the boot (heel-bottom or
        toe-bottom), not a mesh vertex: the bevelled mesh never dips below it, and
        one fixed pivot per roll phase means the contact point does not jump.
        """
        vs = self.foot_verts[side]
        ys = [v.y for v in vs]
        zmin = min(v.z for v in vs)
        corner = V(0.0, min(ys) if which == "heel" else max(ys), zmin)
        c = self.foot_rot(pitch, yaw) @ corner
        return V(cx - c.x, cy - c.y, -c.z)

    def foot(self, side, x, y, pitch=0.0, yaw=0.0):
        return (self.ankle_on_floor(side, x, y, pitch, yaw), pitch, yaw)


# ---- keying ---------------------------------------------------------------

def apply_pose(sv, P, frame):
    rig = sv.rig
    for name in sv.order:
        pb = rig.pose.bones[name]
        L = sv.base(P, name).inverted() @ P[name]
        pb.rotation_mode = "XYZ"
        prev = pb.rotation_euler.copy()
        pb.rotation_euler = L.to_3x3().normalized().to_euler("XYZ", prev)
        loc = L.translation if name == "Hips" else Vector((0, 0, 0))
        pb.location = loc
        pb.keyframe_insert("rotation_euler", frame=frame)
        pb.keyframe_insert("location", frame=frame)


def bake_action(sv, name, frames, pose_fn, loop=True, store=None):
    rig = sv.rig
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    rig.animation_data.action = act
    for pb in rig.pose.bones:
        pb.rotation_mode = "XYZ"
        pb.rotation_euler = (0, 0, 0)
    poses = []
    for f in range(frames + 1):
        t = f / frames
        spec = pose_fn(sv, t if not loop or f < frames else 0.0)
        P = sv.solve(spec, tag=f"{name}@{f}")
        P["_props"] = spec.get("props", {})
        apply_pose(sv, P, f)
        poses.append(P)
    tr = rig.animation_data.nla_tracks.new()
    tr.name = name
    tr.strips.new(name, 0, act)
    tr.mute = True
    rig.animation_data.action = None
    if store is not None:
        store[name] = dict(frames=frames, poses=poses, loop=loop,
                           key=spec_key_frames.get(name, 0.5))
    return act


# ---- shared poses -----------------------------------------------------------
HIP_Z = 0.912
STANCE_X = 0.11


def stand_feet(sv, wide=0.0, fwd_l=0.0, fwd_r=0.0, yaw_out=7.0):
    return {"L": sv.foot("L", -STANCE_X - wide, fwd_l, yaw=yaw_out),
            "R": sv.foot("R", STANCE_X + wide, fwd_r, yaw=-yaw_out)}


def hang(swing=3.0, abd=4.0, elbow=8.0):
    return {"fk": (swing, abd, elbow)}


def idle_breath(t, cycles=1):
    return math.sin(2 * math.pi * cycles * t)


# ---- gait ----------------------------------------------------------------------
# Per leg, u in [0,1): 0 heel strike, ->0.1 foot flat, 0.4 heel off, 0.62 toe off, swing.
U_FLAT, U_HEEL_OFF, U_TOE_OFF = 0.10, 0.33, 0.60
DORSI, TOE_OFF_PITCH = 16.0, -58.0
HEEL_STRIKE_Y = 0.272                # ground point of the heel at strike, ahead of the hips


def gait_foot(sv, side, u, stride=GAIT_STRIDE, x=0.1, heel_y=HEEL_STRIKE_Y, lift=1.0,
              y_off=0.0):
    """Ankle (pos, pitch, yaw) for a treadmill gait; ground moves -Y at stride/cycle."""
    u %= 1.0
    toe_len = None
    if u < U_TOE_OFF:
        gy = heel_y - stride * u + y_off          # ground point that was under the heel at u=0
        if u < U_FLAT:
            p = DORSI * (1 - smooth(u / U_FLAT) ** 0.8)
            return (sv.ankle_from_contact(side, gy, x, p, 0.0, "heel"), p, 0.0)
        # foot flat: heel point stays at gy
        flat = sv.ankle_from_contact(side, gy, x, 0.0, 0.0, "heel")
        if u < U_HEEL_OFF:
            return (flat, 0.0, 0.0)
        # roll over the toe: toe contact point fixed on the ground
        toe0 = sv.ankle_from_contact(side, 0.0, 0.0, 0.0, 0.0, "toe")
        heel0 = sv.ankle_from_contact(side, 0.0, 0.0, 0.0, 0.0, "heel")
        toe_len = heel0.y - toe0.y                # heel->toe ground distance
        ty = gy + toe_len
        s = (u - U_HEEL_OFF) / (U_TOE_OFF - U_HEEL_OFF)
        p = TOE_OFF_PITCH * s ** 1.25
        return (sv.ankle_from_contact(side, ty, x, p, 0.0, "toe"), p, 0.0)
    # swing: from toe-off pose to heel-strike pose
    s = (u - U_TOE_OFF) / (1 - U_TOE_OFF)
    a0, p0, _ = gait_foot(sv, side, U_TOE_OFF - 1e-6, stride, x, heel_y, lift, y_off)
    a1, p1, _ = gait_foot(sv, side, 1e-6, stride, x, heel_y, lift, y_off)
    ys = a0.y + (a1.y - a0.y) * (0.5 - 0.5 * math.cos(math.pi * s ** 0.9))
    zs = lerp(a0.z, a1.z, s) + lift * track(s, [(0, 0.0), (0.22, 0.072), (0.55, 0.042),
                                                 (0.85, 0.018), (1.0, 0.0)], loop=False)
    p = track(s, [(0, p0), (0.3, -22.0), (0.62, 2.0), (1.0, p1)], loop=False)
    return (V(x, ys, zs), p, 0.0)


GAIT_Z0, GAIT_BOB, GAIT_LOW = 0.888, 0.02, 0.05


def gait_body(u, bob=GAIT_BOB, lat=0.02, yaw=5.0, drop=3.0, z0=GAIT_Z0):
    """Pelvis: lowest just after each contact, shift toward the stance leg (L stance first)."""
    z = z0 - bob * math.cos(4 * math.pi * (u - GAIT_LOW))
    x = -lat * math.sin(2 * math.pi * (u - 0.05))
    pyaw = -yaw * math.cos(2 * math.pi * u)
    roll = drop * math.sin(2 * math.pi * (u - 0.05))
    return V(x, 0.0, z), pyaw, roll


def gait_spec(sv, t, arms_fn, lean=0.0, spine_pitch=3.0, stride=GAIT_STRIDE, lift=1.0):
    hips, pyaw, roll = gait_body(t)
    feet = {"L": gait_foot(sv, "L", t, stride, -0.1, lift=lift),
            "R": gait_foot(sv, "R", t + 0.5, stride, 0.1, lift=lift)}
    spec = dict(hips=hips, hrot=(lean, roll, pyaw),
                spine=(spine_pitch, -roll * 0.8, -pyaw * 2.0),
                head=(-lean * 0.6 - spine_pitch * 0.5 + 0.8 * math.cos(4 * math.pi * (t - GAIT_LOW)),
                      -roll * 0.2, pyaw * 1.0),
                feet=feet)
    spec["arms"] = arms_fn(t)
    return spec


def walk(sv, t):
    def arms(t):
        c = math.cos(2 * math.pi * (t - 0.04))
        sr, sl = 22 * c, -22 * c              # R arm forward while L leg forward
        return {"R": hang(sr, 5, 14 + 9 * max(0.0, -sr / 22)),
                "L": hang(sl, 5, 14 + 9 * max(0.0, -sl / 22))}
    return gait_spec(sv, t, lambda t: {k: dict(v, frame="Spine") if "fk" in v else v
                                       for k, v in arms(t).items()})


def carry(sv, t):
    _, pyaw, _ = gait_body(t)
    bobz = 0.4 * (gait_body(t)[0].z - GAIT_Z0)

    def arms(t):
        out = {}
        for s, sx in (("L", -1), ("R", 1)):
            out[s] = dict(grip=V(sx * 0.185, 0.43, 1.215 + bobz), g=V(0, 0, -1),
                          hint=V(0, 1, 0), pole=V(sx * 0.5, -1, -0.6), frame="root")
        return out
    spec = gait_spec(sv, t, arms, lean=-2.0, spine_pitch=-3.0, stride=GAIT_STRIDE)
    spec["spine"] = (spec["spine"][0], spec["spine"][1], -pyaw * 1.0)  # box keeps shoulders square
    return spec


# Pallet jack handle bar in worker model units: jack 1.05 m ahead of an unscaled
# worker, bar 0.669 m behind the jack origin at 1.545 m. Level workers are scaled
# 1.2 and the jack is not, so divide by 1.2.
JACK_BAR = V(0.0, (1.05 - 0.669) / 1.2, 1.545 / 1.2)


def push_jack(sv, t):
    def arms(t):
        out = {}
        for s, sx in (("L", -1), ("R", 1)):
            out[s] = dict(grip=JACK_BAR + V(sx * 0.11, 0, 0), g=V(sx, 0, 0),
                          pole=V(sx * 0.7, -0.6, -0.8), frame="root")
        return out
    spec = gait_spec(sv, t, arms, lean=7.0, spine_pitch=5.0)
    _, pyaw, _ = gait_body(t)
    spec["spine"] = (spec["spine"][0], spec["spine"][1], -pyaw * 1.0)
    return spec


# ---- stepping helpers (slow treadmill / in place) ------------------------------

def step_foot(sv, side, u, x, yc, travel, stance=0.72, lift=0.05, yaw=0.0):
    """Flat-footed step: travel = ground distance moved back during stance (0 = in place)."""
    u %= 1.0
    if u < stance:
        y = yc + travel / 2 - travel * (u / stance)
        return (sv.ankle_on_floor(side, x, y, 0.0, yaw), 0.0, yaw)
    s = (u - stance) / (1 - stance)
    y = yc - travel / 2 + travel * smooth(s)
    a = sv.ankle_on_floor(side, x, y, 0.0, yaw)
    a.z += lift * math.sin(math.pi * s)
    return (a, 6.0 * math.sin(math.pi * s), yaw)


# ---- activities -------------------------------------------------------------------
BROOM_GRIP_GAP = 0.27     # second hand this far down the shaft
BROOM_REACH = 1.17        # grip -> bristle contact (see props_handheld.broom)


def shaft_hand(sv, side, grip_top, axis, lo=0.14, hi=0.5, pole=None):
    """Second hand on a shaft: slides to the shaft point nearest its shoulder (within lo..hi
    metres below the top grip), so it stays on the handle instead of reaching past it."""
    def f(P):
        S = sv.base(P, "UpperArm_" + side).translation
        u = min(hi, max(lo, (S - grip_top).dot(axis) + 0.22))
        return dict(grip=grip_top + axis * u, g=axis,
                    pole=pole or V(-1 if side == "L" else 1, -0.4, -0.6))
    return f


def broom_axis(grip, head_xy, head_z):
    """Unit shaft direction from the top grip so the head lands at head_z."""
    dz = head_z - grip.z
    r = math.sqrt(max(0.0, BROOM_REACH ** 2 - dz * dz))
    h = Vector((head_xy[0] - grip.x, head_xy[1] - grip.y, 0)).normalized()
    return Vector((h.x * r, h.y * r, dz)).normalized()


def sweep(sv, t):
    T = 38 / FPS
    travel = SWEEP_SPEED * T * 0.72
    stroke = math.sin(2 * math.pi * t)                     # -1..1 left/right
    ph = math.cos(2 * math.pi * t)
    feet = {"L": step_foot(sv, "L", t + 0.25, -0.15, 0.02, travel, yaw=8),
            "R": step_foot(sv, "R", t + 0.75, 0.15, -0.04, travel, yaw=-8)}
    hips = V(0.03 * stroke, -0.04, 0.87 + 0.008 * abs(ph))
    grip_r = V(0.06 + 0.10 * stroke, 0.20, 1.02)
    head = (0.38 * stroke - 0.02, 0.62)
    s = broom_axis(grip_r, head, 0.0)
    spec = dict(hips=hips, hrot=(12, -2 * stroke, -10 * stroke),
                spine=(20, -1.5 * stroke, -10 * stroke), head=(12, 0, -4 * stroke), feet=feet)
    spec["arms"] = {"R": dict(grip=grip_r, g=s, pole=V(1, -0.6, -0.5)),
                    "L": shaft_hand(sv, "L", grip_r, s)}
    spec["props"] = {"R": "prop_broom"}
    return spec


MOP_REACH = 1.12


def mop(sv, t):
    x = 0.36 * math.sin(2 * math.pi * t)
    y = 0.62 + 0.13 * math.sin(4 * math.pi * t)
    sh = math.sin(2 * math.pi * t)
    feet = stand_feet(sv, wide=0.06, fwd_l=0.06, fwd_r=-0.06, yaw_out=9)
    hips = V(0.035 * sh, -0.03, 0.88)
    grip_r = V(0.05 + 0.1 * sh, 0.18 + 0.05 * math.sin(4 * math.pi * t), 1.04)
    dz = 0.02 - grip_r.z
    r = math.sqrt(MOP_REACH ** 2 - dz * dz)
    h = Vector((x - grip_r.x, y - grip_r.y, 0)).normalized()
    s = Vector((h.x * r, h.y * r, dz)).normalized()
    spec = dict(hips=hips, hrot=(10, -2 * sh, -10 * sh), spine=(18, -2 * sh, -10 * sh),
                head=(12, 0, -5 * sh), feet=feet)
    spec["arms"] = {"R": dict(grip=grip_r, g=s, pole=V(1, -0.6, -0.5)),
                    "L": shaft_hand(sv, "L", grip_r, s)}
    spec["props"] = {"R": "prop_mop"}
    return spec


def cup_pose(t_raise):
    """Right-hand cup grip (chest frame) blending chest height -> lips."""
    k = smooth(t_raise)
    grip = lerp(V(0.16, 0.25, 1.14), V(0.085, 0.155, 1.52), k)
    tilt = lerp(0.0, 55.0, smooth((t_raise - 0.55) / 0.45))
    g = (rx(tilt) @ V(0, 0, -1))
    hint = lerp(V(-0.3, 1, 0), V(-0.6, 0.5, 0.6), k)
    return dict(grip=grip, g=g, hint=hint, pole=V(1, -0.5, -0.8), frame="Spine")


def drink_coffee(sv, t):
    r = ease(t, [(0, 0.0), (0.12, 0.0), (0.3, 1.0), (0.44, 1.0), (0.6, 0.0), (1.0, 0.0)])
    sip = smooth((t - 0.3) / 0.06) * (1 - smooth((t - 0.4) / 0.05))
    shift = track(t, [(0, 0.0), (0.25, 0.012), (0.55, 0.02), (0.8, -0.022), (1.0, 0.0)])
    feet = stand_feet(sv)
    spec = dict(hips=V(shift, 0, HIP_Z - 0.006 * abs(shift) / 0.02), hrot=(0, shift * 120, 0),
                spine=(1 - 3 * r, -shift * 100, 0), head=(-12 * sip - 2 * r + 2, 0, 0), feet=feet)
    c = cup_pose(r)
    c["grip"] = c["grip"] + V(0, 0, 0.012 * sip)
    spec["arms"] = {"R": c, "L": dict(hang(3 + 2 * idle_breath(t), 5, 10), frame="Spine")}
    spec["props"] = {"R": "prop_coffee_cup"}
    return spec


def talk(sv, t):
    beat = math.sin(2 * math.pi * 3 * t)
    nod = 6 * max(0.0, math.sin(2 * math.pi * 3 * t + 0.6))
    turn = track(t, [(0, 0.0), (0.3, 12.0), (0.55, -6.0), (0.8, 8.0), (1.0, 0.0)])
    rr = track(t, [(0, V(0.2, 0.28, 1.1)), (0.17, V(0.27, 0.33, 1.24)), (0.33, V(0.14, 0.3, 1.14)),
                   (0.5, V(0.28, 0.3, 1.22)), (0.67, V(0.19, 0.36, 1.28)), (0.83, V(0.25, 0.27, 1.1)),
                   (1.0, V(0.2, 0.28, 1.1))])
    ll = track(t, [(0, V(-0.22, 0.27, 1.12)), (0.2, V(-0.16, 0.31, 1.18)), (0.4, V(-0.29, 0.33, 1.26)),
                   (0.6, V(-0.2, 0.26, 1.08)), (0.8, V(-0.26, 0.34, 1.22)), (1.0, V(-0.22, 0.27, 1.12))])
    palm = track(t, [(0, 20.0), (0.25, 70.0), (0.5, 30.0), (0.75, 80.0), (1.0, 20.0)])
    gr = rz(-30) @ ry(-palm) @ V(0, 0, -1)
    gl = rz(30) @ ry(palm) @ V(0, 0, -1)
    shift = 0.015 * math.sin(2 * math.pi * t)
    spec = dict(hips=V(shift, 0, HIP_Z - 0.004), hrot=(0, shift * 60, turn * 0.3),
                spine=(2 + 1.5 * beat, -shift * 50, turn * 0.5), head=(nod - 2, 2 * beat, turn * 0.5),
                feet=stand_feet(sv))
    spec["arms"] = {"R": dict(grip=rr, g=gr, pole=V(0.6, -0.5, -1), frame="Spine"),
                    "L": dict(grip=ll, g=gl, pole=V(-0.6, -0.5, -1), frame="Spine")}
    return spec


def on_hip(side):
    sx = -1 if side == "L" else 1
    return dict(grip=V(sx * 0.195, 0.02, 0.985), g=V(0, -0.35, -1), hint=V(-sx * 0.25, 0.8, -0.4),
                pole=V(sx * 1, -0.35, 0.05), frame="Hips")


def listen(sv, t):
    nod = 7 * (math.sin(math.pi * smooth((t - 0.12) / 0.12)) + math.sin(math.pi * smooth((t - 0.4) / 0.1)))
    laugh = smooth((t - 0.62) / 0.05) * (1 - smooth((t - 0.86) / 0.08))
    bounce = laugh * abs(math.sin(2 * math.pi * 7 * (t - 0.62)))
    shift = track(t, [(0, 0.0), (0.5, 0.02), (1.0, 0.0)])
    spec = dict(hips=V(shift, 0, HIP_Z - 0.005 - 0.01 * bounce), hrot=(-2 * laugh, shift * 80, 3),
                spine=(-3 * laugh + 4 * bounce, -shift * 60, -2),
                head=(nod - 10 * laugh + 3 * bounce, 4 + 3 * laugh, 6 - 4 * laugh),
                feet=stand_feet(sv, wide=0.02))
    spec["arms"] = {"L": on_hip("L"),
                    "R": dict(hang(4 + 6 * laugh, 6 + 4 * bounce, 12 + 25 * laugh), frame="Spine")}
    return spec


def laugh(sv, t):
    k = smooth(t / 0.18) * (1 - smooth((t - 0.78) / 0.22))
    bounce = k * abs(math.sin(2 * math.pi * 4.5 * t))
    idle_r = dict(hang(2, 4, 6), frame="Spine")
    belly = dict(grip=V(0.07, 0.17, 1.06), g=V(-0.5, 0, -1), hint=V(-1, 0.3, 0), pole=V(1, -0.5, -0.5),
                 frame="Spine")
    spec = dict(hips=V(0, -0.01 * k, HIP_Z - 0.004 - 0.012 * bounce), hrot=(-3 * k, 0, 0),
                spine=(-6 * k + 8 * bounce, 0, 3 * k), head=(-18 * k + 6 * bounce, 4 * k, 5 * k),
                feet=stand_feet(sv))

    def r_arm(P, k=k):
        a = sv.arm_fk(P, "R", 2, 4, 6)
        b = sv.to_space(P, "Spine", point=belly["grip"])
        return dict(grip=lerp(a["grip"], b, k), g=lerp(a["g"], sv.to_space(P, "Spine", direction=belly["g"]), k),
                    hint=lerp(a["hint"], sv.to_space(P, "Spine", direction=belly["hint"]), k),
                    pole=V(1, -0.5, -0.5))
    spec["arms"] = {"R": r_arm, "L": dict(hang(2 + 6 * k, 5 + 5 * bounce, 6 + 20 * k), frame="Spine")}
    _ = idle_r
    return spec


SIT_HIPS = V(0.0, -0.02, 0.525)


def sit_idle(sv, t):
    r = ease(t, [(0, 0.0), (0.45, 0.0), (0.58, 1.0), (0.68, 1.0), (0.8, 0.0), (1.0, 0.0)])
    sip = smooth((t - 0.58) / 0.04) * (1 - smooth((t - 0.66) / 0.04))
    breath = idle_breath(t, 2)
    feet = {"L": sv.foot("L", -0.14, 0.46, yaw=8), "R": sv.foot("R", 0.15, 0.40, yaw=-10)}
    spec = dict(hips=SIT_HIPS + V(0, 0, 0.002 * breath), hrot=(-8, 0, 0),
                spine=(4 + 1.0 * breath + 4 * r, 0, 0),
                head=(6 - 6 * r - 10 * sip + 4 * math.sin(2 * math.pi * t), 0,
                      8 * math.sin(2 * math.pi * t)), feet=feet,
                knee={"L": V(0, 1, 0.6), "R": V(0, 1, 0.6)})
    thigh = dict(grip=V(0.155, 0.26, 0.655), g=V(0, 0, -1), hint=V(-0.2, 1, 0), pole=V(1, -1, 0),
                 frame="root")
    lips = cup_pose(1.0)
    lips["grip"] = V(0.085, 0.16, 1.52)

    def r_arm(P):
        a_g = thigh["grip"]
        b_g = sv.to_space(P, "Spine", point=lips["grip"])
        k = smooth(r)
        tilt = 55 * smooth((r - 0.55) / 0.45) + 10 * sip
        return dict(grip=lerp(a_g, b_g, k) + V(0, 0, 0.0), g=rx(tilt) @ V(0, 0, -1),
                    hint=lerp(V(-0.2, 1, 0), sv.to_space(P, "Spine", direction=V(-0.6, 0.5, 0.6)), k),
                    pole=V(1, -0.6, -0.4))
    spec["arms"] = {"R": r_arm,
                    "L": dict(grip=V(-0.14, 0.28, 0.645), g=V(0.2, -0.3, -1), hint=V(0.2, 1, -0.3),
                              pole=V(-1, -1, 0), frame="root")}
    spec["props"] = {"R": "prop_coffee_cup"}
    return spec


def clipboard(sv, t):
    look_up = ease(t, [(0, 0.0), (0.5, 0.0), (0.6, 1.0), (0.85, 1.0), (0.95, 0.0), (1.0, 0.0)])
    write = (1 - look_up) * math.sin(2 * math.pi * 9 * t)
    hy = V(0.62, 0.78, 0.0)
    up = V(0, -0.45, 1).normalized()
    g = hy.cross(up).normalized()
    board = dict(grip=V(0.03, 0.33, 1.09), g=g, hint=hy, pole=V(-1, -0.6, -0.3), frame="Spine")

    def r_arm(P):
        # pen tip on the board: offset from the clipboard grip in board space
        M = P["Hand_L"] @ sv.prop_offset("L")
        pt = M @ V(0.04, 0.0 + 0.03 * write, -0.12 + 0.015 * math.sin(2 * math.pi * 4 * t))
        if look_up > 0:
            rest = sv.arm_fk(P, "R", 18, 6, 55)
            pt = lerp(pt + V(0.02, 0, 0.06), rest["grip"], look_up * 0.0) + V(0, 0, 0.05 * look_up)
        return dict(grip=pt, g=V(-0.4, 0.2, -1), hint=V(-0.6, 0.6, -0.3), pole=V(1, -0.4, -0.5))
    spec = dict(hips=V(0.01, 0, HIP_Z - 0.003), hrot=(0, 1, -4),
                spine=(6 - 7 * look_up, 0, -6 + 14 * look_up),
                head=(30 - 50 * look_up, 0, -6 + 26 * look_up), feet=stand_feet(sv))
    spec["arm_order"] = ("L", "R")
    spec["arms"] = {"L": board, "R": r_arm}
    spec["props"] = {"L": "prop_clipboard"}
    return spec


def scan_pallet(sv, t):
    aim = ease(t, [(0, 0.0), (0.12, 0.0), (0.35, 1.0), (0.62, 1.0), (0.85, 0.0), (1.0, 0.0)])
    beep = math.sin(math.pi * smooth((t - 0.42) / 0.1))
    target = V(0.02, 1.0, 1.02)
    low = V(0.23, 0.2, 0.98)
    high = V(0.12, 0.47, 1.3)
    grip = lerp(low, high, aim) + V(0, 0, 0.015 * beep)
    nose = lerp(V(0.1, 1, -0.9), (target - high), aim).normalized()
    nose = (rx(6 * beep) @ nose).normalized()
    g = orth(V(0, -0.25, -1), nose)
    spec = dict(hips=V(0.0, 0.01 * aim, HIP_Z - 0.006 * aim), hrot=(2 * aim, 0, 0),
                spine=(3 + 5 * aim, 0, 6 * aim), head=(8 + 6 * aim - 3 * beep, 0, 4 * aim),
                feet=stand_feet(sv, fwd_r=0.04))
    spec["arms"] = {"R": dict(grip=grip, g=g, hint=nose, pole=V(1, -0.8, -0.6)),
                    "L": dict(hang(3 + 4 * aim, 5, 10), frame="Spine")}
    spec["props"] = {"R": "prop_scanner"}
    return spec


def inspect(sv, t):
    k = ease(t, [(0, 0.8), (0.3, 1.0), (0.55, 0.9), (0.75, 1.0), (1.0, 0.8)])
    point = smooth((t - 0.35) / 0.12) * (1 - smooth((t - 0.62) / 0.12))
    feet = {"L": sv.foot("L", -0.17, 0.05, yaw=10), "R": sv.foot("R", 0.18, 0.12, yaw=-8)}
    spec = dict(hips=V(0.0, lerp(-0.03, -0.11, k), lerp(0.85, 0.74, k)), hrot=(lerp(16, 28, k), 0, 0),
                spine=(lerp(14, 20, k), 0, 4 * point), head=(lerp(-12, -26, k), 0, 10 * point - 6 * math.sin(2 * math.pi * t)),
                feet=feet, knee={"L": V(-0.25, 1, 0), "R": V(0.25, 1, 0)})

    def on_knee(side):
        def f(P):
            sx = -1 if side == "L" else 1
            knee = P["LowerLeg_" + side].translation
            hip = P["UpperLeg_" + side].translation
            g = V(sx * 0.3, -1, 0.1)
            grip = knee + (hip - knee) * 0.3 + V(0, 0.02, 0.075)    # front of the thigh, above the knee
            return dict(grip=grip, g=g,
                        pole=V(sx, -0.6, 0.0))
        return f

    def l_arm(P):
        a = on_knee("L")(P)
        S = sv.base(P, "UpperArm_L").translation
        tgt = S + V(0.05, 0.5, -0.12)
        return dict(grip=lerp(a["grip"], tgt, point), g=lerp(a["g"], V(1, 0, -0.2), point),
                    pole=V(-1, -0.6, -0.2))
    spec["arms"] = {"R": on_knee("R"), "L": l_arm}
    return spec


def stretch(sv, t):
    up = ease(t, [(0, 0.0), (0.12, 0.0), (0.4, 1.0), (0.7, 1.0), (0.9, 0.0), (1.0, 0.0)], loop=False)
    lean = ease(t, [(0, 0.0), (0.3, 0.0), (0.5, 1.0), (0.62, 1.0), (0.8, 0.0), (1.0, 0.0)], loop=False)
    sway = math.sin(math.pi * smooth((t - 0.42) / 0.3)) * lean
    spec = dict(hips=V(0, 0.02 * lean, HIP_Z - 0.002), hrot=(-4 * lean, 0, 0),
                spine=(-14 * lean, 5 * sway, 0), head=(-16 * lean, 0, 0), feet=stand_feet(sv))

    def arm(side):
        sx = -1 if side == "L" else 1

        def f(P):
            a = sv.arm_fk(P, side, 2, 4, 6)
            top = sv.to_space(P, "Spine", point=V(sx * 0.17, 0.0, 1.965))
            g_up = sv.to_space(P, "Spine", direction=V(0, -1, 0))
            k = up
            mid = (sx * 0.0)
            return dict(grip=lerp(a["grip"], top, k), g=lerp(a["g"], g_up, k).normalized(),
                        hint=None,
                        pole=lerp(V(sx * 0.4, -1, -0.2), V(sx * 1, -0.3, 0.2), k) + V(mid, 0, 0))
        return f
    spec["arms"] = {"R": arm("R"), "L": arm("L")}
    return spec


def wave(sv, t):
    up = ease(t, [(0, 0.0), (0.22, 1.0), (0.8, 1.0), (1.0, 0.0)], loop=False)
    w = math.sin(2 * math.pi * 3 * smooth((t - 0.2) / 0.62)) * smooth((t - 0.18) / 0.06) * (1 - smooth((t - 0.8) / 0.06))
    spec = dict(hips=V(-0.012 * up, 0, HIP_Z - 0.003), hrot=(0, -1.5 * up, 0),
                spine=(-2 * up, -3 * up, 4 * up), head=(-4 * up, 3 * up, 6 * up), feet=stand_feet(sv))

    def r_arm(P):
        a = sv.arm_fk(P, "R", 2, 4, 6)
        rot = ry(28 * w)
        top = sv.to_space(P, "Spine", point=V(0.5, 0.04, 1.84) + V(0.08 * w, 0, -0.02 * abs(w)))
        g = sv.to_space(P, "Spine", direction=rot @ V(1, 0, 0))
        hy = sv.to_space(P, "Spine", direction=rot @ V(0, 0.15, 1))
        return dict(grip=lerp(a["grip"], top, up), g=lerp(a["g"], g, up).normalized(),
                    hint=lerp(a["hint"], hy, up).normalized(), pole=lerp(V(0.4, -1, -0.2), V(1, 0.2, -1), up))
    spec["arms"] = {"R": r_arm, "L": dict(hang(2, 4, 6), frame="Spine")}
    return spec


def phone_call(sv, t):
    # four steps in place over 3 s, body turns right then back; feet re-planted rotated
    def yaw_at(u):
        return track(u, [(0, 0.0), (0.25, -10.0), (0.5, -22.0), (0.75, -10.0), (1.0, 0.0)])
    feet = {}
    for s, sx, off in (("L", -1, 0.0), ("R", 1, 0.25)):
        u = (t - off) % 1.0
        q = (u % 0.5) / 0.5                    # each foot steps twice per cycle
        n = math.floor(u / 0.5)
        y0 = yaw_at((off + n * 0.5) % 1.0)
        y1 = yaw_at((off + n * 0.5 + 0.5) % 1.0)
        stance = 0.62
        yw = y0 if q < stance else lerp(y0, y1, smooth((q - stance) / (1 - stance)))
        base = rz(yw) @ V(sx * STANCE_X, 0.0, 0)
        a = sv.ankle_on_floor(s, base.x, base.y, 0.0, yw - sx * 7)
        lift = 0.0 if q < stance else 0.045 * math.sin(math.pi * (q - stance) / (1 - stance))
        a.z += lift
        feet[s] = (a, 5 * lift / 0.045, yw - sx * 7)
    body_yaw = 0.5 * (feet["L"][2] + feet["R"][2])
    shift = 0.018 * math.sin(4 * math.pi * t)
    gest = smooth((t - 0.3) / 0.1) * (1 - smooth((t - 0.6) / 0.12))
    spec = dict(hips=rz(body_yaw) @ V(shift, 0, 0) + V(0, 0, HIP_Z - 0.006), hrot=(0, shift * 60, body_yaw),
                spine=(2, -shift * 40, 4 * gest), head=(4 - 6 * gest + 3 * math.sin(2 * math.pi * 2 * t), 6, -4),
                feet=feet)
    spec["arms"] = {"R": dict(grip=V(0.125, 0.03, 1.615), g=V(0, 0.95, -0.35),
                              pole=V(1, 0.4, -0.9), frame="Head"),
                    "L": dict(grip=lerp(V(-0.195, 0.02, 0.985), V(-0.22, 0.36, 1.12), gest),
                              g=lerp(V(0, -0.35, -1), V(1, 0, -0.6), gest),
                              hint=lerp(V(0.25, 0.8, -0.4), V(0.3, 1, 0.2), gest),
                              pole=V(-1, -0.4, 0), frame="Hips")}
    spec["props"] = {"R": "prop_phone"}
    return spec


BOLT = V(0.1, 0.46, 0.46)


def wrench(sv, t):
    ang = 35 + 25 * math.sin(2 * math.pi * 2 * t)          # two ratchet strokes per loop
    g = ry(-ang) @ V(1, 0, 0)                               # handle from the bolt, in the XZ plane
    grip = BOLT + g * 0.19
    push = math.sin(2 * math.pi * 2 * t)
    feet = {"L": sv.foot("L", -0.12, -0.44, pitch=-62, yaw=4),
            "R": sv.foot("R", 0.16, 0.30, yaw=-10)}
    spec = dict(hips=V(0.0, -0.06, 0.475 + 0.006 * push), hrot=(10, 2, -6),
                spine=(22 + 2 * push, 0, -8 - 3 * push), head=(18, 0, -4), feet=feet,
                knee={"L": V(0, 1, -0.3), "R": V(0.1, 1, 0.4)})

    def l_arm(P):
        knee = P["LowerLeg_R"].translation
        return dict(grip=knee + V(-0.02, 0.03, 0.08), g=V(0.4, -0.3, -1), hint=V(0.4, 1, -0.4),
                    pole=V(-1, -0.4, -0.2))
    spec["arms"] = {"R": dict(grip=grip, g=g, pole=V(1, -0.5, -0.4)), "L": l_arm}
    spec["props"] = {"R": "prop_wrench"}
    return spec


# name: (frames, fn, loop, key frame fraction used on the contact sheet)
ACTIONS = {
    "Sweep": (38, sweep, True, 0.25),
    "Mop": (48, mop, True, 0.2),
    "DrinkCoffee": (96, drink_coffee, True, 0.36),
    "Talk": (72, talk, True, 0.17),
    "Listen": (72, listen, True, 0.7),
    "Laugh": (29, laugh, False, 0.45),
    "SitIdle": (96, sit_idle, True, 0.2),
    "Clipboard": (72, clipboard, True, 0.3),
    "ScanPallet": (48, scan_pallet, True, 0.45),
    "Inspect": (72, inspect, True, 0.5),
    "Stretch": (60, stretch, False, 0.55),
    "Wave": (36, wave, False, 0.5),
    "PhoneCall": (72, phone_call, True, 0.3),
    "Wrench": (48, wrench, True, 0.12),
    "PushJack": (GAIT_FRAMES, push_jack, True, 0.0),
}
GAIT = {"Walk": (GAIT_FRAMES, walk, True, 0.0), "Carry": (GAIT_FRAMES, carry, True, 0.0)}
spec_key_frames = {k: v[3] for k, v in list(ACTIONS.items()) + list(GAIT.items())}


def build_actions(rig, foot_verts, names, store=None):
    """Bake the named actions (from GAIT and ACTIONS) onto rig. Returns the solver."""
    prefs = bpy.context.preferences.edit
    old = prefs.keyframe_new_interpolation_type
    prefs.keyframe_new_interpolation_type = "LINEAR"
    sv = Solver(rig, foot_verts)
    table = dict(GAIT, **ACTIONS)
    for n in names:
        frames, fn, loop, _ = table[n]
        bake_action(sv, n, frames, fn, loop=loop, store=store)
    prefs.keyframe_new_interpolation_type = old
    summary = {}
    for tag, kind, val in sv.warn:
        act, rest = tag.split("@", 1)
        frame, limb = rest.split(" ", 1)
        k = (act, limb, kind)
        n, mx, fr = summary.get(k, (0, 0.0, 0))
        summary[k] = (n + 1, max(mx, val), frame if val > mx else fr)
    for (act, limb, kind), (n, mx, fr) in sorted(summary.items()):
        print(f"POSE WARN {act:12s} {limb:6s} {kind:20s} frames={n:3d} max={mx:.3f} @f{fr}")
    return sv
