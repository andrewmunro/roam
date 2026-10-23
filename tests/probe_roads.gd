extends Node
## Prints the road features (OSM tags as the vector tiles carry them) within --radius
## metres of --latlon, from the local tile cache: what the builder is given there.
## Run: godot --headless --path . res://tests/probe_roads.tscn -- --latlon=lat,lon [--radius=60] [--points]

func _ready() -> void:
	var lat := 0.0
	var lon := 0.0
	var radius := 60.0
	var verbose := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--latlon="):
			var v := a.substr(9).split(",")
			lat = v[0].to_float()
			lon = v[1].to_float()
		elif a == "--points":
			verbose = true
		elif a.begins_with("--radius="):
			radius = a.substr(9).to_float()
	Geo.set_origin(lat, lon)
	var t := Geo.local_to_tile(Vector3.ZERO, Geo.CHUNK_ZOOM)
	var key := "mvt/%d/%d/%d" % [Geo.CHUNK_ZOOM, t.x, t.y]
	var bytes := Fetch._read_disk(key)
	if bytes.is_empty():
		push_error("tile %s not cached (view it first)" % key)
		get_tree().quit(1)
		return
	var layer: Dictionary = MVTDecoder.decode(bytes, ["transportation"]).get("transportation", {})
	var origin := Geo.tile_origin_local(t, Geo.CHUNK_ZOOM)
	var spot := Vector2(-origin.x, -origin.z)  # the probe point in tile metres
	var k := Geo.tile_size_local(Geo.CHUNK_ZOOM) / float(layer.extent)
	for f: Dictionary in layer.features:
		var near := INF
		var pts := 0
		for r: PackedVector2Array in f.rings:
			for i in r.size() - 1:
				var q := Geometry2D.get_closest_point_to_segment(spot, r[i] * k, r[i + 1] * k)
				near = minf(near, q.distance_to(spot))
			pts += r.size()
		if near <= radius:
			print("%5.1f m  %d pts  %s" % [near, pts, f.tags])
			if verbose and pts < 100:
				for r: PackedVector2Array in f.rings:
					var line := "   "
					for q in r:
						var m := q * k - spot
						line += " (%d,%d)" % [m.x, -m.y]  # metres east, north of the spot
					print(line)
	get_tree().quit()
