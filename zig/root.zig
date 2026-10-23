// SPDX-License-Identifier: Apache-2.0

//! Zig facade over upstream S2 C++ through this fork's translated bridge.
//!
//! Import `s2geometry`; linked mode is default. `-Druntime=true` requires `load`;
//! `-fsys=s2` uses installed S2 and Abseil.
//!
//! Runtime providers must export this bridge's 93 `s2br_*` symbols. Runtime loading
//! is unavailable on WASI, Emscripten and freestanding targets.
//!
//! Value types and output buffers are caller-owned. `Loop` and `Polygon` own
//! C++ handles; call `deinit` once, never copy ownership, and use each on one thread.
//!
//! List fills use a count-then-fill pattern. Short buffers return `BufferTooSmall` without writes;
//! invalid inputs return `InvalidArgument`.
//!
//! The package targets Zig 0.16.0.

const std = @import("std");

const rt = @import("rt");

/// True when native symbols are resolved at run time rather than linked.
/// This comptime constant lets consumers select the matching initialization path.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Selects an explicit library path or system name; no fallback is attempted.
/// Failed requests return a `LoadError`.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Errors returned while resolving the native library.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Loads the native provider once; matching concurrent requests share success until process exit.
/// Linked builds panic; mismatches/reentrant calls fail, and failed requests may be retried.
pub fn load(source: LoadSource) LoadError!void {
    if (comptime !runtime_loaded) {
        std.debug.panic(
            "s2geometry: load was called on a linked build; this module is not " ++
                "runtime-loaded, so there is no library to load. Build with " ++
                "runtime loading configured, or do not call load.",
            .{},
        );
    }
    return c.load(source);
}

/// Returns the retained request, or null before loading and in linked builds.
pub fn loadedSource() ?LoadSource {
    if (comptime !runtime_loaded) return null;
    return c.loadedSource();
}

/// Translated fork bridge surface. Direct calls bypass this facade's checks,
/// buffer and ownership contracts, and error mapping.
pub const c = @import("c");

/// Errors for invalid inputs, short buffers, allocation failures, and bridge errors.
/// Polygon operations may return `Internal` when upstream reports an unexpected failure.
pub const Error = error{
    InvalidArgument,
    BufferTooSmall,
    OutOfMemory,
    Internal,
};

/// Maps bridge status values; unknown nonzero statuses become `Internal`.
fn check(status: c.S2BridgeStatus) Error!void {
    switch (status) {
        c.S2BRIDGE_OK => {},
        c.S2BRIDGE_INVALID_ARGUMENT => return error.InvalidArgument,
        c.S2BRIDGE_BUFFER_TOO_SMALL => return error.BufferTooSmall,
        c.S2BRIDGE_OUT_OF_MEMORY => return error.OutOfMemory,
        c.S2BRIDGE_INTERNAL_ERROR => return error.Internal,
        else => return error.Internal,
    }
}

fn asBool(value: c_int) bool {
    return value != 0;
}

/// Rejects a `usize` index that cannot fit upstream's `int` parameter.
/// Such indices return `InvalidArgument` rather than narrowing.
fn asIndex(i: usize) Error!c_int {
    if (i > @as(usize, @intCast(std.math.maxInt(c_int)))) return error.InvalidArgument;
    return @intCast(i);
}

/// Returns the caller-buffer prefix written by the bridge or `BufferTooSmall`.
fn filled(out: []CellId, written: usize) Error![]CellId {
    if (written > out.len) return error.BufferTooSmall;
    return out[0..written];
}

/// Largest valid S2 cell level (`S2CellId::kMaxLevel`, `s2/s2cell_id.h:99-100`).
pub const max_level: u8 = @intCast(c.S2BRIDGE_MAX_LEVEL);

/// Number of cube faces in S2.
pub const num_faces: u8 = 6;

