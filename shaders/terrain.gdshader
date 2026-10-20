shader_type spatial;
// Flat-shaded low-poly terrain: per-face normals from screen-space derivatives,
// colour from vertex colours. Culling is off so horizon skirts render from outside.
render_mode cull_disabled, specular_disabled;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Face normal from screen-space derivatives, oriented towards the camera (the
	// sign of dFdy depends on the render target's y direction).
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = dot(n, VIEW) < 0.0 ? -n : n;
	ALBEDO = pow(COLOR.rgb, vec3(2.2)); // vertex colours are authored in sRGB
	ROUGHNESS = 1.0;
}
