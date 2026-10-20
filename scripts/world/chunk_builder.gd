class_name ChunkBuilder
extends RefCounted
## Turns one z14 tile's vector data + elevation into plain mesh/collision arrays.
## Touches no scene nodes, so it can run on a worker thread or be stepped on the
## main thread (see step()). Chunk-local space: x east, z south, origin at the tile's
## north-west corner, in true metres.

enum Lod { FULL, HORIZON }

const LAYERS := ["transportation", "building", "water", "waterway", "landcover", "landuse", "park"]
const MASK_RES := 512  # Fine exclusion mask (roads, buildings, water) for scatter.
const BLOCKS := 4  # Scatter is split into BLOCKS x BLOCKS sub-chunks for culling.

enum Cls { GRASS, FARM, FOREST, PARK, SAND, URBAN, WATER, WETLAND, ROCK, ICE }
const CLASS_COLORS := [
	Color(0.55, 0.63, 0.42), Color(0.76, 0.72, 0.50), Color(0.38, 0.51, 0.33),
	Color(0.52, 0.65, 0.41), Color(0.88, 0.82, 0.64), Color(0.66, 0.66, 0.62),
	Color(0.40, 0.44, 0.37), Color(0.45, 0.56, 0.45), Color(0.60, 0.57, 0.53),
	Color(0.93, 0.95, 0.98),
]
const LANDCOVER := {
	"farmland": Cls.FARM, "wood": Cls.FOREST, "forest": Cls.FOREST, "grass": Cls.PARK,
	"sand": Cls.SAND, "beach": Cls.SAND, "wetland": Cls.WETLAND, "rock": Cls.ROCK,
	"ice": Cls.ICE, "glacier": Cls.ICE,
}
const URBAN_LANDUSE := [
	"residential", "commercial", "industrial", "retail", "school", "university",
	"college", "hospital", "railway", "military", "quarry", "garages", "kindergarten",
	"library", "theme_park", "zoo",
]
const PARK_LANDUSE := ["pitch", "playground", "cemetery", "stadium", "track", "golf_course", "park"]

## class -> [half width m, rank, base colour, marking]
## marking: 0 none, 1 dashed centre line, 2 centre + edge lines
const ROADS := {
	"motorway": [6.5, 9, Color(0.40, 0.40, 0.42), 2],
	"trunk": [5.5, 8, Color(0.41, 0.41, 0.43), 2],
	"primary": [5.0, 7, Color(0.43, 0.43, 0.44), 2],
	"secondary": [4.5, 6, Color(0.44, 0.44, 0.45), 1],
	"tertiary": [4.0, 5, Color(0.45, 0.45, 0.46), 1],
	"minor": [3.2, 4, Color(0.47, 0.47, 0.48), 1],
	"busway": [3.2, 4, Color(0.47, 0.47, 0.48), 1],
	"raceway": [6.0, 4, Color(0.40, 0.40, 0.42), 2],
	"service": [2.2, 3, Color(0.50, 0.50, 0.50), 0],
	"track": [1.8, 2, Color(0.62, 0.53, 0.40), 0],
	"path": [0.9, 1, Color(0.74, 0.67, 0.54), 0],
}
const DRIVABLE_RANK := 2  # Spawn/flatten only on roads at least this rank.

# Inputs
var tile: Vector2i
var lod: Lod
var size: float  # tile edge in true metres
var latitude: float
var _mvt_bytes: PackedByteArray
var _elev: ElevationSource
var _merc0: PackedFloat64Array  # tile NW corner, mercator
var _scale: float
var _seed: int

# Working state
var _step := 0
var _layers := {}
var _n := 0  # vertices per side
var _cell := 0.0  # vertex spacing
var _class := PackedByteArray()  # per vertex
var _mask := PackedByteArray()  # MASK_RES^2, non-zero = no scatter
var _h := PackedFloat32Array()  # final terrain heights per vertex
var _water_level := PackedFloat32Array()  # per vertex, NAN if not water
var _shore := PackedByteArray()  # 1 = non-water vertex next to water (kept noise-free)
var _road_lines: Array[Dictionary] = []  # clipped to the tile: {pts, cls, bridge}
## Unclipped (including the tile buffer) so neighbouring chunks flatten their shared
## edge identically.
var _flatten_lines: Array[Dictionary] = []
var _noise := FastNoiseLite.new()