/// A unit-sphere direction in x, y, z order; owns no storage.
/// Methods report bridge errors through `Error`.
pub const Point = struct {
    x: f64,
    y: f64,
    z: f64,

    /// Returns a normalized copy; bridge failures are reported as `Error`.
    pub fn normalized(self: Point) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_point_normalized(self.x, self.y, self.z, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// Converts this direction to latitude/longitude in degrees.
    /// Upstream accepts non-unit vectors (`s2/s2latlng.h:60-61`).
    pub fn toLatLng(self: Point) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_lat_lng_from_point(self.x, self.y, self.z, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }
};

/// Latitude/longitude pair in degrees; owns no storage.
/// Values are not normalized or validated until a method checks them.
pub const LatLng = struct {
    lat_deg: f64,
    lng_deg: f64,

    /// Constructs a degree-valued pair without normalization or validation.
    pub fn fromDegrees(lat_deg: f64, lng_deg: f64) LatLng {
        return .{ .lat_deg = lat_deg, .lng_deg = lng_deg };
    }

    /// Converts radians to degrees.
    pub fn fromRadians(lat_rad: f64, lng_rad: f64) LatLng {
        return .{
            .lat_deg = lat_rad * (180.0 / std.math.pi),
            .lng_deg = lng_rad * (180.0 / std.math.pi),
        };
    }

    /// Tests upstream's latitude and longitude bounds (`s2/s2latlng.h:101`).
    pub fn isValid(self: LatLng) bool {
        var out: c_int = 0;
        check(c.s2br_latlng_is_valid_deg(self.lat_deg, self.lng_deg, &out)) catch {
            return false;
        };
        return asBool(out);
    }

    /// Clamps latitude and wraps longitude into [-180, 180] degrees.
    pub fn normalized(self: LatLng) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_latlng_normalized_deg(self.lat_deg, self.lng_deg, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// Converts finite coordinates to a unit direction.
    /// Non-finite coordinates return `InvalidArgument`.
    pub fn toPoint(self: LatLng) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_point_from_lat_lng_deg(self.lat_deg, self.lng_deg, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// Returns surface distance in degrees; finite inputs are required but not normalized.
    /// The Haversine form is faster and slightly less accurate above 180°.
    pub fn distanceDeg(self: LatLng, other: LatLng) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_lat_lng_distance_deg(
            self.lat_deg,
            self.lng_deg,
            other.lat_deg,
            other.lng_deg,
            &out,
        ));
        return out;
    }
};

/// A closed rectangle in cube-face (u,v) coordinates; owns no storage.
pub const BoundUV = struct {
    u_lo: f64,
    u_hi: f64,
    v_lo: f64,
    v_hi: f64,
};

/// A 64-bit S2 cell id; owns no storage, and invalid ids remain representable.
/// Methods requiring a real cell return `InvalidArgument`; raw is upstream's integer (`s2/s2cell_id.h:242-243`).
pub const CellId = struct {
    /// Upstream's raw 64-bit id; any value is representable without validation.
    raw: u64,

    /// Invalid id `S2CellId::None()` (`s2/s2cell_id.h:127-128`).
    pub const none: CellId = .{ .raw = 0 };

    /// Invalid id `S2CellId::Sentinel()` (`s2/s2cell_id.h:131-132`).
    pub const sentinel: CellId = .{ .raw = 0xffff_ffff_ffff_ffff };

    /// Returns the leaf containing a finite coordinate; input need not be normalized.
    /// Non-finite coordinates return `InvalidArgument`.
    pub fn fromLatLng(point: LatLng) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_lat_lng_deg(point.lat_deg, point.lng_deg, &out));
        return .{ .raw = out };
    }

    /// Returns the leaf containing a direction; unit length is not required.
    pub fn fromPoint(point: Point) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_point(point.x, point.y, point.z, &out));
        return .{ .raw = out };
    }

    /// Returns a face cell for indices 0..5; 6 and 7 produce invalid ids.
    /// Indices above 7 return `InvalidArgument`.
    pub fn fromFace(face_index: u8) Error!CellId {
        if (face_index > 7) return error.InvalidArgument;
        var out: u64 = undefined;
        try check(c.s2br_cell_from_face(@intCast(face_index), &out));
        return .{ .raw = out };
    }

    /// Builds a cell from face, Hilbert position, and level.
    /// Invalid face/level or a position wider than 61 bits returns `InvalidArgument`.
    pub fn fromFacePosLevel(face_index: u8, hilbert_pos: u64, target_level: u8) Error!CellId {
        if (face_index > 5) return error.InvalidArgument;
        if (target_level > max_level) return error.InvalidArgument;
        var out: u64 = undefined;
        try check(c.s2br_cell_from_face_pos_level(
            @intCast(face_index),
            hilbert_pos,
            @intCast(target_level),
            &out,
        ));
        return .{ .raw = out };
    }

    /// Builds a cell from face 0..5 and center-grid indices `i`,`j` below 2^30; invalid values return `InvalidArgument`.
    pub fn fromFaceIJ(face_index: u8, i: u32, j: u32) Error!CellId {
        if (face_index > 5) return error.InvalidArgument;
        const limit: u32 = (@as(u32, 1) << max_level) - 1;
        if (i > limit or j > limit) return error.InvalidArgument;
        var out: u64 = undefined;
        try check(c.s2br_cell_from_face_ij(
            @intCast(face_index),
            @intCast(i),
            @intCast(j),
            &out,
        ));
        return .{ .raw = out };
    }

    /// Parses an S2 token; malformed tokens return `InvalidArgument`, not `none`.
    pub fn fromToken(token: []const u8) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_token(token.ptr, token.len, &out));
        return .{ .raw = out };
    }

    /// Parses upstream's debug spelling; malformed text returns `InvalidArgument`.
    pub fn fromDebugString(text: []const u8) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_debug_string(text.ptr, text.len, &out));
        return .{ .raw = out };
    }

    /// Writes the token into `buf` and returns a slice borrowing that buffer.
    /// At least 17 bytes are needed; short buffers return `BufferTooSmall` unchanged.
    pub fn toToken(self: CellId, buf: []u8) Error![]const u8 {
        var needed: usize = undefined;
        try check(c.s2br_cell_to_token(self.raw, buf.ptr, buf.len, &needed));
        if (buf.len <= needed) return error.BufferTooSmall;
        return buf[0..needed];
    }

    /// Writes the debug spelling into `buf` and returns a slice borrowing it.
    /// A short buffer returns `BufferTooSmall` without writing.
    pub fn toDebugString(self: CellId, buf: []u8) Error![]const u8 {
        var needed: usize = undefined;
        try check(c.s2br_cell_to_debug_string(self.raw, buf.ptr, buf.len, &needed));
        if (buf.len <= needed) return error.BufferTooSmall;
        return buf[0..needed];
    }

    /// Tests whether the raw value names a valid cell.
    pub fn isValid(self: CellId) bool {
        return asBool(c.s2br_cell_is_valid(self.raw));
    }

    /// Returns the cell level; an invalid id returns `InvalidArgument`.
    pub fn level(self: CellId) Error!u8 {
        var out: c_int = undefined;
        try check(c.s2br_cell_level(self.raw, &out));
        return @intCast(out);
    }

    /// Returns the face index (0..5); invalid ids return `InvalidArgument`.
    pub fn face(self: CellId) Error!u8 {
        var out: c_int = undefined;
        try check(c.s2br_cell_face(self.raw, &out));
        return @intCast(out);
    }

    /// Returns the cell's Hilbert position; invalid ids return `InvalidArgument`.
    pub fn pos(self: CellId) Error!u64 {
        var out: u64 = undefined;
        try check(c.s2br_cell_pos(self.raw, &out));
        return out;
    }

    /// Tests whether this is a leaf cell.
    pub fn isLeaf(self: CellId) bool {
        return asBool(c.s2br_cell_is_leaf(self.raw));
    }

    /// Tests whether this is one of the six face cells.
    pub fn isFace(self: CellId) bool {
        return asBool(c.s2br_cell_is_face(self.raw));
    }

    /// Returns the ancestor at `target_level`, or the immediate parent when null.
    /// Levels above this cell or a level-0 immediate parent return `InvalidArgument`.
    pub fn parent(self: CellId, target_level: ?u8) Error!CellId {
        const target: u8 = if (target_level) |l| l else blk: {
            const here = try self.level();
            // A level-0 cell has no parent in upstream's documented range.
            // Reject it rather than underflowing the immediate-parent level.
            if (here == 0) return error.InvalidArgument;
            break :blk here - 1;
        };
        var out: u64 = undefined;
        try check(c.s2br_cell_parent(self.raw, @intCast(target), &out));
        return .{ .raw = out };
    }

    /// Returns child position 0..3; leaves and invalid positions return `InvalidArgument`.
    pub fn child(self: CellId, position: u8) Error!CellId {
        if (position > 3) return error.InvalidArgument;
        var out: u64 = undefined;
        try check(c.s2br_cell_child(self.raw, @intCast(position), &out));
        return .{ .raw = out };
    }

    /// Fills `out` with target-level descendants and returns a slice borrowing it.
    /// Target levels must be in [this cell's level, `max_level`]; short buffers return `BufferTooSmall`.
    pub fn children(self: CellId, target_level: u8, out: []CellId) Error![]CellId {
        var written: usize = 0;
        try check(c.s2br_cell_children(
            self.raw,
            @intCast(target_level),
            @ptrCast(out.ptr),
            out.len,
            &written,
        ));
        return filled(out, written);
    }

    /// Returns the descendant count; invalid levels or counts that exceed `usize` return `InvalidArgument`.
    pub fn childrenCount(self: CellId, target_level: u8) Error!usize {
        var required: usize = undefined;
        try check(c.s2br_cell_children(
            self.raw,
            @intCast(target_level),
            null,
            0,
            &required,
        ));
        return required;
    }

    /// Returns the next cell at this level along the Hilbert curve; it does not wrap.
    pub fn next(self: CellId) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_next(self.raw, &out));
        return .{ .raw = out };
    }

    /// Returns the previous cell at this level; it does not wrap.
    pub fn prev(self: CellId) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_prev(self.raw, &out));
        return .{ .raw = out };
    }

    /// Tests cell containment; both ids must be valid or the call returns `InvalidArgument`.
    pub fn contains(self: CellId, other: CellId) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cell_contains(self.raw, other.raw, &out));
        return asBool(out);
    }

    /// Tests cell intersection; both ids must be valid or the call returns `InvalidArgument`.
    pub fn intersects(self: CellId, other: CellId) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cell_intersects(self.raw, other.raw, &out));
        return asBool(out);
    }

    /// Returns the inclusive minimum and maximum id range for this cell.
    pub fn range(self: CellId) Error![2]CellId {
        var lo: u64 = undefined;
        var hi: u64 = undefined;
        try check(c.s2br_cell_range(self.raw, &lo, &hi));
        return .{ .{ .raw = lo }, .{ .raw = hi } };
    }

    /// Returns the four distinct edge neighbors.
    pub fn edgeNeighbors(self: CellId) Error![4]CellId {
        var ids: [4]u64 = undefined;
        try check(c.s2br_cell_edge_neighbors(self.raw, &ids));
        return .{
            .{ .raw = ids[0] },
            .{ .raw = ids[1] },
            .{ .raw = ids[2] },
            .{ .raw = ids[3] },
        };
    }

    /// Fills `out` with 3–4 vertex neighbors and returns a slice borrowing it.
    /// `target_level` must be below this cell's level; short buffers return `BufferTooSmall`.
    pub fn vertexNeighbors(self: CellId, target_level: u8, out: []CellId) Error![]CellId {
        var written: usize = 0;
        try check(c.s2br_cell_vertex_neighbors(
            self.raw,
            @intCast(target_level),
            @ptrCast(out.ptr),
            out.len,
            &written,
        ));
        return filled(out, written);
    }

    /// Returns the 3–4 vertex-neighbor count; invalid ids or levels return `InvalidArgument`.
    pub fn vertexNeighborsCount(self: CellId, target_level: u8) Error!usize {
        var required: usize = undefined;
        try check(c.s2br_cell_vertex_neighbors(
            self.raw,
            @intCast(target_level),
            null,
            0,
            &required,
        ));
        return required;
    }

    /// Fills `out` with upstream's all-neighbor list, retaining duplicates, and returns a borrowed slice.
    /// Target level is inclusive through `max_level`; short buffers return `BufferTooSmall`.
    pub fn allNeighbors(self: CellId, target_level: u8, out: []CellId) Error![]CellId {
        var written: usize = 0;
        try check(c.s2br_cell_all_neighbors(
            self.raw,
            @intCast(target_level),
            @ptrCast(out.ptr),
            out.len,
            &written,
        ));
        return filled(out, written);
    }

    /// Returns the upstream neighbor-list length; upstream builds the list to count it.
    pub fn allNeighborsCount(self: CellId, target_level: u8) Error!usize {
        var required: usize = undefined;
        try check(c.s2br_cell_all_neighbors(
            self.raw,
            @intCast(target_level),
            null,
            0,
            &required,
        ));
        return required;
    }

    /// Returns the cell centre as latitude/longitude in degrees.
    pub fn toLatLng(self: CellId) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_cell_to_lat_lng_deg(self.raw, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// Returns the cell centre as a unit direction.
    pub fn toPoint(self: CellId) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_cell_to_point(self.raw, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// Returns the cell edge length in (s,t) projection-space units.
    pub fn sizeSt(self: CellId) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_cell_size_st(self.raw, &out));
        return out;
    }

    /// Returns the cell bounds in its face's (u,v) coordinates.
    pub fn boundUV(self: CellId) Error!BoundUV {
        var uv: [4]f64 = undefined;
        try check(c.s2br_cell_bound_uv(self.raw, &uv));
        return .{ .u_lo = uv[0], .u_hi = uv[1], .v_lo = uv[2], .v_hi = uv[3] };
    }
};

