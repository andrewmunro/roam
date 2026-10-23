#!/usr/bin/env python3
"""Writes a stand-in for osmdata.openstreetmap.de's water-polygons-split-3857.zip with
one tiny polygon in mid-Pacific, for when that server is down: tiles build, but the sea
is missing (inland areas look the same; rivers and lakes come from OSM itself).
Usage: no_ocean.py OUT.zip"""
import io
import struct
import sys
import zipfile

# A 10 m square in EPSG:3857, far from land.
x0, y0 = -15000000.0, 0.0
ring = [(x0, y0), (x0, y0 + 10), (x0 + 10, y0 + 10), (x0 + 10, y0), (x0, y0)]
bbox = (x0, y0, x0 + 10, y0 + 10)


def header(length_words):
	return (struct.pack(">7i", 9994, 0, 0, 0, 0, 0, length_words)
		+ struct.pack("<2i", 1000, 5) + struct.pack("<4d", *bbox) + struct.pack("<4d", 0, 0, 0, 0))


content = (struct.pack("<i", 5) + struct.pack("<4d", *bbox) + struct.pack("<2i", 1, len(ring))
	+ struct.pack("<i", 0) + b"".join(struct.pack("<2d", *p) for p in ring))
record = struct.pack(">2i", 1, len(content) // 2) + content
shp = header((100 + len(record)) // 2) + record
shx = header((100 + 8) // 2) + struct.pack(">2i", 50, len(content) // 2)
# dBase III with one numeric field FID.
dbf = (struct.pack("<4BIHH20x", 3, 126, 1, 1, 1, 32 + 32 + 1, 1 + 10)
	+ b"FID".ljust(11, b"\0") + b"N" + b"\0" * 4 + bytes([10, 0]) + b"\0" * 14 + b"\r"
	+ b" " + b"0".rjust(10) + b"\x1a")
prj = ('PROJCS["WGS 84 / Pseudo-Mercator",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",'
	'6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]],'
	'PROJECTION["Mercator_1SP"],PARAMETER["central_meridian",0],PARAMETER["scale_factor",1],'
	'PARAMETER["false_easting",0],PARAMETER["false_northing",0],UNIT["metre",1],'
	'AUTHORITY["EPSG","3857"]]')
with zipfile.ZipFile(sys.argv[1], "w") as z:
	base = "water-polygons-split-3857/water_polygons."
	z.writestr(base + "shp", shp)
	z.writestr(base + "shx", shx)
	z.writestr(base + "dbf", dbf)
	z.writestr(base + "prj", prj)
