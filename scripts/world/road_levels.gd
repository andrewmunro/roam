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
const GRID := 12.0
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
var _g := PackedFloat32Array()  # ground: DEM smoothed along the roads
var _h := PackedFloat32Array()  # solved road height
var _grid := {}  # Vector2i -> PackedInt32Array of segment starts (sample k to _next[k])


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
	for round_i in 4:
		_h = _bounded(target, _envelope(lo, false), _envelope(hi, true))
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
		_h = nxt
	_build_grid()


## Road surface height at p (without any lift): a blend of the roads whose surface
## covers p (or comes within `reach` of it), of the kinds in `mask`, keeping to one
## level: that of the closest road, or with `hint` (the height of the piece being
## built, from its own centre line) the road nearest that height, so a junction beside
## a cutting stays at street level. NAN if no such road is near.
func surface(p: Vector2, mask := ALL, reach := REACH, hint := NAN) -> float:
	var cands: PackedInt32Array = _grid.get(Vector2i(floori(p.x / GRID), floori(p.y / GRID)), PackedInt32Array())
	if cands.is_empty():
		return NAN
	# Two passes (closest road, then the blend at its level): this is called a lot, and
	# allocating per call costs more than measuring twice.
	var best := INF
	var ref := NAN
	for k in cands:
		if (1 << _kind[k]) & mask == 0:
			continue
		var a := _p[k]
		var ab := _p[_next[k]] - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var d := p.distance_to(a + ab * t) - _hw[k]
		if d > reach:
			continue
		var h := lerpf(_h[k], _h[_next[k]], t)
		var score := d if is_nan(hint) else absf(h - hint) + 0.05 * maxf(d, 0.0)
		if score < best:
			best = score
			ref = h
	if is_nan(ref):
		return NAN
	var sum := 0.0
	var wsum := 0.0
	for k in cands:
		if (1 << _kind[k]) & mask == 0:
			continue
		var a := _p[k]
		var ab := _p[_next[k]] - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		var d := p.distance_to(a + ab * t) - _hw[k]
		if d > reach:
			continue
		var h := lerpf(_h[k], _h[_next[k]], t)
		if absf(h - ref) > LEVEL_GAP:
			continue
		d = maxf(d, 0.0)
		var w := 1.0 / (0.25 + d * d)
		sum += h * w
		wsum += w
	return sum / wsum


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
						# Interior points only join interior points they coincide with.
						if not is_end and not j_end and (lj.vertex as PackedByteArray)[j - lj.first] == 0:
							continue
						var d := _p[k].distance_to(_p[j])
						# An end may also stop partway along another road's segment (a slip
						# road meeting a carriageway between its mapped points).
						if is_end and _next[j] >= 0:
							var q := Geometry2D.get_closest_point_to_segment(_p[k], _p[j], _p[_next[j]])
							if q.distance_to(_p[k]) < best_d:
								best_d = q.distance_to(_p[k])
								best = j if q.distance_to(_p[j]) <= q.distance_to(_p[_next[j]]) else _next[j]
							continue
						if d < best_d:
							best_d = d
							best = j
			if best >= 0 and not _links[k].has(best):
				_links[k].append(best)
				_links[best].append(k)


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
					if _joined(sk, sj):
						continue  # they meet at a junction here after all
					out.append(Vector2i(sk, sj) if lk.layer > lj.layer else Vector2i(sj, sk))
	return out


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
## sink into a cutting); a bored one runs straight from portal to portal.
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
		for i in count:
			if i > 0:
				along += _p[first + i].distance_to(_p[first + i - 1])
			target[first + i] = minf(lerpf(g0, g1, along / maxf(total, 0.01)), _g[first + i])
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


static func _bounded(target: PackedFloat32Array, lo: PackedFloat32Array, hi: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(target.size())
	for k in target.size():
		if lo[k] > hi[k]:
			out[k] = (lo[k] + hi[k]) * 0.5  # squeezed between two limits: split the difference
		else:
			out[k] = clampf(target[k], lo[k], hi[k])
	return out


func _build_grid() -> void:
	for k in _p.size():
		if _next[k] < 0:
			continue
		var a := _p[k]
		var b := _p[_next[k]]
		var pad := _hw[k] + REACH
		for gy in range(floori((minf(a.y, b.y) - pad) / GRID), floori((maxf(a.y, b.y) + pad) / GRID) + 1):
			for gx in range(floori((minf(a.x, b.x) - pad) / GRID), floori((maxf(a.x, b.x) + pad) / GRID) + 1):
				var c := Vector2i(gx, gy)
				if _grid.has(c):
					_grid[c].append(k)
				else:
					_grid[c] = PackedInt32Array([k])
