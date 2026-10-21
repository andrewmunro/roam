class_name WorldStreamer
extends Node3D
## Keeps rings of chunks around a target node: full detail within FULL_RADIUS tiles,
## terrain-only out to FAR_RADIUS. Handles fetching, (threaded or time-sliced)
## building, unloading and floating-origin shifts.

signal chunk_ready(chunk: Chunk)

const TILEJSON_URL := "https://tiles.openfreemap.org/planet"
const FULL_RADIUS := 1
const FAR_RADIUS := 2
const UNLOAD_RADIUS := 3
const REBASE_DISTANCE := 2000.0
const FRAME_BUDGET_USEC := 4000
## Longest a full chunk waits for Overpass junction data before guessing instead.
const OSM_WAIT := 1.0  # then build with guessed signals; real data rebuilds the chunk later

@export var target: Node3D

var elevation := ElevationSource.new()
var osm_points := OsmPoints.new()
var _tile_url := ""
var _chunks := {}  # Vector2i -> Chunk (shown)
var _jobs := {}  # Vector2i -> {lod, state, builder, task, chunk, generation}
var _generation := 0
var _use_threads := false
var _target_tile := Vector2i(-1, -1)


func _ready() -> void:
	_use_threads = OS.get_processor_count() > 1 and (not OS.has_feature("web") or OS.has_feature("threads"))
	if OS.has_environment("ROAM_NO_THREADS"):
		_use_threads = false
	Geo.origin_shifted.connect(_on_origin_shifted)
	osm_points.attach(self)
	osm_points.tile_loaded.connect(_on_osm_tile)
	Fetch.request(TILEJSON_URL, _on_tilejson, -1.0, false)


func _on_tilejson(ok: bool, body: PackedByteArray) -> void:
	if ok:
		var json: Variant = JSON.parse_string(body.get_string_from_utf8())
		if json is Dictionary and json.has("tiles"):
			_tile_url = json.tiles[0]
	if _tile_url.is_empty():
		push_error("Could not load TileJSON from %s; retrying" % TILEJSON_URL)
		get_tree().create_timer(3.0).timeout.connect(
			func() -> void: Fetch.request(TILEJSON_URL, _on_tilejson, -1.0, false))


## Drops every chunk (used when teleporting / after Geo.set_origin).
func reset() -> void:
	_generation += 1
	Fetch.cancel_queued()
	osm_points.cancel_queued()
	for c: Chunk in _chunks.values():
		c.queue_free()
	_chunks.clear()
	for job: Dictionary in _jobs.values():
		if job.chunk:
			job.chunk.queue_free()
	_jobs.clear()
	_target_tile = Vector2i(-1, -1)


func chunk_at(local_pos: Vector3) -> Chunk:
	var t := Geo.local_to_tile(local_pos, Geo.CHUNK_ZOOM)
	var c: Chunk = _chunks.get(t)
	if c and c.lod == ChunkBuilder.Lod.FULL:
		return c
	return null


## True if the position is inside any tunnel volume (this tile or a neighbour, since
## boxes can poke slightly over a tile edge).
func in_tunnel_box(global_pos: Vector3) -> bool:
	var t := Geo.local_to_tile(global_pos, Geo.CHUNK_ZOOM)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c: Chunk = _chunks.get(t + Vector2i(dx, dy))
			if c and not c.tunnel_boxes.is_empty() and c.in_tunnel_box(global_pos - c.position):
				return true
	return false


## True if the position is in a tunnel and under the ground (so a surface road running
## alongside a portal doesn't count).
func in_tunnel(global_pos: Vector3) -> bool:
	if not in_tunnel_box(global_pos):
		return false
	var c: Chunk = _chunks.get(Geo.local_to_tile(global_pos, Geo.CHUNK_ZOOM))
	if c == null:
		return true
	var local := global_pos - c.position
	return c.terrain_height(Vector2(local.x, local.z)) > global_pos.y + 0.3


const AREA_CLASSES := ["suburb", "quarter", "neighbourhood", "village", "hamlet", "isolated_dwelling"]
const SETTLEMENT_CLASSES := ["city", "town", "village"]


