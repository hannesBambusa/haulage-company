"""Side-by-side: docs/previews/props.png (left) + labelled-by-order crops of gameplay-target.png
(right) -> docs/previews/compare_props.png. Uses Blender's image API + numpy (no Pillow needed).

Run: Blender -b --factory-startup --python tools/blender/compare_props.py
"""
import os
import sys

import bpy
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402

PREV = os.path.join(C.PROJECT, "docs", "previews", "props.png")
REF = os.path.join(C.PROJECT, "docs", "reference", "gameplay-target.png")
OUT = os.path.join(C.PROJECT, "docs", "previews", "compare_props.png")

# (label, x0, y0, x1, y1) in reference pixels, origin top-left (1536 x 1024 image)
CROPS = [
    ("walls+dock doors", 440, 400, 960, 740),
    ("racks loaded", 430, 90, 900, 300),
    ("pallet boxes", 500, 320, 700, 420),
    ("inbound pallets", 960, 270, 1130, 380),
    ("empty pallets", 840, 380, 950, 460),
    ("outbound pallets", 1270, 360, 1440, 480),
    ("cone trees", 0, 820, 380, 1000),
    ("cone trees R", 1280, 740, 1536, 1000),
    ("round trees", 60, 50, 330, 220),
    ("fence+bollards", 1140, 640, 1536, 940),
    ("jersey+fence L", 0, 480, 260, 690),
    ("office booth", 1390, 600, 1536, 820),
    ("office desk", 1090, 160, 1250, 260),
    ("lamp post", 0, 190, 80, 420),
]
CELL_W, CELL_H = 600, 330


def load(path):
    img = bpy.data.images.load(path)
    w, h = img.size
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
    return np.flipud(px)  # top-left origin


def resize(arr, w, h):
    sh, sw = arr.shape[:2]
    ys = (np.arange(h) * sh / h).astype(int)
    xs = (np.arange(w) * sw / w).astype(int)
    return arr[ys][:, xs]


def main():
    ref = load(REF)
    cols = 2
    rows = (len(CROPS) + cols - 1) // cols
    prev = load(PREV)
    # scale the preview to the height of the crop column
    ph0, pw0 = prev.shape[:2]
    ph = rows * CELL_H
    pw = int(pw0 * ph / ph0)
    prev = resize(prev, pw, ph)
    right_w = cols * CELL_W
    H = max(ph, rows * CELL_H)
    canvas = np.zeros((H, pw + right_w, 4), dtype=np.float32)
    canvas[..., 3] = 1.0
    canvas[..., :3] = 0.08
    canvas[:ph, :pw] = prev
    for i, (_lbl, x0, y0, x1, y1) in enumerate(CROPS):
        crop = ref[y0:y1, x0:x1]
        ch, cw = crop.shape[:2]
        sc = min((CELL_W - 10) / cw, (CELL_H - 10) / ch)
        tw, th = max(1, int(cw * sc)), max(1, int(ch * sc))
        crop = resize(crop, tw, th)
        r, c = divmod(i, cols)
        ox = pw + c * CELL_W + (CELL_W - tw) // 2
        oy = r * CELL_H + (CELL_H - th) // 2
        canvas[oy:oy + th, ox:ox + tw] = crop
    out = bpy.data.images.new("compare", pw + right_w, H, alpha=True)
    out.pixels[:] = np.flipud(canvas).ravel()
    out.filepath_raw = OUT
    out.file_format = "PNG"
    out.save()
    print("[props] compare", OUT)
    for i, (lbl, *_r) in enumerate(CROPS):
        print(f"  cell {i // cols},{i % cols}: {lbl}")


if __name__ == "__main__":
    main()
