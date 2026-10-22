shader_type canvas_item;
// Clips a canvas item (the minimap) to an antialiased circle filling its rect.

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float r = length(UV - 0.5) * 2.0;
	float edge = fwidth(r) * 1.5;
	c.a *= 1.0 - smoothstep(1.0 - edge, 1.0, r);
	COLOR = c;
}
