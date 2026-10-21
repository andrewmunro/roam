extends Node
## Maps gameplay roles to Low Poly Ultimate Pack meshes and owns the shared atlas
## material. Every pack mesh uses the same 1024px atlas, so one material covers all.

const ROOT := "res://assets/lpup/"
const ROLES := {
	"tree_broadleaf": ["nature/trees/tree-oak", "nature/trees/tree-beech", "nature/trees/tree-lime",
		"nature/trees/tree-birch", "nature/trees/tree-round", "nature/trees/tree",
		"nature/trees/tree-simple", "nature/trees/tree-elipse"],
	"tree_conifer": ["nature/trees/tree-conifer", "nature/trees/tree-fir", "nature/trees/tree-spruce",
		"nature/trees/tree-pyramid", "nature/trees/tree-triangle"],
	"tree_palm": ["nature/trees/palm", "nature/trees/palm-big", "nature/trees/palm-high",
		"nature/trees/palm-round"],
	"bush": ["nature/trees/shrub", "nature/trees/shrub-round"],
	"rock": ["nature/stone-round", "nature/stone-oval", "nature/stone-pointy", "nature/rocks-small",
		"nature/stone-flat"],
	"lamp_road": ["props/lamp-road"],
	"parked_car": ["vehicles/car-passenger", "vehicles/car-taxi", "vehicles/car-hippie-van",
		"vehicles/jeep-open", "vehicles/car-veteran", "vehicles/car-police"],
	"street_furniture": ["props/fire-hydrant", "props/trash-can", "props/mail-box",
		"props/bin-wheelie", "props/bench-old", "props/bike-stand"],
	# Outside North America: no yellow cabs, police cruisers, hydrants or US mailboxes.
	# Listed more than once to weight the mix towards ordinary saloons.
	"parked_car_intl": ["vehicles/car-passenger", "vehicles/car-passenger", "vehicles/car-passenger",
		"vehicles/car-hippie-van", "vehicles/jeep-open"],
	"street_furniture_intl": ["props/trash-can", "props/bench-old", "props/bin-wheelie",
		"props/bike-stand"],
	"park_furniture": ["props/bench-forest", "props/trash-can"],
	"sign_stop": ["props/traffic-sign-stop"],
	"traffic_light": ["props/traffic-lights"],
}
## Roles built here rather than taken from the pack (it has no UK-style signals or
## give-way signs). They use vertex colours instead of the atlas.
const PROCEDURAL := ["traffic_light_pole", "sign_give_way"]
## Roles that get box colliders, and how far away each role stays visible.
const SOLID_ROLES := ["parked_car", "parked_car_intl"]
## Fall over when the car hits them (see Knockables).
const KNOCKABLE_ROLES := ["lamp_road", "traffic_light", "traffic_light_pole", "sign_stop",
	"sign_give_way", "street_furniture", "street_furniture_intl", "park_furniture"]
const VISIBILITY := {"street_furniture": 250.0, "street_furniture_intl": 250.0,
	"park_furniture": 300.0, "sign_stop": 300.0, "sign_give_way": 300.0, "parked_car": 450.0,
	"parked_car_intl": 450.0, "traffic_light": 600.0, "traffic_light_pole": 450.0}
const DEFAULT_VISIBILITY := 900.0

var atlas_material: StandardMaterial3D
var prop_material: StandardMaterial3D  ## vertex-coloured, for PROCEDURAL roles
var _meshes := {}  # role -> Array[Dictionary{mesh: Mesh, aabb: AABB}]


func _ready() -> void:
	atlas_material = StandardMaterial3D.new()
	atlas_material.albedo_texture = load(ROOT + "atlas-albedo.png")
	atlas_material.roughness = 0.95
	atlas_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	prop_material = StandardMaterial3D.new()
	prop_material.vertex_color_use_as_albedo = true
	prop_material.roughness = 0.8


## Mesh variants for a role: [{mesh: Mesh, aabb: AABB, material?: Material}]. Models
## made of several meshes (vehicles have separate wheels) are merged so they work in a
## MultiMesh.
func variants(role: String) -> Array:
	if not _meshes.has(role) and role in PROCEDURAL:
		var mesh := _build_prop(role)
		_meshes[role] = [{mesh = mesh, aabb = mesh.get_aabb(), material = prop_material}]
	if not _meshes.has(role):
		var list := []
		for path: String in ROLES.get(role, []):
			var scene: PackedScene = load(ROOT + path + ".fbx")
			if scene == null:
				continue
			var root := scene.instantiate()
			var st := SurfaceTool.new()
			var count := 0
			for mi in _meshes_in(root):
				for surface in mi.mesh.get_surface_count():
					st.append_from(mi.mesh, surface, _relative_xf(mi, root))
					count += 1
			root.free()
			if count > 0:
				var mesh := st.commit()
				list.append({mesh = mesh, aabb = mesh.get_aabb()})
		_meshes[role] = list
	return _meshes[role]


