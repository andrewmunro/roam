class_name RoadLevels
extends RefCounted
## One road surface height for every drivable road around a chunk: streets, slip roads,
## bridges, tunnels and the cuttings and ramps between them. Pure data, so it runs on
## the chunk builder's worker thread.
##
## The roads of all nine tiles around a chunk become one graph of samples a few metres
## apart, joined where the roads share a point. Every sample wants to lie on the ground
## (the DEM, smoothed along the roads), but structures set hard limits: a dug-down
## tunnel stays TUNNEL_COVER under the surface, a bridge clears what it crosses, and a
## road crossing over another without a junction stays CLEAR above it. Limits spread
## along the graph at no more than MAX_GRADE, so the streets leading to a tunnel portal
## sink into a cutting and those leading onto a flyover climb a ramp by themselves, and
## every road meeting at a junction gets the same height there.
##
## Everything that draws a road surface (carriageways, junctions, kerbs, decks, tunnel
## floors) asks surface() for its height, so pieces that meet always agree. Every chunk
## solves the same graph around its edges, so neighbours agree at the seams too.

enum Kind { GRADE, BRIDGE, TUNNEL }
const GRADE_BIT := 1
const BRIDGE_BIT := 2
const TUNNEL_BIT := 4
const STREETS := GRADE_BIT | BRIDGE_BIT  ## what lies open to the sky
const ALL := 7

const STEP := 4.0  ## sample spacing along the roads
const MAX_GRADE := 0.07  ## steepest climb into a cutting or onto a ramp
const TUNNEL_COVER := 7.0  ## a dug-down tunnel's road lies this far under the surface
const CLEAR := 5.6  ## a road crossing over another (no junction) clears it by this much
const WATER_CLEAR := 5.0
const JOIN := 1.0  ## line ends this close to another road's point join it
const REACH := 2.5  ## how far past a road's edge surface() still finds it
const LEVEL_GAP := 1.5  ## roads further apart in height than this are separate levels
const GRID := 6.0
const OVERLAP_PARALLEL := 0.7  ## overlapping roads more than LEVEL_GAP apart are linked only if this parallel (|cos|)
const JOIN_CROSS := 20.0  ## roads that join within this along the network don't cross nearby
const MERGE := 60.0  ## overlapping roads joined within this distance are merging, not stacked
const RAMP_END := 25.0  ## side-by-side overlaps this near a road's end are a ramp landing
const FIT_GAP := 0.3  ## room left between roads squeezed side by side at different levels
const FIT_MIN := 0.55  ## a squeezed road keeps at least this share of its half width
const PORTAL_GAP := 250.0  ## roads linking two tunnel portals this close stay down in the cutting

var dem: Callable  ## (Vector2) -> float, raw elevation in chunk space (valid past the tile)
var water_at: Callable  ## (Vector2) -> bool, optional: water under a bridge

var _lines: Array[Dictionary] = []
# Samples
var _p := PackedVector2Array()
var _kind := PackedByteArray()
var _line := PackedInt32Array()
var _next := PackedInt32Array()  # next sample on the same line, or -1
var _hw := PackedFloat32Array()
var _links: Array[PackedInt32Array] = []
var _road_links: Array[PackedInt32Array] = []  # _links before overlaps were linked: the roads themselves
var _g := PackedFloat32Array()  # ground: DEM smoothed along the roads
var _h := PackedFloat32Array()  # solved road height
var _grid := {}  # Vector2i -> PackedInt32Array of segment starts (sample k to _next[k])
var _ab := PackedVector2Array()  # segment k: _p[_next[k]] - _p[k]
var _il2 := PackedFloat32Array()  # 1 / its length squared
var _h1 := PackedFloat32Array()  # height at its far end
var lo_limit := PackedFloat32Array()  # final limits per sample (for tools and tests)
var hi_limit := PackedFloat32Array()
var _wl := PackedFloat32Array()  # fitted half width per sample, left (+normal) and right
var _wr := PackedFloat32Array()
var _near_h := PackedFloat32Array()  # surface(): heights and distances of the roads in reach
var _near_d := PackedFloat32Array()


