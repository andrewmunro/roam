class_name OsmPoints
extends RefCounted
## Junction details the vector tiles leave out: traffic signals, mini-roundabouts and
## stop / give-way nodes, from the Overpass API (no key needed, and it sends CORS
## headers so the web build can use it). One small CSV query per z12 tile (5-10 km
## across), kept on disk for good. Overpass is a shared and often overloaded service,
## so queries go one at a time on their own connection (never holding up map tiles),
## chunks wait only briefly for them, and `tile_loaded` lets the streamer rebuild
## chunks that had to guess.

signal tile_loaded(t: Vector2i)

const ZOOM := 12
## Tried in turn; both send CORS headers.
const ENDPOINTS := ["https://overpass-api.de/api/interpreter?data=",
	"https://maps.mail.ru/osm/tools/overpass/api/interpreter?data="]
const QUERY := "[out:csv(::lat,::lon,highway,natural;false)][timeout:25];(" \
	+ "node[highway~\"^(traffic_signals|mini_roundabout|give_way|stop|street_lamp)$\"](%s);" \
	+ "node[natural=tree](%s););out;"
const KINDS := {
	"traffic_signals": RoadNetwork.Pt.SIGNALS, "mini_roundabout": RoadNetwork.Pt.MINI,
	"give_way": RoadNetwork.Pt.GIVE_WAY, "stop": RoadNetwork.Pt.STOP,
	"street_lamp": RoadNetwork.Pt.LAMP,
}
const CACHE_DIR := "user://cache/osm2"  # osm2: also trees and street lamps
const RETRY_MSEC := 120000  # a failed tile is asked for again after this long
const TIMEOUT := 30.0

var _tiles := {}  # Vector2i -> PackedFloat64Array [mx, my, kind, ...]
var _failed := {}  # Vector2i -> Time.get_ticks_msec() of the failure
var _waiting := {}  # Vector2i -> Array[Callable]
var _queue: Array[Vector2i] = []  # newest last: the area the player just reached goes first
var _http: HTTPRequest
var _busy := false
var _current := Vector2i.ZERO  # tile being fetched while _busy
var _endpoint := 0  # index into ENDPOINTS for _current
var _preferred := 0  # endpoint that answered last


## The HTTPRequest needs a place in the scene tree.
func attach(host: Node) -> void:
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT
	_http.accept_gzip = true
	host.add_child(_http)
	_http.request_completed.connect(_on_completed)


## z12 tiles covering a mercator rect.
static func tiles_for_rect(mx0: float, my0: float, mx1: float, my1: float) -> Array[Vector2i]:
	var a := Geo.merc_to_tile(mx0, my1, ZOOM)
	var b := Geo.merc_to_tile(mx1, my0, ZOOM)
	var out: Array[Vector2i] = []
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			out.append(Vector2i(x, y))
	return out


func has_all(tiles: Array[Vector2i]) -> bool:
	for t in tiles:
		if not _tiles.has(t):
			return false
	return true


## Calls `done` once every tile has loaded or failed.
func ensure(tiles: Array[Vector2i], done: Callable) -> void:
	var missing: Array[Vector2i] = []
	for t in tiles:
		if _tiles.has(t):
			continue
		if _failed.has(t) and Time.get_ticks_msec() - int(_failed[t]) < RETRY_MSEC:
			continue
		if FileAccess.file_exists(_cache_path(t)):
			_tiles[t] = FileAccess.get_file_as_bytes(_cache_path(t)).to_float64_array()
			continue
		missing.append(t)
	if missing.is_empty() or _http == null:
		done.call()
		return
	var remaining := [missing.size()]
	var on_one := func() -> void:
		remaining[0] -= 1
		if remaining[0] == 0:
			done.call()
	for t in missing:
		if _waiting.has(t):
			_waiting[t].append(on_one)
			if _queue.has(t):
				_queue.erase(t)
				_queue.append(t)
			continue
		_waiting[t] = [on_one]
		_queue.append(t)
	_pump()