## Instantiates a pack model with the atlas material applied to every mesh.
func instantiate(path: String) -> Node3D:
	var node: Node3D = load(ROOT + path + ".fbx").instantiate()
	apply_atlas(node)
	return node


func apply_atlas(node: Node) -> void:
	if node is MeshInstance3D:
		node.material_override = atlas_material
	for c in node.get_children():
		apply_atlas(c)


static func _meshes_in(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes_in(c))
	return out


static func _relative_xf(n: Node, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	while n != root:
		if n is Node3D:
			xf = n.transform * xf
		n = n.get_parent()
	return xf


# --- Procedural props (front faces +Z, like the pack models) ---------------------------

const POLE := Color(0.32, 0.33, 0.33)
const HEAD := Color(0.06, 0.06, 0.06)


func _build_prop(role: String) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	match role:
		"traffic_light_pole":
			# UK-style pole signal: three-aspect head on a backing board, showing green.
			_box(st, Vector3(0, 1.55, 0), Vector3(0.12, 3.1, 0.12), POLE)
			_box(st, Vector3(0, 2.55, 0.0), Vector3(0.62, 1.26, 0.03), Color(0.92, 0.92, 0.9))
			_box(st, Vector3(0, 2.55, 0.02), Vector3(0.56, 1.2, 0.03), HEAD)
			_box(st, Vector3(0, 2.55, 0.14), Vector3(0.34, 1.0, 0.22), HEAD)
			_box(st, Vector3(0, 2.86, 0.26), Vector3(0.2, 0.2, 0.03), Color(0.35, 0.06, 0.05))
			_box(st, Vector3(0, 2.55, 0.26), Vector3(0.2, 0.2, 0.03), Color(0.38, 0.26, 0.05))
			_box(st, Vector3(0, 2.24, 0.26), Vector3(0.2, 0.2, 0.03), Color(0.35, 1.0, 0.55))
		"sign_give_way":
			_box(st, Vector3(0, 1.05, 0), Vector3(0.07, 2.1, 0.07), POLE)
			var top := 2.45
			var tri_red := [Vector3(-0.42, top, 0.05), Vector3(0.42, top, 0.05), Vector3(0, top - 0.73, 0.05)]
			var tri_white := [Vector3(-0.27, top - 0.09, 0.06), Vector3(0.27, top - 0.09, 0.06), Vector3(0, top - 0.56, 0.06)]
			_tri(st, tri_red, Vector3.BACK, Color(0.75, 0.08, 0.08))
			_tri(st, tri_white, Vector3.BACK, Color(0.95, 0.95, 0.95))
			var back := [Vector3(-0.42, top, 0.04), Vector3(0.42, top, 0.04), Vector3(0, top - 0.73, 0.04)]
			_tri(st, back, Vector3.FORWARD, POLE)
	return st.commit()


## Triangle facing `nrm` (Godot front faces are clockwise).
static func _tri(st: SurfaceTool, p: Array, nrm: Vector3, color: Color) -> void:
	var a: Vector3 = p[0]
	var b: Vector3 = p[1]
	var c: Vector3 = p[2]
	if (b - a).cross(c - a).dot(nrm) > 0.0:
		var t := b
		b = c
		c = t
	for v in [a, b, c]:
		st.set_color(color)
		st.set_normal(nrm)
		st.add_vertex(v)


static func _box(st: SurfaceTool, centre: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	for axis in 3:
		for sgn: float in [1.0, -1.0]:
			var n := Vector3.ZERO
			n[axis] = sgn
			var u := Vector3.ZERO
			u[(axis + 1) % 3] = h[(axis + 1) % 3]
			var v := Vector3.ZERO
			v[(axis + 2) % 3] = h[(axis + 2) % 3]
			var c := centre + n * h[axis]
			_tri(st, [c - u - v, c + u - v, c + u + v], n, color)
			_tri(st, [c - u - v, c + u + v, c - u + v], n, color)
