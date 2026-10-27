#!/bin/bash
# usage: round.sh N
cd /Users/hannesalm/code/games/haulage-company
G=/Applications/Godot.app/Contents/MacOS/Godot
$G --headless --path . --import 2>&1 | grep -iE "error|fail" | head
$G --path . --resolution 1536x1024 --script res://scripts/tools/screenshot.gd -- --out=res://docs/previews/scene_r$1.png 2>&1 | grep -iE "error|warn|screenshot" | head -20
$G --headless --path . --script res://scripts/tools/compare.gd -- --shot=res://docs/previews/scene_r$1.png --round=$1 2>&1 | grep -iE "error|compare"
