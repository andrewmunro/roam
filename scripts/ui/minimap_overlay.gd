class_name MinimapOverlay
extends Control
## Drawn over the round minimap: its rim, a north tick that moves round the edge (the
## map turns with the car), the car arrow, and input: wheel, trackpad or two-finger
## pinch zooms, a click or tap teleports.

signal zoom_requested(factor: float)  ## <1 zooms in, >1 zooms out
signal map_clicked(offset: Vector2)  ## pixels from the map centre, screen axes

## Car heading in radians, clockwise from north.
var heading := 0.0:
	set(value):
		heading = value
		queue_redraw()

var _press_pos := Vector2.INF
var _pinch := {}  # touch index -> position, for touches that started on the map
var _pinch_dist := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	tooltip_text = "Click the map to jump to the nearest road"


func _has_point(point: Vector2) -> bool:
	return point.distance_to(size * 0.5) <= minf(size.x, size.y) * 0.5


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMagnifyGesture:
		zoom_requested.emit(1.0 / event.factor)
		accept_event()
	elif event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					zoom_requested.emit(0.85)
				accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					zoom_requested.emit(1.0 / 0.85)
				accept_event()
			MOUSE_BUTTON_LEFT:
				# A click is a press and release in (nearly) the same place, not a pinch.
				if event.pressed:
					_press_pos = event.position
				elif _press_pos != Vector2.INF and event.position.distance_to(_press_pos) < 12.0 and _pinch.size() < 2:
					map_clicked.emit(event.position - size * 0.5)
					_press_pos = Vector2.INF
				accept_event()


## Two-finger pinch on the map (touches arrive here before the touch controls see them).
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	if event is InputEventScreenTouch:
		if event.pressed and get_global_rect().has_point(event.position) and _has_point(event.position - global_position):
			_pinch[event.index] = event.position
			_pinch_dist = _pinch_span()
			if _pinch.size() >= 2:
				_press_pos = Vector2.INF
		elif not event.pressed and _pinch.has(event.index):
			_pinch.erase(event.index)
			_pinch_dist = _pinch_span()
	elif event is InputEventScreenDrag and _pinch.has(event.index):
		_pinch[event.index] = event.position
		var d := _pinch_span()
		if _pinch.size() >= 2 and _pinch_dist > 1.0 and d > 1.0:
			zoom_requested.emit(_pinch_dist / d)
			get_viewport().set_input_as_handled()
		_pinch_dist = d


func _pinch_span() -> float:
	if _pinch.size() < 2:
		return 0.0
	var pts: Array = _pinch.values()
	return (pts[0] as Vector2).distance_to(pts[1])


func _draw() -> void:
	var centre := size * 0.5
	var r := minf(size.x, size.y) * 0.5
	var u := r / 88.0  # 1 at the desktop map size
	draw_arc(centre, r - 0.5, 0.0, TAU, 96, HudStyle.EDGE, maxf(1.0, u), true)
	# Screen "up" is the car's heading, so north sits at -heading round the rim.
	var dir := Vector2(sin(-heading), -cos(-heading))
	var tick := centre + dir * (r - 12.0 * u)
	HudStyle.draw_text_centred(self, tick, "N", maxi(9, roundi(12.0 * u)), HudStyle.BOLD, HudStyle.INK, u)
	# The car: an amber arrow pointing up the screen.
	var s := 8.0 * u
	var arrow := PackedVector2Array([centre + Vector2(0, -1.15) * s, centre + Vector2(0.8, 0.9) * s,
		centre + Vector2(0, 0.5) * s, centre + Vector2(-0.8, 0.9) * s])
	var outline := arrow.duplicate()
	outline.append(arrow[0])
	draw_polyline(outline, Color(0, 0, 0, 0.45), 2.5 * u, true)
	draw_colored_polygon(arrow, HudStyle.AMBER)


## "NE 47°" for a heading in radians clockwise from north.
static func heading_text(h: float) -> String:
	var deg := fposmod(rad_to_deg(h), 360.0)
	var names := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	return "%s %d°" % [names[roundi(deg / 45.0) % 8], roundi(deg) % 360]
