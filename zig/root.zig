//! Typed Zig facade over the real google/s2geometry C++ library.
//!
//! Nothing here reimplements S2. No Hilbert curve, no spherical triangle area,
//! no cell-id bit layout, no token codec. Every answer this module returns was
//! computed by the upstream C++ compiled from `src/s2` and reached through
//! `zig/bridge.h`, the C surface that `addTranslateC` translates. What this
//! module adds is the part a C header cannot express:
//!
//!   * units in every name (`lat_deg`, `radius_deg`, `perimeterRad`), so no
//!     value is ambiguous about radians-versus-degrees or steradians-versus-area;
//!   * caller-owned output buffers with the required length always reported, so
//!     no list return needs a heap allocation;
//!   * a closed error set matching what the bridge can actually report, cut at
//!     the conditions this code checks;
//!   * opaque `Loop` and `Polygon` handles with a `deinit` that calls the
//!     matching C++ free, so no caller frees C++ storage.
//!
//! ## Allocation
//!
//! A `CellId`, a `LatLng`, a `Point`, a `Cell`, a `Cap` and a `LatLngRect` are
//! plain values: no allocation, nothing to free. `Loop` and `Polygon` own C++
//! storage and their `deinit` releases it through `s2br_*_destroy`; a `deinit`
//! after a failed `init` is safe, because the bridge accepts a null handle.
//! List-returning calls write into a buffer the caller owns and never allocate
//! on the Zig side; the one allocation they may perform is upstream's own, and
//! that is released before the call returns.
//!
//! ## Ownership across the boundary
//!
//! The vertex arrays this module accepts are *borrowed*: `Loop.init` and
//! `Polygon.init` read them and keep no reference, because `S2Loop::Init` copies
//! them (`s2/s2loop.cc:201-207`). The caller's buffer is free to go out of scope
//! the moment the call returns. Output buffers are likewise borrowed for the
//! duration of the call and written only inside their own length.
//!
//! ## Invalid geometry
//!
//! `Loop.init` and `Polygon.init` take the caller's vertices as given. A chain
//! that breaks a loop precondition -- a repeated vertex, a self-intersection,
//! a shell that is not simple -- is still constructed, in every build mode, and
//! `Loop.isValid` / `Polygon.isValid` report it. Upstream's own default is
//! fatal instead: `S2Loop::InitIndex` runs `ABSL_CHECK(IsValid())`
//! (`s2/s2loop.cc:353-359`) and `S2Polygon::InitIndex` does the same
//! (`s2/s2polygon.cc:353-360`) whenever the global `--s2debug` flag is on,
//! which it is by default in any build without `NDEBUG`
//! (`s2/s2debug.h:18-25`). The bridge therefore builds every handle with
//! `S2Debug::DISABLE`, the per-object opt-out upstream documents for a caller
//! that validates explicitly (`s2/s2debug.h:30-40`, `s2/s2loop.h:111-124`,
//! `s2/s2polygon.h:126-148`, `s2/s2loop.h:159-174`,
//! `s2/s2polygon.h:210-223`). What counts as invalid is still upstream's
//! answer, computed by upstream's validator; nothing here re-decides it.
//!
//! Two boundaries of that promise are worth stating. A vertex is required to
//! be a unit-length direction -- upstream says so (`s2/s2loop.h:126-130`) and
//! says that its own check comes too late to be one, because construction
//! reaches the exact predicate that assumes unit length
//! (`s2/s2loop.cc:225-230`, `s2/s2predicates.h:394`). `Loop.init`,
//! `Polygon.init` and `Polygon.initLoops` therefore refuse one with
//! `InvalidArgument` instead of passing it to a call that would abort; what
//! `isValid` reports is the topology of a chain built from directions. And a
//! boolean operation has a precondition `isValid` does not cover: upstream
//! states that its `S2Error` overloads "should never return an error provided
//! that both input polygons are valid" (`s2/s2polygon.h:385-388`), so
//! `Polygon.unite` and `Polygon.intersection` require valid operands and
//! report an invalid one as `InvalidArgument` rather than running the
//! operation on it.
//!
//! ## Threading
//!
//! Everything except `Loop` and `Polygon` is a value, so it is shareable. A
//! `Loop` or `Polygon` holds mutable C++ state and belongs to one thread at a
//! time; the upstream types carry no locking of their own.
//!
//! ## Escape hatch
//!
//! `pub const c` is the translated bridge, so a caller who needs something this
//! module does not name can reach it. Going through it gives upstream
//! behaviour with none of the guarantees above, which is the point of making it
//! public.

const std = @import("std");

/// The translated `zig/bridge.h`: this fork's own C surface over upstream C++,
/// not an upstream header. It is public so a caller can reach a call this
/// module does not wrap.
pub const c = @import("c");

/// What this module reports, cut at what the bridge can return and what this
/// code checks:
///
///  * `InvalidArgument` for a non-finite coordinate, a token or debug string the
///    upstream parser rejects, a level outside the range upstream documents, a
///    caller buffer that cannot hold a result and its NUL, a vertex that is
///    not a unit-length direction, and an invalid operand of a boolean polygon
///    operation.
///  * `BufferTooSmall` for a caller buffer too short for a required list length.
///  * `OutOfMemory` when an upstream C++ allocation failed: a real condition,
///    reported rather than swallowed.
///  * `Internal` when upstream reported failure through its own status: a
///    boolean polygon operation that failed for two valid operands, which
///    upstream documents as not something that can happen
///    (`s2/s2polygon.h:385-388`) and which is therefore a real report of
///    something upstream declined to do.
pub const Error = error{
    InvalidArgument,
    BufferTooSmall,
    OutOfMemory,
    Internal,
};

