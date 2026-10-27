#!/usr/bin/env bash
# Build all vehicle / character glbs into assets/models/. Rerunnable.
# Optional: BLENDER=/path/to/blender  ./build_all_vehicles.sh [--check] [--preview] [--actions]
# --actions renders docs/previews/worker_actions.png + walk_cycle.png (needs the prop glbs
# from build_all_props.sh). build_worker.py imports build_worker_anims.py.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"

run() {
  echo ">> $1"
  "$BLENDER" -b --factory-startup --python-exit-code 1 --python "$HERE/$1" > "/tmp/haulage_$1.log" 2>&1 \
    || { tail -30 "/tmp/haulage_$1.log"; echo "FAILED: $1"; exit 1; }
  grep -E "^EXPORTED|^PROP OFFSET|^POSE WARN" "/tmp/haulage_$1.log" || true
}

run build_truck_cab.py
run build_trailer_box.py
run build_forklift.py
run build_pallet_jack.py
run build_worker.py

for f in truck_cab_red truck_cab_blue trailer_box forklift pallet_jack worker worker_bluehat; do
  [[ -s "$ROOT/assets/models/$f.glb" ]] || { echo "MISSING $f.glb"; exit 1; }
done
echo "all 7 glb files present"

for arg in "$@"; do
  case "$arg" in
    --check) "$BLENDER" -b --factory-startup --python-exit-code 1 --python "$HERE/check_vehicles.py" 2>/dev/null | grep -vE "INFO|^Blender|^Read" ;;
    --preview) "$BLENDER" -b --factory-startup --python-exit-code 1 --python "$HERE/render_vehicles_preview.py" 2>&1 | grep -E "RENDERED|WROTE|Error" ;;
    --actions) "$BLENDER" -b --factory-startup --python-exit-code 1 --python "$HERE/render_worker_actions.py" 2>&1 | grep -E "WROTE|Error" ;;
  esac
done