## Where the position is: {road, area, settlement}. Road is the nearest named road
## within 25 m; area the nearest suburb/neighbourhood point; settlement the nearest
## city/town among loaded chunks (may be empty).
func describe(global_pos: Vector3) -> Dictionary:
	var out := {road = "", area = "", settlement = ""}
	var best_road := 25.0
	var best_area := 2500.0
	var best_town := INF
	var t := Geo.local_to_tile(global_pos, Geo.CHUNK_ZOOM)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var c: Chunk = _chunks.get(t + Vector2i(dx, dy))
			if c == null:
				continue
			var local := global_pos - c.position
			var p := Vector2(local.x, local.z)
			for r: Dictionary in c.road_names:
				var pts: PackedVector2Array = r.pts
				for k in range(1, pts.size()):
					var d := p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[k - 1], pts[k]))
					if d < best_road:
						best_road = d
						out.road = r.name if r.ref.is_empty() else ("%s (%s)" % [r.name, r.ref] if not r.name.is_empty() else r.ref)
			for pl: Dictionary in c.places:
				var d: float = p.distance_to(pl.pos)
				if pl.cls in AREA_CLASSES and d < best_area:
					best_area = d
					out.area = pl.name
				if pl.cls in SETTLEMENT_CLASSES and d < best_town:
					best_town = d
					out.settlement = pl.name
	return out


func is_loading() -> bool:
	return not _jobs.is_empty()


func _process(_delta: float) -> void:
	if target == null or _tile_url.is_empty():
		return
	var pos := target.global_position
	if Vector2(pos.x, pos.z).length() > REBASE_DISTANCE:
		Geo.shift_origin(pos)
		pos = target.global_position
	var t := Geo.local_to_tile(pos, Geo.CHUNK_ZOOM)
	if t != _target_tile:
		_target_tile = t
		_update_rings()
	_run_jobs()


func _ring_dist(t: Vector2i) -> int:
	return maxi(absi(t.x - _target_tile.x), absi(t.y - _target_tile.y))


func _update_rings() -> void:
	for dy in range(-FAR_RADIUS, FAR_RADIUS + 1):
		for dx in range(-FAR_RADIUS, FAR_RADIUS + 1):
			var t := _target_tile + Vector2i(dx, dy)
			var want := ChunkBuilder.Lod.FULL if maxi(absi(dx), absi(dy)) <= FULL_RADIUS else ChunkBuilder.Lod.HORIZON
			var shown: Chunk = _chunks.get(t)
			if shown and (shown.lod == want or shown.lod == ChunkBuilder.Lod.FULL):
				continue
			if _jobs.has(t) and (_jobs[t].lod == want or _jobs[t].lod == ChunkBuilder.Lod.FULL):
				continue
			_start_job(t, want)
	for t: Vector2i in _chunks.keys():
		if _ring_dist(t) > UNLOAD_RADIUS:
			_chunks[t].queue_free()
			_chunks.erase(t)
	for t: Vector2i in _jobs.keys():
		if _ring_dist(t) > UNLOAD_RADIUS and _jobs[t].task == -1:
			if _jobs[t].chunk:
				_jobs[t].chunk.queue_free()
			_jobs.erase(t)
	# Drop elevation tiles no longer near anything we keep.
	var keep := {}
	for t: Vector2i in _chunks.keys() + _jobs.keys():
		var lod: int = _jobs[t].lod if _jobs.has(t) else _chunks[t].lod
		for e in _elevation_tiles(t, 1 if lod == ChunkBuilder.Lod.FULL else 0):
			keep[e] = true
	elevation.forget_far(keep)


## Elevation tiles covering the chunk plus `ring` chunks around it (full chunks profile
## bridges and tunnels across their neighbours).
func _elevation_tiles(t: Vector2i, ring := 0) -> Array[Vector2i]:
	var m := Geo.tile_origin_merc(t, Geo.CHUNK_ZOOM)
	var s := Geo.tile_size_merc(Geo.CHUNK_ZOOM)
	return ElevationSource.tiles_for_rect(m[0] - ring * s, m[1] - s - ring * s,
		m[0] + s + ring * s, m[1] + ring * s)


