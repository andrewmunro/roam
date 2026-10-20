shader_type spatial;
// Roads: UV.x runs across the road (0..1), UV.y is distance along it in metres.
// COLOR.rgb is the asphalt colour, COLOR.a the marking style (0 none, 0.5 dashed
// centre line, 1 centre line + edge lines).
render_mode specular_disabled;

void fragment() {
	vec3 col = pow(COLOR.rgb, vec3(2.2)); // sRGB vertex colour
	float style = COLOR.a;
	float aa = fwidth(UV.x) * 1.5;
	if (style > 0.25) {
		float centre = 1.0 - smoothstep(0.012, 0.012 + aa, abs(UV.x - 0.5));
		float dash = step(0.5, fract(UV.y / 9.0));
		col = mix(col, vec3(0.82, 0.82, 0.76), centre * dash);
	}
	if (style > 0.75) {
		float edge = 1.0 - smoothstep(0.012, 0.012 + aa, abs(abs(UV.x - 0.5) - 0.45));
		col = mix(col, vec3(0.8, 0.8, 0.8), edge);
	}
	ALBEDO = col;
	ROUGHNESS = 0.9;
}