/// Region view of a `CellId`; owns no storage, and invalid ids are representable.
/// Methods that require a valid id return `InvalidArgument`.
pub const Cell = struct {
    /// Cell identifier; assigning it does not validate the id.
    id: CellId,

    /// Wraps the id without validation or allocation.
    pub fn init(id: CellId) Cell {
        return .{ .id = id };
    }

    /// Returns approximate area in steradians (≤3% error; ≤0.1% from level 5).
    pub fn approxArea(self: Cell) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_cell_approx_area(self.id.raw, &out));
        return out;
    }

    /// Returns cell area in steradians; upstream accuracy is about six digits even for leaves.
    pub fn exactArea(self: Cell) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_cell_exact_area(self.id.raw, &out));
        return out;
    }

    /// Returns mean cell area in steradians; levels above `max_level` return `InvalidArgument`.
    pub fn averageAreaAtLevel(level: u8) Error!f64 {
        if (level > max_level) return error.InvalidArgument;
        var out: f64 = undefined;
        try check(c.s2br_cell_average_area(@intCast(level), &out));
        return out;
    }

    /// Returns upstream's cell centre, the point that divides the cell into four children.
    pub fn center(self: Cell) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_cell_center(self.id.raw, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// Returns corner 0..3 counter-clockwise from the lower-left; invalid indices return `InvalidArgument`.
    pub fn vertex(self: Cell, k: u8) Error!Point {
        if (k > 3) return error.InvalidArgument;
        var xyz: [3]f64 = undefined;
        try check(c.s2br_cell_vertex(self.id.raw, @intCast(k), &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// Returns the cell bounds in face (u,v) coordinates.
    pub fn boundUV(self: Cell) Error!BoundUV {
        var uv: [4]f64 = undefined;
        try check(c.s2br_cell_bound_uv_of_cell(self.id.raw, &uv));
        return .{ .u_lo = uv[0], .u_hi = uv[1], .v_lo = uv[2], .v_hi = uv[3] };
    }

    /// Tests closed-cell containment; shared-boundary points belong to each touching cell.
    /// Non-unit directions are accepted (`s2/s2cell.h:307-308`).
    pub fn containsPoint(self: Cell, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cell_contains_point(self.id.raw, point.x, point.y, point.z, &out));
        return asBool(out);
    }
};

/// A spherical cap centered at `center` with angular radius in degrees; owns no storage.
/// Upstream clamps radii at 180°; larger radii also describe the full sphere.
pub const Cap = struct {
    /// Centre as latitude/longitude; not normalized.
    center: LatLng,
    /// Radius in degrees; upstream clamps at 180° (zero is empty).
    radius_deg: f64,

    /// Returns cap area in steradians.
    pub fn area(self: Cap) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_cap_area_deg(
            self.center.lat_deg,
            self.center.lng_deg,
            self.radius_deg,
            &out,
        ));
        return out;
    }

    /// Returns the distance from the centre to the cutting plane in sphere-radius units.
    pub fn height(self: Cap) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_cap_height(
            self.center.lat_deg,
            self.center.lng_deg,
            self.radius_deg,
            &out,
        ));
        return out;
    }

    /// Returns the complementary cap; empty and full radii become 180° and 0°.
    pub fn complement(self: Cap) Error!Cap {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        var radius: f64 = undefined;
        try check(c.s2br_cap_complement_deg(
            self.center.lat_deg,
            self.center.lng_deg,
            self.radius_deg,
            &lat,
            &lng,
            &radius,
        ));
        return .{
            .center = .{ .lat_deg = lat, .lng_deg = lng },
            .radius_deg = radius,
        };
    }

    /// Tests containment; `point` must be finite and unit length or the call returns `InvalidArgument`.
    pub fn containsPoint(self: Cap, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cap_contains_point(
            self.center.lat_deg,
            self.center.lng_deg,
            self.radius_deg,
            point.x,
            point.y,
            point.z,
            &out,
        ));
        return asBool(out);
    }
};

