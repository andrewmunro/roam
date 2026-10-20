shader_type spatial;
render_mode specular_schlick_ggx;

uniform vec3 shallow : source_color = vec3(0.22, 0.46, 0.60);
uniform vec3 deep : source_color = vec3(0.10, 0.27, 0.42);

void fragment() {
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = mix(deep, shallow, 0.4 + 0.6 * fresnel);
	ROUGHNESS = 0.15;
	METALLIC = 0.0;
	SPECULAR = 0.6;
}
