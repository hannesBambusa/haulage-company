#!/usr/bin/env bash
# Builds Haulage Company as a macOS app: build/macos/Haulage Company.app
#
#   ./build.sh            release build
#   ./build.sh --debug    debug build (shows script errors in a console)
#   ./build.sh --run      build, then open the app
#   ./build.sh -y         don't ask before downloading export templates
#
# Override the Godot binary with GODOT=/path/to/Godot ./build.sh
set -euo pipefail

cd "$(dirname "$0")"

GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
PRESET="macOS"
OUT="build/macos/Haulage Company.app"
MODE="--export-release"
RUN=0
YES=0

for arg in "$@"; do
	case "$arg" in
		--debug) MODE="--export-debug" ;;
		--run) RUN=1 ;;
		-y|--yes) YES=1 ;;
		-h|--help) sed -n '2,9p' "$0"; exit 0 ;;
		*) echo "Unknown option: $arg" >&2; exit 1 ;;
	esac
done

if [[ ! -x "$GODOT" ]]; then
	echo "Godot not found at $GODOT (set GODOT=...)" >&2
	exit 1
fi

# "4.7.2.stable.official.ed1daf0bf" -> template dir "4.7.2.stable", release tag "4.7.2-stable"
FULL_VERSION="$("$GODOT" --version | tail -1)"
TEMPLATE_VERSION="$(echo "$FULL_VERSION" | cut -d. -f1-4)"
RELEASE_TAG="$(echo "$TEMPLATE_VERSION" | sed -E 's/\.([a-z]+[0-9]*)$/-\1/')"
TEMPLATE_DIR="$HOME/Library/Application Support/Godot/export_templates/$TEMPLATE_VERSION"

# Reuse templates another project already downloaded (e.g. ../arpg/.downloads) before downloading.
if [[ ! -f "$TEMPLATE_DIR/macos.zip" ]]; then
	for candidate in ../*/.downloads/godot_templates/templates; do
		if [[ -f "$candidate/macos.zip" && "$(cat "$candidate/version.txt" 2>/dev/null)" == "$TEMPLATE_VERSION" ]]; then
			echo "Using export templates from $candidate"
			mkdir -p "$TEMPLATE_DIR"
			cp "$candidate/macos.zip" "$candidate/version.txt" "$TEMPLATE_DIR/"
			break
		fi
	done
fi

if [[ ! -f "$TEMPLATE_DIR/macos.zip" ]]; then
	URL="https://github.com/godotengine/godot/releases/download/$RELEASE_TAG/Godot_v${RELEASE_TAG}_export_templates.tpz"
	echo "Export templates for Godot $TEMPLATE_VERSION are missing."
	echo "They are a one-time download (~1.3 GB) from: $URL"
	if [[ $YES -eq 0 ]]; then
		read -r -p "Download now? [y/N] " answer
		[[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
	fi
	TMP="$(mktemp -d)"
	trap 'rm -rf "$TMP"' EXIT
	curl -fL --progress-bar -o "$TMP/templates.tpz" "$URL"
	unzip -q "$TMP/templates.tpz" -d "$TMP/unpacked"
	mkdir -p "$TEMPLATE_DIR"
	cp -R "$TMP/unpacked/templates/." "$TEMPLATE_DIR/"
	echo "Templates installed to $TEMPLATE_DIR"
fi

echo "Importing assets..."
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true

echo "Exporting ($PRESET, ${MODE#--export-})..."
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
"$GODOT" --headless --path . "$MODE" "$PRESET" "$OUT"

if [[ ! -d "$OUT" ]]; then
	echo "Export failed: $OUT was not created." >&2
	exit 1
fi

echo "Built: $(pwd)/$OUT"

if [[ $RUN -eq 1 ]]; then
	open "$OUT"
fi
