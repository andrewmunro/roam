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
}
## Roles that get box colliders, and how far away each role stays visible.
const SOLID_ROLES := ["parked_car", "parked_car_intl", "lamp_road"]
const VISIBILITY := {"street_furniture": 250.0, "street_furniture_intl": 250.0,
	"park_furniture": 300.0, "sign_stop": 300.0, "parked_car": 450.0, "parked_car_intl": 450.0}
const DEFAULT_VISIBILITY := 900.0

var atlas_material: StandardMaterial3D
var _meshes := {}  # role -> Array[Dictionary{mesh: Mesh, aabb: AABB}]


func _ready() -> void:
	atlas_material = StandardMaterial3D.new()
	atlas_material.albedo_texture = load(ROOT + "atlas-albedo.png")
	atlas_material.roughness = 0.95
	atlas_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


## Mesh variants for a role: [{mesh: Mesh, aabb: AABB}]. Models made of several
## meshes (vehicles have separate wheels) are merged so they work in a MultiMesh.
func variants(role: String) -> Array:
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
