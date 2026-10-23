#!/usr/bin/env bash
# Builds roam's own vector tiles: OpenMapTiles schema (as OpenFreeMap serves) plus the
# tags the builder wants that the stock schema drops (roam-tags.patch):
#   transportation: lanes, width   (road widths instead of guessing from the class)
#   building:       roof_shape, roof_height   (pyramids, spires, domes without Overpass)
# Only zoom 14 (Geo.CHUNK_ZOOM) is built, as a z/x/y directory of uncompressed .pbf
# files any static host can serve.
#
# Usage: tools/tiles/build.sh AREA [OUT_DIR]
#   AREA: a Geofabrik extract name (e.g. west-yorkshire, great-britain, egypt), or a
#         path to an .osm.pbf
#   OUT_DIR default: ~/.cache/roam-tiles/out/AREA
# Env: WORK (default ~/.cache/roam-tiles), JAVA_OPTS (default -Xmx8g).
# Serve locally: tools/tiles/serve.sh OUT_DIR, then run the game with ?tiles=URL
# (or ROAM_TILES=URL), URL like http://localhost:8714/{z}/{x}/{y}.pbf.
set -euo pipefail

area=${1:?usage: tools/tiles/build.sh AREA [OUT_DIR]}
work=${WORK:-~/.cache/roam-tiles}
work=${work/#\~/$HOME}
name=$(basename "$area" .osm.pbf)
out=${2:-$work/out/$name}
here=$(cd "$(dirname "$0")" && pwd)
repo=$work/planetiler-openmaptiles
version=v3.16

mkdir -p "$work"
if [[ ! -d $repo ]]; then
	git clone --depth 1 --branch "$version" https://github.com/openmaptiles/planetiler-openmaptiles.git "$repo"
fi
if ! git -C "$repo" diff --quiet; then
	echo "using patched checkout in $repo"
else
	git -C "$repo" apply "$here/roam-tags.patch"
fi
jar=$(ls "$repo"/target/planetiler-openmaptiles-*-with-deps.jar 2>/dev/null | head -1 || true)
if [[ -z $jar || "$here/roam-tags.patch" -nt $jar ]]; then
	(cd "$repo" && ./mvnw -q -DskipTests package)
	jar=$(ls "$repo"/target/planetiler-openmaptiles-*-with-deps.jar | head -1)
fi

if [[ -f $area ]]; then
	osm=$area
	args=(--osm-path="$osm")
else
	args=(--area="$area")
fi

# The sea comes from osmdata.openstreetmap.de; when that's unreachable, build without it.
water=$work/sources/water-polygons-split-3857.zip
if [[ ! -s $water ]] && ! curl -sfI --max-time 30 -o /dev/null \
		https://osmdata.openstreetmap.de/download/water-polygons-split-3857.zip; then
	echo "warning: osmdata.openstreetmap.de unreachable; building without the sea" >&2
	mkdir -p "$work/sources"
	python3 "$here/no_ocean.py" "$water"
fi

rm -rf "$out"
mkdir -p "$out"
# shellcheck disable=SC2086
java ${JAVA_OPTS:--Xmx8g} -jar "$jar" "${args[@]}" --download \
	--download-dir="$work/sources" --tmpdir="$work/tmp" \
	--minzoom=14 --maxzoom=14 --render_maxzoom=14 \
	--output="$out" --format=files --tile_compression=none --force
echo "tiles in $out"
