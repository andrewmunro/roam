extends Node
## Loads the main scene, lets it stream, and reports progress. Optionally drives
## forward and saves screenshots (when not headless).
## Run: godot --path . res://tests/run_world.tscn [-- --shots=dir --drive]
## --latlon=lat,lon --heading=deg spawn like a shared link; --cam=lat,lon,h,heading,pitch
## (repeatable) places the camera for each shot in turn (h above whatever the ray hits).
## --no-hud hides the HUD (clean backdrops for UI mockups); --ui=menu, --ui=search:<query> or
## --ui=arrive:<place> (the place name and credits shown after a teleport)
## opens that HUD panel once the world has loaded.
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
var _aerial := 0.0
var _aerial_tilt := 0.35
var _target := Vector2.ZERO  # requested lat/lon
var _look_around := false
var _look_tunnel := false
var _no_hud := false
var _ui := ""  # --ui=search:<query> or --ui=menu: opens that HUD panel once the world is ready
var _cams: Array[PackedFloat64Array] = []  # --cam=lat,lon,h,heading,pitch (repeatable): one per shot
var _map_click := Vector2.INF  # --map-click=dx,dy: simulated minimap click (pixels from centre)
var _tunnel_drive := 0  # 0 off, 1 waiting, 2 driving
var _checked := false
var _collision_check := false
var _knock := 0  # --knock: 1 waiting, 2 driving at a lamp, 3 done
var _knock_target := Vector3.ZERO
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
		elif a == "--knock":
			_knock = 1
		elif a == "--collision-check":
			_collision_check = true
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
		elif a.begins_with("--map-click="):
			var v := a.substr(12).split(",")
			_map_click = Vector2(v[0].to_float(), v[1].to_float())
		elif a == "--look-tunnel":
			_look_tunnel = true
		elif a == "--look-around":
			_look_around = true
		elif a.begins_with("--topdown="):
			_topdown = a.substr(10).to_float()
		elif a.begins_with("--aerial="):
			var parts := a.substr(9).split(",")
			_aerial = parts[0].to_float()
			if parts.size() > 1:
				_aerial_tilt = parts[1].to_float()
		elif a.begins_with("--cam="):
			var c := PackedFloat64Array()
			for v in a.substr(6).split(","):
				c.append(v.to_float())
			_cams.append(c)
		elif a.begins_with("--ui="):
			_ui = a.substr(5)
		elif a == "--no-hud":
			_no_hud = true
		elif a.begins_with("--every="):
			_report_every = a.substr(8).to_float()
	_main = load("res://scenes/main.tscn").instantiate()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--latlon="):
			var ll := a.substr(9).split(",")
			_main.start_lat = ll[0].to_float()
			_main.start_lon = ll[1].to_float()
			_main.start_label = a.substr(9)
			_target = Vector2(ll[0].to_float(), ll[1].to_float())
		elif a.begins_with("--heading="):
			_main._spawn_heading = a.substr(10).to_float()
	add_child(_main)
	if _no_hud:
		_main.get_node("HUD").visible = false
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
	if _map_click != Vector2.INF and not car.freeze and _t > 5.0:
		var hud: Node = _main.get_node("HUD")
		var before := car.global_position
		var fwd := car.global_transform.basis.z
		hud._on_map_clicked(_map_click)
		var after := car.global_position
		var rel := after - before
		print("map click %s: moved %.0f m (%.0f m ahead, %.0f m right), heading %s" % [_map_click, Vector2(rel.x, rel.z).length(),
			rel.dot(fwd), rel.dot(fwd.cross(Vector3.UP)), MinimapOverlay.heading_text(hud._heading())])
		_map_click = Vector2.INF
	if _knock == 1 and not car.freeze and _t > 5.0:
		_start_knock(car)
	elif _knock == 2:
		Input.action_press("accelerate", 0.7)
		if _t > 13.0:
			_knock = 3
			var debris := 0
			for c in _main.get_node("World").get_children():
				for n in c.get_children():
					if n is RigidBody3D:
						debris += 1
						print("knock: debris %s at %s, upright %.2f, speed %.1f m/s" % [n.get_child(0).mesh.resource_name,
							n.global_position.snapped(Vector3.ONE * 0.1), n.global_transform.basis.y.dot(Vector3.UP),
							n.linear_velocity.length()])
			print("knock: %d props knocked over, car speed %.0f km/h at %s (lamp was at %s)" % [debris,
				car.speed_kmh(), car.global_position.snapped(Vector3.ONE * 0.1), _knock_target.snapped(Vector3.ONE * 0.1)])
	if _collision_check and not car.freeze and _t > 6.0:
		_collision_check = false
		_check_collision()
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
		if _aerial > 0.0 and not car.freeze:
			# Looks down at the requested spot (not the car), turning a quarter per shot.
			var cam: Camera3D = _main.get_node("Camera")
			cam.set_process(false)
			var spot := Geo.latlon_to_local(_target.x, _target.y)
			var hit := car.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
				spot + Vector3.UP * 2000, spot - Vector3.UP * 2000, 2))
			if not hit.is_empty():
				spot.y = hit.position.y
			var yaw := _shot_idx * PI / 2.0
			cam.global_position = spot + Vector3(sin(yaw), 0, cos(yaw)) * _aerial * _aerial_tilt + Vector3.UP * _aerial
			cam.look_at(spot, Vector3.UP if _aerial_tilt > 0.01 else Vector3.FORWARD)
		if _look_around and not car.freeze:
			var cam: Camera3D = _main.get_node("Camera")
			cam.set_process(false)
			var yaw := _shot_idx * PI / 2.0
			cam.global_position = car.global_position + Vector3(0, 8, 0)
			cam.look_at(cam.global_position + Vector3(sin(yaw), -0.15, cos(yaw)), Vector3.UP)
		# Shots wait for streaming to settle (software rendering is slow to catch up).
		var settled: bool = not car.freeze and not (_main.get_node("World") as WorldStreamer).is_loading()
		if not _ui.is_empty() and settled:
			var hud: Node = _main.get_node("HUD")
			if _ui == "menu":
				hud._set_menu_open(true)
				hud._credits_box.visible = true
			elif _ui.begins_with("arrive:"):
				hud.arrive(_ui.substr(7))
			elif _ui.begins_with("search:"):
				hud._open_search()
				hud._search.text = _ui.substr(7)
				hud._on_submit(_ui.substr(7))
			_ui = ""
		if not _cams.is_empty() and settled:
			_place_cam(_cams[mini(_shot_idx, _cams.size() - 1)])
		if not _shots.is_empty() and settled:
			_save_shot(_shots.path_join("shot_%02d.png" % _shot_idx))
			_shot_idx += 1
	if _t > float(OS.get_environment("RUN_SECONDS") if OS.has_environment("RUN_SECONDS") else "40"):
		get_tree().quit()


