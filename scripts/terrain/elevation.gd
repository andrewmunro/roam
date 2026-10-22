class_name ElevationSource
extends RefCounted
## Streams AWS Terrarium elevation tiles and samples heights in mercator metres.
## Samples are treated as located at pixel centres and interpolated bilinearly, so a
## query near a tile edge needs the neighbouring tile too (see tiles_for_rect).

const URL := "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/%d/%d/%d.png"
const ZOOM := 13
const SIZE := 256
# Despiking: SRTM (most of the world outside Europe and the US) is a surface model, so a
# block of towers on a plain reads as a steep hill. Bumps narrower than SPIKE_RADIUS that
# rise SPIKE_MIN above the plain, steeply, from level ground are cut back to it.
const SPIKE_RADIUS := 100.0  ## metres; bumps up to about twice this across
const SPIKE_MIN := 15.0  ## metres above the surrounding ground
const SPIKE_SLOPE := 0.9  ## peak over the radius of its upper half: walls about 1:1
const SPIKE_FLOOD := 5.0  ## metres above the opened ground that count as part of a bump
const SPIKE_BASE := 0.25  ## most the ground under it may vary, as a share of its height (min 8 m)

var _tiles := {}  # Vector2i -> PackedFloat32Array (SIZE*SIZE heights), empty if failed
var _waiting := {}  # Vector2i -> Array[Callable]


func has_tile(t: Vector2i) -> bool:
	return _tiles.has(t)


## Tiles needed to sample anywhere inside the mercator rect, plus a margin that
## covers the vector tile buffer.
static func tiles_for_rect(mx0: float, my0: float, mx1: float, my1: float) -> Array[Vector2i]:
	var margin := Geo.tile_size_merc(ZOOM) / SIZE * 9.0  # vector tile buffer + tunnel grade samples
	var a := Geo.merc_to_tile(mx0 - margin, my1 + margin, ZOOM)
	var b := Geo.merc_to_tile(mx1 + margin, my0 - margin, ZOOM)
	var out: Array[Vector2i] = []
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			out.append(Vector2i(x, y))
	return out


func ensure(tiles: Array[Vector2i], priority: float, done: Callable) -> void:
	var missing: Array[Vector2i] = []
	for t in tiles:
		if not _tiles.has(t):
			missing.append(t)
	if missing.is_empty():
		done.call()
		return
	var remaining := [missing.size()]
	var on_one := func() -> void:
		remaining[0] -= 1
		if remaining[0] == 0:
			done.call()
	for t in missing:
		if _waiting.has(t):
			_waiting[t].append(on_one)
			continue
		_waiting[t] = [on_one]
		var n := 1 << ZOOM
		var url := URL % [ZOOM, posmod(t.x, n), clampi(t.y, 0, n - 1)]
		Fetch.request(url, _on_tile.bind(t), priority)


func _on_tile(ok: bool, body: PackedByteArray, t: Vector2i) -> void:
	if not ok:
		_store(t, PackedFloat32Array())
		return
	# Decoding and despiking take ~150 ms a tile: off the main thread.
	WorkerThreadPool.add_task(func() -> void:
		var heights := PackedFloat32Array()
		var img := Image.new()
		if img.load_png_from_buffer(body) == OK:
			heights = _despike(_decode(img), _pixel_metres(t))
		_store.call_deferred(t, heights))


func _store(t: Vector2i, heights: PackedFloat32Array) -> void:
	if heights.is_empty():
		push_warning("Elevation tile %s unavailable, using sea level" % t)
	_tiles[t] = heights
	var callbacks: Array = _waiting.get(t, [])
	_waiting.erase(t)
	for cb: Callable in callbacks:
		cb.call()


static func _decode(img: Image) -> PackedFloat32Array:
	img.convert(Image.FORMAT_RGB8)
	var px := img.get_data()
	var heights := PackedFloat32Array()
	heights.resize(SIZE * SIZE)
	for i in SIZE * SIZE:
		var o := i * 3
		heights[i] = px[o] * 256.0 + px[o + 1] + px[o + 2] / 256.0 - 32768.0
	return heights


## Ground size of one pixel of tile t, in metres.
static func _pixel_metres(t: Vector2i) -> float:
	var n := float(1 << ZOOM)
	var lat := atan(sinh(PI * (1.0 - 2.0 * (t.y + 0.5) / n)))
	return Geo.tile_size_merc(ZOOM) / SIZE * cos(lat)