/// Maps one bridge status onto `Error`. An unrecognised non-zero status is
/// `Internal` rather than being read as a pass: the bridge returns only the
/// five values named here, so anything else would otherwise be a silent success.
///
/// `S2BridgeStatus` is a C enum, which `translate-c` gives the unnamed integer
/// type `c_uint` rather than a Zig enum, so there are no fields to switch on:
/// the statuses are the constants `translate-c` emitted at the top level, one
/// per enumerator, and each is compared by value.
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

/// Reads a bridge `int` that carries a boolean.
fn asBool(value: c_int) bool {
    return value != 0;
}

/// A public index, as the `int` the bridge takes it as.
///
/// Upstream indexes loops and vertices with an `int` (`S2Loop::vertex(int i)`,
/// `s2/s2loop.h:193`; `S2Polygon::loop(int k)`, `s2/s2polygon.h:259`), while a
/// Zig caller holds a `usize` and can write down any value one, `maxInt(usize)`
/// included. Narrowing that is not an index: it panics in every mode that
/// checks an `@intCast`, and in the mode that does not it is a different
/// index, silently. So a public index past the largest `int` is
/// `InvalidArgument`, refused here before the call, where the facade can
/// report it, rather than narrowed where it cannot be.
fn asIndex(i: usize) Error!c_int {
    if (i > @as(usize, @intCast(std.math.maxInt(c_int)))) return error.InvalidArgument;
    return @intCast(i);
}

/// Returns the filled prefix of a caller's buffer after a list-returning bridge
/// call.
///
/// The bridge always reports how many items the list really has, even when it
/// wrote none, so a count larger than the buffer means the buffer was too
/// small -- including the case of an empty buffer, where the count is all the
/// caller learns. Slicing with the reported count before this check would read
/// past the end, which is why every list method goes through here.
fn filled(out: []CellId, written: usize) Error![]CellId {
    if (written > out.len) return error.BufferTooSmall;
    return out[0..written];
}

/// The largest valid cell level, `S2CellId::kMaxLevel`
/// (`s2/s2cell_id.h:99-100`), which is `S2::kMaxCellLevel` (`s2/s2coords.h:131`).
pub const max_level: u8 = @intCast(c.S2BRIDGE_MAX_LEVEL);

/// The number of cube faces, `S2CellId::kNumFaces` (`s2/s2cell_id.h:98`).
pub const num_faces: u8 = 6;

