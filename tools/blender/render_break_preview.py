"""Line-up of the break-area props and the mop bucket -> docs/previews/break_props.png.

Hand props are shown in their grips on docs/previews/worker_actions.png instead
(their origin is the grip point, so they would sit half under this floor).

Reuses render_props_preview.py (same light, camera and ground) with its own rows.
Run: Blender -b --factory-startup --python tools/blender/render_break_preview.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common_props as C  # noqa: E402
import render_props_preview as R  # noqa: E402

R.ROWS = [
    ["vending_machine", "coffee_machine", "water_cooler", "break_table", "break_chair"],
    ["bench", "trash_bin", "wet_floor_sign", "toolbox", "prop_bucket"],
]
R.GAP = 0.6
R.OUT = os.path.join(C.PROJECT, "docs", "previews", "break_props.png")

if __name__ == "__main__":
    R.main()
