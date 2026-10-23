extends "res://tests/view_chunk.gd"
## Road geometry regression suite: builds the chunk under each fixed spot (from the
## local cache, fetching what's missing; no Overpass, so results are repeatable) and
## measures what a driver would see as broken:
##   overlap  m² where two road surfaces lie at different levels without clearance
##            (0.4 m to CLEAR - 0.6 apart): roads hanging over or buried in each other
##   buried   m² of carriageway more than 0.3 m under the terrain (cuttings and tunnels
##            excepted), and the worst depth
##   tilted   m² of carriageway steeper than about 25 degrees (vertical faces excepted)
## (carriageway: the road mesh less kerbs, pavements and skirts, which share UV (0.5, 0)
## and an empty UV2)
##   walls    metres of retaining wall standing on a carriageway
##   lifted   metres of road at grade solved more than LIFTED above its ground (bridge
##            approaches top out near a clearance; higher is a solver runaway)
## Compares with tests/locations_baseline.json (tests/locations_baseline_own.json on our own
## tiles, ROAM_TILES; see tools/tiles) and fails if any spot got worse.
## --where lists the worst 20 m cells of each spot (lat,lon) to look at with tools/view.sh.
## Run: godot --headless --path . res://tests/test_locations.tscn -- [--only=name,...] [--write-baseline] [--where]

var _baseline := "res://tests/locations_baseline_own.json" if not TileSource.custom.is_empty() \
	else "res://tests/locations_baseline.json"
## [name, lat, lon]: cuttings, tunnels, interchanges, hills, dual carriageways.
const SPOTS := [
	["leeds_portal", 53.79984, -1.55534],
	["leeds_onramp", 53.80085, -1.55480],
	["manchester_mancunian_way", 53.47200, -2.24000],
	["knaresborough_iles_lane", 54.00671, -1.46342],
	["sf_sunset", 37.76938, -122.48620],
	["sf_broadway_tunnel", 37.79670, -122.41800],
	["sf_us101", 37.77200, -122.42300],
	["birmingham_spaghetti", 52.51000, -1.85800],
	["birmingham_aston_expressway", 52.49300, -1.88400],
	["giza_ring_road", 29.98801, 31.21661],
	["london_hyde_park_corner", 51.50270, -0.15270],
	["paris_porte_maillot", 48.87800, 2.28300],
	["leeds_armley_gyratory", 53.79456, -1.56540],
	["nyc_lincoln_tunnel", 40.75838, -73.99772],
]
const LIFTED := 7.0
## Worse than the baseline by more than this (and the absolute slack) fails.
const TOLERANCE := 0.1
const SLACK := {overlap = 20.0, buried = 10.0, buried_worst = 0.3, tilted = 5.0, walls = 5.0, lifted = 10.0}

var _where := false
var _cells := {}  # "metric" -> {Vector2i 20 m cell: amount}, for --where


