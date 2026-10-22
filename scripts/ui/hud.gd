extends CanvasLayer
## The driving HUD: speed and road, a round minimap, search and settings behind icon
## buttons, and a launch screen (place name, controls, data credits) that fades once
## the player starts driving. Quiet by default; everything else on request.
## Sizes follow the mockups: designed at 720 px tall (desktop) or 412 px wide (portrait
## phone) and scaled with the short screen edge, never below a readable minimum.

signal teleport_requested(lat: float, lon: float, label: String)
signal road_teleport_requested(global_pos: Vector3)  ## minimap click: nearest road to here
signal world_rebuild_requested  ## a setting changed how chunks are built

const NOMINATIM := "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=6&q=%s"
const MINIMAP_SPAN := 700.0  # default metres shown across
const MINIMAP_SPAN_MIN := 150.0
const MINIMAP_SPAN_MAX := 5000.0  # roughly the loaded area
const SETTINGS_PATH := "user://settings.cfg"
const CREDIT_LINE := "© OpenStreetMap contributors · OpenFreeMap © OpenMapTiles · Terrain: Mapzen"
const CREDITS := "Map data © OpenStreetMap contributors, available under the Open Database Licence.\n" \
	+ "Vector tiles: OpenFreeMap, © OpenMapTiles.\n" \
	+ "Terrain: Mapzen Terrain Tiles on AWS (SRTM, GMTED2010, NED, ETOPO1 and others).\n" \
	+ "Junctions, lamps and trees: Overpass API. Search: Nominatim.\n" \
	+ "Models: Low Poly Ultimate Pack. Typeface: Manrope (SIL Open Font Licence)."
const COPYRIGHT_URL := "https://www.openstreetmap.org/copyright"
const FADE_SPEED := 2.5  # alpha per second
const LAUNCH_CREDIT_TIME := 8.0  # the credit fades after this, or when driving starts
const ARRIVAL_TIME := 5.0  # place name and credit after a teleport

@export var car: Car
@export var streamer: WorldStreamer

var _u := 1.0  # canvas units per mockup pixel
var _px := 1.0  # canvas units per CSS pixel
var _narrow := false
var _styled: Array[Array] = []  # [label, mockup size, minimum CSS size, weight, letter spacing]

# Driving readout
var _speed_box: VBoxContainer
var _speed_label: Label
var _unit_label: Label
var _road_label: Label
var _area_label: Label
var _settlement := ""
var _describe_timer := 0.0
var _debug_label: Label
var _toast: PanelContainer
var _status_label: Label

# Minimap
var _map: Control
var _minimap_cam: Camera3D
var _minimap_view: SubViewportContainer
var _minimap_overlay: MinimapOverlay
var _minimap_span := MINIMAP_SPAN

# Search and settings
var _search_btn: HudIconButton
var _menu_btn: HudIconButton
var _search_panel: PanelContainer
var _search: LineEdit
var _search_close: HudIconButton
var _results: VBoxContainer
var _search_msg: Label
var _result_coords: Array[Vector2] = []
var _result_names: Array[String] = []
var _results_query := ""  # the (stripped) query whose results are listed; "" when none
var _selected := -1
var _last_search_msec := -10000
var _pending_query := ""
var _menu_panel: PanelContainer
var _menu_rows: VBoxContainer
var _credits_box: VBoxContainer
var _units_hint: Label
var _debug_hint: Label
var _roads_hint: Label

# Launch screen
var _intro: Control
var _wordmark: Label
var _place_box: VBoxContainer
var _place_title: Label
var _place_sub: Label
var _card: PanelContainer
var _credit: Label
var _showing_controls := true  # until the first throttle or steer input
var _place_timer := 0.0
var _credit_timer := LAUNCH_CREDIT_TIME
var _place_from_world := false  # the place name comes from the map once it has loaded

var _mph := false
var _debug := false
var _touch: TouchControls


func _ready() -> void:
	_load_settings()
	_touch = TouchControls.new()
	_touch.name = "TouchControls"
	add_child(_touch)
	_build_intro()
	_build_readout()
	_build_minimap()
	_build_buttons()
	_build_search()  # after the minimap so search results draw (and click) over it
	_build_menu()
	_touch.exclude = [_map, _search_panel, _menu_panel, _search_btn, _menu_btn]
	_touch.active_changed.connect(func(_on: bool) -> void: _layout())
	get_viewport().size_changed.connect(_layout)
	_layout()


# --- Building ------------------------------------------------------------------------

