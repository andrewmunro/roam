class_name Car
extends RigidBody3D
## Arcade raycast car. Each wheel casts a ray down for a spring/damper and applies
## longitudinal and lateral tyre forces clamped to a friction circle. The visible
## model comes from the pack; its wheel meshes are re-pivoted so they can spin and steer.

@export var model_path := "vehicles/car-passenger"
@export var engine_force := 10000.0
@export var boost_multiplier := 2.2
@export var max_speed := 50.0  ## m/s, where drag equals engine force (no boost)
@export var brake_force := 16000.0
@export var max_steer := 0.55
@export var spring := 12000.0
@export var damper := 1600.0
@export var friction := 1.3
@export var handbrake_grip := 0.25

const RAY_UP := 0.35  # ray starts this far above the modelled wheel centre
const DROOP := 0.25  # extra extension below the modelled position

var streamer: WorldStreamer
var in_tunnel := false
var _wheels: Array[Dictionary] = []
var _steer := 0.0
var _speed := 0.0


func _ready() -> void:
	_ensure_input_actions()
	mass = 1200.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.4, 0)
	angular_damp = 0.5
	continuous_cd = true
	can_sleep = false  # forces from the wheel rays don't wake a sleeping body
	collision_mask = 1 | (1 << (Chunk.TERRAIN_LAYER - 1))  # world + terrain (also used by wheel rays)
	freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	var model := Catalog.instantiate(model_path)
	model.name = "Model"
	add_child(model)
	_setup_wheels(model)
	_setup_collision(model)
	Geo.origin_shifted.connect(func(_o: Vector3) -> void: reset_physics_interpolation())


func speed_kmh() -> float:
	return _speed * 3.6


## Places the car at `pos` facing `forward` and wakes it up.
func place(pos: Vector3, forward: Vector3) -> void:
	forward.y = 0.0
	if forward.length_squared() < 1e-4:
		forward = Vector3.BACK
	var basis := Basis.looking_at(-forward.normalized(), Vector3.UP)  # model faces +Z
	freeze = false
	global_transform = Transform3D(basis, pos)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reset_physics_interpolation()


func _setup_wheels(model: Node3D) -> void:
	for mi in _find_meshes(model):
		var n := String(mi.name).to_lower()
		var idx := n.find("wheel_")
		if idx == -1:
			continue
		var tag := n.substr(idx + 6, 2)
		# Re-pivot the wheel around its geometric centre.
		var aabb := mi.mesh.get_aabb()
		var centre := mi.transform * aabb.get_center()
		var pivot := Node3D.new()
		pivot.name = "Pivot_" + tag
		var parent := mi.get_parent()
		parent.add_child(pivot)
		pivot.position = centre
		mi.reparent(pivot, false)
		mi.transform = Transform3D(Basis.IDENTITY, -centre) * mi.transform
		var anchor := _relative_xf(pivot, self).origin
		_wheels.append({
			pivot = pivot, anchor = anchor, rest_y = pivot.position.y,
			front = tag.begins_with("f"), rear = tag.begins_with("b") or tag.begins_with("r"),
			radius = aabb.size.y * 0.5, spin = 0.0, contact = false,
		})
	if _wheels.is_empty():
		# Model without separate wheels: use invisible wheels at the corners.
		var box := _model_aabb(model)
		for corner in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var p := Vector3(box.get_center().x + corner.x * box.size.x * 0.4, 0.35,
				box.get_center().z + corner.y * box.size.z * 0.35)
			var pivot := Node3D.new()
			add_child(pivot)
			pivot.position = p
			_wheels.append({pivot = pivot, anchor = p, rest_y = p.y, front = corner.y > 0,
				rear = corner.y < 0, radius = 0.35, spin = 0.0, contact = false})


func _setup_collision(model: Node3D) -> void:
	var box := _model_aabb(model)
	var bottom := box.position.y + 0.42
	var top := box.end.y
	var shape := BoxShape3D.new()
	shape.size = Vector3(box.size.x * 0.95, top - bottom, box.size.z * 0.97)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(box.get_center().x, (top + bottom) * 0.5, box.get_center().z)
	add_child(cs)
	# Sensor for street furniture: lamps and signs get knocked over instead of acting as walls.
	var sensor := Area3D.new()
	sensor.name = "KnockSensor"
	sensor.collision_layer = 0
	sensor.collision_mask = Knockables.KNOCK_LAYER
	sensor.monitorable = false
	var scs := CollisionShape3D.new()
	var sshape := BoxShape3D.new()
	sshape.size = Vector3(box.size.x, box.size.y, box.size.z) * 1.02
	scs.shape = sshape
	scs.position = box.get_center()
	sensor.add_child(scs)
	sensor.body_shape_entered.connect(func(_rid: RID, body: Node3D, shape: int, _local: int) -> void:
		Knockables.knock(body, shape, self))
	add_child(sensor)


