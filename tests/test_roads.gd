extends Node
## Builds the saved SF and Leeds tiles on flat elevation, prints stage timings, road
## and junction counts and checks road mesh sanity.
## Run: godot --headless --path . res://tests/test_roads.tscn

const TILES := [
	["res://tests/sf_14_2620_6332.pbf", Vector2i(2620, 6332), 37.7694, -122.4862, ""],
	["res://tests/leeds_14_8121_5276.pbf", Vector2i(8121, 5276), 53.7966, -1.5440,
		"res://tests/leeds_osm_points.txt"],
]


func _ready() -> void:
	for spec: Array in TILES:
		_build(spec)
	get_tree().quit()


func _build(spec: Array) -> void:
	Geo.set_origin(spec[2], spec[3])
	var data := FileAccess.get_file_as_bytes(spec[0])
	var osm := {}
	if not (spec[4] as String).is_empty():
		osm = {points = OsmPoints.parse_csv(FileAccess.get_file_as_string(spec[4])), complete = true}
	print("== ", spec[0], " (osm points: %d)" % (osm.get("points", PackedFloat64Array()).size() / 3))
	var t := Time.get_ticks_usec()
	var b := ChunkBuilder.new(spec[1], ChunkBuilder.Lod.FULL, data, ElevationSource.new(), {}, osm)
	var stage_times := []
	var last := t
	while not b.step():
		var now := Time.get_ticks_usec()
		stage_times.append(snappedf((now - last) / 1000.0, 0.1))
		last = now
	stage_times.append(snappedf((Time.get_ticks_usec() - last) / 1000.0, 0.1))
	print("build total %.0f ms, stages %s" % [(Time.get_ticks_usec() - t) / 1000.0, stage_times])
	var v: PackedVector3Array = b.roads.vertices
	var idx: PackedInt32Array = b.roads.indices
	var bad := 0
	for i in range(0, idx.size(), 3):
		var a := v[idx[i]]; var c := v[idx[i + 1]]; var d := v[idx[i + 2]]
		var longest := maxf(a.distance_to(c), maxf(c.distance_to(d), d.distance_to(a)))
		if longest > 60.0:
			bad += 1
			if bad <= 5:
				print("  long triangle %.0f m at %s" % [longest, a])
	print("road verts %d, tris %d, long tris %d" % [v.size(), idx.size() / 3, bad])
	print("roads: ", b.road_stats)
	var roles := {}
	for block: Dictionary in b.scatter:
		for role: String in block:
			roles[role] = roles.get(role, 0) + (block[role] as Array).size()
	print("instances: ", roles)
	for k in mini(b.signal_spots.size(), 6):
		var sp: Vector2 = b.signal_spots[k]
		var sl := Geo.merc_to_lonlat(b._merc0[0] + sp.x / b._scale, b._merc0[1] - sp.y / b._scale)
		print("  signals at %.6f,%.6f" % [sl[1], sl[0]])
	for r: Vector3 in b._rings:
		var ll := Geo.merc_to_lonlat(b._merc0[0] + r.x / b._scale, b._merc0[1] - r.y / b._scale)
		print("  roundabout r=%.0f m at %.5f,%.5f" % [r.z, ll[1], ll[0]])
	print("buildings verts %d, scatter blocks %d, terrain verts %d" % [b.buildings.vertices.size(), b.scatter.size(), b.terrain.vertices.size()])
	var chunk := Chunk.new()
	chunk.setup(b)
	add_child(chunk)
	var times := []
	var done := false
	while not done:
		var t0 := Time.get_ticks_usec()
		done = chunk.finalize_step()
		times.append(snappedf((Time.get_ticks_usec() - t0) / 1000.0, 0.1))
	print("finalize steps ms: ", times)
	chunk.queue_free()
