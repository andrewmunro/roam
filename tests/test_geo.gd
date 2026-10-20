extends SceneTree
## Run: godot --headless --path . -s tests/test_geo.gd

func _init() -> void:
	var geo: Node = load("res://scripts/geo/geo.gd").new()
	var worst := 0.0
	for c in [Vector2(37.76938, -122.4862), Vector2(-33.8688, 151.2093), Vector2(64.1466, -21.9426), Vector2(0.0, 0.0)]:
		geo.set_origin(c.x, c.y)
		for off in [Vector3.ZERO, Vector3(1234.5, 0, -987.6), Vector3(-2500, 0, 2500)]:
			# Round trip through lon/lat in doubles (Vector2 would be float32).
			var m: PackedFloat64Array = geo.local_to_merc(off)
			var lonlat: PackedFloat64Array = geo.merc_to_lonlat(m[0], m[1])
			var back: Vector3 = geo.latlon_to_local(lonlat[1], lonlat[0])
			worst = maxf(worst, back.distance_to(off))
			var t: Vector2i = geo.local_to_tile(off, 14)
			var o: Vector3 = geo.tile_origin_local(t, 14)
			var s: float = geo.tile_size_local(14)
			assert(off.x >= o.x - 0.001 and off.x <= o.x + s and off.z >= o.z - 0.001 and off.z <= o.z + s, "tile containment")
		# True distance check: 1 km east along the origin latitude vs haversine.
		var east: Vector2 = geo.local_to_latlon(Vector3(1000, 0, 0))
		var d := 6371008.8 * deg_to_rad(east.y - c.y) * cos(deg_to_rad(c.x))
		print("lat %.1f: 1000 m east -> %.2f m true (WGS84 sphere approx)" % [c.x, d])
	print("worst round-trip error: %.6f m" % worst)
	print("PASS" if worst < 0.01 else "FAIL")
	geo.free()
	quit()