/// Latitude/longitude bounds in degrees; owns no storage.
/// Inverted longitude bounds cross the antimeridian; methods reject non-finite coordinates.
pub const LatLngRect = struct {
    lat_lo_deg: f64,
    lng_lo_deg: f64,
    lat_hi_deg: f64,
    lng_hi_deg: f64,

    /// Stores inclusive lower/upper bounds as supplied; no validation or normalization occurs.
    /// Use `isValid` to check upstream's bounds rules.
    pub fn fromBounds(
        lat_lo_deg: f64,
        lng_lo_deg: f64,
        lat_hi_deg: f64,
        lng_hi_deg: f64,
    ) LatLngRect {
        return .{
            .lat_lo_deg = lat_lo_deg,
            .lng_lo_deg = lng_lo_deg,
            .lat_hi_deg = lat_hi_deg,
            .lng_hi_deg = lng_hi_deg,
        };
    }

    /// Returns rectangle area in steradians on the unit sphere.
    pub fn area(self: LatLngRect) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_rect_area_deg(
            self.lat_lo_deg,
            self.lng_lo_deg,
            self.lat_hi_deg,
            self.lng_hi_deg,
            &out,
        ));
        return out;
    }

    /// Tests inclusive containment; pass finite, normalized coordinates.
    /// The method does not normalize its argument.
    pub fn containsLatLng(self: LatLngRect, point: LatLng) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_rect_contains_lat_lng_deg(
            self.lat_lo_deg,
            self.lng_lo_deg,
            self.lat_hi_deg,
            self.lng_hi_deg,
            point.lat_deg,
            point.lng_deg,
            &out,
        ));
        return asBool(out);
    }

    /// Widens a rectangle touching a pole to include every longitude; otherwise unchanged.
    pub fn polarClosure(self: LatLngRect) Error!LatLngRect {
        var bounds: [4]f64 = undefined;
        try check(c.s2br_rect_polar_closure_deg(
            self.lat_lo_deg,
            self.lng_lo_deg,
            self.lat_hi_deg,
            self.lng_hi_deg,
            &bounds,
        ));
        return .{
            .lat_lo_deg = bounds[0],
            .lng_lo_deg = bounds[1],
            .lat_hi_deg = bounds[2],
            .lng_hi_deg = bounds[3],
        };
    }

    /// Tests whether the longitude bounds cross the 180° line.
    pub fn isInverted(self: LatLngRect) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_rect_is_inverted_deg(
            self.lat_lo_deg,
            self.lng_lo_deg,
            self.lat_hi_deg,
            self.lng_hi_deg,
            &out,
        ));
        return asBool(out);
    }

    /// Tests upstream's coordinate bounds and empty-interval rules.
    pub fn isValid(self: LatLngRect) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_rect_is_valid_deg(
            self.lat_lo_deg,
            self.lng_lo_deg,
            self.lat_hi_deg,
            self.lng_hi_deg,
            &out,
        ));
        return asBool(out);
    }
};