## Adds a road. `layer` follows OSM (bridges default to 1, tunnels to -1); `bored`
## tunnels run straight through a hill, other tunnels with `kind` TUNNEL are dug down
## under the street. Tunnels drawn at grade (underpasses) are GRADE with a negative
## layer, so they dip under whatever crosses them.
func add_line(pts: PackedVector2Array, kind: int, hw: float, layer: int, bored := false) -> void:
	if pts.size() >= 2:
		_lines.append({pts = pts, kind = kind, hw = hw, layer = layer, bored = bored})


func is_empty() -> bool:
	return _p.is_empty()


func solve() -> void:
	_sample()
	if _p.is_empty():
		return
	_join()
	_road_links = _links.duplicate(true)
	_heights()
	# Roads whose surfaces overlap must be at one height, unless the first solve put
	# them a clearance apart (a car park over a cutting): link those and solve again.
	if _link_overlaps():
		_heights()
	_fit_widths()
	_build_grid()


## Ground, limits and crossings, then the heights between them (see solve).
func _heights() -> void:
	_ground()
	var n := _p.size()
	var target := _g.duplicate()
	var lo := PackedFloat32Array()
	var hi := PackedFloat32Array()
	lo.resize(n)
	hi.resize(n)
	lo.fill(-INF)
	hi.fill(INF)
	var crossings := _crossings()
	var crossed := {}  # line -> true if a road passes under it
	for c: Vector2i in crossings:
		crossed[_line[c.x]] = true
	for li in _lines.size():
		var l: Dictionary = _lines[li]
		if l.kind == Kind.BRIDGE:
			_bridge_limits(li, crossed.has(li), lo)
		elif l.kind == Kind.TUNNEL:
			_tunnel_limits(li, target, hi)
	_link_portals(hi)
	# Crossings push the structure (or the road diving under) apart until they clear.
	var lo_env := PackedFloat32Array()
	var hi_env := PackedFloat32Array()
	for round_i in 5:
		lo_env = _envelope(lo, false)
		hi_env = _envelope(hi, true)
		_h = _bounded(target, lo_env, hi_env)
		if round_i == 4:
			break  # the last round only applies the previous one's pushes
		var moved := false
		for c: Vector2i in crossings:
			var up := c.x
			var down := c.y
			if _h[up] - _h[down] >= CLEAR - 0.05:
				continue
			moved = true
			if _lines[_line[down]].layer < 0 or _kind[up] != Kind.BRIDGE:
				hi[down] = minf(hi[down], _h[up] - CLEAR)
			else:
				lo[up] = maxf(lo[up], _h[down] + CLEAR)
		if not moved:
			break
	# Round off the kinks where a ramp or cutting starts.
	for pass_i in 3:
		var nxt := _h.duplicate()
		for k in n:
			var sum := _h[k]
			var cnt := 1
			for j in _links[k]:
				sum += _h[j]
				cnt += 1
			nxt[k] = sum / cnt
		# Smoothing must not lift a tunnel into its roof or sink a deck onto the road below.
		_h = _bounded(nxt, lo_env, hi_env)
	lo_limit = lo_env
	hi_limit = hi_env



## Half widths (left, right) of the road through p heading `dir` with nominal half width
## `hw`, fitted so roads side by side at different levels don't overlap (see
## _fit_widths). Left is the side of Vector2(-dir.y, dir.x). (hw, hw) if no such road.
func fit(p: Vector2, dir: Vector2, hw: float) -> Vector2:
	var best := 1.0
	var out := Vector2(hw, hw)
	for k: int in _grid.get(Vector2i(floori(p.x / GRID), floori(p.y / GRID)), PackedInt32Array()):
		if absf(_hw[k] - hw) > 0.6:
			continue
		var a := _p[k]
		var t := clampf((p - a).dot(_ab[k]) * _il2[k], 0.0, 1.0)
		var d := p.distance_to(a + _ab[k] * t)
		var along := _ab[k].normalized().dot(dir)
		if d >= best or absf(along) < 0.7:
			continue
		best = d
		var j := _next[k]
		var l := lerpf(_wl[k], _wl[j], t)
		var r := lerpf(_wr[k], _wr[j], t)
		out = Vector2(l, r) if along > 0.0 else Vector2(r, l)
		out *= hw / _hw[k]
	return out