func _ready() -> void:
	_use_osm = false
	var only := PackedStringArray()
	var write := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7).split(",")
		elif a == "--write-baseline":
			write = true
		elif a == "--where":
			_where = true
	await _load_tile_url()
	var results := {}
	for spot: Array in SPOTS:
		if not only.is_empty() and not only.has(spot[0]):
			continue
		Geo.set_origin(spot[1], spot[2])
		var t := Geo.local_to_tile(Vector3.ZERO, Geo.CHUNK_ZOOM)
		var t0 := Time.get_ticks_msec()
		var b: ChunkBuilder = await _build(t)
		var m := _measure(b)
		m.ms = Time.get_ticks_msec() - t0
		results[spot[0]] = m
		print("%-28s overlap %7.0f m²  buried %6.0f m² (worst %5.2f m)  tilted %6.0f m²  walls %5.0f m  lifted %4.0f m  (%d ms)" % [
			spot[0], m.overlap, m.buried, m.buried_worst, m.tilted, m.walls, m.lifted, m.ms])
		if _where:
			_print_where(b)
		for c: Node in _chunks.values():
			c.queue_free()
		_chunks.clear()
	var ok := _compare(results)
	if write:
		var old: Dictionary = _load_baseline()
		old.merge(results, true)
		var f := FileAccess.open(_baseline, FileAccess.WRITE)
		f.store_string(JSON.stringify(old, "\t", true))
		print("baseline written")
	print("PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)


func _measure(b: ChunkBuilder) -> Dictionary:
	var L: RoadLevels = b._levels
	var size: float = b.size
	var inside := func(p: Vector2) -> bool: return p.x >= 0.0 and p.y >= 0.0 and p.x < size and p.y < size
	# Overlap: probe across each road's width at every solver sample.
	var overlap := 0.0
	const ACROSS := 1.5
	for k in L._p.size():
		if L._next[k] < 0 or not inside.call(L._p[k]):
			continue
		var dir := L._ab[k].normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var o := -L._hw[k] + ACROSS * 0.5
		while o < L._hw[k]:
			var hs := L.heights_at(L._p[k] + nrm * o)
			hs.sort()
			for i in range(1, hs.size()):
				var gap := hs[i] - hs[i - 1]
				if gap > 0.4 and gap < RoadLevels.CLEAR - 0.6:
					var area := ACROSS * L._p[k].distance_to(L._p[L._next[k]])
					overlap += area
					_note("overlap", L._p[k], area)
					break
			o += ACROSS
	# Buried and tilted carriageway, from the road mesh itself.
	var v: PackedVector3Array = b.roads.vertices
	var idx: PackedInt32Array = b.roads.indices
	var uv: PackedVector2Array = b.roads.uvs
	var uv2: PackedVector2Array = b.roads.uv2s
	var buried := 0.0
	var worst := 0.0
	var tilted := 0.0
	for i in range(0, idx.size(), 3):
		var side := false
		for j in 3:
			var m := idx[i + j]
			side = side or (uv[m] == Vector2(0.5, 0.0) and uv2[m] == Vector2.ZERO)
		if side:
			continue
		var a := v[idx[i]]
		var c := (v[idx[i + 1]] - a).cross(v[idx[i + 2]] - a)
		var area := c.length() * 0.5
		var mid := (a + v[idx[i + 1]] + v[idx[i + 2]]) / 3.0
		var q := Vector2(mid.x, mid.z)
		if not inside.call(q):
			continue
		var ny := absf(c.normalized().y)
		if ny < 0.3:
			continue  # a vertical face (kerb side), not a surface
		if ny < 0.9:
			tilted += area
			_note("tilted", q, area)
		var d := b.height_at(q) - mid.y
		if d > 0.3 and L.depth(q, 1.0) <= 0.5 and L.heights_at(q, RoadLevels.TUNNEL_BIT).is_empty() \
				and not _cut_open(b, q):
			buried += area  # (down in a cutting or tunnel the terrain is cut away)
			_note("buried", q, area)
			worst = maxf(worst, d)
	# Walls on a carriageway: wall feet inside a road surface between foot and top.
	var walls := 0.0
	for w: Dictionary in b.wall_lines:
		for s in 3:
			var f := (s + 0.5) / 3.0
			var q: Vector2 = (w.a as Vector2).lerp(w.b, f)
			var foot := lerpf(w.ya, w.yb, f)
			var top := lerpf(w.ta, w.tb, f)
			for h in L.heights_at(q, RoadLevels.STREETS):
				if h > foot + 0.5 and h < top - 0.5:
					walls += (w.a as Vector2).distance_to(w.b) / 3.0
					_note("walls", q, (w.a as Vector2).distance_to(w.b) / 3.0)
					break
	# Roads at grade lifted far above their ground.
	var lifted := 0.0
	for k in L._p.size():
		if L._next[k] < 0 or L._kind[k] != RoadLevels.Kind.GRADE or not inside.call(L._p[k]):
			continue
		if L._h[k] - L._g[k] > LIFTED:
			lifted += L._p[k].distance_to(L._p[L._next[k]])
			_note("lifted", L._p[k], L._p[k].distance_to(L._p[L._next[k]]))
	return {overlap = overlap, buried = buried, buried_worst = worst, tilted = tilted, walls = walls, lifted = lifted}


## True if the terrain shader cuts the ground away at q (over a cutting, see
## ChunkBuilder.cut_mask).
func _cut_open(b: ChunkBuilder, q: Vector2) -> bool:
	if b.cut_mask == null:
		return false
	var res := ChunkBuilder.CUT_MASK_RES
	var px := Vector2i(clampi(int(q.x / b.size * res), 0, res - 1), clampi(int(q.y / b.size * res), 0, res - 1))
	return b.cut_mask.get_pixelv(px).r < 0.0


func _note(metric: String, p: Vector2, amount: float) -> void:
	if not _where:
		return
	if not _cells.has(metric):
		_cells[metric] = {}
	var c := Vector2i((p / 20.0).floor())
	_cells[metric][c] = _cells[metric].get(c, 0.0) + amount


func _print_where(b: ChunkBuilder) -> void:
	var origin := Geo.tile_origin_local(b.tile, Geo.CHUNK_ZOOM)
	for metric: String in _cells:
		var cells: Dictionary = _cells[metric]
		var keys := cells.keys()
		keys.sort_custom(func(x: Vector2i, y: Vector2i) -> bool: return cells[x] > cells[y])
		var line := "    %s:" % metric
		for c: Vector2i in keys.slice(0, 6):
			var ll := Geo.local_to_latlon(origin + Vector3(c.x * 20.0 + 10.0, 0.0, c.y * 20.0 + 10.0))
			line += "  %.5f,%.5f (%.0f)" % [ll.x, ll.y, cells[c]]
		print(line)
	_cells.clear()


func _load_baseline() -> Dictionary:
	if not FileAccess.file_exists(_baseline):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(_baseline))
	return data if data is Dictionary else {}


func _compare(results: Dictionary) -> bool:
	var base := _load_baseline()
	var ok := true
	for name: String in results:
		if not base.has(name):
			print("  %s: no baseline yet" % name)
			continue
		for key: String in SLACK:
			var now: float = results[name][key]
			var was: float = base[name].get(key, 0.0)
			if now > was * (1.0 + TOLERANCE) + SLACK[key]:
				print("  WORSE %s %s: %.1f -> %.1f" % [name, key, was, now])
				ok = false
			elif now < was * (1.0 - TOLERANCE) - SLACK[key]:
				print("  better %s %s: %.1f -> %.1f" % [name, key, was, now])
	return ok
