class_name TouchControls
extends Control
## On-screen driving controls for touch screens. The first finger that lands anywhere
## (except on HUD widgets or the small buttons) becomes a floating joystick centred
## under it, drawn only while held: X steers, up accelerates, down brakes and then
## reverses. Small handbrake/boost/reset buttons sit in the corners. They press the
## regular input actions, so the car can't tell them from a keyboard or gamepad.
## Shown on touch devices (or on the first touch); hidden again by keyboard/gamepad use.

signal active_changed(active: bool)

## Sizes are in CSS pixels (points) and converted to canvas units, so the controls are
## the same physical size on any screen density or stretch factor.
const STICK_RADIUS := 62.0
const KNOB_RADIUS := 27.0
const SMALL_SIZE := Vector2(86, 40)
const RESET_SIZE := Vector2(70, 36)
const MARGIN := 16.0
const GAP := 14.0
const FONT_SIZE := 12.0
const STICK_DEADZONE := 0.12

const FILL := Color(0, 0, 0, 0.3)
const FILL_PRESSED := Color(1, 1, 1, 0.32)
const EDGE := Color(1, 1, 1, 0.55)
const TEXT_OUTLINE := Color(0, 0, 0, 0.8)

## Canvas units kept free along the bottom edge (for the map credit line).
@export var bottom_reserve := 22.0
## HUD widgets (search, minimap…) that keep their touches instead of starting the stick.
var exclude: Array[Control] = []

var active := false
var _px := 1.0  # canvas units per CSS pixel
var _margin := Vector4.ZERO  # safe-area margins: left, top, right, bottom
var _stick_centre := Vector2.ZERO
var _stick_touch := -1
var _stick := Vector2.ZERO  # -1..1 on both axes, screen orientation (y down)
## id -> {rect, label, action, touches: Array[int]}
var _buttons := {}
var _touches := {}  # touch index -> button id, or "stick"
var _strength := {}  # action -> strength last sent


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for id: String in ["handbrake", "boost", "reset_car"]:
		_buttons[id] = {rect = Rect2(), touches = [] as Array[int], action = id}
	_buttons.handbrake.label = "HANDBRAKE"
	_buttons.boost.label = "BOOST"
	_buttons.reset_car.label = "RESET"
	get_viewport().size_changed.connect(_layout)
	_layout()
	set_active(DisplayServer.is_touchscreen_available())


func set_active(on: bool) -> void:
	if on == active and visible == on:
		return
	active = on
	visible = on
	if not on:
		_release_all()
	active_changed.emit(on)
	queue_redraw()


## Canvas-space rect of a button, by action name (used by tests).
func button_rect(id: String) -> Rect2:
	return _buttons[id].rect


func stick_radius() -> float:
	return STICK_RADIUS * _px


func _layout() -> void:
	var vp := get_viewport_rect().size
	var win := Vector2(get_window().size)
	if vp.x <= 0.0 or win.x <= 0.0:
		return
	var dpr := maxf(DisplayServer.screen_get_scale(), 1.0)
	_px = vp.x / (win.x / dpr)
	# Shrink a little on very small screens so everything still fits.
	var css := vp / _px
	_px *= clampf(minf(css.x / 400.0, css.y / 340.0), 0.7, 1.0)
	_margin = Vector4.ONE * MARGIN * _px
	if OS.has_feature("mobile"):
		var safe := DisplayServer.get_display_safe_area()
		var screen := Vector2(DisplayServer.screen_get_size())
		var k := vp.x / win.x
		_margin.x = maxf(_margin.x, safe.position.x * k)
		_margin.y = maxf(_margin.y, safe.position.y * k)
		_margin.z = maxf(_margin.z, (screen.x - safe.end.x) * k)
		_margin.w = maxf(_margin.w, (screen.y - safe.end.y) * k)
	var bottom := vp.y - _margin.w - bottom_reserve
	var small := SMALL_SIZE * _px
	var gap := GAP * _px
	var boost_pos := Vector2(vp.x - _margin.z - small.x, bottom - small.y)
	_buttons.boost.rect = Rect2(boost_pos, small)
	_buttons.handbrake.rect = Rect2(Vector2(boost_pos.x, boost_pos.y - gap - small.y), small)
	var reset := RESET_SIZE * _px
	_buttons.reset_car.rect = Rect2(Vector2(_margin.x, bottom - reset.y), reset)
	queue_redraw()


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		if not active and event is InputEventScreenTouch and event.pressed:
			set_active(true)
		if active:
			_touch(event)
	elif active and _from_other_device(event):
		set_active(false)


## True for keyboard/gamepad input that means the player isn't using the touch UI.
func _from_other_device(event: InputEvent) -> bool:
	if event is InputEventKey:
		# The on-screen keyboard sends keys while typing in the search box.
		return event.pressed and not event.echo and not get_viewport().gui_get_focus_owner() is LineEdit
	if event is InputEventJoypadButton:
		return event.pressed
	if event is InputEventJoypadMotion:
		return absf(event.axis_value) > 0.5
	return false