func _label(mock_size: float, min_css: float, weight: int, spacing := 0) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_styled.append([l, mock_size, min_css, weight, spacing])
	return l


func _build_readout() -> void:
	_speed_box = VBoxContainer.new()
	_speed_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_speed_box)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	_speed_box.add_child(row)
	_speed_label = _label(64, 30, HudStyle.LIGHT)
	_unit_label = _label(15, 10.5, HudStyle.SEMIBOLD, 2)
	_unit_label.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(_speed_label)
	row.add_child(_unit_label)
	_road_label = _label(17, 13, HudStyle.SEMIBOLD)
	_area_label = _label(14, 11.5, HudStyle.MEDIUM)
	for l in [_road_label, _area_label]:
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.clip_text = true
		_speed_box.add_child(l)
	_debug_label = _label(12.5, 10.5, HudStyle.MEDIUM)
	_debug_label.visible = _debug
	add_child(_debug_label)
	_toast = PanelContainer.new()
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	_status_label = _label(14, 12, HudStyle.MEDIUM)
	_toast.add_child(_status_label)
	add_child(_toast)


func _build_minimap() -> void:
	_map = Control.new()
	add_child(_map)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var round_mask := ShaderMaterial.new()
	round_mask.shader = preload("res://shaders/round_mask.gdshader")
	svc.material = round_mask
	_minimap_view = svc
	_map.add_child(svc)
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
	env.background_color = Color(0.13, 0.17, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 1.0
	_minimap_cam.environment = env
	vp.add_child(_minimap_cam)
	_minimap_overlay = MinimapOverlay.new()
	_minimap_overlay.zoom_requested.connect(func(f: float) -> void:
		_minimap_span = clampf(_minimap_span * f, MINIMAP_SPAN_MIN, MINIMAP_SPAN_MAX)
		_minimap_cam.size = _minimap_span)
	_minimap_overlay.map_clicked.connect(_on_map_clicked)
	_map.add_child(_minimap_overlay)


func _build_buttons() -> void:
	_search_btn = HudIconButton.new("search", "Search a place (/)")
	_search_btn.pressed.connect(_open_search)
	add_child(_search_btn)
	_menu_btn = HudIconButton.new("settings", "Settings")
	_menu_btn.pressed.connect(func() -> void: _set_menu_open(not _menu_panel.visible))
	add_child(_menu_btn)


func _build_search() -> void:
	_search_panel = PanelContainer.new()
	_search_panel.visible = false
	add_child(_search_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	_search_panel.add_child(column)
	var row := HBoxContainer.new()
	column.add_child(row)
	_search = LineEdit.new()
	_search.placeholder_text = "Search a place or enter lat, lon"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_submitted.connect(_on_submit)
	_search.text_changed.connect(_on_search_edited)
	_search.gui_input.connect(_on_search_key)
	for state: String in ["normal", "focus", "read_only"]:
		_search.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	_search.add_theme_color_override("font_color", HudStyle.INK)
	_search.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.62))
	_search.add_theme_color_override("caret_color", HudStyle.AMBER)
	_search.add_theme_color_override("selection_color", Color(HudStyle.AMBER, 0.35))
	row.add_child(_search)
	_search_close = HudIconButton.new("close", "Close (Esc)")
	_search_close.pressed.connect(_close_search)
	row.add_child(_search_close)
	_results = VBoxContainer.new()
	_results.add_theme_constant_override("separation", 0)
	column.add_child(_results)
	_search_msg = _label(13, 11.5, HudStyle.MEDIUM)
	_search_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_search_msg.visible = false
	column.add_child(_search_msg)


func _build_menu() -> void:
	_menu_panel = PanelContainer.new()
	_menu_panel.visible = false
	add_child(_menu_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	_menu_panel.add_child(column)
	_menu_rows = VBoxContainer.new()
	_menu_rows.add_theme_constant_override("separation", 0)
	column.add_child(_menu_rows)
	_menu_row("Show controls", "H", func() -> void:
		_set_menu_open(false)
		_show_controls(true))
	_units_hint = _menu_row("Speed in", "", func() -> void:
		_mph = not _mph
		_save_settings()
		_update_menu_hints())
	_debug_hint = _menu_row("Location and fps", "F3", func() -> void: _set_debug(not _debug))
	_roads_hint = _menu_row("Road surface", "", func() -> void:
		RoadNetwork.use_mask = not RoadNetwork.use_mask
		_save_settings()
		_update_menu_hints()
		world_rebuild_requested.emit())
	_menu_row("Data credits", "", func() -> void: _credits_box.visible = not _credits_box.visible)
	_credits_box = VBoxContainer.new()
	_credits_box.visible = false
	column.add_child(_credits_box)
	var text := _label(12, 11, HudStyle.MEDIUM)
	text.text = CREDITS
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_credits_box.add_child(text)
	var link := _label(12.5, 11, HudStyle.SEMIBOLD)
	link.text = "openstreetmap.org/copyright ↗"
	link.add_theme_color_override("font_color", HudStyle.AMBER)
	link.mouse_filter = Control.MOUSE_FILTER_STOP
	link.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	link.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			OS.shell_open(COPYRIGHT_URL))
	_credits_box.add_child(link)
	_update_menu_hints()


