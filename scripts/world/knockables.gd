class_name Knockables
## Street furniture that falls over when hit. Props are drawn in MultiMeshes with a
## sensor-only box per instance (KNOCK_LAYER); when the car's sensor touches one, that
## instance is hidden and replaced by a loose rigid body thrown along by the car.

const KNOCK_LAYER := 1 << 2  ## sensor boxes around knockable instances
const DEBRIS_LAYER := 1 << 3  ## fallen props: collide with the world and each other, not the car
const MAX_DEBRIS := 40
const MASS := {"lamp_road": 120.0, "traffic_light": 200.0, "traffic_light_pole": 60.0,
	"sign_stop": 25.0, "sign_give_way": 25.0}

static var _debris: Array[RigidBody3D] = []


## Box (centre, size) used both as the sensor and the fallen prop's collider. Tall props
## with arms (street lamps, mast-arm signals) only get their pole, at the model origin.
static func box_for(aabb: AABB) -> AABB:
	if maxf(aabb.size.x, aabb.size.z) > 1.5 and aabb.size.y > 3.0:
		return AABB(Vector3(-0.25, aabb.position.y, -0.25), Vector3(0.5, aabb.size.y, 0.5))
	return AABB(aabb.position, aabb.size * 0.95)


## Adds sensor boxes for a MultiMesh's instances under `chunk`.
static func add_sensors(chunk: Node3D, role: String, mm: MultiMesh, xfs: Array, aabb: AABB,
		material: Material) -> void:
	var box := box_for(aabb)
	var shape := BoxShape3D.new()
	shape.size = box.size
	var body := StaticBody3D.new()
	body.name = "Knockables"
	body.collision_layer = KNOCK_LAYER
	body.collision_mask = 0
	body.set_meta("knock", {role = role, mm = mm, mesh = mm.mesh, box = box, material = material})
	for k in xfs.size():
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.transform = xfs[k] * Transform3D(Basis.IDENTITY, box.get_center())
		cs.set_meta("instance", k)
		body.add_child(cs)
	chunk.add_child(body)


## Called by the car's sensor. Swaps the touched instance for a falling rigid body.
static func knock(body: Node, shape_index: int, hitter: RigidBody3D) -> void:
	if not body.has_meta("knock"):
		return
	var cs: CollisionShape3D = body.shape_owner_get_owner(body.shape_find_owner(shape_index))
	if cs == null or cs.disabled:
		return
	var info: Dictionary = body.get_meta("knock")
	var k: int = cs.get_meta("instance")
	var mm: MultiMesh = info.mm
	var xf := mm.get_instance_transform(k)
	cs.set_deferred("disabled", true)
	mm.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3.ZERO), xf.origin))
	var box: AABB = info.box
	var rb := RigidBody3D.new()
	rb.collision_layer = DEBRIS_LAYER
	rb.collision_mask = 1 | (1 << 1) | DEBRIS_LAYER  # world, terrain, other debris
	rb.mass = MASS.get(info.role, 20.0)
	rb.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	rb.center_of_mass = box.get_center() * Vector3(1, 0.6, 1)
	var mi := MeshInstance3D.new()
	mi.mesh = info.mesh
	mi.material_override = info.material
	rb.add_child(mi)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box.size
	col.shape = shape
	col.position = box.get_center()
	rb.add_child(col)
	var chunk: Node3D = body.get_parent()
	chunk.add_child(rb)
	rb.transform = xf
	# Thrown along with the car and tipped over away from it.
	var v := hitter.linear_velocity
	var push := Vector3(v.x, 0, v.z)
	rb.linear_velocity = push * 0.8 + Vector3.UP * minf(push.length() * 0.15, 4.0)
	var axis := Vector3.UP.cross(push.normalized()) if push.length() > 0.5 else Vector3.RIGHT
	rb.angular_velocity = axis * clampf(push.length() * 0.25, 1.0, 6.0)
	# The impact costs the car a little speed (more for heavy poles).
	hitter.linear_velocity *= 1.0 - clampf(rb.mass / 3000.0, 0.02, 0.1)
	_debris.append(rb)
	while _debris.size() > MAX_DEBRIS:
		var old: RigidBody3D = _debris.pop_front()
		if is_instance_valid(old):
			old.queue_free()
