extends CanvasLayer
## Speed/coords readout, minimap, location search and controls help. Built in code.

signal teleport_requested(lat: float, lon: float, label: String)

const NOMINATIM := "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=6&q=%s"
const MINIMAP_SIZE := 220
const MINIMAP_SPAN := 700.0  # metres shown across

@export var car: Car
@export var streamer: WorldStreamer

var _speed_label: Label
var _info_label: Label
var _status_label: Label
var _search: LineEdit
var _results: ItemList
var _result_coords: Array[Vector2] = []
var _minimap_cam: Camera3D
var _minimap_panel: Control
var _last_search_msec := -10000


func _ready() -> void:
	_build_info()
	_build_search()
	_build_minimap()
	_build_help()


func _build_info() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(16, 12)
	add_child(box)
	_speed_label = _label(36)
	_info_label = _label(14)
	_status_label = _label(16)
	_status_label.modulate = Color(1, 0.9, 0.5)
	for l in [_speed_label, _info_label, _status_label]:
		box.add_child(l)


func _build_search() -> void:
	var column := VBoxContainer.new()
	column.anchor_left = 0.5
	column.anchor_right = 0.5
	column.offset_left = -210
	column.offset_right = 210
	column.offset_top = 12
	add_child(column)
	var row := HBoxContainer.new()
	column.add_child(row)
	_search = LineEdit.new()
	_search.placeholder_text = "Search a place or enter lat, lon�"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(_on_search)
	row.add_child(_search)
	var go := Button.new()
	go.text = "Go"
	go.pressed.connect(func() -> void: _on_search(_search.text))
	row.add_child(go)
	_results = ItemList.new()
	_results.visible = false
	_results.auto_height = true
	_results.item_activated.connect(_on_result)
	_results.item_clicked.connect(func(i: int, _p: Vector2, _b: int) -> void: _on_result(i))
	column.add_child(_results)


func _build_minimap() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-MINIMAP_SIZE - 16, 12)
	_minimap_panel = panel
	add_child(panel)
	var svc := SubViewportContainer.new()
	svc.custom_minimum_size = Vector2(MINIMAP_SIZE, MINIMAP_SIZE)
	svc.stretch = true
	panel.add_child(svc)
	var vp := SubViewport.new()
	vp.size = Vector2i(MINIMAP_SIZE, MINIMAP_SIZE)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	svc.add_child(vp)
	_minimap_cam = Camera3D.new()
	_minimap_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_minimap_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_minimap_cam.size = MINIMAP_SPAN
	_minimap_cam.cull_mask = Chunk.MINIMAP_LAYER
	_minimap_cam.far = 4000.0
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.24, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.0
	_minimap_cam.environment = env
	vp.add_child(_minimap_cam)
	# Car marker
	var marker := Polygon2D.new()
	marker.polygon = PackedVector2Array([Vector2(0, -9), Vector2(6, 7), Vector2(0, 3), Vector2(-6, 7)])
	marker.color = Color(1, 0.35, 0.2)
	marker.position = Vector2(MINIMAP_SIZE, MINIMAP_SIZE) * 0.5
	svc.add_child(marker)


func _build_help() -> void:
	var help := _label(13)
	help.text = "W/S drive · A/D steer · Space handbrake · Shift boost · R reset · M map · right-drag look · wheel zoom"
	help.modulate = Color(1, 1, 1, 0.75)
	help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	help.position = Vector2(16, -30)
	add_child(help)
	var credit := _label(11)
	credit.text = "© OpenStreetMap contributors · OpenFreeMap · Terrain: Mapzen/AWS"
	credit.modulate = Color(1, 1, 1, 0.6)
	credit.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	credit.position = Vector2(-380, -24)
	add_child(credit)


func _label(font_size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("outline_size", 4)
	return l


func set_status(text: String) -> void:
	_status_label.text = text


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_map"):
		_minimap_panel.visible = not _minimap_panel.visible
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_results.visible = false
		_search.release_focus()


func _process(_delta: float) -> void:
	if car == null:
		return
	_speed_label.text = "%d km/h" % roundi(absf(car.speed_kmh()))
	var ll := Geo.local_to_latlon(car.global_position)
	_info_label.text = "%.5f, %.5f   alt %d m   %d fps" % [ll.x, ll.y, roundi(car.global_position.y),
		Engine.get_frames_per_second()]
	if _minimap_cam.is_inside_tree():
		var xf := car.get_global_transform_interpolated()
		var fwd := Vector3(xf.basis.z.x, 0.0, xf.basis.z.z)
		if fwd.length_squared() > 1e-4:
			# Looking straight down with the car's heading pointing up the screen.
			fwd = fwd.normalized()
			var basis := Basis(fwd.cross(Vector3.UP), fwd, Vector3.UP)
			_minimap_cam.global_transform = Transform3D(basis, xf.origin + Vector3.UP * 1500.0)


func _on_search(text: String) -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	# Direct "lat, lon" input.
	var parts := text.replace(" ", "").split(",")
	if parts.size() == 2 and parts[0].is_valid_float() and parts[1].is_valid_float():
		_go(parts[0].to_float(), parts[1].to_float(), text)
		return
	# Nominatim usage policy: at most one request per second.
	if Time.get_ticks_msec() - _last_search_msec < 1000:
		return
	_last_search_msec = Time.get_ticks_msec()
	var headers := PackedStringArray()
	if not OS.has_feature("web"):
		headers.append("User-Agent: Roam/0.1 (Godot driving game)")
	set_status("Searching…")
	Fetch.request(NOMINATIM % text.uri_encode(), _on_search_result, -10.0, false, headers)


func _on_search_result(ok: bool, body: PackedByteArray) -> void:
	set_status("")
	var data: Variant = JSON.parse_string(body.get_string_from_utf8()) if ok else null
	_results.clear()
	_result_coords.clear()
	if not data is Array or data.is_empty():
		_results.add_item("No results")
		_results.set_item_disabled(0, true)
		_result_coords.append(Vector2.INF)
	else:
		for r: Dictionary in data:
			_results.add_item(str(r.get("display_name", "?")))
			_result_coords.append(Vector2(float(r.lat), float(r.lon)))
	_results.visible = true


func _on_result(index: int) -> void:
	if index < 0 or index >= _result_coords.size() or _result_coords[index] == Vector2.INF:
		return
	var c := _result_coords[index]
	_go(c.x, c.y, _results.get_item_text(index))


func _go(lat: float, lon: float, label: String) -> void:
	_results.visible = false
	_search.release_focus()
	teleport_requested.emit(lat, lon, label)
