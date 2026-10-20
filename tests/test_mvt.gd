extends SceneTree
## Run: godot --headless --path . -s tests/test_mvt.gd

const LAYERS := ["transportation", "building", "water", "waterway", "landcover", "landuse", "park"]

func _init() -> void:
	var data := FileAccess.get_file_as_bytes("res://tests/sf_14_2620_6332.pbf")
	var t := Time.get_ticks_usec()
	var layers := MVTDecoder.decode(data, LAYERS)
	print("decoded %d bytes in %.1f ms" % [data.size(), (Time.get_ticks_usec() - t) / 1000.0])
	for name in layers:
		var classes := {}
		for f: Dictionary in layers[name].features:
			var c = f.tags.get("class", "?")
			classes[c] = classes.get(c, 0) + 1
		print("  %s: %d features, extent %d, classes %s" % [name, layers[name].features.size(), layers[name].extent, classes])
	var b: Dictionary = layers.building.features[0]
	print("  first building: ", b.tags, " rings=", b.rings.size(), " area=", MVTDecoder.ring_area(b.rings[0]))
	var r: Dictionary = layers.transportation.features[0]
	print("  first road: ", r.tags)
	quit()