## Road surface height at p (without any lift): a blend of the roads whose surface
## covers p (or comes within `reach` of it), of the kinds in `mask`, keeping to one
## level: that of the closest road, or with `hint` (the height of the piece being
## built, from its own centre line) the road nearest that height, so a junction beside
## a cutting stays at street level. NAN if no such road is near.
func surface(p: Vector2, mask := ALL, reach := REACH, hint := NAN) -> float:
	var cands: PackedInt32Array = _grid.get(Vector2i(floori(p.x / GRID), floori(p.y / GRID)), PackedInt32Array())
	if cands.is_empty():
		return NAN
	# One pass over the cell's segments notes the roads in reach (into reused buffers:
	# this is called a lot, and allocating per call costs more than the maths), then the
	# blend runs over just those, at the level of the best one.
	var best := INF
	var ref := NAN
	var n := 0
	for k in cands:
		if (1 << _kind[k]) & mask == 0:
			continue
		var a := _p[k]
		var ab := _ab[k]
		var t := clampf((p - a).dot(ab) * _il2[k], 0.0, 1.0)
		var d := p.distance_to(a + ab * t) - _hw[k]
		if d > reach:
			continue
		var h := lerpf(_h[k], _h1[k], t)
		var score := d if is_nan(hint) else absf(h - hint) + 0.05 * maxf(d, 0.0)
		if score < best:
			best = score
			ref = h
		if n == _near_h.size():
			_near_h.resize(n * 2 + 8)
			_near_d.resize(n * 2 + 8)
		_near_h[n] = h
		_near_d[n] = maxf(d, 0.0)
		n += 1
	if n == 0:
		return NAN
	var sum := 0.0
	var wsum := 0.0
	for i in n:
		if absf(_near_h[i] - ref) > LEVEL_GAP:
			continue
		var w := 1.0 / (0.25 + _near_d[i] * _near_d[i])
		sum += _near_h[i] * w
		wsum += w
	return sum / wsum


## Heights of every road surface of the kinds in `mask` covering p (within its width),
## one per road: where a road bends, the segment nearest p.
func heights_at(p: Vector2, mask := ALL) -> PackedFloat32Array:
	var by_line := {}  # line -> Vector2(distance, height)
	for k: int in _grid.get(Vector2i(floori(p.x / GRID), floori(p.y / GRID)), PackedInt32Array()):
		if (1 << _kind[k]) & mask == 0:
			continue
		var a := _p[k]
		var t := clampf((p - a).dot(_ab[k]) * _il2[k], 0.0, 1.0)
		var d := p.distance_to(a + _ab[k] * t)
		var left := _ab[k].cross(p - a) > 0.0  # the Vector2(-dir.y, dir.x) side
		var w := lerpf(_wl[k], _wl[_next[k]], t) if left else lerpf(_wr[k], _wr[_next[k]], t)
		if d <= w and d < (by_line.get(_line[k], Vector2(INF, 0.0)) as Vector2).x:
			by_line[_line[k]] = Vector2(d, lerpf(_h[k], _h1[k], t))
	var out := PackedFloat32Array()
	for v: Vector2 in by_line.values():
		out.append(v.y)
	return out


## How far the open road at p lies below the ground (0 if none, or at grade): roads in
## cuttings and the dips under crossings.
func depth(p: Vector2, pad := 0.0) -> float:
	var cands: PackedInt32Array = _grid.get(Vector2i(floori(p.x / GRID), floori(p.y / GRID)), PackedInt32Array())
	var best := INF
	var out := 0.0
	for k in cands:
		if _kind[k] != Kind.GRADE:
			continue
		var a := _p[k]
		var b := _p[_next[k]]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var d := p.distance_to(a + ab * t) - _hw[k]
		if d < pad and d < best:
			best = d
			out = maxf(0.0, lerpf(_g[k] - _h[k], _g[_next[k]] - _h[_next[k]], t))
	return out


# --- Graph --------------------------------------------------------------------------

func _sample() -> void:
	for li in _lines.size():
		var l: Dictionary = _lines[li]
		var pts: PackedVector2Array = l.pts
		l.first = _p.size()
		var vertex := PackedByteArray()  # 1 where the sample is one of the line's own points
		for k in pts.size() - 1:
			var a := pts[k]
			var b := pts[k + 1]
			var steps := maxi(1, ceili(a.distance_to(b) / STEP))
			for s in steps:
				_add_sample(a.lerp(b, float(s) / steps), li, l)
				vertex.append(1 if s == 0 else 0)
		_add_sample(pts[pts.size() - 1], li, l)
		vertex.append(1)
		_next[_next.size() - 1] = -1
		l.vertex = vertex
		l.count = _p.size() - l.first