func _start_job(t: Vector2i, lod: ChunkBuilder.Lod) -> void:
	var gen := _generation
	var full := lod == ChunkBuilder.Lod.FULL
	var job := {lod = lod, state = "fetch", builder = null, task = -1, chunk = null,
		mvt = PackedByteArray(), neighbours = {}, waiting = 11 if full else 1}
	_jobs[t] = job
	var priority := float(_ring_dist(t)) + (0.0 if lod == ChunkBuilder.Lod.FULL else 0.5)
	var arrived := func() -> void:
		if gen != _generation or not is_same(_jobs.get(t), job):
			return
		job.waiting -= 1
		if job.waiting == 0:
			var tiles := _elevation_tiles(t, 1 if full else 0)
			var osm := osm_points.snapshot(_osm_tiles(t)) if full else {}
			job.builder = ChunkBuilder.new(t, lod, job.mvt, elevation.snapshot(tiles), job.neighbours, osm)
			job.mvt = PackedByteArray()
			job.neighbours = {}
			job.state = "build"
			if _use_threads:
				job.task = WorkerThreadPool.add_task(job.builder.run_all, false, "chunk %s" % t)
	elevation.ensure(_elevation_tiles(t, 1 if full else 0), priority, arrived)
	if full:
		# Signals and mini-roundabouts; don't hold the chunk up for long if Overpass is slow.
		var osm_done := [false]
		var osm_arrived := func() -> void:
			if not osm_done[0]:
				osm_done[0] = true
				arrived.call()
		osm_points.ensure(_osm_tiles(t), osm_arrived)
		get_tree().create_timer(OSM_WAIT).timeout.connect(osm_arrived)
		Fetch.request(_mvt_url(t), func(ok: bool, body: PackedByteArray) -> void:
			if ok:
				job.mvt = body
			arrived.call(), priority)
		# Neighbours' roads, so bridges and tunnels can be followed across tile edges.
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var offset := Vector2i(dx, dy)
				Fetch.request(_mvt_url(t + offset), func(ok: bool, body: PackedByteArray) -> void:
					if ok:
						job.neighbours[offset] = body
					arrived.call(), priority + 0.3)


## Overpass tiles covering a chunk and the margin RoadNetwork looks into.
func _osm_tiles(t: Vector2i) -> Array[Vector2i]:
	var m := Geo.tile_origin_merc(t, Geo.CHUNK_ZOOM)
	var s := Geo.tile_size_merc(Geo.CHUNK_ZOOM)
	var pad := RoadNetwork.MARGIN / Geo.scale
	return OsmPoints.tiles_for_rect(m[0] - pad, m[1] - s - pad, m[0] + s + pad, m[1] + pad)


func _mvt_url(t: Vector2i) -> String:
	var n := 1 << Geo.CHUNK_ZOOM
	return _tile_url.replace("{z}", str(Geo.CHUNK_ZOOM)) \
		.replace("{x}", str(posmod(t.x, n))).replace("{y}", str(clampi(t.y, 0, n - 1)))


func _run_jobs() -> void:
	var start := Time.get_ticks_usec()
	# Nearest jobs first so the area under the player is ready soonest.
	var order := _jobs.keys()
	order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _ring_dist(a) < _ring_dist(b))
	for t: Vector2i in order:
		var job: Dictionary = _jobs[t]
		while Time.get_ticks_usec() - start < FRAME_BUDGET_USEC:
			if job.state == "build":
				if job.task != -1:
					if not WorkerThreadPool.is_task_completed(job.task):
						break
					WorkerThreadPool.wait_for_task_completion(job.task)
					job.task = -1
					job.state = "finalize"
				elif job.builder.step():
					job.state = "finalize"
			elif job.state == "finalize":
				if job.chunk == null:
					job.chunk = Chunk.new()
					job.chunk.setup(job.builder)
					job.chunk.visible = false
					add_child(job.chunk)
					job.chunk.position = Geo.tile_origin_local(t, Geo.CHUNK_ZOOM)
				if job.chunk.finalize_step():
					_complete(t, job)
					break
			else:
				break
		if Time.get_ticks_usec() - start >= FRAME_BUDGET_USEC:
			return


func _complete(t: Vector2i, job: Dictionary) -> void:
	_jobs.erase(t)
	var old: Chunk = _chunks.get(t)
	if old:
		old.queue_free()
	var chunk: Chunk = job.chunk
	chunk.visible = true
	_chunks[t] = chunk
	chunk_ready.emit(chunk)


## Overpass data arrived late: rebuild full chunks that had to guess their junctions.
func _on_osm_tile(_osm_tile: Vector2i) -> void:
	for t: Vector2i in _chunks:
		var c: Chunk = _chunks[t]
		if c.lod == ChunkBuilder.Lod.FULL and not c.osm_complete and not _jobs.has(t) 				and osm_points.has_all(_osm_tiles(t)):
			_start_job(t, ChunkBuilder.Lod.FULL)


func _on_origin_shifted(offset: Vector3) -> void:
	for c: Chunk in _chunks.values():
		c.position -= offset
	for job: Dictionary in _jobs.values():
		if job.chunk:
			job.chunk.position -= offset
	if target:
		target.global_position -= offset