/// A unit-sphere direction, as three doubles in the order x, y, z.
///
/// This is upstream's `S2Point` (`s2/s2point.h:55`), a plain 3-vector
/// (`s2/s2point.h:63`, `s2/util/math/vector.h`). The bridge builds one
/// component at a time and hands one back the same way, so nothing here depends
/// on that layout being shared with anything.
pub const Point = struct {
    x: f64,
    y: f64,
    z: f64,

    /// `S2Point::Normalize` (`s2/s2point.h:157`).
    pub fn normalized(self: Point) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_point_normalized(self.x, self.y, self.z, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// `S2LatLng(const S2Point&)` (`s2/s2latlng.h:64-65`).
    pub fn toLatLng(self: Point) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_lat_lng_from_point(self.x, self.y, self.z, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }
};

/// A point on the unit sphere as a latitude and longitude, in degrees.
///
/// Degrees are in the field names and nowhere else in this module. Upstream
/// stores radians internally (`s2/s2latlng.h:95-96`) and this is the only place
/// the two units meet.
pub const LatLng = struct {
    lat_deg: f64,
    lng_deg: f64,

    /// `S2LatLng::FromDegrees` (`s2/s2latlng.h:72`).
    pub fn fromDegrees(lat_deg: f64, lng_deg: f64) LatLng {
        return .{ .lat_deg = lat_deg, .lng_deg = lng_deg };
    }

    /// `S2LatLng::FromRadians` (`s2/s2latlng.h:71`), converted here so that
    /// degrees stay the only unit the fields speak.
    pub fn fromRadians(lat_rad: f64, lng_rad: f64) LatLng {
        return .{
            .lat_deg = lat_rad * (180.0 / std.math.pi),
            .lng_deg = lng_rad * (180.0 / std.math.pi),
        };
    }

    /// `S2LatLng::is_valid` (`s2/s2latlng.h:101`): latitude within +/-90 degrees
    /// and longitude within +/-180 degrees, both inclusive.
    pub fn isValid(self: LatLng) bool {
        var out: c_int = 0;
        check(c.s2br_latlng_is_valid_deg(self.lat_deg, self.lng_deg, &out)) catch {
            return false;
        };
        return asBool(out);
    }

    /// `S2LatLng::Normalized` (`s2/s2latlng.h:106`): clamps latitude to +/-90
    /// degrees and wraps longitude into [-180, 180].
    pub fn normalized(self: LatLng) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_latlng_normalized_deg(self.lat_deg, self.lng_deg, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// `S2LatLng::ToPoint` (`s2/s2latlng.h:126`): the equivalent unit-length
    /// direction vector.
    pub fn toPoint(self: LatLng) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_point_from_lat_lng_deg(self.lat_deg, self.lng_deg, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// `S2LatLng::GetDistance` (`s2/s2latlng.h:131-137`) in degrees, measured
    /// along the surface of the sphere. Named for its unit because a tolerance
    /// written against radians is not a tolerance against this.
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

/// A rectangle in a cube face's (u,v) coordinates, as upstream's `R2Rect`
/// reports it. Each axis is a closed interval.
pub const BoundUV = struct {
    u_lo: f64,
    u_hi: f64,
    v_lo: f64,
    v_hi: f64,
};

/// An S2 cell id: the 64-bit unsigned integer naming one cell of the sphere's
/// decomposition (`s2/s2cell_id.h:58-66`).
///
/// The id *is* the cell. Nothing here reads or writes the face and
/// Hilbert-position layout; that is upstream's, and `raw` is exactly the integer
/// upstream stores (`s2/s2cell_id.h:236-238`).
pub const CellId = struct {
    /// The underlying id, exactly as upstream stores it.
    raw: u64,

    /// An invalid id, upstream's `S2CellId::None()` (`s2/s2cell_id.h:236-238`).
    pub const none: CellId = .{ .raw = 0 };

    /// An invalid id guaranteed larger than every valid one, upstream's
    /// `S2CellId::Sentinel()` (`s2/s2cell_id.h:126-128`).
    pub const sentinel: CellId = .{ .raw = 0xffff_ffff_ffff_ffff };

    /// The leaf cell containing `point`
    /// (`S2CellId(const S2LatLng&)`, `s2/s2cell_id.h:119-122`).
    pub fn fromLatLng(point: LatLng) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_lat_lng_deg(point.lat_deg, point.lng_deg, &out));
        return .{ .raw = out };
    }

    /// The leaf cell containing a direction vector, which need not be unit
    /// length (`S2CellId(const S2Point&)`, `s2/s2cell_id.h:107-117`).
    pub fn fromPoint(point: Point) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_point(point.x, point.y, point.z, &out));
        return .{ .raw = out };
    }

    /// The six level-0 face cells, `S2CellId::FromFace` (`s2/s2cell_id.h:165`).
    /// `face_index` may be 0..5 for a real cell; 6 and 7 produce an invalid id, which
    /// is what upstream's own tests use them for (`s2/s2cell_id_test.cc:335-336`).
    pub fn fromFace(face_index: u8) Error!CellId {
        if (face_index > 7) return error.InvalidArgument;
        var out: u64 = undefined;
        try check(c.s2br_cell_from_face(@intCast(face_index), &out));
        return .{ .raw = out };
    }

    /// `S2CellId::FromFacePosLevel` (`s2/s2cell_id.h:173`). `hilbert_pos` is
    /// the position along the Hilbert curve over that face, which is what
    /// `pos` reads back; it is named in full here because `pos` is this
    /// struct's own method.
    /// `face_index` must be 0..5, as upstream requires for this constructor.
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

    /// `S2CellId::FromFaceIJ` (`s2/s2cell_id.h:484`), from the cell centre's
    /// i/j coordinates, each in 0 .. 2^30 - 1.
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

    /// `S2CellId::FromToken` (`s2/s2cell_id.h:422`).
    ///
    /// A token upstream rejects is `error.InvalidArgument`, not the id 0:
    /// upstream answers a malformed token with `S2CellId::None()`
    /// (`s2/s2cell_id.cc:249-250`), and a caller must not have to tell that
    /// apart from a real cell.
    pub fn fromToken(token: []const u8) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_token(token.ptr, token.len, &out));
        return .{ .raw = out };
    }

    /// `S2CellId::FromDebugString` (`s2/s2cell_id.h:454`): the
    /// "face/childpos..." spelling upstream writes its own neighbour fixtures
    /// in (`s2/s2cell_id_test.cc:638`, `s2/s2cell_id_test.cc:666`).
    pub fn fromDebugString(text: []const u8) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_debug_string(text.ptr, text.len, &out));
        return .{ .raw = out };
    }

    /// Writes the token into `buf` and returns the part of `buf` holding it.
    ///
    /// `buf` needs room for the token *and* its NUL; upstream's longest token is
    /// 16 characters (`s2/s2cell_id.h:415-420`, `s2/s2cell_id.cc:232`), so 17
    /// bytes always suffice. A shorter buffer writes nothing and is
    /// `error.BufferTooSmall`.
    pub fn toToken(self: CellId, buf: []u8) Error![]const u8 {
        var needed: usize = undefined;
        try check(c.s2br_cell_to_token(self.raw, buf.ptr, buf.len, &needed));
        if (buf.len <= needed) return error.BufferTooSmall;
        return buf[0..needed];
    }

    /// Writes the debug string into `buf`, under the same buffer rule as
    /// `toToken`.
    pub fn toDebugString(self: CellId, buf: []u8) Error![]const u8 {
        var needed: usize = undefined;
        try check(c.s2br_cell_to_debug_string(self.raw, buf.ptr, buf.len, &needed));
        if (buf.len <= needed) return error.BufferTooSmall;
        return buf[0..needed];
    }

    /// `S2CellId::is_valid` (`s2/s2cell_id.h:236`).
    pub fn isValid(self: CellId) bool {
        return asBool(c.s2br_cell_is_valid(self.raw));
    }

    /// `S2CellId::level` (`s2/s2cell_id.h:259`), in 0 .. `max_level`.
    pub fn level(self: CellId) Error!u8 {
        var out: c_int = undefined;
        try check(c.s2br_cell_level(self.raw, &out));
        return @intCast(out);
    }

    /// `S2CellId::face` (`s2/s2cell_id.h:242`), in 0..5.
    pub fn face(self: CellId) Error!u8 {
        var out: c_int = undefined;
        try check(c.s2br_cell_face(self.raw, &out));
        return @intCast(out);
    }

    /// `S2CellId::pos` (`s2/s2cell_id.h:246`): the cell centre's position along
    /// the Hilbert curve over its face.
    pub fn pos(self: CellId) Error!u64 {
        var out: u64 = undefined;
        try check(c.s2br_cell_pos(self.raw, &out));
        return out;
    }

    /// `S2CellId::is_leaf` (`s2/s2cell_id.h:268`).
    pub fn isLeaf(self: CellId) bool {
        return asBool(c.s2br_cell_is_leaf(self.raw));
    }

    /// `S2CellId::is_face` (`s2/s2cell_id.h:274`).
    pub fn isFace(self: CellId) bool {
        return asBool(c.s2br_cell_is_face(self.raw));
    }

    /// The cell at `target_level` containing this one: `S2CellId::parent(int level)`
    /// (`s2/s2cell_id.h:325`). `target_level` must be at or below this cell's own
    /// level, which is upstream's precondition (`s2/s2cell_id.h:322-325`);
    /// `null` means the immediate parent, which is what upstream's own
    /// zero-argument `parent()` is (`s2/s2cell_id.h:320`, `s2/s2cell_id.h:660`).
    pub fn parent(self: CellId, target_level: ?u8) Error!CellId {
        const target: u8 = if (target_level) |l| l else blk: {
            const here = try self.level();
            // A level-0 cell has no parent: upstream's zero-argument `parent()`
            // is `parent(level() - 1)` (`s2/s2cell_id.h:660`) and a negative
            // level is outside what that method documents
            // (`s2/s2cell_id.h:322-325`).
            if (here == 0) return error.InvalidArgument;
            break :blk here - 1;
        };
        var out: u64 = undefined;
        try check(c.s2br_cell_parent(self.raw, @intCast(target), &out));
        return .{ .raw = out };
    }

    /// The immediate child at traversal position 0..3:
    /// `S2CellId::child(int position)` (`s2/s2cell_id.h:329`).
    pub fn child(self: CellId, position: u8) Error!CellId {
        if (position > 3) return error.InvalidArgument;
        var out: u64 = undefined;
        try check(c.s2br_cell_child(self.raw, @intCast(position), &out));
        return .{ .raw = out };
    }

    /// Every descendant of this cell at `target_level`, in ascending Hilbert-curve
    /// order, written into `out`; returns the part of `out` that was filled.
    ///
    /// There are 4^(target_level - own level) of them, which is a number worth
    /// taking seriously: a face cell asked for level 30 has 2^60. Ask
    /// `childrenCount` for the number first if the buffer is not already large
    /// enough -- a short buffer is `BufferTooSmall` with nothing written into
    /// it -- and expect the fill itself to be no cheaper than that count.
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

    /// How many descendants this cell has at `target_level`, read from upstream's own
    /// `child_begin`/`child_end` range (`s2/s2cell_id.h:344-347`) rather than
    /// recomputed here: the difference of the two endpoints' own
    /// `distance_from_begin` (`s2/s2cell_id.h:360-363`), which counts `next()`
    /// steps, is the length of the range. That is a constant-time answer, which
    /// is the only kind that exists for the 2^60 a face cell at level 30 names:
    /// nothing that walked or materialised the range could report it at all.
    ///
    /// A range longer than a `usize` can count -- 2^60 on a 32-bit target -- is
    /// `InvalidArgument` rather than a wrapped count.
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

    /// `S2CellId::next` (`s2/s2cell_id.h:355`): the next cell at the same level
    /// along the Hilbert curve. It does not wrap from the last face to the first
    /// (`s2/s2cell_id.h:351-355`).
    pub fn next(self: CellId) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_next(self.raw, &out));
        return .{ .raw = out };
    }

    /// `S2CellId::prev` (`s2/s2cell_id.h:359`).
    pub fn prev(self: CellId) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_prev(self.raw, &out));
        return .{ .raw = out };
    }

    /// `S2CellId::contains` (`s2/s2cell_id.h:313`).
    pub fn contains(self: CellId, other: CellId) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cell_contains(self.raw, other.raw, &out));
        return asBool(out);
    }

    /// `S2CellId::intersects` (`s2/s2cell_id.h:317`).
    pub fn intersects(self: CellId, other: CellId) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cell_intersects(self.raw, other.raw, &out));
        return asBool(out);
    }

    /// The inclusive id range this cell spans, `S2CellId::range_min` and
    /// `range_max` (`s2/s2cell_id.h:302-305`). Upstream defines `contains` in
    /// terms of exactly this pair (`s2/s2cell_id.h:290-295`).
    pub fn range(self: CellId) Error![2]CellId {
        var lo: u64 = undefined;
        var hi: u64 = undefined;
        try check(c.s2br_cell_range(self.raw, &lo, &hi));
        return .{ .{ .raw = lo }, .{ .raw = hi } };
    }

    /// The four cells across this cell's four edges, in the order
    /// `S2CellId::GetEdgeNeighbors` defines (`s2/s2cell_id.h:455-459`). Always
    /// four distinct cells, so this allocates nothing.
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

    /// The neighbours of the vertex of this cell closest to `target_level`, written
    /// into `out`: `S2CellId::AppendVertexNeighbors` (`s2/s2cell_id.h:468`).
    ///
    /// Three or four results, because a cell whose nearest vertex is one of the
    /// eight cube vertices has only three (`s2/s2cell_id.cc:548-553`), which is
    /// why this returns a slice and not a fixed array. `target_level` must be strictly
    /// below this cell's own level (`s2/s2cell_id.cc:516-518`).
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

    /// How many neighbours `vertexNeighbors` produces at `target_level`: three or four.
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

    /// Every neighbour of this cell at `target_level`:
    /// `S2CellId::AppendAllNeighbors` (`s2/s2cell_id.h:477`).
    ///
    /// Eight results normally, and upstream's own corner-cell fixture contains a
    /// duplicate among them (`s2/s2cell_id_test.cc:641-649`), so this reports
    /// what upstream produced rather than deduplicating it. `target_level` must be in
    /// this cell's own level .. `max_level` inclusive (`s2/s2cell_id.cc:558`,
    /// `s2/s2cell_id.h:611-614`).
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

    /// How many neighbours `allNeighbors` produces at `target_level`.
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

    /// `S2CellId::ToLatLng` (`s2/s2cell_id.h:239`): the centre of the cell.
    pub fn toLatLng(self: CellId) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_cell_to_lat_lng_deg(self.raw, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// `S2CellId::ToPoint` (`s2/s2cell_id.h:181`): the unit-length direction of
    /// the cell centre.
    pub fn toPoint(self: CellId) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_cell_to_point(self.raw, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// `S2CellId::GetSizeST` (`s2/s2cell_id.h:188-192`): the cell's edge length
    /// in the (s,t) projection space. A projection-space length, not an angle
    /// and not a distance on the sphere.
    pub fn sizeSt(self: CellId) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_cell_size_st(self.raw, &out));
        return out;
    }

    /// `S2CellId::IJLevelToBoundUV` (`s2/s2cell_id.h:506`): the cell's bounds in
    /// its cube face's (u,v) coordinates.
    pub fn boundUV(self: CellId) Error!BoundUV {
        var uv: [4]f64 = undefined;
        try check(c.s2br_cell_bound_uv(self.raw, &uv));
        return .{ .u_lo = uv[0], .u_hi = uv[1], .v_lo = uv[2], .v_hi = uv[3] };
    }
};