## A clickable row in the settings menu; returns its right-hand hint label.
func _menu_row(text: String, hint: String, action: Callable) -> Label:
	var row := _row_panel()
	var box := HBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(box)
	var l := _label(14, 12, HudStyle.MEDIUM)
	l.text = text
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(l)
	var h := _label(12.5, 11, HudStyle.SEMIBOLD)
	h.text = hint
	h.modulate = Color(1, 1, 1, 0.75)
	box.add_child(h)
	row.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			action.call())
	_menu_rows.add_child(row)
	return h


## A full-width row that highlights under the pointer (menu items, search results).
func _row_panel() -> PanelContainer:
	var row := PanelContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.mouse_entered.connect(func() -> void: row.add_theme_stylebox_override("panel", _row_style(true)))
	row.mouse_exited.connect(func() -> void: row.add_theme_stylebox_override("panel", _row_style(false)))
	row.add_theme_stylebox_override("panel", _row_style(false))
	return row


func _row_style(on: bool, accent := false) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1, 1, 1, 0.1) if on else Color(0, 0, 0, 0)
	box.content_margin_left = 16.0 * _u
	box.content_margin_right = 16.0 * _u
	box.content_margin_top = 9.0 * _u
	box.content_margin_bottom = 9.0 * _u
	if accent:
		box.border_color = HudStyle.AMBER
		box.border_width_left = maxi(2, roundi(3.0 * _u))
	return box


func _build_intro() -> void:
	_intro = Control.new()
	_intro.set_anchors_preset(Control.PRESET_FULL_RECT)
	_intro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_intro)
	_wordmark = _label(15, 12, HudStyle.SEMIBOLD, 5)
	_wordmark.text = "roam"
	_intro.add_child(_wordmark)
	_place_box = VBoxContainer.new()
	_place_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_intro.add_child(_place_box)
	_place_title = _label(34, 22, HudStyle.LIGHT)
	_place_sub = _label(14, 11.5, HudStyle.MEDIUM, 1)
	for l in [_place_title, _place_sub]:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_place_box.add_child(l)
	_card = PanelContainer.new()
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_intro.add_child(_card)
	_credit = _label(11.5, 10.5, HudStyle.MEDIUM)
	_credit.text = CREDIT_LINE
	_credit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intro.add_child(_credit)


## Rebuilds the controls card for the current input method and scale.
func _fill_card() -> void:
	for c in _card.get_children():
		_card.remove_child(c)  # now, so the old content doesn't count towards the new size
		c.queue_free()
	_styled = _styled.filter(func(s: Array) -> bool: return is_instance_valid(s[0]) and (s[0] as Node).is_inside_tree())
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", roundi(14.0 * _u))
	_card.add_child(column)
	if _touch.active:
		var text_w := (minf(get_viewport().get_visible_rect().size.x, 520.0 * _u) - 2.0 * 22.0 * _u
			- 2.0 * 28.0 * _u - 40.0 * _u)
		for spec: Array in [["◎", "Drag on the left to steer and accelerate"],
				["⇧", "Boost and handbrake on the right"], ["⟲", "A second finger looks around"]]:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", roundi(12.0 * _u))
			var glyph := _label(13, 11, HudStyle.BOLD)
			glyph.text = spec[0]
			var t := _label(13.5, 12, HudStyle.MEDIUM)
			t.text = spec[1]
			t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			t.custom_minimum_size.x = text_w
			row.add_child(glyph)
			row.add_child(t)
			column.add_child(row)
	else:
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", roundi(34.0 * _u))
		grid.add_theme_constant_override("v_separation", roundi(14.0 * _u))
		column.add_child(grid)
		for spec: Array in [[["W", "A", "S", "D"], "Drive"], [["Space"], "Handbrake"], [["Shift"], "Boost"],
				[["R"], "Back on the road"], [["M"], "Map"], [["Right drag"], "Look around"]]:
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", roundi(10.0 * _u))
			var keys := HBoxContainer.new()
			keys.add_theme_constant_override("separation", roundi(4.0 * _u))
			for k: String in spec[0]:
				keys.add_child(_keycap(k))
			row.add_child(keys)
			var t := _label(14, 12, HudStyle.MEDIUM)
			t.text = spec[1]
			row.add_child(t)
			grid.add_child(row)
	var hint := _label(12.5, 11, HudStyle.MEDIUM)
	hint.text = "Start driving to hide" if _touch.active else "Start driving to hide · H shows this again"
	hint.modulate = Color(1, 1, 1, 0.8)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(hint)
	_restyle()


