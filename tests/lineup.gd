extends Node3D
## Renders every catalog variant in a row and saves a screenshot.
## Run: godot --path . res://tests/lineup.tscn -- --out=path.png

func _ready() -> void:
	var x := 0.0
	var labels := []
	for role: String in Catalog.ROLES:
		for v: Dictionary in Catalog.variants(role):
			var mi := MeshInstance3D.new()
			mi.mesh = v.mesh
			mi.material_override = Catalog.atlas_material
			mi.transform = Transform3D(Basis.IDENTITY, Vector3(x, 0, 0)) * v.xf
			add_child(mi)
			labels.append("%s@%d" % [role, x])
			x += 5.0
	print(labels)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = x * 0.5
	add_child(cam)
	cam.look_at_from_position(Vector3(x * 0.5, 6, 40), Vector3(x * 0.5, 4, 0))
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.6, 0.7, 0.8)
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	add_child(env)
	for i in 5:
		await get_tree().process_frame
	var out := "user://lineup.png"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	get_viewport().get_texture().get_image().save_png(out)
	get_tree().quit()
