class_name RoadNetwork
extends RefCounted
## Road graph for one chunk, built from the tile's at-grade roads plus the nearby parts
## of the neighbouring tiles' roads. Roads become ribbons that stop short of each
## junction; every junction gets one merged surface with rounded corners, kerbs,
## markings and the signs or lights that control it, and small circular loops become
## roundabouts. Pure data, so it runs on the chunk builder's worker thread.
##
## Every chunk sees the same graph around its edges, so junctions on a seam come out
## identically in both chunks. Geometry is emitted only by the chunk that owns it: edges
## from its own tile, junctions and roundabouts whose centre lies inside it.

const SNAP := 0.75  ## line ends closer than this are one node
const T_SNAP := 1.5  ## a dangling end this close to another road joins it there
const MARGIN := 150.0  ## how far into the neighbouring tiles the graph reaches
const DASH := 12.0  ## centre line period; each edge fits a whole number of them
const KERB := 0.12
const PAVEMENT := 2.0
const PAINT := Color(0.88, 0.88, 0.84)
const YELLOW := Color(0.86, 0.68, 0.16)
const KERB_COLOR := Color(0.74, 0.73, 0.70)
const PAVING := Color(0.63, 0.62, 0.59)
const VERGE := Color(0.50, 0.49, 0.46)
const GRASS := Color(0.43, 0.57, 0.33)
const STYLE_PAINT := 64  ## UV2.y for solid paint (see road.gdshader)
const GRID := 24.0  ## spatial hash cell for clearance queries

enum Ctl { NONE, PRIORITY, SIGNALS, ALL_STOP, MINI }
enum Pt { SIGNALS, MINI, GIVE_WAY, STOP }

# Inputs
var size: float
var region: String
var left_hand := false
var north_america := false
var uk := false
var height_at: Callable  ## (Vector2) -> float, final terrain height
## Overpass nodes near the tile: {pos: Vector2, kind: Pt}.
var points: Array[Dictionary] = []
var have_points := false  ## false: no Overpass data, so guess where the signals are

# Outputs
var verts := PackedVector3Array()
var uvs := PackedVector2Array()
var uv2s := PackedVector2Array()
var colors := PackedColorArray()
var indices := PackedInt32Array()
var instances: Array[Array] = []  ## [role: String, xf: Transform3D]
var paved: Array[Dictionary] = []  ## own edges with pavements: {pts, hw}
var ring_zones: Array[Vector3] = []  ## roundabouts: (centre x, centre z, outer radius)
## No parking near junctions: {pts, hw} strips from each junction along its arms.
var no_park: Array[Dictionary] = []
var stats := {junctions = 0, roundabouts = 0, signals = 0, mini = 0, give_way = 0, stops = 0}
var signal_spots: Array[Vector2] = []  ## centres of signalised junctions (for tests)

var _lines: Array[Dictionary] = []
var _node_pos := PackedVector2Array()
var _node_ends: Array[Array] = []  # per node: end codes (edge * 2 + side, side 0 = edge.a)
var _edges: Array[Dictionary] = []
var _junction := PackedByteArray()  # per node: 1 = junction (not a plain continuation)
var _ring_of_node := PackedInt32Array()
var _rings: Array[Dictionary] = []
var _clusters: Array[Dictionary] = []
var _seg_grid := {}  # Vector2i -> Array of edge ids
var _pt_grid := {}  # Vector2i -> Array of point indices


## Adds a road polyline. `oneway` follows OSM: 1 along the line, -1 against it.
## Phantom lines (bridges, tunnels) shape junctions but are drawn elsewhere.
## `lanes_hw` is the half width of the travel lanes alone (without parking).
func add_line(pts: PackedVector2Array, cls: String, hw: float, lanes_hw: float, rank: int,
		color: Color, marking: int, oneway: int, own: bool, pave: bool, phantom := false) -> void:
	var p := PackedVector2Array()
	for q in pts:
		if p.is_empty() or q.distance_squared_to(p[p.size() - 1]) > 0.0025:
			p.append(q)
	if p.size() < 2:
		return
	if oneway < 0:
		p.reverse()
	_lines.append({pts = p, cls = cls, hw = hw, lanes_hw = lanes_hw, rank = rank, color = color, mark = marking,
		oneway = oneway != 0, own = own, pave = pave, phantom = phantom})


func build() -> void:
	var t0 := Time.get_ticks_usec()
	var tm := []
	_build_graph()
	tm.append(Time.get_ticks_usec())
	_lines.clear()
	_find_rings()
	_classify_nodes()
	_build_clusters()
	tm.append(Time.get_ticks_usec())
	_build_grids()
	tm.append(Time.get_ticks_usec())
	for r in _rings:
		_ring_cuts(r)
	for c in _clusters:
		_cluster_cuts(c)
	tm.append(Time.get_ticks_usec())
	for r in _rings:
		if _owned(r.centre):
			_emit_ring(r)
	for c in _clusters:
		if _owned(c.centre):
			_emit_cluster(c)
	tm.append(Time.get_ticks_usec())
	for e in _edges:
		if e.own and not e.phantom and e.ring < 0:
			_emit_edge(e)
	tm.append(Time.get_ticks_usec())
	var out := []
	var last := t0
	for t: int in tm:
		out.append((t - last) / 1000)
		last = t
	if OS.has_environment("ROAM_ROAD_TIMES"):
		print("road network ms (graph, rings, grids, cuts, junctions, edges): ", out)


func _owned(p: Vector2) -> bool:
	return p.x >= 0.0 and p.y >= 0.0 and p.x < size and p.y < size


static func _lift(rank: int) -> float:
	return 0.12 + rank * 0.025


# --- Graph ----------------------------------------------------------------------------

static func _key(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x * 8.0), roundi(p.y * 8.0))


static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


