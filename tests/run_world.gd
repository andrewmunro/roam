extends Node
## Loads the main scene, lets it stream, and reports progress. Optionally drives
## forward and saves screenshots (when not headless).
## Run: godot --path . res://tests/run_world.tscn [-- --shots=dir --drive]
## --touch shows the touch controls; --touch-drive also drives with simulated touches
## (gas pedal, then the steering stick pushed right).

var _main: Node
var _t := 0.0
var _next_report := 0.0
var _shots := ""
var _drive := false
var _drive_after := 0.0
var _report_every := 5.0
var _topdown := 0.0
var _look_around := false
var _look_tunnel := false
var _tunnel_drive := 0  # 0 off, 1 waiting, 2 driving
var _checked := false
var _rebase_test := false
var _rebase_stage := 0
var _rebase_latlon := Vector2.ZERO
var _shot_idx := 0
var _max_frame_ms := 0.0
var _last := 0
var _touch := false
var _touch_drive := false
var _touch_t0 := -1.0
var _touch_stage := 0
var _touch_start := Vector3.ZERO
var _heading0 := Vector3.ZERO

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
		elif a == "--rebase-test":
			_rebase_test = true
		elif a == "--touch":
			_touch = true
		elif a == "--touch-drive":
			_touch = true
			_touch_drive = true
		elif a == "--drive":
			_drive = true
		elif a.begins_with("--drive-after="):
			_drive_after = a.substr(14).to_float()
		elif a == "--tunnel-drive":
			_tunnel_drive = 1
		elif a == "--look-tunnel":
			_look_tunnel = true
		elif a == "--look-around":
			_look_around = true
		elif a.begins_with("--topdown="):
			_topdown = a.substr(10).to_float()
		elif a.begins_with("--every="):
			_report_every = a.substr(8).to_float()
	_main = load("res://scenes/main.tscn").instantiate()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--latlon="):
			var ll := a.substr(9).split(",")
			_main.start_lat = ll[0].to_float()
			_main.start_lon = ll[1].to_float()
			_main.start_label = a.substr(9)
	add_child(_main)
	_last = Time.get_ticks_usec()

