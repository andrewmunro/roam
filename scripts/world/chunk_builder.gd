class_name ChunkBuilder
extends RefCounted
## Turns one z14 tile's vector data + elevation into plain mesh/collision arrays.
## Touches no scene nodes, so it can run on a worker thread or be stepped on the
## main thread (see step()). Chunk-local space: x east, z south, origin at the tile's
## north-west corner, in true metres.

enum Lod { FULL, HORIZON }

const LAYERS := ["transportation", "building", "water", "waterway", "landcover", "landuse", "park",
	"transportation_name", "place"]
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
const NETWORK_RANK := 3  # Roads from this rank up join the junction-aware RoadNetwork.
const SKIP_PATHS := ["corridor", "platform", "elevator"]  # indoor / station platforms
const PAVING := Color(0.66, 0.65, 0.62)
const DIRT := Color(0.62, 0.55, 0.42)


## Paths by OSM subclass: [half width, colour]. In towns footways are paving, not dirt.
func _path_style(sub: String, urban: bool) -> Array:
	match sub:
		"pedestrian":
			return [2.6, Color(0.72, 0.70, 0.65)]
		"cycleway":
			return [1.0, Color(0.50, 0.40, 0.38)]
		"steps":
			return [0.9, Color(0.62, 0.61, 0.58)]
	return [0.8, PAVING if urban else DIRT]


## Street names and place points, for the HUD's "where am I" line.
func _collect_labels() -> void:
	var k := _to_local("transportation_name") if _layers.has("transportation_name") else 1.0
	for f: Dictionary in _features("transportation_name"):
		var name := _label(f.tags)
		var ref := str(f.tags.get("ref", ""))
		if name.is_empty() and ref.is_empty():
			continue
		for r: PackedVector2Array in f.rings:
			road_names.append({pts = _scale_ring(r, k), name = name, ref = ref})
	var kp := _to_local("place") if _layers.has("place") else 1.0
	for f: Dictionary in _features("place"):
		var name := _label(f.tags)
		if name.is_empty() or f.rings.is_empty() or f.rings[0].is_empty():
			continue
		places.append({pos = f.rings[0][0] * kp, name = name, cls = str(f.tags.get("class", ""))})


## Latin-script name: English, then the international (transliterated) name.
static func _label(tags: Dictionary) -> String:
	for key in ["name_en", "name:en", "name_int", "name"]:
		var v := str(tags.get(key, ""))
		if not v.is_empty():
			return v
	return ""

# Inputs
var tile: Vector2i
var lod: Lod
var size: float  # tile edge in true metres
var latitude: float
var longitude: float
var region: String  ## see RegionStyle
var _mvt_bytes: PackedByteArray
var _neighbour_bytes := {}  # Vector2i offset -> PackedByteArray (8 surrounding tiles)
## Bridge/tunnel lines from the surrounding tiles, in this chunk's space:
## {pts, kind, cls, layer}. Lets structures be chained and profiled across seams.
var _neighbour_structures: Array[Dictionary] = []
## At-grade roads of the surrounding tiles within RoadNetwork.MARGIN of this one:
## {pts, cls, oneway}. Junctions near the seams are laid out from both sides' roads.
var _neighbour_roads: Array[Dictionary] = []
## Drivable at-grade roads of the surrounding tiles within CUT_REACH (each tile's own
## part only): {pts, cls}. Cuttings down to tunnel portals are traced through these.
var _neighbour_grade: Array[Dictionary] = []
var _have_neighbours := false
## Overpass nodes (signals, mini-roundabouts, stop/give-way) as [mx, my, kind, ...].
var _osm_points := PackedFloat64Array()
var _osm_complete := false
## Mapped street lamps and trees (chunk space), from the same Overpass data.
var _osm_lamps := PackedVector2Array()
var _osm_trees := PackedVector2Array()
const MIN_MAPPED_LAMPS := 6  # fewer than this in a tile: lamps are probably unmapped, so guess
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
var _road_owner := PackedInt32Array()  # MASK_RES^2, index+1 of the road last drawn there
var _h := PackedFloat32Array()  # final terrain heights per vertex
var _water_level := PackedFloat32Array()  # per vertex, NAN if not water
var _shore := PackedByteArray()  # 1 = non-water vertex next to water (kept noise-free)
var _road_lines: Array[Dictionary] = []  # clipped to the tile: {pts, cls, bridge}
## Unclipped (including the tile buffer) so neighbouring chunks flatten their shared
## edge identically.
var _flatten_lines: Array[Dictionary] = []
## RoadNetwork input from this tile: {pts, cls, oneway, own}.
var _net_lines: Array[Dictionary] = []
var _rings: Array[Vector3] = []  # roundabouts (centre x, z, outer radius), from RoadNetwork
var _no_park := PackedByteArray()  # MASK_RES^2, 1 = too close to a junction to park
var _noise := FastNoiseLite.new()

# Outputs (read by Chunk once done())
var terrain := {}  # {vertices, colors, indices}
var collision := {}  # {heights: PackedFloat32Array, width: int, cell: float}
var water := {}
var roads := {}
## Road surface triangles per scatter block, for collision (the car drives on the
## drawn road, which sits a little above the terrain).
var road_faces: Array[PackedVector3Array] = []
## Terrain heights of already-built neighbours along the shared edges: side ("w", "e",
## "n", "s") -> PackedFloat32Array of _n values. This chunk's edges are pinned to them.
var edge_pins := {}
var road_spawn: Array[Dictionary] = []  # {pts: PackedVector3Array, rank: int}
var road_names: Array[Dictionary] = []  # {pts: PackedVector2Array, name: String, ref: String}
var road_stats := {}  ## RoadNetwork.stats: junction, roundabout and signal counts
var signal_spots: Array[Vector2] = []
var osm_complete := false  ## junction controls came from Overpass, not guesses
var places: Array[Dictionary] = []  # {pos: Vector2, name: String, cls: String}
## Collision faces for bridge decks/railings and tunnel floors/walls.
var structure_faces := PackedVector3Array()
## Concrete for bridge slabs, railings, pillars and tunnel tubes (building shader, no windows).
var structures := {}
## Tunnel volumes in chunk space; each maps the unit cube [-1, 1]^3 onto a box. While
## the car is inside one, terrain collision is off. `portal_boxes` is the subset where
## the tube meets the surface, which the terrain shader cuts away.
var tunnel_boxes: Array[Transform3D] = []
var portal_boxes: Array[Transform3D] = []
## The portal boxes at tunnel mouths, which the terrain shader cuts away (cuttings use
## cut_mask: there are far too many of their boxes for the shader to loop over).
var mouth_boxes: Array[Transform3D] = []
## Where the terrain is cut away over cuttings (null if there are none): CUT_MASK_RES^2,
## R = signed distance (m) to the cutting's edge (negative inside), G = floor height
## above cut_base. The terrain shader discards terrain inside that is above the floor.
var cut_mask: Image
var cut_base := 0.0
const CUT_MASK_RES := 256
var _open_segments: Array[Dictionary] = []  # {a, b, ha, hb, wall, skip_l, skip_r}
## Terrain triangles (terrain physics layer) re-added around tunnel portals, where the
## heightmap collision has holes so cars can drive into the tube.
var terrain_patch_faces := PackedVector3Array()
var _tunnel_segments: Array[Dictionary] = []  # {a, b: Vector2, ha, hb: road heights, wall}
var buildings := {}
var building_faces: Array[PackedVector3Array] = []  # per scatter block, for incremental upload
var scatter: Array[Dictionary] = []  # per block: {role: Array[Transform3D]}