func _build_graph() -> void:
	# Line ends that nearly meet (tile seams, rounding) become one point.
	var ends := PackedVector2Array()
	for l in _lines:
		var pts: PackedVector2Array = l.pts
		ends.append(pts[0])
		ends.append(pts[pts.size() - 1])
	var parent := PackedInt32Array()
	parent.resize(ends.size())
	for i in parent.size():
		parent[i] = i
	var grid := {}
	for i in ends.size():
		var c := Vector2i(floori(ends[i].x / 2.0), floori(ends[i].y / 2.0))
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var cell: Variant = grid.get(c + Vector2i(dx, dy))
				if cell == null:
					continue
				for j: int in cell:
					if ends[i].distance_squared_to(ends[j]) < SNAP * SNAP:
						parent[_find(parent, i)] = _find(parent, j)
		if grid.has(c):
			grid[c].append(i)
		else:
			grid[c] = [i]
	var sums := {}
	for i in ends.size():
		var r := _find(parent, i)
		var s: Vector3 = sums.get(r, Vector3.ZERO)
		sums[r] = s + Vector3(ends[i].x, ends[i].y, 1.0)
	var cluster_size := {}
	for i in ends.size():
		var r := _find(parent, i)
		cluster_size[r] = cluster_size.get(r, 0) + 1
		var s: Vector3 = sums[r]
		var l: Dictionary = _lines[i >> 1]
		var pts: PackedVector2Array = l.pts
		pts[0 if i & 1 == 0 else pts.size() - 1] = Vector2(s.x / s.z, s.y / s.z)
		l.pts = pts
	var count := _vertex_counts()
	# Dangling ends that stop on another road (simplification dropped the shared
	# vertex): split that road there.
	var seg_grid := {}
	for li in _lines.size():
		var pts: PackedVector2Array = _lines[li].pts
		for k in pts.size() - 1:
			for c in _cells(pts[k], pts[k + 1], T_SNAP):
				if seg_grid.has(c):
					seg_grid[c].append(Vector2i(li, k))
				else:
					seg_grid[c] = [Vector2i(li, k)]
	var inserts := {}  # line -> Array of [segment, t, point]
	for i in ends.size():
		var li := i >> 1
		var pts: PackedVector2Array = _lines[li].pts
		var p := pts[0 if i & 1 == 0 else pts.size() - 1]
		if cluster_size[_find(parent, i)] > 1 or count.get(_key(p), 0) > 1:
			continue
		var c := Vector2i(floori(p.x / GRID), floori(p.y / GRID))
		var best := T_SNAP
		var hit := Vector3(-1, 0, 0)
		var hit_p := Vector2.ZERO
		for s: Vector2i in seg_grid.get(c, []):
			var opts: PackedVector2Array = _lines[s.x].pts
			if s.x == li and (s.y <= 1 or s.y >= opts.size() - 3):
				continue
			var a := opts[s.y]
			var b := opts[s.y + 1]
			var ab := b - a
			var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
			var q := a + ab * t
			var d := p.distance_to(q)
			if d < best:
				best = d
				hit = Vector3(s.x, s.y, t)
				hit_p = q
		if hit.x < 0:
			continue
		if hit.z <= 0.001 or hit.z >= 0.999:
			hit_p = _lines[int(hit.x)].pts[int(hit.y) + (1 if hit.z > 0.5 else 0)]
		else:
			if not inserts.has(int(hit.x)):
				inserts[int(hit.x)] = []
			inserts[int(hit.x)].append([int(hit.y), hit.z, hit_p])
		pts[0 if i & 1 == 0 else pts.size() - 1] = hit_p
		_lines[li].pts = pts
	for li: int in inserts:
		var list: Array = inserts[li]
		list.sort_custom(func(x: Array, y: Array) -> bool:
			return x[0] > y[0] or (x[0] == y[0] and x[1] > y[1]))
		var pts: PackedVector2Array = _lines[li].pts
		for ins: Array in list:
			pts.insert(int(ins[0]) + 1, ins[2])
		_lines[li].pts = pts
	count = _vertex_counts()
	# Split lines into edges at every node: ends and shared vertices.
	var node_of := {}
	for l in _lines:
		var pts: PackedVector2Array = l.pts
		var start := 0
		for k in range(1, pts.size()):
			if k == pts.size() - 1 or count[_key(pts[k])] >= 2:
				_add_edge(pts.slice(start, k + 1), l, _node(node_of, pts[start]), _node(node_of, pts[k]))
				start = k
	_junction.resize(_node_pos.size())
	_junction.fill(0)
	_ring_of_node.resize(_node_pos.size())
	_ring_of_node.fill(-1)


func _vertex_counts() -> Dictionary:
	var count := {}
	for l in _lines:
		var pts: PackedVector2Array = l.pts
		for k in pts.size():
			var key := _key(pts[k])
			count[key] = count.get(key, 0) + 1
		if pts[0].distance_squared_to(pts[pts.size() - 1]) < 1e-6:
			count[_key(pts[0])] = count.get(_key(pts[0]), 0) + 1  # closed loop: its start is a node
	return count