## Puts the camera h metres above the ground (or road) at lat,lon, looking along heading
## (degrees clockwise from north) and pitch (degrees, negative looks down).
func _place_cam(c: PackedFloat64Array) -> void:
	var cam: Camera3D = _main.get_node("Camera")
	cam.set_process(false)
	var p := Geo.latlon_to_local(c[0], c[1])
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
		p + Vector3.UP * 500, p - Vector3.UP * 500))
	p.y = (hit.position.y if not hit.is_empty() else 0.0) + c[2]
	var yaw := deg_to_rad(c[3])
	var pitch := deg_to_rad(c[4])
	cam.global_position = p
	cam.look_at(p + Vector3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)), Vector3.UP)


## Saves the viewport once the frame with this frame's camera moves has been drawn.
func _save_shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("shot: ", path)


## Drives with simulated screen touches on the floating stick: a finger lands mid-screen
## and pushes up (throttle), after 3 s also right (steer), at 6 s back to straight up,
## at 8 s down (brake), then lifts at 10 s.
func _run_touch_drive(car: Car, tc: TouchControls) -> void:
	if _touch_t0 < 0.0:
		_touch_t0 = _t
		_touch_start = car.global_position
	var dt := _t - _touch_t0
	var r := tc.stick_radius()
	var origin := get_viewport().get_visible_rect().size * Vector2(0.4, 0.65)
	if _touch_stage == 0:
		_screen_touch(0, origin, true)
		_screen_drag(0, origin + Vector2(0, -r), Vector2(0, -r))
		print("touch: stick at %s pushed up, start %s" % [origin, _touch_start.snapped(Vector3.ONE * 0.1)])
		_touch_stage = 1
	elif _touch_stage == 1 and dt > 3.0:
		print("touch: after 3 s speed=%.0f km/h moved %.1f m accelerate=%.2f" % [car.speed_kmh(),
			car.global_position.distance_to(_touch_start), Input.get_action_strength("accelerate")])
		_screen_drag(0, origin + Vector2(r * 0.7, -r * 0.7), Vector2(r * 0.7, r * 0.3))
		_touch_stage = 2
		_touch_start = car.global_position
		_heading0 = car.global_transform.basis.z
	elif _touch_stage == 2 and dt > 3.2:
		print("touch: steer_right=%.2f steer_left=%.2f accelerate=%.2f" % [Input.get_action_strength("steer_right"),
			Input.get_action_strength("steer_left"), Input.get_action_strength("accelerate")])
		_touch_stage = 3
	elif _touch_stage == 3 and dt > 6.0:
		var h := car.global_transform.basis.z
		var turn := rad_to_deg(Vector2(_heading0.x, _heading0.z).angle_to(Vector2(h.x, h.z)))
		print("touch: steering 3 s turned %.0f deg, speed=%.0f km/h" % [turn, car.speed_kmh()])
		_screen_drag(0, origin + Vector2(0, -r), Vector2(-r * 0.7, -r * 0.3))
		_touch_stage = 4
	elif _touch_stage == 4 and dt > 8.0:
		_screen_drag(0, origin + Vector2(0, r), Vector2(0, 2.0 * r))
		print("touch: pulled down at %.0f km/h, brake=%.2f" % [car.speed_kmh(), Input.get_action_strength("brake")])
		_touch_stage = 5
	elif _touch_stage == 5 and dt > 10.0:
		print("touch: after 2 s braking speed=%.0f km/h" % car.speed_kmh())
		_screen_touch(0, origin + Vector2(0, r), false)
		_touch_stage = 6
	elif _touch_stage == 6 and dt > 10.5:
		print("touch: released, steer=%.2f accelerate=%.2f brake=%.2f" % [Input.get_action_strength("steer_right"),
			Input.get_action_strength("accelerate"), Input.get_action_strength("brake")])
		_touch_stage = 7


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
	var arrays := roads.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var space := car.get_world_3d().direct_space_state
	var worst := -INF
	var below := 0
	var worst_info := ""
	for k in range(0, verts.size(), 7):
		# Kerb feet and pavement skirts are meant to reach into the ground.
		var ck := Vector3(cols[k].r, cols[k].g, cols[k].b)
		if ck.distance_to(Vector3(RoadNetwork.VERGE.r, RoadNetwork.VERGE.g, RoadNetwork.VERGE.b)) < 0.02 				or ck.distance_to(Vector3(RoadNetwork.KERB_COLOR.r, RoadNetwork.KERB_COLOR.g, RoadNetwork.KERB_COLOR.b)) < 0.02:
			continue
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
			if diff > 0.3 and OS.has_environment("ROAM_ROAD_CHECK_VERBOSE"):
				print("  below %.2f m: colour %s uv2 %s at %s" % [diff, cols[k], (arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array)[k], verts[k]])
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