/// An S2 cell, `S2Cell` (`s2/s2cell.h`): the two-dimensional region sense of a
/// cell, where `CellId` is the integer sense.
pub const Cell = struct {
    id: CellId,

    pub fn init(id: CellId) Cell {
        return .{ .id = id };
    }

    /// `S2Cell::ApproxArea` (`s2/s2cell.h:232`) in steradians. Upstream bounds the
    /// error at 3%, and at 0.1% for level 5 and finer (`s2/s2cell.h:227-232`).
    pub fn approxArea(self: Cell) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_cell_approx_area(self.id.raw, &out));
        return out;
    }

    /// `S2Cell::ExactArea` (`s2/s2cell.h:237`) in steradians, accurate to about
    /// six digits even for a leaf cell (`s2/s2cell.h:233-237`).
    pub fn exactArea(self: Cell) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_cell_exact_area(self.id.raw, &out));
        return out;
    }

    /// `S2Cell::AverageArea(int level)` (`s2/s2cell.h:221`): the mean area of
    /// every cell at `level`, in steradians. One number per level because the
    /// six faces partition the sphere evenly.
    pub fn averageAreaAtLevel(level: u8) Error!f64 {
        if (level > max_level) return error.InvalidArgument;
        var out: f64 = undefined;
        try check(c.s2br_cell_average_area(@intCast(level), &out));
        return out;
    }

    /// `S2Cell::GetCenter` (`s2/s2cell.h:217`): the point at which the cell
    /// divides into four children, which is upstream's definition of "centre"
    /// and is not in general the middle of the (u,v) rectangle
    /// (`s2/s2cell.h:210-217`).
    pub fn center(self: Cell) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_cell_center(self.id.raw, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// `S2Cell::GetVertex(int k)` (`s2/s2cell.h:136-141`): the k-th corner,
    /// counter-clockwise from the lower-left corner of the (u,v) square.
    pub fn vertex(self: Cell, k: u8) Error!Point {
        if (k > 3) return error.InvalidArgument;
        var xyz: [3]f64 = undefined;
        try check(c.s2br_cell_vertex(self.id.raw, @intCast(k), &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// `S2Cell::GetBoundUV` (`s2/s2cell.h:240`).
    pub fn boundUV(self: Cell) Error!BoundUV {
        var uv: [4]f64 = undefined;
        try check(c.s2br_cell_bound_uv_of_cell(self.id.raw, &uv));
        return .{ .u_lo = uv[0], .u_hi = uv[1], .v_lo = uv[2], .v_hi = uv[3] };
    }

    /// `S2Cell::Contains(const S2Point&)` (`s2/s2cell.h:308`). Cell ids are
    /// closed sets, so a point on a shared boundary is contained by every cell
    /// that touches it (`s2/s2cell_id.h:107-112`).
    pub fn containsPoint(self: Cell, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cell_contains_point(self.id.raw, point.x, point.y, point.z, &out));
        return asBool(out);
    }
};

/// A spherical cap, `S2Cap` (`s2/s2cap.h`): the points within `radius_deg` of
/// `center` along the sphere.
pub const Cap = struct {
    center: LatLng,
    radius_deg: f64,

    /// `S2Cap::GetArea` (`s2/s2cap.cc:48-50`) in steradians.
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

    /// `S2Cap::height` (`s2/s2cap.h:105`): the distance from the centre to the
    /// cutting plane, as a multiple of the sphere radius.
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

    /// `S2Cap::Complement` (`s2/s2cap.cc:65-71`). The complement of a full cap
    /// is the empty cap and of the empty cap the full one, so the result's
    /// radius is 180 degrees for an empty cap and 0 for a full one.
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

    /// `S2Cap::Contains(const S2Point&)` (`s2/s2cap.h:192`). Upstream
    /// REQUIRES a unit-length vector (`s2/s2cap.cc:296-300`), so `point` must
    /// be finite and of length 1 within upstream's own tolerance; anything else
    /// is `error.InvalidArgument` rather than a value computed from an input
    /// upstream never defined. `Point.normalized` is the way to get one.
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

/// A latitude-longitude rectangle, `S2LatLngRect` (`s2/s2latlng_rect.h`).
///
/// `lng_lo_deg > lng_hi_deg` is a legal rectangle that crosses the 180 degree
/// line, not an error, and `isInverted` reports exactly that condition.
pub const LatLngRect = struct {
    lat_lo_deg: f64,
    lng_lo_deg: f64,
    lat_hi_deg: f64,
    lng_hi_deg: f64,

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

    /// `S2LatLngRect::Area` (`s2/s2latlng_rect.h:184`) in steradians on the unit
    /// sphere.
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

    /// `S2LatLngRect::Contains(const S2LatLng&)` (`s2/s2latlng_rect.h:179`). The
    /// answer is inclusive of the boundary, so upstream separates it from
    /// `InteriorContains` (`s2/s2latlng_rect.h:172-179`); this reports the
    /// inclusive one.
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

    /// `S2LatLngRect::PolarClosure` (`s2/s2latlng_rect.cc:229-234`): the same
    /// region, widened to every longitude when either edge touches a pole. A
    /// rectangle that touches no pole is returned unchanged.
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

    /// `S2LatLngRect::is_inverted` (`s2/s2latlng_rect.h:145`): true when this
    /// rectangle crosses the 180 degree line.
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

    /// `S2LatLngRect::is_valid` (`s2/s2latlng_rect.h:132`).
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

/// An owned S2 loop, `S2Loop` (`s2/s2loop.h`).
///
/// The loop's interior is the region on the *left* of the vertex chain, and
/// containment is defined so that every point of the sphere belongs to exactly
/// one face (`s2/s2loop.h:82-92`), which is why a loop does not necessarily
/// contain its own vertices.
pub const Loop = struct {
    handle: ?*c.S2BridgeLoop,

    /// A loop through `vertices`, at least three of them
    /// (`S2Loop::Init(absl::Span<const S2Point>)`, `s2/s2loop.h:130`).
    ///
    /// `vertices` is borrowed: upstream copies it (`s2/s2loop.cc:201-207`), so it
    /// need not outlive the call. A `[]const [3]f64` is passed straight through
    /// as the `double xyz[3 * n]` the bridge reads, because the element stride is
    /// three doubles either way.
    ///
    /// Every vertex must be a unit-length direction, within upstream's own
    /// tolerance (`S2::IsUnitLength`, `s2/s2pointutil.cc:32-40`); one that is
    /// not is `InvalidArgument`, because `S2Loop::Init` reaches an exact
    /// predicate that assumes it and dies otherwise (`s2/s2predicates.h:394`).
    /// See `Invalid geometry` above.
    ///
    /// The chain itself need not be a valid loop: an invalid one is constructed
    /// and `isValid` reports it, in every build mode. See `Invalid geometry`
    /// above.
    ///
    /// A length `vertices.len` that upstream could not be told about is
    /// `InvalidArgument` as well: `S2Loop::Init` stores the count in an `int`
    /// (`s2/s2loop.cc:203`, `s2/s2loop.h:647`). The bridge rejects it before
    /// reading the buffer or allocating, so no handle is produced.
    pub fn init(vertices: []const [3]f64) Error!Loop {
        if (vertices.len < 3) return error.InvalidArgument;
        var out: ?*c.S2BridgeLoop = null;
        try check(c.s2br_loop_create(@ptrCast(vertices.ptr), vertices.len, &out));
        return .{ .handle = out.? };
    }

    /// `S2Loop::kEmpty` (`s2/s2loop.h:139`): a loop with no edges that contains
    /// no points.
    pub fn empty() Error!Loop {
        var out: ?*c.S2BridgeLoop = null;
        try check(c.s2br_loop_create_empty(&out));
        return .{ .handle = out.? };
    }

    /// `S2Loop::kFull` (`s2/s2loop.h:143`): a loop with no edges that contains
    /// every point.
    pub fn full() Error!Loop {
        var out: ?*c.S2BridgeLoop = null;
        try check(c.s2br_loop_create_full(&out));
        return .{ .handle = out.? };
    }

    /// Releases the C++ storage. The bridge accepts a null handle
    /// (`zig/bridge.h`, `s2br_loop_destroy`), so `deinit` on a loop whose
    /// construction failed is safe and does nothing.
    pub fn deinit(self: *Loop) void {
        c.s2br_loop_destroy(self.handle);
        self.* = undefined;
    }

    /// `S2Loop::num_vertices` (`s2/s2loop.h:187`).
    pub fn numVertices(self: Loop) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_loop_num_vertices(self.handle, &out));
        return @intCast(out);
    }

    /// `S2Loop::vertex(int i)` (`s2/s2loop.h:193-195`).
    ///
    /// An `i` past the largest `int` is `InvalidArgument`, not a narrowed
    /// index; see `asIndex`.
    pub fn vertex(self: Loop, i: usize) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_loop_vertex(self.handle, try asIndex(i), &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// The vertex `i` as degrees, `S2LatLng(const S2Point&)`.
    ///
    /// An `i` past the largest `int` is `InvalidArgument`; see `asIndex`.
    pub fn vertexLatLng(self: Loop, i: usize) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_loop_vertex_lat_lng_deg(self.handle, try asIndex(i), &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// `S2Loop::GetArea` (`s2/s2loop.h:265`) in steradians, between 0 and 4*pi.
    ///
    /// Unsigned: whether the loop is a shell or a hole is not part of the answer
    /// (`s2/s2loop.h:262-265`). Use `signedArea` when the sign is what matters.
    pub fn area(self: Loop) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_loop_area(self.handle, &out));
        return out;
    }

    /// `S2::GetSignedArea` over the vertices (`s2/s2loop_measures.h:78`) in
    /// steradians: negative when the interior is more than half the sphere.
    pub fn signedArea(self: Loop) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_loop_signed_area(self.handle, &out));
        return out;
    }

    /// `S2::GetPerimeter` over the vertices (`s2/s2loop_measures.h:44`) in
    /// radians. Named for its unit because radians and degrees are not
    /// interchangeable in a tolerance written against it.
    pub fn perimeterRad(self: Loop) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_loop_perimeter_rad(self.handle, &out));
        return out;
    }

    /// `S2Loop::Contains(const S2Point&)` (`s2/s2loop.h:414`).
    pub fn containsPoint(self: Loop, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_contains_point(self.handle, point.x, point.y, point.z, &out));
        return asBool(out);
    }

    /// `S2Loop::IsNormalized` (`s2/s2loop.h:249`): whether the enclosed area is
    /// at most 2*pi.
    pub fn isNormalized(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_normalized(self.handle, &out));
        return asBool(out);
    }

    /// `S2Loop::Normalize` (`s2/s2loop.h:253`): inverts if necessary so the
    /// enclosed area is at most 2*pi.
    pub fn normalize(self: *Loop) Error!void {
        try check(c.s2br_loop_normalize(self.handle));
    }

    /// `S2Loop::Invert` (`s2/s2loop.h:260`).
    pub fn invert(self: *Loop) Error!void {
        try check(c.s2br_loop_invert(self.handle));
    }

    /// `S2Loop::is_empty` (`s2/s2loop.h:223`).
    pub fn isEmpty(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_empty(self.handle, &out));
        return asBool(out);
    }

    /// `S2Loop::is_full` (`s2/s2loop.h:226`).
    pub fn isFull(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_full(self.handle, &out));
        return asBool(out);
    }

    /// `S2Loop::IsValid` (`s2/s2loop.h:179`): every loop precondition holds,
    /// including no self-intersection and no repeated vertex.
    ///
    /// Reachable for an invalid loop precisely because `init` does not abort on
    /// one; see `Invalid geometry` above.
    pub fn isValid(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_valid(self.handle, &out));
        return asBool(out);
    }
};