## Grid cells a segment (grown by `pad`) touches.
static func _cells(a: Vector2, b: Vector2, pad: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var i0 := floori((minf(a.x, b.x) - pad) / GRID)
	var i1 := floori((maxf(a.x, b.x) + pad) / GRID)
	var j0 := floori((minf(a.y, b.y) - pad) / GRID)
	var j1 := floori((maxf(a.y, b.y) + pad) / GRID)
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			out.append(Vector2i(i, j))
	return out


func _node(node_of: Dictionary, p: Vector2) -> int:
	var key := _key(p)
	if node_of.has(key):
		return node_of[key]
	var id := _node_pos.size()
	node_of[key] = id
	_node_pos.append(p)
	_node_ends.append([])
	return id


func _add_edge(pts: PackedVector2Array, l: Dictionary, a: int, b: int) -> void:
	pts[0] = _node_pos[a]
	pts[pts.size() - 1] = _node_pos[b]
	var dist := PackedFloat32Array([0.0])
	for k in range(1, pts.size()):
		dist.append(dist[k - 1] + pts[k].distance_to(pts[k - 1]))
	var length := dist[dist.size() - 1]
	if length < 0.05:
		return
	var id := _edges.size()
	_edges.append({a = a, b = b, pts = pts, dist = dist, len = length, hw = l.hw, lanes_hw = l.lanes_hw, rank = l.rank,
		cls = l.cls, color = l.color, mark = l.mark, oneway = l.oneway, own = l.own, pave = l.pave,
		phantom = l.phantom, c0 = 0.0, c1 = 0.0, ring = -1, internal = false, id = id})
	_node_ends[a].append(id * 2)
	_node_ends[b].append(id * 2 + 1)


## Point and outward direction (away from that end) at distance s from an edge end.
func _frame(e: Dictionary, side: int, s: float) -> Array:
	var length: float = e.len
	var d := s if side == 0 else length - s
	var pts: PackedVector2Array = e.pts
	var dist: PackedFloat32Array = e.dist
	var k := clampi(dist.bsearch(d), 1, pts.size() - 1)
	var seg := dist[k] - dist[k - 1]
	var t := clampf((d - dist[k - 1]) / maxf(seg, 1e-6), 0.0, 1.0)
	var fwd := (pts[k] - pts[k - 1]).normalized()
	return [pts[k - 1].lerp(pts[k], t), fwd if side == 0 else -fwd]


## Exact direction of an edge's end segment, pointing away from that end.
func _end_dir(e: Dictionary, side: int) -> Vector2:
	var pts: PackedVector2Array = e.pts
	if side == 0:
		return (pts[1] - pts[0]).normalized()
	return (pts[pts.size() - 2] - pts[pts.size() - 1]).normalized()


## Smoothed direction away from an end (a few metres along), for junction layout.
func _arm_dir(e: Dictionary, side: int) -> Vector2:
	var s := minf(5.0, e.len)
	var f: Array = _frame(e, side, s)
	var origin: Vector2 = e.pts[0] if side == 0 else e.pts[e.pts.size() - 1]
	var d: Vector2 = f[0] - origin
	return d.normalized() if d.length() > 0.01 else _end_dir(e, side)


func _other_end(node: int, end: int) -> int:
	for o: int in _node_ends[node]:
		if o != end:
			return o
	return end


# --- Roundabouts ------------------------------------------------------------------------

func _find_rings() -> void:
	var out := {}  # node -> oneway edges leaving it
	for i in _edges.size():
		var e: Dictionary = _edges[i]
		if e.phantom or e.rank < 3:
			continue
		if e.a == e.b:
			_try_ring([i])  # closed loop, one way or not
		elif e.oneway:
			if out.has(e.a):
				out[e.a].append(i)
			else:
				out[e.a] = [i]
	for i in _edges.size():
		var e0: Dictionary = _edges[i]
		if not e0.oneway or e0.ring >= 0 or e0.phantom or e0.a == e0.b or not out.has(e0.a) or e0.len > 150.0:
			continue
		if e0.len > 25.0 and (e0.pts as PackedVector2Array).size() < 3:
			continue  # long and straight: not part of a roundabout
		# Depth-first along one-way edges back to the start, short routes only.
		var stack: Array = [[i]]
		var budget := 24
		while not stack.is_empty() and budget > 0:
			budget -= 1
			var path: Array = stack.pop_back()
			var last: Dictionary = _edges[path[path.size() - 1]]
			if last.b == e0.a:
				if _try_ring(path):
					break
				continue
			if path.size() >= 10:
				continue
			var total := 0.0
			for id: int in path:
				total += _edges[id].len
			if total > 300.0:
				continue
			for nxt: int in out.get(last.b, []):
				if _edges[nxt].ring < 0 and _edges[nxt].len < 150.0 and not path.has(nxt):
					stack.append(path + [nxt])


## Accepts a closed run of edges as a roundabout if it is round and small.
func _try_ring(path: Array) -> bool:
	var poly := PackedVector2Array()
	var perimeter := 0.0
	var rank := 0
	var hw := 0.0
	for id: int in path:
		var e: Dictionary = _edges[id]
		if e.ring >= 0:
			return false
		var pts: PackedVector2Array = e.pts
		poly.append_array(pts.slice(0, pts.size() - 1))
		perimeter += e.len
		rank = maxi(rank, e.rank)
		hw = maxf(hw, e.hw)
	if poly.size() < 3:
		return false
	var area := 0.0
	var cx := 0.0
	var cy := 0.0
	for k in poly.size():
		var p := poly[k]
		var q := poly[(k + 1) % poly.size()]
		var cr := p.cross(q)
		area += cr
		cx += (p.x + q.x) * cr
		cy += (p.y + q.y) * cr
	area *= 0.5
	if absf(area) < 1.0:
		return false
	var circ := 4.0 * PI * absf(area) / (perimeter * perimeter)
	var radius := sqrt(absf(area) / PI)
	if circ < 0.8 or radius < 4.0 or radius > 45.0:
		return false
	var centre := Vector2(cx, cy) / (6.0 * area)
	var width := clampf(hw * 0.85, 3.2, 6.0)
	width = minf(width, radius * 0.55)
	var id := _rings.size()
	var nodes: Array[int] = []
	for eid: int in path:
		_edges[eid].ring = id
		for n: int in [_edges[eid].a, _edges[eid].b]:
			if not nodes.has(n):
				nodes.append(n)
	_rings.append({centre = centre, r = radius, hw = width, rank = rank, nodes = nodes,
		edges = path.duplicate(), arms = [], color = _edges[path[0]].color})
	return true


# --- Junctions --------------------------------------------------------------------------

func _classify_nodes() -> void:
	for ri in _rings.size():
		for n: int in _rings[ri].nodes:
			_ring_of_node[n] = ri
	for n in _node_pos.size():
		var ends: Array = _node_ends[n]
		if _ring_of_node[n] >= 0 or ends.size() < 2:
			continue
		if ends.size() >= 3:
			_junction[n] = 1
			continue
		var e1: Dictionary = _edges[ends[0] >> 1]
		var e2: Dictionary = _edges[ends[1] >> 1]
		if ends[0] >> 1 == ends[1] >> 1:
			continue  # loop through a single node
		var straight := _end_dir(e1, ends[0] & 1).dot(_end_dir(e2, ends[1] & 1)) < -0.64
		if absf(e1.hw - e2.hw) > 0.05 or not straight:
			_junction[n] = 1


func _build_clusters() -> void:
	# Junctions a few metres apart (dual carriageways, staggered side roads) merge.
	var parent := PackedInt32Array()
	parent.resize(_node_pos.size())
	for i in parent.size():
		parent[i] = i
	for i in _edges.size():
		var e: Dictionary = _edges[i]
		if e.a == e.b or not _junction[e.a] or not _junction[e.b] or e.phantom:
			continue
		if e.len < minf(18.0, 2.0 * e.hw + 4.0):
			parent[_find(parent, e.a)] = _find(parent, e.b)
			e.internal = true
	var groups := {}
	for n in _node_pos.size():
		if _junction[n]:
			var r := _find(parent, n)
			if groups.has(r):
				groups[r].append(n)
			else:
				groups[r] = [n]
	for r: int in groups:
		var nodes: Array = groups[r]
		var extent := 0.0
		for a: int in nodes:
			for b: int in nodes:
				extent = maxf(extent, _node_pos[a].distance_to(_node_pos[b]))
		if extent > 45.0:
			for n: int in nodes:
				for end: int in _node_ends[n]:
					_edges[end >> 1].internal = false
			for n: int in nodes:
				_add_cluster([n])
		else:
			_add_cluster(nodes)


func _add_cluster(nodes: Array) -> void:
	var centre := Vector2.ZERO
	for n: int in nodes:
		centre += _node_pos[n]
	centre /= nodes.size()
	var arms: Array[Dictionary] = []
	var all_phantom := true
	for n: int in nodes:
		for end: int in _node_ends[n]:
			var e: Dictionary = _edges[end >> 1]
			if (e.internal and nodes.has(e.a) and nodes.has(e.b)) or e.ring >= 0:
				continue
			var arm := _walk_arm(n, end)
			arms.append(arm)
			all_phantom = all_phantom and arm.phantom
	if arms.size() < 2 or all_phantom:
		return
	for n: int in nodes:
		for end: int in _node_ends[n]:
			var e: Dictionary = _edges[end >> 1]
			if e.internal and nodes.has(e.a) and nodes.has(e.b):
				e.c0 = e.len  # covered by the junction surface
				e.c1 = e.len
	for arm in arms:
		var to: Vector2 = arm.origin + arm.dir * 8.0 - centre
		arm.angle = atan2(to.y, to.x)
	arms.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.angle < y.angle)
	_clusters.append({nodes = nodes, centre = centre, arms = arms})


## Follows a road away from a junction through plain continuations, far enough to
## place the junction's cut. Returns the arm's description.
func _walk_arm(node: int, end: int) -> Dictionary:
	var path: Array[Vector2i] = []  # (edge, side at the near end)
	var total := 0.0
	var eid := end >> 1
	var side := end & 1
	var far_junction := false
	while true:
		path.append(Vector2i(eid, side))
		var e: Dictionary = _edges[eid]
		total += e.len
		var far: int = e.b if side == 0 else e.a
		if far == node or total > 80.0:
			break
		if _junction[far] or _ring_of_node[far] >= 0:
			far_junction = true
			break
		if _node_ends[far].size() != 2:
			break
		var nxt := _other_end(far, eid * 2 + (1 - side))
		if nxt >> 1 == eid:
			break
		eid = nxt >> 1
		side = nxt & 1
	var first: Dictionary = _edges[end >> 1]
	var oneway := 0
	if first.oneway:
		oneway = 1 if end & 1 == 0 else -1
	return {node = node, origin = _node_pos[node], path = path, len = total, far_junction = far_junction,
		hw = first.hw, rank = first.rank, phantom = first.phantom, pave = first.pave, oneway = oneway,
		color = first.color, dir = _arm_dir(first, end & 1), cut = 0.0, angle = 0.0}


## Frame on an arm at distance s from its junction node: [point, outward dir].
func _arm_frame(arm: Dictionary, s: float) -> Array:
	var rem := s
	var path: Array[Vector2i] = arm.path
	for k in path.size():
		var e: Dictionary = _edges[path[k].x]
		if rem <= e.len or k == path.size() - 1:
			return _frame(e, path[k].y, minf(rem, e.len))
		rem -= e.len
	return [arm.origin, arm.dir]


