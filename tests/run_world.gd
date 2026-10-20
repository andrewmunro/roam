extends Node
## Loads the main scene, lets it stream, and reports progress. Optionally drives
## forward and saves screenshots (when not headless).
## Run: godot --path . res://tests/run_world.tscn [-- --shots=dir --drive]

var _main: Node
var _t := 0.0
var _next_report := 0.0
var _shots := ""
var _drive := false
var _drive_after := 0.0
var _report_every := 5.0
var _topdown := 0.0
var _checked := false
var _rebase_test := false
var _rebase_stage := 0
var _rebase_latlon := Vector2.ZERO
var _shot_idx := 0
var _max_frame_ms := 0.0
var _last := 0

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
		elif a == "--rebase-test":
			_rebase_test = true
		elif a == "--drive":
			_drive = true
		elif a.begins_with("--drive-after="):
			_drive_after = a.substr(14).to_float()
		elif a.begins_with("--topdown="):
			_topdown = a.substr(10).to_float()
		elif a.begins_with("--every="):
			_report_every = a.substr(8).to_float()
	_main = load("res://scenes/main.tscn").instantiate()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--latlon="):
			var ll := a.substr(9).split(",")
			_main.start_lat = ll[0].to_float()
			_main.start_lon = ll[1].to_float()
			_main.start_label = a.substr(9)
	add_child(_main)
	_last = Time.get_ticks_usec()

func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_ms := (now - _last) / 1000.0
	_last = now
	if _t > 1.0:
		_max_frame_ms = maxf(_max_frame_ms, frame_ms)
	_t += delta
	var car: Car = _main.get_node("Car")
	if _drive and not car.freeze and _t > _drive_after:
		Input.action_press("accelerate")
	if _rebase_test:
		_run_rebase_test(car)
	if not car.freeze and not _checked and _t > 3.0:
		_checked = true
		_check_roads(car)
	if _t >= _next_report:
		_next_report += _report_every
		var world: WorldStreamer = _main.get_node("World")
		var chunks := world.get_children().filter(func(c): return c is Chunk and c.visible)
		var full := chunks.filter(func(c): return c.lod == ChunkBuilder.Lod.FULL).size()
		print("t=%.0fs chunks=%d (full %d) jobs=%d frozen=%s car=%s speed=%.0f km/h worst_frame=%.0f ms" % [
			_t, chunks.size(), full, world._jobs.size(), car.freeze, car.global_position.snapped(Vector3.ONE * 0.1),
			car.speed_kmh(), _max_frame_ms])
		_max_frame_ms = 0.0
		if _topdown > 0.0 and not car.freeze:
			var cam: Camera3D = _main.get_node("Camera")
			cam.set_process(false)
			cam.global_position = car.global_position + Vector3(0, _topdown, _topdown * 0.6)
			cam.look_at(car.global_position, Vector3.UP)
		if not _shots.is_empty() and not car.freeze:
			var img := get_viewport().get_texture().get_image()
			img.save_png(_shots.path_join("shot_%02d.png" % _shot_idx))
			_shot_idx += 1
	if _t > float(OS.get_environment("RUN_SECONDS") if OS.has_environment("RUN_SECONDS") else "40"):
		get_tree().quit()


## Compares road ribbon heights with the terrain collision directly beneath them.
func _check_roads(car: Car) -> void:
	var world: WorldStreamer = _main.get_node("World")
	var chunk := world.chunk_at(car.global_position)
	var roads: MeshInstance3D = chunk.get_node_or_null("Roads")
	if roads == null:
		print("no roads in chunk")
		return
	var verts: PackedVector3Array = roads.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var space := car.get_world_3d().direct_space_state
	var worst := -INF
	var below := 0
	var worst_info := ""
	for k in range(0, verts.size(), 7):
		var p := chunk.to_global(verts[k])
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 100, p - Vector3.UP * 100, 1, [car.get_rid()]))
		if hit.is_empty() or hit.collider.name != "TerrainCollision":
			continue
		var diff: float = hit.position.y - p.y
		if diff > worst:
			worst = diff
			var col: Node = hit.collider
			worst_info = "%s/%s local=%s" % [col.get_parent().name, col.name, verts[k]]
		if diff > 0.0:
			below += 1
	print("road check: %d samples, %d below terrain, worst %.2f m (chunk %s at %s)" % [verts.size() / 7, below, worst, chunk.tile, chunk.position])
	var meshes := chunk.get_children().filter(func(c): return c is MeshInstance3D).map(func(c): return c.name)
	print("  worst hit: ", worst_info)
	print("chunk children: ", meshes, " total chunks under world: ", world.get_child_count())


## Jumps the car 2.5 km east (forcing a floating-origin shift), then checks that every
## chunk sits exactly where its tile belongs and the car's lat/lon is unchanged.
func _run_rebase_test(car: Car) -> void:
	var world: WorldStreamer = _main.get_node("World")
	if _rebase_stage == 0 and not car.freeze and _t > 4.0:
		var target := car.global_position + Vector3(2500, 0, 0)
		_rebase_latlon = Geo.local_to_latlon(target)
		car.place(target + Vector3.UP * 300.0, Vector3.FORWARD)
		car.freeze = true
		_rebase_stage = 1
		print("rebase test: jumped to ", target, " origin before ", Geo.origin_latlon())
	elif _rebase_stage == 1 and not world.is_loading() and _t > 8.0:
		var worst := 0.0
		for c in world.get_children():
			if c is Chunk:
				worst = maxf(worst, c.position.distance_to(Geo.tile_origin_local(c.tile, Geo.CHUNK_ZOOM)))
		var ll := Geo.local_to_latlon(car.global_position)
		print("rebase test: origin now %s, car local %s, latlon drift %.7f deg, worst chunk offset %.4f m" % [
			Geo.origin_latlon(), car.global_position, (ll - _rebase_latlon).length(), worst])
		print("REBASE PASS" if worst < 0.01 and car.global_position.length() < 2000.0 else "REBASE FAIL")
		_rebase_stage = 2
