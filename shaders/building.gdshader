shader_type spatial;
// Procedural facades for extruded OSM buildings.
// Walls: UV = (window bays along the wall, 0 at one corner; metres above ground).
// UV2 = (height, bays + random): the integer part of UV2.y is the wall's bay count,
// its fraction (0.05..0.95) the building's random number.
// COLOR.rgb = wall/roof colour (sRGB), COLOR.a = 1 for walls, 0 for roofs.
render_mode specular_schlick_ggx;

const float FLOOR_H = 3.2;  // target storey height; each building fits a whole number
const float PARAPET = 0.5;  // solid band above the top storey
const float PIER = 0.2;  // masonry at each end of a wall, in bays

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

// 1 inside [lo, hi] with ~1px antialiased edges.
float band(float x, float lo, float hi, float aa) {
	return smoothstep(lo - aa, lo + aa, x) * (1.0 - smoothstep(hi - aa, hi + aa, x));
}

void fragment() {
	vec3 base = pow(COLOR.rgb, vec3(2.2));
	float height = UV2.x;
	float bays = floor(UV2.y);
	// Snapped back to its 1/1000 steps: interpolation jitters it, and hashes amplify that.
	float rnd = round((fract(UV2.y) - 0.05) / 0.9 * 1000.0) / 1000.0;
	ALBEDO = base;
	ROUGHNESS = 0.9;
	if (COLOR.a < 0.5) {
		// Roofs (and structures): faint patchy weathering, faded out with distance.
		vec2 p = UV * 0.35;
		float fade = 1.0 - smoothstep(0.3, 1.2, length(fwidth(p)));
		ALBEDO = base * mix(1.0, 0.86 + 0.24 * value_noise(p + rnd * 37.0), fade);
	} else {
		float y = UV.y;
		vec3 wall = base;
		// Ground-level darkening: deeper on taller buildings, as in a street canyon.
		float ao = mix(0.62, 1.0, smoothstep(-0.5, clamp(height * 0.5, 3.0, 14.0), y));
		// Darker plinth, light coping band along the top.
		wall *= 1.0 - (1.0 - step(0.6, y)) * 0.25;
		float coping = step(height - 0.35, y);
		wall *= mix(1.0, 1.2, coping);
		ALBEDO = wall * ao;
		if (height > 3.5 && bays > 0.5) {
			bool curtain = (height > 35.0 && rnd > 0.4) || (height > 18.0 && rnd > 0.85);
			bool house = height < 9.0;
			float floors = max(floor((height - PARAPET) / FLOOR_H + 0.3), 1.0);
			float fh = (height - PARAPET) / floors;
			float gv = y / fh;
			float floor_i = floor(gv);
			// Bays fill the wall between its corner piers (curtain walls run edge to edge).
			float pier = curtain ? 0.0 : (bays >= 2.0 ? PIER : 0.08);
			float g = (UV.x - pier) / (bays - 2.0 * pier) * bays;
			float in_wall = step(pier, UV.x) * step(UV.x, bays - pier);
			vec2 cell = vec2(fract(g), fract(gv));
			vec2 aa = fwidth(vec2(g, gv)) * 0.75;
			float rows = step(0.0, y) * step(floor_i, floors - 1.0) * in_wall;

			float x_lo, x_hi, y_lo, y_hi;
			if (curtain) {
				x_lo = 0.04; x_hi = 0.96;  // mullions
				y_lo = 0.14; y_hi = 0.94;  // spandrel panels
			} else {
				float ww = house ? 0.5 : mix(0.42, 0.62, rnd);
				x_lo = 0.5 - ww * 0.5; x_hi = 0.5 + ww * 0.5;
				y_lo = 0.28; y_hi = 0.82;
			}
			bool shopfront = floor_i < 0.5 && height > 9.0;
			if (shopfront) {
				x_lo = 0.06; x_hi = 0.94;
				y_lo = 0.04; y_hi = 0.74;
			}
			float window = band(cell.x, x_lo, x_hi, aa.x) * band(cell.y, y_lo, y_hi, aa.y) * rows;
			// Shopfront: dark fascia above the glazing.
			if (shopfront) {
				float fascia = band(cell.y, 0.78, 0.94, aa.y) * band(cell.x, 0.02, 0.98, aa.x) * rows;
				wall = mix(wall, mix(vec3(0.03), base * 0.35, rnd), fascia);
			} else if (!curtain) {
				// Stone sill below each window, lintel above.
				float sill = band(cell.x, x_lo - 0.05, x_hi + 0.05, aa.x) * band(cell.y, y_lo - 0.05, y_lo, aa.y);
				float lintel = band(cell.x, x_lo, x_hi, aa.x) * band(cell.y, y_hi, y_hi + 0.04, aa.y);
				wall = mix(wall, mix(base, vec3(0.62, 0.6, 0.55), 0.6), (sill + lintel) * rows);
				// Faint string course at each floor line.
				wall *= 1.0 - band(cell.y, 0.0, 0.025, aa.y) * rows * 0.15;
			} else {
				// Curtain wall: spandrels in a darker tone of the frame colour.
				wall = mix(wall, base * 0.55, rows);
			}

			// Glass: dark interior, some blinds part drawn, sky reflected at grazing angles.
			float wv = clamp((cell.y - y_lo) / (y_hi - y_lo), 0.0, 1.0);
			vec2 win_id = vec2(floor(g), floor_i) + rnd * 97.0;
			float h = hash12(win_id);
			vec3 interior = mix(vec3(0.02, 0.025, 0.03), vec3(0.07, 0.07, 0.065), hash12(win_id + 3.1));
			float blind = step(0.55, h) * step(1.0 - mix(0.15, 0.6, hash12(win_id + 7.7)), wv);
			interior = mix(interior, vec3(0.42, 0.40, 0.36), blind * (shopfront ? 0.0 : 1.0));
			if (curtain) {
				interior = mix(interior, vec3(0.05, 0.08, 0.1), 0.6);
			}
			// Shadow of the reveal along the top and one side of the opening.
			float reveal = smoothstep(0.82, 1.0, wv) + smoothstep(x_lo + 0.08, x_lo, cell.x);
			interior *= 1.0 - clamp(reveal, 0.0, 1.0) * 0.6;
			float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
			vec3 sky = mix(vec3(0.18, 0.24, 0.32), vec3(0.42, 0.55, 0.7), wv);
			vec3 glass = mix(interior, sky, clamp(fres * 0.85 + (curtain ? 0.25 : 0.05), 0.0, 1.0));
			float lit = step(0.9, hash12(win_id + 11.3));
			glass = mix(glass, vec3(0.55, 0.45, 0.28), lit * 0.3);

			ALBEDO = mix(wall * ao, glass, window);
			ROUGHNESS = mix(0.9, 0.15, window);
			SPECULAR = mix(0.3, 0.7, window);
		}
	}
}