func _apply_cut(arm: Dictionary, cut: float) -> void:
	arm.cut = cut
	var rem := cut
	var path: Array[Vector2i] = arm.path
	for k in path.size():
		var e: Dictionary = _edges[path[k].x]
		var key := "c0" if path[k].y == 0 else "c1"
		if rem >= e.len and k < path.size() - 1:
			e[key] = e.len
			rem -= e.len
			continue
		e[key] = maxf(e[key], minf(rem, e.len))
		arm.mouth = _frame(e, path[k].y, minf(rem, e.len))
		return


func _keep_clear(arm: Dictionary) -> void:
	var o: Vector2 = arm.origin
	if o.x < -60.0 or o.y < -60.0 or o.x > size + 60.0 or o.y > size + 60.0:
		return  # too far away to matter to this tile
	var pts := PackedVector2Array()
	var s := 0.0
	var end: float = minf(arm.cut + 12.0, arm.len)
	while true:
		pts.append(_arm_frame(arm, s)[0])
		if s >= end:
			break
		s = minf(s + 8.0, end)
	no_park.append({pts = pts, hw = arm.hw})


func _cut_cap(arm: Dictionary) -> float:
	return arm.len * 0.45 if arm.far_junction else maxf(arm.len - 0.5, 0.1)


func _cluster_cuts(c: Dictionary) -> void:
	var arms: Array[Dictionary] = c.arms
	var n := arms.size()
	var need := PackedFloat32Array()
	need.resize(n)
	need.fill(1.0)
	for i in n:
		var j := (i + 1) % n
		var a := arms[i]
		var b := arms[j]
		var gap := fposmod(b.angle - a.angle, TAU)
		if gap > PI * 0.94:
			continue  # straight on, or the outside of a bend: no corner to round
		var da: Vector2 = a.dir
		var db: Vector2 = b.dir
		var pa: Vector2 = a.origin + Vector2(-da.y, da.x) * a.hw
		var pb: Vector2 = b.origin - Vector2(-db.y, db.x) * b.hw
		var den := da.cross(db)
		var radius := clampf(0.6 * minf(a.hw, b.hw) + 2.0, 2.5, 6.0)
		var t := 0.0
		var u := 0.0
		# Roads meeting at a sharp angle (slip roads, diverging carriageways) would only
		# clear each other far out; let the surface fill the gore instead.
		var reach := maxf(a.hw, b.hw) * 1.5 + 6.0
		if absf(den) > 0.02:
			t = clampf((pb - pa).cross(db) / den, 0.0, reach)
			u = clampf((pb - pa).cross(da) / den, 0.0, reach)
		need[i] = maxf(need[i], t + radius)
		need[j] = maxf(need[j], u + radius)
	for i in n:
		_apply_cut(arms[i], clampf(need[i], 0.1, _cut_cap(arms[i])))
		if n > 2:
			_keep_clear(arms[i])


func _ring_cuts(r: Dictionary) -> void:
	var outer: float = r.r + r.hw
	var centre: Vector2 = r.centre
	var arms: Array[Dictionary] = []
	for n: int in r.nodes:
		for end: int in _node_ends[n]:
			var e: Dictionary = _edges[end >> 1]
			if e.ring == _ring_of_node[n] and e.ring >= 0:
				continue
			var arm := _walk_arm(n, end)
			# Where the arm leaves the circulating carriageway.
			var s_exit := 0.0
			while s_exit < arm.len:
				var f: Array = _arm_frame(arm, s_exit)
				if (f[0] as Vector2).distance_to(centre) >= outer:
					break
				s_exit += 0.5
			arm.s_exit = s_exit
			var flare := clampf(arm.hw * 0.8 + 1.5, 2.5, 6.0)
			_apply_cut(arm, clampf(s_exit + flare, 0.5, _cut_cap(arm)))
			_keep_clear(arm)
			var to: Vector2 = (arm.mouth[0] as Vector2) - centre
			arm.angle = atan2(to.y, to.x)
			arms.append(arm)
	for eid: int in r.edges:
		_edges[eid].c0 = _edges[eid].len
		_edges[eid].c1 = _edges[eid].len
	r.arms = arms
	ring_zones.append(Vector3(centre.x, centre.y, outer))


# --- Spatial queries --------------------------------------------------------------------

func _build_grids() -> void:
	for i in _edges.size():
		var e: Dictionary = _edges[i]
		if e.phantom:
			continue
		var pts: PackedVector2Array = e.pts
		for k in pts.size() - 1:
			for c in _cells(pts[k], pts[k + 1], e.hw):
				if _seg_grid.has(c):
					if _seg_grid[c].back() != i:
						_seg_grid[c].append(i)
				else:
					_seg_grid[c] = [i]
	for i in points.size():
		var p: Vector2 = points[i].pos
		var c := Vector2i(floori(p.x / GRID), floori(p.y / GRID))
		if _pt_grid.has(c):
			_pt_grid[c].append(i)
		else:
			_pt_grid[c] = [i]


## True if p is on the carriageway of a road other than `skip`.
func _on_other_road(p: Vector2, skip: int) -> bool:
	var c := Vector2i(floori(p.x / GRID), floori(p.y / GRID))
	for i: int in _seg_grid.get(c, []):
		if i == skip:
			continue
		var e: Dictionary = _edges[i]
		var pts: PackedVector2Array = e.pts
		var lim: float = e.hw + 0.3
		for k in pts.size() - 1:
			var q := Geometry2D.get_closest_point_to_segment(p, pts[k], pts[k + 1])
			if q.distance_squared_to(p) < lim * lim:
				return true
	return false