func _touch(event: InputEvent) -> void:
	var index: int = event.index
	var pos: Vector2 = event.position
	if event is InputEventScreenTouch and event.pressed:
		var id := _hit(pos)
		if id.is_empty():
			return  # not ours: the HUD or the camera orbit gets it
		get_viewport().gui_release_focus()  # leave the search box so driving works
		_touches[index] = id
		if id == "stick":
			_stick_touch = index
			_stick_centre = pos
			_stick = Vector2.ZERO
		else:
			_buttons[id].touches.append(index)
			if id == "reset_car":
				_send_action("reset_car", true)
	elif event is InputEventScreenTouch:
		if not _touches.has(index):
			return
		var id: String = _touches[index]
		_touches.erase(index)
		if id == "stick":
			_stick_touch = -1
			_stick = Vector2.ZERO
		else:
			_buttons[id].touches.erase(index)
			if id == "reset_car":
				_send_action("reset_car", false)
	else:
		if not _touches.has(index):
			return
		if _touches[index] == "stick":
			var r := STICK_RADIUS * _px
			var d := pos - _stick_centre
			# Dragging past the rim pulls the base along, so the stick never "runs out".
			if d.length() > r:
				_stick_centre = pos - d.normalized() * r
				d = pos - _stick_centre
			_stick = d / r
	get_viewport().set_input_as_handled()
	_apply()
	queue_redraw()


## Which control is under `pos`: a button id, "stick", or "" for HUD widgets and when
## the stick is already held (so a second finger can orbit the camera).
func _hit(pos: Vector2) -> String:
	for id: String in _buttons:
		if _buttons[id].rect.grow(8.0 * _px).has_point(pos):
			return id
	for c in exclude:
		if c.is_visible_in_tree() and c.get_global_rect().has_point(pos):
			return ""
	return "stick" if _stick_touch == -1 else ""


## Deadzone plus a gentle curve, per axis.
static func _shape(v: float) -> float:
	var mag := absf(v)
	if mag <= STICK_DEADZONE:
		return 0.0
	return signf(v) * pow((mag - STICK_DEADZONE) / (1.0 - STICK_DEADZONE), 1.3)


func _apply() -> void:
	var steer := _shape(clampf(_stick.x, -1.0, 1.0))
	var pedal := _shape(clampf(-_stick.y, -1.0, 1.0))  # up is positive
	_set_action("steer_left", maxf(-steer, 0.0))
	_set_action("steer_right", maxf(steer, 0.0))
	_set_action("accelerate", maxf(pedal, 0.0))
	_set_action("brake", maxf(-pedal, 0.0))
	for id: String in ["handbrake", "boost"]:
		_set_action(id, 1.0 if not _buttons[id].touches.is_empty() else 0.0)


func _set_action(action: String, strength: float) -> void:
	var old: float = _strength.get(action, 0.0)
	if is_equal_approx(old, strength):
		return
	_strength[action] = strength
	if strength > 0.0:
		Input.action_press(action, strength)
	else:
		Input.action_release(action)


## Sends an action as an event, for code that reacts in _unhandled_input (reset).
func _send_action(action: String, pressed: bool) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	Input.parse_input_event(ev)


func _release_all() -> void:
	_touches.clear()
	_stick_touch = -1
	_stick = Vector2.ZERO
	for id: String in _buttons:
		_buttons[id].touches.clear()
	_apply()


func _draw() -> void:
	var font := get_theme_default_font()
	var fs := int(FONT_SIZE * _px)
	var line := maxf(1.5 * _px, 1.0)
	if _stick_touch != -1:
		# Joystick: base ring with throttle/brake/steer chevrons and the knob under the finger.
		var r := STICK_RADIUS * _px
		draw_circle(_stick_centre, r, FILL)
		draw_arc(_stick_centre, r, 0.0, TAU, 48, EDGE, line, true)
		for dir: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			var tip := _stick_centre + dir * r * 0.82
			var back := tip - dir * r * 0.16
			var side := Vector2(-dir.y, dir.x) * r * 0.16
			draw_polyline(PackedVector2Array([back + side, tip, back - side]), EDGE, line * 1.4, true)
		var knob := _stick_centre + _stick.limit_length(1.0) * r
		draw_circle(knob, KNOB_RADIUS * _px, FILL_PRESSED)
		draw_arc(knob, KNOB_RADIUS * _px, 0.0, TAU, 32, Color(1, 1, 1, 0.75), line, true)
	var box := StyleBoxFlat.new()
	box.set_corner_radius_all(int(12 * _px))
	box.set_border_width_all(int(maxf(1.5 * _px, 1.0)))
	box.border_color = EDGE
	box.anti_aliasing = true
	for id: String in _buttons:
		var b: Dictionary = _buttons[id]
		box.bg_color = FILL_PRESSED if not b.touches.is_empty() else FILL
		draw_style_box(box, b.rect)
		_draw_text(font, fs, b.label, b.rect.get_center())


func _draw_text(font: Font, fs: int, text: String, centre: Vector2) -> void:
	var sz := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var pos := Vector2(centre.x - sz.x * 0.5, centre.y - sz.y * 0.5 + font.get_ascent(fs))
	draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, maxi(int(4 * _px), 2), TEXT_OUTLINE)
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
