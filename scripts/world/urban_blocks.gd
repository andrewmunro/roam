class_name UrbanBlocks
extends RefCounted
## City blocks as the space left between roads: every at-grade road is stamped onto a
## 1 m grid at its full width, and the free regions it leaves are traced into outlines.
## Each block then gets one continuous kerb and pavement round its edge, so pavements
## meet cleanly at corners and islands instead of being stitched from per-road strips.
## Pure data, so it runs on the chunk builder's worker thread.

const CELL := 1.0
const MARGIN := 120.0  ## how far past the tile edges blocks are traced
const CORNERS := [7.0, 3.0]  ## kerb radius at block corners, and the fallback for narrow blocks
const MIN_AREA := 40.0  ## smaller free spots are left as they are
const MAX_AREA := 250000.0
const GRID := 48.0  ## spatial hash for coverage queries
const UNPAVED := 64  ## owner flag: the road beside has no pavements
const FREE := 255  ## owner value of a cell no road covers
const SNAP := 2.5  ## traced vertices this close to a road edge are moved onto it

var size: float
var _w := 0
var _h := 0
var _owner := PackedByteArray()  ## per cell: rank of the road stamped there (| UNPAVED), or FREE
var blocks: Array[PackedVector2Array] = []  ## outlines in chunk space, counter-clockwise
var _grid := {}  ## Vector2i -> Array of block indices
var _segs := {}  ## Vector2i -> Array of road segments [a, b, hw]
var colors := {}  ## rank -> asphalt colour of roads of that rank


## `roads`: [{pts, hw, rank, pave, color}] at grade; `cuttings`: [{pts, hw}].
## `skip_at`: (Vector2) -> bool, true where no block should be (roundabout islands).
func build(p_size: float, roads: Array, cuttings: Array, skip_at: Callable) -> void:
	size = p_size
	_w = ceili((size + MARGIN * 2.0) / CELL / 2.0) * 2
	_h = _w
	_owner.resize(_w * _h)
	_owner.fill(FREE)
	var t0 := Time.get_ticks_usec()
	var order := roads.duplicate()
	# Paved roads stamp last, so the owner of a cell shared with an unpaved one is paved.
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(not a.pave) * 100 + a.rank > int(not b.pave) * 100 + b.rank)
	for c: Dictionary in cuttings:
		_stamp(c.pts, c.hw + 1.0, 9 | UNPAVED)
		_index(c.pts, c.hw + 1.0)
	for r: Dictionary in order:
		_stamp(r.pts, r.hw, int(r.rank) | (0 if r.pave else UNPAVED))
		_index(r.pts, r.hw)
		colors[int(r.rank)] = r.color
	# Read as an LA8 image half as wide, every odd cell is a pixel's alpha: road codes
	# (< 128) are transparent, free cells opaque. The native tracer then outlines the
	# free regions on 2 x 1 m cells without a pass over the grid in script.
	var t1 := Time.get_ticks_usec()
	var img := Image.create_from_data(_w / 2, _h, false, Image.FORMAT_LA8, _owner)
	var bm := BitMap.new()
	bm.create_from_image_alpha(img, 0.5)
	var outlines := bm.opaque_to_polygons(Rect2i(0, 0, _w / 2, _h), 0.6)
	var t2 := Time.get_ticks_usec()
	for outline: PackedVector2Array in outlines:
		var poly := PackedVector2Array()
		var touches := false
		for q in outline:
			if q.x <= 1.0 or q.y <= 1.0 or q.x >= _w / 2 - 1.0 or q.y >= _h - 1.0:
				touches = true
				break
			poly.append(Vector2(q.x * 2.0, q.y) * CELL - Vector2(MARGIN, MARGIN))
		if touches or poly.size() < 3:
			continue  # cut off by the edge of the grid: not a whole block
		var area := MVTDecoder.ring_area(poly)
		if absf(area) < MIN_AREA or absf(area) > MAX_AREA:
			continue
		if area < 0.0:
			poly.reverse()
		poly = _snap(poly)
		var c := _centroid(poly)
		if skip_at.call(c):
			continue
		# Round the corners (shrink, then grow back with round joins) at least as much
		# as the junction surfaces do, so the kerb sits on asphalt all round; narrow
		# blocks make do with less.
		var rounded := PackedVector2Array()
		for r: float in CORNERS:
			var shrunk := Geometry2D.offset_polygon(poly, -r)
			if shrunk.size() == 1:
				var grown := Geometry2D.offset_polygon(shrunk[0], r, Geometry2D.JOIN_ROUND)
				if grown.size() == 1:
					rounded = grown[0]
					break
		if rounded.is_empty():
			continue  # too thin to be a block (a sliver between parallel roads)
		poly = rounded
		if MVTDecoder.ring_area(poly) < 0.0:
			poly.reverse()
		var i := blocks.size()
		blocks.append(poly)
		var bb := _bounds(poly)
		for gy in range(floori(bb.position.y / GRID), floori(bb.end.y / GRID) + 1):
			for gx in range(floori(bb.position.x / GRID), floori(bb.end.x / GRID) + 1):
				var key := Vector2i(gx, gy)
				if _grid.has(key):
					_grid[key].append(i)
				else:
					_grid[key] = [i]
	if OS.has_environment("ROAM_ROAD_TIMES"):
		print("blocks ms (stamp, trace, outlines): ", [(t1 - t0) / 1000, (t2 - t1) / 1000,
			(Time.get_ticks_usec() - t2) / 1000], " outlines ", outlines.size())


