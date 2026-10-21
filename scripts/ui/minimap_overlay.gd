class_name MinimapOverlay
extends Control
## Drawn over the minimap: a compass ring with a north marker (the map rotates with the
## car, so north moves round the edge), zoom buttons, and click/tap-to-teleport.

signal zoom_requested(factor: float)  ## <1 zooms in, >1 zooms out
signal map_clicked(offset: Vector2)  ## pixels from the map centre, screen axes

## Car heading in radians, clockwise from north.
var heading := 0.0:
	set(value):
		heading = value
		queue_redraw()

var _press_pos := Vector2.INF


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var buttons := VBoxContainer.new()
	buttons.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	buttons.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	buttons.grow_vertical = Control.GROW_DIRECTION_BEGIN
	buttons.offset_right = -4
	buttons.offset_bottom = -4
	buttons.add_theme_constant_override("separation", 4)
	add_child(buttons)
	for spec: Array in [["+", 0.6], ["−", 1.0 / 0.6]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(28, 28)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 18)
		var factor: float = spec[1]
		b.pressed.connect(func() -> void: zoom_requested.emit(factor))
		buttons.add_child(b)
	tooltip_text = "Click the map to teleport to the nearest road"


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
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
				# A click is a press and release in (nearly) the same place.
				if event.pressed:
					_press_pos = event.position
				elif _press_pos != Vector2.INF and event.position.distance_to(_press_pos) < 12.0:
					map_clicked.emit(event.position - size * 0.5)
					_press_pos = Vector2.INF
				accept_event()


func _draw() -> void:
	var centre := size * 0.5
	var r := minf(size.x, size.y) * 0.5 - 12.0
	draw_arc(centre, r, 0.0, TAU, 64, Color(1, 1, 1, 0.25), 1.5, true)
	# Screen "up" is the car's heading, so north sits at -heading round the ring.
	var font := get_theme_default_font()
	for i in 4:
		var a := -heading + i * PI / 2.0
		var dir := Vector2(sin(a), -cos(a))
		var p := centre + dir * r
		var label: String = ["N", "E", "S", "W"][i]
		var colour := Color(1, 0.35, 0.25) if i == 0 else Color(1, 1, 1, 0.8)
		var fs := 15 if i == 0 else 11
		if i == 0:
			draw_circle(p, 10.0, Color(0, 0, 0, 0.55))
		var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string_outline(font, p + Vector2(-text_size.x * 0.5, text_size.y * 0.35), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color(0, 0, 0, 0.8))
		draw_string(font, p + Vector2(-text_size.x * 0.5, text_size.y * 0.35), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colour)


## "NE 47°" for a heading in radians clockwise from north.
static func heading_text(h: float) -> String:
	var deg := fposmod(rad_to_deg(h), 360.0)
	var names := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	return "%s %d°" % [names[roundi(deg / 45.0) % 8], roundi(deg) % 360]
