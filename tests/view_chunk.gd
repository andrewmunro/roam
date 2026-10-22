extends Node3D
## Fast geometry viewer: builds only the chunks under the requested cameras (with their
## neighbours' data, from the local cache), renders one shot per camera and quits. No
## streaming, car, HUD or horizon, so a location check takes seconds, not minutes.
## Run: godot --path . res://tests/view_chunk.tscn -- --out=dir --cam=lat,lon,h,heading,pitch ...
## --cam (repeatable): h metres above whatever a downward ray hits (road, roof, terrain),
## heading in degrees clockwise from north, pitch in degrees (negative looks down).
## --roads-only hides buildings and scatter; --tiles=seam also builds the tiles beside the
## cameras' own (to check seams); --res is set with the window size (--resolution WxH).

const TILEJSON_URL := "https://tiles.openfreemap.org/planet"
const OSM_WAIT := 40.0  # Overpass is slow; only waited for when not cached

var _out := ""
var _cams: Array[PackedFloat64Array] = []
var _roads_only := false
var _seam := false
var _elev := ElevationSource.new()
var _osm := OsmPoints.new()
var _tile_url := ""
var _chunks := {}  # Vector2i -> Chunk


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--cam="):
			_cams.append(PackedFloat64Array(Array(a.substr(6).split(",")).map(func(v: String) -> float: return v.to_float())))
		elif a == "--roads-only":
			_roads_only = true
		elif a == "--tiles=seam":
			_seam = true
	if _cams.is_empty() or _out.is_empty():
		push_error("usage: --out=dir --cam=lat,lon,h,heading,pitch [...]")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	Geo.set_origin(_cams[0][0], _cams[0][1])
	_osm.attach(self)
	var t0 := Time.get_ticks_msec()
	await _load_tile_url()
	# Tiles under the cameras (and, for seams, every tile touching them).
	var tiles: Array[Vector2i] = []
	for c in _cams:
		var t := Geo.local_to_tile(Geo.latlon_to_local(c[0], c[1]), Geo.CHUNK_ZOOM)
		for dy in range(-1, 2) if _seam else [0]:
			for dx in range(-1, 2) if _seam else [0]:
				if not tiles.has(t + Vector2i(dx, dy)):
					tiles.append(t + Vector2i(dx, dy))
	for t in tiles:
		await _build(t)
	print("view_chunk: built %d chunk(s) in %d ms" % [tiles.size(), Time.get_ticks_msec() - t0])
	# Physics needs a frame to see the new collision before cameras ray-cast onto it.
	await get_tree().physics_frame
	await get_tree().physics_frame
	var cam: Camera3D = $Camera
	for i in _cams.size():
		_place(cam, _cams[i])
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw  # shadows settle a frame late
		var path := _out.path_join("view_%02d.png" % i)
		get_viewport().get_texture().get_image().save_png(path)
		print("shot: ", path)
	get_tree().quit()


func _load_tile_url() -> void:
	var done := [false]
	Fetch.request(TILEJSON_URL, func(ok: bool, body: PackedByteArray) -> void:
		if ok:
			Fetch._write_disk(TILEJSON_URL, body)
		else:
			body = Fetch._read_disk(TILEJSON_URL)
		var json: Variant = JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null
		if json is Dictionary and json.has("tiles"):
			_tile_url = json.tiles[0]
		done[0] = true, -1.0, false)
	while not done[0]:
		await get_tree().process_frame


func _mvt(t: Vector2i) -> PackedByteArray:
	var n := 1 << Geo.CHUNK_ZOOM
	var url := _tile_url.replace("{z}", str(Geo.CHUNK_ZOOM)).replace("{x}", str(posmod(t.x, n))) \
		.replace("{y}", str(clampi(t.y, 0, n - 1)))
	var key := "mvt/%d/%d/%d" % [Geo.CHUNK_ZOOM, posmod(t.x, n), clampi(t.y, 0, n - 1)]
	var out := [null]
	Fetch.request(url, func(ok: bool, body: PackedByteArray) -> void: out[0] = body if ok else PackedByteArray(),
		0.0, true, PackedStringArray(), key)
	while out[0] == null:
		await get_tree().process_frame
	return out[0]


func _build(t: Vector2i) -> void:
	var m := Geo.tile_origin_merc(t, Geo.CHUNK_ZOOM)
	var s := Geo.tile_size_merc(Geo.CHUNK_ZOOM)
	var elev_tiles := ElevationSource.tiles_for_rect(m[0] - s, m[1] - 2.0 * s, m[0] + 2.0 * s, m[1] + s)
	var elev_done := [false]
	_elev.ensure(elev_tiles, 0.0, func() -> void: elev_done[0] = true)
	var pad := RoadNetwork.MARGIN / Geo.scale
	var osm_tiles := OsmPoints.tiles_for_rect(m[0] - pad, m[1] - s - pad, m[0] + s + pad, m[1] + pad)
	var osm_done := [false]
	_osm.ensure(osm_tiles, func() -> void: osm_done[0] = true)
	var mvt: PackedByteArray = await _mvt(t)
	var neighbours := {}
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx != 0 or dy != 0:
				neighbours[Vector2i(dx, dy)] = await _mvt(t + Vector2i(dx, dy))
	var waited := 0.0
	while not elev_done[0] or (not osm_done[0] and waited < OSM_WAIT):
		await get_tree().process_frame
		waited += get_process_delta_time()
	var b := ChunkBuilder.new(t, ChunkBuilder.Lod.FULL, mvt, _elev.snapshot(elev_tiles), neighbours,
		_osm.snapshot(osm_tiles))
	# Pin edges to neighbours already built, as the streamer does.
	var sides := {"w": Vector2i(-1, 0), "e": Vector2i(1, 0), "n": Vector2i(0, -1), "s": Vector2i(0, 1)}
	var opposite := {"w": "e", "e": "w", "n": "s", "s": "n"}
	for side: String in sides:
		var c: Chunk = _chunks.get(t + sides[side])
		if c and not c.edge_heights(opposite[side]).is_empty():
			b.edge_pins[side] = c.edge_heights(opposite[side])
	var tb := Time.get_ticks_msec()
	b.run_all()
	print("view_chunk: tile %s built in %d ms" % [t, Time.get_ticks_msec() - tb])
	var chunk := Chunk.new()
	chunk.setup(b)
	add_child(chunk)
	chunk.position = Geo.tile_origin_local(t, Geo.CHUNK_ZOOM)
	while not chunk.finalize_step():
		pass
	_chunks[t] = chunk
	if _roads_only:
		for child in chunk.get_children():
			if child.name.begins_with("Buildings") or child is MultiMeshInstance3D:
				child.visible = false


func _place(cam: Camera3D, c: PackedFloat64Array) -> void:
	var p := Geo.latlon_to_local(c[0], c[1])
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
		p + Vector3.UP * 500, p - Vector3.UP * 500))
	p.y = (hit.position.y if not hit.is_empty() else 0.0) + c[2]
	var yaw := deg_to_rad(c[3])
	var pitch := deg_to_rad(c[4])
	cam.global_position = p
	cam.look_at(p + Vector3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)), Vector3.UP)
