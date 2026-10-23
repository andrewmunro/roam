# Road and mesh issues

Working list for road, bridge, tunnel and terrain generation. Goal: smooth,
seamless, drivable geometry; real-world accuracy (Street View) is reference, not
a requirement. Fix generically in the builder, never per location.

Check a spot fast with the chunk viewer (seconds, from cache):

```
tools/view.sh OUT_DIR -- --cam=lat,lon,h,heading,pitch [--cam=...] [--roads-only] [--tiles=seam]
```

Use driver-eye cams (h 1.5-3, pitch about -5) looking both ways, inside
tunnels and cuttings, on and under bridges, plus one oblique. Full game run with a
drive: `RES=960x540 tools/shots.sh DIR 400 -- --latlon=LAT,LON --heading=H --drive --drive-after=70`.
Regression tests: `tests/test_chunk_heights.tscn` (worst terrain-above-road
0.30 m on the SF tile), `tests/test_roads.tscn` (timings), `tests/test_despike.tscn`.

## Plan (agreed 2026-10-22): measure, then fix root causes

Most symptoms below come from three causes:

1. **Roads overlap at different levels** because widths are guessed (tiles carry
   no lanes or width): twin carriageways, slips beside the main road.
2. **Terrain fights roads**: a 15 m grid over 30 m SRTM can't follow two roads at
   different heights close together; flattening is max-wins.
3. **Walls and decks are placed from nominal widths**, not the geometry drawn.

Order of work:

1. Regression suite: `tests/test_locations.tscn` builds 10-20 fixed spots from
   cache and measures, per spot: overlap between road surfaces at different levels
   (m²), terrain above road (count, worst), steeply tilted road triangles (m²), walls
   standing on a carriageway (m). Results compare against a stored baseline; a
   change that makes any spot worse fails.
2. Fit widths to the space available (neighbouring ways, buildings), with walls and
   decks at the fitted edge.
3. Roads own the ground: cut or conform terrain to road surfaces (road mask, or road
   heights stamped into finer local terrain) instead of draping and lifting.
4. Our own tiles (Planetiler) with lanes, width and roof tags.

Symptom fixes are paused unless the suite shows them as root-cause fixes.

### Progress

- **Suite** in place (`tests/test_locations.tscn`, baseline `tests/locations_baseline.json`,
  `--where` lists hotspots). ~6 min for 12 spots.
- **Overlap** (cause 1), in `RoadLevels`:
  - overlapping roads are linked to one height after a first solve, unless that solve
    put them a clearance apart (stacked); different layers only where they merge;
  - a street joins a tunnel or bridge only head on at both ends (no mid-span joins, no
    car-park lane joining a tunnel mouth);
  - squeezed limits: tunnels keep under what crosses them, bridges over;
  - fitted widths: roads side by side at different levels give up their share of the
    overlap (`fit()`), and walls, shoulders and decks follow the fitted edges;
  - one-way carriageways of motorway/trunk/primary/secondary are narrower.
- **Terrain** (cause 2): `_keep_under_roads` keeps terrain near open roads 0.15 m under
  the nearest point of each road; then, with the roads drawn (roads stage now runs
  before the terrain mesh), `_ground_under_roads` lowers every terrain vertex within a
  cell of a drawn carriageway triangle (`RoadNetwork.ground_tris`: edges at their drawn
  width, junction fills, roundabout rings and islands, local roads) under it, ~50-85 ms.
  Triangles down in a cutting open the ground instead (added to the cut mask), so a
  junction in a cutting isn't roofed over by terrain. Buried road: 0 m² at all 12 spots
  (was 586 Leeds onramp, 1715 Giza, 82 Paris).
- Twin carriageways at one level mapped closer than their widths are fitted too (not
  only roads at different levels); merging/continuing roads are left alone.
- Collision: faces with no area or a sub-centimetre edge are dropped before Jolt sees
  them (one made it reject a whole road shape on the own-tiles US-101 tile).
- **Own tiles** (`tools/tiles/`): `build.sh AREA` builds z14 OpenMapTiles with Planetiler
  plus `roam-tags.patch` (transportation `lanes`, `width`; building `roof_shape`,
  `roof_height`) into a z/x/y directory; `serve.sh DIR` serves it with CORS. The game
  takes `?tiles=URL` (web) or `ROAM_TILES=URL`, falling back to OpenFreeMap per tile
  (`TileSource`). Tagged widths set road half widths (`_tagged_hw`), tagged roofs replace
  Overpass roofs. osmdata.openstreetmap.de (sea polygons) was unreachable, so
  `no_ocean.py` stands in: tiles build without the sea. Hosting not decided.
  Built so far: West Yorkshire, Greater Manchester, North Yorkshire, West Midlands, Greater
  London, Egypt, Ile-de-France, NorCal (~1.5 GB of z14 tiles, ~200k files).
  Own-tile suite baseline: `tests/locations_baseline_own.json` (run with ROAM_TILES set).
  Tagged lanes vs guessed widths, same build: Leeds onramp overlap 925 -> 76 m², walls
  145 -> 76 m; Spaghetti overlap 1570 -> 1319; Broadway tilt 3870 -> 2741. Worse where
  real widths are wider than the mapped gap allows: SF Sunset overlap 149 -> 276, Giza
  1239 -> 1964, Paris tilt 430 -> 1170 (Périphérique 4 lanes, hw 7.2 vs 3.85 guessed,
  crowding the Porte Maillot ramps).