/// An S2 loop whose interior lies left of its vertex chain (`s2/s2loop.h:262-264`).
/// Owns one C++ object; never copy ownership, and call `deinit` exactly once.
pub const Loop = struct {
    /// Opaque owned C++ handle; do not replace it directly.
    handle: ?*c.S2BridgeLoop,

    /// Creates an owned loop from borrowed vertices; upstream copies the input.
    /// Requires 3+ unit directions and an `int`-sized count; invalid input returns `InvalidArgument`.
    pub fn init(vertices: []const [3]f64) Error!Loop {
        if (vertices.len < 3) return error.InvalidArgument;
        var out: ?*c.S2BridgeLoop = null;
        try check(c.s2br_loop_create(@ptrCast(vertices.ptr), vertices.len, &out));
        return .{ .handle = out.? };
    }

    /// Creates an owned empty loop; call `deinit` to release it.
    pub fn empty() Error!Loop {
        var out: ?*c.S2BridgeLoop = null;
        try check(c.s2br_loop_create_empty(&out));
        return .{ .handle = out.? };
    }

    /// Creates an owned full-sphere loop; call `deinit` to release it.
    pub fn full() Error!Loop {
        var out: ?*c.S2BridgeLoop = null;
        try check(c.s2br_loop_create_full(&out));
        return .{ .handle = out.? };
    }

    /// Frees this loop's C++ storage; call once and never on a non-owning copy.
    pub fn deinit(self: *Loop) void {
        c.s2br_loop_destroy(self.handle);
        self.* = undefined;
    }

    /// Returns the number of loop vertices.
    pub fn numVertices(self: Loop) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_loop_num_vertices(self.handle, &out));
        return @intCast(out);
    }

    /// Returns vertex `i`; only indices below `numVertices` are valid.
    /// Out-of-range indices return `InvalidArgument`.
    pub fn vertex(self: Loop, i: usize) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_loop_vertex(self.handle, try asIndex(i), &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// Returns vertex `i` as latitude/longitude in degrees; uses `vertex`'s index rules.
    pub fn vertexLatLng(self: Loop, i: usize) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_loop_vertex_lat_lng_deg(self.handle, try asIndex(i), &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// Returns unsigned loop area in steradians (0..4π); upstream allocation may return `OutOfMemory`.
    pub fn area(self: Loop) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_loop_area(self.handle, &out));
        return out;
    }

    /// Returns signed loop area in steradians; negative means the interior exceeds a hemisphere.
    pub fn signedArea(self: Loop) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_loop_signed_area(self.handle, &out));
        return out;
    }

    /// Returns loop perimeter in radians.
    pub fn perimeterRad(self: Loop) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_loop_perimeter_rad(self.handle, &out));
        return out;
    }

    /// Tests containment of a finite direction; unit length is not required.
    /// Upstream allocation may return `OutOfMemory`.
    pub fn containsPoint(self: Loop, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_contains_point(self.handle, point.x, point.y, point.z, &out));
        return asBool(out);
    }

    /// Tests whether the enclosed area is at most 2π.
    pub fn isNormalized(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_normalized(self.handle, &out));
        return asBool(out);
    }

    /// Normalizes this loop in place so its enclosed area is at most 2π.
    pub fn normalize(self: *Loop) Error!void {
        try check(c.s2br_loop_normalize(self.handle));
    }

    /// Inverts this loop in place.
    pub fn invert(self: *Loop) Error!void {
        try check(c.s2br_loop_invert(self.handle));
    }

    /// Tests whether this loop is empty.
    pub fn isEmpty(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_empty(self.handle, &out));
        return asBool(out);
    }

    /// Tests whether this loop is full.
    pub fn isFull(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_full(self.handle, &out));
        return asBool(out);
    }

    /// Checks loop validity, including self-intersection and repeated vertices.
    /// Invalid-loop diagnostics may allocate and return `OutOfMemory`.
    pub fn isValid(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_valid(self.handle, &out));
        return asBool(out);
    }
};