func _keycap(text: String) -> PanelContainer:
	var cap := PanelContainer.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(1, 1, 1, 0.08)
	box.border_color = Color(1, 1, 1, 0.42)
	box.set_border_width_all(1)
	box.set_corner_radius_all(roundi(6.0 * _u))
	box.content_margin_left = 7.0 * _u
	box.content_margin_right = 7.0 * _u
	box.content_margin_top = 3.0 * _u
	box.content_margin_bottom = 3.0 * _u
	box.anti_aliasing = true
	cap.add_theme_stylebox_override("panel", box)
	cap.custom_minimum_size = Vector2(26, 26) * _u
	var l := _label(12, 10.5, HudStyle.BOLD)
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.add_child(l)
	return cap


# --- Layout --------------------------------------------------------------------------

## Places everything for the current screen shape. Portrait screens get a larger UI
## scale so the short side spans the same canvas units as in landscape.
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
	var dpr := maxf(DisplayServer.screen_get_scale(), 1.0)
	_px = clampf(view.x / (win.x / dpr), 0.5, 4.0)  # (headless test windows are tiny)
	_narrow = view.y > view.x
	_u = minf(view.x, view.y) / (412.0 if _narrow else 720.0)
	var top_stack := _narrow or _touch.active  # thumbs own the bottom of the screen
	var m := (22.0 if _narrow else 28.0) * _u
	var top := (54.0 if _narrow else 28.0) * _u
	if OS.has_feature("mobile"):
		top = maxf(top, DisplayServer.get_display_safe_area().position.y * view.y / win.y + 8.0 * _u)
	_fill_card()
	# Minimap, top right.
	var map_size := (104.0 if _narrow else 176.0) * _u
	_map.position = Vector2(view.x - m - map_size, top)
	_map.size = Vector2.ONE * map_size
	# Icon buttons: top left on desktop; under the map on phones.
	var b := (44.0 if _narrow else 40.0) * _u
	for btn: HudIconButton in [_search_btn, _menu_btn]:
		btn.custom_minimum_size = Vector2.ONE * b
		btn.size = Vector2.ONE * b
	if _narrow:
		_search_btn.position = Vector2(view.x - m - b, top + map_size + 10.0 * _u)
		_menu_btn.position = _search_btn.position - Vector2(b + 10.0 * _u, 0)
	else:
		_search_btn.position = Vector2(m, top)
		_menu_btn.position = Vector2(m + b + 10.0 * _u, top)
	_debug_label.position = Vector2(m, top + b + 10.0 * _u) if not _narrow else Vector2(m, view.y * 0.5)
	# Speed, road and area: bottom left, or top left on phones and with touch controls.
	_speed_box.add_theme_constant_override("separation", roundi(2.0 * _u))
	var name_width := (240.0 if _narrow else 460.0) * _u
	for l: Label in [_road_label, _area_label]:
		l.custom_minimum_size.x = name_width
	if top_stack:
		# On phones the icon buttons sit under the map; with touch on a wide screen
		# the cluster goes under them.
		_speed_box.position = Vector2(m, top + (0.0 if _narrow else b + 14.0 * _u))
		name_width = minf(name_width, _map.position.x - m - 12.0 * _u)
		for l: Label in [_road_label, _area_label]:
			l.custom_minimum_size.x = name_width
	# Panels.
	var panel := HudStyle.glass(16.0 * _u)
	_search_panel.add_theme_stylebox_override("panel", panel)
	_menu_panel.add_theme_stylebox_override("panel", panel)
	var field := StyleBoxEmpty.new()
	field.content_margin_left = 14.0 * _u
	field.content_margin_top = 10.0 * _u
	field.content_margin_bottom = 10.0 * _u
	_search.add_theme_stylebox_override("normal", field)
	_search.add_theme_stylebox_override("focus", field)
	_search.add_theme_font_override("font", HudStyle.font(HudStyle.MEDIUM))
	_search.add_theme_font_size_override("font_size", _size(15, 13))
	_search_close.custom_minimum_size = Vector2.ONE * 40.0 * _u
	var panel_w := minf(380.0 * _u, view.x - 2.0 * m)
	_search_panel.position = Vector2(m, top)
	_search_panel.size = Vector2(panel_w, 0)
	_search_panel.custom_minimum_size.x = panel_w
	_search_msg.add_theme_constant_override("line_spacing", 0)
	var menu_w := minf(280.0 * _u, view.x - 2.0 * m)
	_menu_panel.custom_minimum_size.x = menu_w
	_menu_panel.size = Vector2(menu_w, 0)
	_menu_panel.position = Vector2(_menu_btn.position.x if not _narrow else view.x - m - menu_w,
		_menu_btn.position.y + b + 10.0 * _u)
	for row in _menu_rows.get_children():
		(row as PanelContainer).add_theme_stylebox_override("panel", _row_style(false))
	_credits_box.add_theme_constant_override("separation", roundi(6.0 * _u))
	var inset := StyleBoxEmpty.new()
	inset.content_margin_left = 16.0 * _u
	inset.content_margin_right = 16.0 * _u
	inset.content_margin_bottom = 6.0 * _u
	for l in _credits_box.get_children():
		(l as Label).custom_minimum_size.x = menu_w - 32.0 * _u
		(l as Label).add_theme_stylebox_override("normal", inset)
	# Status toast, top centre.
	var toast := HudStyle.glass(999.0)
	toast.content_margin_left = 16.0 * _u
	toast.content_margin_right = 16.0 * _u
	toast.content_margin_top = 7.0 * _u
	toast.content_margin_bottom = 7.0 * _u
	_toast.add_theme_stylebox_override("panel", toast)
	# Launch screen.
	var card := HudStyle.glass(18.0 * _u)
	card.content_margin_left = 28.0 * _u
	card.content_margin_right = 28.0 * _u
	card.content_margin_top = 22.0 * _u
	card.content_margin_bottom = 18.0 * _u
	_card.add_theme_stylebox_override("panel", card)
	_restyle()
	# Sit the unit on the number's baseline rather than the bottom of its line box.
	var unit_drop := StyleBoxEmpty.new()
	unit_drop.content_margin_bottom = HudStyle.font(HudStyle.LIGHT).get_descent(_size(64, 30)) \
		- HudStyle.font(HudStyle.SEMIBOLD, roundi(2.0 * _u)).get_descent(_size(15, 10.5))
	_unit_label.add_theme_stylebox_override("normal", unit_drop)
	var card_size := _card.get_combined_minimum_size()
	if _narrow:
		_card.custom_minimum_size.x = view.x - 2.0 * m
		card_size = _card.get_combined_minimum_size()
		_card.position = Vector2(m, view.y * 0.34)
	else:
		_card.custom_minimum_size.x = 0
		_card.position = Vector2((view.x - card_size.x) * 0.5, view.y - 92.0 * _u - card_size.y)
	_card.size = card_size
	_place_box.custom_minimum_size.x = view.x - 2.0 * m
	_place_box.reset_size()
	if _narrow:
		# Stacked over the card: place name, then the wordmark.
		var mark_y := _card.position.y - 30.0 * _u
		_wordmark.position = Vector2((view.x - _wordmark.get_combined_minimum_size().x) * 0.5, mark_y)
		_place_box.position = Vector2(m, mark_y - 10.0 * _u - _place_box.get_combined_minimum_size().y)
	else:
		_wordmark.position = Vector2((view.x - _wordmark.get_combined_minimum_size().x) * 0.5, top + 2.0 * _u)
		_place_box.position = Vector2(m, view.y * 0.34)
	# Credit line: bottom right, or bottom left clear of the touch pads.
	var pads := (2.0 * TouchControls.PAD_RADIUS + 24.0) * _px if _touch.active else 0.0
	var credit_w := minf(view.x - 2.0 * m - pads, 620.0 * _u)
	_credit.custom_minimum_size.x = credit_w
	_credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if _touch.active else HORIZONTAL_ALIGNMENT_RIGHT
	# A wrapping label measures its height at its current width, so set that first.
	_credit.size = Vector2(credit_w, 0)
	var credit_h := _credit.get_minimum_size().y
	_credit.size = Vector2(credit_w, credit_h)
	var credit_x := m if _touch.active else view.x - m - credit_w
	_credit.position = Vector2(credit_x, view.y - 20.0 * _u - credit_h)
	_place_toast()
	_place_speed_box()