func _physics_process(delta: float) -> void:
	if freeze:
		return
	var throttle := Input.get_action_strength("accelerate")
	var braking := Input.get_action_strength("brake")
	var handbrake := Input.is_action_pressed("handbrake")
	var steer_in := Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	var boost := boost_multiplier if Input.is_action_pressed("boost") else 1.0
	if get_viewport().gui_get_focus_owner() is LineEdit:  # typing in the search box
		throttle = 0.0
		braking = 0.0
		steer_in = 0.0
		handbrake = false

	# Terrain has collision holes at tunnel mouths, so nothing to switch here; the
	# flag is for the camera and the stuck-under-terrain safety net.
	in_tunnel = streamer != null and streamer.in_tunnel(global_position)
	var xf := global_transform
	var up := xf.basis.y
	var fwd := xf.basis.z
	_speed = linear_velocity.dot(fwd)
	var speed_factor := clampf(absf(_speed) / 35.0, 0.0, 1.0)
	var steer_target := steer_in * max_steer * lerpf(1.0, 0.3, speed_factor)
	_steer = move_toward(_steer, steer_target, delta * 2.5)

	# Brake key reverses once nearly stopped.
	var drive := throttle
	var brake := 0.0
	if braking > 0.0:
		if _speed > 1.0:
			brake = braking
		else:
			drive = -braking * 0.5

	var space := get_world_3d().direct_space_state
	var wheel_mass := mass / _wheels.size()
	for w in _wheels:
		var from: Vector3 = xf * (w.anchor + Vector3.UP * RAY_UP)
		var max_len: float = RAY_UP + DROOP + w.radius
		var query := PhysicsRayQueryParameters3D.create(from, from - up * max_len, collision_mask, [get_rid()])
		var hit := space.intersect_ray(query)
		w.contact = not hit.is_empty()
		var dist: float = max_len
		if w.contact:
			dist = from.distance_to(hit.position)
			var normal: Vector3 = hit.normal
			var contact: Vector3 = hit.position
			var offset := contact - global_position
			var point_vel := linear_velocity + angular_velocity.cross(offset)
			# Suspension
			var compression := max_len - dist
			var load := maxf(0.0, spring * compression - damper * point_vel.dot(up))
			apply_force(normal * load, offset)
			# Tyre frame
			var wheel_fwd := fwd.rotated(up, _steer) if w.front else fwd
			var side := normal.cross(wheel_fwd).normalized()
			wheel_fwd = side.cross(normal).normalized()
			var v_side := point_vel.dot(side)
			var v_fwd := point_vel.dot(wheel_fwd)
			var grip := friction * (handbrake_grip if handbrake and w.rear else 1.0)
			var f_side := -v_side * wheel_mass / delta * 0.7
			var f_long := drive * engine_force * boost / _wheels.size()
			f_long -= v_fwd * 25.0  # rolling resistance
			if brake > 0.0 or (handbrake and w.rear):
				var b := brake_force / _wheels.size() * maxf(brake, 1.0 if handbrake else 0.0)
				f_long -= clampf(v_fwd * wheel_mass / delta, -b, b)
			var f := side * f_side + wheel_fwd * f_long
			var limit := grip * load
			if f.length() > limit:
				f = f.normalized() * limit
			apply_force(f, offset)
			w.spin += v_fwd / w.radius * delta
		else:
			w.spin += drive * delta * 10.0
		# Visual wheel
		var pivot: Node3D = w.pivot
		pivot.position.y = w.rest_y + RAY_UP - (dist - w.radius)
		pivot.rotation = Vector3(w.spin, _steer if w.front else 0.0, 0.0)

	# Aerodynamic drag sized so engine force balances it at max_speed.
	var drag := engine_force / (max_speed * max_speed)
	apply_central_force(-linear_velocity * linear_velocity.length() * drag)
	# Air control: keep the car from tumbling endlessly when airborne.
	var grounded := _wheels.any(func(w: Dictionary) -> bool: return w.contact)
	if not grounded:
		angular_velocity = angular_velocity.lerp(Vector3.ZERO, delta * 0.8)


static func _find_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_find_meshes(c))
	return out


func _model_aabb(model: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in _find_meshes(model):
		var a := _relative_xf(mi, self) * mi.mesh.get_aabb()
		box = a if first else box.merge(a)
		first = false
	return box


static func _relative_xf(n: Node, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	while n != root and n != null:
		if n is Node3D:
			xf = n.transform * xf
		n = n.get_parent()
	return xf


static func _ensure_input_actions() -> void:
	var actions := {
		"accelerate": [_key(KEY_W), _key(KEY_UP), _axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)],
		"brake": [_key(KEY_S), _key(KEY_DOWN), _axis(JOY_AXIS_TRIGGER_LEFT, 1.0)],
		"steer_left": [_key(KEY_A), _key(KEY_LEFT), _axis(JOY_AXIS_LEFT_X, -1.0)],
		"steer_right": [_key(KEY_D), _key(KEY_RIGHT), _axis(JOY_AXIS_LEFT_X, 1.0)],
		"handbrake": [_key(KEY_SPACE), _button(JOY_BUTTON_A)],
		"boost": [_key(KEY_SHIFT), _button(JOY_BUTTON_X)],
		"reset_car": [_key(KEY_R), _button(JOY_BUTTON_Y)],
		"toggle_map": [_key(KEY_M)],
		"toggle_help": [_key(KEY_H)],
		"toggle_debug": [_key(KEY_F3)],
		"open_search": [_key(KEY_SLASH)],
	}
	for action: String in actions:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.15)
		for ev: InputEvent in actions[action]:
			InputMap.action_add_event(action, ev)


static func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	return ev


static func _button(index: JoyButton) -> InputEventJoypadButton:
	var ev := InputEventJoypadButton.new()
	ev.button_index = index
	return ev


static func _axis(axis: JoyAxis, value: float) -> InputEventJoypadMotion:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	return ev