/// A polygon of nested loops whose interior has odd nesting depth (`s2/s2polygon.h:172-183`).
/// Owns one C++ object; never copy ownership, and call `deinit` exactly once.
pub const Polygon = struct {
    /// Opaque owned C++ handle; do not replace it directly.
    handle: ?*c.S2BridgePolygon,

    /// Creates an owned polygon from borrowed shell vertices; upstream copies them.
    /// Requires 3+ unit directions and an `int`-sized count; invalid input returns `InvalidArgument`.
    pub fn init(vertices: []const [3]f64) Error!Polygon {
        if (vertices.len < 3) return error.InvalidArgument;
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_create(@ptrCast(vertices.ptr), vertices.len, &out));
        return .{ .handle = out.? };
    }

    /// Creates an owned polygon from borrowed vertices and loop sizes; upstream derives nesting.
    /// Empty/mismatched sizes, non-unit vertices, or counts above native `int` return `InvalidArgument`.
    pub fn initLoops(vertices: []const [3]f64, loop_sizes: []const usize) Error!Polygon {
        if (loop_sizes.len == 0) return error.InvalidArgument;
        var total: usize = 0;
        for (loop_sizes) |size| {
            if (size < 3) return error.InvalidArgument;
            // Reject overflowing lengths as invalid input before summing.
            if (size > std.math.maxInt(usize) - total) return error.InvalidArgument;
            total += size;
        }
        if (total != vertices.len) return error.InvalidArgument;
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_create_loops(
            @ptrCast(vertices.ptr),
            loop_sizes.ptr,
            loop_sizes.len,
            &out,
        ));
        return .{ .handle = out.? };
    }

    /// Creates an owned empty polygon; call `deinit` to release it.
    pub fn empty() Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_create_empty(&out));
        return .{ .handle = out.? };
    }

    /// Creates an owned full-sphere polygon; call `deinit` to release it.
    pub fn full() Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_create_full(&out));
        return .{ .handle = out.? };
    }

    /// Frees this polygon's C++ storage; call once and never on a non-owning copy.
    pub fn deinit(self: *Polygon) void {
        c.s2br_polygon_destroy(self.handle);
        self.* = undefined;
    }

    /// Returns the number of loops.
    pub fn numLoops(self: Polygon) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_polygon_num_loops(self.handle, &out));
        return @intCast(out);
    }

    /// Returns the total number of vertices across all loops.
    pub fn numVertices(self: Polygon) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_polygon_num_vertices(self.handle, &out));
        return @intCast(out);
    }

    /// Returns the vertex count for `loop_index`; out-of-range indices return `InvalidArgument`.
    pub fn loopNumVertices(self: Polygon, loop_index: usize) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_polygon_loop_num_vertices(self.handle, try asIndex(loop_index), &out));
        return @intCast(out);
    }

    /// Returns a vertex in upstream's nesting preorder, not input order.
    /// Both indices are checked; out-of-range indices return `InvalidArgument`.
    pub fn loopVertex(self: Polygon, loop_index: usize, vertex_index: usize) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_polygon_loop_vertex(
            self.handle,
            try asIndex(loop_index),
            try asIndex(vertex_index),
            &xyz,
        ));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// Returns a loop vertex as latitude/longitude in degrees; uses `loopVertex`'s index rules.
    pub fn loopVertexLatLng(
        self: Polygon,
        loop_index: usize,
        vertex_index: usize,
    ) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_polygon_loop_vertex_lat_lng_deg(
            self.handle,
            try asIndex(loop_index),
            try asIndex(vertex_index),
            &lat,
            &lng,
        ));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// Returns polygon area in steradians, with holes subtracted.
    pub fn area(self: Polygon) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_polygon_area(self.handle, &out));
        return out;
    }

    /// Tests containment of a finite unit direction.
    /// Creating the upstream shape index may return `OutOfMemory`.
    pub fn containsPoint(self: Polygon, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_contains_point(self.handle, point.x, point.y, point.z, &out));
        return asBool(out);
    }

    /// Tests containment after converting finite latitude/longitude to a direction.
    pub fn containsLatLng(self: Polygon, point: LatLng) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_contains_lat_lng_deg(
            self.handle,
            point.lat_deg,
            point.lng_deg,
            &out,
        ));
        return asBool(out);
    }

    /// Returns the centroid in normalized degrees; it may lie outside the polygon.
    pub fn centroidLatLng(self: Polygon) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_polygon_centroid_lat_lng_deg(self.handle, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// Tests whether this polygon is empty.
    pub fn isEmpty(self: Polygon) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_is_empty(self.handle, &out));
        return asBool(out);
    }

    /// Tests whether this polygon is full.
    pub fn isFull(self: Polygon) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_is_full(self.handle, &out));
        return asBool(out);
    }

    /// Checks polygon and loop validity.
    /// Invalid-polygon diagnostics may allocate and return `OutOfMemory`.
    pub fn isValid(self: Polygon) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_is_valid(self.handle, &out));
        return asBool(out);
    }

    /// Returns a new owned complement; leaves `self` unchanged and may return `OutOfMemory`.
    pub fn complement(self: Polygon) Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_complement(self.handle, &out));
        return .{ .handle = out.? };
    }

    /// Returns a new owned intersection; inputs stay caller-owned and must be valid.
    /// Invalid operands return `InvalidArgument`; upstream failures return `Internal` without a partial result.
    pub fn intersection(a: Polygon, b: Polygon) Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_intersection(a.handle, b.handle, &out));
        return .{ .handle = out.? };
    }

    /// Returns a new owned union; inputs stay caller-owned and must be valid.
    /// Invalid operands return `InvalidArgument`; upstream failures return `Internal`.
    pub fn unite(a: Polygon, b: Polygon) Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_union(a.handle, b.handle, &out));
        return .{ .handle = out.? };
    }
};

