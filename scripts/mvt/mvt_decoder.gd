class_name MVTDecoder
## Minimal Mapbox Vector Tile (protobuf) decoder.
##
## decode() returns {layer_name: {extent: int, features: Array[Dictionary]}} where each
## feature is {id: int, type: int, tags: Dictionary, rings: Array[PackedVector2Array]}.
## Coordinates stay in tile units (0..extent, y down). Unwanted layers are skipped
## without being parsed, which matters because label layers are large.

const GEOM_POINT := 1
const GEOM_LINE := 2
const GEOM_POLYGON := 3

var _buf: PackedByteArray
var _pos := 0


static func decode(data: PackedByteArray, wanted_layers: Array) -> Dictionary:
	var d := MVTDecoder.new()
	d._buf = data
	var out := {}
	var end := data.size()
	while d._pos < end:
		var key := d._varint()
		if key >> 3 == 3 and key & 7 == 2:
			var length := d._varint()
			var layer_end := d._pos + length
			var layer := d._layer(layer_end, wanted_layers)
			if not layer.is_empty():
				out[layer.name] = layer
			d._pos = layer_end
		else:
			d._skip(key & 7)
	return out


func _varint() -> int:
	var result := 0
	var shift := 0
	while true:
		var b := _buf[_pos]
		_pos += 1
		result |= (b & 0x7f) << shift
		if b < 0x80:
			return result
		shift += 7
	return result


func _skip(wire_type: int) -> void:
	match wire_type:
		0: _varint()
		1: _pos += 8
		2: _pos += _varint()
		5: _pos += 4


func _string(length: int) -> String:
	var s := _buf.slice(_pos, _pos + length).get_string_from_utf8()
	_pos += length
	return s


func _layer(layer_end: int, wanted_layers: Array) -> Dictionary:
	var name := ""
	var extent := 4096
	var feature_spans: Array[Vector2i] = []
	var keys: Array[String] = []
	var values: Array = []
	while _pos < layer_end:
		var key := _varint()
		var field := key >> 3
		var wire := key & 7
		if field == 1 and wire == 2:
			name = _string(_varint())
			# The name is conventionally the first field, so bail out early.
			if not wanted_layers.has(name):
				return {}
		elif field == 2 and wire == 2:
			var length := _varint()
			feature_spans.append(Vector2i(_pos, _pos + length))
			_pos += length
		elif field == 3 and wire == 2:
			keys.append(_string(_varint()))
		elif field == 4 and wire == 2:
			var length := _varint()
			values.append(_value(_pos + length))
		elif field == 5 and wire == 0:
			extent = _varint()
		else:
			_skip(wire)
	if not wanted_layers.has(name):
		return {}
	var features: Array[Dictionary] = []
	for span in feature_spans:
		_pos = span.x
		features.append(_feature(span.y, keys, values))
	return {name = name, extent = extent, features = features}


func _value(value_end: int) -> Variant:
	var v: Variant = null
	while _pos < value_end:
		var key := _varint()
		match key >> 3:
			1: v = _string(_varint())
			2:
				v = _buf.decode_float(_pos)
				_pos += 4
			3:
				v = _buf.decode_double(_pos)
				_pos += 8
			4, 5: v = _varint()
			6:
				var z := _varint()
				v = (z >> 1) ^ -(z & 1)
			7: v = _varint() != 0
			_: _skip(key & 7)
	return v


func _feature(feature_end: int, keys: Array[String], values: Array) -> Dictionary:
	var id := 0
	var type := 0
	var tags := {}
	var rings: Array[PackedVector2Array] = []
	while _pos < feature_end:
		var key := _varint()
		match key >> 3:
			1: id = _varint()
			2:
				var tags_end := _pos + _varint()
				while _pos < tags_end:
					var k := _varint()
					var v := _varint()
					tags[keys[k]] = values[v]
			3: type = _varint()
			4: rings = _geometry(_pos + _varint())
			_: _skip(key & 7)
	return {id = id, type = type, tags = tags, rings = rings}


func _geometry(geom_end: int) -> Array[PackedVector2Array]:
	var rings: Array[PackedVector2Array] = []
	var ring := PackedVector2Array()
	var x := 0
	var y := 0
	while _pos < geom_end:
		var cmd_int := _varint()
		var cmd := cmd_int & 7
		var count := cmd_int >> 3
		if cmd == 7:  # ClosePath
			if ring.size() > 0:
				ring.append(ring[0])
			continue
		for i in count:
			var dx := _varint()
			var dy := _varint()
			x += (dx >> 1) ^ -(dx & 1)
			y += (dy >> 1) ^ -(dy & 1)
			if cmd == 1:  # MoveTo starts a new part
				if ring.size() > 0:
					rings.append(ring)
				ring = PackedVector2Array()
			ring.append(Vector2(x, y))
	if ring.size() > 0:
		rings.append(ring)
	return rings


## Shoelace area in tile coordinates. Per the MVT spec, exterior polygon rings are
## positive (clockwise on screen) and holes are negative.
static func ring_area(ring: PackedVector2Array) -> float:
	var a := 0.0
	var n := ring.size()
	for i in n:
		var p := ring[i]
		var q := ring[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return a * 0.5