/// An owned S2 polygon, `S2Polygon` (`s2/s2polygon.h`): a set of nested loops
/// whose interior is the points contained by an odd number of them
/// (`s2/s2polygon.h:176-183`).
pub const Polygon = struct {
    handle: ?*c.S2BridgePolygon,

    /// A polygon whose interior is the single shell `vertices`,
    /// `S2Polygon::Init(std::unique_ptr<S2Loop>)` (`s2/s2polygon.h:196`).
    /// `vertices` is borrowed; see `Loop.init`.
    ///
    /// Every vertex must be a unit-length direction, and one that is not is
    /// `InvalidArgument`; the shell is built by `S2Loop::Init` and inherits
    /// that requirement. See `Loop.init` and `Invalid geometry` above.
    ///
    /// The shell need not be a valid loop, and need not produce a valid
    /// polygon: `isValid` reports either, in every build mode. See `Invalid
    /// geometry` above.
    ///
    /// A length `vertices.len` that upstream could not be told about is
    /// `InvalidArgument` as well, for the same reason as in `Loop.init`: the
    /// shell is built by `S2Loop::Init`.
    pub fn init(vertices: []const [3]f64) Error!Polygon {
        if (vertices.len < 3) return error.InvalidArgument;
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_create(@ptrCast(vertices.ptr), vertices.len, &out));
        return .{ .handle = out.? };
    }

    /// A polygon from nested loops, `S2Polygon::InitNested`
    /// (`s2/s2polygon.h:183`).
    ///
    /// `vertices` holds every loop back to back and `loop_sizes` gives their
    /// lengths in order. The caller says nothing about which loops are shells
    /// and which are holes: upstream works that out from the nesting depth
    /// (`s2/s2polygon.h:184-189`) and reorders the loops into the traversal order
    /// `loopVertex` reports.
    ///
    /// Every vertex of every loop must be a unit-length direction, as in
    /// `init` above.
    ///
    /// A length list upstream could not be told about is `InvalidArgument` as
    /// well: `S2Polygon::num_loops()` narrows the loop count to an `int`
    /// (`s2/s2polygon.h:248`), `S2Loop::Init` stores each length in one
    /// (`s2/s2loop.h:647`), and `S2Polygon::InitLoopProperties` sums them in
    /// another (`s2/s2polygon.cc:530`). The bridge rejects an impossible count
    /// before it reads `loop_sizes` or allocates, so no handle is produced.
    pub fn initLoops(vertices: []const [3]f64, loop_sizes: []const usize) Error!Polygon {
        if (loop_sizes.len == 0) return error.InvalidArgument;
        var total: usize = 0;
        for (loop_sizes) |size| {
            if (size < 3) return error.InvalidArgument;
            // A list whose lengths cannot even be summed describes no vertex
            // array, which is the same argument error as one that sums to the
            // wrong length -- and not something to panic over.
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

    /// The empty polygon: no loops, so no interior (`S2Polygon::is_empty`,
    /// `s2/s2polygon.h:241`).
    pub fn empty() Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_create_empty(&out));
        return .{ .handle = out.? };
    }

    /// `S2Polygon::MakeFull` (`s2/s2polygon.h:170`): the whole sphere.
    pub fn full() Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_create_full(&out));
        return .{ .handle = out.? };
    }

    /// Releases the C++ storage; see `Loop.deinit`.
    pub fn deinit(self: *Polygon) void {
        c.s2br_polygon_destroy(self.handle);
        self.* = undefined;
    }

    /// `S2Polygon::num_loops` (`s2/s2polygon.h:248`).
    pub fn numLoops(self: Polygon) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_polygon_num_loops(self.handle, &out));
        return @intCast(out);
    }

    /// `S2Polygon::num_vertices` (`s2/s2polygon.h:252`), the total over all
    /// loops.
    pub fn numVertices(self: Polygon) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_polygon_num_vertices(self.handle, &out));
        return @intCast(out);
    }

    /// `S2Polygon::loop(k)->num_vertices` (`s2/s2polygon.h:259`).
    ///
    /// A `loop_index` past the largest `int` is `InvalidArgument`; see
    /// `asIndex`.
    pub fn loopNumVertices(self: Polygon, loop_index: usize) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_polygon_loop_num_vertices(self.handle, try asIndex(loop_index), &out));
        return @intCast(out);
    }

    /// `S2Polygon::loop(k)->vertex(i)` (`s2/s2polygon.h:259`,
    /// `s2/s2loop.h:193`). The loop index is the traversal order
    /// `InitNested` produced (`s2/s2polygon.h:186-189`).
    ///
    /// Either index past the largest `int` is `InvalidArgument`, and the loop
    /// index is checked first; see `asIndex`.
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

    /// The same vertex as degrees.
    ///
    /// Either index past the largest `int` is `InvalidArgument`, and the loop
    /// index is checked first; see `asIndex`.
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

    /// `S2Polygon::GetArea` (`s2/s2polygon.h:275`) in steradians, between 0 and
    /// 4*pi, with holes already subtracted.
    pub fn area(self: Polygon) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_polygon_area(self.handle, &out));
        return out;
    }

    /// `S2Polygon::Contains(const S2Point&)` (`s2/s2polygon.h:653-656`). The
    /// point carries the same unit-length requirement as `Cap.containsPoint`
    /// (`s2/s2polygon.cc:704-706`).
    pub fn containsPoint(self: Polygon, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_contains_point(self.handle, point.x, point.y, point.z, &out));
        return asBool(out);
    }

    /// The same question asked of a normalized S2LatLng, which upstream's own
    /// `S2LatLng::ToPoint` turns into the unit vector that overload requires.
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

    /// `S2Polygon::GetCentroid` (`s2/s2polygon.h:286`) normalized and in
    /// degrees. The centroid of a region need not lie inside it
    /// (`s2/s2polygon.h:279-286`).
    pub fn centroidLatLng(self: Polygon) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_polygon_centroid_lat_lng_deg(self.handle, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// `S2Polygon::is_empty` (`s2/s2polygon.h:241`).
    pub fn isEmpty(self: Polygon) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_is_empty(self.handle, &out));
        return asBool(out);
    }

    /// `S2Polygon::is_full` (`s2/s2polygon.h:245`).
    pub fn isFull(self: Polygon) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_is_full(self.handle, &out));
        return asBool(out);
    }

    /// `S2Polygon::IsValid` (`s2/s2polygon.h:229`).
    ///
    /// Including the validity of every loop the polygon owns. Reachable for an
    /// invalid polygon precisely because `init` does not abort on one; see
    /// `Invalid geometry` above.
    pub fn isValid(self: Polygon) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_is_valid(self.handle, &out));
        return asBool(out);
    }

    /// `S2Polygon::InitToComplement` (`s2/s2polygon.h:496-497`): a new polygon
    /// covering everything `self` does not. `self` is untouched.
    pub fn complement(self: Polygon) Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_complement(self.handle, &out));
        return .{ .handle = out.? };
    }

    /// `S2Polygon::InitToIntersection` (`s2/s2polygon.h:389`): a new polygon
    /// covering the overlap of `a` and `b`. Neither input is modified.
    ///
    /// Both operands must be valid, which is upstream's stated precondition for
    /// the operation: its `S2Error` overloads "should never return an error
    /// provided that both input polygons are valid" (`s2/s2polygon.h:385-388`).
    /// An invalid operand is `InvalidArgument`, decided by `isValid` before the
    /// operation runs rather than by anything it does, and `Internal` is what a
    /// failure upstream did report comes back as. Either way no partial result
    /// is returned.
    pub fn intersection(a: Polygon, b: Polygon) Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_intersection(a.handle, b.handle, &out));
        return .{ .handle = out.? };
    }

    /// `S2Polygon::InitToUnion` (`s2/s2polygon.h:396`): a new polygon covering
    /// `a` or `b`. Neither input is modified, and both must be valid; see
    /// `intersection` above for what an invalid operand and an upstream failure
    /// are reported as.
    pub fn unite(a: Polygon, b: Polygon) Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_union(a.handle, b.handle, &out));
        return .{ .handle = out.? };
    }
};