## True if p is inside a traced block.
func covers(p: Vector2) -> bool:
	for i: int in _grid.get(Vector2i(floori(p.x / GRID), floori(p.y / GRID)), []):
		if Geometry2D.is_point_in_polygon(p, blocks[i]):
			return true
	return false


## The road beside a block edge point, looking outwards from it (corners are rounded,
## so the nearest road may be a few metres off): its rank | UNPAVED if it has no
## pavements, or FREE if there is none.
func road_beside(p: Vector2, outward: Vector2) -> int:
	for d: float in [1.5, 3.0, 5.0, 8.0]:
		var q := p + outward * d
		var i := floori((q.x + MARGIN) / CELL)
		var j := floori((q.y + MARGIN) / CELL)
		if i < 0 or j < 0 or i >= _w or j >= _h:
			break
		if _owner[j * _w + i] != FREE:
			return _owner[j * _w + i]
	return FREE


## Grid of road segments [a, b, hw] for snapping.
func _index(pts: PackedVector2Array, hw: float) -> void:
	for k in pts.size() - 1:
		var seg := [pts[k], pts[k + 1], hw]
		var lo := Vector2(minf(pts[k].x, pts[k + 1].x), minf(pts[k].y, pts[k + 1].y)) - Vector2(hw, hw) - Vector2.ONE * SNAP
		var hi := Vector2(maxf(pts[k].x, pts[k + 1].x), maxf(pts[k].y, pts[k + 1].y)) + Vector2(hw, hw) + Vector2.ONE * SNAP
		for gy in range(floori(lo.y / GRID), floori(hi.y / GRID) + 1):
			for gx in range(floori(lo.x / GRID), floori(hi.x / GRID) + 1):
				var key := Vector2i(gx, gy)
				if _segs.has(key):
					_segs[key].append(seg)
				else:
					_segs[key] = [seg]


## Moves each traced vertex (stair-stepped by the grid) onto the true edge of the road
## it lies along, so kerbs run straight and meet the drawn carriageway.
func _snap(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for v in poly:
		var best := v
		var best_err := SNAP
		for seg: Array in _segs.get(Vector2i(floori(v.x / GRID), floori(v.y / GRID)), []):
			var q := Geometry2D.get_closest_point_to_segment(v, seg[0], seg[1])
			var d := v.distance_to(q)
			var err := absf(d - float(seg[2]))
			if err < best_err and d > 0.01:
				best_err = err
				best = q + (v - q) / d * float(seg[2])
		out.append(best)
	return out


func _stamp(pts: PackedVector2Array, hw: float, owner: int) -> void:
	var off := Vector2(MARGIN, MARGIN)
	for k in pts.size() - 1:
		var a := pts[k] + off
		var b := pts[k + 1] + off
		var d := b - a
		if d.length_squared() < 1e-6:
			continue
		var n := Vector2(-d.y, d.x).normalized() * hw
		var e := d.normalized() * hw
		Raster.fill_polygon(_owner, _w, _h, CELL, PackedVector2Array([a - n - e, b - n + e, b + n + e, a + n - e]), owner)


static func _centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / poly.size()


static func _bounds(poly: PackedVector2Array) -> Rect2:
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	return r