## Bottom-left speed cluster; re-anchored as its height changes.
func _place_speed_box() -> void:
	if _narrow or _touch.active:
		return
	var view := get_viewport().get_visible_rect().size
	var h := _speed_box.get_combined_minimum_size().y
	_speed_box.position = Vector2(36.0 * _u, view.y - 34.0 * _u - h)


func _place_toast() -> void:
	var view := get_viewport().get_visible_rect().size
	var sz := _toast.get_combined_minimum_size()
	var y := (54.0 if _narrow else 28.0) * _u
	if _narrow:
		y = _search_btn.position.y + _search_btn.size.y + 12.0 * _u
	_toast.position = Vector2((view.x - sz.x) * 0.5, y)
	_toast.size = sz


func _size(mock: float, min_css: float) -> int:
	return maxi(roundi(mock * _u), roundi(min_css * _px))


func _restyle() -> void:
	for s in _styled:
		var l: Label = s[0]
		if is_instance_valid(l):
			HudStyle.style_label(l, _size(s[1], s[2]), s[3], maxf(_u, 1.0), roundi(s[4] * _u))


# --- Launch screen and credits ------------------------------------------------------

## Called on every teleport (and the first spawn): shows the place name and data
## credits, which fade once the world has loaded and the car is moving.
func arrive(label: String) -> void:
	var parts := label.split(",", false, 1)
	var numeric := parts.size() == 2 and parts[0].strip_edges().is_valid_float()
	_place_from_world = numeric
	_place_title.text = "" if numeric else parts[0].strip_edges()
	_place_sub.text = label.strip_edges() if numeric else (parts[1].strip_edges() if parts.size() > 1 else "")
	_place_timer = ARRIVAL_TIME
	_credit_timer = maxf(_credit_timer, ARRIVAL_TIME)
	_settlement = ""