## Cuts building-like spikes (see SPIKE_RADIUS) back to the ground around them: a grey
## opening (min then max filter) gives the ground without anything narrower than the
## window, and each connected bump above it is removed if it is tall, steep and stands on
## level ground. Mountains (sloped ground) and broad hills are left alone. Works within
## the tile, so every chunk sampling it sees the same heights.
static func _despike(h: PackedFloat32Array, px_m: float) -> PackedFloat32Array:
	# Cheap pass first: nothing steep enough in the tile, nothing to do.
	var steep := SPIKE_SLOPE * 0.5 * px_m
	var any := false
	for y in SIZE:
		var row := y * SIZE
		for x in SIZE - 1:
			if absf(h[row + x + 1] - h[row + x]) > steep or (y < SIZE - 1 and absf(h[row + SIZE + x] - h[row + x]) > steep):
				any = true
				break
		if any:
			break
	if not any:
		return h
	var r := maxi(1, roundi(SPIKE_RADIUS / px_m))
	var ground := _filter(_filter(_filter(_filter(h, r, true, true), r, false, true), r, true, false), r, false, false)
	var seen := PackedByteArray()
	seen.resize(SIZE * SIZE)
	var out := h.duplicate()
	var stack := PackedInt32Array()
	var comp := PackedInt32Array()
	for start in SIZE * SIZE:
		if seen[start] or h[start] - ground[start] < SPIKE_FLOOD:
			continue
		# Flood the bump: every pixel SPIKE_FLOOD above the opened ground (SRTM noise in
		# a city sits a few metres above it everywhere).
		seen[start] = 1
		stack.append(start)
		comp.clear()
		var peak := 0.0
		var lo := INF
		var hi := -INF
		while not stack.is_empty():
			var i := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			comp.append(i)
			peak = maxf(peak, h[i] - ground[i])
			lo = minf(lo, ground[i])
			hi = maxf(hi, ground[i])
			var x := i % SIZE
			for j in [i - 1 if x > 0 else -1, i + 1 if x < SIZE - 1 else -1, i - SIZE, i + SIZE]:
				if j >= 0 and j < SIZE * SIZE and not seen[j] and h[j] - ground[j] >= SPIKE_FLOOD:
					seen[j] = 1
					stack.append(j)
		# Steepness: peak over the radius of its upper half (the rim blurs into noise).
		var upper := 0
		for i in comp:
			upper += 1 if h[i] - ground[i] >= peak * 0.5 else 0
		var radius := sqrt(upper / PI) * px_m
		# Ground below sea level is seabed (the tiles carry bathymetry): a shore, not a plain.
		if peak >= SPIKE_MIN and peak / radius >= SPIKE_SLOPE and hi - lo <= maxf(8.0, SPIKE_BASE * peak) and lo >= 0.0:
			for i in comp:
				out[i] = ground[i]
	return out


## Running min (or max) over 2r+1 pixels along rows or columns, edges clamped
## (van Herk/Gil-Werman: three passes per line whatever r is).
static func _filter(h: PackedFloat32Array, r: int, rows: bool, take_min: bool) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(SIZE * SIZE)
	var k := 2 * r + 1
	var n := SIZE + 2 * r
	var line := PackedFloat32Array()
	line.resize(n)
	var g := PackedFloat32Array()
	g.resize(n)
	var b := PackedFloat32Array()
	b.resize(n)
	for l in SIZE:
		var base := l * SIZE if rows else l
		var step := 1 if rows else SIZE
		for i in n:
			line[i] = h[base + clampi(i - r, 0, SIZE - 1) * step]
		for i in n:  # running from each block start
			g[i] = line[i] if i % k == 0 else (minf(g[i - 1], line[i]) if take_min else maxf(g[i - 1], line[i]))
		for i in range(n - 1, -1, -1):  # and from each block end
			b[i] = line[i] if i == n - 1 or (i + 1) % k == 0 else (minf(b[i + 1], line[i]) if take_min else maxf(b[i + 1], line[i]))
		for i in SIZE:  # window [i, i + 2r] in line = pixel i ± r
			out[base + i * step] = minf(b[i], g[i + k - 1]) if take_min else maxf(b[i], g[i + k - 1])
	return out


## A read-only copy holding just the given tiles, safe to sample from a worker thread
## while this source keeps loading.
func snapshot(tiles: Array[Vector2i]) -> ElevationSource:
	var s := ElevationSource.new()
	for t in tiles:
		if _tiles.has(t):
			s._tiles[t] = _tiles[t]
	return s


func forget_far(keep: Dictionary) -> void:
	for t in _tiles.keys():
		if not keep.has(t):
			_tiles.erase(t)


func _pixel(tx: int, ty: int, px: int, py: int) -> float:
	if px >= SIZE:
		tx += 1
		px -= SIZE
	elif px < 0:
		tx -= 1
		px += SIZE
	if py >= SIZE:
		ty += 1
		py -= SIZE
	elif py < 0:
		ty -= 1
		py += SIZE
	var h: PackedFloat32Array = _tiles.get(Vector2i(tx, ty), PackedFloat32Array())
	if h.is_empty():
		return 0.0
	return h[py * SIZE + px]


## Height in metres at a mercator position. Requires tiles from tiles_for_rect.
func sample(mx: float, my: float) -> float:
	var size := Geo.tile_size_merc(ZOOM)
	var fx := (mx + Geo.HALF_WORLD) / size
	var fy := (Geo.HALF_WORLD - my) / size
	var tx := floori(fx)
	var ty := floori(fy)
	var px := (fx - tx) * SIZE - 0.5
	var py := (fy - ty) * SIZE - 0.5
	var ix := floori(px)
	var iy := floori(py)
	var u := px - ix
	var v := py - iy
	var h00 := _pixel(tx, ty, ix, iy)
	var h10 := _pixel(tx, ty, ix + 1, iy)
	var h01 := _pixel(tx, ty, ix, iy + 1)
	var h11 := _pixel(tx, ty, ix + 1, iy + 1)
	return lerpf(lerpf(h00, h10, u), lerpf(h01, h11, u), v)
