extends Camera3D
## Smoothed third-person camera. Mouse wheel zooms, right-drag orbits (springs back).

@export var target: Node3D
@export var distance := 9.0
@export var height := 3.2
@export var stiffness := 6.0

var _orbit := 0.0
var _dragging := false


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF  # moved in _process
	Geo.origin_shifted.connect(func(offset: Vector3) -> void:
		global_position -= offset
		reset_physics_interpolation())


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP: distance = maxf(4.0, distance * 0.9)
			MOUSE_BUTTON_WHEEL_DOWN: distance = minf(60.0, distance * 1.1)
			MOUSE_BUTTON_RIGHT: _dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		_orbit -= event.relative.x * 0.008


func _process(delta: float) -> void:
	if target == null:
		return
	var xf := target.get_global_transform_interpolated()
	var fwd := xf.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 1e-4:
		fwd = Vector3.BACK
	fwd = fwd.normalized().rotated(Vector3.UP, _orbit)
	if not _dragging:
		_orbit = lerpf(_orbit, 0.0, 1.0 - exp(-delta * 1.5))
	var tunnel: bool = target is Car and target.in_tunnel
	var dist := minf(distance, 6.0) if tunnel else distance
	var desired := xf.origin - fwd * dist + Vector3.UP * ((1.8 if tunnel else height) + dist * 0.12)
	# Spring arm: don't let walls, roofs or hillsides come between camera and car.
	var pivot := xf.origin + Vector3.UP * 1.2
	var exclude: Array[RID] = []
	if target is CollisionObject3D:
		exclude.append(target.get_rid())
	var block := get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(pivot, desired, 0xFFFFFFFF, exclude))
	if not block.is_empty():
		desired = block.position + (pivot - block.position).normalized() * 0.4
	var t := 1.0 - exp(-delta * stiffness)
	global_position = global_position.lerp(desired, t)
	if not block.is_empty():
		global_position = desired  # snap in, otherwise the lerp clips through
	if tunnel:
		look_at(xf.origin + Vector3.UP * 1.2, Vector3.UP)
		return
	# Don't sink into the ground on crests.
	var space := get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 50.0, global_position - Vector3.UP * 50.0))
	if not hit.is_empty() and global_position.y < hit.position.y + 1.0:
		global_position.y = hit.position.y + 1.0
	look_at(xf.origin + Vector3.UP * 1.2, Vector3.UP)
