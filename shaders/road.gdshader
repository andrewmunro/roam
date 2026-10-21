shader_type spatial;
// Roads: UV.x runs across the road (0..1), UV.y along it in metres (stretched so each
// stretch of road holds a whole number of 12 m dash periods). COLOR.rgb is the surface
// colour. UV2.x is the half width in metres, UV2.y the marking style:
//   bits 0-1  centre line: 0 none, 1 white dashes, 2 double yellow
//   bits 2-3  extra lanes: lane lines dividing each direction (one-way: the whole road)
//   bit 4     solid edge lines
//   bit 5     one-way
//   64        solid paint (stop lines, give-way lines, crossings): drawn as COLOR
render_mode specular_disabled;

const vec3 WHITE = vec3(0.70, 0.70, 0.64);
const vec3 YELLOW = vec3(0.70, 0.45, 0.04);

void vertex() {
	if (UV2.y > 63.5) {
		// Paint sits a few cm over the asphalt; pull it towards the camera a little so
		// it doesn't flicker at a distance.
		vec3 cam = CAMERA_POSITION_WORLD - MODEL_MATRIX[3].xyz;
		VERTEX += (cam - VERTEX) * 0.0015;
	}
}

float line_at(float x, float centre, float half_w, float aa) {
	return 1.0 - smoothstep(half_w, half_w + aa, abs(x - centre));
}

void fragment() {
	vec3 col = pow(COLOR.rgb, vec3(2.2)); // sRGB vertex colour
	int style = int(UV2.y + 0.5);
	if (style >= 64) {
		ALBEDO = col;
		ROUGHNESS = 0.7;
	} else {
		if (style > 0) {
			float hw = UV2.x;
			float x = (UV.x - 0.5) * 2.0 * hw;
			float aa = fwidth(x) * 1.2;
			float phase = fract(UV.y / 12.0);
			float dash = step(0.333, phase) * step(phase, 0.667);
			float lane_dash = step(0.375, phase) * step(phase, 0.625);
			int centre = style & 3;
			int lanes = (style >> 2) & 3;
			bool oneway = (style & 32) != 0;
			float white = 0.0;
			float yellow = 0.0;
			if (centre == 1) {
				white = max(white, line_at(x, 0.0, 0.07, aa) * dash);
			} else if (centre == 2) {
				yellow = max(yellow, line_at(abs(x), 0.16, 0.06, aa));
			}
			float edge_w = hw - 0.3;
			if (lanes > 0) {
				float n = float(lanes + 1);
				if (oneway) {
					for (int k = 1; k <= lanes; k++) {
						float lx = -edge_w + 2.0 * edge_w * float(k) / n;
						white = max(white, line_at(x, lx, 0.06, aa) * lane_dash);
					}
				} else {
					for (int k = 1; k <= lanes; k++) {
						float lx = edge_w * float(k) / n;
						white = max(white, line_at(abs(x), lx, 0.06, aa) * lane_dash);
					}
				}
			}
			if ((style & 16) != 0) {
				white = max(white, line_at(abs(x), edge_w, 0.08, aa));
			}
			col = mix(col, WHITE, white);
			col = mix(col, YELLOW, yellow);
		}
		ALBEDO = col;
		ROUGHNESS = 0.9;
	}
}
