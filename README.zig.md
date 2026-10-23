# Zig facade API

This reference covers the typed facade; package build and platform requirements are in `README.md`.

## Exports

The root namespace exports `Error`, `max_level` (30), `num_faces` (6), `c`, and the types below. It also exports `runtime_loaded`, `LoadSource`, `LoadError`, `load` and `loadedSource` for the runtime-loading route.

`c` exposes the translated declarations from `zig/bridge.h`. It is an unchecked escape hatch: facade validation, error mapping, ownership and buffer guarantees do not apply.

## Errors and contracts

| Error | Meaning |
|---|---|
| `InvalidArgument` | An input, index, cell id or option is outside the supported contract. |
| `BufferTooSmall` | An output buffer cannot hold the result; no bytes or elements are written. The required length is not returned. |
| `OutOfMemory` | An upstream C++ allocation failed. |
| `Internal` | Upstream reported failure or the bridge returned an unknown status. |

- `Point`, `LatLng`, `BoundUV`, `CellId`, `Cell`, `Cap` and `LatLngRect` are plain values; copies own no storage.
- `Loop` and `Polygon` own opaque C++ handles. Zig copies alias the same handle: call `deinit` exactly once on the owner. Input vertex arrays are borrowed for the call and copied by upstream.
- List methods fill a caller-owned buffer and return its populated prefix. Use the paired `...Count` method to size it; a short buffer is unchanged and returns no count. `CellId.childrenCount` computes the range without building descendants.
- `LatLng` stores degrees; `fromDegrees` does not normalize, while `normalized` clamps latitude and wraps longitude. `distanceDeg` requires normalized inputs. `Loop.perimeterRad` returns radians; areas are steradians.
- `Cap.containsPoint` and `Polygon.containsPoint` require a finite unit direction; `Cell.containsPoint` accepts non-unit directions.
- `CellId.raw` accepts any `u64` without validation. Methods that need a valid cell return `InvalidArgument`; `isValid` reports validity. `fromFace` accepts 0..7, with 6 and 7 producing invalid ids.
- `fromFacePosLevel` requires face 0..5, level 0..30 and a position no wider than 61 bits. `fromFaceIJ` requires face 0..5 and `i`,`j` below 2^30.
- `CellId.toToken` and `toDebugString` need room for text plus NUL; a token needs at most 17 bytes.
- `LatLngRect` bounds with `lng_lo_deg > lng_hi_deg` describe a rectangle crossing the antimeridian. A `Cap` radius is clamped at 180 degrees by upstream.
- `Coverer` validates `min_level <= max_level <= 30`, `level_mod` in 1..3, and `max_cells` in 1..`maxInt(c_int)`. Covering results may change between upstream versions; `...Count` runs the coverer.

## Value types

### `Point`

Fields: `x`, `y`, `z: f64`. `normalized() Error!Point`; `toLatLng() Error!LatLng`.

### `LatLng`

Fields: `lat_deg`, `lng_deg: f64`. `fromDegrees(f64, f64) LatLng`; `fromRadians(f64, f64) LatLng`; `isValid() bool`; `normalized() Error!LatLng`; `toPoint() Error!Point`; `distanceDeg(other: LatLng) Error!f64`.

### `BoundUV`

Fields: `u_lo`, `u_hi`, `v_lo`, `v_hi: f64`.

### `CellId`