func _add_sample(p: Vector2, li: int, l: Dictionary) -> void:
	_p.append(p)
	_kind.append(l.kind)
	_line.append(li)
	_next.append(_p.size())
	_hw.append(l.hw)


## Links samples along each line, and between lines where one ends on another or both
## pass through the same mapped point (a junction). Crossings at different levels share
## no point, so they stay apart.
func _join() -> void:
	var n := _p.size()
	_links.resize(n)
	for k in n:
		_links[k] = PackedInt32Array()
	for k in n:
		if _next[k] >= 0:
			_links[k].append(_next[k])
			_links[_next[k]].append(k)
	var hash := {}
	for li in _lines.size():
		var l: Dictionary = _lines[li]
		for i in l.count:
			var k: int = l.first + i
			var c := Vector2i((_p[k] / 2.0).floor())
			if hash.has(c):
				hash[c].append(k)
			else:
				hash[c] = PackedInt32Array([k])
	for li in _lines.size():
		var l: Dictionary = _lines[li]
		var vertex: PackedByteArray = l.vertex
		for i in l.count:
			var k: int = l.first + i
			var is_end: bool = i == 0 or i == l.count - 1
			if vertex[i] == 0 and not is_end:
				continue
			var c := Vector2i((_p[k] / 2.0).floor())
			var best := -1
			var best_d := JOIN if is_end else 0.3
			var r := 2 if is_end else 1
			for dy in range(-r, r + 1):
				for dx in range(-r, r + 1):
					for j: int in hash.get(c + Vector2i(dx, dy), PackedInt32Array()):
						if _line[j] == li:
							continue
						var lj: Dictionary = _lines[_line[j]]
						var j_end: bool = j == lj.first or j == lj.first + lj.count - 1
						# A street meets a tunnel or bridge only where one carries on from the other
						# (a portal, a bridge end): never partway, and not a lane in a car park that
						# happens to end over a tunnel mouth.
						var other_kind := _kind[j] != _kind[k]
						if other_kind and not (is_end and _continues(k, j)):
							continue
						# Interior points only join interior points they coincide with.
						if not is_end and not j_end and (lj.vertex as PackedByteArray)[j - lj.first] == 0:
							continue
						var d := _p[k].distance_to(_p[j])
						# An end may also stop partway along another road's segment (a slip
						# road meeting a carriageway between its mapped points).
						if is_end and _next[j] >= 0:
							var q := Geometry2D.get_closest_point_to_segment(_p[k], _p[j], _p[_next[j]])
							var nearer := j if q.distance_to(_p[j]) <= q.distance_to(_p[_next[j]]) else _next[j]
							if other_kind and not _continues(k, nearer):
								continue
							if q.distance_to(_p[k]) < best_d:
								best_d = q.distance_to(_p[k])
								best = nearer
							continue
						if d < best_d:
							best_d = d
							best = j
			if best >= 0 and not _links[k].has(best):
				_links[k].append(best)
				_links[best].append(k)


## Links samples of different roads of one kind whose surfaces overlap (a slip road
## running into a carriageway, twin carriageways or ramps mapped close together; roads
## at an angle only if already near one level, so a street passing under a bridge's
## approach isn't tied to it; at
## different layers only where they merge, see _merges): two surfaces in the same place
## must be at one height, so a slip road is pulled down to the
## cutting it merges into and climbs out at MAX_GRADE from there, instead of hanging
## over the carriageway beside it. Pairs the first solve put CLEAR apart are left: one
## is stacked over the other. True if any link was added.
func _link_overlaps() -> bool:
	var added := false
	const CELL := 8.0
	var hash := {}
	var widest := 0.0
	for k in _p.size():
		widest = maxf(widest, _hw[k])
		var c := Vector2i((_p[k] / CELL).floor())
		if hash.has(c):
			hash[c].append(k)
		else:
			hash[c] = PackedInt32Array([k])
	for k in _p.size():
		var layer: int = _lines[_line[k]].layer
		var r := ceili((_hw[k] + widest) / CELL)
		var c := Vector2i((_p[k] / CELL).floor())
		var best := {}  # line -> [sample, distance]: the nearest overlapping sample per road
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				for j: int in hash.get(c + Vector2i(dx, dy), PackedInt32Array()):
					if _line[j] == _line[k] or _kind[j] != _kind[k]:
						continue
					if _lines[_line[j]].layer != layer and not _merges(k, _line[j]):
						continue  # stacked at different layers: kept apart as a crossing
					var d := _p[k].distance_to(_p[j])
					if d >= _hw[k] + _hw[j] - 0.5 or absf(_h[k] - _h[j]) >= CLEAR:
						continue
					if absf(_dir(k).dot(_dir(j))) < OVERLAP_PARALLEL and absf(_h[k] - _h[j]) > LEVEL_GAP:
						continue  # across it and well apart (a street passing under a bridge's ramp): not a merge
					var cur: Array = best.get(_line[j], [-1, INF])
					if d < cur[1]:
						best[_line[j]] = [j, d]
		for li: int in best:
			var j: int = best[li][0]
			if not _links[k].has(j):
				_links[k].append(j)
				_links[j].append(k)
				added = true
	return added