## Road surface vs terrain collision (how far roads float), and terrain height
## mismatches along shared edges of neighbouring full chunks.
func _check_collision() -> void:
	var world: WorldStreamer = _main.get_node("World")
	var chunks: Dictionary = world._chunks
	var gaps := PackedFloat32Array()
	for t: Vector2i in chunks:
		var c: Chunk = chunks[t]
		if c.lod != ChunkBuilder.Lod.FULL:
			continue
		var roads: MeshInstance3D = c.get_node_or_null("Roads")
		if roads == null:
			continue
		var verts: PackedVector3Array = roads.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for k in range(0, verts.size(), 11):
			var v := verts[k]
			gaps.append(v.y - c.terrain_height(Vector2(v.x, v.z)))
	gaps.sort()
	var n := gaps.size()
	print("road above terrain: n=%d median %.2f p90 %.2f p99 %.2f max %.2f m" % [n, gaps[n / 2], gaps[n * 9 / 10],
		gaps[n * 99 / 100], gaps[n - 1]])
	var worst := 0.0
	var where := ""
	var bad := 0
	var total := 0
	for t: Vector2i in chunks:
		var a: Chunk = chunks[t]
		if a.lod != ChunkBuilder.Lod.FULL or a._heights.is_empty():
			continue
		for off: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			var b: Chunk = chunks.get(t + off)
			if b == null or b.lod != ChunkBuilder.Lod.FULL or b._heights.is_empty():
				continue
			var n2 := a._grid_n
			for k in n2:
				var ha: float
				var hb: float
				if off.x == 1:
					ha = a._heights[k * n2 + n2 - 1]
					hb = b._heights[k * n2]
				else:
					ha = a._heights[(n2 - 1) * n2 + k]
					hb = b._heights[k]
				var d := absf(ha - hb)
				total += 1
				if d > 0.05:
					bad += 1
				if d > worst:
					worst = d
					where = "%s|%s k=%d (%.2f vs %.2f)" % [t, t + off, k, ha, hb]
	print("seam mismatch: %d of %d edge vertices > 5 cm, worst %.2f m at %s" % [bad, total, worst, where])