Field: `raw: u64`; constants `none` (`0`) and `sentinel` (`0xffff_ffff_ffff_ffff`).
- Constructors return `Error!CellId`: `fromLatLng(LatLng)`, `fromPoint(Point)`, `fromFace(u8)`, `fromFacePosLevel(u8, u64, u8)`, `fromFaceIJ(u8, u32, u32)`, `fromToken([]const u8)`, `fromDebugString([]const u8)`.
- Strings: `toToken([]u8) Error![]const u8`; `toDebugString([]u8) Error![]const u8`. Malformed input to the matching parsers returns `InvalidArgument`.
- Queries: `isValid() bool`, `isLeaf() bool`, `isFace() bool`, `level() Error!u8`, `face() Error!u8`, `pos() Error!u64`.
- Navigation: `parent(target_level: ?u8) Error!CellId` (`null` means immediate parent; explicit levels cannot exceed this cell's; level 0 has none), `child(position: u8) Error!CellId` (0..3, non-leaf cells only), `next() Error!CellId`, `prev() Error!CellId` (neither wraps).
- Children: `children(target_level: u8, out: []CellId) Error![]CellId`; `childrenCount(target_level: u8) Error!usize`. Target levels range from this cell's level through 30.
- Relations: `contains(CellId) Error!bool`, `intersects(CellId) Error!bool`, `range() Error![2]CellId` (inclusive minimum and maximum).
- Neighbors: `edgeNeighbors() Error![4]CellId` returns distinct ids; `vertexNeighbors(level: u8, out: []CellId)` and `allNeighbors(level: u8, out: []CellId)` return `Error![]CellId`; each has a matching `...Count(level: u8) Error!usize`. Vertex levels are below this cell's level and return 3–4 ids; all-neighbor levels run from this level through 30 and may repeat ids at face vertices.
- Conversions: `toLatLng() Error!LatLng`, `toPoint() Error!Point`, `sizeSt() Error!f64`, `boundUV() Error!BoundUV`.

### `Cell`

Field: `id: CellId`. `init(CellId) Cell`; `approxArea()`, `exactArea()` and `averageAreaAtLevel(u8)` return `Error!f64` (level 0..30); `center()` and `vertex(u8)` return `Error!Point` (`vertex` accepts 0..3); `boundUV()` returns `Error!BoundUV`; `containsPoint(Point)` returns `Error!bool`.

### `Cap`

Fields: `center: LatLng`, `radius_deg: f64`. `area() Error!f64`; `height() Error!f64`; `complement() Error!Cap`; `containsPoint(Point) Error!bool`.

### `LatLngRect`

Fields: `lat_lo_deg`, `lng_lo_deg`, `lat_hi_deg`, `lng_hi_deg: f64`. `fromBounds(f64, f64, f64, f64) LatLngRect`; `area() Error!f64`; `containsLatLng(LatLng) Error!bool`; `polarClosure() Error!LatLngRect`; `isInverted() Error!bool`; `isValid() Error!bool`.

### `Loop`

`init([]const [3]f64)`, `empty()` and `full()` return `Error!Loop`; `deinit(*Loop) void`. Read methods: `numVertices() Error!usize`, `vertex(usize) Error!Point`, `vertexLatLng(usize) Error!LatLng`, `area() Error!f64`, `signedArea() Error!f64`, `perimeterRad() Error!f64`, `containsPoint(Point) Error!bool`, `isNormalized() Error!bool`, `isEmpty() Error!bool`, `isFull() Error!bool`, `isValid() Error!bool`. Mutators: `normalize(*Loop) Error!void`, `invert(*Loop) Error!void`.

### `Polygon`

`init([]const [3]f64)` and `initLoops([]const [3]f64, []const usize)` return `Error!Polygon`; `empty()` and `full()` return `Error!Polygon`; `deinit(*Polygon) void`.
- Accessors: `numLoops() Error!usize`, `numVertices() Error!usize`, `loopNumVertices(usize) Error!usize`, `loopVertex(usize, usize) Error!Point`, `loopVertexLatLng(usize, usize) Error!LatLng`.
- Geometry: `area() Error!f64`, `containsPoint(Point) Error!bool`, `containsLatLng(LatLng) Error!bool`, `centroidLatLng() Error!LatLng`, `isEmpty() Error!bool`, `isFull() Error!bool`, `isValid() Error!bool`.
- `complement()`, `intersection(Polygon, Polygon)` and `unite(Polygon, Polygon)` return a new `Error!Polygon`; the boolean operations borrow their operands.

### `Coverer`

Fields: `min_level: u8 = 0`, `max_level: u8 = max_level`, `level_mod: u8 = 1`, `max_cells: u32 = 8`.
- `coveringCap(Cap, out: []CellId)`, `coveringRect(LatLngRect, out: []CellId)`, `coveringPolygon(Polygon, out: []CellId)` and `coveringCell(CellId, out: []CellId)` return `Error![]CellId`.
- Each covering method has a corresponding `...Count(region) Error!usize` method.

`Loop.init` and `Polygon.init` require at least three unit-length directions and a native-`int`-sized input. `Polygon.initLoops` also requires unit-length vertices, at least three per loop, matching loop sizes and a native-`int`-sized total.
Constructors preserve input orientation; `Loop.normalize` mutates its receiver. `Polygon.intersection` and `unite` borrow both operands, reject invalid polygons, and return a new owned polygon.

## Runtime loading

`LoadSource` is `.path` for an explicit absolute file path or `.system` for a library name without a path component. Empty sources, embedded NULs and requests over 32,768 bytes are rejected; there is no fallback. In a linked build, `load` panics; in a runtime-loaded build, it validates the provider before publishing the dispatch table.

```zig
if (comptime s2.runtime_loaded) {
    try s2.load(.{ .path = "/opt/s2geometry/lib/libs2bridge.so.0" });
}
```

A repeated request for the same provider is accepted; a different provider returns `ProviderMismatch`. Failed attempts can be retried by calling `load` again. The provider is retained for process lifetime; there is no unload. `loadedSource` returns the retained request, or `null` before loading and in linked builds.

`LoadError` is `EmptySource`, `SourceTooLong`, `InvalidSource`, `UnsupportedTarget`, `OpenFailed`, `MissingSymbol`, `ValidationFailed`, `ProviderMismatch` or `ReentrantLoad`. `wasm32-wasi` has no dynamic loader and reports `UnsupportedTarget`.