func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	var frame_ms := (now - _last) / 1000.0
	_last = now
	if _t > 1.0:
		_max_frame_ms = maxf(_max_frame_ms, frame_ms)
	_t += delta
	var car: Car = _main.get_node("Car")
	if _drive and not car.freeze and _t > _drive_after:
		Input.action_press("accelerate")
	if _touch:
		var tc: TouchControls = _main.get_node("HUD/TouchControls")
		if not tc.active:
			tc.set_active(true)
		if _touch_drive and not car.freeze:
			_run_touch_drive(car, tc)
	if _look_tunnel and not car.freeze:
		_aim_at_tunnel()
	if _tunnel_drive == 1 and not car.freeze and _t > 4.0:
		_start_tunnel_drive(car)
	if _tunnel_drive == 2:
		Input.action_press("accelerate", 0.6)
	if _rebase_test:
		_run_rebase_test(car)
	if not car.freeze and not _checked and _t > 3.0:
		_checked = true
		_check_roads(car)
	if _t >= _next_report:
		_next_report += _report_every
		var world: WorldStreamer = _main.get_node("World")
		var chunks := world.get_children().filter(func(c): return c is Chunk and c.visible)
		var full := chunks.filter(func(c): return c.lod == ChunkBuilder.Lod.FULL).size()
		print("t=%.0fs chunks=%d (full %d) jobs=%d frozen=%s car=%s speed=%.0f km/h worst_frame=%.0f ms" % [
			_t, chunks.size(), full, world._jobs.size(), car.freeze, car.global_position.snapped(Vector3.ONE * 0.1),
			car.speed_kmh(), _max_frame_ms])
		_max_frame_ms = 0.0
		if not car.freeze:
			var p := car.global_position
			var up_hit := car.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
				p + Vector3.UP * 0.5, p + Vector3.UP * 500.0, 2))
			var down_hit := car.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
				p + Vector3.UP * 0.5, p - Vector3.UP * 50.0, 0xFFFFFFFF, [car.get_rid()]))
			var fwd := car.global_transform.basis.z
			var ahead := car.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
				p + Vector3.UP * 0.8, p + Vector3.UP * 0.8 + fwd * 6.0, car.collision_mask, [car.get_rid()]))
			if not ahead.is_empty():
				print("  ahead: %s/%s at %.1f m, normal %s" % [ahead.collider.get_parent().name, ahead.collider.name,
					(ahead.position - p).length(), ahead.normal.snapped(Vector3.ONE * 0.01)])
			print("  vel=%s throttle=%.2f wheels=%s sleeping=%s focus=%s" % [car.linear_velocity.snapped(Vector3.ONE * 0.01),
				Input.get_action_strength("accelerate"), car._wheels.map(func(w): return w.contact),
				car.sleeping, get_viewport().gui_get_focus_owner()])
			car.contact_monitor = true
			car.max_contacts_reported = 6
			var touching := car.get_colliding_bodies().map(func(b): return "%s/%s" % [b.get_parent().name, b.name])
			if not touching.is_empty():
				print("  touching: ", touching)
			print("  in_tunnel=%s terrain_above=%s below=%s" % [car.in_tunnel,
				"none" if up_hit.is_empty() else "%.1f" % up_hit.position.y,
				"none" if down_hit.is_empty() else "%s@%.1f" % [down_hit.collider.name, down_hit.position.y]])
		if _topdown > 0.0 and not car.freeze:
			var cam: Camera3D = _main.get_node("Camera")
			cam.set_process(false)
			cam.global_position = car.global_position + Vector3(0, _topdown, _topdown * 0.6)
			cam.look_at(car.global_position, Vector3.UP)
		if _look_around and not car.freeze:
			var cam: Camera3D = _main.get_node("Camera")
			cam.set_process(false)
			var yaw := _shot_idx * PI / 2.0
			cam.global_position = car.global_position + Vector3(0, 8, 0)
			cam.look_at(cam.global_position + Vector3(sin(yaw), -0.15, cos(yaw)), Vector3.UP)
		if not _shots.is_empty() and not car.freeze:
			var img := get_viewport().get_texture().get_image()
			img.save_png(_shots.path_join("shot_%02d.png" % _shot_idx))
			_shot_idx += 1
	if _t > float(OS.get_environment("RUN_SECONDS") if OS.has_environment("RUN_SECONDS") else "40"):
		get_tree().quit()


