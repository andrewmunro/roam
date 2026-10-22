#!/usr/bin/env bash
# Fast geometry check: builds only the chunks under the cameras (tests/view_chunk.tscn)
# and saves OUT_DIR/view_NN.png, one per --cam. Seconds per location, not minutes.
#
# Usage: tools/view.sh OUT_DIR -- --cam=lat,lon,h,heading,pitch [--cam=...] [--roads-only] [--tiles=seam]
# Env: GODOT (binary), RES (WxH, default 960x540).
set -euo pipefail

out=${1:?usage: tools/view.sh OUT_DIR -- --cam=lat,lon,h,heading,pitch ...}
shift
[[ ${1:-} == -- ]] && shift

godot=${GODOT:-$(command -v godot || echo ~/.local/godot/Godot_v4.7.2-stable_linux.x86_64)}
res=${RES:-960x540}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -f "$out"/view_*.png

timeout 300 xvfb-run -a -s "-screen 0 ${res}x24" \
	"$godot" --path "$root" --rendering-driver opengl3 --resolution "$res" --audio-driver Dummy \
	res://tests/view_chunk.tscn -- --out="$out" "$@" 2>&1 \
	| grep -vE '^ALSA|V-Sync|set_use_vsync|^\s*$' || true
ls "$out"/view_*.png
