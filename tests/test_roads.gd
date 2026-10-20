extends Node
## Builds the saved SF tile on flat elevation and checks road ribbon sanity.
## Run: godot --headless --path . res://tests/test_roads.tscn

func _ready() -> void:
	Geo.set_origin(37.7694, -122.4862)
	var data := FileAccess.get_file_as_bytes("res://tests/sf_14_2620_6332.pbf")
	var t := Time.get_ticks_usec()
	var b := ChunkBuilder.new(Vector2i(2620, 6332), ChunkBuilder.Lod.FULL, data, ElevationSource.new())
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
		if longest > 30.0:
			bad += 1
			if bad <= 5:
				print("  long triangle %.0f m at %s" % [longest, a])
	print("road verts %d, tris %d, long tris %d" % [v.size(), idx.size() / 3, bad])
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
	get_tree().quit()
