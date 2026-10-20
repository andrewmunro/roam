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
}

var atlas_material: StandardMaterial3D
var _meshes := {}  # role -> Array[Dictionary{mesh, xf}]


func _ready() -> void:
	atlas_material = StandardMaterial3D.new()
	atlas_material.albedo_texture = load(ROOT + "atlas-albedo.png")
	atlas_material.roughness = 0.95
	atlas_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


## Mesh variants for a role: [{mesh: Mesh, xf: Transform3D}] where xf is the mesh's
## transform inside its source scene.
func variants(role: String) -> Array:
	if not _meshes.has(role):
		var list := []
		for path: String in ROLES.get(role, []):
			var scene: PackedScene = load(ROOT + path + ".fbx")
			if scene == null:
				continue
			var root := scene.instantiate()
			var mi := _first_mesh(root)
			if mi:
				list.append({mesh = mi.mesh, xf = _relative_xf(mi, root)})
			root.free()
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


static func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _first_mesh(c)
		if m:
			return m
	return null


static func _relative_xf(n: Node, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	while n != root:
		if n is Node3D:
			xf = n.transform * xf
		n = n.get_parent()
	return xf
