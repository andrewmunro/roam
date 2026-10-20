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


func _ready() -> void:
	car.streamer = streamer
	streamer.chunk_ready.connect(_on_chunk_ready)
	hud.teleport_requested.connect(teleport)
	teleport(start_lat, start_lon, start_label)


func teleport(lat: float, lon: float, label: String) -> void:
	car.freeze = true
	Geo.set_origin(lat, lon)
	streamer.reset()
	car.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	_spawn_pending = true
	hud.set_status("Loading %s…" % label)


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
		_place_on_road(car.global_position, Vector3.BACK)


## Moves the car to the closest drivable road (bigger roads preferred), or onto the
## terrain if there are no roads nearby.
func _place_on_road(near: Vector3, fallback_dir: Vector3) -> void:
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
					var score: float = Vector2(p.x - near.x, p.z - near.z).length() - road.rank * 15.0
					if score < best_score:
						best_score = score
						best_pos = p
						best_dir = pts[k + 1] - pts[k - 1]
	if best_score == INF:
		var hit := get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
			Vector3(near.x, 9000, near.z), Vector3(near.x, -1000, near.z)))
		best_pos = hit.position if not hit.is_empty() else near
	# Keep the current heading if it roughly matches the road.
	if best_dir.dot(fallback_dir) < 0.0 and fallback_dir != Vector3.BACK:
		best_dir = -best_dir
	car.place(best_pos + Vector3.UP * 0.6, best_dir)
