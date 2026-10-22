extends Node3D
## Wires the streamer, car, camera and HUD together; handles spawning, resets and
## teleports.

@export var start_lat := 37.76938
@export var start_lon := -122.48620
@export var start_label := "Golden Gate Park, San Francisco"

@onready var streamer: WorldStreamer = $World
@onready var car: Car = $Car
@onready var hud: CanvasLayer = $HUD

var _spawn_pending := false
var _stuck_check := 0.0
var _spawn_heading := NAN  ## degrees clockwise from north, from a shared link
var _url_timer := 0.0


func _ready() -> void:
	car.streamer = streamer
	streamer.chunk_ready.connect(_on_chunk_ready)
	hud.teleport_requested.connect(teleport)
	hud.road_teleport_requested.connect(func(target: Vector3) -> void:
		if not _spawn_pending and not _place_on_road(target, car.global_transform.basis.z, 0.0, 400.0):
			hud.set_status("No road there yet"))
	var shared := _location_from_url()
	if not shared.is_empty():
		_spawn_heading = shared.get("heading", NAN)
		teleport(shared.lat, shared.lon, "%.5f, %.5f" % [shared.lat, shared.lon])
	else:
		teleport(start_lat, start_lon, start_label)


## Web only: "#lat,lon[,heading]" in the page URL (a shared link) or empty.
func _location_from_url() -> Dictionary:
	if not OS.has_feature("web"):
		return {}
	var hash_text := str(JavaScriptBridge.eval("window.location.hash", true)).trim_prefix("#")
	var parts := hash_text.uri_decode().replace(" ", "").split(",")
	if parts.size() < 2 or not parts[0].is_valid_float() or not parts[1].is_valid_float():
		return {}
	var out := {lat = clampf(parts[0].to_float(), -85.0, 85.0), lon = wrapf(parts[1].to_float(), -180.0, 180.0)}
	if parts.size() >= 3 and parts[2].is_valid_float():
		out.heading = parts[2].to_float()
	return out


## Keeps the page URL pointing at the car, so it can be copied and shared.
func _process(delta: float) -> void:
	_url_timer -= delta
	if _url_timer > 0.0 or _spawn_pending or not OS.has_feature("web"):
		return
	_url_timer = 2.0
	var ll := Geo.local_to_latlon(car.global_position)
	var f := car.global_transform.basis.z
	var heading := fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)
	JavaScriptBridge.eval("history.replaceState(null, '', '#%.5f,%.5f,%d')" % [ll.x, ll.y, roundi(heading)], true)


func teleport(lat: float, lon: float, label: String) -> void:
	car.freeze = true
	Geo.set_origin(lat, lon)
	streamer.reset()
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	_spawn_pending = true
	hud.set_status("Loading %s…" % label)
	hud.arrive(label)


func _physics_process(delta: float) -> void:
	_stuck_check += delta
	if _spawn_pending or car.freeze or _stuck_check < 0.5:
		return
	_stuck_check = 0.0
	# Safety net: if the car ended up under the terrain outside a tunnel, put it back.
	if streamer.in_tunnel_box(car.global_position):
		return
	var p := car.global_position
	var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
		p + Vector3.UP * 0.5, p + Vector3.UP * 500.0, 1 << (Chunk.TERRAIN_LAYER - 1)))
	if not hit.is_empty() or p.y < -1000.0:
		_place_on_road(p, car.global_transform.basis.z)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset_car") and not _spawn_pending:
		_place_on_road(car.global_position, car.global_transform.basis.z)


func _on_chunk_ready(_chunk: Chunk) -> void:
	if _spawn_pending and streamer.chunk_at(car.global_position):
		_spawn_pending = false
		hud.set_status("")
		var facing := Vector3.BACK
		if not is_nan(_spawn_heading):
			var h := deg_to_rad(_spawn_heading)
			facing = Vector3(sin(h), 0.0, -cos(h))  # local -z is north
			_spawn_heading = NAN
		_place_on_road(car.global_position, facing)


## Moves the car to the closest drivable road (bigger roads preferred by `rank_bonus`
## metres per rank), or onto the terrain if there are no roads nearby. With
## `max_dist` set, only roads within that distance count and false is returned
## (car untouched) if there are none.
func _place_on_road(near: Vector3, fallback_dir: Vector3, rank_bonus := 15.0, max_dist := INF) -> bool:
	var best_score := INF
	var best_pos := Vector3.ZERO
	var best_dir := fallback_dir
	for dz in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			var c := streamer.chunk_at(near + Vector3(dx, 0, dz) * Geo.tile_size_local(Geo.CHUNK_ZOOM))
			if c == null:
				continue
			for road: Dictionary in c.road_spawn:
				var pts: PackedVector3Array = road.pts
				for k in range(1, pts.size() - 1):
					var p := pts[k] + c.position
					var dist := Vector2(p.x - near.x, p.z - near.z).length()
					if dist > max_dist:
						continue
					var score: float = dist - road.rank * rank_bonus
					if score < best_score:
						best_score = score
						best_pos = p
						best_dir = pts[k + 1] - pts[k - 1]
	if best_score == INF and max_dist < INF:
		return false
	if best_score == INF:
		var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
			Vector3(near.x, 9000, near.z), Vector3(near.x, -1000, near.z)))
		best_pos = hit.position if not hit.is_empty() else near
	# Keep the current heading if it roughly matches the road.
	if best_dir.dot(fallback_dir) < 0.0 and fallback_dir != Vector3.BACK:
		best_dir = -best_dir
	car.place(best_pos + Vector3.UP * 0.6, best_dir)
	return true
