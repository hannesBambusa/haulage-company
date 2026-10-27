"""Rebuilds scenes/level_1.tscn from the r5 backup plus the r6+ changes.
Run: python3 edit_level.py  (idempotent: always starts from level_1.r5.tscn)"""
import math, re, os

SP = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(SP, "level_1.r5.tscn")
DST = "/Users/hannesalm/code/games/haulage-company/scenes/level_1.tscn"
CFG = {}
exec(open(os.path.join(SP, "level_cfg.py")).read(), CFG)

text = open(SRC).read()
head, *blocks = re.split(r"\n(?=\[)", text)
blocks = [head] + blocks


def node_name(b):
    m = re.match(r'\[node name="([^"]+)"(?:[^\]]*parent="([^"]*)")?', b)
    if not m:
        return None
    parent = m.group(2)
    if parent is None:
        return "."
    return m.group(1) if parent == "." else parent + "/" + m.group(1)


def find(path):
    for i, b in enumerate(blocks):
        if node_name(b) == path:
            return i
    raise KeyError(path)


def remove(path):
    del blocks[find(path)]


def set_prop(path, key, value):
    i = find(path)
    b = blocks[i]
    lines = b.rstrip("\n").split("\n")
    for k, ln in enumerate(lines):
        if ln.startswith(key + " = "):
            lines[k] = f"{key} = {value}"
            break
    else:
        lines.append(f"{key} = {value}")
    blocks[i] = "\n".join(lines) + "\n"


def fmt(v):
    v = round(v, 4)
    if v == int(v):
        return str(int(v))
    return repr(v)


def xf(x, y, z, yaw_deg=0.0, s=1.0, sx=None):
    c, n = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
    sxv = s if sx is None else sx
    # rows of R_y * diag(sx, s, s)
    r = [c * sxv, 0, n * s, 0, s, 0, -n * sxv, 0, c * s]
    return "Transform3D(" + ", ".join(fmt(a) for a in r + [x, y, z]) + ")"


def get_xf(path):
    b = blocks[find(path)]
    m = re.search(r"transform = Transform3D\(([^)]*)\)", b)
    return [float(a) for a in m.group(1).split(",")]


def put_xf(path, vals):
    set_prop(path, "transform", "Transform3D(" + ", ".join(fmt(a) for a in vals) + ")")


def shift_x(path, dx):
    v = get_xf(path)
    v[9] += dx
    put_xf(path, v)


def scale_node(path, s):
    v = get_xf(path)
    for k in range(9):
        v[k] *= s
    put_xf(path, v)


def vec3s(pts):
    return "PackedVector3Array(" + ", ".join(f"{fmt(x)}, {fmt(y)}, {fmt(z)}" for x, y, z in pts) + ")"


# --- ext resources ----------------------------------------------------------
ext_ids = {}
for m in re.finditer(r'\[ext_resource type="[^"]+" path="([^"]+)" id="([^"]+)"\]', text):
    ext_ids[m.group(1)] = m.group(2)
next_ext = [len(ext_ids) + 1]
new_ext = []


def ext(path, typ):
    if path in ext_ids:
        return ext_ids[path]
    rid = f"{next_ext[0]}_{os.path.splitext(os.path.basename(path))[0][:10]}"
    next_ext[0] += 1
    ext_ids[path] = rid
    new_ext.append(f'[ext_resource type="{typ}" path="{path}" id="{rid}"]')
    return rid


def scene(name):
    return ext(f"res://assets/models/{name}.glb", "PackedScene")


def script(path):
    return ext(path, "Script")


added = []


def add(name, parent, body="", instance=None, typ=None):
    hdr = f'[node name="{name}"'
    if typ:
        hdr += f' type="{typ}"'
    hdr += f' parent="{parent}"'
    if instance:
        hdr += f' instance=ExtResource("{instance}")'
    hdr += "]"
    added.append((parent, hdr + "\n" + body.strip("\n") + ("\n" if body.strip() else "")))


CFG["run"](globals())

# insert added nodes after the last node of their parent's subtree (or append)
for parent, blk in added:
    idx = None
    for i, b in enumerate(blocks):
        n = node_name(b)
        if n is None:
            continue
        if n == parent or n.startswith(parent + "/") or (parent == "." and n != "."):
            idx = i
    if parent == ".":
        idx = len(blocks) - 1
    anc = parent
    while idx is None and "/" in anc:  # parent lives inside an instanced scene
        anc = anc.rsplit("/", 1)[0]
        for i, b in enumerate(blocks):
            n = node_name(b)
            if n is not None and (n == anc or n.startswith(anc + "/")):
                idx = i
    blocks.insert(idx + 1, blk)

out = "\n".join(b.rstrip("\n") + "\n" for b in blocks)
# ext resources go after the last existing one
last = out.rfind("[ext_resource")
end = out.index("\n", last) + 1
out = out[:end] + "".join(e + "\n" for e in new_ext) + out[end:]
steps = out.count("[ext_resource") + out.count("[sub_resource") + 1
out = re.sub(r"load_steps=\d+", f"load_steps={steps}", out, count=1)
open(DST, "w").write(out)
print("wrote", DST, "nodes:", out.count("[node "), "added:", len(added), "ext:", len(new_ext))
