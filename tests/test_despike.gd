extends Node
## Elevation despiking: a tower block read as a hill (Giza) is cut back to the plain,
## real hills and mountains are left alone.
## Run: godot --headless --path . res://tests/test_despike.tscn

# [name, lat, lon, expect removed]
const CASES := [
	["giza towers", 29.98801, 31.21661, true],
	["sf twin peaks", 37.7544, -122.4477, false],
	["sf telegraph hill", 37.8024, -122.4058, false],
	["alps zermatt", 46.0207, 7.7491, false],
	["leeds centre", 53.79984, -1.55534, false],
	["rio sugarloaf", -22.9486, -43.1566, false],
	["gibraltar rock", 36.1340, -5.3480, false],
]


func _ready() -> void:
	var ok := true
	for c: Array in CASES:
		var m: PackedFloat64Array = Geo.lonlat_to_merc(c[2], c[1])
		var t := Geo.merc_to_tile(m[0], m[1], ElevationSource.ZOOM)
		var body := [null]
		Fetch.request(ElevationSource.URL % [ElevationSource.ZOOM, t.x, t.y],
			func(got: bool, b: PackedByteArray) -> void: body[0] = b if got else PackedByteArray())
		while body[0] == null:
			await get_tree().process_frame
		var img := Image.new()
		img.load_png_from_buffer(body[0])
		var raw := ElevationSource._decode(img)
		var t0 := Time.get_ticks_usec()
		var clean := ElevationSource._despike(raw, ElevationSource._pixel_metres(t))
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		var worst := 0.0
		var worst_i := 0
		var changed := 0
		for i in raw.size():
			var d := raw[i] - clean[i]
			if d > worst:
				worst = d
				worst_i = i
			changed += 1 if d > 0.0 else 0
		# At the case's own point: the spike there must go (or stay, for real hills).
		var px := int((m[0] - Geo.tile_origin_merc(t, ElevationSource.ZOOM)[0]) / Geo.tile_size_merc(ElevationSource.ZOOM) * 256.0)
		var py := int((Geo.tile_origin_merc(t, ElevationSource.ZOOM)[1] - m[1]) / Geo.tile_size_merc(ElevationSource.ZOOM) * 256.0)
		var spot := 0.0
		for y in range(maxi(0, py - 8), mini(256, py + 9)):
			for x in range(maxi(0, px - 8), mini(256, px + 9)):
				spot = maxf(spot, raw[y * 256 + x] - clean[y * 256 + x])
		var removed := spot >= ElevationSource.SPIKE_MIN
		var pass_: bool = removed == c[3] and (c[3] or changed == 0)
		ok = ok and pass_
		var at := ""
		if changed > 0:  # where the most was cut, to look up
			var size := Geo.tile_size_merc(ElevationSource.ZOOM)
			var o := Geo.tile_origin_merc(t, ElevationSource.ZOOM)
			var ll: PackedFloat64Array = Geo.merc_to_lonlat(o[0] + (worst_i % 256 + 0.5) / 256.0 * size,
				o[1] - (worst_i / 256 + 0.5) / 256.0 * size)
			at = " at %.5f,%.5f (%.0f m -> %.0f m)" % [ll[1], ll[0], raw[worst_i], clean[worst_i]]
		print("%s %s: tile %s, %d px lowered, most %.1f m%s, %.0f ms" % ["ok" if pass_ else "FAIL", c[0], t, changed, worst, at, ms])
	print("PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)
