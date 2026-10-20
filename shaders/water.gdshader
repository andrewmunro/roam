shader_type spatial;
render_mode specular_schlick_ggx;

// sRGB colours; converted below (shader defaults for source_color aren't linearised).
uniform vec3 shallow = vec3(0.38, 0.60, 0.70);
uniform vec3 deep = vec3(0.20, 0.40, 0.54);

void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = pow(mix(deep, shallow, 0.3 + 0.5 * fresnel), vec3(2.2));
	ROUGHNESS = 0.3;
	METALLIC = 0.0;
	SPECULAR = 0.5;
}
