class_name Chunk
extends Node3D
## Scene representation of one tile. Built from a finished ChunkBuilder in a few
## steps (one per frame) so node creation doesn't cause a single long hitch.

const MINIMAP_LAYER := 2

static var terrain_material: ShaderMaterial
static var road_material: ShaderMaterial
static var water_material: ShaderMaterial
static var building_material: ShaderMaterial

var tile: Vector2i
var lod: ChunkBuilder.Lod
var size := 0.0
var road_spawn: Array[Dictionary] = []
var road_names: Array[Dictionary] = []  ## see ChunkBuilder.road_names
var places: Array[Dictionary] = []
var tunnel_boxes: Array[Transform3D] = []  ## see ChunkBuilder.tunnel_boxes
var portal_boxes: Array[Transform3D] = []
var _tunnel_inverse: Array[Transform3D] = []
var _heights := PackedFloat32Array()  # terrain grid, for height queries
var _grid_n := 0
var _grid_cell := 1.0
var ready_for_physics := false
var osm_complete := false  ## built with Overpass junction data (see OsmPoints)

var _builder: ChunkBuilder
var _finalize_step := 0
var _collision_block := 0
var _scatter_block := 0


static func _ensure_materials() -> void:
	if terrain_material:
		return
	terrain_material = ShaderMaterial.new()
	terrain_material.shader = load("res://shaders/terrain.gdshader")
	road_material = ShaderMaterial.new()
	road_material.shader = load("res://shaders/road.gdshader")
	water_material = ShaderMaterial.new()
	water_material.shader = load("res://shaders/water.gdshader")
	building_material = ShaderMaterial.new()
	building_material.shader = load("res://shaders/building.gdshader")


func setup(builder: ChunkBuilder) -> void:
	_ensure_materials()
	_builder = builder
	tile = builder.tile
	lod = builder.lod
	osm_complete = builder.osm_complete
	size = builder.size
	name = "Chunk_%d_%d_%s" % [tile.x, tile.y, "full" if lod == ChunkBuilder.Lod.FULL else "far"]


## Creates the next group of nodes. Returns true when the chunk is complete.
func finalize_step() -> bool:
	var b := _builder
	match _finalize_step:
		0:
			_add_mesh("Terrain", _array_mesh(b.terrain, true), _terrain_material_for(b), 1)
			if not b.collision.is_empty():
				_heights = b.collision.heights
				_grid_n = b.collision.width
				_grid_cell = b.collision.cell
			tunnel_boxes = b.tunnel_boxes
			portal_boxes = b.portal_boxes
			for box in tunnel_boxes:
				_tunnel_inverse.append(box.affine_inverse())
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
			road_names = b.road_names
			places = b.places
			_add_trimesh("StructureCollision", b.structure_faces)
			if not b.structures.is_empty() and b.structures.vertices.size() > 0:
				_add_mesh("Structures", _array_mesh(b.structures, false), building_material, 1)
		2:
			if not b.buildings.is_empty() and b.buildings.vertices.size() > 0:
				_add_mesh("Buildings", _array_mesh(b.buildings, false), building_material, 1)
		3:
			# Building and road collision are the slowest uploads; spread blocks over frames.
			var start := Time.get_ticks_usec()
			var blocks := maxi(b.building_faces.size(), b.road_faces.size())
			while _collision_block < blocks and Time.get_ticks_usec() - start < 4000:
				if _collision_block < b.building_faces.size():
					_add_trimesh("BuildingCollision", b.building_faces[_collision_block])
				if _collision_block < b.road_faces.size():
					_add_trimesh("RoadCollision", b.road_faces[_collision_block])
				_collision_block += 1
			if _collision_block < blocks:
				return false
		4:
			var start := Time.get_ticks_usec()
			while _scatter_block < b.scatter.size() and Time.get_ticks_usec() - start < 4000:
				_add_scatter_block(b.scatter[_scatter_block])
				_scatter_block += 1
			if _scatter_block < b.scatter.size():
				return false
	_finalize_step += 1
	if _finalize_step > 4:
		_builder = null
		return true
	return false


const MAX_PORTALS := 16
const TERRAIN_LAYER := 2  ## physics layer bit for terrain (cars ignore it inside tunnels)