## Drives with simulated screen touches: holds the gas pedal, after 3 s pushes the
## steering stick right, releases it at 6 s and the gas at 8 s.
func _run_touch_drive(car: Car, tc: TouchControls) -> void:
	if _touch_t0 < 0.0:
		_touch_t0 = _t
		_touch_start = car.global_position
	var dt := _t - _touch_t0
	var gas := tc.button_rect("accelerate").get_center()
	var stick := tc.stick_home()
	var r := tc.button_rect("accelerate").size.x * 0.72  # roughly the stick radius
	if _touch_stage == 0:
		_screen_touch(0, gas, true)
		print("touch: gas down at %s, start %s" % [gas, _touch_start.snapped(Vector3.ONE * 0.1)])
		_touch_stage = 1
	elif _touch_stage == 1 and dt > 3.0:
		print("touch: after 3 s speed=%.0f km/h moved %.1f m" % [car.speed_kmh(), car.global_position.distance_to(_touch_start)])
		_screen_touch(1, stick, true)
		_screen_drag(1, stick + Vector2(r * 0.9, 0), Vector2(r * 0.9, 0))
		_touch_stage = 2
		_touch_start = car.global_position
		_heading0 = car.global_transform.basis.z
	elif _touch_stage == 2 and dt > 3.2 and dt < 3.4:
		print("touch: steer_right=%.2f steer_left=%.2f accelerate=%.2f" % [Input.get_action_strength("steer_right"),
			Input.get_action_strength("steer_left"), Input.get_action_strength("accelerate")])
		_touch_stage = 3
	elif _touch_stage == 3 and dt > 6.0:
		var h := car.global_transform.basis.z
		var turn := rad_to_deg(Vector2(_heading0.x, _heading0.z).angle_to(Vector2(h.x, h.z)))
		print("touch: steering 3 s turned %.0f deg, speed=%.0f km/h, moved %.1f m" % [turn, car.speed_kmh(),
			car.global_position.distance_to(_touch_start)])
		_screen_touch(1, stick + Vector2(r * 0.9, 0), false)
		_touch_stage = 4
	elif _touch_stage == 4 and dt > 8.0:
		_screen_touch(0, gas, false)
		_touch_stage = 5
	elif _touch_stage == 5 and dt > 8.5:
		print("touch: released, steer=%.2f accelerate=%.2f speed=%.0f km/h" % [Input.get_action_strength("steer_right"),
			Input.get_action_strength("accelerate"), car.speed_kmh()])
		_touch_stage = 6


func _screen_touch(index: int, canvas_pos: Vector2, pressed: bool) -> void:
	var ev := InputEventScreenTouch.new()
	ev.index = index
	ev.pressed = pressed
	ev.position = get_viewport().get_final_transform() * canvas_pos
	Input.parse_input_event(ev)


func _screen_drag(index: int, canvas_pos: Vector2, rel: Vector2) -> void:
	var ev := InputEventScreenDrag.new()
	ev.index = index
	ev.position = get_viewport().get_final_transform() * canvas_pos
	ev.relative = get_viewport().get_final_transform().basis_xform(rel)
	Input.parse_input_event(ev)


## Compares road ribbon heights with the terrain collision directly beneath them.
func _check_roads(car: Car) -> void:
	var world: WorldStreamer = _main.get_node("World")
	var chunk := world.chunk_at(car.global_position)
	var roads: MeshInstance3D = chunk.get_node_or_null("Roads")
	if roads == null:
		print("no roads in chunk")
		return
	var verts: PackedVector3Array = roads.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var space := car.get_world_3d().direct_space_state
	var worst := -INF
	var below := 0
	var worst_info := ""
	for k in range(0, verts.size(), 7):
		var p := chunk.to_global(verts[k])
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 100, p - Vector3.UP * 100, 3, [car.get_rid()]))
		if hit.is_empty() or hit.collider.name != "TerrainCollision":
			continue
		var diff: float = hit.position.y - p.y
		if diff > worst:
			worst = diff
			var col: Node = hit.collider
			worst_info = "%s/%s local=%s" % [col.get_parent().name, col.name, verts[k]]
		if diff > 0.0:
			below += 1
	print("road check: %d samples, %d below terrain, worst %.2f m (chunk %s at %s)" % [verts.size() / 7, below, worst, chunk.tile, chunk.position])
	var meshes := chunk.get_children().filter(func(c): return c is MeshInstance3D).map(func(c): return c.name)
	print("  worst hit: ", worst_info)
	print("chunk children: ", meshes, " total chunks under world: ", world.get_child_count())