func _show_controls(on: bool) -> void:
	_showing_controls = on
	if on:
		_credit_timer = maxf(_credit_timer, ARRIVAL_TIME)
	_touch.hint = on and _touch.active


func _driving_input() -> bool:
	for a: String in ["accelerate", "brake", "steer_left", "steer_right"]:
		if Input.get_action_strength(a) > 0.05:
			return true
	return false


func _update_intro(delta: float) -> void:
	var loaded := car != null and not car.freeze
	if loaded:
		_place_timer -= delta
		_credit_timer -= delta
		if _driving_input() and _showing_controls:
			# The first throttle or steer: the launch screen has done its job.
			_show_controls(false)
			_place_timer = minf(_place_timer, 0.0)
			_credit_timer = minf(_credit_timer, 0.0)
	_fade(_card, _showing_controls, delta)
	_fade(_wordmark, _showing_controls, delta)
	_fade(_place_box, _place_timer > 0.0 or not loaded, delta)
	_fade(_credit, _credit_timer > 0.0 or not loaded, delta)
	_touch.hint = _showing_controls and _touch.active


func _fade(c: CanvasItem, show: bool, delta: float) -> void:
	c.modulate.a = move_toward(c.modulate.a, 1.0 if show else 0.0, FADE_SPEED * delta)
	c.visible = c.modulate.a > 0.0


# --- Status, settings ---------------------------------------------------------------

func set_status(text: String) -> void:
	_status_label.text = text
	_toast.visible = not text.is_empty()
	_place_toast()


func _set_debug(on: bool) -> void:
	_debug = on
	_debug_label.visible = on
	_save_settings()
	_update_menu_hints()


func _update_menu_hints() -> void:
	if _units_hint:
		_units_hint.text = "mph" if _mph else "km/h"
	if _debug_hint:
		_debug_hint.text = ("On · F3" if _debug else "Off · F3")
	if _roads_hint:
		_roads_hint.text = "Mask (beta)" if RoadNetwork.use_mask else "Meshes"


## Re-reads settings set from outside the menu (a URL parameter) into its hints.
func refresh_settings() -> void:
	_update_menu_hints()


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		_mph = cfg.get_value("hud", "mph", false)
		_debug = cfg.get_value("hud", "debug", false)
		RoadNetwork.use_mask = RoadNetwork.use_mask or cfg.get_value("world", "road_mask", false)


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("hud", "mph", _mph)
	cfg.set_value("hud", "debug", _debug)
	cfg.set_value("world", "road_mask", RoadNetwork.use_mask)
	cfg.save(SETTINGS_PATH)