## The shared terrain material, or a copy that cuts holes where tunnels meet the surface.
func _terrain_material_for(b: ChunkBuilder) -> ShaderMaterial:
	if b.mouth_boxes.is_empty() and b.cut_mask == null and b.road_mask == null:
		return terrain_material
	var m: ShaderMaterial = terrain_material.duplicate()
	var inv: Array[Projection] = []
	for i in mini(b.mouth_boxes.size(), MAX_PORTALS):
		inv.append(Projection(b.mouth_boxes[i].affine_inverse()))
	m.set_shader_parameter("portal_count", inv.size())
	m.set_shader_parameter("portals", inv)
	if b.cut_mask != null:
		m.set_shader_parameter("has_cut", true)
		m.set_shader_parameter("cut_mask", ImageTexture.create_from_image(b.cut_mask))
		m.set_shader_parameter("cut_size", b.size)
		m.set_shader_parameter("cut_base", b.cut_base)
	if b.road_mask != null:
		m.set_shader_parameter("has_roads", true)
		m.set_shader_parameter("road_mask", ImageTexture.create_from_image(b.road_mask))
		m.set_shader_parameter("road_size", b.road_mask.get_width() * UrbanBlocks.CELL)
	return m


## True if the chunk-local point is inside one of this chunk's tunnel volumes.
func in_tunnel_box(local_pos: Vector3) -> bool:
	for inv in _tunnel_inverse:
		var p := inv * local_pos
		if absf(p.x) <= 1.0 and absf(p.y) <= 1.0 and absf(p.z) <= 1.0:
			return true
	return false


## This chunk's terrain heights along one edge ("w", "e", "n", "s"), for pinning a
## neighbour's matching edge (see ChunkBuilder.edge_pins).
func edge_heights(side: String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if _heights.is_empty():
		return out
	var n := _grid_n
	out.resize(n)
	for k in n:
		match side:
			"w": out[k] = _heights[k * n]
			"e": out[k] = _heights[k * n + n - 1]
			"n": out[k] = _heights[k]
			_: out[k] = _heights[(n - 1) * n + k]
	return out


## Terrain height at a chunk-local x/z, on the same triangles as ChunkBuilder.height_at.
func terrain_height(p: Vector2) -> float:
	if _heights.is_empty():
		return -INF
	var n := _grid_n
	var fx := clampf(p.x / _grid_cell, 0.0, n - 1.001)
	var fz := clampf(p.y / _grid_cell, 0.0, n - 1.001)
	var i := floori(fx)
	var j := floori(fz)
	var u := fx - i
	var v := fz - j
	var h00 := _heights[j * n + i]
	var h11 := _heights[(j + 1) * n + i + 1]
	if u >= v:
		var h10 := _heights[j * n + i + 1]
		return h00 + u * (h10 - h00) + v * (h11 - h10)
	var h01 := _heights[(j + 1) * n + i]
	return h00 + v * (h01 - h00) + u * (h11 - h01)


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
	if data.has("uv2s"):
		arrays[Mesh.ARRAY_TEX_UV2] = data.uv2s
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
	var heights: PackedFloat32Array = c.get("collision_heights", c.heights).duplicate()
	for i in heights.size():
		heights[i] /= cell
	var shape := HeightMapShape3D.new()
	shape.map_width = c.width
	shape.map_depth = c.width
	shape.map_data = heights
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	body.collision_layer = 1 << (TERRAIN_LAYER - 1)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(size * 0.5, 0, size * 0.5)
	cs.scale = Vector3(cell, cell, cell)
	body.add_child(cs)
	add_child(body)
	if not _builder.terrain_patch_faces.is_empty():
		_add_trimesh("TerrainPatchCollision", _builder.terrain_patch_faces, 1 << (TERRAIN_LAYER - 1))


## One static body holding a box per instance (shared shape per mesh variant).
func _add_boxes(xfs: Array, aabb: AABB) -> void:
	var shape := BoxShape3D.new()
	shape.size = aabb.size * 0.95
	var body := StaticBody3D.new()
	body.name = "PropCollision"
	for xf: Transform3D in xfs:
		var cs := CollisionShape3D.new()
		cs.shape = shape
		cs.transform = xf * Transform3D(Basis.IDENTITY, aabb.get_center())
		body.add_child(cs)
	add_child(body)


func _add_trimesh(node_name: String, faces: PackedVector3Array, layer := 1) -> void:
	if faces.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = layer
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


func _add_scatter_block(bucket: Dictionary) -> void:
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
			for k in list.size():
				mm.set_instance_transform(k, list[k])
			var material: Material = variants[v].get("material", Catalog.atlas_material)
			if role in Catalog.KNOCKABLE_ROLES:
				Knockables.add_sensors(self, role, mm, list, variants[v].aabb, material)
			elif role in Catalog.SOLID_ROLES:
				_add_boxes(list, variants[v].aabb)
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = material
			mmi.visibility_range_end = Catalog.VISIBILITY.get(role, Catalog.DEFAULT_VISIBILITY)
			mmi.visibility_range_end_margin = 50.0
			mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			add_child(mmi)