# Outputs (read by Chunk once done())
var terrain := {}  # {vertices, colors, indices}
var collision := {}  # {heights: PackedFloat32Array, width: int, cell: float}
var water := {}
var roads := {}
var road_spawn: Array[Dictionary] = []  # {pts: PackedVector3Array, rank: int}
var bridge_faces := PackedVector3Array()
var buildings := {}
var building_faces: Array[PackedVector3Array] = []  # per scatter block, for incremental upload
var scatter: Array[Dictionary] = []  # per block: {role: Array[Transform3D]}


func _init(p_tile: Vector2i, p_lod: Lod, mvt: PackedByteArray, elev: ElevationSource) -> void:
	tile = p_tile
	lod = p_lod
	_mvt_bytes = mvt
	_elev = elev
	_scale = Geo.scale
	_merc0 = Geo.tile_origin_merc(tile, Geo.CHUNK_ZOOM)
	size = Geo.tile_size_merc(Geo.CHUNK_ZOOM) * _scale
	var ll := Geo.merc_to_lonlat(_merc0[0], _merc0[1])
	latitude = ll[1]
	_n = 129 if lod == Lod.FULL else 33
	_cell = size / (_n - 1)
	_seed = hash(tile)
	_noise.seed = 1337
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 3
	_noise.frequency = 1.0 / 90.0


## Runs one pipeline stage. Returns true when everything is built.
func step() -> bool:
	var stages: Array[Callable]
	if lod == Lod.FULL:
		stages = [_decode, _classify, _sample_heights, _water, _flatten_roads,
			_build_terrain, _build_roads, _build_buildings, _build_scatter]
	else:
		stages = [_sample_heights, _build_terrain]
	if _step < stages.size():
		stages[_step].call()
		_step += 1
	return _step >= stages.size()


func run_all() -> void:
	while not step():
		pass


# --- Stage: decode -----------------------------------------------------------

func _decode() -> void:
	if not _mvt_bytes.is_empty():
		_layers = MVTDecoder.decode(_mvt_bytes, LAYERS)
	_mvt_bytes = PackedByteArray()


func _features(layer: String) -> Array:
	return _layers[layer].features if _layers.has(layer) else []


func _to_local(layer: String) -> float:
	return size / float(_layers[layer].extent)