func _is_end(k: int) -> bool:
	var l: Dictionary = _lines[_line[k]]
	return k == l.first or k == l.first + l.count - 1


## True if line ends k and j meet head on (each carrying on where the other stops) and
## are roads of a similar size.
func _continues(k: int, j: int) -> bool:
	if not _is_end(k) or not _is_end(j):
		return false
	if _hw[k] > _hw[j] * 2.0 or _hw[j] > _hw[k] * 2.0:
		return false
	return _end_dir(k).dot(_end_dir(j)) < -0.5


## Direction a line leaves through its end sample k.
func _end_dir(k: int) -> Vector2:
	var l: Dictionary = _lines[_line[k]]
	var inner: int = k + 1 if k == l.first else k - 1
	return (_p[k] - _p[inner]).normalized()


## Narrows roads where another runs alongside closer than their two widths allow (twin
## carriageways mapped too close, a slip beside the main road at another level): each
## gives up its share of the overlap on that side, FIT_GAP apart, keeping at least
## FIT_MIN of its width. At one level only roads abreast (centres at least half their
## widths apart) count, not one merging into or continuing another; roads a clearance
## apart are stacked.
func _fit_widths() -> void:
	const CELL := 8.0
	var n := _p.size()
	_wl.resize(n)
	_wr.resize(n)
	var hash := {}
	var widest := 0.0
	for k in n:
		_wl[k] = _hw[k]
		_wr[k] = _hw[k]
		widest = maxf(widest, _hw[k])
		var c := Vector2i((_p[k] / CELL).floor())
		if hash.has(c):
			hash[c].append(k)
		else:
			hash[c] = PackedInt32Array([k])
	for k in n:
		var dir := _dir(k)
		var nrm := Vector2(-dir.y, dir.x)
		var r := ceili((_hw[k] + widest + FIT_GAP) / CELL)
		var c := Vector2i((_p[k] / CELL).floor())
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				for j: int in hash.get(c + Vector2i(dx, dy), PackedInt32Array()):
					if _line[j] == _line[k]:
						continue
					var dh := absf(_h[j] - _h[k])
					if dh >= CLEAR - 0.6 or absf(_dir(j).dot(dir)) < 0.8:
						continue
					var lateral := nrm.dot(_p[j] - _p[k])
					if dh <= LEVEL_GAP and absf(lateral) < 0.5 * (_hw[k] + _hw[j]):
						continue  # at one level, only twins mapped too close: not merging or continuing
					var along := absf(dir.dot(_p[j] - _p[k]))
					if along > STEP:
						continue  # its sample abreast of this one does the measuring
					var overlap := _hw[k] + _hw[j] + FIT_GAP - absf(lateral)
					if overlap <= 0.0:
						continue
					var w := maxf(_hw[k] * FIT_MIN, _hw[k] - overlap * _hw[k] / (_hw[k] + _hw[j]))
					if lateral > 0.0:
						_wl[k] = minf(_wl[k], w)
					else:
						_wr[k] = minf(_wr[k], w)
	# Ease in and out along each road rather than stepping.
	for li in _lines.size():
		var l: Dictionary = _lines[li]
		_wl = _ease_widths(_wl, l.first, l.count)
		_wr = _ease_widths(_wr, l.first, l.count)


