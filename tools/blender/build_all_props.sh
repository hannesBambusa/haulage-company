#!/usr/bin/env bash
# Build every prop glb into assets/models/ and verify them. Exits non-zero on any failure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
for s in props_pallets props_rack props_shell props_site props_trees props_office props_break props_handheld; do
  echo "== $s"
  "$BLENDER" -b --factory-startup --python-exit-code 1 --python "$HERE/$s.py" 2>&1 \
    | grep -E "^\[props\]|Error|Traceback|line [0-9]+" || true
  test "${PIPESTATUS[0]}" -eq 0 || { echo "FAILED: $s"; exit 1; }
done
echo "== check"
"$BLENDER" -b --factory-startup --python-exit-code 1 --python "$HERE/check_props.py" 2>&1 \
  | grep -vE "INFO:|^Blender |^Read |^$|Blender quit" 
exit "${PIPESTATUS[0]}"