func _set_menu_open(on: bool) -> void:
	_menu_panel.visible = on
	if on:
		_close_search()
		_credits_box.visible = false
	_menu_panel.reset_size()


# --- Input ---------------------------------------------------------------------------

## Clicks or taps outside an open panel close it (without swallowing the event).
func _input(event: InputEvent) -> void:
	var pos := Vector2.INF
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
	elif event is InputEventScreenTouch and event.pressed:
		pos = event.position
	if pos == Vector2.INF:
		return
	if _search_panel.visible and not _search_panel.get_global_rect().has_point(pos):
		_close_search()
	if _menu_panel.visible and not _menu_panel.get_global_rect().has_point(pos) \
			and not _menu_btn.get_global_rect().has_point(pos):
		_set_menu_open(false)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_map"):
		_map.visible = not _map.visible
	elif event.is_action_pressed("toggle_help"):
		_show_controls(not _showing_controls)
	elif event.is_action_pressed("toggle_debug"):
		_set_debug(not _debug)
	elif event.is_action_pressed("open_search"):
		_open_search()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_close_search()
		_set_menu_open(false)


# --- Per frame -----------------------------------------------------------------------

func _process(delta: float) -> void:
	_update_intro(delta)
	if not _pending_query.is_empty() and Time.get_ticks_msec() - _last_search_msec >= 1000:
		var q := _pending_query
		_pending_query = ""
		_search_now(q)
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
		parts.append(MinimapOverlay.heading_text(_heading()))
		_area_label.text = "  ·  ".join(parts)
		if _place_from_world and not car.freeze:
			var title: String = where.road if not where.road.is_empty() else where.area
			if not title.is_empty():
				_place_title.text = title
				_place_sub.text = _settlement
				_place_from_world = false
	var heading := _heading()
	_minimap_overlay.heading = heading
	var kmh := absf(car.speed_kmh())
	_speed_label.text = str(roundi(kmh * 0.621371 if _mph else kmh))
	_unit_label.text = " MPH" if _mph else " KM/H"
	_place_speed_box()
	if _debug:
		var ll := Geo.local_to_latlon(car.global_position)
		_debug_label.text = "%.5f, %.5f  ·  alt %d m  ·  %d fps" % [ll.x, ll.y, roundi(car.global_position.y),
			Engine.get_frames_per_second()]
	if _minimap_cam.is_inside_tree():
		var xf := car.get_global_transform_interpolated()
		var fwd := Vector3(xf.basis.z.x, 0.0, xf.basis.z.z)
		if fwd.length_squared() > 1e-4:
			# Looking straight down with the car's heading pointing up the screen.
			fwd = fwd.normalized()
			var basis := Basis(fwd.cross(Vector3.UP), fwd, Vector3.UP)
			_minimap_cam.global_transform = Transform3D(basis, xf.origin + Vector3.UP * 1500.0)


## Car heading in radians, clockwise from north (local -z is north, +x east).
func _heading() -> float:
	var f := car.get_global_transform_interpolated().basis.z
	return atan2(f.x, -f.z)


## Minimap pixel offset (screen axes, from centre) -> world position. The map is
## drawn with the car's heading up and `_minimap_span` metres across.
func _on_map_clicked(offset: Vector2) -> void:
	var xf := car.get_global_transform_interpolated()
	var fwd := Vector3(xf.basis.z.x, 0.0, xf.basis.z.z).normalized()
	var right := fwd.cross(Vector3.UP)
	var metres_per_px := _minimap_span / _minimap_view.size.y
	var target := xf.origin + (right * offset.x - fwd * offset.y) * metres_per_px
	road_teleport_requested.emit(target)


# --- Search --------------------------------------------------------------------------

func _open_search() -> void:
	_set_menu_open(false)
	_search_panel.visible = true
	_search_btn.visible = false
	_menu_btn.visible = false
	if _results_query != _search.text.strip_edges():
		_clear_results()
		_show_message("")
	_search_panel.reset_size()
	_search.grab_focus()
	_search.select_all()


func _close_search() -> void:
	if not _search_panel.visible:
		return
	_search_panel.visible = false
	_search_btn.visible = true
	_menu_btn.visible = true
	_search.release_focus()


