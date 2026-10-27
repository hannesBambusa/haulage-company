# Haulage Company

A logistics terminal tycoon about running a Swedish "åkeri" (haulage company). Working title: Terminal Manager. Built in Godot 4.7.

## Layout

- `assets/models`: .glb files exported from Blender
- `assets/materials`, `assets/textures`: Godot materials and textures
- `scenes`: Godot scenes (`main.tscn` is the entry point)
- `scripts`: gameplay GDScript
- `ui`: UI scenes
- `tools/blender`: Blender build scripts
- `docs`: notes and reference images

## Run

    /Applications/Godot.app/Contents/MacOS/Godot --path .

## Pipeline

Blender build scripts in `tools/blender/*.py` export .glb into `assets/models`. Godot owns scenes, lighting and gameplay. 1 Blender unit = 1 m.