## Points for the given tiles; `complete` is false if any tile is missing.
func snapshot(tiles: Array[Vector2i]) -> Dictionary:
	var points := PackedFloat64Array()
	var complete := true
	for t in tiles:
		if _tiles.has(t):
			points.append_array(_tiles[t])
		else:
			complete = false
	return {points = points, complete = complete}


## Drops queued queries (e.g. after a teleport); their waiters are told they failed.
func cancel_queued() -> void:
	for t in _queue:
		_finish(t, false)
	_queue.clear()


func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	var t: Vector2i = _queue.pop_back()
	_endpoint = _preferred
	_send(t)


func _send(t: Vector2i) -> void:
	var headers := PackedStringArray()
	if not OS.has_feature("web"):
		headers.append("User-Agent: Roam/1.0 (Godot driving game)")  # browsers send their own
	if _http.request(ENDPOINTS[_endpoint] + _query(t), headers) == OK:
		_busy = true
		_current = t
	else:
		_finish(t, false)
		_pump()


func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	var t := _current
	var ok := result == HTTPRequest.RESULT_SUCCESS and code == 200
	var text := body.get_string_from_utf8() if ok else ""
	var points := parse_csv(text)
	# A busy server can answer 200 with an error page instead of CSV.
	if ok and points.is_empty() and not text.strip_edges().is_empty():
		ok = false
	if not ok and _endpoint != (_preferred + ENDPOINTS.size() - 1) % ENDPOINTS.size():
		_endpoint = (_endpoint + 1) % ENDPOINTS.size()  # try the next server
		_send(t)
		return
	if ok:
		_preferred = _endpoint
		_tiles[t] = points
		_write_cache(t, points)
	_finish(t, ok)
	if ok:
		tile_loaded.emit(t)
	_pump()


func _finish(t: Vector2i, ok: bool) -> void:
	if not ok:
		_failed[t] = Time.get_ticks_msec()
		push_warning("Overpass data for z12 tile %s unavailable for now; guessing junction controls" % t)
	var callbacks: Array = _waiting.get(t, [])
	_waiting.erase(t)
	for cb: Callable in callbacks:
		cb.call()


static func _query(t: Vector2i) -> String:
	var m := Geo.tile_origin_merc(t, ZOOM)
	var s := Geo.tile_size_merc(ZOOM)
	var nw := Geo.merc_to_lonlat(m[0], m[1])
	var se := Geo.merc_to_lonlat(m[0] + s, m[1] - s)
	var bbox := "%.5f,%.5f,%.5f,%.5f" % [se[1], nw[0], nw[1], se[0]]
	return (QUERY % [bbox, bbox]).uri_encode()


## "lat<TAB>lon<TAB>highway<TAB>natural" lines -> [mx, my, kind, ...]; other lines are
## skipped.
static func parse_csv(text: String) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for line in text.split("\n", false):
		var f := line.split("\t")
		if f.size() < 3 or not f[0].is_valid_float():
			continue
		var kind := -1
		if KINDS.has(f[2].strip_edges()):
			kind = KINDS[f[2].strip_edges()]
		elif f.size() >= 4 and f[3].strip_edges() == "tree":
			kind = RoadNetwork.Pt.TREE
		if kind == -1:
			continue
		var m := Geo.lonlat_to_merc(f[1].to_float(), f[0].to_float())
		out.append_array([m[0], m[1], float(kind)])
	return out


static func _cache_path(t: Vector2i) -> String:
	return CACHE_DIR.path_join("%d_%d_%d.bin" % [ZOOM, t.x, t.y])


static func _write_cache(t: Vector2i, points: PackedFloat64Array) -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var f := FileAccess.open(_cache_path(t), FileAccess.WRITE)
	if f:
		f.store_buffer(points.to_byte_array())