## Tile units -> chunk metres.
static func _scale_ring(ring: PackedVector2Array, k: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(ring.size())
	for i in ring.size():
		out[i] = ring[i] * k
	return out


func _feature_rings(layer: String, f: Dictionary) -> Array[PackedVector2Array]:
	var k := _to_local(layer)
	var out: Array[PackedVector2Array] = []
	for r: PackedVector2Array in f.rings:
		out.append(_scale_ring(r, k))
	return out


# --- Stage: classify land cover ------------------------------------------------

func _classify() -> void:
	_class.resize(_n * _n)
	_class.fill(Cls.GRASS)
	_mask.resize(MASK_RES * MASK_RES)
	_mask.fill(0)
	# Paint in increasing priority. Rings are shifted by half a cell so Raster's
	# cell-centre sampling lands on vertices.
	var shift := Vector2(_cell, _cell) * 0.5
	var paint := func(layer: String, f: Dictionary, cls: int) -> void:
		var rings := _feature_rings(layer, f)
		for i in rings.size():
			rings[i] = _translate(rings[i], shift)
		Raster.fill_rings(_class, _n, _n, _cell, rings, cls)
	for f: Dictionary in _features("landuse"):
		var c: String = str(f.tags.get("class", ""))
		if c in URBAN_LANDUSE:
			paint.call("landuse", f, Cls.URBAN)
		elif c in PARK_LANDUSE:
			paint.call("landuse", f, Cls.PARK)
	for f: Dictionary in _features("park"):
		paint.call("park", f, Cls.PARK)
	for order in [Cls.FARM, Cls.PARK, Cls.FOREST, Cls.SAND, Cls.ROCK, Cls.ICE, Cls.WETLAND]:
		for f: Dictionary in _features("landcover"):
			var key := str(f.tags.get("subclass", f.tags.get("class", "")))
			var cls: int = LANDCOVER.get(key, LANDCOVER.get(str(f.tags.get("class", "")), -1))
			if cls == order:
				paint.call("landcover", f, cls)
	var mask_cell := size / MASK_RES
	for f: Dictionary in _features("water"):
		if f.tags.get("brunnel", "") == "tunnel" or f.type != MVTDecoder.GEOM_POLYGON:
			continue
		paint.call("water", f, Cls.WATER)
		Raster.fill_rings(_mask, MASK_RES, MASK_RES, mask_cell, _feature_rings("water", f), 1)
	# Waterways (rivers/streams as lines) become narrow water strips.
	for f: Dictionary in _features("waterway"):
		var c := str(f.tags.get("class", ""))
		if f.tags.get("brunnel", "") == "tunnel" or not (c in ["river", "canal"]):
			continue
		for r in _feature_rings("waterway", f):
			Raster.stroke_polyline(_class, _n, _n, _cell, _translate(r, shift), _cell * 0.75, Cls.WATER)
			Raster.stroke_polyline(_mask, MASK_RES, MASK_RES, mask_cell, r, _cell * 0.5, 1)
	# Building features are multipolygons spanning the tile; fill ring by ring so each
	# scanline only visits one footprint's edges (holes don't matter for the mask).
	for f: Dictionary in _features("building"):
		for r in _feature_rings("building", f):
			Raster.fill_polygon(_mask, MASK_RES, MASK_RES, mask_cell, r, 2)
	# Roads: clip to the tile so neighbouring chunks don't draw the same piece twice.
	var rect := PackedVector2Array([Vector2.ZERO, Vector2(size, 0), Vector2(size, size), Vector2(0, size)])
	for f: Dictionary in _features("transportation"):
		var c := str(f.tags.get("class", ""))
		if not ROADS.has(c) or f.type != MVTDecoder.GEOM_LINE:
			continue
		var brunnel := str(f.tags.get("brunnel", ""))
		if brunnel == "tunnel":
			continue
		for r in _feature_rings("transportation", f):
			if brunnel != "bridge" and ROADS[c][1] >= DRIVABLE_RANK:
				_flatten_lines.append({pts = r, cls = c})
			for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(r, rect):
				if piece.size() >= 2:
					_road_lines.append({pts = piece, cls = c, bridge = brunnel == "bridge"})
					Raster.stroke_polyline(_mask, MASK_RES, MASK_RES, mask_cell, piece,
						ROADS[c][0] + 1.5, 3)
	_mark_dense_urban()


## OSM often has no landuse polygons in city centres; treat ground that is mostly
## covered by buildings and roads as urban paving.
func _mark_dense_urban() -> void:
	var built := PackedFloat32Array()
	built.resize(_n * _n)
	var scale := float(_n - 1) / MASK_RES
	for mj in MASK_RES:
		for mi in MASK_RES:
			var m := _mask[mj * MASK_RES + mi]
			if m >= 2:
				built[roundi((mj + 0.5) * scale) * _n + roundi((mi + 0.5) * scale)] += 1.0
	var per_cell := 1.0 / (scale * scale)  # mask cells per vertex cell
	for j in _n:
		for i in _n:
			var v := j * _n + i
			if _class[v] != Cls.GRASS and _class[v] != Cls.PARK:
				continue
			var sum := 0.0
			for dj in range(-2, 3):
				for di in range(-2, 3):
					var ii := clampi(i + di, 0, _n - 1)
					var jj := clampi(j + dj, 0, _n - 1)
					sum += built[jj * _n + ii]
			if _class[v] == Cls.GRASS and sum / (25.0 * per_cell) > 0.3:
				_class[v] = Cls.URBAN


static func _translate(ring: PackedVector2Array, d: Vector2) -> PackedVector2Array:
	var out := ring.duplicate()
	for i in out.size():
		out[i] += d
	return out


# --- Stage: heights -------------------------------------------------------------

func _sample_heights() -> void:
	_h.resize(_n * _n)
	var merc_cell := _cell / _scale
	for j in _n:
		var my := _merc0[1] - j * merc_cell
		for i in _n:
			var mx := _merc0[0] + i * merc_cell
			_h[j * _n + i] = _elev.sample(mx, my)
	if lod == Lod.HORIZON:
		for i in _h.size():
			_h[i] = maxf(_h[i], -2.0)


## Procedural detail (±~2 m) in absolute mercator space so chunks agree at seams.
func _detail(i: int, j: int) -> float:
	var mx := fposmod(_merc0[0] + i * _cell / _scale, 100000.0)
	var my := fposmod(_merc0[1] - j * _cell / _scale, 100000.0)
	return _noise.get_noise_2d(mx, my) * 1.3


# --- Stage: water -----------------------------------------------------------------

func _water() -> void:
	_water_level.resize(_n * _n)
	_water_level.fill(NAN)
	for v in _n * _n:
		if _class[v] == Cls.WATER:
			_water_level[v] = maxf(_h[v], 0.0)
	# Smooth levels a little so lakes don't show DEM noise.
	var smoothed := _water_level.duplicate()
	for j in _n:
		for i in _n:
			var v := j * _n + i
			if is_nan(_water_level[v]):
				continue
			var sum := 0.0
			var cnt := 0
			for dj in range(-2, 3):
				for di in range(-2, 3):
					var ii := i + di
					var jj := j + dj
					if ii < 0 or jj < 0 or ii >= _n or jj >= _n:
						continue
					var w := _water_level[jj * _n + ii]
					if not is_nan(w):
						sum += w
						cnt += 1
			smoothed[v] = sum / cnt
	_water_level = smoothed
	for v in _n * _n:
		if not is_nan(_water_level[v]):
			_h[v] = minf(_h[v], _water_level[v] - 2.5)
	# Pull banks just under the water surface so narrow rivers show water instead of
	# a trench whose rims hide the (flat) surface.
	_shore.resize(_n * _n)
	_shore.fill(0)
	for j in _n:
		for i in _n:
			var v := j * _n + i
			if not is_nan(_water_level[v]):
				continue
			var level := INF
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var ii := i + di
					var jj := j + dj
					if ii >= 0 and jj >= 0 and ii < _n and jj < _n and not is_nan(_water_level[jj * _n + ii]):
						level = minf(level, _water_level[jj * _n + ii])
			if level < INF:
				_shore[v] = 1
				_h[v] = minf(_h[v], level - 0.6)


# --- Stage: road flattening ---------------------------------------------------------

func _flatten_roads() -> void:
	var weight := PackedFloat32Array()
	weight.resize(_n * _n)
	weight.fill(0.0)
	var target := PackedFloat32Array()
	target.resize(_n * _n)
	for road in _flatten_lines:
		var spec: Array = ROADS[road.cls]
		var pts := _resample(road.pts, 10.0)
		var hs := PackedFloat32Array()
		hs.resize(pts.size())
		for k in pts.size():
			hs[k] = _dem_at(pts[k])
		hs = _smooth(hs, 3)
		# Fully flatten out to a grid cell beyond the edge so every terrain triangle
		# under the road is flat; blend back to natural terrain over two more cells.
		var inner: float = spec[0] + _cell
		var outer: float = spec[0] + _cell * 3.0
		for k in pts.size() - 1:
			var a := pts[k]
			var b := pts[k + 1]
			var i0 := maxi(0, floori((minf(a.x, b.x) - outer) / _cell))
			var i1 := mini(_n - 1, ceili((maxf(a.x, b.x) + outer) / _cell))
			var j0 := maxi(0, floori((minf(a.y, b.y) - outer) / _cell))
			var j1 := mini(_n - 1, ceili((maxf(a.y, b.y) + outer) / _cell))
			var ab := b - a
			var len2 := maxf(ab.length_squared(), 1e-6)
			for j in range(j0, j1 + 1):
				for i in range(i0, i1 + 1):
					var p := Vector2(i * _cell, j * _cell)
					var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
					var d := p.distance_to(a + ab * t)
					if d >= outer:
						continue
					var w := 1.0 - smoothstep(inner, outer, d)
					var v := j * _n + i
					if w > weight[v]:
						weight[v] = w
						target[v] = lerpf(hs[k], hs[k + 1], t)
	# Apply flattening, then add procedural detail away from roads and water.
	for j in _n:
		for i in _n:
			var v := j * _n + i
			var w := weight[v]
			var h := lerpf(_h[v], target[v], w)
			if is_nan(_water_level[v]) and _shore[v] == 0:
				h += _detail(i, j) * (1.0 - w)
			_h[v] = h


static func _smooth(values: PackedFloat32Array, radius: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(values.size())
	for i in values.size():
		var sum := 0.0
		var cnt := 0
		for k in range(maxi(0, i - radius), mini(values.size(), i + radius + 1)):
			sum += values[k]
			cnt += 1
		out[i] = sum / cnt
	return out


static func _resample(pts: PackedVector2Array, max_seg: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in pts.size() - 1:
		var a := pts[k]
		var b := pts[k + 1]
		var steps := maxi(1, ceili(a.distance_to(b) / max_seg))
		for s in steps:
			out.append(a.lerp(b, float(s) / steps))
	out.append(pts[pts.size() - 1])
	return out


## Raw elevation at a chunk-local point; valid in the tile buffer too, so both
## chunks sharing an edge get the same answer.
func _dem_at(p: Vector2) -> float:
	return _elev.sample(_merc0[0] + p.x / _scale, _merc0[1] - p.y / _scale)


## Height on the actual terrain triangles (diagonal from (i,j) to (i+1,j+1)).
func height_at(p: Vector2) -> float:
	var fx := clampf(p.x / _cell, 0.0, _n - 1.001)
	var fz := clampf(p.y / _cell, 0.0, _n - 1.001)
	var i := floori(fx)
	var j := floori(fz)
	var u := fx - i
	var v := fz - j
	var h00 := _h[j * _n + i]
	var h11 := _h[(j + 1) * _n + i + 1]
	if u >= v:
		var h10 := _h[j * _n + i + 1]
		return h00 + u * (h10 - h00) + v * (h11 - h10)
	var h01 := _h[(j + 1) * _n + i]
	return h00 + v * (h01 - h00) + u * (h11 - h01)


# --- Stage: terrain mesh ---------------------------------------------------------------

func _build_terrain() -> void:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	verts.resize(_n * _n)
	colors.resize(_n * _n)
	var full := lod == Lod.FULL
	for j in _n:
		for i in _n:
			var v := j * _n + i
			var h := _h[v]
			verts[v] = Vector3(i * _cell, h, j * _cell)
			var cls: int = _class[v] if full else (Cls.WATER if h <= 0.0 else Cls.GRASS)
			colors[v] = _vertex_color(i, j, cls, h)
	for j in _n - 1:
		for i in _n - 1:
			var a := j * _n + i
			indices.append_array([a, a + 1, a + _n + 1, a, a + _n + 1, a + _n])
	if not full:
		_add_skirts(verts, colors, indices)
	terrain = {vertices = verts, colors = colors, indices = indices}
	if full:
		collision = {heights = _h, width = _n, cell = _cell}
		_build_water_mesh()


func _vertex_color(i: int, j: int, cls: int, h: float) -> Color:
	var c: Color = CLASS_COLORS[cls]
	if cls == Cls.GRASS or cls == Cls.FOREST or cls == Cls.FARM:
		# Steep slopes turn rocky, high ground turns to snow.
		var hx := _h[j * _n + mini(i + 1, _n - 1)] - _h[j * _n + maxi(i - 1, 0)]
		var hz := _h[mini(j + 1, _n - 1) * _n + i] - _h[maxi(j - 1, 0) * _n + i]
		var slope := Vector2(hx, hz).length() / (2.0 * _cell)
		c = c.lerp(CLASS_COLORS[Cls.ROCK], smoothstep(0.45, 0.9, slope))
		var snow_line := lerpf(4800.0, 1800.0, clampf((absf(latitude) - 20.0) / 40.0, 0.0, 1.0))
		c = c.lerp(CLASS_COLORS[Cls.ICE], smoothstep(snow_line, snow_line + 300.0, h))
	var vary := 0.93 + 0.14 * (hash(Vector2i(i, j) + tile * 1000) % 1000) / 1000.0
	return Color(c.r * vary, c.g * vary, c.b * vary)


func _add_skirts(verts: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array) -> void:
	var edges: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array(), PackedInt32Array(), PackedInt32Array()]
	for k in _n:
		edges[0].append(k)  # north, west->east
		edges[1].append(k * _n + _n - 1)  # east, north->south
		edges[2].append((_n - 1) * _n + (_n - 1 - k))  # south, east->west
		edges[3].append((_n - 1 - k) * _n)  # west, south->north
	for edge in edges:
		var base := verts.size()
		for v in edge:
			verts.append(verts[v] - Vector3(0, 30, 0))
			colors.append(colors[v])
		for k in edge.size() - 1:
			var a := edge[k]
			var b := edge[k + 1]
			indices.append_array([a, base + k + 1, b, a, base + k, base + k + 1])


func _build_water_mesh() -> void:
	var verts := PackedVector3Array()
	for j in _n - 1:
		for i in _n - 1:
			var corners := [j * _n + i, j * _n + i + 1, (j + 1) * _n + i + 1, (j + 1) * _n + i]
			var level := 0.0
			var cnt := 0
			for v: int in corners:
				if not is_nan(_water_level[v]):
					level += _water_level[v]
					cnt += 1
			if cnt == 0:
				continue
			level /= cnt
			var y := level - 0.3
			var p := [Vector3(i * _cell, y, j * _cell), Vector3((i + 1) * _cell, y, j * _cell),
				Vector3((i + 1) * _cell, y, (j + 1) * _cell), Vector3(i * _cell, y, (j + 1) * _cell)]
			verts.append_array([p[0], p[1], p[2], p[0], p[2], p[3]])
	water = {vertices = verts}


# --- Stage: roads --------------------------------------------------------------------

func _build_roads() -> void:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for road in _road_lines:
		var spec: Array = ROADS[road.cls]
		var hw: float = spec[0]
		var rank: int = spec[1]
		var color: Color = spec[2]
		color.a = spec[3] / 2.0
		var pts := _resample(road.pts, 3.0)
		if pts.size() < 2:
			continue
		# Extend free ends (not on the tile border) to cover gaps at junctions.
		var first_dir := (pts[1] - pts[0]).normalized()
		var last_dir := (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()
		if not _on_border(pts[0]):
			pts.insert(0, pts[0] - first_dir * hw * 0.8)
		if not _on_border(pts[pts.size() - 1]):
			pts.append(pts[pts.size() - 1] + last_dir * hw * 0.8)
		var lift := 0.12 + rank * 0.025
		var heights := PackedFloat32Array()
		heights.resize(pts.size())
		if road.bridge:
			var h0 := height_at(pts[0])
			var h1 := height_at(pts[pts.size() - 1])
			var total := 0.0
			var dist := PackedFloat32Array([0.0])
			for k in range(1, pts.size()):
				total += pts[k].distance_to(pts[k - 1])
				dist.append(total)
			for k in pts.size():
				heights[k] = lerpf(h0, h1, dist[k] / maxf(total, 0.01)) + lift
		else:
			# Sit on the highest of centre and both edges so terrain can't poke through.
			for k in pts.size():
				var d := (pts[mini(k + 1, pts.size() - 1)] - pts[maxi(k - 1, 0)]).normalized()
				var side := Vector2(-d.y, d.x) * hw
				heights[k] = maxf(height_at(pts[k]), maxf(height_at(pts[k] + side), height_at(pts[k] - side))) + lift
		var base := verts.size()
		var along := 0.0
		var spawn_pts := PackedVector3Array()
		for k in pts.size():
			var dir: Vector2
			if k == 0:
				dir = pts[1] - pts[0]
			elif k == pts.size() - 1:
				dir = pts[k] - pts[k - 1]
			else:
				dir = (pts[k] - pts[k - 1]).normalized() + (pts[k + 1] - pts[k]).normalized()
			dir = dir.normalized()
			var nrm := Vector2(-dir.y, dir.x) * hw
			if k > 0:
				along += pts[k].distance_to(pts[k - 1])
			var y := heights[k]
			var l := Vector3(pts[k].x + nrm.x, y, pts[k].y + nrm.y)
			var r := Vector3(pts[k].x - nrm.x, y, pts[k].y - nrm.y)
			verts.append_array([l, r])
			uvs.append_array([Vector2(0, along), Vector2(1, along)])
			colors.append_array([color, color])
			spawn_pts.append(Vector3(pts[k].x, y, pts[k].y))
			if k > 0:
				var a := base + (k - 1) * 2
				indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
				if road.bridge:
					bridge_faces.append_array([verts[a], verts[a + 1], verts[a + 2],
						verts[a + 1], verts[a + 3], verts[a + 2]])
		if rank >= DRIVABLE_RANK:
			road_spawn.append({pts = spawn_pts, rank = rank})
		if rank >= 6 and not road.bridge:
			_place_lamps(pts, heights, hw, lift)
	roads = {vertices = verts, uvs = uvs, colors = colors, indices = indices}


## Street lamps on alternating sides; the model's arm points along +x.
func _place_lamps(pts: PackedVector2Array, heights: PackedFloat32Array, hw: float, lift: float) -> void:
	const SPACING := 45.0
	var next := SPACING * 0.5
	var along := 0.0
	var side := 1.0
	for k in range(1, pts.size()):
		var seg := pts[k].distance_to(pts[k - 1])
		along += seg
		if along < next:
			continue
		next += SPACING
		side = -side
		var dir := (pts[k] - pts[k - 1]) / maxf(seg, 0.001)
		var nrm := Vector2(-dir.y, dir.x) * side
		var p := pts[k] + nrm * (hw + 1.2)
		var arm := -Vector3(nrm.x, 0, nrm.y)  # towards the road centre
		var basis := Basis(arm, Vector3.UP, arm.cross(Vector3.UP))
		_add_instance("lamp_road", Transform3D(basis, Vector3(p.x, heights[k] - lift, p.y)))


func _add_instance(role: String, xf: Transform3D) -> void:
	if scatter.is_empty():
		scatter.resize(BLOCKS * BLOCKS)
		for b in scatter.size():
			scatter[b] = {}
	var block_size := size / BLOCKS
	var block := clampi(int(xf.origin.z / block_size), 0, BLOCKS - 1) * BLOCKS 		+ clampi(int(xf.origin.x / block_size), 0, BLOCKS - 1)
	var bucket: Dictionary = scatter[block]
	if not bucket.has(role):
		bucket[role] = []
	bucket[role].append(xf)


func _on_border(p: Vector2) -> bool:
	return p.x < 0.01 or p.y < 0.01 or p.x > size - 0.01 or p.y > size - 0.01


# --- Stage: buildings ------------------------------------------------------------------

const BUILDING_COLORS := [
	Color(0.66, 0.62, 0.56), Color(0.62, 0.52, 0.44), Color(0.55, 0.58, 0.62),
	Color(0.70, 0.67, 0.61), Color(0.56, 0.44, 0.38), Color(0.64, 0.60, 0.50),
	Color(0.48, 0.52, 0.56), Color(0.72, 0.65, 0.54),
]

func _build_buildings() -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var rect := PackedVector2Array([Vector2.ZERO, Vector2(size, 0), Vector2(size, size), Vector2(0, size)])
	var k := _to_local("building") if _layers.has("building") else 1.0
	building_faces.resize(BLOCKS * BLOCKS)
	for f: Dictionary in _features("building"):
		if f.tags.get("hide_3d", false):
			continue
		var height := maxf(float(f.tags.get("render_height", 6.0)), 3.0)
		var min_h := float(f.tags.get("render_min_height", 0.0))
		for ring: PackedVector2Array in f.rings:
			if MVTDecoder.ring_area(ring) <= 0.0:
				continue  # hole
			var poly := _scale_ring(ring, k)
			if poly.size() > 1 and poly[0] == poly[poly.size() - 1]:
				poly.remove_at(poly.size() - 1)
			for piece: PackedVector2Array in Geometry2D.intersect_polygons(poly, rect):
				if absf(MVTDecoder.ring_area(piece)) < 12.0:
					continue
				var color: Color = BUILDING_COLORS[hash(piece[0]) % BUILDING_COLORS.size()]
				_extrude(piece, min_h, height, color, verts, normals, colors)
	buildings = {vertices = verts, normals = normals, colors = colors}


func _extrude(poly: PackedVector2Array, min_h: float, height: float, color: Color,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray) -> void:
	var ground := INF
	for p in poly:
		ground = minf(ground, height_at(p))
	var bottom := ground + min_h - (2.0 if min_h == 0.0 else 0.0)
	var top := ground + height
	var roof := color.darkened(0.35)
	var n := poly.size()
	var ccw := MVTDecoder.ring_area(poly) > 0.0  # counter-clockwise in x/z maths sense
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var a0 := Vector3(a.x, bottom, a.y)
		var b0 := Vector3(b.x, bottom, b.y)
		var a1 := Vector3(a.x, top, a.y)
		var b1 := Vector3(b.x, top, b.y)
		var edge := b - a
		var out := Vector2(edge.y, -edge.x) if ccw else Vector2(-edge.y, edge.x)
		var nrm := Vector3(out.x, 0, out.y).normalized()
		_tri(a0, b0, b1, nrm, color, verts, normals, colors)
		_tri(a0, b1, a1, nrm, color, verts, normals, colors)
		var bs := size / BLOCKS
		var block := clampi(int(a.y / bs), 0, BLOCKS - 1) * BLOCKS + clampi(int(a.x / bs), 0, BLOCKS - 1)
		building_faces[block].append_array([a0, b0, b1, a0, b1, a1])
	var idx := Geometry2D.triangulate_polygon(poly)
	for t in range(0, idx.size(), 3):
		var p0 := poly[idx[t]]
		var p1 := poly[idx[t + 1]]
		var p2 := poly[idx[t + 2]]
		_tri(Vector3(p0.x, top, p0.y), Vector3(p1.x, top, p1.y), Vector3(p2.x, top, p2.y),
			Vector3.UP, roof, verts, normals, colors)


## Appends a triangle facing `nrm` (Godot front faces are clockwise).
static func _tri(a: Vector3, b: Vector3, c: Vector3, nrm: Vector3, color: Color,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray) -> void:
	if (b - a).cross(c - a).dot(nrm) > 0.0:
		verts.append_array([a, c, b])
	else:
		verts.append_array([a, b, c])
	normals.append_array([nrm, nrm, nrm])
	colors.append_array([color, color, color])


# --- Stage: scatter -----------------------------------------------------------------------

## class -> [instances per vertex cell, {role: weight}]
func _scatter_rules() -> Dictionary:
	var trees := "tree_broadleaf"
	var alat := absf(latitude)
	if alat < 23.0:
		trees = "tree_palm"
	elif alat > 55.0:
		trees = "tree_conifer"
	return {
		Cls.GRASS: [0.12, {trees: 2, "tree_conifer": 1, "bush": 3, "rock": 2}],
		Cls.FARM: [0.02, {"bush": 1, trees: 1}],
		Cls.FOREST: [1.6, {trees: 3, "tree_conifer": 3, "bush": 1}],
		Cls.PARK: [0.25, {trees: 4, "bush": 2}],
		Cls.SAND: [0.03, {"rock": 1, ("tree_palm" if alat < 35.0 else "bush"): 1}],
		Cls.URBAN: [0.06, {trees: 3, "bush": 1}],
		Cls.WETLAND: [0.2, {"bush": 3, trees: 1}],
		Cls.ROCK: [0.15, {"rock": 1}],
	}


func _build_scatter() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed
	var rules := _scatter_rules()
	var mask_cell := size / MASK_RES
	for j in _n - 1:
		for i in _n - 1:
			var cls: int = _class[j * _n + i]
			if not rules.has(cls):
				continue
			var h := _h[j * _n + i]
			var rule: Array = rules[cls]
			var count := int(rule[0]) + (1 if rng.randf() < fmod(rule[0], 1.0) else 0)
			for c in count:
				var p := Vector2((i + rng.randf()) * _cell, (j + rng.randf()) * _cell)
				var mi := clampi(int(p.x / mask_cell), 0, MASK_RES - 1)
				var mj := clampi(int(p.y / mask_cell), 0, MASK_RES - 1)
				if _mask[mj * MASK_RES + mi] != 0:
					continue
				var role := _pick(rule[1], rng)
				if role == "tree_broadleaf" and h > 1400.0:
					role = "tree_conifer"
				var s := rng.randf_range(0.8, 1.3)
				var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
				_add_instance(role, Transform3D(basis, Vector3(p.x, height_at(p) - 0.15, p.y)))


static func _pick(weights: Dictionary, rng: RandomNumberGenerator) -> String:
	var total := 0.0
	for w in weights.values():
		total += w
	var r := rng.randf() * total
	for role: String in weights:
		r -= weights[role]
		if r <= 0.0:
			return role
	return weights.keys()[0]
