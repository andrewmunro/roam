extends Node
## Coordinate conversions between lat/lon, Web Mercator metres, slippy-map tiles
## and the local game frame (x = east, -z = north, metres, centred on an origin).
##
## Mercator positions are stored as two GDScript floats (64-bit) because absolute
## values (~2e7 m) do not fit float32 precision. Anything in Vector2/Vector3 is local.

signal origin_shifted(offset: Vector3)  ## Every node in the world must move by -offset.
signal origin_reset  ## Teleport: everything was invalidated.

const EARTH_RADIUS := 6378137.0
const HALF_WORLD := PI * EARTH_RADIUS
const CHUNK_ZOOM := 14

var origin_mx := 0.0
var origin_my := 0.0
## True-metres per mercator-metre at the origin latitude. Fixed between teleports so
## that chunks built at different times always line up exactly.
var scale := 1.0


func set_origin(lat: float, lon: float) -> void:
	var m := lonlat_to_merc(lon, lat)
	origin_mx = m[0]
	origin_my = m[1]
	scale = cos(deg_to_rad(lat))
	origin_reset.emit()


## Moves the origin to the given local position without changing scale.
func shift_origin(local_pos: Vector3) -> void:
	var offset := Vector3(local_pos.x, 0.0, local_pos.z)
	origin_mx += offset.x / scale
	origin_my -= offset.z / scale
	origin_shifted.emit(offset)


func origin_latlon() -> Vector2:
	var ll := merc_to_lonlat(origin_mx, origin_my)
	return Vector2(ll[1], ll[0])


static func lonlat_to_merc(lon: float, lat: float) -> PackedFloat64Array:
	lat = clampf(lat, -85.05, 85.05)
	var x := EARTH_RADIUS * deg_to_rad(lon)
	var y := EARTH_RADIUS * log(tan(PI / 4.0 + deg_to_rad(lat) / 2.0))
	return PackedFloat64Array([x, y])


## Returns [lon, lat].
static func merc_to_lonlat(mx: float, my: float) -> PackedFloat64Array:
	var lon := rad_to_deg(mx / EARTH_RADIUS)
	var lat := rad_to_deg(2.0 * atan(exp(my / EARTH_RADIUS)) - PI / 2.0)
	return PackedFloat64Array([lon, lat])


func merc_to_local(mx: float, my: float) -> Vector3:
	return Vector3((mx - origin_mx) * scale, 0.0, -(my - origin_my) * scale)


func local_to_merc(p: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([origin_mx + p.x / scale, origin_my - p.z / scale])


## Returns Vector2(lat, lon).
func local_to_latlon(p: Vector3) -> Vector2:
	var m := local_to_merc(p)
	var ll := merc_to_lonlat(m[0], m[1])
	return Vector2(ll[1], ll[0])


func latlon_to_local(lat: float, lon: float) -> Vector3:
	var m := lonlat_to_merc(lon, lat)
	return merc_to_local(m[0], m[1])


static func tile_size_merc(zoom: int) -> float:
	return 2.0 * HALF_WORLD / float(1 << zoom)


static func merc_to_tile(mx: float, my: float, zoom: int) -> Vector2i:
	var size := tile_size_merc(zoom)
	return Vector2i(floori((mx + HALF_WORLD) / size), floori((HALF_WORLD - my) / size))


## North-west corner of a tile in mercator metres.
static func tile_origin_merc(tile: Vector2i, zoom: int) -> PackedFloat64Array:
	var size := tile_size_merc(zoom)
	return PackedFloat64Array([tile.x * size - HALF_WORLD, HALF_WORLD - tile.y * size])


## Local position of a tile's north-west corner.
func tile_origin_local(tile: Vector2i, zoom: int) -> Vector3:
	var m := tile_origin_merc(tile, zoom)
	return merc_to_local(m[0], m[1])


## Tile edge length in local (true) metres.
func tile_size_local(zoom: int) -> float:
	return tile_size_merc(zoom) * scale


func local_to_tile(p: Vector3, zoom: int) -> Vector2i:
	var m := local_to_merc(p)
	return merc_to_tile(m[0], m[1], zoom)
