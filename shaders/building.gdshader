shader_type spatial;
// Procedural facades for extruded OSM buildings.
// UV  = (metres along the perimeter, metres above ground), UV2 = (height, random 0..1)
// COLOR.rgb = wall/roof colour (sRGB), COLOR.a = 1 for walls, 0 for roofs.
render_mode specular_schlick_ggx;

const float FLOOR_H = 3.2;
const float BAY_W = 3.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// 1 inside [lo, hi] with ~1px antialiased edges.
float band(float x, float lo, float hi, float aa) {
	return smoothstep(lo - aa, lo + aa, x) * (1.0 - smoothstep(hi - aa, hi + aa, x));
}

void fragment() {
	vec3 base = pow(COLOR.rgb, vec3(2.2));
	float height = UV2.x;
	float rnd = UV2.y;
	ALBEDO = base;
	ROUGHNESS = 0.9;
	if (COLOR.a > 0.5 && height > 3.5) {
		vec2 f = UV;
		float floors = max(floor(height / FLOOR_H), 1.0);
		float floor_i = floor(f.y / FLOOR_H);
		vec2 cell = vec2(fract(f.x / BAY_W), fract(f.y / FLOOR_H));
		vec2 aa = fwidth(f / vec2(BAY_W, FLOOR_H)) * 0.75;
		// Window size varies per building; tall buildings get wider glazing.
		float ww = mix(0.45, 0.7, rnd) + (height > 30.0 ? 0.15 : 0.0);
		float wx = band(cell.x, 0.5 - ww * 0.5, 0.5 + ww * 0.5, aa.x);
		float wy = band(cell.y, 0.28, 0.82, aa.y);
		float inside = step(0.0, f.y) * step(floor_i, floors - 1.0) * step(f.y, height - 0.6);
		float window = wx * wy * inside;
		// Ground floor: taller shop glazing on taller (non-house) buildings.
		bool shopfront = floor_i < 0.5 && height > 9.0;
		if (shopfront) {
			window = band(cell.x, 0.08, 0.92, aa.x) * band(cell.y, 0.08, 0.78, aa.y) * step(0.0, f.y);
		}
		float lit = step(0.82, hash12(vec2(floor(f.x / BAY_W), floor_i) + rnd * 97.0));
		vec3 glass = mix(vec3(0.05, 0.09, 0.14), vec3(0.16, 0.22, 0.30), hash12(vec2(floor_i, rnd * 13.0)));
		glass = mix(glass, vec3(0.55, 0.45, 0.28), lit * 0.35);
		// Slightly darker plinth band and a light cornice line at the top.
		float plinth = 1.0 - step(0.6, f.y);
		float cornice = step(height - 0.45, f.y);
		vec3 wall = base * (1.0 - plinth * 0.3) * mix(1.0, 1.15, cornice);
		ALBEDO = mix(wall, glass, window);
		ROUGHNESS = mix(0.9, 0.15, window);
		SPECULAR = mix(0.3, 0.7, window);
	}
}
