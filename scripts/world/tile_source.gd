class_name TileSource
## Where vector tiles come from: OpenFreeMap's planet, or our own tiles
## (tools/tiles/build.sh: the same schema plus lanes, width and roof tags) from
## ROAM_TILES or the page's ?tiles=, a URL with {z}/{x}/{y}. Outside what our own tiles
## cover (a 404 or an empty tile) each tile falls back to OpenFreeMap.

const TILEJSON_URL := "https://tiles.openfreemap.org/planet"

## Our own tile URL template, or "" for OpenFreeMap only.
static var custom := OS.get_environment("ROAM_TILES")
static var _ofm := ""  # OpenFreeMap's tile URL template, from its TileJSON


## True once tiles can be asked for.
static func is_ready() -> bool:
	return not _ofm.is_empty() or not custom.is_empty()


## Loads OpenFreeMap's TileJSON (its tile URL carries a weekly version), retrying every
## few seconds while it can't be had; the last good copy stands in when offline.
static func start(tree: SceneTree) -> void:
	Fetch.request(TILEJSON_URL, func(ok: bool, body: PackedByteArray) -> void:
		if ok:
			Fetch._write_disk(TILEJSON_URL, body)
		else:
			body = Fetch._read_disk(TILEJSON_URL)
		var json: Variant = JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null
		if json is Dictionary and json.has("tiles"):
			_ofm = json.tiles[0]
		if _ofm.is_empty():
			push_error("Could not load TileJSON from %s; retrying" % TILEJSON_URL)
			tree.create_timer(3.0).timeout.connect(func() -> void: start(tree)), -1.0, false)


## Fetches tile t at Geo.CHUNK_ZOOM: callback(ok, body).
static func fetch(t: Vector2i, callback: Callable, priority := 0.0) -> void:
	var n := 1 << Geo.CHUNK_ZOOM
	var x := posmod(t.x, n)
	var y := clampi(t.y, 0, n - 1)
	# Keyed without OpenFreeMap's version, or every release would fetch the world again.
	var key := "mvt/%d/%d/%d" % [Geo.CHUNK_ZOOM, x, y]
	var from_ofm := func() -> void:
		if _ofm.is_empty():
			callback.call(false, PackedByteArray())
		else:
			Fetch.request(_fill(_ofm, x, y), callback, priority, true, PackedStringArray(), key)
	if custom.is_empty():
		from_ofm.call()
		return
	# Not kept on disk: a rebuilt tile set would hide behind the old copies.
	Fetch.request(_fill(custom, x, y), func(ok: bool, body: PackedByteArray) -> void:
		if ok and not body.is_empty():
			callback.call(true, body)
		else:
			from_ofm.call(), priority, false)


static func _fill(template: String, x: int, y: int) -> String:
	return template.replace("{z}", str(Geo.CHUNK_ZOOM)).replace("{x}", str(x)).replace("{y}", str(y))
