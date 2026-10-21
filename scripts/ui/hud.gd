extends CanvasLayer
## Speed/coords readout, minimap, location search, controls help and touch controls.
## Built in code; switches to a compact layout on narrow (portrait) screens.

signal teleport_requested(lat: float, lon: float, label: String)

const NOMINATIM := "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=6&q=%s"
const MINIMAP_SIZE := 220
const MINIMAP_SIZE_NARROW := 150
const NARROW_WIDTH := 1000.0  # canvas units below which the compact layout is used
const MINIMAP_SPAN := 700.0  # metres shown across

@export var car: Car
@export var streamer: WorldStreamer

var _speed_label: Label
var _road_label: Label
var _area_label: Label
var _settlement := ""
var _describe_timer := 0.0
var _info_label: Label
var _info_box: VBoxContainer
var _status_label: Label
var _search_column: VBoxContainer
var _search: LineEdit
var _results: ItemList
var _result_coords: Array[Vector2] = []
var _minimap_cam: Camera3D
var _minimap_panel: Control
var _minimap_view: SubViewportContainer
var _minimap_marker: Polygon2D
var _help: Label
var _touch: TouchControls
var _last_search_msec := -10000


func _ready() -> void:
	_touch = TouchControls.new()
	_touch.name = "TouchControls"
	add_child(_touch)
	_build_info()
	_build_minimap()
	_build_search()  # after the minimap so search results draw (and click) over it
	_build_help()
	_touch.active_changed.connect(func(_on: bool) -> void: _layout())
	get_viewport().size_changed.connect(_layout)
	_layout()


func _build_info() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(16, 12)
	_info_box = box
	add_child(box)
	_speed_label = _label(36)
	_road_label = _label(20)
	_area_label = _label(15)
	_area_label.modulate = Color(1, 1, 1, 0.85)
	_info_label = _label(13)
	_info_label.modulate = Color(1, 1, 1, 0.7)
	_status_label = _label(16)
	_status_label.modulate = Color(1, 0.9, 0.5)
	for l in [_speed_label, _road_label, _area_label, _info_label, _status_label]:
		box.add_child(l)


func _build_search() -> void:
	var column := VBoxContainer.new()
	_search_column = column
	add_child(column)
	var row := HBoxContainer.new()
	column.add_child(row)
	_search = LineEdit.new()
	_search.placeholder_text = "Search a place or enter lat, lon…"
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
	_minimap_panel = panel
	add_child(panel)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	_minimap_view = svc
	panel.add_child(svc)
	var vp := SubViewport.new()
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
	_minimap_marker = marker
	svc.add_child(marker)


func _build_help() -> void:
	var help := _label(13)
	_help = help
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


## Places the top widgets for the current screen shape. Portrait screens get a larger UI
## scale (so text stays readable on phones), a full-width search bar and a smaller map.
func _layout() -> void:
	var win := Vector2(get_window().size)
	if win.x <= 0.0 or win.y <= 0.0:
		return
	var base := Vector2(ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height"))
	var factor := 1.0
	if win.y > win.x:
		# canvas_items stretch fits the base width here; scale up so the short side
		# spans base.y units, as it does in landscape.
		factor = maxf(1.0, base.x / base.y)
	if not is_equal_approx(get_window().content_scale_factor, factor):
		get_window().content_scale_factor = factor  # emits size_changed, which re-runs this
		return
	var view := get_viewport().get_visible_rect().size
	var narrow := view.x < NARROW_WIDTH
	var map_size := MINIMAP_SIZE_NARROW if narrow else MINIMAP_SIZE
	_minimap_view.custom_minimum_size = Vector2(map_size, map_size)
	_minimap_marker.position = Vector2(map_size, map_size) * 0.5
	_minimap_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	var top := 12.0
	if narrow:
		# Search bar across the top, info and map below it.
		_search_column.anchor_left = 0.0
		_search_column.anchor_right = 1.0
		_search_column.offset_left = 16
		_search_column.offset_right = -16
		_search.custom_minimum_size.y = 40
		top = 12.0 + 40.0 + 10.0
	else:
		_search_column.anchor_left = 0.5
		_search_column.anchor_right = 0.5
		_search_column.offset_left = -210
		_search_column.offset_right = 210
		_search.custom_minimum_size.y = 0
	_search_column.offset_top = 12
	_info_box.position = Vector2(16, top)
	var panel_size := _minimap_panel.get_combined_minimum_size()
	_minimap_panel.offset_left = -panel_size.x - 16
	_minimap_panel.offset_right = -16
	_minimap_panel.offset_top = top
	_minimap_panel.offset_bottom = top + panel_size.y
	_help.visible = not _touch.active and not narrow


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


func _process(delta: float) -> void:
	if car == null:
		return
	_describe_timer -= delta
	if _describe_timer <= 0.0 and streamer:
		_describe_timer = 0.25
		var where := streamer.describe(car.global_position)
		if not where.settlement.is_empty():
			_settlement = where.settlement  # keep the last town seen; it may be out of range
		_road_label.text = where.road
		var parts := []
		for s: String in [where.area, _settlement]:
			if not s.is_empty() and not parts.has(s):
				parts.append(s)
		_area_label.text = " · ".join(parts)
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
	_settlement = ""
	_results.visible = false
	_search.release_focus()
	teleport_requested.emit(lat, lon, label)
