class_name RegionStyle
## Coarse regional looks: building and roof colours, which pack models line the
## streets, and which side of the road traffic keeps to. Regions are rough lat/lon
## boxes; anything unmatched gets the generic style.

const GENERIC := "generic"
const UK := "uk"
const EUROPE := "europe"
const NORTH_AMERICA := "north_america"
const JAPAN := "japan"
const EAST_ASIA := "east_asia"
const OCEANIA := "oceania"

## [lat_min, lat_max, lon_min, lon_max, region]; first match wins.
const BOXES := [
	[49.8, 61.0, -11.0, 2.0, UK],
	[24.0, 46.0, 123.0, 146.0, JAPAN],
	[18.0, 46.0, 100.0, 146.0, EAST_ASIA],
	[-48.0, -10.0, 112.0, 179.0, OCEANIA],
	[35.0, 71.0, -11.0, 40.0, EUROPE],
	[15.0, 72.0, -170.0, -50.0, NORTH_AMERICA],
]

const WALLS := {
	UK: [Color(0.56, 0.31, 0.23), Color(0.48, 0.27, 0.21), Color(0.62, 0.38, 0.28),
		Color(0.72, 0.60, 0.45), Color(0.82, 0.80, 0.75), Color(0.66, 0.56, 0.44)],
	EUROPE: [Color(0.86, 0.80, 0.68), Color(0.80, 0.70, 0.52), Color(0.88, 0.86, 0.80),
		Color(0.76, 0.62, 0.50), Color(0.70, 0.72, 0.70), Color(0.84, 0.74, 0.60)],
	NORTH_AMERICA: [Color(0.78, 0.74, 0.68), Color(0.72, 0.62, 0.52), Color(0.64, 0.67, 0.70),
		Color(0.80, 0.78, 0.73), Color(0.56, 0.44, 0.38), Color(0.74, 0.70, 0.58)],
	JAPAN: [Color(0.84, 0.83, 0.80), Color(0.72, 0.72, 0.70), Color(0.78, 0.74, 0.66),
		Color(0.62, 0.62, 0.62), Color(0.88, 0.88, 0.86)],
	EAST_ASIA: [Color(0.80, 0.79, 0.76), Color(0.70, 0.70, 0.68), Color(0.76, 0.72, 0.64),
		Color(0.64, 0.66, 0.68)],
	GENERIC: [Color(0.66, 0.62, 0.56), Color(0.62, 0.52, 0.44), Color(0.55, 0.58, 0.62),
		Color(0.70, 0.67, 0.61), Color(0.56, 0.44, 0.38), Color(0.64, 0.60, 0.50)],
}
## Tall buildings everywhere: glass, steel and concrete.
const MODERN_WALLS := [Color(0.52, 0.58, 0.64), Color(0.66, 0.68, 0.70), Color(0.44, 0.50, 0.56),
	Color(0.74, 0.74, 0.72), Color(0.58, 0.56, 0.52)]
const ROOFS := {
	UK: Color(0.30, 0.31, 0.34),  # slate
	EUROPE: Color(0.55, 0.30, 0.22),  # terracotta
	JAPAN: Color(0.32, 0.34, 0.38),
}


static func region_for(lat: float, lon: float) -> String:
	for b: Array in BOXES:
		if lat >= b[0] and lat <= b[1] and lon >= b[2] and lon <= b[3]:
			return b[4]
	return GENERIC


static func wall_colour(region: String, height: float, key: int) -> Color:
	var palette: Array = MODERN_WALLS if height >= 24.0 else WALLS.get(region, WALLS[GENERIC])
	return palette[key % palette.size()]


## Roof colour for low buildings, or null to darken the walls.
static func roof_colour(region: String, height: float) -> Variant:
	if height >= 24.0:
		return null
	return ROOFS.get(region)


static func parked_car_role(region: String) -> String:
	return "parked_car" if region == NORTH_AMERICA else "parked_car_intl"


static func street_furniture_role(region: String) -> String:
	return "street_furniture" if region == NORTH_AMERICA else "street_furniture_intl"


static func left_hand_traffic(region: String) -> bool:
	return region == UK or region == JAPAN or region == OCEANIA