## Overpass points of a kind within `radius` of p.
func _points_near(p: Vector2, radius: float, kind: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var r := ceili(radius / GRID)
	var c := Vector2i(floori(p.x / GRID), floori(p.y / GRID))
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			for i: int in _pt_grid.get(c + Vector2i(dx, dy), []):
				var pt: Dictionary = points[i]
				if pt.kind == kind and (pt.pos as Vector2).distance_to(p) <= radius:
					out.append(pt.pos)
	return out


# --- Mesh helpers -----------------------------------------------------------------------

func _ribbon_h(p: Vector2, n: Vector2, hw: float, lift: float) -> float:
	return maxf(height_at.call(p), maxf(height_at.call(p + n * hw), height_at.call(p - n * hw))) + lift


func _vert(p: Vector3, uv: Vector2, uv2: Vector2, color: Color) -> int:
	verts.append(p)
	uvs.append(uv)
	uv2s.append(uv2)
	colors.append(color)
	return verts.size() - 1


## Triangle that faces up (or `facing`), whatever order its corners come in.
func _tri(a: int, b: int, c: int, facing := Vector3.UP) -> void:
	var n := (verts[b] - verts[a]).cross(verts[c] - verts[a])
	if n.dot(facing) > 0.0:
		indices.append_array([a, c, b])
	else:
		indices.append_array([a, b, c])


func _quad(a: int, b: int, c: int, d: int, facing := Vector3.UP) -> void:
	_tri(a, b, c, facing)
	_tri(a, c, d, facing)


## Flat polygon (any winding), triangulated; heights per vertex.
func _fill(poly: PackedVector2Array, hs: PackedFloat32Array, color: Color, centre: Vector2) -> void:
	var base := verts.size()
	for k in poly.size():
		_vert(Vector3(poly[k].x, hs[k], poly[k].y), Vector2(0.5, 0.0), Vector2.ZERO, color)
	var tris := Geometry2D.triangulate_polygon(poly)
	if tris.is_empty():
		# Self-intersecting outline (crossing corner curves at awkward junctions): fan
		# from the centre instead; overlaps don't show as it's all one colour.
		var h := -INF
		for v in hs:
			h = maxf(h, v)
		var mid := _vert(Vector3(centre.x, h, centre.y), Vector2(0.5, 0.0), Vector2.ZERO, color)
		for k in poly.size():
			_tri(mid, base + k, base + (k + 1) % poly.size())
		return
	for t in range(0, tris.size(), 3):
		_tri(base + tris[t], base + tris[t + 1], base + tris[t + 2])


## Paint quad (corners in order), lying at height h.
func _paint(corners: Array[Vector2], h: float, color := PAINT) -> void:
	var base := verts.size()
	for c in corners:
		_vert(Vector3(c.x, h + 0.02, c.y), Vector2.ZERO, Vector2(0.0, STYLE_PAINT), color)
	_quad(base, base + 1, base + 2, base + 3)


## A line across an arm at distance s from its junction, from x0 to x1 metres off the
## centre line (positive towards the arm's left looking out), optionally dashed.
func _across(arm: Dictionary, s: float, x0: float, x1: float, width: float, dash := 0.0,
		gap := 0.0, color := PAINT) -> void:
	var f: Array = _arm_frame(arm, s)
	var p: Vector2 = f[0]
	var t: Vector2 = f[1]
	var n := Vector2(-t.y, t.x)
	var h := _ribbon_h(p, n, arm.hw, _lift(arm.rank))
	var half := t * width * 0.5
	if dash <= 0.0:
		_paint([p + n * x0 - half, p + n * x1 - half, p + n * x1 + half, p + n * x0 + half], h, color)
		return
	var x := x0
	while x < x1 - 0.05:
		var xe := minf(x + dash, x1)
		_paint([p + n * x - half, p + n * xe - half, p + n * xe + half, p + n * x + half], h, color)
		x = xe + gap


## The part of an arm's width carrying traffic towards the junction, as offsets from
## the centre line along the arm's left normal; empty if the arm is exit-only.
func _approach(arm: Dictionary) -> Vector2:
	var w: float = arm.hw - 0.3
	if arm.oneway == 1:
		return Vector2.ZERO
	if arm.oneway == -1:
		return Vector2(-w, w)
	# Looking out along the arm, inbound traffic keeps to the arm's left in left-hand
	# traffic countries and to its right elsewhere.
	return Vector2(0.15, w) if left_hand else Vector2(-w, -0.15)


## Transform for a prop on the inbound kerb of an arm at distance s, facing traffic.
func _kerb_prop(arm: Dictionary, s: float, out := 0.6) -> Transform3D:
	var f: Array = _arm_frame(arm, s)
	var p: Vector2 = f[0]
	var t: Vector2 = f[1]
	var n := Vector2(-t.y, t.x)
	var side := 1.0 if left_hand else -1.0  # inbound drivers' near side
	var q: Vector2 = p + n * side * (arm.hw + out)
	var y := _ribbon_h(p, n, arm.hw, _lift(arm.rank))
	y = y + KERB if arm.pave else height_at.call(q)
	var z := Vector3(t.x, 0.0, t.y)
	return Transform3D(Basis(Vector3.UP.cross(z), Vector3.UP, z), Vector3(q.x, y, q.y))


# --- Edges ------------------------------------------------------------------------------

## Tangent (forward along the edge) at a node end with no cut: mitred with the road it
## continues into, so the two ribbons share their end vertices.
func _node_tangent(e: Dictionary, side: int, eid: int) -> Vector2:
	var node: int = e.a if side == 0 else e.b
	var fwd := _end_dir(e, side) if side == 0 else -_end_dir(e, side)
	if _junction[node] or _node_ends[node].size() != 2:
		return fwd
	var o := _other_end(node, eid * 2 + side)
	if o >> 1 == eid:
		return fwd
	var out := _end_dir(_edges[o >> 1], o & 1)
	var t := (fwd - out) if side == 0 else (fwd + out)
	return t.normalized() if t.length() > 0.01 else fwd


func _style(e: Dictionary) -> int:
	var style := 0
	var rank: int = e.rank
	if not e.oneway and e.mark >= 1:
		if north_america:
			style = 2 if rank >= 5 else 0
		else:
			style = 1
	var base_hw: float = e.lanes_hw
	if e.oneway:
		var lanes := clampi(roundi(base_hw * 2.0 / 3.6), 1, 4)
		style |= (lanes - 1) << 2
		style |= 32
	elif base_hw >= 6.0:
		style |= 1 << 2
	if e.mark >= 2 and not e.pave:
		style |= 16  # edge lines on open roads; in town the kerb is the edge
	return style


func _emit_edge(e: Dictionary) -> void:
	var c0: float = e.c0
	var c1: float = e.c1
	var length: float = e.len
	if c0 + c1 >= length - 0.05:
		return
	var eid: int = e.id
	var pts: PackedVector2Array = e.pts
	var dist: PackedFloat32Array = e.dist
	var ss := PackedFloat32Array([c0])
	var tans: Array[Vector2] = []
	tans.append(_node_tangent(e, 0, eid) if c0 < 0.01 else (_frame(e, 0, c0)[1] as Vector2))
	for k in range(1, pts.size()):
		var steps := maxi(1, ceili((dist[k] - dist[k - 1]) / 3.0))
		var fwd := (pts[k] - pts[k - 1]).normalized()
		for st in range(1, steps + 1):
			var d := lerpf(dist[k - 1], dist[k], float(st) / steps)
			if d <= c0 + 0.05 or d >= length - c1 - 0.05:
				continue
			ss.append(d)
			if st == steps and k < pts.size() - 1:
				tans.append((fwd + (pts[k + 1] - pts[k]).normalized()).normalized())
			else:
				tans.append(fwd)
	ss.append(length - c1)
	tans.append(_node_tangent(e, 1, eid) if c1 < 0.01 else -(_frame(e, 1, c1)[1] as Vector2))
	var hw: float = e.hw
	var lift := _lift(e.rank)
	var visible := length - c0 - c1
	var periods := roundf(visible / DASH)
	var style := _style(e)
	if periods < 1.0:
		style &= ~3  # too short for a centre dash
		periods = 1.0
	var scale := periods * DASH / visible
	var uv2 := Vector2(hw, style)
	var color: Color = e.color
	var base := verts.size()
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var hs := PackedFloat32Array()
	for k in ss.size():
		var p := _point_at(pts, dist, ss[k])
		var n := Vector2(-tans[k].y, tans[k].x)
		var h := _ribbon_h(p, n, hw, lift)
		var v := (ss[k] - c0) * scale
		_vert(Vector3(p.x + n.x * hw, h, p.y + n.y * hw), Vector2(0, v), uv2, color)
		_vert(Vector3(p.x - n.x * hw, h, p.y - n.y * hw), Vector2(1, v), uv2, color)
		left.append(p + n * hw)
		right.append(p - n * hw)
		hs.append(h)
		if k > 0:
			var a := base + (k - 1) * 2
			indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	if e.pave:
		paved.append({pts = pts, hw = hw})
		var nl := PackedVector2Array()
		var nr := PackedVector2Array()
		for k in ss.size():
			nl.append((left[k] - right[k]).normalized())
			nr.append((right[k] - left[k]).normalized())
		_kerb(left, hs, nl, eid)
		_kerb(right, hs, nr, eid)


static func _point_at(pts: PackedVector2Array, dist: PackedFloat32Array, d: float) -> Vector2:
	var k := clampi(dist.bsearch(d), 1, pts.size() - 1)
	var t := clampf((d - dist[k - 1]) / maxf(dist[k] - dist[k - 1], 1e-6), 0.0, 1.0)
	return pts[k - 1].lerp(pts[k], t)


## Kerb and pavement along a road edge line: `pts` on the carriageway edge at road
## heights `hs`, `out` pointing away from the road. Skipped where the pavement would
## lie on another road.
func _kerb(pts: PackedVector2Array, hs: PackedFloat32Array, out: PackedVector2Array, skip: int) -> void:
	# Clearance is checked every third point (it is the slow part); points between
	# need both checked neighbours clear.
	if pts.size() > 4:
		# Every other ribbon point is plenty for a kerb.
		var sp := PackedVector2Array()
		var sh := PackedFloat32Array()
		var so := PackedVector2Array()
		for k in pts.size():
			if k % 2 == 0 or k == pts.size() - 1:
				sp.append(pts[k])
				sh.append(hs[k])
				so.append(out[k])
		pts = sp
		hs = sh
		out = so
	var n := pts.size()
	var clear: Array[bool] = []
	clear.resize(n)
	for k in n:
		if k % 3 == 0 or k == n - 1:
			clear[k] = not _on_other_road(pts[k] + out[k] * (PAVEMENT * 0.75), skip)
	for k in n:
		if k % 3 != 0 and k != n - 1:
			clear[k] = clear[k - k % 3] and clear[mini(k - k % 3 + 3, n - 1)]
	var run_start := -1
	for k in n + 1:
		var ok := k < n and clear[k]
		if ok and run_start < 0:
			run_start = k
		elif not ok and run_start >= 0:
			if k - run_start >= 2:
				_kerb_run(pts, hs, out, run_start, k)
			run_start = -1


func _kerb_run(pts: PackedVector2Array, hs: PackedFloat32Array, out: PackedVector2Array, i0: int, i1: int) -> void:
	# Five vertices per point: kerb foot and top, pavement inner and outer edge, and the
	# outer edge's skirt down into the ground. Written directly (this is hot).
	var base := verts.size()
	var flat := Vector2.ZERO
	for k in range(i0, i1):
		var p := pts[k]
		var q := p + out[k] * PAVEMENT
		var h := hs[k]
		var ground: float = height_at.call(q)
		verts.append_array([Vector3(p.x, h - 0.05, p.y), Vector3(p.x, h + KERB, p.y), Vector3(p.x, h + KERB, p.y),
			Vector3(q.x, h + KERB, q.y), Vector3(q.x, minf(ground, h) - 0.3, q.y)])
		colors.append_array([KERB_COLOR, KERB_COLOR, PAVING, PAVING, VERGE])
	var count := i1 - i0
	uvs.resize(verts.size())
	uv2s.resize(verts.size())
	for v in range(base, verts.size()):
		uvs[v] = flat
		uv2s[v] = flat
	# The strip's handedness is the same all along, so wind every quad like the first.
	var o3 := Vector3(out[i0].x, 0.0, out[i0].y)
	var faces := [[0, 5, 6, 1, -o3], [2, 3, 8, 7, Vector3.UP], [3, 8, 9, 4, o3]]
	var quads := PackedInt32Array()
	for f: Array in faces:
		var a := verts[base + f[0]]
		var flip := (verts[base + f[1]] - a).cross(verts[base + f[2]] - a).dot(f[4]) > 0.0
		if flip:
			quads.append_array([f[0], f[2], f[1], f[0], f[3], f[2]])
		else:
			quads.append_array([f[0], f[1], f[2], f[0], f[2], f[3]])
	for k in count - 1:
		var off := base + k * 5
		for q in quads:
			indices.append(off + q)


# --- Junction surfaces ------------------------------------------------------------------

func _mouth(arm: Dictionary) -> Dictionary:
	var p: Vector2 = arm.mouth[0]
	var t: Vector2 = arm.mouth[1]
	var n := Vector2(-t.y, t.x)
	var hw: float = arm.hw
	return {p = p, t = t, l = p + n * hw, r = p - n * hw, h = _ribbon_h(p, n, hw, _lift(arm.rank))}


## Quadratic curve from a to b whose tangents run back along ta / tb (outward arm
## directions); empty if the two edges don't meet in front of the corner.
static func _fillet(a: Vector2, ta: Vector2, b: Vector2, tb: Vector2, steps: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var den := (-ta).cross(-tb)
	if absf(den) < 0.05:
		return out
	var s := (b - a).cross(-tb) / den
	var u := (b - a).cross(-ta) / den
	if s <= 0.05 or u <= 0.05 or s > 60.0 or u > 60.0:
		return out
	var q := a - ta * s
	for k in range(1, steps):
		var f := float(k) / steps
		out.append(a.lerp(q, f).lerp(q.lerp(b, f), f))
	return out


func _emit_cluster(c: Dictionary) -> void:
	var arms: Array[Dictionary] = c.arms
	var n := arms.size()
	var mouths: Array[Dictionary] = []
	var top_rank := 0
	var color := Color()
	for arm in arms:
		mouths.append(_mouth(arm))
		if arm.rank > top_rank:
			top_rank = arm.rank
			color = arm.color
	var lift := _lift(top_rank)
	var poly := PackedVector2Array()
	var hs := PackedFloat32Array()
	for i in n:
		var j := (i + 1) % n
		var ma := mouths[i]
		var mb := mouths[j]
		poly.append_array([ma.r, ma.l])
		hs.append_array([ma.h, ma.h])
		var curve := _fillet(ma.l, ma.t, mb.r, mb.t, 6)
		var kerb_pts := PackedVector2Array([ma.l])
		var kerb_h := PackedFloat32Array([ma.h])
		for p in curve:
			var h: float = height_at.call(p) + lift
			poly.append(p)
			hs.append(h)
			kerb_pts.append(p)
			kerb_h.append(h)
		kerb_pts.append(mb.r)
		kerb_h.append(mb.h)
		if arms[i].pave and arms[j].pave and (n > 2 or not curve.is_empty()):
			_fillet_kerb(kerb_pts, kerb_h)
	_fill(poly, hs, color, c.centre)
	stats.junctions += 1
	_emit_controls(c, arms)


func _fillet_kerb(pts: PackedVector2Array, hs: PackedFloat32Array) -> void:
	if pts.size() < 2 or pts[0].distance_to(pts[pts.size() - 1]) < 0.5:
		return
	var out := PackedVector2Array()
	for k in pts.size():
		var tan := pts[mini(k + 1, pts.size() - 1)] - pts[maxi(k - 1, 0)]
		out.append(Vector2(tan.y, -tan.x).normalized())
	_kerb(pts, hs, out, -1)


# --- Junction control -------------------------------------------------------------------

func _control(c: Dictionary, arms: Array[Dictionary]) -> int:
	var live := 0
	var big := 0
	var road := 0
	var max_rank := 0
	var min_rank := 99
	var radius := 0.0
	for arm in arms:
		if arm.phantom:
			continue
		live += 1
		max_rank = maxi(max_rank, arm.rank)
		if arm.rank >= 4:
			min_rank = mini(min_rank, arm.rank)
			road += 1
		if arm.rank >= 6:
			big += 1
		radius = maxf(radius, (arm.mouth[0] as Vector2).distance_to(c.centre))
	if live < 3:
		return Ctl.NONE
	if have_points:
		if not _points_near(c.centre, radius + 8.0, Pt.MINI).is_empty():
			return Ctl.MINI
		if not _points_near(c.centre, radius + 15.0, Pt.SIGNALS).is_empty():
			return Ctl.SIGNALS
	elif big >= 2 and road >= 3:
		return Ctl.SIGNALS  # no data: busy junctions of main roads get lights
	if north_america and road == 4 and live == 4 and max_rank <= 5 and min_rank == max_rank:
		return Ctl.ALL_STOP
	return Ctl.PRIORITY


## The two arms that carry the main road through the junction.
func _major_pair(arms: Array[Dictionary]) -> Vector2i:
	var best := -INF
	var pair := Vector2i(-1, -1)
	for i in arms.size():
		for j in range(i + 1, arms.size()):
			var straight := -(arms[i].dir as Vector2).dot(arms[j].dir)
			var score: float = (arms[i].rank + arms[j].rank) * 10.0 + straight * 6.0
			if score > best:
				best = score
				pair = Vector2i(i, j)
	return pair


func _emit_controls(c: Dictionary, arms: Array[Dictionary]) -> void:
	var ctl := _control(c, arms)
	if ctl == Ctl.NONE:
		return
	var major := _major_pair(arms)
	var major_rank := 0
	if major.x >= 0:
		major_rank = maxi(arms[major.x].rank, arms[major.y].rank)
	if ctl == Ctl.SIGNALS:
		stats.signals += 1
		signal_spots.append(c.centre)
	elif ctl == Ctl.PRIORITY and not north_america and major.x >= 0:
		_centre_through(arms[major.x], arms[major.y])
	if ctl == Ctl.MINI:
		stats.mini += 1
		_disc(c.centre, 1.6, height_at.call(c.centre) + _lift(major_rank), PAINT, true)
	for i in arms.size():
		var arm := arms[i]
		var app := _approach(arm)
		if arm.phantom or app == Vector2.ZERO:
			continue
		var cut: float = arm.cut
		var room: float = (arm.len * 0.5 if arm.far_junction else arm.len) - cut
		var stop_pt := _arm_point_near(arm, Pt.STOP)
		match ctl:
			Ctl.SIGNALS:
				var line_s := cut + 1.0
				if room > 7.0:
					_crossing(arm, cut + 0.5)
					line_s = cut + 4.6
				_across(arm, line_s, app.x, app.y, 0.3)
				instances.append([RegionStyle.traffic_light_role(region), _kerb_prop(arm, line_s)])
			Ctl.ALL_STOP:
				_stop(arm, app, room)
			Ctl.MINI:
				_across(arm, cut + 0.4, app.x, app.y, 0.2, 0.6, 0.3)
				stats.give_way += 1
			Ctl.PRIORITY:
				if i == major.x or i == major.y or room < 1.5:
					continue
				if stop_pt or north_america:
					if arm.rank >= 4 or major_rank >= 5:
						_stop(arm, app, room)
					continue
				if arm.rank <= 3 and major_rank <= 4:
					continue  # driveways and yards onto side streets
				_across(arm, cut + 0.4, app.x, app.y, 0.2, 0.6, 0.3)
				_across(arm, cut + 1.0, app.x, app.y, 0.2, 0.6, 0.3)
				if uk and room > 18.0 and arm.rank >= 4:
					_triangle(arm, cut + 12.0, (app.x + app.y) * 0.5)
				var sign_here: bool = arm.rank >= 4 and (not uk or major_rank >= 6 or _arm_point_near(arm, Pt.GIVE_WAY))
				if sign_here:
					instances.append(["sign_give_way", _kerb_prop(arm, cut + 1.2)])
				stats.give_way += 1


## Carries the main road's centre line across the mouths of the side roads (UK and
## most of Europe; American centre lines stop at the junction).
func _centre_through(a: Dictionary, b: Dictionary) -> void:
	if a.oneway != 0 or b.oneway != 0 or a.phantom or b.phantom or a.rank < 4 or b.rank < 4:
		return
	var ma := _mouth(a)
	var mb := _mouth(b)
	var pa: Vector2 = ma.p
	var pb: Vector2 = mb.p
	if pa.distance_to(pb) < 4.0 or (ma.t as Vector2).dot(mb.t) > -0.5:
		return  # not a through road
	var curve := _fillet(pa, ma.t, pb, mb.t, 12)
	var pts := PackedVector2Array([pa])
	if curve.is_empty():
		for k in range(1, 12):
			pts.append(pa.lerp(pb, k / 12.0))
	else:
		pts.append_array(curve)
	pts.append(pb)
	# Dashes 4 m on, 2 m off, centred on the gap like the ribbons' dashes.
	var dist := PackedFloat32Array([0.0])
	for k in range(1, pts.size()):
		dist.append(dist[k - 1] + pts[k].distance_to(pts[k - 1]))
	var total := dist[dist.size() - 1]
	var n := maxf(roundf(total / 6.0), 1.0)
	var period := total / n
	var h := maxf(ma.h, mb.h)
	for i in int(n):
		var s0 := i * period + period * 0.17
		var s1 := s0 + period * 0.66
		var p0 := _point_at(pts, dist, s0)
		var p1 := _point_at(pts, dist, s1)
		var d := (p1 - p0).normalized()
		var w := Vector2(-d.y, d.x) * 0.07
		_paint([p0 - w, p1 - w, p1 + w, p0 + w], h)


func _stop(arm: Dictionary, app: Vector2, room: float) -> void:
	if room < 1.5:
		return
	_across(arm, arm.cut + 1.0, app.x, app.y, 0.45)
	if arm.rank >= 4:
		instances.append(["sign_stop", _kerb_prop(arm, arm.cut + 1.4)])
	stats.stops += 1


## True if an Overpass point of `kind` lies on the arm close to the junction.
func _arm_point_near(arm: Dictionary, kind: int) -> bool:
	if not have_points:
		return false
	var f: Array = _arm_frame(arm, arm.cut + 8.0)
	return not _points_near(f[0], arm.hw + 10.0, kind).is_empty()


## Pedestrian crossing across the whole arm starting at distance s.
func _crossing(arm: Dictionary, s: float) -> void:
	var w: float = arm.hw - 0.2
	if uk:
		# Two lines of studs either side of the crossing.
		_across(arm, s, -w, w, 0.12, 0.25, 0.35)
		_across(arm, s + 3.0, -w, w, 0.12, 0.25, 0.35)
		return
	var f: Array = _arm_frame(arm, s + 1.6)
	var p: Vector2 = f[0]
	var t: Vector2 = f[1]
	var n := Vector2(-t.y, t.x)
	var h := _ribbon_h(p, n, arm.hw, _lift(arm.rank))
	var x := -w + 0.3
	while x < w - 0.3:
		var a := p + n * x
		var b := p + n * minf(x + 0.5, w)
		_paint([a - t * 1.5, b - t * 1.5, b + t * 1.5, a + t * 1.5], h)
		x += 1.1


## UK give-way triangle on the approach lane, pointing at the junction.
func _triangle(arm: Dictionary, s: float, x: float) -> void:
	var f: Array = _arm_frame(arm, s)
	var p: Vector2 = f[0]
	var t: Vector2 = f[1]
	var n := Vector2(-t.y, t.x)
	var h := _ribbon_h(p, n, arm.hw, _lift(arm.rank))
	# Base towards the junction, point towards approaching drivers.
	var c := p + n * x
	var apex := c + t * 2.0
	var base_c := c - t * 2.0
	_paint([apex, apex, base_c + n * 0.6, base_c - n * 0.6], h)


## Flat disc; raised gives it a low dome like a mini-roundabout.
func _disc(centre: Vector2, radius: float, h: float, color: Color, paint := false) -> void:
	var seg := 20
	var uv2 := Vector2(0.0, STYLE_PAINT if paint else 0)
	var mid := _vert(Vector3(centre.x, h + (0.06 if paint else 0.0), centre.y), Vector2.ZERO, uv2, color)
	var base := verts.size()
	for k in seg:
		var p := centre + Vector2.from_angle(k * TAU / seg) * radius
		_vert(Vector3(p.x, h + (0.02 if paint else 0.0), p.y), Vector2.ZERO, uv2, color)
	for k in seg:
		_tri(mid, base + k, base + (k + 1) % seg)


# --- Roundabouts ------------------------------------------------------------------------

func _emit_ring(r: Dictionary) -> void:
	var centre: Vector2 = r.centre
	var radius: float = r.r
	var outer: float = radius + r.hw
	var inner: float = radius - r.hw
	var lift := _lift(r.rank)
	var color: Color = r.color
	var seg := clampi(int(radius * 1.2), 20, 64)
	stats.roundabouts += 1
	# Circulating carriageway.
	var base := verts.size()
	var ring_h := PackedFloat32Array()
	for k in seg:
		var d := Vector2.from_angle(k * TAU / seg)
		var po := centre + d * outer
		var pi_ := centre + d * maxf(inner, 0.5)
		var h := maxf(height_at.call(po), height_at.call(pi_)) + lift
		ring_h.append(h)
		_vert(Vector3(pi_.x, h, pi_.y), Vector2(0.5, 0.0), Vector2.ZERO, color)
		_vert(Vector3(po.x, h, po.y), Vector2(0.5, 0.0), Vector2.ZERO, color)
	for k in seg:
		var a := base + k * 2
		var b := base + ((k + 1) % seg) * 2
		_quad(a, a + 1, b + 1, b)
	# Wide rings get a dashed line between their two lanes.
	if r.hw * 2.0 >= 8.0:
		var dashes := maxi(roundi(TAU * radius / 6.0), 8)
		for k in dashes:
			var a0 := (k + 0.2) * TAU / dashes
			var a1 := (k + 0.7) * TAU / dashes
			var d0 := Vector2.from_angle(a0)
			var d1 := Vector2.from_angle(a1)
			var h := ring_h[int(a0 / TAU * seg) % seg]
			_paint([centre + d0 * (radius - 0.07), centre + d1 * (radius - 0.07),
				centre + d1 * (radius + 0.07), centre + d0 * (radius + 0.07)], h)
	# Entries and exits flare into the ring.
	for arm: Dictionary in r.arms:
		_ring_mouth(r, arm)
	# Central island: kerbed and grassed, or just painted when tiny.
	var hc: float = height_at.call(centre) + lift
	if inner < 2.5:
		_disc(centre, maxf(inner, 1.2), hc, PAINT, true)
		stats.mini += 1
		return
	var top := hc + 0.15
	var apron := inner - 1.2 if inner > 5.0 else inner
	base = verts.size()
	for k in seg:
		var d := Vector2.from_angle(k * TAU / seg)
		var p := centre + d * inner
		var q := centre + d * apron
		_vert(Vector3(p.x, ring_h[k] - 0.05, p.y), Vector2.ZERO, Vector2.ZERO, KERB_COLOR)
		_vert(Vector3(p.x, top, p.y), Vector2.ZERO, Vector2.ZERO, KERB_COLOR)
		_vert(Vector3(p.x, top, p.y), Vector2.ZERO, Vector2.ZERO, PAVING)
		_vert(Vector3(q.x, top, q.y), Vector2.ZERO, Vector2.ZERO, PAVING)
	for k in seg:
		var a := base + k * 4
		var b := base + ((k + 1) % seg) * 4
		var d := Vector2.from_angle((k + 0.5) * TAU / seg)
		_quad(a, b, b + 1, a + 1, Vector3(d.x, 0.0, d.y))
		if apron < inner:
			_quad(a + 2, b + 2, b + 3, a + 3)
	_disc(centre, apron, top + 0.08, GRASS)
	if inner > 6.0:
		var xf := Transform3D(Basis.IDENTITY, Vector3(centre.x, top, centre.y))
		instances.append(["bush", xf])


func _ring_mouth(r: Dictionary, arm: Dictionary) -> void:
	var centre: Vector2 = r.centre
	var outer: float = r.r + r.hw
	var m := _mouth(arm)
	var lift := _lift(maxi(r.rank, arm.rank))
	var poly := PackedVector2Array([m.r, m.l])
	var hs := PackedFloat32Array([m.h, m.h])
	var flare := clampf(arm.hw * 0.8 + 1.5, 2.5, 6.0)
	var ends: Array[Vector2] = []
	for side: float in [1.0, -1.0]:
		var corner: Vector2 = m.l if side > 0.0 else m.r
		# Where this kerb line would meet the ring, then swing along the ring.
		var hit := _line_circle(corner, -(m.t as Vector2), centre, outer)
		var ang := (hit - centre).angle()
		var n: Vector2 = Vector2(-m.t.y, m.t.x) * side
		var da := flare / outer
		var p1 := centre + Vector2.from_angle(ang + da) * outer
		var p2 := centre + Vector2.from_angle(ang - da) * outer
		var target := p1 if (p1 - hit).dot(n) > (p2 - hit).dot(n) else p2
		ends.append(target)
		var curve := PackedVector2Array()
		for k in range(1, 5):
			var f := k / 4.0
			curve.append(corner.lerp(hit, f).lerp(hit.lerp(target, f), f))
		if side < 0.0:
			curve.reverse()
		if side > 0.0:
			for p in curve:
				poly.append(p)
				hs.append(height_at.call(p) + lift)
		else:
			# Close the polygon along the ring, inside its outer edge.
			var a0 := (ends[0] - centre).angle()
			var a1 := (ends[1] - centre).angle()
			var span := wrapf(a1 - a0, -PI, PI)
			for k in range(1, 6):
				var p := centre + Vector2.from_angle(a0 + span * k / 6.0) * (outer - 0.6)
				poly.append(p)
				hs.append(height_at.call(p) + lift)
			for p in curve:
				poly.append(p)
				hs.append(height_at.call(p) + lift)
	_fill(poly, hs, arm.color, (m.p as Vector2).lerp(centre, 0.3))
	var app := _approach(arm)
	if app != Vector2.ZERO and not arm.phantom:
		_across(arm, maxf(arm.s_exit + 0.3, 0.5), app.x, app.y, 0.25, 0.6, 0.3)
		stats.give_way += 1
		if arm.rank >= 4 and arm.cut + 2.0 < arm.len:
			instances.append(["sign_give_way" if not north_america else "sign_stop",
				_kerb_prop(arm, arm.s_exit + 1.5)])


## First point where the ray from p along d reaches the circle (or p if it never does).
static func _line_circle(p: Vector2, d: Vector2, c: Vector2, radius: float) -> Vector2:
	var f := p - c
	var b := f.dot(d)
	var disc := b * b - (f.length_squared() - radius * radius)
	if disc < 0.0:
		return p
	var t := -b - sqrt(disc)
	if t < 0.0:
		t = -b + sqrt(disc)
	return p + d * maxf(t, 0.0)