func _on_search_key(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	match event.keycode:
		KEY_DOWN, KEY_UP:
			if not _result_coords.is_empty():
				var step := 1 if event.keycode == KEY_DOWN else -1
				_select(wrapi(_selected + step, 0, _result_coords.size()))
			_search.accept_event()
		KEY_ESCAPE:
			_close_search()
			_search.accept_event()


## Editing the query drops the old results, the selection and any pending search.
func _on_search_edited(_text: String) -> void:
	_pending_query = ""
	_clear_results()
	_show_message("")


func _on_submit(text: String) -> void:
	# Enter picks the highlighted result only if the results belong to the text in the field.
	if _selected >= 0 and _selected < _result_coords.size() and _results_query == text.strip_edges() \
			and _result_names.size() > _selected and not _results.get_children().is_empty():
		_pick(_selected)
		return
	text = text.strip_edges()
	if text.is_empty():
		return
	# Direct "lat, lon" input.
	var parts := text.replace(" ", "").split(",")
	if parts.size() == 2 and parts[0].is_valid_float() and parts[1].is_valid_float():
		_go(parts[0].to_float(), parts[1].to_float(), text)
		return
	_show_message("Searching…")
	# Nominatim usage policy: at most one request per second, so queue a quick repeat.
	if Time.get_ticks_msec() - _last_search_msec < 1000:
		_pending_query = text
	else:
		_search_now(text)


func _search_now(text: String) -> void:
	_last_search_msec = Time.get_ticks_msec()
	var headers := PackedStringArray()
	if not OS.has_feature("web"):
		headers.append("User-Agent: Roam/0.1 (Godot driving game)")
	var query := text
	Fetch.request(NOMINATIM % text.uri_encode(), func(ok: bool, body: PackedByteArray) -> void:
		_on_search_result(ok, body, query), -10.0, false, headers)


func _on_search_result(ok: bool, body: PackedByteArray, query: String) -> void:
	if query != _search.text.strip_edges():
		return  # the query was edited while this request was in flight
	_clear_results()
	_results_query = query
	var data: Variant = JSON.parse_string(body.get_string_from_utf8()) if ok else null
	if not ok or not data is Array:
		_show_message("Can't reach search right now. Check your connection and try again.")
		return
	if data.is_empty():
		_show_message("No places found for “%s”." % query)
		return
	_show_message("")
	for r: Dictionary in data:
		var full := str(r.get("display_name", ""))
		var bits := full.split(", ")
		var title := str(r.get("name", ""))
		if title.is_empty():
			title = bits[0]
		var kind := str(r.get("addresstype", r.get("type", ""))).replace("_", " ").capitalize()
		var rest := ", ".join(bits.slice(1, 4))
		_add_result(title, (kind + " · " + rest) if not kind.is_empty() else rest,
			Vector2(float(r.lat), float(r.lon)))
	_select(0)
	_search_panel.reset_size()


func _add_result(title: String, detail: String, coords: Vector2) -> void:
	var index := _result_coords.size()
	_result_coords.append(coords)
	_result_names.append(title)
	var row := PanelContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.mouse_entered.connect(func() -> void: _select(index))
	row.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
			_pick(index))
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", roundi(1.0 * _u))
	row.add_child(box)
	var t := _label(14.5, 12.5, HudStyle.SEMIBOLD)
	t.text = title
	var d := _label(12.5, 11, HudStyle.MEDIUM)
	d.text = detail
	d.modulate = Color(1, 1, 1, 0.78)
	for l in [t, d]:
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.clip_text = true
		box.add_child(l)
	_results.add_child(row)
	_restyle()


func _select(index: int) -> void:
	_selected = index
	var rows := _results.get_children()
	for i in rows.size():
		(rows[i] as PanelContainer).add_theme_stylebox_override("panel", _row_style(i == index, i == index))


func _clear_results() -> void:
	for c in _results.get_children():
		_results.remove_child(c)
		c.queue_free()
	_styled = _styled.filter(func(s: Array) -> bool: return is_instance_valid(s[0]) and s[0].is_inside_tree())
	_result_coords.clear()
	_result_names.clear()
	_results_query = ""
	_selected = -1


func _show_message(text: String) -> void:
	_search_msg.text = text
	_search_msg.visible = not text.is_empty()
	var box := StyleBoxEmpty.new()
	box.content_margin_left = 16.0 * _u
	box.content_margin_right = 16.0 * _u
	box.content_margin_top = 8.0 * _u
	box.content_margin_bottom = 10.0 * _u
	_search_msg.add_theme_stylebox_override("normal", box)
	_search_panel.reset_size()


func _pick(index: int) -> void:
	if index < 0 or index >= _result_coords.size():
		return
	_go(_result_coords[index].x, _result_coords[index].y, _result_names[index])


func _go(lat: float, lon: float, label: String) -> void:
	_settlement = ""
	_close_search()
	teleport_requested.emit(lat, lon, label)