- Results vs first baseline: overlap Giza 11611 -> 1299 m², Paris 6792 -> 879, Broadway
  6435 -> 588, Spaghetti 3411 -> 1740; buried Leeds onramp 1023 -> 586, Giza 2325 ->
  1715; walls Paris 820 -> 271 m.
- Still to do: twin carriageways at one level still overlap (markings); Spaghetti
  stacked ramps (side-by-side clearance attempt made things worse elsewhere; reverted);
  Cairo DEM still has building bumps the despike gate keeps (steep minor roads);
  classify stage ~1.7 s (was 0.7 s) from the two-pass solve.

## Open

| # | Issue | Where | Notes |
|---|-------|-------|-------|
| 14 | Junction surfaces in a cutting have no walls: ground at street level ends in an open edge above the road | Paris Porte Maillot 48.87700,2.27862 (heading 0) | Cut mask now opens over them; `_build_sides` only walls the cutting's lines. |
| 15 | Own tiles: real lane widths crowd tightly mapped ramps and twins (overlap, tilt) | SF Sunset 37.77063,-122.47915; Giza; Paris | Fitting helps a little; ramps at junctions need their own fit. |
| 16 | Own tiles built without the sea (osmdata.openstreetmap.de unreachable from here) | coastal tiles | Rebuild when it answers; `build.sh` uses it automatically. |
| 17 | Own tiles hosting | — | Static z/x/y on R2/Pages vs PMTiles: not decided. Opt-in only (`?tiles=`) until then. |
| 13 | Slip road merging into the cutting: road covered by dark shards, deformed surface, walls at odd angles | Leeds A58(M) 53.80068,-1.55483 (heading 2) and 53.80105,-1.55478 (heading 187) | Reported from the live site after b15ffbc. |
| 1 | Parallel carriageways overlap: medians show asphalt patches, lane markings cross | Giza ring road 29.98801,31.21661; Aston Expressway 52.5098,-1.8598 | At Giza the "median" is a low bridge slip (layer 1, solved at ground, 19.0) buried by terrain (20.3) raised by a neighbouring climbing road's flattening. Terrain isn't flattened under bridges. |
| 2 | Road stage ~1.8x slower than before the solver rewrite | `tests/test_roads.tscn`: 4.0 s vs 2.2 s (roads stage) | Profile `RoadLevels.surface()` call volume, `_classify` (+200 ms). |
| 3 | Dark low wall / skirt along a median edge | Giza 29.98801,31.21661 street level | Probably `_skirt()` on an unkerbed edge beside a higher piece. |
| 4 | Cycleway drawn over the carriageway in red | Neville St, Leeds 53.7935,-1.5470 | Real lane is painted on the road; maybe fine, maybe skip path samples on carriageways. |
| 5 | Broadway tunnel west portal: building over the approach cut? | SF 37.7967,-122.4180 | Agent saw it on older code; my re-render missed the portal. Needs proper cams. |
| 6 | Pillars under bridges don't check for roads below | `_build_bridge` | Candidate from the Leeds agent (Westgate); not confirmed. |
| 7 | Solver: final crossing round's pushes are never re-solved; 3 smoothing passes after `_bounded` can cross tunnel ceilings / bridge floors | `road_levels.gd` `solve()` | Assert lo <= h <= hi after smoothing on Broadway and Leeds tiles. |
| 8 | `_link_portals` pair loop may be slow in dense tiles | `road_levels.gd` | Time it. |
| 9 | Step pyramids (stacked `building:part`s, e.g. Djoser 29.8713,31.2165) | buildings | Unchecked. |
| 10 | Pyramid crossing a seam: face from the clipped buffer edge can differ between chunks | `_roof_faces` | Rare; Great Pyramid looks fine. |
| 11 | Overpass mirrors: only overpass-api.de and maps.mail.ru; others untested for CORS | `osm_points.gd` | Public server is often at capacity (30-40 s per tile). |
| 12 | Hide terrain under roads (road mask in shader) if skirts aren't enough | terrain shader | Mask mode exists (`?roads=mask`), not default. |

## Not yet checked (location-fixer gaps)

The agents ran on an overloaded machine and finished with thin coverage:

- SF: Stockton tunnel, freeway overpasses (US-101 near 37.7720,-122.4230), inside
  the Broadway tube.
- Leeds: Victoria Bridge and Leeds Bridge ends at street level; a drive across
  either bridge.
- Spaghetti Junction: drive along the flyover ramps; street-level views of the
  stacked ramps.
- More bridge and tunnel types: a long river bridge, a motorway over a valley,
  a bored rail/road tunnel under a hill, a stacked interchange outside the UK.

## Done

- Road height solver (`RoadLevels`): grade, bridges, tunnels, cuttings in one
  graph; junctions beside cuttings stay at street level.
- Cutting walls per side, parapets over drops, closed ends; portal decks at
  street level (Leeds A58(M)). Drive through the cutting and up the Westgate slip
  works.
- Deck soffits closed (Spaghetti Junction "comb").
- Buildings clipped out of road corridors (Iles Lane, Knaresborough).
- Roads no longer buried on SF hills (terrain poke lift for non-sunk roads).
- DEM despike: tower blocks read as hills in SRTM (Giza ring road).
- Pyramid, cone and dome roofs from OSM `roof:shape` (Giza pyramids).
- MVT and Overpass caching independent of upstream versions; 429 backoff.
