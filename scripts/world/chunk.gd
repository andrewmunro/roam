class_name Chunk
extends Node3D
## Scene representation of one tile. Built from a finished ChunkBuilder in a few
## steps (one per frame) so node creation doesn't cause a single long hitch.

const MINIMAP_LAYER := 2
const SCATTER_RANGE := 900.0

static var terrain_material: ShaderMaterial
static var road_material: ShaderMaterial
static var water_material: ShaderMaterial
static var building_material: StandardMaterial3D

var tile: Vector2i
var lod: ChunkBuilder.Lod
var size := 0.0
var road_spawn: Array[Dictionary] = []
var ready_for_physics := false

var _builder: ChunkBuilder
var _finalize_step := 0
var _collision_block := 0


static func _ensure_materials() -> void:
	if terrain_material:
		return
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = load("res://shaders/terrain.gdshader")
	road_material = ShaderMaterial.new()
	road_material.shader = load("res://shaders/road.gdshader")
	water_material = ShaderMaterial.new()
	water_material.shader = load("res://shaders/water.gdshader")
	building_material = StandardMaterial3D.new()
	building_material.vertex_color_use_as_albedo = true
	building_material.vertex_color_is_srgb = true
	building_material.roughness = 0.9


func setup(builder: ChunkBuilder) -> void:
	_ensure_materials()
	_builder = builder
	tile = builder.tile
	lod = builder.lod
	size = builder.size
	name = "Chunk_%d_%d_%s" % [tile.x, tile.y, "full" if lod == ChunkBuilder.Lod.FULL else "far"]


## Creates the next group of nodes. Returns true when the chunk is complete.
func finalize_step() -> bool:
	var b := _builder
	match _finalize_step:
		0:
			_add_mesh("Terrain", _array_mesh(b.terrain, true), terrain_material, 1)
			if not b.collision.is_empty():
				_add_heightmap(b.collision)
				ready_for_physics = true
		1:
			if not b.water.is_empty() and b.water.vertices.size() > 0:
				_add_mesh("Water", _array_mesh(b.water, false), water_material, 1 | MINIMAP_LAYER)
			if not b.roads.is_empty() and b.roads.vertices.size() > 0:
				var roads := _add_mesh("Roads", _array_mesh(b.roads, true), road_material, 1 | MINIMAP_LAYER)
				roads.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			road_spawn = b.road_spawn
			_add_trimesh("BridgeCollision", b.bridge_faces)
		2:
			if not b.buildings.is_empty() and b.buildings.vertices.size() > 0:
				_add_mesh("Buildings", _array_mesh(b.buildings, false), building_material, 1)
		3:
			# Building collision is the slowest upload; spread blocks over frames.
			var start := Time.get_ticks_usec()
			while _collision_block < b.building_faces.size() and Time.get_ticks_usec() - start < 4000:
				_add_trimesh("BuildingCollision", b.building_faces[_collision_block])
				_collision_block += 1
			if _collision_block < b.building_faces.size():
				return false
		4:
			_add_scatter(b.scatter)
	_finalize_step += 1
	if _finalize_step > 4:
		_builder = null
		return true
	return false


static func _array_mesh(data: Dictionary, indexed: bool) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data.vertices
	if data.has("normals"):
		arrays[Mesh.ARRAY_NORMAL] = data.normals
	else:
		var n := PackedVector3Array()
		n.resize(data.vertices.size())
		n.fill(Vector3.UP)
		arrays[Mesh.ARRAY_NORMAL] = n
	if data.has("colors"):
		arrays[Mesh.ARRAY_COLOR] = data.colors
	if data.has("uvs"):
		arrays[Mesh.ARRAY_TEX_UV] = data.uvs
	if indexed and data.has("indices"):
		arrays[Mesh.ARRAY_INDEX] = data.indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _add_mesh(node_name: String, mesh: Mesh, material: Material, layers: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = material
	mi.layers = layers
	add_child(mi)
	return mi


func _add_heightmap(c: Dictionary) -> void:
	var cell: float = c.cell
	var heights: PackedFloat32Array = c.heights.duplicate()
	for i in heights.size():
		heights[i] /= cell
	var shape := HeightMapShape3D.new()
	shape.map_width = c.width
	shape.map_depth = c.width
	shape.map_data = heights
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(size * 0.5, 0, size * 0.5)
	cs.scale = Vector3(cell, cell, cell)
	body.add_child(cs)
	add_child(body)


func _add_trimesh(node_name: String, faces: PackedVector3Array) -> void:
	if faces.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = node_name
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


func _add_scatter(blocks: Array[Dictionary]) -> void:
	for bucket in blocks:
		for role: String in bucket:
			var variants: Array = Catalog.variants(role)
			if variants.is_empty():
				continue
			var xfs: Array = bucket[role]
			# Split instances between the role's mesh variants deterministically.
			var per_variant := []
			per_variant.resize(variants.size())
			for v in variants.size():
				per_variant[v] = []
			for k in xfs.size():
				per_variant[hash(k * 7919 + tile.x) % variants.size()].append(xfs[k])
			for v in variants.size():
				var list: Array = per_variant[v]
				if list.is_empty():
					continue
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = variants[v].mesh
				mm.instance_count = list.size()
				var inner: Transform3D = variants[v].xf
				for k in list.size():
					var xf: Transform3D = list[k]
					mm.set_instance_transform(k, xf * inner)
				var mmi := MultiMeshInstance3D.new()
				mmi.multimesh = mm
				mmi.material_override = Catalog.atlas_material
				mmi.visibility_range_end = SCATTER_RANGE
				mmi.visibility_range_end_margin = 50.0
				mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
				add_child(mmi)
