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

// Roads surfaced by the terrain itself (ROAM_ROAD_MASK): L8 over the tile, road where
// below 0.5 (see UrbanBlocks.road_mask). road_size is the mask's extent in metres.
uniform bool has_roads = false;
uniform sampler2D road_mask : filter_linear, repeat_disable;
uniform float road_size = 1.0;

varying vec3 local_pos;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x),
		mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}

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
	if (has_roads) {
		vec2 uv = local_pos.xz / road_size;
		if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
			float m = texture(road_mask, uv).r;
			float aa = max(fwidth(m), 0.02);
			float road = 1.0 - smoothstep(0.5 - aa, 0.5 + aa, m);
			// Asphalt: patchy repairs and fine grain, settling to flat with distance.
			vec2 w = local_pos.xz;
			float fade = 1.0 - smoothstep(0.15, 0.6, length(fwidth(w)));
			float tone = 0.9 + 0.12 * value_noise(w * 0.12) + 0.06 * fade * (value_noise(w * 2.3) - 0.5);
			vec3 asphalt = pow(vec3(0.43, 0.43, 0.45) * tone, vec3(2.2));
			ALBEDO = mix(ALBEDO, asphalt, road);
			ROUGHNESS = mix(1.0, 0.85, road);
		}
	}
}