func _init(p_tile: Vector2i, p_lod: Lod, mvt: PackedByteArray, elev: ElevationSource,
		neighbours := {}, osm := {}) -> void:
	tile = p_tile
	_osm_points = osm.get("points", PackedFloat64Array())
	_osm_complete = osm.get("complete", false)
	osm_complete = _osm_complete
	lod = p_lod
	_mvt_bytes = mvt
	_neighbour_bytes = neighbours
	_elev = elev
	_scale = Geo.scale
	_merc0 = Geo.tile_origin_merc(tile, Geo.CHUNK_ZOOM)
	size = Geo.tile_size_merc(Geo.CHUNK_ZOOM) * _scale
	var pts: PackedFloat64Array = _osm_points
	for i in range(0, pts.size() - 2, 3):
		var kind := int(pts[i + 2])
		if kind != RoadNetwork.Pt.LAMP and kind != RoadNetwork.Pt.TREE:
			continue
		var p := Vector2((pts[i] - _merc0[0]) * _scale, (_merc0[1] - pts[i + 1]) * _scale)
		if p.x < 0.0 or p.y < 0.0 or p.x >= size or p.y >= size:
			continue
		if kind == RoadNetwork.Pt.LAMP:
			_osm_lamps.append(p)
		else:
			_osm_trees.append(p)
	var ll := Geo.merc_to_lonlat(_merc0[0], _merc0[1])
	latitude = ll[1]
	longitude = ll[0]
	region = RegionStyle.region_for(latitude, longitude)
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
		stages = [_decode, _classify, _sample_heights, _water, _flatten_roads, _pin_edges,
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
	var rect := PackedVector2Array([Vector2.ZERO, Vector2(size, 0), Vector2(size, size), Vector2(0, size)])
	_have_neighbours = not _neighbour_bytes.is_empty()
	var grown := Rect2(-RoadNetwork.MARGIN, -RoadNetwork.MARGIN, size + 2.0 * RoadNetwork.MARGIN,
		size + 2.0 * RoadNetwork.MARGIN)
	for offset: Vector2i in _neighbour_bytes:
		var bytes: PackedByteArray = _neighbour_bytes[offset]
		if bytes.is_empty():
			continue
		var layer: Dictionary = MVTDecoder.decode(bytes, ["transportation"]).get("transportation", {})
		if layer.is_empty():
			continue
		var k := size / float(layer.extent)
		var shift := Vector2(offset) * size
		# That tile's own area near ours, in its coordinates.
		var near := Rect2(Vector2.ZERO, Vector2(size, size)).intersection(Rect2(grown.position - shift, grown.size))
		var near_poly := PackedVector2Array([near.position, Vector2(near.end.x, near.position.y), near.end,
			Vector2(near.position.x, near.end.y)])
		var reach := Rect2(Vector2.ZERO, Vector2(size, size)).intersection(
			Rect2(Vector2(-CUT_REACH, -CUT_REACH) - shift, Vector2(size, size) + Vector2.ONE * 2.0 * CUT_REACH))
		var reach_poly := PackedVector2Array([reach.position, Vector2(reach.end.x, reach.position.y), reach.end,
			Vector2(reach.position.x, reach.end.y)])
		for f: Dictionary in layer.features:
			var brunnel := str(f.tags.get("brunnel", ""))
			var c := str(f.tags.get("class", ""))
			if not ROADS.has(c) or f.type != MVTDecoder.GEOM_LINE:
				continue
			if not (brunnel == "bridge" or brunnel == "tunnel"):
				if ROADS[c][1] >= DRIVABLE_RANK and reach.has_area():
					for r: PackedVector2Array in f.rings:
						for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(_scale_ring(r, k), reach_poly):
							_neighbour_grade.append({pts = _translate(piece, shift), cls = c})
				if ROADS[c][1] >= NETWORK_RANK and near.has_area() and not (str(f.tags.get("subclass", "")) in SKIP_PATHS):
					var oneway := int(f.tags.get("oneway", 0))
					for r: PackedVector2Array in f.rings:
						for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(_scale_ring(r, k), near_poly):
							_neighbour_roads.append({pts = _translate(piece, shift), cls = c, oneway = oneway})
				continue
			var layer_tag := int(f.tags.get("layer", 1 if brunnel == "bridge" else 0))
			for r: PackedVector2Array in f.rings:
				# Only that tile's own part (its buffer overlaps ours and other neighbours).
				for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(_scale_ring(r, k), rect):
					_neighbour_structures.append({pts = _translate(piece, shift), kind = brunnel,
						cls = c, layer = layer_tag})
	_neighbour_bytes = {}


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
	var structures_by_key := {}  # "kind|class|layer" -> Array[PackedVector2Array]
	var grade_roads: Array[Dictionary] = []  # at-grade lines; added once tunnels have claimed approaches
	var add_road := func(r: PackedVector2Array, c: String, sub := "", oneway := 0) -> void:
		if ROADS[c][1] >= DRIVABLE_RANK:
			_flatten_lines.append({pts = r, cls = c})
		if ROADS[c][1] >= NETWORK_RANK and not _have_neighbours:
			# No neighbour data: this tile's buffer is the only context past the seams.
			for piece: PackedVector2Array in Geometry2D.clip_polyline_with_polygon(r, rect):
				_net_lines.append({pts = piece, cls = c, oneway = oneway, own = false})
		for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(r, rect):
			if ROADS[c][1] >= NETWORK_RANK and piece.size() >= 2:
				_net_lines.append({pts = piece, cls = c, oneway = oneway, own = true})
			if piece.size() >= 2:
				_road_lines.append({pts = piece, cls = c, sub = sub, bridge = false, tunnel = false})
				Raster.stroke_polyline(_mask, MASK_RES, MASK_RES, mask_cell, piece,
					ROADS[c][0] + 1.5, 3)
	for f: Dictionary in _features("transportation"):
		var c := str(f.tags.get("class", ""))
		var sub := str(f.tags.get("subclass", ""))
		if c == "path" and f.type == MVTDecoder.GEOM_POLYGON:
			paint.call("transportation", f, Cls.URBAN)  # pedestrian squares, platforms: paving
			continue
		if not ROADS.has(c) or f.type != MVTDecoder.GEOM_LINE or sub in SKIP_PATHS:
			continue
		var brunnel := str(f.tags.get("brunnel", ""))
		if brunnel == "bridge" or brunnel == "tunnel":
			var layer := int(f.tags.get("layer", 1 if brunnel == "bridge" else 0))
			var key := "%s|%s|%d" % [brunnel, c, layer]
			if not structures_by_key.has(key):
				structures_by_key[key] = []
			for r in _feature_rings("transportation", f):
				structures_by_key[key].append_array(Geometry2D.intersect_polyline_with_polygon(r, rect))
			continue
		for r in _feature_rings("transportation", f):
			grade_roads.append({pts = r, cls = c, sub = sub, oneway = int(f.tags.get("oneway", 0))})
	_collect_labels()
	for s in _neighbour_structures:
		var key := "%s|%s|%d" % [s.kind, s.cls, s.layer]
		if not structures_by_key.has(key):
			structures_by_key[key] = []
		structures_by_key[key].append(s.pts)
	# At-grade drivable roads of all nine tiles, each tile's own part, so that every chunk
	# judges tunnels and traces their cuttings from the same picture.
	var context: Array[Dictionary] = _neighbour_grade.duplicate()
	for g in grade_roads:
		if ROADS[g.cls][1] >= DRIVABLE_RANK:
			for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(g.pts, rect):
				context.append({pts = piece, cls = g.cls})
	# OSM splits long bridges/tunnels into several ways (and tiles cut them); chain
	# the pieces from this and the surrounding tiles, then judge and profile them whole.
	var chains: Array[Dictionary] = []  # {pts, kind, cls, layer, under, sunk}
	for key: String in structures_by_key:
		var parts := key.split("|")
		for r in _chain_lines(structures_by_key[key]):
			var ch := {pts = r, kind = parts[0], cls = parts[1], layer = int(parts[2]), under = false, sunk = false}
			if ch.kind == "tunnel" and not (ROADS[ch.cls][1] < NETWORK_RANK_TUNNEL and ch.layer < 0):
				ch.under = _is_underground(r, ch.layer, context)
			chains.append(ch)
	# Short tunnel pieces that join a deep tunnel (slip roads merging underground) are deep too.
	for ch in chains:
		if ch.kind == "tunnel" and not ch.under and ROADS[ch.cls][1] >= DRIVABLE_RANK \
				and (_joins_deep(ch.pts[0], ch, chains) or _joins_deep(ch.pts[ch.pts.size() - 1], ch, chains)):
			ch.under = true
	# Dug-down road tunnels (not bored through a hill) have their portals deep in a cutting.
	var portals: Array[Dictionary] = []  # {pos, chain}
	for i in chains.size():
		var ch: Dictionary = chains[i]
		if ch.under and ROADS[ch.cls][1] >= DRIVABLE_RANK and not _is_bored_tunnel(ch.pts):
			ch.sunk = true
			for p: Vector2 in [ch.pts[0], ch.pts[ch.pts.size() - 1]]:
				if _real_end(p) and not _joins_deep(p, ch, chains):
					portals.append({pos = p, chain = i})
	_trace_cuttings(context, portals)
	# Ramps that leave or join another bridge in mid-air start at that deck's height,
	# not on the ground below it. Two passes let pins propagate along a chain of ramps.
	for pass_i in 2:
		for ch in chains:
			if ch.kind != "bridge":
				continue
			var r: PackedVector2Array = ch.pts
			var pins := Vector2(NAN, NAN)
			if pass_i > 0:
				pins = Vector2(_deck_height_at(r[0], ch, chains), _deck_height_at(r[r.size() - 1], ch, chains))
			ch.profile = _structure_profile(r, "bridge", ch.layer, false, pins)
	for ch in chains:
		var r: PackedVector2Array = ch.pts
		var c: String = ch.cls
		var kind: String = ch.kind
		if not _touches_tile(r):
			continue  # entirely in a neighbour: that chunk draws it
		if kind == "tunnel" and ROADS[c][1] < NETWORK_RANK_TUNNEL and ch.layer < 0:
			continue  # underground car parks, service ramps and passages: not drawn
		if kind == "tunnel" and not ch.under:
			if ROADS[c][1] >= DRIVABLE_RANK:
				add_road.call(_clip_to_tile_polyline(r), c)  # underpass or passage: a road at grade
			continue  # (underground footpaths: nothing to draw)
		var profile: Dictionary = ch.profile if ch.has("profile") else _structure_profile(r, kind, ch.layer, ch.sunk)
		for run: Dictionary in _clip_profile(profile):
			if run.pts.size() >= 2:
				_road_lines.append({pts = run.pts, heights = run.heights, cls = c,
					bridge = kind == "bridge", tunnel = kind == "tunnel", sunk = ch.sunk})
				if kind == "bridge":
					Raster.stroke_polyline(_mask, MASK_RES, MASK_RES, mask_cell, run.pts,
						ROADS[c][0] + 1.5, 3)
	# The stretches of road down in a cutting become open structures (walls, no roof).
	if not _cut_depth.is_empty():
		var kept: Array[Dictionary] = []
		for g in grade_roads:
			for part: Dictionary in _split_cutting(g):
				if not part.cut:
					kept.append({pts = part.pts, cls = g.cls, sub = g.sub, oneway = g.oneway})
					continue
				for run: Dictionary in _clip_profile(part):
					if run.pts.size() >= 2:
						_road_lines.append({pts = run.pts, heights = run.heights, cls = g.cls,
							bridge = false, tunnel = true, open = true})
		grade_roads = kept
	for g in grade_roads:
		if g.pts.size() >= 2:
			add_road.call(g.pts, g.cls, g.sub, g.oneway)
	_paint_road_owners(mask_cell)
	_mark_dense_urban()


# --- Bridges and tunnels -------------------------------------------------------------
#
# Vector tiles clip lines to the tile plus a buffer, so a long bridge or tunnel is only
# partly known to each tile. Heights are therefore computed from information that both
# tiles sharing a seam can see: the DEM (sampled in absolute mercator space) and, within
# STRUCT_REACH of a point, the line itself and its real (unclipped) ends. Structures that
# lie wholly inside one tile with both ends known use the more realistic end-to-end
# grade instead.

const BRIDGE_CLEARANCE := 5.5
const WATER_CLEARANCE := 5.0
const LAYER_HEIGHT := 6.0
const TUNNEL_HEIGHT := 6.0
const TUNNEL_COVER := 7.0  # road must be this far under the surface inside a tunnel
const TUNNEL_MIN_RELIEF := 10.0
const MIN_RETAIN := 0.4  # a cutting wall stands only where its side is this far above the road
const DECK_DROP := 0.4  # a dug-down tunnel's roof deck sits this far under the surface
const MAX_GRADE := 0.06  # steepest bridge/tunnel approach
const ENVELOPE := 12.0


## True if p is a genuine line end rather than a cut at the edge of the 3x3 tiles
## this chunk knows structures for.
func _real_end(p: Vector2) -> bool:
	var m := size - 0.5
	return p.x > -m and p.y > -m and p.x < size + m and p.y < size + m


func _touches_tile(line: PackedVector2Array) -> bool:
	for k in range(1, line.size()):
		if _inside_tile(line[k]) or _inside_tile(line[k - 1]):
			return true
	return false


## The part of a chained line inside this tile (as one polyline, for at-grade use).
func _clip_to_tile_polyline(line: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in line:
		if _inside_tile(p):
			out.append(p)
	return out if out.size() >= 2 else line


## Most OSM tunnels are underpasses beneath embankments or buildings, which the DEM
## can't see. Only treat a line as a bored tunnel if the ground rises well above it.
## A mapped tunnel is really below ground if a hill rises above it, or if it is long
## and either on a negative layer or crossed by street-level roads (dug-down city
## tunnels). Short ones are underpasses below embankments or passages through
## buildings, drawn at grade.
func _is_underground(line: PackedVector2Array, layer: int, grade_roads: Array[Dictionary]) -> bool:
	if _is_bored_tunnel(line):
		return true
	var length := _polyline_length(line)
	if layer < 0 and length >= 120.0:
		return true
	return length >= 60.0 and _crossed_by_road(line, grade_roads)


func _crossed_by_road(line: PackedVector2Array, grade_roads: Array[Dictionary]) -> bool:
	var box := _bounds(line).grow(2.0)
	var ends := [line[0], line[line.size() - 1]]
	for g in grade_roads:
		if ROADS[g.cls][1] < DRIVABLE_RANK:
			continue
		var pts: PackedVector2Array = g.pts
		if pts.size() < 2:
			continue
		if not g.has("box"):
			g.box = _bounds(pts)
		if not box.intersects(g.box):
			continue
		for k in range(1, pts.size()):
			for m in range(1, line.size()):
				var x: Variant = Geometry2D.segment_intersects_segment(pts[k - 1], pts[k], line[m - 1], line[m])
				if x != null and (x as Vector2).distance_to(ends[0]) > 3.0 and (x as Vector2).distance_to(ends[1]) > 3.0:
					return true
	return false


static func _bounds(pts: PackedVector2Array) -> Rect2:
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r


const NETWORK_RANK_TUNNEL := 4  # minor roads and up get proper underground tunnels
const CUTTING_GRADE := 0.08
const CUT_REACH := 350.0  # neighbour roads this far out are traced for cuttings
const CUT_GAP := 250.0  # roads between two portals at most this far apart stay deep
const CUT_STEP := 3.0  # sample spacing along traced roads


## True if `p` (an end of chain `ch`) meets another underground tunnel: an underground
## junction, not a portal.
func _joins_deep(p: Vector2, ch: Dictionary, chains: Array[Dictionary]) -> bool:
	for other in chains:
		if other == ch or not other.under:
			continue
		var pts: PackedVector2Array = other.pts
		for k in range(1, pts.size()):
			if Geometry2D.get_closest_point_to_segment(p, pts[k - 1], pts[k]).distance_to(p) < 1.5:
				return true
	return false


# Depth of the cutting along traced roads: samples (chunk space), depth below the DEM,
# half width, and a grid of segment starts (sample k to k + 1) for lookups.
var _cut_pts := PackedVector2Array()
var _cut_depth := PackedFloat32Array()
var _cut_hw := PackedFloat32Array()
var _cut_next := PackedInt32Array()  # k + 1 if the piece continues, else -1
var _cut_grid := {}  # Vector2i -> PackedInt32Array of segment starts
const CUT_GRID := 16.0


## A dug-down tunnel's portals are TUNNEL_COVER deep, so the roads leading to them run
## in a cutting that climbs at CUTTING_GRADE: the depth falls off with the distance along
## the road network (slip roads branching off climb out too). Roads that link two portals
## closely stay deep all the way, as city tunnels usually sit in one long cutting.
## Traced on the at-grade roads of all nine tiles so neighbouring chunks agree.
func _trace_cuttings(context: Array[Dictionary], portals: Array[Dictionary]) -> void:
	if portals.is_empty():
		return
	# Sample the roads near any portal.
	var reach := CUT_GAP + TUNNEL_COVER / CUTTING_GRADE
	var piece_start := PackedInt32Array()
	for g in context:
		var box := _bounds(g.pts).grow(reach)
		var near := false
		for pt: Dictionary in portals:
			near = near or box.has_point(pt.pos)
		if not near:
			continue
		var pts := _resample(g.pts, CUT_STEP)
		piece_start.append(_cut_pts.size())
		var hw: float = ROADS[g.cls][0]
		for k in pts.size():
			_cut_pts.append(pts[k])
			_cut_hw.append(hw)
			_cut_next.append(_cut_pts.size() if k < pts.size() - 1 else -1)
	var n := _cut_pts.size()
	if n == 0:
		return
	# Pieces join where one ends on (or near) another: junctions and tile seams.
	var hash := {}
	for k in n:
		var cell := Vector2i((_cut_pts[k] / 2.0).floor())
		if not hash.has(cell):
			hash[cell] = PackedInt32Array()
		hash[cell].append(k)
	var nearest := func(p: Vector2, skip_from: int, skip_to: int, radius: float) -> int:
		var best := -1
		var best_d := radius
		var c := Vector2i((p / 2.0).floor())
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				for k: int in hash.get(c + Vector2i(dx, dy), PackedInt32Array()):
					if k >= skip_from and k < skip_to:
						continue
					var d := _cut_pts[k].distance_to(p)
					if d < best_d:
						best_d = d
						best = k
		return best
	var links: Array[PackedInt32Array] = []
	links.resize(n)
	for k in n:
		links[k] = PackedInt32Array()
	for k in n:
		if _cut_next[k] >= 0:
			links[k].append(_cut_next[k])
			links[_cut_next[k]].append(k)
	piece_start.append(n)
	for i in piece_start.size() - 1:
		for k: int in [piece_start[i], piece_start[i + 1] - 1]:
			var j: int = nearest.call(_cut_pts[k], piece_start[i], piece_start[i + 1], 1.5)
			if j >= 0:
				links[k].append(j)
				links[j].append(k)
	# Distance along the roads from each portal.
	var seeds: Array[PackedInt32Array] = []
	var dists: Array[PackedFloat32Array] = []
	for pt: Dictionary in portals:
		var s := PackedInt32Array()
		var j: int = nearest.call(pt.pos, 0, 0, 2.0)
		if j >= 0:
			s.append(j)
		seeds.append(s)
		dists.append(_road_distances(links, s, reach))
	# Anchors at full depth: the portals, and the roads joining two portals closely.
	var anchors := PackedInt32Array()
	for s in seeds:
		anchors.append_array(s)
	for a in portals.size():
		for b in range(a + 1, portals.size()):
			if portals[a].chain == portals[b].chain or seeds[a].is_empty() or seeds[b].is_empty() \
					or portals[a].pos.distance_to(portals[b].pos) > CUT_GAP:
				continue
			var gap := INF
			for k in n:
				gap = minf(gap, dists[a][k] + dists[b][k])
			if gap > CUT_GAP:
				continue
			for k in n:
				if dists[a][k] + dists[b][k] <= gap + 1.0:
					anchors.append(k)
	var from_anchor := _road_distances(links, anchors, TUNNEL_COVER / CUTTING_GRADE)
	_cut_depth.resize(n)
	for k in n:
		_cut_depth[k] = maxf(0.0, TUNNEL_COVER - CUTTING_GRADE * from_anchor[k])
	for k in n:
		var m := _cut_next[k]
		if m < 0 or (_cut_depth[k] <= 0.0 and _cut_depth[m] <= 0.0):
			continue
		var lo := (_cut_pts[k].min(_cut_pts[m]) / CUT_GRID).floor()
		var hi := (_cut_pts[k].max(_cut_pts[m]) / CUT_GRID).floor()
		for gy in range(int(lo.y), int(hi.y) + 1):
			for gx in range(int(lo.x), int(hi.x) + 1):
				var cell := Vector2i(gx, gy)
				if not _cut_grid.has(cell):
					_cut_grid[cell] = PackedInt32Array()
				_cut_grid[cell].append(k)


## Shortest distance along `links` from any of `seeds` to every sample (INF beyond `limit`).
func _road_distances(links: Array[PackedInt32Array], seeds: PackedInt32Array, limit: float) -> PackedFloat32Array:
	var dist := PackedFloat32Array()
	dist.resize(links.size())
	dist.fill(INF)
	var queue := PackedInt32Array()
	for s in seeds:
		dist[s] = 0.0
		queue.append(s)
	# Label-correcting search: the graph is nearly a tree, so few samples are revisited.
	var head := 0
	while head < queue.size():
		var k := queue[head]
		head += 1
		for j in links[k]:
			var d := dist[k] + _cut_pts[k].distance_to(_cut_pts[j])
			if d < dist[j] and d <= limit:
				dist[j] = d
				queue.append(j)
	return dist


## Depth of the cutting under `p` (0 if it is not on a traced road), and the traced
## road's half width, as Vector2(depth, hw).
func _cut_at(p: Vector2, tolerance: float) -> Vector2:
	var best := Vector2.ZERO
	var best_d := tolerance
	for k: int in _cut_grid.get(Vector2i((p / CUT_GRID).floor()), PackedInt32Array()):
		var a := _cut_pts[k]
		var b := _cut_pts[_cut_next[k]]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := q.distance_to(p)
		if d < best_d:
			best_d = d
			var t := a.distance_to(q) / maxf(a.distance_to(b), 0.001)
			best = Vector2(lerpf(_cut_depth[k], _cut_depth[_cut_next[k]], t), _cut_hw[k])
	return best


## Splits an at-grade road into parts at street level and parts down in a cutting:
## [{pts, cut: bool, heights (cut parts only)}]. Cut parts end where the depth reaches 0.
func _split_cutting(g: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var whole: PackedVector2Array = g.pts
	if ROADS[g.cls][1] < DRIVABLE_RANK or whole.size() < 2:
		return [{pts = whole, cut = false}]
	var pts := _resample(whole, 2.0)
	var depth := PackedFloat32Array()
	var any := false
	for p in pts:
		var d := _cut_at(p, 1.5).x
		depth.append(d)
		any = any or d > 0.05
	if not any:
		return [{pts = whole, cut = false}]
	var k := 0
	while k < pts.size() - 1:
		var cut := depth[k] > 0.05 or depth[k + 1] > 0.05
		var run := PackedVector2Array([pts[k]])
		var hs := PackedFloat32Array([_dem_at(pts[k]) - depth[k]])
		while k < pts.size() - 1 and (depth[k] > 0.05 or depth[k + 1] > 0.05) == cut:
			k += 1
			run.append(pts[k])
			hs.append(_dem_at(pts[k]) - depth[k])
		out.append({pts = run, cut = cut, heights = _smooth(hs, 2)} if cut else {pts = run, cut = false})
	return out


func _is_bored_tunnel(line: PackedVector2Array) -> bool:
	var ends := maxf(_dem_at(line[0]), _dem_at(line[line.size() - 1]))
	for p in _resample(line, 10.0):
		if _dem_at(p) - ends >= TUNNEL_MIN_RELIEF:
			return true
	return false


## Joins lines that share an endpoint into longer polylines.
static func _chain_lines(lines: Array) -> Array[PackedVector2Array]:
	var pool: Array[PackedVector2Array] = []
	for l: PackedVector2Array in lines:
		if l.size() >= 2:
			pool.append(l)
	var out: Array[PackedVector2Array] = []
	while not pool.is_empty():
		var chain: PackedVector2Array = pool.pop_back()
		var grew := true
		while grew:
			grew = false
			for i in pool.size():
				var other := pool[i]
				var head := chain[0]
				var tail := chain[chain.size() - 1]
				var joined := PackedVector2Array()
				if tail.distance_to(other[0]) < 0.5:
					joined = chain + other.slice(1)
				elif tail.distance_to(other[other.size() - 1]) < 0.5:
					var rev := other.duplicate()
					rev.reverse()
					joined = chain + rev.slice(1)
				elif head.distance_to(other[other.size() - 1]) < 0.5:
					joined = other + chain.slice(1)
				elif head.distance_to(other[0]) < 0.5:
					var rev := other.duplicate()
					rev.reverse()
					joined = rev + chain.slice(1)
				if not joined.is_empty():
					chain = joined
					pool.remove_at(i)
					grew = true
					break
		out.append(chain)
	return out


static func _polyline_length(pts: PackedVector2Array) -> float:
	var total := 0.0
	for k in range(1, pts.size()):
		total += pts[k].distance_to(pts[k - 1])
	return total


## Height of another bridge's deck under a ramp end at p (NAN if none meets it there).
func _deck_height_at(p: Vector2, self_chain: Dictionary, chains: Array[Dictionary]) -> float:
	if not _real_end(p):
		return NAN
	var best := DECK_JOIN
	var h := NAN
	for ch in chains:
		if is_same(ch, self_chain) or ch.kind != "bridge" or not ch.has("profile"):
			continue
		var pts: PackedVector2Array = ch.profile.pts
		var hs: PackedFloat32Array = ch.profile.heights
		for k in range(1, pts.size()):
			var q := Geometry2D.get_closest_point_to_segment(p, pts[k - 1], pts[k])
			var d := q.distance_to(p)
			if d < best:
				best = d
				var seg := pts[k - 1].distance_to(pts[k])
				var t := pts[k - 1].distance_to(q) / seg if seg > 0.001 else 0.0
				h = lerpf(hs[k - 1], hs[k], t)
	return h


const DECK_JOIN := 3.0  ## a ramp end this close to another deck joins it


## Resamples a bridge/tunnel line every 3 m and assigns the road surface height.
## `pins` fixes a bridge's start/end heights where it joins another deck (NAN: free).
## Returns {pts, heights}.
func _structure_profile(line: PackedVector2Array, kind: String, layer: int, sunk := false,
		pins := Vector2(NAN, NAN)) -> Dictionary:
	var pts := _resample(line, 3.0)
	var n := pts.size()
	var dist := PackedFloat32Array([0.0])
	for k in range(1, n):
		dist.append(dist[k - 1] + pts[k].distance_to(pts[k - 1]))
	var total := dist[n - 1]
	var ground := PackedFloat32Array()
	ground.resize(n)
	for k in n:
		ground[k] = _dem_at(pts[k])
		if kind == "bridge":
			ground[k] = maxf(ground[k], 0.0)  # the DEM includes the seabed; clear the water surface
	var start_real := _real_end(pts[0])
	var end_real := _real_end(pts[n - 1])
	var contained := start_real and end_real
	var e0 := ground[0] if is_nan(pins.x) else pins.x
	var e1 := ground[n - 1] if is_nan(pins.y) else pins.y
	var hs := PackedFloat32Array()
	hs.resize(n)
	for k in n:
		var grade := lerpf(e0, e1, dist[k] / maxf(total, 0.01))
		if kind == "bridge":
			var env := -INF  # upper envelope of what the deck must clear
			for j in n:
				if absf(dist[j] - dist[k]) <= ENVELOPE:
					var water := ground[j] <= 0.5 or (_inside_tile(pts[j]) and _class_at(pts[j]) == Cls.WATER)
					var clear := WATER_CLEARANCE if water else BRIDGE_CLEARANCE
					env = maxf(env, ground[j] + clear + (layer - 1) * LAYER_HEIGHT)
			hs[k] = maxf(grade, env) if contained else env
		else:
			var deep := grade if contained else _deep_ground(pts[k]) - 2.0
			# A dug-down tunnel's roof stays well under the street above it.
			hs[k] = minf(deep, ground[k] - TUNNEL_COVER - (2.0 if sunk else 0.0))
	# Approaches climb or descend at a realistic grade from the real ends (a dug-down
	# tunnel's ends are portals at the bottom of a cutting).
	var grade_limit := CUTTING_GRADE if kind == "tunnel" else MAX_GRADE
	var end_drop := TUNNEL_COVER if sunk else 0.0
	for k in n:
		if start_real:
			var g0 := e0 - end_drop
			hs[k] = clampf(hs[k], g0 - grade_limit * dist[k], g0 + grade_limit * dist[k])
		if end_real:
			var d := total - dist[k]
			var g1 := e1 - end_drop
			hs[k] = clampf(hs[k], g1 - grade_limit * d, g1 + grade_limit * d)
	return {pts = pts, heights = _smooth(hs, 5)}


## Lowest DEM height within ~120 m: a smooth stand-in for a tunnel's grade that depends
## only on absolute position.
func _deep_ground(p: Vector2) -> float:
	var lowest := _dem_at(p)
	for r: float in [60.0, 120.0]:
		for a in 8:
			lowest = minf(lowest, _dem_at(p + Vector2.from_angle(a * TAU / 8.0) * r))
	return lowest


## Cuts a profile to the tile, interpolating heights at the border.
func _clip_profile(profile: Dictionary) -> Array[Dictionary]:
	var pts: PackedVector2Array = profile.pts
	var hs: PackedFloat32Array = profile.heights
	var out: Array[Dictionary] = []
	var cur_p := PackedVector2Array()
	var cur_h := PackedFloat32Array()
	var inside := func(p: Vector2) -> bool:
		return p.x >= 0.0 and p.y >= 0.0 and p.x <= size and p.y <= size
	for k in pts.size():
		var in_k: bool = inside.call(pts[k])
		if k > 0 and in_k != inside.call(pts[k - 1]):
			var t := _border_t(pts[k - 1], pts[k])
			cur_p.append(pts[k - 1].lerp(pts[k], t))
			cur_h.append(lerpf(hs[k - 1], hs[k], t))
			if not in_k:
				out.append({pts = cur_p, heights = cur_h})
				cur_p = PackedVector2Array()
				cur_h = PackedFloat32Array()
		if in_k:
			cur_p.append(pts[k])
			cur_h.append(hs[k])
	if cur_p.size() >= 2:
		out.append({pts = cur_p, heights = cur_h})
	return out


## Parameter along a->b where the segment crosses the tile border (exactly one of the
## two points is inside).
func _border_t(a: Vector2, b: Vector2) -> float:
	var a_in := _inside_tile(a)
	var lo := 0.0
	var hi := 1.0
	for i in 24:
		var mid := (lo + hi) * 0.5
		if _inside_tile(a.lerp(b, mid)) == a_in:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


func _inside_tile(p: Vector2) -> bool:
	return p.x >= 0.0 and p.y >= 0.0 and p.x <= size and p.y <= size


## Marks which road covers each mask cell, so props can tell junctions apart from
## plain road edges.
func _paint_road_owners(mask_cell: float) -> void:
	_road_owner.resize(MASK_RES * MASK_RES)
	_road_owner.fill(0)
	for idx in _road_lines.size():
		var road: Dictionary = _road_lines[idx]
		if ROADS[road.cls][1] >= DRIVABLE_RANK:
			Raster.stroke_polyline(_road_owner, MASK_RES, MASK_RES, mask_cell, road.pts,
				ROADS[road.cls][0], idx + 1)


## True if a road other than `idx` is within `radius` metres of p.
func _near_other_road(p: Vector2, idx: int, radius: float) -> bool:
	var mask_cell := size / MASK_RES
	var r := ceili(radius / mask_cell)
	var ci := int(p.x / mask_cell)
	var cj := int(p.y / mask_cell)
	for j in range(maxi(cj - r, 0), mini(cj + r + 1, MASK_RES)):
		for i in range(maxi(ci - r, 0), mini(ci + r + 1, MASK_RES)):
			var o := _road_owner[j * MASK_RES + i]
			if o != 0 and o != idx + 1:
				return true
	return false


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
			# Not in towns or under roads/buildings: there the banks are quays and
			# embankments, and lowering them sinks whole islands and riverside streets.
			if level < INF and _class[v] != Cls.URBAN and not _masked_near(i, j):
				_shore[v] = 1
				_h[v] = minf(_h[v], level - 0.6)


## True if the fine mask has a road or building within about one vertex cell.
func _masked_near(i: int, j: int) -> bool:
	var scale := float(MASK_RES) / (_n - 1)
	var ci := int(i * scale)
	var cj := int(j * scale)
	var r := int(scale)
	for mj in range(maxi(cj - r, 0), mini(cj + r + 1, MASK_RES)):
		for mi in range(maxi(ci - r, 0), mini(ci + r + 1, MASK_RES)):
			if _mask[mj * MASK_RES + mi] >= 2:
				return true
	return false


# --- Stage: road flattening ---------------------------------------------------------

## Splits the road mesh's triangles into scatter blocks for incremental upload.
func _collect_road_faces(verts: PackedVector3Array, indices: PackedInt32Array) -> void:
	road_faces.resize(BLOCKS * BLOCKS)
	var bs := size / BLOCKS
	for t in range(0, indices.size(), 3):
		var a := verts[indices[t]]
		var b := verts[indices[t + 1]]
		var c := verts[indices[t + 2]]
		# Only the drivable top: kerb and edge faces would be walls the car snags on,
		# while the wheel rays step up onto the surface by themselves.
		var nrm := (b - a).cross(c - a)
		if absf(nrm.y) < 0.6 * nrm.length():
			continue
		var m := (a + b + c) / 3.0
		var block := clampi(int(m.z / bs), 0, BLOCKS - 1) * BLOCKS + clampi(int(m.x / bs), 0, BLOCKS - 1)
		road_faces[block].append_array([a, b, c])


const PIN_BAND := 7  # cells over which a pinned edge blends back into this chunk's own terrain


## Makes shared edges match already-built neighbours exactly. Each tile only sees its own
## data, so flattening, water and smoothing can disagree by metres at a seam; the
## difference is spread smoothly over PIN_BAND cells (relaxation with the pinned edges
## fixed, zero beyond the band, free along unpinned edges).
func _pin_edges() -> void:
	if edge_pins.is_empty():
		return
	var n := _n
	var delta := PackedFloat32Array()
	delta.resize(n * n)
	delta.fill(0.0)
	var fixed := PackedByteArray()
	fixed.resize(n * n)
	fixed.fill(0)
	var dist := PackedInt32Array()  # cells to the nearest pinned edge
	dist.resize(n * n)
	dist.fill(1 << 20)
	for side: String in edge_pins:
		var pins: PackedFloat32Array = edge_pins[side]
		for k in n:
			var v := _edge_vertex(side, k, 0)
			delta[v] = pins[k] - _h[v]
			fixed[v] = 1
			for d in PIN_BAND + 1:
				var w := _edge_vertex(side, k, d)
				dist[w] = mini(dist[w], d)
	var band: PackedInt32Array = []
	for v in n * n:
		if fixed[v] == 0 and dist[v] <= PIN_BAND:
			band.append(v)
	for it in 3 * PIN_BAND * PIN_BAND:
		for v in band:
			var i := v % n
			var j := v / n
			var sum := 0.0
			var cnt := 0
			if i > 0:
				sum += delta[v - 1]
				cnt += 1
			if i < n - 1:
				sum += delta[v + 1]
				cnt += 1
			if j > 0:
				sum += delta[v - n]
				cnt += 1
			if j < n - 1:
				sum += delta[v + n]
				cnt += 1
			delta[v] = lerpf(delta[v], sum / cnt, 1.5)  # over-relaxed
	for v in n * n:
		_h[v] += delta[v]


## Vertex index `depth` cells in from an edge, `k` along it.
func _edge_vertex(side: String, k: int, depth: int) -> int:
	match side:
		"w": return k * _n + depth
		"e": return k * _n + (_n - 1 - depth)
		"n": return depth * _n + k
	return (_n - 1 - depth) * _n + k


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


## Water surface on the vertex grid with one level per vertex, so neighbouring quads
## share edges (per-quad levels left hairline gaps). Shore vertices take the level of
## the water next to them.
func _build_water_mesh() -> void:
	var level := PackedFloat32Array()
	level.resize(_n * _n)
	for j in _n:
		for i in _n:
			var v := j * _n + i
			if not is_nan(_water_level[v]):
				level[v] = _water_level[v]
				continue
			var sum := 0.0
			var cnt := 0
			for dj in range(-1, 2):
				for di in range(-1, 2):
					var ii := i + di
					var jj := j + dj
					if ii >= 0 and jj >= 0 and ii < _n and jj < _n and not is_nan(_water_level[jj * _n + ii]):
						sum += _water_level[jj * _n + ii]
						cnt += 1
			level[v] = sum / cnt if cnt > 0 else NAN
	var verts := PackedVector3Array()
	for j in _n - 1:
		for i in _n - 1:
			var c := [j * _n + i, j * _n + i + 1, (j + 1) * _n + i + 1, (j + 1) * _n + i]
			var any_water := false
			var complete := true
			for v: int in c:
				any_water = any_water or not is_nan(_water_level[v])
				complete = complete and not is_nan(level[v])
			if not (any_water and complete):
				continue
			var p := []
			for v: int in c:
				p.append(Vector3((v % _n) * _cell, level[v] - 0.3, (v / _n) * _cell))
			verts.append_array([p[0], p[1], p[2], p[0], p[2], p[3]])
	water = {vertices = verts}


# --- Stage: roads --------------------------------------------------------------------

## Half width for a road: OSM widths cover the travel lanes; urban side streets also
## get parking lanes where the buildings either side leave room for them.
func _road_hw(cls: String, pts: PackedVector2Array) -> float:
	var spec: Array = ROADS[cls]
	var hw: float = spec[0]
	var rank: int = spec[1]
	if (rank == 4 or rank == 5) and _urban_at(pts[pts.size() / 2]):
		if _street_room(pts) - RoadNetwork.PAVEMENT - 0.3 >= hw + PARKING * 0.75:
			hw += PARKING
	return hw


const PARKING := 2.2  ## extra half width for a parking lane


## Half the typical gap between the buildings either side of a street (INF if open).
## Samples straight out from the centre line on each side and takes a low quartile, so
## a single gap between buildings doesn't widen a narrow street.
func _street_room(pts: PackedVector2Array) -> float:
	var cell := size / MASK_RES
	var reach := 14.0
	var gaps := PackedFloat32Array()
	for k in pts.size() - 1:
		var a := pts[k]
		var b := pts[k + 1]
		var len := a.distance_to(b)
		if len < 0.01:
			continue
		var t := (b - a) / len
		var n := Vector2(-t.y, t.x)
		var d := 2.0
		while d < len:
			var p := a + t * d
			d += 8.0
			if p.x < 0.0 or p.y < 0.0 or p.x >= size or p.y >= size:
				continue
			var span := 0.0
			for side: float in [1.0, -1.0]:
				var x := 1.0
				while x < reach:
					var q := p + n * side * x
					var i := int(q.x / cell)
					var j := int(q.y / cell)
					if i >= 0 and j >= 0 and i < MASK_RES and j < MASK_RES and _mask[j * MASK_RES + i] == 2:
						break
					x += cell * 0.5
				span += x
			gaps.append(span * 0.5)
	if gaps.is_empty():
		return INF
	gaps.sort()
	return gaps[gaps.size() / 4]


## Pavements line built-up streets from side streets up to trunk roads (not motorways).
## Built-up means urban land use or buildings close by anywhere along the road: city
## centres often have no land-use polygon at all.
func _road_paved(cls: String, pts: PackedVector2Array) -> bool:
	var rank: int = ROADS[cls][1]
	if rank < 4 or rank > 8:
		return false
	var dist := PackedFloat32Array([0.0])
	for k in range(1, pts.size()):
		dist.append(dist[k - 1] + pts[k].distance_to(pts[k - 1]))
	var total := dist[dist.size() - 1]
	for s in 5:
		var d := total * (s + 0.5) / 5.0
		var k := clampi(dist.bsearch(d), 1, pts.size() - 1)
		var p := pts[k - 1].lerp(pts[k], clampf((d - dist[k - 1]) / maxf(dist[k] - dist[k - 1], 0.001), 0.0, 1.0))
		if built_up_at(p):
			return true
	return false


## Urban land use, or a building within BUILT_UP_RADIUS metres.
func built_up_at(p: Vector2) -> bool:
	if _urban_at(p):
		return true
	var cell := size / MASK_RES
	var r := ceili(BUILT_UP_RADIUS / cell)
	var ci := int(p.x / cell)
	var cj := int(p.y / cell)
	for mj in range(maxi(cj - r, 0), mini(cj + r + 1, MASK_RES), 2):
		for mi in range(maxi(ci - r, 0), mini(ci + r + 1, MASK_RES), 2):
			if _mask[mj * MASK_RES + mi] == 2:
				return true
	return false


const BUILT_UP_RADIUS := 35.0


func _urban_at(p: Vector2) -> bool:
	return _class_at(Vector2(clampf(p.x, 0.0, size), clampf(p.y, 0.0, size))) == Cls.URBAN


## Lays out this tile's at-grade roads, junctions and roundabouts (see RoadNetwork).
func _build_network() -> RoadNetwork:
	var net := RoadNetwork.new()
	net.size = size
	net.region = region
	net.left_hand = RegionStyle.left_hand_traffic(region)
	net.north_america = region == RegionStyle.NORTH_AMERICA
	net.uk = region == RegionStyle.UK
	net.height_at = height_at
	net.built_up_at = built_up_at
	net.have_points = _osm_complete
	for i in range(0, _osm_points.size() - 2, 3):
		var p := Vector2((_osm_points[i] - _merc0[0]) * _scale, (_merc0[1] - _osm_points[i + 1]) * _scale)
		if p.x > -RoadNetwork.MARGIN and p.y > -RoadNetwork.MARGIN and p.x < size + RoadNetwork.MARGIN 				and p.y < size + RoadNetwork.MARGIN:
			net.points.append({pos = p, kind = int(_osm_points[i + 2])})
	var add := func(line: Dictionary, own: bool, phantom: bool) -> void:
		var spec: Array = ROADS[line.cls]
		var pts: PackedVector2Array = line.pts
		net.add_line(pts, line.cls, _road_hw(line.cls, pts) if not phantom else spec[0], spec[0], spec[1],
			spec[2], spec[3], int(line.get("oneway", 0)), own, _road_paved(line.cls, pts) and not phantom, phantom)
	for line in _net_lines:
		add.call(line, line.own, false)
	for line in _neighbour_roads:
		add.call(line, false, false)
	# Bridges and tunnels shape the junctions at their ends but are drawn separately.
	for road in _road_lines:
		if (road.bridge or road.tunnel) and ROADS[road.cls][1] >= NETWORK_RANK:
			add.call(road, true, true)
		if road.get("open", false):
			net.add_cutting(road.pts, ROADS[road.cls][0])
	net.build()
	return net


func _build_roads() -> void:
	var net := _build_network()
	var verts := net.verts
	var uvs := net.uvs
	var uv2s := net.uv2s
	var colors := net.colors
	var indices := net.indices
	for item: Array in net.instances:
		_add_instance(item[0], item[1])
	_rings = net.ring_zones
	_no_park.resize(MASK_RES * MASK_RES)
	_no_park.fill(0)
	var cell := size / MASK_RES
	for z: Dictionary in net.no_park:
		# Half a cell wider: cells are coarse and sampled at their centres.
		Raster.stroke_polyline(_no_park, MASK_RES, MASK_RES, cell, z.pts, z.hw + cell * 0.5, 1)
	road_stats = net.stats
	signal_spots = net.signal_spots
	for road_idx in _road_lines.size():
		var road: Dictionary = _road_lines[road_idx]
		var spec: Array = ROADS[road.cls]
		var hw: float = spec[0]
		var rank: int = spec[1]
		var color: Color = spec[2]
		var style := 0 if spec[3] == 0 else (1 if spec[3] == 1 else 17)
		var structure: bool = road.bridge or road.tunnel
		var pts: PackedVector2Array = road.pts if structure else _resample(road.pts, 3.0)
		if pts.size() < 2:
			continue
		# At-grade roads are drawn by the network; here they only get props and spawns.
		var networked := not structure and rank >= NETWORK_RANK
		if road.cls == "path":
			var ps := _path_style(road.get("sub", ""), _class_at(pts[pts.size() / 2]) == Cls.URBAN)
			hw = ps[0]
			color = ps[1]
			style = 0
		if not structure:
			hw = _road_hw(road.cls, road.pts) if networked else hw
		# Extend free ends of paths and tracks (not on the tile border) over junction gaps.
		var first_dir := (pts[1] - pts[0]).normalized()
		var last_dir := (pts[pts.size() - 1] - pts[pts.size() - 2]).normalized()
		if not structure and not networked and not _on_border(pts[0]):
			pts.insert(0, pts[0] - first_dir * hw * 0.8)
		if not structure and not networked and not _on_border(pts[pts.size() - 1]):
			pts.append(pts[pts.size() - 1] + last_dir * hw * 0.8)
		var lift := 0.12 + rank * 0.025
		var heights := PackedFloat32Array()
		heights.resize(pts.size())
		if road.bridge:
			# Never let the deck dip below the (final) terrain, e.g. near its ends.
			for k in pts.size():
				heights[k] = maxf(road.heights[k], height_at(pts[k])) + lift
			_build_bridge(pts, heights, hw, road_idx, rank >= DRIVABLE_RANK)
		elif road.tunnel:
			# Near the portals the final terrain can sit below the raw DEM (carving,
			# flattening); never let the tunnel float above it.
			# The profile comes from the raw DEM; where it is shallow, blend into the final
			# (flattened) terrain so cuttings meet the street level without a step.
			for k in pts.size():
				var ground := height_at(pts[k])
				var w := clampf((ground - road.heights[k]) / 3.0, 0.0, 1.0)
				heights[k] = lerpf(ground, road.heights[k], w) + lift
			_build_tunnel(pts, heights, hw, road.get("open", false), road.get("sunk", false))
		elif networked:
			for k in pts.size():  # only for spawns and props: the network draws these
				heights[k] = height_at(pts[k]) + lift
		else:
			# Sit on the highest of centre and both edges so terrain can't poke through.
			for k in pts.size():
				var d := (pts[mini(k + 1, pts.size() - 1)] - pts[maxi(k - 1, 0)]).normalized()
				var side := Vector2(-d.y, d.x) * hw
				heights[k] = maxf(height_at(pts[k]), maxf(height_at(pts[k] + side), height_at(pts[k] - side))) + lift
		var base := verts.size()
		var along := 0.0
		var spawn_pts := PackedVector3Array()
		var uv2 := Vector2(hw, style)
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
			spawn_pts.append(Vector3(pts[k].x, y, pts[k].y))
			if networked:
				continue
			var l := Vector3(pts[k].x + nrm.x, y, pts[k].y + nrm.y)
			var r := Vector3(pts[k].x - nrm.x, y, pts[k].y - nrm.y)
			verts.append_array([l, r])
			uvs.append_array([Vector2(0, along), Vector2(1, along)])
			uv2s.append_array([uv2, uv2])
			colors.append_array([color, color])
			if k > 0:
				var a := base + (k - 1) * 2
				indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
				if structure:
					structure_faces.append_array([verts[a], verts[a + 1], verts[a + 2],
						verts[a + 1], verts[a + 3], verts[a + 2]])
		if rank >= DRIVABLE_RANK and not road.tunnel:
			road_spawn.append({pts = spawn_pts, rank = rank})
		if rank >= 6 and not structure:
			if _osm_lamps.size() < MIN_MAPPED_LAMPS:
				_place_lamps(pts, heights, hw, lift, _road_paved(road.cls, road.pts))
		if not structure:
			_place_street_props(pts, heights, hw, lift, rank, road_idx, hw > ROADS[road.cls][0] + 1.0)
	roads = {vertices = verts, uvs = uvs, uv2s = uv2s, colors = colors, indices = indices}
	_collect_road_faces(verts, indices)
	# Keep trees off the pavements (props above are placed before this).
	var mask_cell := size / MASK_RES
	for p: Dictionary in net.paved:
		Raster.stroke_polyline(_mask, MASK_RES, MASK_RES, mask_cell, p.pts, p.hw + RoadNetwork.PAVEMENT + 0.5, 3)

	_cut_portal_collision()
	_build_cut_mask()
	structures = {vertices = _s_verts, normals = _s_normals, colors = _s_colors,
		uvs = _s_uvs, uv2s = _s_uv2s}


# --- Structure geometry ----------------------------------------------------------------

const CONCRETE := Color(0.62, 0.61, 0.58, 0.0)  # alpha 0: no windows in the building shader
const TUNNEL_WALL := Color(0.55, 0.53, 0.47, 0.0)

var _s_verts := PackedVector3Array()
var _s_normals := PackedVector3Array()
var _s_colors := PackedColorArray()
var _s_uvs := PackedVector2Array()
var _s_uv2s := PackedVector2Array()


## Quad a-b-c-d (in order around the face) facing `nrm`; optionally also collidable.
func _s_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, nrm: Vector3, color: Color,
		collide := false) -> void:
	var uv := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	_tri(a, b, c, nrm, color, _s_verts, _s_normals, _s_colors, _s_uvs, _s_uv2s, uv, Vector2.ZERO)
	_tri(a, c, d, nrm, color, _s_verts, _s_normals, _s_colors, _s_uvs, _s_uv2s, uv, Vector2.ZERO)
	if collide:
		structure_faces.append_array([a, b, c, a, c, d])


## Box between two points along the road, `half` wide, from y0 to y1 at each end.
func _s_beam(p0: Vector2, p1: Vector2, half: float, y0a: float, y1a: float, y0b: float,
		y1b: float, color: Color, collide := false) -> void:
	var dir := (p1 - p0).normalized()
	var side := Vector2(-dir.y, dir.x) * half
	var corners := [p0 + side, p1 + side, p1 - side, p0 - side]
	var lo := [y0a, y0b, y0b, y0a]
	var hi := [y1a, y1b, y1b, y1a]
	var mid := (p0 + p1) * 0.5
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		var face := (a + b) * 0.5 - mid
		var out := Vector3(face.x, 0, face.y).normalized()
		_s_quad(Vector3(a.x, lo[i], a.y), Vector3(b.x, lo[(i + 1) % 4], b.y),
			Vector3(b.x, hi[(i + 1) % 4], b.y), Vector3(a.x, hi[i], a.y), out, color, collide)
	_s_quad(Vector3(corners[0].x, hi[0], corners[0].y), Vector3(corners[1].x, hi[1], corners[1].y),
		Vector3(corners[2].x, hi[2], corners[2].y), Vector3(corners[3].x, hi[3], corners[3].y),
		Vector3.UP, color)


func _build_bridge(pts: PackedVector2Array, heights: PackedFloat32Array, hw: float,
		road_idx: int, railings: bool) -> void:
	var since_pillar := 15.0
	for k in range(1, pts.size()):
		var a := pts[k - 1]
		var b := pts[k]
		var ya := heights[k - 1]
		var yb := heights[k]
		var dir := (b - a).normalized()
		var side := Vector2(-dir.y, dir.x)
		# Deck slab under the road surface.
		_s_beam(a, b, hw + 0.3, ya - 1.3, ya - 0.02, yb - 1.3, yb - 0.02, CONCRETE)
		# Railings (collidable so the car stays on the bridge), except where another
		# road shares the deck, e.g. a footway or junction joining it.
		for s: float in [1.0, -1.0]:
			var off := side * s * (hw + 0.15)
			if not railings or _near_other_road((a + b) * 0.5 + off, road_idx, 1.5):
				continue
			_s_beam(a + off, b + off, 0.15, ya - 0.1, ya + 0.9, yb - 0.1, yb + 0.9, CONCRETE, true)
		# Pillars where the deck is well above the ground.
		since_pillar += a.distance_to(b)
		var g := height_at(b)
		if since_pillar >= 30.0 and yb - g > 3.0:
			since_pillar = 0.0
			var half := minf(hw * 0.35, 1.2)
			var p0 := b - dir * half
			var p1 := b + dir * half
			_s_beam(p0, p1, half, g - 1.0, yb - 1.3, g - 1.0, yb - 1.3, CONCRETE)
			var bs := size / BLOCKS
			var block := clampi(int(b.y / bs), 0, BLOCKS - 1) * BLOCKS + clampi(int(b.x / bs), 0, BLOCKS - 1)
			if building_faces.is_empty():
				building_faces.resize(BLOCKS * BLOCKS)
			var c0 := Vector3(b.x, g - 1.0, b.y)
			var c1 := Vector3(b.x, yb - 1.3, b.y)
			var s3 := Vector3(side.x, 0, side.y) * half
			building_faces[block].append_array([c0 - s3, c0 + s3, c1 + s3, c0 - s3, c1 + s3, c1 - s3])


## Tunnel tube shaped to the terrain: on the open approach the walls are retaining walls
## only as tall as the ground beside them; the roof starts where the hill covers the
## tube, with a headwall up to the hillside there (the portal face).
## Tunnel tube, or with `open` a cutting: walls up to the ground and no roof. A `sunk`
## (dug-down) tunnel is roofed all the way, with a headwall over each portal.
func _build_tunnel(pts: PackedVector2Array, heights: PackedFloat32Array, hw: float, open := false,
		sunk := false) -> void:
	var wall := hw + 0.8
	var run_start := 0
	var n := pts.size()
	# Per point: ground height along both walls, and whether there is a roof.
	var ground := PackedFloat32Array()
	var side_ground: Array[PackedFloat32Array] = [PackedFloat32Array(), PackedFloat32Array()]
	var covered: Array[bool] = []
	for k in n:
		var d := (pts[mini(k + 1, n - 1)] - pts[maxi(k - 1, 0)]).normalized()
		var side := Vector2(-d.y, d.x)
		for si in 2:
			var s := 1.0 if si == 0 else -1.0
			side_ground[si].append(maxf(height_at(pts[k] + side * s * wall),
				height_at(pts[k] + side * s * (wall + 2.0))))
		var g := maxf(side_ground[0][k], side_ground[1][k])
		ground.append(maxf(g, height_at(pts[k])))
		covered.append(not open and (sunk or height_at(pts[k]) >= heights[k] + TUNNEL_HEIGHT + 0.5))
	# Walls left out beside another cutting, per segment and side; short stretches kept
	# between left-out ones would stand alone as fins, so they go too.
	var skips: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	for si in 2:
		skips[si].resize(n - 1)
		skips[si].fill(0)
		if not open:
			continue
		for k in range(1, n):
			var side := Vector2(-(pts[k] - pts[k - 1]).normalized().y, (pts[k] - pts[k - 1]).normalized().x)
			var s := 1.0 if si == 0 else -1.0
			if _beside_cutting((pts[k - 1] + pts[k]) * 0.5 + side * s * (wall + 2.5)):
				skips[si][k - 1] = 1
		var k := 0
		while k < n - 1:
			if skips[si][k] == 1:
				k += 1
				continue
			var e := k
			while e < n - 1 and skips[si][e] == 0:
				e += 1
			if k > 0 and e < n - 1 and pts[k].distance_to(pts[e]) < 15.0:
				for m in range(k, e):
					skips[si][m] = 1
			k = e
	var skipped := [false, false]  # a wall left out in the current run (left, right)
	for k in range(1, n):
		var a := pts[k - 1]
		var b := pts[k]
		var ya := heights[k - 1]
		var yb := heights[k]
		var dir := (b - a).normalized()
		var side := Vector2(-dir.y, dir.x)
		_tunnel_segments.append({a = a, b = b, ha = ya, hb = yb, wall = wall})
		var roof := covered[k - 1] and covered[k]
		var max_top := TUNNEL_COVER + 2.0
		var skip := [false, false]
		for si in 2:
			var s := 1.0 if si == 0 else -1.0
			# No wall between side-by-side cuttings (central reservations, slip roads).
			skip[si] = skips[si][k - 1] == 1
			# Hard shoulder out to the wall (or across to the next cutting): the terrain
			# above it is cut away.
			var reach := wall + (MEDIAN if skip[si] else 0.0)
			var e0 := a + side * s * (hw - 0.2)
			var e1 := b + side * s * (hw - 0.2)
			var f0 := a + side * s * reach
			var f1 := b + side * s * reach
			# A touch below the road surface, so where it reaches under a neighbouring
			# carriageway that road's own surface stays on top.
			_s_quad(Vector3(e0.x, ya - 0.02, e0.y), Vector3(e1.x, yb - 0.02, e1.y), Vector3(f1.x, yb - 0.02, f1.y),
				Vector3(f0.x, ya - 0.02, f0.y), Vector3.UP, SHOULDER, true)
			if skip[si]:
				skipped[si] = true
				continue
			# Each wall retains only the ground on its own side, with a low parapet; where
			# that side is barely above the road (a shallow end, or a road beside it at
			# street level) there is nothing to retain and no wall.
			var depth_a := side_ground[si][k - 1] - ya
			var depth_b := side_ground[si][k] - yb
			if not roof and maxf(depth_a, depth_b) < MIN_RETAIN:
				continue
			var top_a := TUNNEL_HEIGHT if roof else clampf(depth_a + 0.5, 0.3, max_top)
			var top_b := TUNNEL_HEIGHT if roof else clampf(depth_b + 0.5, 0.3, max_top)
			var pa := a + side * s * wall
			var pb := b + side * s * wall
			var inward := Vector3(-side.x * s, 0, -side.y * s)
			var q := [Vector3(pa.x, ya - 0.3, pa.y), Vector3(pb.x, yb - 0.3, pb.y),
				Vector3(pb.x, yb + top_b, pb.y), Vector3(pa.x, ya + top_a, pa.y)]
			_s_quad(q[0], q[1], q[2], q[3], inward, TUNNEL_WALL, true)
			_s_quad(q[0], q[1], q[2], q[3], -inward, CONCRETE)  # outside, seen at portals
		if open:
			_open_segments.append({a = a, b = b, ha = ya, hb = yb, wall = wall, skip_l = skip[0], skip_r = skip[1]})
		var l0 := a + side * wall
		var l1 := b + side * wall
		var r0 := a - side * wall
		var r1 := b - side * wall
		if roof:
			var ca := ya + TUNNEL_HEIGHT
			var cb := yb + TUNNEL_HEIGHT
			var ceiling := [Vector3(l0.x, ca, l0.y), Vector3(l1.x, cb, l1.y), Vector3(r1.x, cb, r1.y), Vector3(r0.x, ca, r0.y)]
			_s_quad(ceiling[0], ceiling[1], ceiling[2], ceiling[3], Vector3.DOWN, TUNNEL_WALL)
			# The top is a deck just under the surface: buried under terrain, but where
			# the terrain beside a cutting is cut away it reads as street level, not as a
			# roof sunk metres below it.
			var da := maxf(ca, minf(height_at(l0), height_at(r0)) - DECK_DROP)
			var db := maxf(cb, minf(height_at(l1), height_at(r1)) - DECK_DROP)
			_s_quad(Vector3(l0.x, da, l0.y), Vector3(l1.x, db, l1.y), Vector3(r1.x, db, r1.y),
				Vector3(r0.x, da, r0.y), Vector3.UP, CONCRETE)
			for s: float in [1.0, -1.0]:
				var e0 := a + side * s * wall
				var e1 := b + side * s * wall
				if da > ca + 0.05 or db > cb + 0.05:
					_s_quad(Vector3(e0.x, ca, e0.y), Vector3(e1.x, cb, e1.y), Vector3(e1.x, db, e1.y),
						Vector3(e0.x, da, e0.y), Vector3(side.x * s, 0, side.y * s), CONCRETE)
		# Headwall where the roof begins or ends (a sunk tunnel's portals are its ends):
		# from the roof up past the ground.
		var start_portal := sunk and k == 1 and not _on_border(a)
		var end_portal := sunk and k == n - 1 and not _on_border(b)
		var entering := start_portal or (covered[k] and not covered[k - 1])
		var leaving := end_portal or (covered[k - 1] and not covered[k])
		if entering or leaving:
			var at := 0 if start_portal else (k if entering or end_portal else k - 1)
			var p := pts[at]
			var y0 := heights[at] + TUNNEL_HEIGHT
			var y1 := maxf(ground[at], y0) + 1.0
			var l := p + side * (wall + 1.0)
			var r := p - side * (wall + 1.0)
			var facing := Vector3(-dir.x, 0, -dir.y) if entering else Vector3(dir.x, 0, dir.y)
			var face := [Vector3(l.x, y0, l.y), Vector3(r.x, y0, r.y), Vector3(r.x, y1, r.y), Vector3(l.x, y1, l.y)]
			_s_quad(face[0], face[1], face[2], face[3], facing, CONCRETE)
			_s_quad(face[0], face[1], face[2], face[3], -facing, CONCRETE)
		# Volumes: one box per run, straight enough that it hugs a cutting's walls.
		var run_len := pts[run_start].distance_to(b)
		var bend := 0.0
		for m in range(run_start + 1, k):
			bend = maxf(bend, Geometry2D.get_closest_point_to_segment(pts[m], pts[run_start], b).distance_to(pts[m]))
		var full := run_len >= (60.0 if open else 30.0) or (open and bend > 0.5)
		if full or k == n - 1:
			var gap_limit := INF if open else (0.0 if sunk else 3.0)
			_add_tunnel_box(pts, heights, run_start, k, wall, gap_limit, skipped)
			run_start = k
			skipped = [false, false]
	# Keep trees and props off the tunnel approaches.
	var mask_cell := size / MASK_RES
	Raster.stroke_polyline(_mask, MASK_RES, MASK_RES, mask_cell, pts, wall + 2.0, 3)


const MEDIAN := 2.5  # how far past a left-out wall the shoulder and cut-away reach
const SHOULDER := Color(0.36, 0.36, 0.37)


## Bakes cut_mask from the open cutting segments (see cut_mask).
func _build_cut_mask() -> void:
	if _open_segments.is_empty():
		return
	var res := CUT_MASK_RES
	var texel := size / res
	var sd := PackedFloat32Array()
	sd.resize(res * res)
	sd.fill(100.0)
	var floor_h := PackedFloat32Array()
	floor_h.resize(res * res)
	floor_h.fill(0.0)
	cut_base = INF
	for seg in _open_segments:
		cut_base = minf(cut_base, minf(seg.ha, seg.hb))
	for seg in _open_segments:
		var a: Vector2 = seg.a
		var b: Vector2 = seg.b
		var ab := b - a
		var len2 := maxf(ab.length_squared(), 1e-6)
		var reach: float = seg.wall + MEDIAN + 3.0 * texel
		var i0 := maxi(0, floori((minf(a.x, b.x) - reach) / texel))
		var i1 := mini(res - 1, ceili((maxf(a.x, b.x) + reach) / texel))
		var j0 := maxi(0, floori((minf(a.y, b.y) - reach) / texel))
		var j1 := mini(res - 1, ceili((maxf(a.y, b.y) + reach) / texel))
		for j in range(j0, j1 + 1):
			for i in range(i0, i1 + 1):
				var p := Vector2((i + 0.5) * texel, (j + 0.5) * texel)
				var t := clampf((p - a).dot(ab) / len2, 0.0, 1.0)
				var q := a + ab * t
				var left := ab.x * (p.y - a.y) - ab.y * (p.x - a.x) > 0.0
				var edge: float = seg.wall + 0.15 + (MEDIAN if (seg.skip_l if left else seg.skip_r) else 0.0)
				var d := p.distance_to(q) - edge
				var v := j * res + i
				if d < sd[v]:
					sd[v] = d
					floor_h[v] = lerpf(seg.ha, seg.hb, t) - cut_base
	var data := PackedByteArray()
	data.resize(res * res * 4)
	for v in res * res:
		data.encode_half(v * 4, sd[v])
		data.encode_half(v * 4 + 2, floor_h[v])
	cut_mask = Image.create_from_data(res, res, false, Image.FORMAT_RGH, data)


## True if `p` lies on (or just beside) a road traced down into a cutting.
func _beside_cutting(p: Vector2) -> bool:
	for k: int in _cut_grid.get(Vector2i((p / CUT_GRID).floor()), PackedInt32Array()):
		var m := _cut_next[k]
		if _cut_depth[k] <= 0.5 and _cut_depth[m] <= 0.5:
			continue
		if Geometry2D.get_closest_point_to_segment(p, _cut_pts[k], _cut_pts[m]).distance_to(p) < _cut_hw[k] + 1.0:
			return true
	return false


## Removes heightmap collision over tunnel mouths. Jolt drops every cell touching a NaN
## vertex, so cells around each portal are knocked out and re-added as exact triangles,
## except those over the tube itself.
func _cut_portal_collision() -> void:
	if portal_boxes.is_empty() or collision.is_empty():
		return
	var inverse: Array[Transform3D] = []
	for box in portal_boxes:
		inverse.append(box.affine_inverse())
	# Terrain point within a tube's width and above its road (it would block the car).
	# Where the tunnel is still at grade the ground stays solid.
	var over_tube := func(p: Vector3) -> bool:
		var near_portal := false
		for inv in inverse:
			var q := inv * p
			if absf(q.x) <= 1.05 and absf(q.z) <= 1.05:
				near_portal = true
				break
		if not near_portal:
			return false
		var p2 := Vector2(p.x, p.z)
		for seg in _tunnel_segments:
			var a: Vector2 = seg.a
			var ab: Vector2 = seg.b - a
			var t := clampf((p2 - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
			if p2.distance_to(a + ab * t) > seg.wall + 0.3:
				continue
			var road: float = lerpf(seg.ha, seg.hb, t)
			if p.y > road + 0.3 and p.y < road + TUNNEL_HEIGHT + 3.0:
				return true
		return false
	var surface := func(x: float, z: float) -> Vector3:
		return Vector3(x, height_at(Vector2(x, z)), z)
	# Knock out every cell the tube passes under (sampled, since cells are ~19 m).
	var holes := _h.duplicate()
	# Only cells under a portal box's footprint can be affected.
	var near := {}  # cell index -> true
	for box in portal_boxes:
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for cx: float in [-1.0, 1.0]:
			for cz: float in [-1.0, 1.0]:
				var c := box * Vector3(cx, 0.0, cz)
				lo = lo.min(Vector2(c.x, c.z))
				hi = hi.max(Vector2(c.x, c.z))
		for j in range(maxi(floori(lo.y / _cell) - 1, 0), mini(ceili(hi.y / _cell) + 1, _n - 1)):
			for i in range(maxi(floori(lo.x / _cell) - 1, 0), mini(ceili(hi.x / _cell) + 1, _n - 1)):
				near[j * (_n - 1) + i] = true
	for key: int in near:
		var i := key % (_n - 1)
		var j := key / (_n - 1)
		var hit := false
		for sj in 5:
			for si in 5:
				if not hit and over_tube.call(surface.call((i + si / 4.0) * _cell, (j + sj / 4.0) * _cell)):
					hit = true
		if hit:
			for c in [j * _n + i, j * _n + i + 1, (j + 1) * _n + i + 1, (j + 1) * _n + i]:
				holes[c] = NAN
	# Jolt drops every cell touching a NaN vertex. Rebuild all of those from ~2 m
	# sub-triangles on the same surface, leaving out only the ones over a tube.
	var sub := ceili(_cell / 2.0)
	var step := _cell / sub
	for j in _n - 1:
		for i in _n - 1:
			var a := j * _n + i
			if not (is_nan(holes[a]) or is_nan(holes[a + 1]) or is_nan(holes[a + _n]) or is_nan(holes[a + _n + 1])):
				continue
			for sj in sub:
				for si in sub:
					var x0 := i * _cell + si * step
					var z0 := j * _cell + sj * step
					var p00: Vector3 = surface.call(x0, z0)
					var p10: Vector3 = surface.call(x0 + step, z0)
					var p11: Vector3 = surface.call(x0 + step, z0 + step)
					var p01: Vector3 = surface.call(x0, z0 + step)
					if not over_tube.call((p00 + p10 + p11) / 3.0):
						terrain_patch_faces.append_array([p00, p10, p11])
					if not over_tube.call((p00 + p11 + p01) / 3.0):
						terrain_patch_faces.append_array([p00, p11, p01])
	collision.collision_heights = holes


## `gap_limit`: the box is a portal (terrain inside it is cut away) where the roof comes
## within this of the surface. `skipped` [left, right]: walls left out beside another
## cutting, where the box reaches further to clear the ground in between.
func _add_tunnel_box(pts: PackedVector2Array, heights: PackedFloat32Array, i0: int, i1: int,
		wall: float, gap_limit := 3.0, skipped := [false, false]) -> void:
	var a := pts[i0]
	var b := pts[i1]
	var y_lo := INF
	var y_hi := -INF
	var surface_gap := INF  # smallest distance from the tunnel ceiling up to the terrain
	for k in range(i0, i1 + 1):
		y_lo = minf(y_lo, heights[k])
		y_hi = maxf(y_hi, heights[k])
		surface_gap = minf(surface_gap, height_at(pts[k]) - (heights[k] + TUNNEL_HEIGHT))
	var dir := (b - a).normalized()
	var left := Vector2(-dir.y, dir.x)
	var open := is_inf(gap_limit)
	var extra_l := MEDIAN if skipped[0] else 0.0
	var extra_r := MEDIAN if skipped[1] else 0.0
	var centre2 := (a + b) * 0.5 + left * (extra_l - extra_r) * 0.5
	# Exactly the run's length: past the ends the approach road relies on terrain collision.
	var x := Vector3(dir.x, 0, dir.y) * (a.distance_to(b) * 0.5)
	var z := Vector3(left.x, 0, left.y) * ((wall + 0.3 if open else wall + 1.0) + (extra_l + extra_r) * 0.5)
	var y := Vector3.UP * ((y_hi - y_lo) * 0.5 + TUNNEL_HEIGHT * 0.5 + 1.5)
	var centre := Vector3(centre2.x, (y_lo + y_hi) * 0.5 + TUNNEL_HEIGHT * 0.5, centre2.y)
	if open:
		# Reach up past the top of the deepest cutting.
		y = Vector3.UP * ((y_hi - y_lo) * 0.5 + (TUNNEL_COVER + 4.0) * 0.5 + 1.5)
		centre.y = (y_lo + y_hi) * 0.5 + (TUNNEL_COVER + 4.0) * 0.5
	var box := Transform3D(Basis(x, y, z), centre)
	tunnel_boxes.append(box)
	if surface_gap < gap_limit:
		portal_boxes.append(box)
		if not open:
			mouth_boxes.append(box)  # cuttings are cut away by cut_mask instead


## Mapped trees and street lamps at their real positions. Lamps face the nearest road;
## trees use the same species mix as scattered ones.
func _place_mapped() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = _seed ^ 0x5eed
	var rules := _scatter_rules()
	var trees := "tree_broadleaf"
	for role: String in rules.get(Cls.PARK, [0, {}])[1]:
		if role.begins_with("tree"):
			trees = role
			break
	for p in _osm_trees:
		if not _road_under(p).is_empty() or not is_nan(_cut_floor_at(p)):
			continue  # our roads are wider than the real ones: keep trees off them
		var s := rng.randf_range(0.9, 1.3)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s, s))
		_add_instance(trees, Transform3D(basis, Vector3(p.x, height_at(p) - 0.15, p.y)))
	if _osm_lamps.size() < MIN_MAPPED_LAMPS:
		return
	for lamp in _osm_lamps:
		var p := lamp
		# Lamps in a (narrower) real central reservation would stand in our lanes.
		var under := _road_under(p)
		if not under.is_empty():
			var q: Vector2 = under[0]
			var out := (p - q).normalized() if p.distance_to(q) > 0.1 else Vector2.RIGHT
			p = q + out * (under[1] + 0.6)
		var floor_h := _cut_floor_at(p)
		var y := floor_h + 0.1 if not is_nan(floor_h) else height_at(p) + RoadNetwork.KERB
		var arm := _towards_nearest_road(p)
		var basis := Basis(arm, Vector3.UP, arm.cross(Vector3.UP))
		_add_instance("lamp_road", Transform3D(basis, Vector3(p.x, y, p.y)))


## The drivable road whose surface covers `p`: [closest centreline point, half width],
## or [] if none does.
func _road_under(p: Vector2) -> Array:
	var mask_cell := size / MASK_RES
	var ci := int(p.x / mask_cell)
	var cj := int(p.y / mask_cell)
	var candidates := {}
	for j in range(maxi(cj - 1, 0), mini(cj + 2, MASK_RES)):
		for i in range(maxi(ci - 1, 0), mini(ci + 2, MASK_RES)):
			if _road_owner[j * MASK_RES + i] != 0:
				candidates[_road_owner[j * MASK_RES + i] - 1] = true
	for idx: int in candidates:
		var road: Dictionary = _road_lines[idx]
		var hw: float = ROADS[road.cls][0]
		var line: PackedVector2Array = road.pts
		for k in range(1, line.size()):
			var q := Geometry2D.get_closest_point_to_segment(p, line[k - 1], line[k])
			if p.distance_to(q) < hw + 0.3:
				return [q, hw]
	return []


## Floor height of the cutting at `p`, or NAN outside cuttings.
func _cut_floor_at(p: Vector2) -> float:
	for k: int in _cut_grid.get(Vector2i((p / CUT_GRID).floor()), PackedInt32Array()):
		var a := _cut_pts[k]
		var b := _cut_pts[_cut_next[k]]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var depth := lerpf(_cut_depth[k], _cut_depth[_cut_next[k]], a.distance_to(q) / maxf(a.distance_to(b), 0.001))
		if depth > 0.05 and p.distance_to(q) < _cut_hw[k] + 0.8:
			return _dem_at(q) - depth
	return NAN


## Unit vector (x/z) from p towards the closest road centreline (any if none nearby).
func _towards_nearest_road(p: Vector2) -> Vector3:
	var best := 40.0
	var dir := Vector2.RIGHT
	for road in _road_lines:
		if ROADS[road.cls][1] < DRIVABLE_RANK:
			continue
		var line: PackedVector2Array = road.pts
		for k in range(1, line.size()):
			var q := Geometry2D.get_closest_point_to_segment(p, line[k - 1], line[k])
			var d := p.distance_to(q)
			if d < best and d > 0.1:
				best = d
				dir = (q - p) / d
	return Vector3(dir.x, 0, dir.y)


## Street lamps on alternating sides; the model's arm points along +x.
func _place_lamps(pts: PackedVector2Array, heights: PackedFloat32Array, hw: float, lift: float,
		paved: bool) -> void:
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
		var y := heights[k] + RoadNetwork.KERB if paved else heights[k] - lift
		_add_instance("lamp_road", Transform3D(basis, Vector3(p.x, y, p.y)))


## Parked cars along urban side streets and street furniture on the pavement. (Junction
## signs and signals come from RoadNetwork.)
func _place_street_props(pts: PackedVector2Array, heights: PackedFloat32Array, hw: float,
		lift: float, rank: int, road_idx: int, parking: bool) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(pts[0]) ^ _seed
	var mask_cell := size / MASK_RES
	var total := 0.0
	var dist := PackedFloat32Array([0.0])
	for k in range(1, pts.size()):
		total += pts[k].distance_to(pts[k - 1])
		dist.append(total)
	var sample := func(d: float) -> Array:  # [point, direction, ground height] at distance d
		var k := clampi(dist.bsearch(d), 1, pts.size() - 1)
		var t := clampf((d - dist[k - 1]) / maxf(dist[k] - dist[k - 1], 0.001), 0.0, 1.0)
		var dir := (pts[k] - pts[k - 1]).normalized()
		return [pts[k - 1].lerp(pts[k], t), dir, lerpf(heights[k - 1], heights[k], t) - lift]
	var free_spot := func(p: Vector2) -> bool:
		var mi := clampi(int(p.x / mask_cell), 0, MASK_RES - 1)
		var mj := clampi(int(p.y / mask_cell), 0, MASK_RES - 1)
		return _mask[mj * MASK_RES + mi] == 0 and p.x > 0.0 and p.y > 0.0 and p.x < size and p.y < size
	var urban := _class_at(pts[pts.size() / 2]) == Cls.URBAN
	# Parked cars sit just inside the road edge, facing the direction of traffic.
	if urban and parking and (rank == 4 or rank == 5) and total > 40.0:
		for side: float in [1.0, -1.0]:
			var d := 12.0 + rng.randf() * 6.0
			while d < total - 12.0:
				if rng.randf() < 0.55:
					var s: Array = sample.call(d)
					var fwd: Vector2 = s[1]
					var nrm := Vector2(-fwd.y, fwd.x) * side
					var p: Vector2 = s[0] + nrm * (hw - 1.1)
					if not _near_other_road(p, road_idx, 4.0) and not _on_roundabout(p) and not _near_junction(p):
						var facing := fwd * side * (-1.0 if RegionStyle.left_hand_traffic(region) else 1.0)
						_add_instance(RegionStyle.parked_car_role(region), _facing(Vector3(p.x, s[2] + lift, p.y), facing))
				d += rng.randf_range(6.5, 9.0)
	# Hydrants, bins, benches and mailboxes on the pavement.
	if urban and rank >= 4 and rank <= 7:
		var d := rng.randf() * 20.0
		while d < total:
			var s: Array = sample.call(d)
			var fwd: Vector2 = s[1]
			var side := 1.0 if rng.randf() < 0.5 else -1.0
			var nrm := Vector2(-fwd.y, fwd.x) * side
			var p: Vector2 = s[0] + nrm * (hw + 1.4)
			if free_spot.call(p + nrm * 0.8) and not _on_roundabout(p) and not _near_junction(p):
				var y: float = s[2] + lift + RoadNetwork.KERB  # on the pavement
				_add_instance(RegionStyle.street_furniture_role(region), _facing(Vector3(p.x, y, p.y), -nrm))
			d += rng.randf_range(15.0, 35.0)


## Transform at `pos` whose +Z (the pack models' front) points along `dir`.
static func _facing(pos: Vector3, dir: Vector2) -> Transform3D:
	var z := Vector3(dir.x, 0.0, dir.y).normalized()
	return Transform3D(Basis(Vector3.UP.cross(z), Vector3.UP, z), pos)


func _class_at(p: Vector2) -> int:
	var i := clampi(roundi(p.x / _cell), 0, _n - 1)
	var j := clampi(roundi(p.y / _cell), 0, _n - 1)
	return _class[j * _n + i]


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


func _near_junction(p: Vector2) -> bool:
	var mask_cell := size / MASK_RES
	var i := clampi(int(p.x / mask_cell), 0, MASK_RES - 1)
	var j := clampi(int(p.y / mask_cell), 0, MASK_RES - 1)
	return _no_park[j * MASK_RES + i] != 0


func _on_roundabout(p: Vector2) -> bool:
	for r in _rings:
		if p.distance_to(Vector2(r.x, r.y)) < r.z + 4.0:
			return true
	return false


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
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var rect := PackedVector2Array([Vector2.ZERO, Vector2(size, 0), Vector2(size, size), Vector2(0, size)])
	var k := _to_local("building") if _layers.has("building") else 1.0
	if building_faces.is_empty():
		building_faces.resize(BLOCKS * BLOCKS)
	var local_heights := _known_height_medians(k)
	for f: Dictionary in _features("building"):
		if f.tags.get("hide_3d", false):
			continue
		var tagged := float(f.tags.get("render_height", UNKNOWN_HEIGHT))
		var min_h := float(f.tags.get("render_min_height", 0.0))
		var osm_colour: Variant = _parse_colour(f.tags.get("colour"))
		for ring: PackedVector2Array in f.rings:
			if MVTDecoder.ring_area(ring) <= 0.0:
				continue  # hole
			var poly := _scale_ring(ring, k)
			if poly.size() > 1 and poly[0] == poly[poly.size() - 1]:
				poly.remove_at(poly.size() - 1)
			# Keyed on absolute position so both tiles sharing a building agree.
			var key := _abs_key(poly[0])
			var height := maxf(tagged, 3.0)
			if tagged == UNKNOWN_HEIGHT and min_h == 0.0:
				height = _estimate_height(poly, key, local_heights)
			for piece: PackedVector2Array in Geometry2D.intersect_polygons(poly, rect):
				if absf(MVTDecoder.ring_area(piece)) < 12.0:
					continue
				var color := RegionStyle.wall_colour(region, height, key)
				if osm_colour != null:
					color = osm_colour
				_extrude(piece, min_h, height, color, key, verts, normals, colors, uvs, uv2s)
	buildings = {vertices = verts, normals = normals, colors = colors, uvs = uvs, uv2s = uv2s}


## OpenMapTiles fills in exactly 5 m when OSM has neither height nor levels.
const UNKNOWN_HEIGHT := 5.0
const HEIGHT_CELLS := 8  # neighbourhood grid for height estimates (~240 m cells)


## Median of the real (tagged) heights in each neighbourhood cell; -1 where none.
func _known_height_medians(k: float) -> PackedFloat32Array:
	var buckets := []
	buckets.resize(HEIGHT_CELLS * HEIGHT_CELLS)
	for b in buckets.size():
		buckets[b] = []
	for f: Dictionary in _features("building"):
		var h := float(f.tags.get("render_height", UNKNOWN_HEIGHT))
		if h == UNKNOWN_HEIGHT or h < 3.0 or float(f.tags.get("render_min_height", 0.0)) > 0.0:
			continue
		for ring: PackedVector2Array in f.rings:
			if MVTDecoder.ring_area(ring) > 0.0:
				buckets[_height_cell(ring[0] * k)].append(h)
	var medians := PackedFloat32Array()
	medians.resize(buckets.size())
	for b in buckets.size():
		var list: Array = buckets[b]
		list.sort()
		medians[b] = list[list.size() / 2] if list.size() >= 3 else -1.0
	return medians


func _height_cell(p: Vector2) -> int:
	var cell := size / HEIGHT_CELLS
	return clampi(int(p.y / cell), 0, HEIGHT_CELLS - 1) * HEIGHT_CELLS \
		+ clampi(int(p.x / cell), 0, HEIGHT_CELLS - 1)


## Height for a building OSM has no height for: like its tagged neighbours if there
## are any (with some variation), otherwise from footprint size.
func _estimate_height(poly: PackedVector2Array, key: int, medians: PackedFloat32Array) -> float:
	var rnd := (key % 1000) / 1000.0
	var cell := _height_cell(poly[0])
	var near := -1.0
	var ci := cell % HEIGHT_CELLS
	var cj := cell / HEIGHT_CELLS
	for r in 2:  # this cell, then the ring around it
		var vals := PackedFloat32Array()
		for dj in range(-r, r + 1):
			for di in range(-r, r + 1):
				var i := ci + di
				var j := cj + dj
				if i >= 0 and j >= 0 and i < HEIGHT_CELLS and j < HEIGHT_CELLS and medians[j * HEIGHT_CELLS + i] > 0.0:
					vals.append(medians[j * HEIGHT_CELLS + i])
		if not vals.is_empty():
			vals.sort()
			near = vals[vals.size() / 2]
			break
	if near > 0.0:
		return clampf(near * lerpf(0.8, 1.2, rnd), 3.5, 60.0)
	var area := absf(MVTDecoder.ring_area(poly))
	if area < 40.0:
		return 3.5  # sheds, garages
	if area < 250.0:
		return lerpf(6.0, 9.0, rnd)  # houses
	return lerpf(9.0, 16.0, rnd)


## Stable non-negative hash of a chunk-local point in absolute (mercator) metres.
func _abs_key(p: Vector2) -> int:
	return absi(hash(Vector2i(roundi(_merc0[0] + p.x / _scale), roundi(_merc0[1] - p.y / _scale))))


## OSM building colour (hex or CSS name), toned down so white walls don't blow out.
static func _parse_colour(value: Variant) -> Variant:
	if value == null:
		return null
	var c := Color.from_string(str(value), Color(-1, -1, -1))
	if c.r < 0.0:
		return null
	var v := c.v
	if v > 0.82:
		c.v = 0.82
	elif v < 0.18:
		c.v = 0.18
	return c


const BAY := 3.0  # target window bay width (m)
const BAY_MIN := 1.6  # walls shorter than this get no windows


## Walls get UV = (window bays along the wall, metres above ground) for the facade
## shader; UV2 = (building height, bays + per-building random fraction);
## COLOR.a = 1 walls, 0 roof.
func _extrude(poly: PackedVector2Array, min_h: float, height: float, color: Color, key: int,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		uvs: PackedVector2Array, uv2s: PackedVector2Array) -> void:
	# Floors count from the uphill side (capped for big footprints on steep slopes);
	# downhill, the wall runs down to the ground as a windowless base.
	var g_min := INF
	var g_max := -INF
	for p in poly:
		var g := height_at(p)
		g_min = minf(g_min, g)
		g_max = maxf(g_max, g)
	var ground := minf(g_max, g_min + 6.0)
	var bottom := (g_min - 2.0) if min_h == 0.0 else ground + min_h
	var top := ground + height
	var regional_roof: Variant = RegionStyle.roof_colour(region, height)
	var roof: Color = regional_roof if regional_roof != null else color.darkened(0.35)
	roof.a = 0.0
	color.a = 1.0
	var rnd := (key % 1000) / 1000.0
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
		var len := edge.length()
		# Each wall holds a whole number of window bays (none on slivers), so windows
		# never straddle a corner. UV.x runs 0..bays along the wall; the bay count
		# rides in UV2.y's integer part, the building's random number in its fraction.
		var bays := 0 if len < BAY_MIN else maxi(1, roundi(len / BAY))
		var info := Vector2(height - min_h, bays + 0.05 + rnd * 0.9)
		var v0 := bottom - ground - min_h
		var v1 := height - min_h
		var ua0 := Vector2(0, v0)
		var ub0 := Vector2(bays, v0)
		var ua1 := Vector2(0, v1)
		var ub1 := Vector2(bays, v1)
		_tri(a0, b0, b1, nrm, color, verts, normals, colors, uvs, uv2s, [ua0, ub0, ub1], info)
		_tri(a0, b1, a1, nrm, color, verts, normals, colors, uvs, uv2s, [ua0, ub1, ua1], info)
		var bs := size / BLOCKS
		var block := clampi(int(a.y / bs), 0, BLOCKS - 1) * BLOCKS + clampi(int(a.x / bs), 0, BLOCKS - 1)
		building_faces[block].append_array([a0, b0, b1, a0, b1, a1])
	var idx := Geometry2D.triangulate_polygon(poly)
	var roof_info := Vector2(height - min_h, 0.05 + rnd * 0.9)
	for t in range(0, idx.size(), 3):
		var p0 := poly[idx[t]]
		var p1 := poly[idx[t + 1]]
		var p2 := poly[idx[t + 2]]
		_tri(Vector3(p0.x, top, p0.y), Vector3(p1.x, top, p1.y), Vector3(p2.x, top, p2.y),
			Vector3.UP, roof, verts, normals, colors, uvs, uv2s, [p0, p1, p2], roof_info)


## Appends a triangle facing `nrm` (Godot front faces are clockwise).
static func _tri(a: Vector3, b: Vector3, c: Vector3, nrm: Vector3, color: Color,
		verts: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		uvs: PackedVector2Array, uv2s: PackedVector2Array, tri_uv: Array, info: Vector2) -> void:
	if (b - a).cross(c - a).dot(nrm) > 0.0:
		verts.append_array([a, c, b])
		uvs.append_array([tri_uv[0], tri_uv[2], tri_uv[1]])
	else:
		verts.append_array([a, b, c])
		uvs.append_array([tri_uv[0], tri_uv[1], tri_uv[2]])
	normals.append_array([nrm, nrm, nrm])
	colors.append_array([color, color, color])
	uv2s.append_array([info, info, info])


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
		Cls.PARK: [0.25, {trees: 4, "bush": 2, "park_furniture": 0.6}],
		Cls.SAND: [0.03, {"rock": 1, ("tree_palm" if alat < 35.0 else "bush"): 1}],
		Cls.URBAN: [0.06, {trees: 3, "bush": 1}],
		Cls.WETLAND: [0.2, {"bush": 3, trees: 1}],
		Cls.ROCK: [0.15, {"rock": 1}],
	}


func _build_scatter() -> void:
	_place_mapped()
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
