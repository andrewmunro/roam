extends Node
## Rebuilds one tile from the fetch cache and checks road heights against terrain.
## Run: godot --headless --path . res://tests/test_chunk_heights.tscn

const TILE := Vector2i(2617, 6332)

func _ready() -> void:
	Geo.set_origin(37.76938, -122.4862)
	var elev := ElevationSource.new()
	var m := Geo.tile_origin_merc(TILE, 14)
	var s := Geo.tile_size_merc(14)
	var tiles := ElevationSource.tiles_for_rect(m[0], m[1] - s, m[0] + s, m[1])
	var done := [false]
	elev.ensure(tiles, 0.0, func() -> void: done[0] = true)
	var tj := [""]
	Fetch.request("https://tiles.openfreemap.org/planet", func(ok: bool, body: PackedByteArray) -> void:
		tj[0] = JSON.parse_string(body.get_string_from_utf8()).tiles[0], 0.0, false)
	while not done[0] or tj[0] == "":
		await get_tree().process_frame
	var url: String = tj[0].replace("{z}", "14").replace("{x}", str(TILE.x)).replace("{y}", str(TILE.y))
	var mvt := [PackedByteArray()]
	Fetch.request(url, func(ok: bool, body: PackedByteArray) -> void: mvt[0] = body)
	while mvt[0].is_empty():
		await get_tree().process_frame
	var b := ChunkBuilder.new(TILE, ChunkBuilder.Lod.FULL, mvt[0], elev.snapshot(tiles))
	b.run_all()
	var v: PackedVector3Array = b.roads.vertices
	var worst := -INF
	var at := Vector3.ZERO
	for p in v:
		var d := b.height_at(Vector2(p.x, p.z)) - p.y
		if d > worst:
			worst = d
			at = p
	print("builder: road verts %d, worst terrain-above-road %.2f m at %s" % [v.size(), worst, at])
	# Terrain mesh vs height_at
	var tv: PackedVector3Array = b.terrain.vertices
	var worst_t := 0.0
	for p in tv:
		worst_t = maxf(worst_t, absf(b.height_at(Vector2(p.x, p.z)) - p.y))
	print("terrain mesh vs height_at max diff %.3f m" % worst_t)
	get_tree().quit()