/// How much of the sphere a covering may use: `S2RegionCoverer::Options`
/// (`s2/s2region_coverer.h:74-160`).
///
/// The defaults are upstream's own: every level, every level modulo one, and
/// eight cells (`s2/s2region_coverer.h:101-103`,
/// `s2/s2region_coverer.h:157-160`).
pub const Coverer = struct {
    /// Cells below this level are never returned, even if that means more of
    /// them (`s2/s2region_coverer.h:113-118`).
    min_level: u8 = 0,
    /// Cells above this level are never returned (`s2/s2region_coverer.h:130`).
    max_level: u8 = max_level,
    /// Only levels where `(level - min_level)` is a multiple of this are used
    /// (`s2/s2region_coverer.h:148`).
    level_mod: u8 = 1,
    /// The desired maximum number of cells; upstream publishes a table of the
    /// accuracy this buys (`s2/s2region_coverer.h:93-100`).
    max_cells: u32 = 8,

    fn options(self: Coverer) Error!c.S2BridgeCovererOptions {
        if (self.min_level > self.max_level) return error.InvalidArgument;
        if (self.max_level > max_level) return error.InvalidArgument;
        if (self.level_mod < 1 or self.level_mod > 3) return error.InvalidArgument;
        if (self.max_cells < 1) return error.InvalidArgument;
        // The bridge carries `max_cells` as an `int32_t`
        // (`zig/bridge.h:565`), so a `u32` above `maxInt(c_int)` would trap
        // the `@intCast` below in Debug and ReleaseSafe rather than report
        // anything. Reject it here, next to the other parameter checks.
        if (self.max_cells > @as(u32, @intCast(std.math.maxInt(c_int))))
            return error.InvalidArgument;
        return .{
            .min_level = @intCast(self.min_level),
            .max_level = @intCast(self.max_level),
            .level_mod = @intCast(self.level_mod),
            .max_cells = @intCast(self.max_cells),
        };
    }

    /// `S2RegionCoverer::GetCovering` for a cap
    /// (`s2/s2region_coverer.h:187-193`), written into `out`; returns the part of
    /// `out` that was filled.
    ///
    /// The covering is an approximation and not a partition: upstream warns
    /// that the output may change between library versions and must not be relied
    /// on for stability (`s2/s2region_coverer.h:57-63`). `coveringCapCount`
    /// sizes `out` exactly, at the cost of running the coverer twice.
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

    /// How many cells `coveringCap` produces, without keeping them.
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

    /// The cells whose union contains `rect`.
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

    /// How many cells `coveringRect` produces, without keeping them.
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

    /// The cells whose union contains `polygon`.
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

    /// How many cells `coveringPolygon` produces, without keeping them.
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

    /// The cells whose union contains a single cell. Upstream's own covering of
    /// a cell is exactly that one cell (`s2/s2region_coverer_test.cc:84-86`).
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

    /// How many cells `coveringCell` produces, without keeping them.
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