## Widths of one line's samples, each the least within two samples, then averaged.
static func _ease_widths(w: PackedFloat32Array, first: int, count: int) -> PackedFloat32Array:
	var low := PackedFloat32Array()
	low.resize(count)
	for i in count:
		low[i] = w[first + i]
		for m in range(maxi(i - 2, 0), mini(i + 3, count)):
			low[i] = minf(low[i], w[first + m])
	for i in count:
		var sum := 0.0
		var cnt := 0
		for m in range(maxi(i - 1, 0), mini(i + 2, count)):
			sum += low[m]
			cnt += 1
		w[first + i] = minf(sum / cnt, w[first + i])
	return w


## Direction of travel at sample k.
func _dir(k: int) -> Vector2:
	var l: Dictionary = _lines[_line[k]]
	var a := maxi(k - 1, int(l.first))
	var b := mini(k + 1, int(l.first) + int(l.count) - 1)
	return (_p[b] - _p[a]).normalized()


## DEM along the roads, smoothed over the graph so streets don't copy its bumps.
func _ground() -> void:
	var n := _p.size()
	_g.resize(n)
	for k in n:
		_g[k] = dem.call(_p[k])
		if _kind[k] == Kind.BRIDGE:
			_g[k] = maxf(_g[k], 0.0)  # the DEM includes the seabed
	for pass_i in 4:
		var nxt := _g.duplicate()
		for k in n:
			var sum := _g[k]
			var cnt := 1
			for j in _links[k]:
				sum += _g[j]
				cnt += 1
			nxt[k] = sum / cnt
		_g = nxt


## Pairs (upper sample, lower sample) where one road crosses over another without a
## junction, by OSM layer (bridges above, tunnels below, then the layer tags).
func _crossings() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var cell := 24.0
	# Only roads off layer 0 (bridges, tunnels, underpasses) can cross another: hash
	# their segments, then test every segment against them.
	var segs := {}
	for k in _p.size():
		if _next[k] < 0 or _lines[_line[k]].layer == 0:
			continue
		var a := _p[k]
		var b := _p[_next[k]]
		for gy in range(floori(minf(a.y, b.y) / cell), floori(maxf(a.y, b.y) / cell) + 1):
			for gx in range(floori(minf(a.x, b.x) / cell), floori(maxf(a.x, b.x) / cell) + 1):
				var c := Vector2i(gx, gy)
				if segs.has(c):
					segs[c].append(k)
				else:
					segs[c] = PackedInt32Array([k])
	if segs.is_empty():
		return out
	var seen := {}
	for j in _p.size():
		if _next[j] < 0:
			continue
		var a := _p[j]
		var b := _p[_next[j]]
		var lj: Dictionary = _lines[_line[j]]
		for gy in range(floori(minf(a.y, b.y) / cell), floori(maxf(a.y, b.y) / cell) + 1):
			for gx in range(floori(minf(a.x, b.x) / cell), floori(maxf(a.x, b.x) / cell) + 1):
				for k: int in segs.get(Vector2i(gx, gy), PackedInt32Array()):
					var lk: Dictionary = _lines[_line[k]]
					# Each pair of layered roads is met twice: test it once.
					if _line[j] == _line[k] or lk.layer == lj.layer or (lj.layer != 0 and j > k):
						continue
					var x: Variant = Geometry2D.segment_intersects_segment(_p[k], _p[_next[k]], a, b)
					if x == null:
						# Side by side, surfaces overlapping by a metre or more: stacked lanes of
						# an interchange, which need the clearance a crossing does (away from the
						# ends, where a ramp comes down onto the road it joins).
						var near := _side_by_side(k, j)
						if near.x >= 0:
							out.append(near if lk.layer > lj.layer else Vector2i(near.y, near.x))
						continue
					var key := Vector2i(mini(_line[k], _line[j]), maxi(_line[k], _line[j]))
					# One limit per crossing (a crossing on a segment end is met twice).
					var spot := Vector2i(((x as Vector2) / 4.0).floor())
					if seen.has([key, spot]):
						continue
					seen[[key, spot]] = true
					# The samples nearest the crossing on each road.
					var sk := k if (x as Vector2).distance_to(_p[k]) < (x as Vector2).distance_to(_p[_next[k]]) else _next[k]
					var sj := j if (x as Vector2).distance_to(a) < (x as Vector2).distance_to(b) else _next[j]
					if _joined(sk, sj) or _merges(sk, _line[sj], JOIN_CROSS):
						continue  # they meet here after all (a ramp onto a footbridge's span)
					out.append(Vector2i(sk, sj) if lk.layer > lj.layer else Vector2i(sj, sk))
	return out


