class_name HudStyle
extends RefCounted
## Shared look for the HUD: one typeface (Manrope) at a few weights, white type on a
## soft shadow, and translucent dark "glass" only behind things you can press.

const FONT_PATH := "res://assets/fonts/Manrope.ttf"
const INK := Color(1, 1, 1)
const GLASS := Color(0.055, 0.07, 0.08, 0.52)
const GLASS_HOVER := Color(0.1, 0.12, 0.13, 0.62)
const GLASS_PRESSED := Color(1, 1, 1, 0.24)
const EDGE := Color(1, 1, 1, 0.16)
const AMBER := Color(0.953, 0.714, 0.29)  ## the one accent: your car on the map, selections
const SHADOW := Color(0, 0, 0, 0.42)

const LIGHT := 300
const MEDIUM := 500
const SEMIBOLD := 600
const BOLD := 700

static var _fonts := {}


## The HUD typeface at a weight, with optional extra space between letters.
static func font(weight: int, spacing := 0) -> FontVariation:
	var key := weight * 100 + spacing
	if not _fonts.has(key):
		var f := FontVariation.new()
		f.base_font = load(FONT_PATH)
		f.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
		f.spacing_glyph = spacing
		_fonts[key] = f
	return _fonts[key]


## Rounded glass panel; `radius` and `edge` in canvas units.
static func glass(radius: float, edge := 1.0, fill := GLASS) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = EDGE
	box.set_border_width_all(maxi(1, roundi(edge)))
	box.set_corner_radius_all(roundi(radius))
	box.anti_aliasing = true
	box.corner_detail = 12
	return box


## Sets a label's typeface, size (canvas units) and soft drop shadow.
static func style_label(l: Label, size: float, weight: int, shadow := 1.0, spacing := 0) -> void:
	l.add_theme_font_override("font", font(weight, spacing))
	l.add_theme_font_size_override("font_size", maxi(1, roundi(size)))
	l.add_theme_color_override("font_color", INK)
	l.add_theme_color_override("font_shadow_color", SHADOW)
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", maxi(1, roundi(shadow)))
	l.add_theme_constant_override("shadow_outline_size", maxi(2, roundi(shadow * 3.0)))


## Text drawn in _draw with the same shadow as the labels; `pos` is the baseline start.
static func draw_text(ci: CanvasItem, pos: Vector2, text: String, size: int, weight: int,
		colour := INK, shadow := 1.0) -> void:
	var f := font(weight)
	ci.draw_string_outline(f, pos + Vector2(0, shadow), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
		maxi(2, roundi(shadow * 3.0)), SHADOW)
	ci.draw_string(f, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, colour)


## Text centred on `centre` (both axes).
static func draw_text_centred(ci: CanvasItem, centre: Vector2, text: String, size: int, weight: int,
		colour := INK, shadow := 1.0) -> void:
	var f := font(weight)
	var sz := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	draw_text(ci, Vector2(centre.x - sz.x * 0.5, centre.y - sz.y * 0.5 + f.get_ascent(size)), text, size,
		weight, colour, shadow)
