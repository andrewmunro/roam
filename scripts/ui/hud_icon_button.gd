class_name HudIconButton
extends Button
## Round glass button with a line icon drawn in code ("search", "settings" or "close").

var icon_kind := "search"


func _init(kind := "search", tip := "") -> void:
	icon_kind = kind
	tooltip_text = tip
	focus_mode = Control.FOCUS_NONE
	flat = true


func _ready() -> void:
	for state: String in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


func _has_point(point: Vector2) -> bool:
	return point.distance_to(size * 0.5) <= minf(size.x, size.y) * 0.5


func _draw() -> void:
	var c := size * 0.5
	var r := minf(size.x, size.y) * 0.5
	var fill := HudStyle.GLASS_PRESSED if is_pressed() else (HudStyle.GLASS_HOVER if is_hovered() else HudStyle.GLASS)
	draw_circle(c, r, fill, true, -1.0, true)
	draw_arc(c, r - 0.5, 0.0, TAU, 48, HudStyle.EDGE, 1.0, true)
	var w := maxf(r * 0.1, 1.5)
	var ink := HudStyle.INK
	match icon_kind:
		"search":
			var lens := c + Vector2(-0.08, -0.08) * r
			draw_arc(lens, r * 0.3, 0.0, TAU, 32, ink, w, true)
			draw_line(lens + Vector2(0.21, 0.21) * r, c + Vector2(0.42, 0.42) * r, ink, w, true)
		"settings":
			draw_arc(c, r * 0.17, 0.0, TAU, 24, ink, w, true)
			draw_arc(c, r * 0.34, 0.0, TAU, 32, ink, w, true)
			for i in 8:
				var d := Vector2.from_angle(i * TAU / 8.0)
				draw_line(c + d * r * 0.34, c + d * r * 0.5, ink, w * 1.6, true)
		"close":
			var k := r * 0.3
			draw_line(c + Vector2(-k, -k), c + Vector2(k, k), ink, w, true)
			draw_line(c + Vector2(k, -k), c + Vector2(-k, k), ink, w, true)