## Jumps the car 2.5 km east (forcing a floating-origin shift), then checks that every
## chunk sits exactly where its tile belongs and the car's lat/lon is unchanged.
func _run_rebase_test(car: Car) -> void:
	var world: WorldStreamer = _main.get_node("World")
	if _rebase_stage == 0 and not car.freeze and _t > 4.0:
		var target := car.global_position + Vector3(2500, 0, 0)
		_rebase_latlon = Geo.local_to_latlon(target)
		car.place(target + Vector3.UP * 300.0, Vector3.FORWARD)
		car.freeze = true
		_rebase_stage = 1
		print("rebase test: jumped to ", target, " origin before ", Geo.origin_latlon())
	elif _rebase_stage == 1 and not world.is_loading() and _t > 8.0:
		var worst := 0.0
		for c in world.get_children():
			if c is Chunk:
				worst = maxf(worst, c.position.distance_to(Geo.tile_origin_local(c.tile, Geo.CHUNK_ZOOM)))
		var ll := Geo.local_to_latlon(car.global_position)
		print("rebase test: origin now %s, car local %s, latlon drift %.7f deg, worst chunk offset %.4f m" % [
			Geo.origin_latlon(), car.global_position, (ll - _rebase_latlon).length(), worst])
		print("REBASE PASS" if worst < 0.01 and car.global_position.length() < 2000.0 else "REBASE FAIL")
		_rebase_stage = 2


## Points the camera into the nearest tunnel portal, moving round it on each shot.
func _aim_at_tunnel() -> void:
	var world: WorldStreamer = _main.get_node("World")
	var cam: Camera3D = _main.get_node("Camera")
	var car: Car = _main.get_node("Car")
	var best := Transform3D()
	var best_d := INF
	for c in world.get_children():
		if c is Chunk:
			for box: Transform3D in c.portal_boxes:
				var g: Transform3D = c.transform * box
				var d: float = g.origin.distance_to(car.global_position)
				if d < best_d:
					best_d = d
					best = g
	if best_d == INF:
		print("no tunnels loaded")
		return
	cam.set_process(false)
	var along := best.basis.x.normalized()
	var side := best.basis.z.normalized()
	var offsets := [along * 40.0, -along * 40.0, along * 25.0 + side * 20.0, Vector3.UP * 60.0 + along * 30.0]
	var off: Vector3 = offsets[_shot_idx % offsets.size()]
	var pos := best.origin + off
	var hit := car.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(pos + Vector3.UP * 300, pos - Vector3.UP * 300, 2))
	if not hit.is_empty():
		pos.y = maxf(pos.y + 4.0, hit.position.y + 3.0)
	cam.global_position = pos
	cam.look_at(best.origin, Vector3.UP)


## Puts the car just outside the nearest portal, facing into the tunnel.
func _start_tunnel_drive(car: Car) -> void:
	var world: WorldStreamer = _main.get_node("World")
	var best_d := INF
	var start := Vector3.ZERO
	var dir := Vector3.ZERO
	for c in world.get_children():
		if not c is Chunk:
			continue
		for box: Transform3D in c.portal_boxes:
			var g: Transform3D = c.transform * box
			var d: float = g.origin.distance_to(car.global_position)
			if d >= best_d:
				continue
			var e0: Vector3 = g.origin - g.basis.x
			var e1: Vector3 = g.origin + g.basis.x
			var road_y: float = g.origin.y - g.basis.y.length() + 1.5
			# The mouth is the end where the surface is closest to the road.
			var gap0: float = c.terrain_height(Vector2(e0.x - c.position.x, e0.z - c.position.z)) - road_y
			var gap1: float = c.terrain_height(Vector2(e1.x - c.position.x, e1.z - c.position.z)) - road_y
			var along: Vector3 = g.basis.x.normalized()
			best_d = d
			if gap0 <= gap1:
				start = e0 - along * 25.0
				dir = along
			else:
				start = e1 + along * 25.0
				dir = -along
	if best_d == INF:
		print("tunnel drive: no portal found")
		_tunnel_drive = 0
		return
	var hit := car.get_world_3d().direct_space_state.intersect_ray(
		PhysicsRayQueryParameters3D.create(start + Vector3.UP * 200, start - Vector3.UP * 200))
	if not hit.is_empty():
		start.y = hit.position.y + 0.8
	car.place(start, dir)
	_tunnel_drive = 2
	print("tunnel drive: start %s dir %s" % [start, dir])
