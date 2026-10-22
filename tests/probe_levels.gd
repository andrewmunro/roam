extends Node
# Builds Leeds tile 8121/5275 (with 5276 as neighbour, flat DEM) and prints solved road
# heights near the A58(M) portal, in metres east/north of the spot.
func _ready() -> void:
	var lat := 53.79984
	var lon := -1.55534
	Geo.set_origin(lat, lon)
	var n := 16384.0
	var fx := (lon + 180.0) / 360.0 * n
	var fy := (1.0 - asinh(tan(deg_to_rad(lat))) / PI) / 2.0 * n
	var ty := 5276
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ty="):
			ty = int(a.substr(5))
	var other := 5275 if ty == 5276 else 5276
	var nb := {Vector2i(0, other - ty): FileAccess.get_file_as_bytes("res://tests/leeds_14_8121_%d.pbf" % other)}
	var b := ChunkBuilder.new(Vector2i(8121, ty), ChunkBuilder.Lod.FULL,
		FileAccess.get_file_as_bytes("res://tests/leeds_14_8121_%d.pbf" % ty), ElevationSource.new(), nb, {})
	b.run_all()
	var size: float = b.size
	var spot := Vector2((fx - 8121) * size, (fy - ty) * size)
	var L: RoadLevels = b._levels
	var last := -1
	var line_s := ""
	for k in L._p.size():
		var rel := L._p[k] - spot
		var e := rel.x
		var no := -rel.y
		if e < -70 or e > 130 or no < -80 or no > 200 or L._hw[k] < 2.0:
			continue
		if L._line[k] != last:
			if line_s != "":
				print(line_s)
			last = L._line[k]
			var l: Dictionary = L._lines[last]
			line_s = "L%d kind=%d layer=%d hw=%.1f: " % [last, l.kind, l.layer, l.hw]
		line_s += "(%d,%d h%.1f) " % [e, no, L._h[k] - L._g[k]]
	print(line_s)
	print("drawn: ", b._open_segments.size(), " open segs")
	# Tilted road triangles near the spot (a flat junction should have none).
	var v: PackedVector3Array = b.roads.vertices
	var idx: PackedInt32Array = b.roads.indices
	var cols: PackedColorArray = b.roads.colors
	for i in range(0, idx.size(), 3):
		var a := v[idx[i]]
		var c := v[idx[i + 1]]
		var d := v[idx[i + 2]]
		var m := (a + c + d) / 3.0
		var rel := Vector2(m.x, m.z) - spot
		if absf(rel.x - 5) > 40 or absf(-rel.y + 5) > 40:
			continue
		var nrm := (c - a).cross(d - a).normalized()
		if absf(nrm.y) < 0.985 and absf(nrm.y) > 0.3:
			print("tilt %.2f at (%d,%d) ys %.1f %.1f %.1f col %s" % [nrm.y, rel.x, -rel.y, a.y, c.y, d.y, cols[idx[i]]])
	get_tree().quit()
