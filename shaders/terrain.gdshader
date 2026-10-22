shader_type spatial;
// Flat-shaded low-poly terrain: per-face normals from screen-space derivatives,
// colour from vertex colours. Culling is off so horizon skirts render from outside.
render_mode cull_disabled, specular_disabled;

// Tunnel portals: inverse box transforms in chunk space; terrain inside is cut away.
uniform int portal_count = 0;
uniform mat4 portals[16];
// Cuttings: R = signed distance to the cutting's edge (m, negative inside), G = floor
// height above cut_base. Terrain inside a cutting and above its floor is cut away.
uniform bool has_cut = false;
uniform sampler2D cut_mask : filter_linear, repeat_disable;
uniform float cut_size = 1.0;
uniform float cut_base = 0.0;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	if (has_cut) {
		vec2 c = texture(cut_mask, local_pos.xz / cut_size).rg;
		if (c.r < 0.0 && local_pos.y > cut_base + c.g - 0.5) {
			discard;
		}
	}
	for (int i = 0; i < portal_count; i++) {
		vec3 p = (portals[i] * vec4(local_pos, 1.0)).xyz;
		if (all(lessThanEqual(abs(p), vec3(1.0)))) {
			discard;
		}
	}
	// Face normal from screen-space derivatives, oriented towards the camera (the
	// sign of dFdy depends on the render target's y direction).
	vec3 n = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	NORMAL = dot(n, VIEW) < 0.0 ? -n : n;
	ALBEDO = pow(COLOR.rgb, vec3(2.2)); // vertex colours are authored in sRGB
	ROUGHNESS = 1.0;
}