## For segments k and j (on roads at different layers) whose surfaces overlap by 1 m
## or more side by side: their nearest samples, as (on k, on j); (-1, -1) otherwise or
## within RAMP_END of either road's end.
func _side_by_side(k: int, j: int) -> Vector2i:
	var none := Vector2i(-1, -1)
	var best := INF
	var pair := none
	for sk: int in [k, _next[k]]:
		for sj: int in [j, _next[j]]:
			var d := _p[sk].distance_to(_p[sj])
			if d < best:
				best = d
				pair = Vector2i(sk, sj)
	if best > _hw[k] + _hw[j] - 1.0:
		return none
	if _from_end(pair.x) < RAMP_END or _from_end(pair.y) < RAMP_END or _merges(pair.x, _line[pair.y]):
		return none
	return pair


## True if sample k's road meets road `li` within `reach` along the network (a merge or
## split, whatever their layer tags say): overlapping there, the two come together.
func _merges(k: int, li: int, reach := MERGE) -> bool:
	var dist := {k: 0.0}
	var front := [k]
	while not front.is_empty():
		var i: int = front.pop_back()
		for j in _road_links[i]:
			if _line[j] == li:
				return true
			var d: float = dist[i] + _p[i].distance_to(_p[j])
			if d <= reach and d < dist.get(j, INF):
				dist[j] = d
				front.append(j)
	return false


## Distance along its road from sample k to the nearer end.
func _from_end(k: int) -> float:
	var l: Dictionary = _lines[_line[k]]
	return minf(k - int(l.first), int(l.first) + int(l.count) - 1 - k) * STEP


func _joined(a: int, b: int) -> bool:
	if a == b or _links[a].has(b):
		return true
	for j in _links[a]:
		if _links[j].has(b):
			return true
	return false


# --- Limits ---------------------------------------------------------------------------

## Distance along a line from each of its samples to the nearer of its ends.
func _end_distance(li: int) -> PackedFloat32Array:
	var l: Dictionary = _lines[li]
	var first: int = l.first
	var count: int = l.count
	var along := PackedFloat32Array([0.0])
	for i in range(1, count):
		along.append(along[i - 1] + _p[first + i].distance_to(_p[first + i - 1]))
	var total := along[count - 1]
	var out := PackedFloat32Array()
	out.resize(count)
	for i in count:
		out[i] = minf(along[i], total - along[i])
	return out


## A bridge over another road is lifted by that crossing alone (see solve). One over
## something the map doesn't give us (water, railways, a valley) clears the ground
## below by CLEAR, but only as far as it can climb from its own ends.
func _bridge_limits(li: int, crossed: bool, lo: PackedFloat32Array) -> void:
	var l: Dictionary = _lines[li]
	var dist := _end_distance(li)
	for i in l.count:
		var k: int = l.first + i
		var clear := CLEAR
		if water_at.is_valid() and water_at.call(_p[k]):
			clear = WATER_CLEAR
		elif crossed:
			continue
		lo[k] = maxf(lo[k], _g[k] + minf(clear, MAX_GRADE * dist[i]))


## A dug-down tunnel stays TUNNEL_COVER under the surface (so the roads leading to it
## sink into a cutting); a bored one runs straight from portal to portal, but no
## shallower than TUNNEL_COVER once in from its portals at MAX_GRADE (a straight line
## between portals either side of a river or a valley would run along the ground).
func _tunnel_limits(li: int, target: PackedFloat32Array, hi: PackedFloat32Array) -> void:
	var l: Dictionary = _lines[li]
	var first: int = l.first
	var count: int = l.count
	if l.bored:
		var g0 := _g[first]
		var g1 := _g[first + count - 1]
		var along := 0.0
		var total := 0.0
		for i in range(1, count):
			total += _p[first + i].distance_to(_p[first + i - 1])
		var from_end := _end_distance(li)
		for i in count:
			if i > 0:
				along += _p[first + i].distance_to(_p[first + i - 1])
			var cover := minf(TUNNEL_COVER, MAX_GRADE * from_end[i])
			target[first + i] = minf(lerpf(g0, g1, along / maxf(total, 0.01)), _g[first + i] - cover)
		return
	for i in count:
		var k := first + i
		hi[k] = minf(hi[k], _g[k] - TUNNEL_COVER)
		target[k] = hi[k]