/// S2 region-covering options; the value owns no storage and reads fields per call.
/// Invalid levels, `level_mod`, or `max_cells` return `InvalidArgument`.
pub const Coverer = struct {
    /// Minimum returned level (0..`max_level`).
    min_level: u8 = 0,
    /// Maximum returned level (0..30).
    max_level: u8 = max_level,
    /// Level spacing, 1..3; other values return `InvalidArgument`.
    level_mod: u8 = 1,
    /// Desired maximum cell count; upstream may exceed it to satisfy `min_level`.
    max_cells: u32 = 8,

    fn options(self: Coverer) Error!c.S2BridgeCovererOptions {
        if (self.min_level > self.max_level) return error.InvalidArgument;
        if (self.max_level > max_level) return error.InvalidArgument;
        if (self.level_mod < 1 or self.level_mod > 3) return error.InvalidArgument;
        if (self.max_cells < 1) return error.InvalidArgument;
        // `max_cells` crosses the bridge as `int32_t`; reject wider `u32` values before casting.
        if (self.max_cells > @as(u32, @intCast(std.math.maxInt(c_int))))
            return error.InvalidArgument;
        return .{
            .min_level = @intCast(self.min_level),
            .max_level = @intCast(self.max_level),
            .level_mod = @intCast(self.level_mod),
            .max_cells = @intCast(self.max_cells),
        };
    }

    /// Covers a finite cap into `out`; the result borrows the buffer.
    /// Short buffers return `BufferTooSmall`; upstream covering results are version-unstable (`s2/s2region_coverer.h:60-62`).
    pub fn coveringCap(self: Coverer, cap: Cap, out: []CellId) Error![]CellId {
        var written: usize = undefined;
        const native_options = try self.options();
        try check(c.s2br_coverer_covering_cap(
            cap.center.lat_deg,
            cap.center.lng_deg,
            cap.radius_deg,
            &native_options,
            @ptrCast(out.ptr),
            out.len,
            &written,
        ));
        return filled(out, written);
    }

    /// Runs the coverer and returns its count; upstream builds and discards the list.
    /// Invalid inputs return `InvalidArgument`; allocation may return `OutOfMemory`.
    pub fn coveringCapCount(self: Coverer, cap: Cap) Error!usize {
        var required: usize = undefined;
        const native_options = try self.options();
        try check(c.s2br_coverer_covering_cap(
            cap.center.lat_deg,
            cap.center.lng_deg,
            cap.radius_deg,
            &native_options,
            null,
            0,
            &required,
        ));
        return required;
    }

    /// Covers a finite rectangle into `out`; the result borrows the buffer.
    /// Short buffers return `BufferTooSmall`; results follow `coveringCap`'s stability rule.
    pub fn coveringRect(self: Coverer, rect: LatLngRect, out: []CellId) Error![]CellId {
        var written: usize = undefined;
        const native_options = try self.options();
        try check(c.s2br_coverer_covering_rect(
            rect.lat_lo_deg,
            rect.lng_lo_deg,
            rect.lat_hi_deg,
            rect.lng_hi_deg,
            &native_options,
            @ptrCast(out.ptr),
            out.len,
            &written,
        ));
        return filled(out, written);
    }

    /// Runs the rectangle coverer and builds its list to return the count.
    pub fn coveringRectCount(self: Coverer, rect: LatLngRect) Error!usize {
        var required: usize = undefined;
        const native_options = try self.options();
        try check(c.s2br_coverer_covering_rect(
            rect.lat_lo_deg,
            rect.lng_lo_deg,
            rect.lat_hi_deg,
            rect.lng_hi_deg,
            &native_options,
            null,
            0,
            &required,
        ));
        return required;
    }

    /// Covers the caller-owned polygon into `out`; the result borrows the buffer.
    /// Short buffers return `BufferTooSmall`; results follow `coveringCap`'s stability rule.
    pub fn coveringPolygon(self: Coverer, polygon: Polygon, out: []CellId) Error![]CellId {
        var written: usize = undefined;
        const native_options = try self.options();
        try check(c.s2br_coverer_covering_polygon(
            polygon.handle,
            &native_options,
            @ptrCast(out.ptr),
            out.len,
            &written,
        ));
        return filled(out, written);
    }

    /// Runs the polygon coverer and builds its list to return the count; the polygon stays caller-owned.
    pub fn coveringPolygonCount(self: Coverer, polygon: Polygon) Error!usize {
        var required: usize = undefined;
        const native_options = try self.options();
        try check(c.s2br_coverer_covering_polygon(
            polygon.handle,
            &native_options,
            null,
            0,
            &required,
        ));
        return required;
    }

    /// Covers a valid cell into `out`; the result borrows the buffer.
    /// Short buffers return `BufferTooSmall`; upstream's cell covering is exactly that cell.
    pub fn coveringCell(self: Coverer, cell: CellId, out: []CellId) Error![]CellId {
        var written: usize = undefined;
        const native_options = try self.options();
        try check(c.s2br_coverer_covering_cell(
            cell.raw,
            &native_options,
            @ptrCast(out.ptr),
            out.len,
            &written,
        ));
        return filled(out, written);
    }

    /// Runs the cell coverer and builds its list to return the count; allocation may return `OutOfMemory`.
    pub fn coveringCellCount(self: Coverer, cell: CellId) Error!usize {
        var required: usize = undefined;
        const native_options = try self.options();
        try check(c.s2br_coverer_covering_cell(
            cell.raw,
            &native_options,
            null,
            0,
            &required,
        ));
        return required;
    }
};
