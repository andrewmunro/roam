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

@export var target: Node3D

var elevation := ElevationSource.new()
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
		for e in _elevation_tiles(t):
			keep[e] = true
	elevation.forget_far(keep)


func _elevation_tiles(t: Vector2i) -> Array[Vector2i]:
	var m := Geo.tile_origin_merc(t, Geo.CHUNK_ZOOM)
	var s := Geo.tile_size_merc(Geo.CHUNK_ZOOM)
	return ElevationSource.tiles_for_rect(m[0], m[1] - s, m[0] + s, m[1])


func _start_job(t: Vector2i, lod: ChunkBuilder.Lod) -> void:
	var gen := _generation
	var job := {lod = lod, state = "fetch", builder = null, task = -1, chunk = null,
		mvt = PackedByteArray(), waiting = 1 if lod == ChunkBuilder.Lod.HORIZON else 2}
	_jobs[t] = job
	var priority := float(_ring_dist(t)) + (0.0 if lod == ChunkBuilder.Lod.FULL else 0.5)
	var arrived := func() -> void:
		if gen != _generation or not is_same(_jobs.get(t), job):
			return
		job.waiting -= 1
		if job.waiting == 0:
			var tiles := _elevation_tiles(t)
			job.builder = ChunkBuilder.new(t, lod, job.mvt, elevation.snapshot(tiles))
			job.mvt = PackedByteArray()
			job.state = "build"
			if _use_threads:
				job.task = WorkerThreadPool.add_task(job.builder.run_all, false, "chunk %s" % t)
	elevation.ensure(_elevation_tiles(t), priority, arrived)
	if lod == ChunkBuilder.Lod.FULL:
		var n := 1 << Geo.CHUNK_ZOOM
		var url := _tile_url.replace("{z}", str(Geo.CHUNK_ZOOM)) \
			.replace("{x}", str(posmod(t.x, n))).replace("{y}", str(clampi(t.y, 0, n - 1)))
		Fetch.request(url, func(ok: bool, body: PackedByteArray) -> void:
			if ok:
				job.mvt = body
			arrived.call(), priority)


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


func _on_origin_shifted(offset: Vector3) -> void:
	for c: Chunk in _chunks.values():
		c.position -= offset
	for job: Dictionary in _jobs.values():
		if job.chunk:
			job.chunk.position -= offset
	if target:
		target.global_position -= offset