## Lines the car up 25 m behind the nearest street lamp and drives into it.
func _start_knock(car: Car) -> void:
	var best := INF
	for c in _main.get_node("World").get_children():
		for body in c.get_children():
			if body is StaticBody3D and body.has_meta("knock") and body.get_meta("knock").role == "lamp_road":
				for cs in body.get_children():
					var p: Vector3 = cs.global_position
					var d := p.distance_to(car.global_position)
					if d < best:
						best = d
						_knock_target = p
	if best == INF:
		print("knock: no lamps loaded")
		_knock = 3
		return
	# Approach along the nearest road, in line with the lamp (as a driver veering off would).
	var dir := Vector3(1, 0, 0.3).normalized()
	var road_d := INF
	for c in _main.get_node("World").get_children():
		if not c is Chunk:
			continue
		for road: Dictionary in c.road_spawn:
			var pts: PackedVector3Array = road.pts
			for k in range(1, pts.size() - 1):
				var d: float = (pts[k] + c.position).distance_to(_knock_target)
				if d < road_d:
					road_d = d
					dir = pts[k + 1] - pts[k - 1]
	dir = Vector3(dir.x, 0, dir.z).normalized()
	var start := _knock_target - dir * 25.0
	var hit := car.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
		start + Vector3.UP * 100, start - Vector3.UP * 100, 3, [car.get_rid()]))
	start.y = (hit.position.y if not hit.is_empty() else _knock_target.y) + 0.8
	car.place(start, dir)
	print("knock: lamp at %s, car starts %s" % [_knock_target.snapped(Vector3.ONE * 0.1), start.snapped(Vector3.ONE * 0.1)])
	_knock = 2
