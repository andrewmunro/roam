#!/usr/bin/env bash
# Renders the game offscreen (Xvfb + Mesa llvmpipe) and saves screenshots via
# tests/run_world.tscn, one every --every seconds (default 5) once the car spawns.
#
# Usage: tools/shots.sh OUT_DIR [SECONDS] [-- run_world args...]
#   tools/shots.sh /tmp/shots 20 -- --latlon=53.7965,-1.5478 --aerial=150 --every=4
# Env: GODOT (binary), RES (WxH, default 1280x720).
set -euo pipefail

out=${1:?usage: tools/shots.sh OUT_DIR [SECONDS] [-- run_world args...]}
shift
secs=16
if [[ $# -gt 0 && $1 != -- ]]; then secs=$1; shift; fi
[[ ${1:-} == -- ]] && shift

godot=${GODOT:-$(command -v godot || echo ~/.local/godot/Godot_v4.7.2-stable_linux.x86_64)}
res=${RES:-1280x720}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -f "$out"/shot_*.png

RUN_SECONDS=$secs timeout $((secs + 90)) xvfb-run -a -s "-screen 0 ${res}x24" \
	"$godot" --path "$root" --rendering-driver opengl3 --resolution "$res" --audio-driver Dummy \
	res://tests/run_world.tscn -- --shots="$out" "$@" 2>&1 \
	| grep -vE '^ALSA|V-Sync|set_use_vsync|^\s*$' || true
ls "$out"/shot_*.png
