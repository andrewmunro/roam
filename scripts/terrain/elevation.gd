class_name ElevationSource
extends RefCounted
## Streams AWS Terrarium elevation tiles and samples heights in mercator metres.
## Samples are treated as located at pixel centres and interpolated bilinearly, so a
## query near a tile edge needs the neighbouring tile too (see tiles_for_rect).

const URL := "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/%d/%d/%d.png"
const ZOOM := 13
const SIZE := 256

var _tiles := {}  # Vector2i -> PackedFloat32Array (SIZE*SIZE heights), empty if failed
var _waiting := {}  # Vector2i -> Array[Callable]


func has_tile(t: Vector2i) -> bool:
	return _tiles.has(t)


## Tiles needed to sample anywhere inside the mercator rect, plus a margin that
## covers the vector tile buffer.
static func tiles_for_rect(mx0: float, my0: float, mx1: float, my1: float) -> Array[Vector2i]:
	var margin := Geo.tile_size_merc(ZOOM) / SIZE * 5.0
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
	var heights := PackedFloat32Array()
	if ok:
		var img := Image.new()
		if img.load_png_from_buffer(body) == OK:
			heights = _decode(img)
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