## City tunnels usually sit in one long cutting: the open roads linking two nearby
## portals of dug-down tunnels stay at full depth instead of climbing out between them.
func _link_portals(hi: PackedFloat32Array) -> void:
	var portals := PackedInt32Array()
	for li in _lines.size():
		var l: Dictionary = _lines[li]
		if l.kind != Kind.TUNNEL or l.bored:
			continue
		for k: int in [l.first, l.first + l.count - 1]:
			for j in _links[k]:
				if _kind[j] != Kind.TUNNEL:
					portals.append(k)
					break
	if portals.size() < 2:
		return
	var dists: Array[PackedFloat32Array] = []
	for k in portals:
		dists.append(_open_distances(k, PORTAL_GAP))
	for a in portals.size():
		for b in range(a + 1, portals.size()):
			if _line[portals[a]] == _line[portals[b]] or _p[portals[a]].distance_to(_p[portals[b]]) > PORTAL_GAP:
				continue
			var gap := INF
			for k in _p.size():
				gap = minf(gap, dists[a][k] + dists[b][k])
			if gap > PORTAL_GAP:
				continue
			for k in _p.size():
				if dists[a][k] + dists[b][k] <= gap + 1.0:
					hi[k] = minf(hi[k], _g[k] - TUNNEL_COVER)


## Distance from sample `from` along the open (not tunnel) roads, INF beyond `limit`.
func _open_distances(from: int, limit: float) -> PackedFloat32Array:
	var dist := PackedFloat32Array()
	dist.resize(_p.size())
	dist.fill(INF)
	dist[from] = 0.0
	var queue := PackedInt32Array([from])
	var head := 0
	while head < queue.size():
		var k := queue[head]
		head += 1
		for j in _links[k]:
			if _kind[j] == Kind.TUNNEL:
				continue
			var d := dist[k] + _p[k].distance_to(_p[j])
			if d < dist[j] and d <= limit:
				dist[j] = d
				queue.append(j)
	return dist


## Spreads limits along the graph at MAX_GRADE: the lowest a sample may lie (from `lo`
## limits) or the highest (`upper`, from `hi` limits).
func _envelope(limits: PackedFloat32Array, upper: bool) -> PackedFloat32Array:
	var out := limits.duplicate()
	var queue := PackedInt32Array()
	for k in out.size():
		if not is_inf(out[k]):
			queue.append(k)
	var head := 0
	while head < queue.size():
		var k := queue[head]
		head += 1
		for j in _links[k]:
			var rise := MAX_GRADE * _p[k].distance_to(_p[j])
			var cand := out[k] + rise if upper else out[k] - rise
			if (upper and cand < out[j] - 0.01) or (not upper and cand > out[j] + 0.01):
				out[j] = cand
				queue.append(j)
	return out


func _bounded(target: PackedFloat32Array, lo: PackedFloat32Array, hi: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(target.size())
	for k in target.size():
		if lo[k] > hi[k]:
			# Squeezed between two limits: clearance beats grade (a steeper ramp still
			# drives, a road through a tunnel roof doesn't). A tunnel keeps under what
			# crosses it, a bridge over it; a street splits the difference.
			if _kind[k] == Kind.TUNNEL:
				out[k] = hi[k]
			elif _kind[k] == Kind.BRIDGE:
				out[k] = lo[k]
			else:
				out[k] = (lo[k] + hi[k]) * 0.5
		else:
			out[k] = clampf(target[k], lo[k], hi[k])
	return out


func _build_grid() -> void:
	# Per segment, what surface() needs without chasing _next.
	_ab.resize(_p.size())
	_il2.resize(_p.size())
	_h1.resize(_p.size())
	for k in _p.size():
		if _next[k] < 0:
			continue
		var a := _p[k]
		var b := _p[_next[k]]
		_ab[k] = b - a
		_il2[k] = 1.0 / maxf((b - a).length_squared(), 1e-6)
		_h1[k] = _h[_next[k]]
		var pad := _hw[k] + REACH
		for gy in range(floori((minf(a.y, b.y) - pad) / GRID), floori((maxf(a.y, b.y) + pad) / GRID) + 1):
			for gx in range(floori((minf(a.x, b.x) - pad) / GRID), floori((maxf(a.x, b.x) + pad) / GRID) + 1):
				var c := Vector2i(gx, gy)
				if _grid.has(c):
					_grid[c].append(k)
				else:
					_grid[c] = PackedInt32Array([k])
