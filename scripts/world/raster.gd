class_name Raster
## Scanline rasterisation onto packed grids (PackedByteArray or PackedInt32Array). Cell (i, j) is sampled at its centre,
## ((i + 0.5) * cell, (j + 0.5) * cell), in the same units as the polygon points.


## Fills all rings with even-odd rule (so holes are respected when passed together).
static func fill_rings(grid: Variant, w: int, h: int, cell: float,
		rings: Array[PackedVector2Array], value: int) -> void:
	var min_y := INF
	var max_y := -INF
	for ring in rings:
		for p in ring:
			min_y = minf(min_y, p.y)
			max_y = maxf(max_y, p.y)
	var j0 := maxi(0, ceili(min_y / cell - 0.5))
	var j1 := mini(h - 1, floori(max_y / cell - 0.5))
	var xs := PackedFloat32Array()
	for j in range(j0, j1 + 1):
		var y := (j + 0.5) * cell
		xs.clear()
		for ring in rings:
			var n := ring.size()
			for k in n:
				var a := ring[k]
				var b := ring[(k + 1) % n]
				if (a.y <= y) != (b.y <= y):
					xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		var row := j * w
		for k in range(0, xs.size() - 1, 2):
			var i0 := maxi(0, ceili(xs[k] / cell - 0.5))
			var i1 := mini(w - 1, floori(xs[k + 1] / cell - 0.5))
			for i in range(i0, i1 + 1):
				grid[row + i] = value


static func fill_polygon(grid: Variant, w: int, h: int, cell: float,
		poly: PackedVector2Array, value: int) -> void:
	var rings: Array[PackedVector2Array] = [poly]
	fill_rings(grid, w, h, cell, rings, value)


## Marks every cell within `half_width` of the polyline.
static func stroke_polyline(grid: Variant, w: int, h: int, cell: float,
		line: PackedVector2Array, half_width: float, value: int) -> void:
	for k in line.size() - 1:
		var a := line[k]
		var b := line[k + 1]
		var d := b - a
		if d.length_squared() < 1e-6:
			continue
		var n := Vector2(-d.y, d.x).normalized() * half_width
		var e := d.normalized() * half_width
		fill_polygon(grid, w, h, cell,
			PackedVector2Array([a - n - e, b - n + e, b + n + e, a + n - e]), value)
