//! Behavioural tests for the S2 facade.
//!
//! Every expected value here is an independent known answer published either by
//! google/s2geometry or by golang/geo, read out of `testdata/` with
//! `@embedFile`, plus a handful of mathematical identities that hold for any
//! correct implementation. Nothing here calls the library and then declares its
//! own output correct, and nothing pins a version string, an export, a default,
//! or a copy.
//!
//! ## Why these fixtures
//!
//! S2 is a codec and a geometry engine at once, so a self-round-trip such as
//! `toToken(fromToken(x)) == x` proves only that the codec agrees with itself.
//! The fixtures used here are values some other implementation published:
//!
//!   * `testdata/golang_cellid_tokens.tsv` -- 32 token/id pairs and five
//!     malformed tokens from golang/geo's `TestCellIDTokensNominal` and
//!     `TestCellIDFromTokensErrorCases`. golang/geo is an independent
//!     reimplementation of the same codec.
//!   * `testdata/golang_cellid_latlng.tsv` -- 14 leaf-cell id <-> lat/lng pairs
//!     from golang/geo's `TestCellIDLatLng`, whose own comment records that they
//!     came from the C++ `s2cellid2latlngtestcase` program.
//!   * `testdata/upstream_neighbors.tsv` -- neighbour, parent/child, containment
//!     and projection-origin answers from `src/s2/s2cell_id_test.cc`,
//!     `src/python/s2geometry_test.py` and golang/geo, one row kind per source.
//!   * `testdata/upstream_coverer_sydney.txt` -- the 42-cell level-22 covering
//!     that `src/s2/s2region_coverer_test.cc`'s `JavaCcConsistency` test
//!     publishes for a polyline through two real Sydney coordinates, with those
//!     coordinates and the options it used.
//!   * `testdata/upstream_polar_closure.tsv` -- four `PolarClosure` answers from
//!     `src/s2/s2latlng_rect_test.cc`: the pole and antimeridian cases.
//!   * `testdata/golang_latlng_normalize.tsv` -- nine normalization answers from
//!     golang/geo and ten validity answers from `src/s2/s2latlng_test.cc`.
//!
//! ## Mathematical identities used where no number is published
//!
//! The six cube faces tile the sphere, so their exact areas sum to 4*pi. Four
//! children tile their parent, so their exact areas sum to the parent's. An
//! octant of the unit sphere has solid angle exactly pi/2, and its three edges
//! are each pi/2 radians long. A hemisphere is 2*pi. A spherical polygon's
//! area is the excess of its interior angles over (n - 2)*pi, which fixes the
//! pi/2, pi/4 and 3*pi/4 that the two overlapping wedges are held to. These
//! follow from geometry, not from a measurement, and a failure in any of them
//! is a real fault.
//!
//! ## Coverage
//!
//! Every public method of the facade is called from this file with concrete
//! argument types, which is what makes `zig build check` a real compile of the
//! facade for every target instead of a compile of an unreferenced archive.

const std = @import("std");
const s2 = @import("s2geometry");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// `token<TAB>id_hex`, plus `token<TAB>1` rows for tokens that must be rejected.
/// golang/geo s2/cellid_test.go:343-380 and :391-425.
const tokens_tsv = @embedFile("testdata/golang_cellid_tokens.tsv");

/// `id_hex<TAB>lat_deg<TAB>lng_deg`. golang/geo s2/cellid_test.go:176-191.
const latlng_tsv = @embedFile("testdata/golang_cellid_latlng.tsv");

/// Neighbour, parent/child, containment and projection-origin answers; the
/// file's own header names the source of each row kind.
const neighbors_tsv = @embedFile("testdata/upstream_neighbors.tsv");

/// The published Sydney covering and the coordinates and options it used.
/// src/s2/s2region_coverer_test.cc:534-563.
const sydney_txt = @embedFile("testdata/upstream_coverer_sydney.txt");

/// `PolarClosure` answers. src/s2/s2latlng_rect_test.cc:416-423.
const polar_tsv = @embedFile("testdata/upstream_polar_closure.tsv");

/// Normalization and validity answers. golang/geo s2/latlng_test.go:32-92 and
/// src/s2/s2latlng_test.cc:56-57, :132-145, :151-166.
const normalize_tsv = @embedFile("testdata/golang_latlng_normalize.tsv");

/// Iterates the meaningful lines of an embedded fixture: no blanks, no comments.
const Lines = struct {
    text: []const u8,
    index: usize = 0,

    fn next(self: *Lines) ?[]const u8 {
        while (self.index < self.text.len) {
            const rest = self.text[self.index..];
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const line = std.mem.trimEnd(u8, rest[0..end], "\r");
            self.index += if (end == rest.len) rest.len else end + 1;
            if (line.len == 0) continue;
            if (line[0] == '#') continue;
            return line;
        }
        return null;
    }
};

/// Splits a fixture line on tabs into `out`, returning the field count so a
/// caller can assert the exact shape it expects. A line with more fields than
/// `out` holds reports a count larger than `out.len` and writes nothing extra.
fn fields(line: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |field| {
        if (count < out.len) out[count] = field;
        count += 1;
    }
    return count;
}

/// A fixture field that is not a number is a bug in the fixture rather than a
/// behavioural failure, so this stops with the offending field named. The
/// alternative, a silent zero, would turn a broken fixture into a test that
/// passes for the wrong reason.
fn parseF64(text: []const u8) f64 {
    return std.fmt.parseFloat(f64, text) catch
        std.debug.panic("s2 fixture: not a number: {s}", .{text});
}

fn parseU64(text: []const u8) u64 {
    const result = if (std.mem.startsWith(u8, text, "0x"))
        std.fmt.parseUnsigned(u64, text[2..], 16)
    else
        std.fmt.parseUnsigned(u64, text, 10);
    return result catch
        std.debug.panic("s2 fixture: not an integer: {s}", .{text});
}

/// The largest buffer a token or debug string can need. Upstream's token is at
/// most 16 characters (`src/s2/s2cell_id.cc:232`) and its debug string at most
/// `2 + kMaxLevel` (`src/s2/s2cell_id.cc:604-609`); either plus its NUL fits.
const text_buf_len = 64;

fn cellIdLessThan(_: void, a: s2.CellId, b: s2.CellId) bool {
    return a.raw < b.raw;
}

/// Whether `got` holds the same cells as `want` with the same number of
/// occurrences of each. `AppendAllNeighbors` appends a neighbour once per
/// edge or vertex that reaches it, so for a cell at a face vertex the answer
/// is a multiset rather than a set and a repeat is part of it
/// (`src/s2/s2cell_id.h:470-474`).
fn expectSameCellMultiset(got: []const s2.CellId, want: []const s2.CellId) !void {
    try testing.expectEqual(want.len, got.len);
    for (want) |one| {
        var want_count: usize = 0;
        var got_count: usize = 0;
        for (want) |other| {
            if (other.raw == one.raw) want_count += 1;
        }
        for (got) |cell| {
            if (cell.raw == one.raw) got_count += 1;
        }
        try testing.expectEqual(want_count, got_count);
    }
}

// ---------------------------------------------------------------------------
// CellId: the token codec
// ---------------------------------------------------------------------------

test "published token/id pairs decode and encode exactly" {
    var lines = Lines{ .text = tokens_tsv };
    var accepted: usize = 0;
    var rejected: usize = 0;
    while (lines.next()) |line| {
        var parts: [2][]const u8 = undefined;
        try testing.expectEqual(@as(usize, 2), fields(line, &parts));

        if (std.mem.eql(u8, parts[1], "1")) {
            // A token the fixture says is malformed. The facade reports it as
            // InvalidArgument rather than as the id 0: upstream answers a bad
            // token with `S2CellId::None()` (`src/s2/s2cell_id.cc:249-250`) and
            // a caller must not have to tell that from a real cell.
            try testing.expectError(error.InvalidArgument, s2.CellId.fromToken(parts[0]));
            rejected += 1;
            continue;
        }

        const expected = s2.CellId{ .raw = parseU64(parts[1]) };
        const decoded = try s2.CellId.fromToken(parts[0]);
        try testing.expectEqual(expected, decoded);

        var buf: [text_buf_len]u8 = undefined;
        const encoded = try decoded.toToken(&buf);
        try testing.expectEqualStrings(parts[0], encoded);

        // The id in the fixture must also be a cell the library considers real:
        // a table of ids that were all rejected would satisfy the two lines
        // above while proving nothing.
        try testing.expect(decoded.isValid());
        accepted += 1;
    }
    // The counts are asserted so a fixture that stopped being read cannot turn
    // the loop above into a pass.
    try testing.expectEqual(@as(usize, 32), accepted);
    try testing.expectEqual(@as(usize, 5), rejected);
}

test "every face root has the token upstream's id layout implies" {
    // The layout is `id = [face][face_pos]`: three face bits, a one-bit level
    // marker, and the Hilbert position (`src/s2/s2cell_id.h:59-67`), and the
    // codec prints the id in hex with trailing zeros removed
    // (`src/s2/s2cell_id.cc:217-233`). For the six level-0 cells that leaves one
    // hex digit each: 2*face + 1. golang/geo's published table confirms the
    // first two rows ("1" and "3") as raw ids.
    const expected_tokens = [_][]const u8{ "1", "3", "5", "7", "9", "b" };
    for (expected_tokens, 0..) |token, face| {
        const id = try s2.CellId.fromFace(@intCast(face));
        try testing.expect(id.isValid());
        try testing.expect(id.isFace());
        try testing.expectEqual(@as(u8, 0), try id.level());
        try testing.expectEqual(@as(u8, @intCast(face)), try id.face());

        var buf: [text_buf_len]u8 = undefined;
        try testing.expectEqualStrings(token, try id.toToken(&buf));

        const expected_raw: u64 =
            (@as(u64, @intCast(face)) << 61) | (@as(u64, 1) << 60);
        try testing.expectEqual(expected_raw, id.raw);
    }
}

test "a rejected token leaves the caller's output untouched" {
    // The facade hides the output variable, so this asks the bridge the way the
    // facade does and inspects the memory behind it. The return value is not
    // compared here: what matters is that nothing was written, which is a
    // property of the caller's buffer rather than of the status.
    const sentinel: u64 = 0xdead_beef_dead_beef;
    var out: u64 = sentinel;
    _ = s2.c.s2br_cell_from_token("nope!", 5, &out);
    try testing.expectEqual(sentinel, out);

    var too_long: u64 = sentinel;
    // Seventeen hex digits: one past the codec's maximum
    // (`src/s2/s2cell_id.cc:236`).
    _ = s2.c.s2br_cell_from_token("0123456789abcdef0", 17, &too_long);
    try testing.expectEqual(sentinel, too_long);
}

test "a token buffer one byte short is refused and left alone" {
    const id = try s2.CellId.fromToken("89c25");
    var full: [text_buf_len]u8 = undefined;
    const token = try id.toToken(&full);
    try testing.expectEqual(@as(usize, 5), token.len);

    // The token needs its NUL, so a buffer of exactly its length is too short.
    var short: [5]u8 = undefined;
    @memset(&short, 0xAA);
    try testing.expectError(error.BufferTooSmall, id.toToken(&short));
    try testing.expectEqual(@as(u8, 0xAA), short[0]);

    // One byte more than the token, i.e. room for the NUL, is enough.
    var exact: [6]u8 = undefined;
    try testing.expectEqualStrings("89c25", try id.toToken(&exact));
}

test "invalid cell ids are refused instead of answered with a number" {
    try testing.expect(!s2.CellId.none.isValid());
    try testing.expect(!s2.CellId.sentinel.isValid());
    try testing.expect(!(s2.CellId{ .raw = 2 }).isValid());

    // Upstream's own test uses faces 6 and 7 to build invalid ids
    // (src/s2/s2cell_id_test.cc:335-336).
    try testing.expect(!(try s2.CellId.fromFace(6)).isValid());
    try testing.expect(!(try s2.CellId.fromFace(7)).isValid());

    // Every accessor needing a real cell refuses an invalid one, because
    // upstream has no defined answer for it: `level()` reads the lowest set bit
    // (`src/s2/s2cell_id.h:596-601`) and id 0 has none.
    try testing.expectError(error.InvalidArgument, s2.CellId.none.level());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.face());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.pos());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.next());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.prev());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.range());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.toLatLng());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.toPoint());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.sizeSt());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.boundUV());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.edgeNeighbors());
    try testing.expectError(error.InvalidArgument, s2.CellId.none.parent(null));
    try testing.expectError(error.InvalidArgument, s2.CellId.none.childrenCount(5));
    try testing.expectError(error.InvalidArgument, s2.CellId.none.contains(s2.CellId.none));
    try testing.expectError(error.InvalidArgument, s2.CellId.none.intersects(s2.CellId.none));
    try testing.expectError(error.InvalidArgument, s2.Cell.init(s2.CellId.none).exactArea());
}

// ---------------------------------------------------------------------------
// CellId: containment and the id range
// ---------------------------------------------------------------------------

test "published containment and intersection table" {
    var lines = Lines{ .text = neighbors_tsv };
    var rows: usize = 0;
    while (lines.next()) |line| {
        var parts: [8][]const u8 = undefined;
        if (fields(line, &parts) != 6) continue;
        if (!std.mem.eql(u8, parts[0], "contain")) continue;

        const x = s2.CellId{ .raw = parseU64(parts[1]) };
        const y = s2.CellId{ .raw = parseU64(parts[2]) };
        try testing.expectEqual(parts[3][0] == '1', try x.contains(y));
        try testing.expectEqual(parts[4][0] == '1', try y.contains(x));
        try testing.expectEqual(parts[5][0] == '1', try x.intersects(y));
        rows += 1;
    }
    try testing.expectEqual(@as(usize, 10), rows);
}

test "contains agrees with the inclusive id range it is defined by" {
    // `contains` is `b >= a.range_min() and b <= a.range_max()`
    // (`src/s2/s2cell_id.h:290-295`), so the two must agree everywhere, and
    // children must partition their parent.
    const parent = try s2.CellId.fromDebugString("0/0333300");
    const parent_range = try parent.range();
    try testing.expect(parent_range[0].raw < parent_range[1].raw);

    var buf: [16]s2.CellId = undefined;
    const level = (try parent.level()) + 2;
    const kids = try parent.children(level, &buf);
    try testing.expectEqual(@as(usize, 16), kids.len);
    for (kids) |kid| {
        try testing.expect(try parent.contains(kid));
        try testing.expect(try parent.intersects(kid));
        try testing.expect(!try kid.contains(parent));
        const kid_range = try kid.range();
        try testing.expect(parent_range[0].raw <= kid_range[0].raw);
        try testing.expect(kid_range[1].raw <= parent_range[1].raw);
    }

    // Cells of one level are `lsb << 1` apart along the Hilbert curve --
    // `next()` is `id_ + 2 * lsb` (`src/s2/s2cell_id.h:714-716`) -- and one
    // cell's range is `id_ -/+ (lsb - 1)` (`:640-646`), so a cell's
    // range_max and its successor's range_min are exactly two apart.  Two is
    // a property of the layout, not of this cell: a leaf's lsb is 1, so its
    // range is its own id, and leaf ids are odd because a level-30 cell's
    // marker is bit 0 (`kPosBits = 2*kMaxLevel + 1`, `:101`), which is why
    // valid leaves stride by two as well.
    for (kids[1..], kids[0 .. kids.len - 1]) |next, prev| {
        const prev_range = try prev.range();
        const next_range = try next.range();
        try testing.expectEqual(prev_range[1].raw + 2, next_range[0].raw);
    }
}

// ---------------------------------------------------------------------------
// CellId: leaf cells and coordinates
// ---------------------------------------------------------------------------

test "published leaf cell ids round trip with published coordinates" {
    var lines = Lines{ .text = latlng_tsv };
    var rows: usize = 0;
    while (lines.next()) |line| {
        var parts: [3][]const u8 = undefined;
        try testing.expectEqual(@as(usize, 3), fields(line, &parts));

        const expected = s2.CellId{ .raw = parseU64(parts[0]) };
        const lat_deg = parseF64(parts[1]);
        const lng_deg = parseF64(parts[2]);
        const ll = s2.LatLng.fromDegrees(lat_deg, lng_deg);

        // Forward: the leaf cell containing the published coordinate.
        const leaf = try s2.CellId.fromLatLng(ll);
        try testing.expectEqual(expected, leaf);
        try testing.expect(leaf.isLeaf());

        // Backward: the published cell's centre is that coordinate, to the
        // tolerance upstream's own inverse test allows
        // (src/s2/s2cell_id_test.cc:302-315).
        const centre = try expected.toLatLng();
        try testing.expectApproxEqAbs(lat_deg, centre.lat_deg, 1e-8);
        try testing.expectApproxEqAbs(lng_deg, centre.lng_deg, 1e-8);

        // The point form agrees with both.
        const as_point = try ll.toPoint();
        try testing.expectEqual(expected, try s2.CellId.fromPoint(as_point));
        const back = try as_point.toLatLng();
        try testing.expectApproxEqAbs(lat_deg, back.lat_deg, 1e-8);
        try testing.expectApproxEqAbs(lng_deg, back.lng_deg, 1e-8);

        // And the cell really contains the point, in the region sense.
        try testing.expect(try s2.Cell.init(leaf).containsPoint(as_point));
        rows += 1;
    }
    try testing.expectEqual(@as(usize, 14), rows);
}

test "the projection origin is on face 0 and its face cell is centred there" {
    // src/python/s2geometry_test.py:486-487 builds the level-0 cell
    // 0x1000000000000000 under the comment "Level-0 cell (i.e. face) centered at
    // (0, 0)", and src/s2/s2cell_id_test.cc:90-95 requires the leaf cell of
    // (0, 0) to be on face 0.
    const origin = s2.LatLng.fromDegrees(0, 0);
    const leaf = try s2.CellId.fromLatLng(origin);
    try testing.expectEqual(@as(u8, 30), try leaf.level());
    try testing.expectEqual(@as(u8, 0), try leaf.face());

    const face_cell = s2.CellId{ .raw = 0x1000000000000000 };
    try testing.expect(try face_cell.contains(leaf));

    const centre = try face_cell.toLatLng();
    try testing.expectApproxEqAbs(@as(f64, 0), centre.lat_deg, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), centre.lng_deg, 1e-12);

    const point = try origin.toPoint();
    try testing.expect(try s2.Cell.init(leaf).containsPoint(point));
    try testing.expect(try s2.Cell.init(face_cell).containsPoint(point));
}

test "the three positive axes land on the three faces the cube names for them" {
    // A point's face is the one whose axis its largest component follows
    // (`src/s2/s2coords.cc:29-41`), and src/python/s2geometry_test.py:486-487
    // calls face 0 the face centred at (0, 0) -- the +X face. The same scheme
    // fixes +Y on face 1 and +Z on face 2, each checked here against the face
    // cell that must contain the leaf cell.
    const cases = [_]struct { point: [3]f64, face: u8 }{
        .{ .point = .{ 1, 0, 0 }, .face = 0 },
        .{ .point = .{ 0, 1, 0 }, .face = 1 },
        .{ .point = .{ 0, 0, 1 }, .face = 2 },
    };
    for (cases) |case| {
        const point = s2.Point{ .x = case.point[0], .y = case.point[1], .z = case.point[2] };
        const leaf = try s2.CellId.fromPoint(point);
        try testing.expectEqual(case.face, try leaf.face());

        const face_cell = try s2.CellId.fromFace(case.face);
        try testing.expect(try face_cell.contains(leaf));
        try testing.expect(try s2.Cell.init(face_cell).containsPoint(point));
        // The face cell is centred on the axis point itself.
        const face_centre = try face_cell.toPoint();
        try testing.expectApproxEqAbs(point.x, face_centre.x, 1e-15);
        try testing.expectApproxEqAbs(point.y, face_centre.y, 1e-15);
        try testing.expectApproxEqAbs(point.z, face_centre.z, 1e-15);
    }
}

// ---------------------------------------------------------------------------
// CellId: parent, child, siblings
// ---------------------------------------------------------------------------

test "published parent and child positions" {
    var lines = Lines{ .text = neighbors_tsv };
    var rows: usize = 0;
    while (lines.next()) |line| {
        var parts: [10][]const u8 = undefined;
        if (fields(line, &parts) != 9) continue;
        if (!std.mem.eql(u8, parts[0], "poslevel")) continue;

        const face: u8 = @intCast(parseU64(parts[1]));
        const pos_in = parseU64(parts[2]);
        const level: u8 = @intCast(parseU64(parts[3]));
        const cell = try s2.CellId.fromFacePosLevel(face, pos_in, level);

        try testing.expectEqual(face, try cell.face());
        try testing.expectEqual(level, try cell.level());
        try testing.expectEqual(parseU64(parts[4]), try cell.pos());
        try testing.expect(!cell.isLeaf());

        const first_child = try cell.child(0);
        try testing.expectEqual(parseU64(parts[5]), try first_child.pos());
        const grandchild = try first_child.child(0);
        try testing.expectEqual(parseU64(parts[6]), try grandchild.pos());

        const parent = try cell.parent(null);
        try testing.expectEqual(parseU64(parts[7]), try parent.pos());
        try testing.expectEqual(level - 1, try parent.level());
        try testing.expect(try parent.contains(cell));

        const grandparent = try cell.parent(level - 2);
        try testing.expectEqual(parseU64(parts[8]), try grandparent.pos());
        try testing.expectEqual(level - 2, try grandparent.level());
        rows += 1;
    }
    try testing.expectEqual(@as(usize, 1), rows);
}

test "a parent has exactly four children and they partition it" {
    const parent = try s2.CellId.fromDebugString("3/0000");
    const level = (try parent.level()) + 1;

    var kids: [4]s2.CellId = undefined;
    for (&kids, 0..) |*kid, position| {
        kid.* = try parent.child(@intCast(position));
        try testing.expectEqual(level, try kid.level());
        try testing.expect(try parent.contains(kid.*));
    }

    var buf: [4]s2.CellId = undefined;
    const from_iteration = try parent.children(level, &buf);
    try testing.expectEqual(@as(usize, 4), from_iteration.len);
    try testing.expectEqual(@as(usize, 4), try parent.childrenCount(level));

    // `child(position)` and the child iteration order must agree.
    std.mem.sort(s2.CellId, from_iteration, {}, cellIdLessThan);
    std.mem.sort(s2.CellId, &kids, {}, cellIdLessThan);
    for (from_iteration, kids) |a, b| {
        try testing.expectEqual(b.raw, a.raw);
    }

    // A level at or below the cell's own has no descendants to list, which is
    // upstream's precondition for the iterator range
    // (`src/s2/s2cell_id.h:344-347`).
    try testing.expectError(error.InvalidArgument, parent.children(level - 2, &buf));
    try testing.expectError(error.InvalidArgument, parent.childrenCount(level - 2));
    try testing.expectError(error.InvalidArgument, parent.children(31, &buf));

    // A buffer one short must be refused without writing past its end.
    var too_small: [3]s2.CellId = undefined;
    for (&too_small) |*slot| slot.* = .{ .raw = 0xEE };
    try testing.expectError(error.BufferTooSmall, parent.children(level, &too_small));
    try testing.expectEqual(@as(u64, 0xEE), too_small[2].raw);

    // A leaf has no child at all.
    const leaf = try s2.CellId.fromLatLng(.{ .lat_deg = 1, .lng_deg = 2 });
    try testing.expect(leaf.isLeaf());
    try testing.expectError(error.InvalidArgument, leaf.child(0));
}

test "a face cell reports its leaf-cell count without building any of them" {
    // A face cell is at level 0, so every leaf cell on its face is one of its
    // descendants at level 30, and there are 4^30 = 2^60 of them.  No buffer
    // holds 2^60 ids and no walk reaches the end of them, so a count is the
    // only answer that can exist, and it has to be arithmetic: upstream's own
    // `child_begin(level)` and `child_end(level)` are the ends of a run of
    // `next()` steps (`src/s2/s2cell_id.h:344-347`) and `distance_from_begin`
    // is upstream's own count of those steps from the first cell of the level
    // (`src/s2/s2cell_id.h:360-363`), so the difference of the two endpoints
    // is the length of the range.  The test above pins the same agreement
    // between count and walk at four cells; this is the far end of it.
    const leaf_count: u64 = @as(u64, 1) << 60;
    var one_cell: [1]s2.CellId = undefined;

    // Face 5 is the boundary rather than an exception.  Its end of the range is
    // `S2CellId::End(30)`, which is `FromFace(5).child_end(30)`
    // (`src/s2/s2cell_id.h:741-743`) and is one past the last cell of the
    // level rather than a cell of its own; `distance_from_begin` documents
    // that it may be called for exactly that id, which is what makes counting
    // the last face the same arithmetic as counting the first.
    for ([_]u8{ 0, 5 }) |face_index| {
        const face = try s2.CellId.fromFace(face_index);
        if (leaf_count > std.math.maxInt(usize)) {
            // A 32-bit `usize` cannot count 2^60, and the answer there is a
            // refusal: a wrapped count would be a length the caller was told
            // to size a buffer from.
            try testing.expectError(error.InvalidArgument, face.childrenCount(30));
            try testing.expectError(error.InvalidArgument, face.children(30, &one_cell));
        } else {
            try testing.expectEqual(leaf_count, @as(u64, @intCast(try face.childrenCount(30))));
            // A buffer that cannot hold the range is refused before the walk
            // starts, and those bytes are the caller's: nothing may be written
            // into them, and the count left behind is what the caller needs to
            // come back with a buffer that does fit.
            var buf: [4]s2.CellId = undefined;
            for (&buf) |*slot| slot.* = s2.CellId.sentinel;
            try testing.expectError(error.BufferTooSmall, face.children(30, &buf));
            for (buf) |id| try testing.expectEqual(s2.CellId.sentinel.raw, id.raw);
        }
    }

    // A count at a size that can be walked has to agree with the walk, cell for
    // cell: three levels below a level-8 cell is 4^3 = 64 of them, and
    // consecutive entries are consecutive `next()` steps because that is the
    // iterator convention upstream documents for this range.
    const cell = try s2.CellId.fromFacePosLevel(3, 0x0abc, 8);
    var deep: [64]s2.CellId = undefined;
    const walked = try cell.children(11, &deep);
    try testing.expectEqual(@as(usize, 64), walked.len);
    try testing.expectEqual(@as(usize, 64), try cell.childrenCount(11));
    for (walked, 0..) |kid, i| {
        try testing.expectEqual(@as(u8, 11), try kid.level());
        try testing.expect(try cell.contains(kid));
        if (i > 0) try testing.expectEqual((try walked[i - 1].next()).raw, kid.raw);
    }

    // Both ends of the range contract: a cell at its own level has only itself
    // as a descendant, and so has a leaf cell asked for level 30, the finest
    // level there is.
    try testing.expectEqual(@as(usize, 1), try cell.childrenCount(8));
    try testing.expectEqual(cell.raw, (try cell.children(8, &one_cell))[0].raw);
    const leaf = try s2.CellId.fromLatLng(.{ .lat_deg = 1, .lng_deg = 2 });
    try testing.expect(leaf.isLeaf());
    try testing.expectEqual(@as(usize, 1), try leaf.childrenCount(30));
    try testing.expectEqual(leaf.raw, (try leaf.children(30, &one_cell))[0].raw);
}

test "next and prev walk the id space and stop at the ends" {
    const cell = try s2.CellId.fromDebugString("2/033020001100");
    const level = try cell.level();

    const next = try cell.next();
    const prev = try cell.prev();
    try testing.expectEqual(level, try next.level());
    try testing.expectEqual(level, try prev.level());
    try testing.expect(next.raw > cell.raw);
    try testing.expect(prev.raw < cell.raw);
    try testing.expectEqual(cell.raw, (try next.prev()).raw);
    try testing.expectEqual(cell.raw, (try prev.next()).raw);

    // They do not wrap (`src/s2/s2cell_id.h:351-355`): past the ends upstream
    // returns an id that is not a cell, which the facade reports as such rather
    // than as a successful id.
    const first = try s2.CellId.fromFace(0);
    try testing.expect(!(try first.prev()).isValid());
    const last = try s2.CellId.fromFace(5);
    try testing.expect(!(try last.next()).isValid());
}

// ---------------------------------------------------------------------------
// CellId: neighbours
// ---------------------------------------------------------------------------

test "published edge, all-neighbour and vertex-neighbour answers" {
    var lines = Lines{ .text = neighbors_tsv };
    var edge_rows: usize = 0;
    var all_rows: usize = 0;
    var corner_rows: usize = 0;
    while (lines.next()) |line| {
        var parts: [8][]const u8 = undefined;
        const count = fields(line, &parts);
        if (count < 3) continue;

        if (std.mem.eql(u8, parts[0], "edgeface")) {
            try testing.expectEqual(@as(usize, 3), count);
            // The one published row: the edge neighbours of the level-0 cell for
            // face 1 are the level-0 cells for these four faces, in this order
            // (src/s2/s2cell_id_test.cc:572-580).
            const face: u8 = @intCast(parseU64(parts[1]));
            const neighbors = try (try s2.CellId.fromFace(face)).edgeNeighbors();
            var it = std.mem.splitScalar(u8, parts[2], ',');
            var index: usize = 0;
            while (it.next()) |expected_face| : (index += 1) {
                const want: u8 = @intCast(parseU64(expected_face));
                try testing.expect(neighbors[index].isFace());
                try testing.expectEqual(want, try neighbors[index].face());
            }
            try testing.expectEqual(@as(usize, 4), index);
            edge_rows += 1;
        } else if (std.mem.eql(u8, parts[0], "allnbrs")) {
            try testing.expectEqual(@as(usize, 3), count);
            const cell = try s2.CellId.fromDebugString(parts[1]);
            const level = try cell.level();

            var buf: [16]s2.CellId = undefined;
            const got = try cell.allNeighbors(level, &buf);
            try testing.expectEqual(try cell.allNeighborsCount(level), got.len);

            var expected: [16]s2.CellId = undefined;
            var expected_len: usize = 0;
            var it = std.mem.splitScalar(u8, parts[2], ',');
            while (it.next()) |text| : (expected_len += 1) {
                expected[expected_len] = try s2.CellId.fromDebugString(text);
            }
            // Upstream compares with UnorderedElementsAre, so this is a
            // multiset comparison: a repeat in the fixture is a repeat upstream
            // expects, and the corner-cell row really does contain 2/3333 twice.
            try expectSameCellMultiset(got, expected[0..expected_len]);
            all_rows += 1;
        } else if (std.mem.eql(u8, parts[0], "cornervertex")) {
            try testing.expectEqual(@as(usize, 5), count);
            const face: u8 = @intCast(parseU64(parts[1]));
            const pos = parseU64(parts[2]);
            const level: u8 = @intCast(parseU64(parts[3]));
            const cell = try s2.CellId.fromFacePosLevel(face, pos, level);

            var buf: [8]s2.CellId = undefined;
            const got = try cell.vertexNeighbors(0, &buf);
            try testing.expectEqual(@as(usize, 3), got.len);
            try testing.expectEqual(try cell.vertexNeighborsCount(0), got.len);

            // Upstream sorts before comparing (src/s2/s2cell_id_test.cc:637-641).
            std.mem.sort(s2.CellId, got, {}, cellIdLessThan);

            var it = std.mem.splitScalar(u8, parts[4], ',');
            var index: usize = 0;
            while (it.next()) |expected_face| : (index += 1) {
                const want: u8 = @intCast(parseU64(expected_face));
                try testing.expect(got[index].isFace());
                try testing.expectEqual(want, try got[index].face());
            }
            try testing.expectEqual(@as(usize, 3), index);
            corner_rows += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), edge_rows);
    try testing.expectEqual(@as(usize, 3), all_rows);
    try testing.expectEqual(@as(usize, 1), corner_rows);
}

test "neighbour level bounds are refused rather than clamped" {
    // `AppendAllNeighbors` requires `nbr_level >= level()`
    // (`src/s2/s2cell_id.cc:558`) and `GetSizeIJ` checks
    // `0 <= level <= kMaxLevel` (`src/s2/s2cell_id.h:611-614`), so the legal
    // range for the parameter is this cell's own level .. 30 inclusive.
    const cell = try s2.CellId.fromDebugString("2/033020001100");
    const level = try cell.level();
    try testing.expect(level > 0);

    var buf: [16]s2.CellId = undefined;
    try testing.expectError(error.InvalidArgument, cell.allNeighbors(level - 1, &buf));
    try testing.expectError(error.InvalidArgument, cell.allNeighbors(31, &buf));

    // Vertex neighbours need a level strictly below this cell's own
    // (src/s2/s2cell_id.cc:516-518).
    try testing.expectError(error.InvalidArgument, cell.vertexNeighbors(level, &buf));
    try testing.expect(level < 30);

    // Edge neighbours always exist, are always four, and are all distinct
    // (`src/s2/s2cell_id.h:455-459`).
    const edges = try cell.edgeNeighbors();
    for (edges, 0..) |edge, i| {
        try testing.expectEqual(level, try edge.level());
        try testing.expect(edge.raw != cell.raw);
        for (edges[0..i]) |earlier| {
            try testing.expect(earlier.raw != edge.raw);
        }
    }

    // Vertex neighbours at a legal level: three or four of them, the count the
    // bridge reports matching the count it writes.
    const count = try cell.vertexNeighborsCount(level - 1);
    try testing.expect(count == 3 or count == 4);
    const vertex = try cell.vertexNeighbors(level - 1, &buf);
    try testing.expectEqual(count, vertex.len);
    for (vertex) |neighbor| {
        try testing.expectEqual(level - 1, try neighbor.level());
    }
}

test "a leaf cell accepts level 30 as its neighbour level" {
    // kMaxLevel is a legal neighbour level, and it is the top of the range
    // rather than one past it: `GetSizeIJ(kMaxLevel)` is 1
    // (`src/s2/s2cell_id.h:611-614`), which is exactly what the
    // `nbr_size <= size` check in `AppendAllNeighbors` asks for
    // (`src/s2/s2cell_id.cc:569-570`).  `GetSizeIJ`'s own `ABSL_DCHECK` stops
    // at kMaxLevel (`src/s2/s2cell_id.h:612`), and the `level < kMaxLevel`
    // bound that appears upstream (`src/s2/s2cell_id_test.cc:551`) belongs to
    // the test helper, which then calls `child_begin(level + 1)` and so needs
    // one level of headroom that `AppendAllNeighbors` itself does not.
    //
    // The cell is the one upstream names in `TEST(S2CellId, Neighbors)`
    // (`src/s2/s2cell_id_test.cc:610-617`): `FromFacePosLevel(0, 0, kMaxLevel)`,
    // "the corner of faces 0, 4, and 5".  `FromFacePosLevel(0, 0, level)` is
    // `S2CellId(1).parent(level)` (`src/s2/s2cell_id.h:547-551`), which is the
    // face-0 leaf at (i, j) = (0, 0) -- `FromFaceIJ(0, 0, 0)`, whose Hilbert
    // position is zero -- so it sits on the cube vertex where faces 0, 4 and 5
    // meet.  Two consequences follow, and the pinned header states both: a
    // neighbour that leaves the face has to be projected onto an adjacent one,
    // and "for cells adjacent to a face vertex, the same neighbor may be
    // appended more than once" (`src/s2/s2cell_id.h:470-474`).  Only the *edge*
    // neighbours are promised to be distinct (`src/s2/s2cell_id.h:456-458`),
    // so the answer below is pinned as a multiset with its repeat, not a set.
    const leaf = try s2.CellId.fromFacePosLevel(0, 0, s2.max_level);
    try testing.expectEqual(s2.max_level, try leaf.level());

    // `kMaxSize - 1`, the largest valid leaf index (`src/s2/s2coords.h:133-135`).
    const ij_max: u32 = (@as(u32, 1) << s2.max_level) - 1;

    // With size == nbr_size == 1 the loop body runs for k in {-1, 0, 1}
    // (`src/s2/s2cell_id.cc:574-597`): two appends for k < 0, four for the
    // middle k, two more for k >= size, then it breaks.  Eight cells, and the
    // two-pass bridge has to report the same number it writes.
    //
    // The eight cells themselves, read off those three iterations for
    // (i, j) = (0, 0) and then off the projections `FromFaceIJWrap` performs
    // (`src/s2/s2cell_id.cc:458-489`, with `FaceUVtoXYZ` and
    // `ValidFaceXYZtoUV` at `src/s2/s2coords.h:368-383` and `:389-403`): a
    // wrap past u == -1 lands on face 4 and one past v == -1 on face 5,
    // because x is exactly 1 on face 0 and the clamped coordinate is
    // 1 + DBL_EPSILON, and the tie between the two in `LargestAbsComponent`
    // (`src/s2/util/math/vector.h:507-513`) goes to the z component, so the
    // corner wrap lands on face 5 as well.
    //
    // The face-5 leaf at (0, ij_max) is listed twice on purpose: the wrap of
    // the (i-1, j-1) corner and the wrap of the (i, j-1) neighbour both land on
    // it.  That is the repeat the header allows, and asserting distinctness
    // here would be asserting something the pinned source declines to promise.
    const expected_leaf = [_][3]u32{
        .{ 0, 0, 1 },
        .{ 0, 1, 0 },
        .{ 0, 1, 1 },
        .{ 4, ij_max - 1, ij_max },
        .{ 4, ij_max, ij_max },
        .{ 5, 0, ij_max },
        .{ 5, 0, ij_max },
        .{ 5, 1, ij_max },
    };
    var buf: [16]s2.CellId = undefined;
    try testing.expectEqual(@as(usize, 8), try leaf.allNeighborsCount(s2.max_level));
    const neighbors = try leaf.allNeighbors(s2.max_level, &buf);
    try testing.expectEqual(@as(usize, 8), neighbors.len);
    for (neighbors) |neighbor| {
        try testing.expectEqual(s2.max_level, try neighbor.level());
        try testing.expect(neighbor.raw != leaf.raw);
    }
    var want_leaf: [expected_leaf.len]s2.CellId = undefined;
    for (expected_leaf, 0..) |ij, i| {
        want_leaf[i] = try s2.CellId.fromFaceIJ(@intCast(ij[0]), ij[1], ij[2]);
    }
    try expectSameCellMultiset(neighbors, &want_leaf);

    // Four of the eight are known independently of that list: the edge
    // neighbours are documented to be exactly four distinct cells of the
    // cell's own level (`src/s2/s2cell_id.h:455-459`), computed by a different
    // loop in a different place (`src/s2/s2cell_id.cc:499-511`).
    const edges = try leaf.edgeNeighbors();
    for (edges) |edge| {
        try testing.expectEqual(s2.max_level, try edge.level());
        var found = false;
        for (neighbors) |neighbor| {
            if (neighbor.raw == edge.raw) found = true;
        }
        try testing.expect(found);
    }

    // Upstream publishes those four edge neighbours by hand for the corner
    // cell of every level (`src/s2/s2cell_id_test.cc:582-596`), and kMaxLevel
    // is one of the levels it walks, so the same answer is available here for
    // the face-1 corner leaf, in the edge order down, right, up, left.
    const face1_corner = try s2.CellId.fromFaceIJ(1, 0, 0);
    const face1_edges = try face1_corner.edgeNeighbors();
    const published_face1_edges = [_]s2.CellId{
        try s2.CellId.fromFaceIJ(5, ij_max, ij_max),
        try s2.CellId.fromFaceIJ(1, 1, 0),
        try s2.CellId.fromFaceIJ(1, 0, 1),
        try s2.CellId.fromFaceIJ(0, ij_max, 0),
    };
    for (published_face1_edges, 0..) |want, i| {
        try testing.expectEqual(s2.max_level, try face1_edges[i].level());
        try testing.expectEqual(want.raw, face1_edges[i].raw);
    }

    // One level down the same parameter still fits: size is 2 and nbr_size is
    // 1, so k also reaches 2 and the count is 2 + 4 + 4 + 2.  The corner is
    // the same cube vertex, so the same face-5 leaf is appended twice again.
    const expected_parent = [_][3]u32{
        .{ 0, 0, 2 },
        .{ 0, 1, 2 },
        .{ 0, 2, 0 },
        .{ 0, 2, 1 },
        .{ 0, 2, 2 },
        .{ 4, ij_max - 2, ij_max },
        .{ 4, ij_max - 1, ij_max },
        .{ 4, ij_max, ij_max },
        .{ 5, 0, ij_max },
        .{ 5, 0, ij_max },
        .{ 5, 1, ij_max },
        .{ 5, 2, ij_max },
    };
    const parent = try leaf.parent(s2.max_level - 1);
    try testing.expectEqual(s2.max_level - 1, try parent.level());
    try testing.expectEqual(@as(usize, 12), try parent.allNeighborsCount(s2.max_level));
    const up = try parent.allNeighbors(s2.max_level, &buf);
    try testing.expectEqual(@as(usize, 12), up.len);
    for (up) |neighbor| {
        try testing.expectEqual(s2.max_level, try neighbor.level());
        try testing.expect(neighbor.raw != parent.raw);
    }
    var want_parent: [expected_parent.len]s2.CellId = undefined;
    for (expected_parent, 0..) |ij, i| {
        want_parent[i] = try s2.CellId.fromFaceIJ(@intCast(ij[0]), ij[1], ij[2]);
    }
    try expectSameCellMultiset(up, &want_parent);
}

// ---------------------------------------------------------------------------
// Cell geometry and area
// ---------------------------------------------------------------------------

test "the six faces partition the sphere exactly" {
    // The cube's faces tile the unit sphere without overlap, so their exact
    // areas sum to the sphere's area, 4*pi. `S2Cell::ExactArea` is the method
    // upstream documents as accurate to six digits even for a leaf cell
    // (`src/s2/s2cell.h:233-237`).
    var total: f64 = 0;
    for (0..6) |face| {
        const id = try s2.CellId.fromFace(@intCast(face));
        total += try s2.Cell.init(id).exactArea();
    }
    try testing.expectApproxEqRel(4 * std.math.pi, total, 1e-12);
}

test "children tile their parent and the approximation stays within its bound" {
    const cell = try s2.CellId.fromFacePosLevel(2, 0x2468, 6);
    const exact = try s2.Cell.init(cell).exactArea();
    try testing.expect(exact > 0);

    var children_total: f64 = 0;
    var buf: [4]s2.CellId = undefined;
    for (try cell.children(7, &buf)) |kid| {
        children_total += try s2.Cell.init(kid).exactArea();
    }
    try testing.expectApproxEqRel(exact, children_total, 1e-12);

    // The approximation is documented within 3% overall and 0.1% from level 5
    // on (`src/s2/s2cell.h:227-232`); this cell is at level 6.
    const approx = try s2.Cell.init(cell).approxArea();
    try testing.expectApproxEqRel(exact, approx, 1e-3);

    // Cells at one level are not congruent, and nothing here should pretend
    // they are: the cube projection stretches the ones near a face's corners
    // and shrinks the ones near its centre, which is why upstream publishes
    // this as `S2Cell::AverageArea` -- a per-level *average*, documented as
    // accurate only to within a factor of 1.7 rather than as a per-cell
    // value (`src/s2/s2cell.h:220-226`).  Comparing one cell's exact area
    // against it measures which part of a face that cell sits in.
    //
    // The average itself is exact: `S2::kAvgArea` is `4*pi/6`
    // (`src/s2/s2metrics.cc:114`) and `Metric::GetValue` scales by
    // `2^(-2*level)` (`src/s2/s2metrics.h:53`), so the average over the
    // 6 * 4^6 cells of level 6 multiplies back to the sphere's 4*pi.
    const average = try s2.Cell.averageAreaAtLevel(6);
    try testing.expectApproxEqRel(
        4 * std.math.pi,
        average * @as(f64, @floatFromInt(@as(u64, 6) << 12)),
        1e-12,
    );
    try testing.expectError(error.InvalidArgument, s2.Cell.averageAreaAtLevel(31));
}

test "a face cell spans the whole (u,v) square and has four distinct corners" {
    // golang/geo publishes `ijLevelToBoundUV(0, 0, 0)` as the whole square
    // [-1, 1] x [-1, 1] in its TestIJLevelToBoundUV table (s2/cellid_test.go).
    const face = try s2.CellId.fromFace(0);
    const uv = try s2.Cell.init(face).boundUV();
    try testing.expectApproxEqAbs(@as(f64, -1), uv.u_lo, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1), uv.u_hi, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -1), uv.v_lo, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1), uv.v_hi, 1e-15);

    // The same bounds through the id, which is the primitive the cell form
    // delegates to (`src/s2/s2cell.h:240`).
    const id_uv = try face.boundUV();
    try testing.expectEqual(uv.u_lo, id_uv.u_lo);
    try testing.expectEqual(uv.v_hi, id_uv.v_hi);

    var corners: [4]s2.Point = undefined;
    for (&corners, 0..) |*corner, k| {
        corner.* = try s2.Cell.init(face).vertex(@intCast(k));
        try testing.expect(try s2.Cell.init(face).containsPoint(corner.*));
        for (corners[0..k]) |earlier| {
            try testing.expect(!std.meta.eql(earlier, corner.*));
        }
    }

    const centre = try s2.Cell.init(face).center();
    try testing.expect(try s2.Cell.init(face).containsPoint(centre));
    const id_centre = try face.toPoint();
    try testing.expectApproxEqAbs(id_centre.x, centre.x, 1e-15);
    try testing.expectApproxEqAbs(id_centre.y, centre.y, 1e-15);
    try testing.expectApproxEqAbs(id_centre.z, centre.z, 1e-15);

    try testing.expectError(error.InvalidArgument, s2.Cell.init(face).vertex(4));

    // A finer cell's (u,v) span is smaller than its ancestor's, and its size in
    // (s,t) space is smaller too (`src/s2/s2cell_id.h:188-192`).
    const finer = try s2.CellId.fromFacePosLevel(0, 0, 4);
    const finer_uv = try s2.Cell.init(finer).boundUV();
    try testing.expect(finer_uv.u_hi - finer_uv.u_lo < uv.u_hi - uv.u_lo);
    try testing.expect(try finer.sizeSt() < try face.sizeSt());
}

// ---------------------------------------------------------------------------
// LatLng, Point, Cap, LatLngRect
// ---------------------------------------------------------------------------

test "published normalization answers for the poles and the antimeridian" {
    var lines = Lines{ .text = normalize_tsv };
    var norm_rows: usize = 0;
    var valid_rows: usize = 0;
    while (lines.next()) |line| {
        var parts: [5][]const u8 = undefined;
        if (fields(line, &parts) == 0) continue;

        if (std.mem.eql(u8, parts[0], "norm")) {
            const ll = s2.LatLng.fromDegrees(parseF64(parts[1]), parseF64(parts[2]));
            const normalized = try ll.normalized();
            try testing.expectApproxEqAbs(parseF64(parts[3]), normalized.lat_deg, 1e-9);
            try testing.expectApproxEqAbs(parseF64(parts[4]), normalized.lng_deg, 1e-9);

            // Normalization is idempotent and its result is valid, which is what
            // makes it a projection onto the valid range rather than a clamp of
            // one coordinate only.
            const again = try normalized.normalized();
            try testing.expectEqual(normalized.lat_deg, again.lat_deg);
            try testing.expectEqual(normalized.lng_deg, again.lng_deg);
            try testing.expect(normalized.isValid());
            norm_rows += 1;
        } else if (std.mem.eql(u8, parts[0], "valid")) {
            const lat = if (std.mem.eql(u8, parts[1], "inf"))
                std.math.inf(f64)
            else if (std.mem.eql(u8, parts[1], "nan"))
                std.math.nan(f64)
            else
                parseF64(parts[1]);
            const lng = if (std.mem.eql(u8, parts[2], "inf"))
                std.math.inf(f64)
            else if (std.mem.eql(u8, parts[2], "nan"))
                std.math.nan(f64)
            else
                parseF64(parts[2]);

            const ll = s2.LatLng.fromDegrees(lat, lng);
            try testing.expectEqual(parts[3][0] == '1', ll.isValid());

            // A non-finite coordinate cannot be normalized or turned into a
            // point, and the facade says so instead of returning a number.
            if (!std.math.isFinite(lat) or !std.math.isFinite(lng)) {
                try testing.expectError(error.InvalidArgument, ll.normalized());
                try testing.expectError(error.InvalidArgument, ll.toPoint());
                try testing.expectError(error.InvalidArgument, s2.CellId.fromLatLng(ll));
            }
            valid_rows += 1;
        }
    }
    try testing.expectEqual(@as(usize, 9), norm_rows);
    try testing.expectEqual(@as(usize, 10), valid_rows);
}

test "published polar closure answers" {
    var lines = Lines{ .text = polar_tsv };
    var rows: usize = 0;
    while (lines.next()) |line| {
        // Two tab-separated groups: the input rectangle as four
        // space-separated numbers and either the expected rectangle or `full`.
        var groups: [2][]const u8 = undefined;
        try testing.expectEqual(@as(usize, 2), fields(line, &groups));

        var in: [4]f64 = undefined;
        {
            var it = std.mem.tokenizeScalar(u8, groups[0], ' ');
            for (&in) |*value| value.* = parseF64(it.next().?);
        }
        // The fixture's input order is lat_lo lat_hi lng_lo lng_hi, which is how
        // `RectFromDegrees` upstream takes it; the facade's constructor takes
        // the fields in the order a rectangle is written on the sphere.
        const rect = s2.LatLngRect.fromBounds(in[0], in[2], in[1], in[3]);
        const closed = try rect.polarClosure();

        if (std.mem.eql(u8, groups[1], "full")) {
            try testing.expectApproxEqAbs(@as(f64, -90), closed.lat_lo_deg, 1e-12);
            try testing.expectApproxEqAbs(@as(f64, 90), closed.lat_hi_deg, 1e-12);
            try testing.expectApproxEqAbs(@as(f64, -180), closed.lng_lo_deg, 1e-12);
            try testing.expectApproxEqAbs(@as(f64, 180), closed.lng_hi_deg, 1e-12);
            try testing.expectApproxEqRel(4 * std.math.pi, try closed.area(), 1e-12);
        } else {
            var want: [4]f64 = undefined;
            var it = std.mem.tokenizeScalar(u8, groups[1], ' ');
            for (&want) |*value| value.* = parseF64(it.next().?);
            try testing.expectApproxEqAbs(want[0], closed.lat_lo_deg, 1e-12);
            try testing.expectApproxEqAbs(want[1], closed.lat_hi_deg, 1e-12);
            try testing.expectApproxEqAbs(want[2], closed.lng_lo_deg, 1e-12);
            try testing.expectApproxEqAbs(want[3], closed.lng_hi_deg, 1e-12);
        }
        rows += 1;
    }
    try testing.expectEqual(@as(usize, 4), rows);
}

test "an antimeridian rectangle reports itself inverted and still holds its points" {
    // src/s2/s2latlng_rect_test.cc:181-198 builds r1 from (0, -180) to
    // (90, 0) and requires (30, -45) inside and (30, 45) outside.
    //
    // That rectangle is reported as inverted, which is what this test's own
    // name claims and what the stored interval forces.  The longitude half of
    // it is an S1Interval, and the two-argument constructor moves a -pi
    // endpoint to +pi before storing it (`src/s2/s1interval.h:229-232`), so
    // the interval upstream wrote as (-pi, 0) is held as (pi, 0), and
    // `is_inverted` is only `lng_.lo() > lng_.hi()`
    // (`src/s2/s2latlng_rect.h:143-145`).  That is a second spelling of the
    // same 180 degrees of longitude -- the half that straddles the date line
    // -- and not a second region.  The containment and the area below are
    // what shows it: both are computed from the stored interval and do not
    // care which way round its endpoints were written.
    const r1 = s2.LatLngRect.fromBounds(0, -180, 90, 0);
    try testing.expect(try r1.isValid());
    try testing.expect(try r1.isInverted());
    try testing.expect(try r1.containsLatLng(.{ .lat_deg = 30, .lng_deg = -45 }));
    try testing.expect(!try r1.containsLatLng(.{ .lat_deg = 30, .lng_deg = 45 }));
    // The fixture's other two cases are the rectangle's own corners
    // (s2latlng_rect_test.cc:191-194): -180 degrees survives as the stored
    // +180 bound, and the north pole is the latitude bound.
    try testing.expect(try r1.containsLatLng(.{ .lat_deg = 0, .lng_deg = -180 }));
    try testing.expect(try r1.containsLatLng(.{ .lat_deg = 90, .lng_deg = 0 }));
    // Area is `lng().GetLength() * (sin(lat_hi) - sin(lat_lo))`
    // (`src/s2/s2latlng_rect.cc:94-99`): half the longitudes, pi radians of
    // them, and the two sines are 1 and 0, so this is a quarter of the
    // sphere, 4*pi/4 = pi.
    try testing.expectApproxEqRel(std.math.pi, try r1.area(), 1e-12);

    // A rectangle whose longitude bounds run the wrong way is legal and crosses
    // the 180 degree line (`src/s2/s2latlng_rect.h:145`).
    const crossing = s2.LatLngRect.fromBounds(0, 170, 10, -170);
    try testing.expect(try crossing.isValid());
    try testing.expect(try crossing.isInverted());
    // Its strip is 20 degrees of longitude wide and wraps the date line, so it
    // is exactly the two ordinary rectangles either side of it, added.
    try testing.expectApproxEqRel(
        (try s2.LatLngRect.fromBounds(0, 170, 10, 180).area()) +
            (try s2.LatLngRect.fromBounds(0, -180, 10, -170).area()),
        try crossing.area(),
        1e-9,
    );

    // Latitude bounds outside the sphere make a rectangle invalid, and the
    // facade reports that rather than clamping.
    const bad = s2.LatLngRect.fromBounds(-100, 0, 100, 10);
    try testing.expect(!try bad.isValid());
}

test "a cap's area is its height and its complement covers the rest of the sphere" {
    // `S2Cap::GetArea` is `2*pi*height` (`src/s2/s2cap.cc:48-50`), so these two
    // accessors are related by construction rather than independently.
    const cap = s2.Cap{ .center = .{ .lat_deg = 10, .lng_deg = 20 }, .radius_deg = 30 };
    const area = try cap.area();
    const height = try cap.height();
    try testing.expectApproxEqRel(2 * std.math.pi * height, area, 1e-12);

    // A radius of 90 degrees is exactly a hemisphere.
    const hemisphere = s2.Cap{ .center = .{ .lat_deg = 0, .lng_deg = 0 }, .radius_deg = 90 };
    try testing.expectApproxEqRel(2 * std.math.pi, try hemisphere.area(), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), try hemisphere.height(), 1e-12);

    // The complement's area is the rest of the sphere and its centre is the
    // antipode (`src/s2/s2cap.cc:65-71`).
    const complement = try cap.complement();
    try testing.expectApproxEqRel(@as(f64, 150), complement.radius_deg, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -10), complement.center.lat_deg, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -160), complement.center.lng_deg, 1e-9);
    try testing.expectApproxEqRel(4 * std.math.pi - area, try complement.area(), 1e-12);

    // Containment, a degree clear of the rim in both directions.  `Contains`
    // compares an `S1ChordAngle` between the centre and the point with the
    // cap's radius (`src/s2/s2cap.cc:296-299`), so a point whose
    // great-circle distance is exactly the radius is decided by three
    // separately rounded doubles -- the centre, the point and the chord
    // angle -- and which way a tie lands is not this test's to decide.  The
    // two points here are a full degree clear instead: (39, 20) is 29
    // degrees from (10, 20) against a 30 degree radius, and (-60, 20) is 70.
    const centre = try cap.center.toPoint();
    try testing.expect(try cap.containsPoint(centre));
    const inside = try s2.LatLng.fromDegrees(39, 20).toPoint();
    try testing.expect(try cap.containsPoint(inside));
    const outside = try s2.LatLng.fromDegrees(-60, 20).toPoint();
    try testing.expect(!try cap.containsPoint(outside));

    // A cap of zero radius contains exactly its centre, and a cap of negative
    // radius is empty -- upstream's own rule (`src/s2/s2cap.h:70-80`).
    const point_cap = s2.Cap{ .center = .{ .lat_deg = 5, .lng_deg = 6 }, .radius_deg = 0 };
    try testing.expectApproxEqAbs(@as(f64, 0), try point_cap.area(), 1e-15);
    try testing.expect(try point_cap.containsPoint(try point_cap.center.toPoint()));

    // `S2Cap::Contains` REQUIRES a unit-length vector and only debug-asserts
    // it (`src/s2/s2cap.cc:296-300`), so a vector that is not a direction is
    // refused here instead of aborting a Debug build or answering from input
    // upstream never defined. The scaled copy of a point that is inside the
    // cap points in exactly the same direction, so the refusal is a statement
    // about the input rather than about the geometry.
    try testing.expectError(
        error.InvalidArgument,
        cap.containsPoint(.{ .x = centre.x * 5, .y = centre.y * 5, .z = centre.z * 5 }),
    );
    try testing.expectError(
        error.InvalidArgument,
        cap.containsPoint(.{ .x = 0, .y = 0, .z = 0 }),
    );
    try testing.expectError(
        error.InvalidArgument,
        cap.containsPoint(.{ .x = std.math.nan(f64), .y = 0, .z = 1 }),
    );
}

test "two coordinates have the great-circle distance upstream publishes" {
    // golang/geo's TestLatLngDistance table (s2/latlng_test.go, itself based on
    // the C++ S2LatLng distance test) gives these in degrees with stated
    // tolerances.
    const cases = [_]struct { a: s2.LatLng, b: s2.LatLng, want: f64, tol: f64 }{
        .{ .a = .{ .lat_deg = 0, .lng_deg = 0 }, .b = .{ .lat_deg = 45, .lng_deg = 0 }, .want = 45, .tol = 1e-12 },
        .{ .a = .{ .lat_deg = -37, .lng_deg = 25 }, .b = .{ .lat_deg = -66, .lng_deg = -155 }, .want = 77, .tol = 1e-9 },
        .{ .a = .{ .lat_deg = 0, .lng_deg = 165 }, .b = .{ .lat_deg = 0, .lng_deg = -80 }, .want = 115, .tol = 1e-9 },
    };
    for (cases) |case| {
        try testing.expectApproxEqAbs(case.want, try case.a.distanceDeg(case.b), case.tol);
        try testing.expectApproxEqAbs(case.want, try case.b.distanceDeg(case.a), case.tol);
    }

    // The radian constructor and the degree constructor describe the same angle.
    const quarter = s2.LatLng.fromRadians(std.math.pi / 4.0, 0);
    try testing.expectApproxEqAbs(@as(f64, 45), quarter.lat_deg, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), quarter.lng_deg, 1e-12);
}

test "point normalization preserves direction and yields unit length" {
    const scaled = try (s2.Point{ .x = 3, .y = 4, .z = 12 }).normalized();
    const length = @sqrt(
        scaled.x * scaled.x + scaled.y * scaled.y + scaled.z * scaled.z,
    );
    try testing.expectApproxEqAbs(@as(f64, 1), length, 1e-15);
    // 3-4-12 is a Pythagorean quadruple with hypotenuse 13, so each component is
    // exactly its integer over 13.
    try testing.expectApproxEqAbs(@as(f64, 3.0 / 13.0), scaled.x, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 4.0 / 13.0), scaled.y, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 12.0 / 13.0), scaled.z, 1e-15);
}

// ---------------------------------------------------------------------------
// Loop
// ---------------------------------------------------------------------------

test "an octant triangle has exactly pi/2 steradians" {
    // The spherical triangle through the three positive coordinate axes is one
    // octant: its three angles are each pi/2, so by the spherical-excess formula
    // its area is 3*(pi/2) - pi = pi/2, and eight of them tile the sphere's
    // 4*pi. Upstream uses exactly these three points as its octant fixture
    // (src/s2/s2loop_measures_test.cc:238-241, which asserts the perimeter is
    // 3*pi/2).
    var loop = try s2.Loop.init(&[_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    });
    defer loop.deinit();

    try testing.expectEqual(@as(usize, 3), try loop.numVertices());
    try testing.expect(try loop.isValid());
    try testing.expect(try loop.isNormalized());
    try testing.expect(!try loop.isEmpty());
    try testing.expect(!try loop.isFull());
    try testing.expectApproxEqRel(std.math.pi / 2.0, try loop.area(), 1e-12);
    try testing.expectApproxEqRel(std.math.pi / 2.0, try loop.signedArea(), 1e-12);
    try testing.expectApproxEqRel(3 * std.math.pi / 2.0, try loop.perimeterRad(), 1e-12);

    // Containment: the middle of the octant is inside; its mirror in -y is not,
    // because the interior is on the left of the chain (1,0,0) -> (0,1,0).
    const inside = try (s2.Point{ .x = 1, .y = 1, .z = 1 }).normalized();
    try testing.expect(try loop.containsPoint(inside));
    const outside = try (s2.Point{ .x = 1, .y = -1, .z = 1 }).normalized();
    try testing.expect(!try loop.containsPoint(outside));

    // The vertices read back as points and as degrees.
    const v0 = try loop.vertex(0);
    try testing.expectApproxEqAbs(@as(f64, 1), v0.x, 1e-15);
    const v0_ll = try loop.vertexLatLng(0);
    try testing.expectApproxEqAbs(@as(f64, 0), v0_ll.lat_deg, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), v0_ll.lng_deg, 1e-12);
    try testing.expectError(error.InvalidArgument, loop.vertex(3));
    try testing.expectError(error.InvalidArgument, loop.vertexLatLng(3));

    // Inverting gives the complement, whose area is the rest of the sphere and
    // which is no longer normalized; normalizing brings it back.
    try loop.invert();
    try testing.expectApproxEqRel(4 * std.math.pi - std.math.pi / 2.0, try loop.area(), 1e-12);
    try testing.expect(!try loop.isNormalized());
    try testing.expect(try loop.containsPoint(outside));
    try testing.expect(!try loop.containsPoint(inside));
    try loop.normalize();
    try testing.expect(try loop.isNormalized());
    try testing.expectApproxEqRel(std.math.pi / 2.0, try loop.area(), 1e-12);
    try testing.expect(try loop.containsPoint(inside));

    // Calling normalize on an already-normalized loop changes nothing.
    try loop.normalize();
    try testing.expectApproxEqRel(std.math.pi / 2.0, try loop.area(), 1e-12);
}

test "the empty and full loops are exact opposites" {
    var empty = try s2.Loop.empty();
    defer empty.deinit();
    var full = try s2.Loop.full();
    defer full.deinit();

    try testing.expect(try empty.isEmpty());
    try testing.expect(!try empty.isFull());
    try testing.expect(try full.isFull());
    try testing.expect(!try full.isEmpty());

    try testing.expectApproxEqAbs(@as(f64, 0), try empty.area(), 1e-15);
    try testing.expectApproxEqRel(4 * std.math.pi, try full.area(), 1e-12);

    const point = try s2.LatLng.fromDegrees(12, 34).toPoint();
    try testing.expect(!try empty.containsPoint(point));
    try testing.expect(try full.containsPoint(point));

    // Each has the single special vertex upstream defines
    // (`src/s2/s2loop.h:84-87`, `:139-143`).
    try testing.expectEqual(@as(usize, 1), try empty.numVertices());
    try testing.expectEqual(@as(usize, 1), try full.numVertices());
    try testing.expect(try empty.isValid());
    try testing.expect(try full.isValid());
}

test "a loop with a repeated vertex is constructible but invalid" {
    // Upstream fixes the vertex set first and answers validity questions
    // afterwards (`src/s2/s2loop.cc:201-221`), so a bad loop is a loop that
    // reports itself invalid rather than a construction that fails.
    var loop = try s2.Loop.init(&[_][3]f64{
        .{ 1, 0, 0 },
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
    });
    defer loop.deinit();
    try testing.expect(!try loop.isValid());

    // Fewer than three vertices is different: upstream's only one-vertex forms
    // are the special empty and full loops, so the bridge refuses to build one.
    try testing.expectError(error.InvalidArgument, s2.Loop.init(&[_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
    }));
    try testing.expectError(error.InvalidArgument, s2.Polygon.init(&[_][3]f64{}));
}

test "a vertex that is not a direction is refused rather than built" {
    // The octant through the positive axes again, with one component doubled.
    // The triple still looks like a point and is still finite, but its squared
    // norm is 4 rather than 1, and that is the one thing about it upstream
    // cannot be asked about: `S2Loop::Init` computes the loop's origin through
    // `InitOriginAndBound` (`src/s2/s2loop.cc:201-207`, `:271`) and the exact
    // predicate reached from there triages its inputs with
    // `ABSL_DCHECK_LE(a.Norm2(), 2)` (`src/s2/s2predicates.h:394`), which dies
    // in every build that does not define `NDEBUG` -- Zig's Debug and
    // ReleaseSafe among them.  Upstream's own validator says the same about the
    // ordering: the unit-length check "happens too late in debug mode, because
    // S2Loop construction calls s2pred::Sign which expects vertices to be unit
    // length" (`src/s2/s2loop.cc:225-230`).
    //
    // So a vertex that is not a direction is not a loop to be reported invalid
    // afterwards, it is an argument no one upstream can answer for, and each
    // constructor that would hand one to `S2Loop::Init` says so instead.
    const not_a_direction = [_][3]f64{
        .{ 2, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    };
    try testing.expectError(error.InvalidArgument, s2.Loop.init(&not_a_direction));
    try testing.expectError(error.InvalidArgument, s2.Polygon.init(&not_a_direction));
    try testing.expectError(error.InvalidArgument, s2.Polygon.initLoops(&not_a_direction, &.{3}));

    // The zero vector and a non-finite component are the other two ways a
    // triple is not a direction, and upstream's own predicate
    // (`S2::IsUnitLength`, `src/s2/s2pointutil.cc:32-40`) rejects both for the
    // same reason it rejects the one above: a squared norm of 0 is not 1, and
    // the norm of an infinity is not a number at all.  A vertex that is a
    // real direction however its components are written is a different thing
    // again -- (1,0,0) is a perfectly good vertex, and (1/sqrt(3), ...) is the
    // face corner the tests above use -- and still builds.
    try testing.expectError(error.InvalidArgument, s2.Loop.init(&[_][3]f64{
        .{ 0, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    }));
    try testing.expectError(error.InvalidArgument, s2.Polygon.init(&[_][3]f64{
        .{ std.math.inf(f64), 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    }));

    var octant = try s2.Loop.init(&[_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    });
    defer octant.deinit();
    try testing.expect(try octant.isValid());
    try testing.expectApproxEqRel(std.math.pi / 2.0, try octant.area(), 1e-12);
}

test "a vertex count no native counter can hold is refused unvisited" {
    // Upstream counts vertices and loops in `int`. `S2Loop::Init` assigns
    // `vertices.size()` into `S2Loop::num_vertices_` (`src/s2/s2loop.cc:203`,
    // `src/s2/s2loop.h:647`), `S2Polygon::InitLoopProperties` adds those
    // per-loop counts up into `S2Polygon::num_vertices_`
    // (`src/s2/s2polygon.cc:530`, `src/s2/s2polygon.h:887`), and
    // `S2Polygon::num_loops()` narrows `loops_.size()` to an `int`
    // (`src/s2/s2polygon.h:248`). A count a `size_t` holds and an `int` does
    // not would arrive at all three already truncated, and narrowing is
    // silent, so nothing downstream could tell the caller. It is an argument
    // error instead, and the facade reports it as one.
    //
    // The array below is the octant through the positive axes -- the same
    // three vertices the test above builds successfully -- and the counts are
    // impossible ones. That is what makes the ordering observable: the bridge
    // walks the caller's buffer as `xyz + 3 * i`, so a check that came after
    // the walk would step off the end of a three-element array on its first
    // vertex, and a check that came only after the allocation would first try
    // to reserve `too_many` `S2Point`s for a call that cannot succeed. The
    // status is asserted with a null handle: no owned object escapes refusal.
    const octant = [_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    };
    const octant_ref: *const [3][3]f64 = &octant;

    // One past the largest `int`, which is one past every one of those native
    // counters on a 32-bit and a 64-bit target alike.
    const too_many: usize = @as(usize, std.math.maxInt(c_int)) + 1;
    const invalid_argument: s2.c.S2BridgeStatus = s2.c.S2BRIDGE_INVALID_ARGUMENT;

    var loop: ?*s2.c.S2BridgeLoop = null;
    try testing.expectEqual(
        invalid_argument,
        s2.c.s2br_loop_create(@ptrCast(octant_ref), too_many, &loop),
    );
    try testing.expect(loop == null);

    var shell: ?*s2.c.S2BridgePolygon = null;
    try testing.expectEqual(
        invalid_argument,
        s2.c.s2br_polygon_create(@ptrCast(octant_ref), too_many, &shell),
    );
    try testing.expect(shell == null);

    // The nested form has three counts that can each be impossible on their
    // own, so each is exercised separately: the number of loops, one loop's
    // length, and the sum of lengths that are each within range.
    const one_size = [_]usize{octant.len};
    var loops: ?*s2.c.S2BridgePolygon = null;
    try testing.expectEqual(
        invalid_argument,
        s2.c.s2br_polygon_create_loops(
            @ptrCast(octant_ref),
            @ptrCast(&one_size),
            too_many,
            &loops,
        ),
    );
    try testing.expect(loops == null);

    const huge_size = [_]usize{too_many};
    var huge: ?*s2.c.S2BridgePolygon = null;
    try testing.expectEqual(
        invalid_argument,
        s2.c.s2br_polygon_create_loops(
            @ptrCast(octant_ref),
            @ptrCast(&huge_size),
            huge_size.len,
            &huge,
        ),
    );
    try testing.expect(huge == null);

    // Two lengths that each fit an `int`, added together into one that does
    // not: the per-loop check passes and the total is what upstream's `int`
    // could not receive. On a 32-bit target the coordinate span binds before
    // the `int` does and the same argument is refused a step earlier, which is
    // the same answer for the same reason.
    const pair = [_]usize{ too_many / 2, too_many - too_many / 2 };
    var sum: ?*s2.c.S2BridgePolygon = null;
    try testing.expectEqual(
        invalid_argument,
        s2.c.s2br_polygon_create_loops(
            @ptrCast(octant_ref),
            @ptrCast(&pair),
            pair.len,
            &sum,
        ),
    );
    try testing.expect(sum == null);

    // The caller's own buffer is the other half of the bound: a vertex is
    // three doubles, so `3 * n` has to be addressable. `span_limit` is the
    // largest count that is, and so is accepted; the first count past it is
    // not, and is the one to ask about. On a 32-bit target that count still
    // fits an `int`, so it separates the two bounds. On a 64-bit target the
    // span limit is far above `INT_MAX`, the `int` bound has already been
    // tested above, and there is nothing left here to separate.
    const span_limit: usize = std.math.maxInt(usize) / (3 * @sizeOf(f64));
    if (span_limit < @as(usize, std.math.maxInt(c_int))) {
        var span: ?*s2.c.S2BridgeLoop = null;
        try testing.expectEqual(
            invalid_argument,
            s2.c.s2br_loop_create(@ptrCast(octant_ref), span_limit + 1, &span),
        );
        try testing.expect(span == null);
    }
}

test "a vertex or loop index no native index can hold is refused" {
    // `S2Loop::vertex(int i)` (`src/s2/s2loop.h:193`) and `S2Polygon::loop(int
    // k)` (`src/s2/s2polygon.h:259`) take an `int`, while a caller of this
    // facade holds a `usize` and can write down any value one. Narrowing a
    // `maxInt(usize)` index is an "integer does not fit" panic in every mode
    // that checks the conversion, and a different index, silently, in the mode
    // that does not. So a public index past the largest `int` is
    // `InvalidArgument`, decided before the bridge is called at all.
    //
    // The handles below are real and were built through the public facade: the
    // octant through the positive axes, three genuine vertices. Only the index
    // is absurd. Both impossible values are tried because they are different
    // mistakes: one past the largest `int` is a value a caller could have got
    // from a count it never truncated, and `maxInt(usize)` is one no count
    // could have produced and which still has to be refused rather than
    // narrowed.
    const octant = [_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    };
    var loop = try s2.Loop.init(&octant);
    defer loop.deinit();
    var poly = try s2.Polygon.init(&octant);
    defer poly.deinit();

    const one_past: usize = @as(usize, std.math.maxInt(c_int)) + 1;
    const beyond: usize = std.math.maxInt(usize);

    // The vertex index, in the role it has on a loop.
    try testing.expectError(error.InvalidArgument, loop.vertex(one_past));
    try testing.expectError(error.InvalidArgument, loop.vertex(beyond));
    try testing.expectError(error.InvalidArgument, loop.vertexLatLng(one_past));
    try testing.expectError(error.InvalidArgument, loop.vertexLatLng(beyond));

    // The loop index, and the vertex index of one loop, which are two
    // different narrowing points on one call.
    try testing.expectError(error.InvalidArgument, poly.loopNumVertices(one_past));
    try testing.expectError(error.InvalidArgument, poly.loopNumVertices(beyond));
    try testing.expectError(error.InvalidArgument, poly.loopVertex(one_past, 0));
    try testing.expectError(error.InvalidArgument, poly.loopVertex(0, one_past));
    try testing.expectError(error.InvalidArgument, poly.loopVertex(beyond, beyond));
    try testing.expectError(error.InvalidArgument, poly.loopVertexLatLng(one_past, 0));
    try testing.expectError(error.InvalidArgument, poly.loopVertexLatLng(0, one_past));
    try testing.expectError(error.InvalidArgument, poly.loopVertexLatLng(beyond, beyond));

    // The same handles still answer indices they can hold, which is what
    // makes the refusals above a fact about the index and not about handles
    // that reject everything. The octant's first vertex is (1, 0, 0) and its
    // single loop has those same three vertices.
    try testing.expectEqual(@as(usize, 3), try loop.numVertices());
    try testing.expectEqual(@as(f64, 1.0), (try loop.vertex(0)).x);
    try testing.expectEqual(@as(usize, 3), try poly.loopNumVertices(0));
    try testing.expectEqual(@as(usize, 3), try poly.numVertices());
}

// ---------------------------------------------------------------------------
// Polygon
// ---------------------------------------------------------------------------

test "a quadrilateral has twice the area of the triangle that halves it" {
    // The cube face on +x is the square through (1,-1,-1), (1,1,-1),
    // (1,1,1) and (1,-1,1), each divided by sqrt(3).  Those four corners
    // run counter-clockwise seen from outside the face, which is the winding
    // a shell has to have: `(b-a) x (c-b)` for a -> b -> c comes out along
    // +x.  The six cube faces projected onto the unit sphere are a sixth of
    // it each (`src/s2/s2coords.h:21-23`, and `S2::kAvgArea` is that closed
    // form, `src/s2/s2metrics.cc:114-115`), so the square is 4*pi/6
    // steradians and its diagonal from the first corner to the third splits
    // it into two congruent triangles of pi/3 each.
    //
    // The rectangle of longitudes this used to build, (1,0,0), (0,1,0),
    // (-1,0,0), (0,-1,0), has its first and third vertices antipodal, and
    // an edge joining an antipodal pair is one of the degenerate loops
    // `S2Loop::IsValid` rejects (`src/s2/s2loop.cc`), so it could not be
    // asked this question at all.  Nothing here is weakened by the change:
    // the square has four real edges, no two of them antipodal, and its two
    // halves are two different triangles rather than one triangle and its
    // mirror image.
    const corner = 1.0 / @sqrt(@as(f64, 3));
    var quad = try s2.Polygon.init(&[_][3]f64{
        .{ corner, -corner, -corner },
        .{ corner, corner, -corner },
        .{ corner, corner, corner },
        .{ corner, -corner, corner },
    });
    defer quad.deinit();

    var first_half = try s2.Polygon.init(&[_][3]f64{
        .{ corner, -corner, -corner },
        .{ corner, corner, -corner },
        .{ corner, corner, corner },
    });
    defer first_half.deinit();
    var second_half = try s2.Polygon.init(&[_][3]f64{
        .{ corner, -corner, -corner },
        .{ corner, corner, corner },
        .{ corner, -corner, corner },
    });
    defer second_half.deinit();

    try testing.expect(try quad.isValid());
    try testing.expect(try first_half.isValid());
    try testing.expect(try second_half.isValid());
    try testing.expectEqual(@as(usize, 1), try quad.numLoops());
    try testing.expectEqual(@as(usize, 4), try quad.numVertices());
    try testing.expectEqual(@as(usize, 3), try first_half.numVertices());
    try testing.expectEqual(@as(usize, 4), try quad.loopNumVertices(0));
    try testing.expectEqual(@as(usize, 3), try first_half.loopNumVertices(0));

    // Each half is half of the square twice over: once because a diagonal
    // splits a square into congruent pieces, and once because the square is
    // a cube face, which the six of them tile to 4*pi.
    const face_area: f64 = 4.0 * std.math.pi / 6.0;
    try testing.expectApproxEqRel(face_area, try quad.area(), 1e-9);
    try testing.expectApproxEqRel(face_area / 2, try first_half.area(), 1e-9);
    try testing.expectApproxEqRel(face_area / 2, try second_half.area(), 1e-9);
    try testing.expectApproxEqRel((try first_half.area()) * 2, try quad.area(), 1e-9);
    try testing.expectApproxEqRel(try first_half.area(), try second_half.area(), 1e-12);

    const first = try quad.loopVertex(0, 0);
    try testing.expectApproxEqAbs(corner, first.x, 1e-15);
    try testing.expectApproxEqAbs(-corner, first.y, 1e-15);
    try testing.expectApproxEqAbs(-corner, first.z, 1e-15);
    // That vertex is the cube corner (1,-1,-1)/sqrt(3), so its latitude is
    // the arcsine of its z coordinate and its longitude the arc tangent of
    // two equal coordinates in the fourth quadrant.
    const first_ll = try quad.loopVertexLatLng(0, 0);
    try testing.expectApproxEqAbs(
        -std.math.asin(corner) * (180.0 / std.math.pi),
        first_ll.lat_deg,
        1e-12,
    );
    try testing.expectApproxEqAbs(@as(f64, -45), first_ll.lng_deg, 1e-12);
    try testing.expectError(error.InvalidArgument, quad.loopVertex(0, 4));
    try testing.expectError(error.InvalidArgument, quad.loopVertex(1, 0));
    try testing.expectError(error.InvalidArgument, quad.loopNumVertices(1));
    try testing.expectError(error.InvalidArgument, quad.loopVertexLatLng(0, 9));

    // The face centre is inside the square and the far side of the sphere is
    // not.  The latitude/longitude spellings say the same: (0,0) is the
    // centre of face 0, and (0, 180) is the centre of face 3, which is the
    // far side of the sphere from it.
    try testing.expect(try quad.containsPoint(.{ .x = 1, .y = 0, .z = 0 }));
    try testing.expect(!try quad.containsPoint(.{ .x = -1, .y = 0, .z = 0 }));
    try testing.expect(try quad.containsLatLng(.{ .lat_deg = 0, .lng_deg = 0 }));
    try testing.expect(!try quad.containsLatLng(.{ .lat_deg = 0, .lng_deg = 180 }));

    // A polygon requires the same unit-length direction a cap does
    // (`src/s2/s2polygon.h:653`, `src/s2/s2polygon.cc:704-706`), so the same
    // inputs are refused, and the latitude/longitude spelling is refused for
    // the coordinate it cannot normalise.
    try testing.expectError(
        error.InvalidArgument,
        quad.containsPoint(.{ .x = 0, .y = 0, .z = 0 }),
    );
    try testing.expectError(
        error.InvalidArgument,
        quad.containsPoint(.{ .x = std.math.inf(f64), .y = 0, .z = 0 }),
    );
    try testing.expectError(
        error.InvalidArgument,
        quad.containsLatLng(.{ .lat_deg = std.math.nan(f64), .lng_deg = 0 }),
    );

    // The square is unchanged by (y,z) -> (-y,-z), so its centroid is the
    // face centre, which is latitude and longitude zero.
    const centroid = try quad.centroidLatLng();
    try testing.expectApproxEqAbs(@as(f64, 0), centroid.lat_deg, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), centroid.lng_deg, 1e-9);
}

test "the empty and full polygons complement each other" {
    var empty = try s2.Polygon.empty();
    defer empty.deinit();
    var full = try s2.Polygon.full();
    defer full.deinit();

    try testing.expect(try empty.isEmpty());
    try testing.expect(try full.isFull());
    try testing.expect(!try full.isEmpty());
    try testing.expect(!try empty.isFull());
    try testing.expectApproxEqAbs(@as(f64, 0), try empty.area(), 1e-15);
    try testing.expectApproxEqRel(4 * std.math.pi, try full.area(), 1e-12);

    // The complement of the empty polygon covers the whole sphere and the
    // complement of the full one covers nothing. The assertions are on area and
    // containment rather than on `isFull`/`isEmpty`, because those are
    // statements about how the boolean operation happens to represent the
    // result (`src/s2/s2polygon.h:241-245`) and this is a statement about the
    // region.
    var empty_complement = try empty.complement();
    defer empty_complement.deinit();
    try testing.expectApproxEqRel(4 * std.math.pi, try empty_complement.area(), 1e-12);
    try testing.expect(try empty_complement.containsPoint(.{ .x = 0, .y = 0, .z = 1 }));
    try testing.expect(try empty_complement.containsPoint(.{ .x = 0, .y = 0, .z = -1 }));

    var full_complement = try full.complement();
    defer full_complement.deinit();
    try testing.expectApproxEqAbs(@as(f64, 0), try full_complement.area(), 1e-15);
    try testing.expect(!try full_complement.containsPoint(.{ .x = 0, .y = 0, .z = 1 }));
}

test "union and intersection of two overlapping wedges give pi/4 and 3pi/4" {
    // Two spherical wedges of solid angle pi/2 each that genuinely overlap.
    // The first is the octant through the positive axes, which covers azimuth
    // 0 to 90 north of the equator; the second is that octant turned 45
    // degrees about the +z axis, so it covers azimuth 45 to 135.  They share
    // exactly the 45-degree-wide wedge between the meridians at 45 and 90.
    //
    // Both vertex lists run counter-clockwise seen from outside, which is what
    // a shell has to be. `S2Polygon::Init` hands the loop it is given straight
    // through (`src/s2/s2polygon.cc:406-414`) rather than normalizing it, and
    // `S2::GetArea` turns a negative signed area into `area + 4*pi`
    // (`src/s2/s2loop_measures.cc:51-55`), so a clockwise list would be
    // measured as the whole sphere minus the triangle rather than the
    // triangle.
    //
    // `sqrt(0.5)` is not exactly unit length in binary -- its square is
    // 0.5000000000000001, so the rotated wedge's squared norm is
    // 1.0000000000000002 -- which is inside the `5 * DBL_EPSILON` a direction
    // has to satisfy (`S2::IsUnitLength`, `src/s2/s2pointutil.cc:32-40`).
    //
    // The four areas come from spherical excess, `sum of interior angles -
    // (n - 2)*pi`, and not from a measurement:
    //   * each wedge has three right angles: 3*pi/2 - pi = pi/2;
    //   * the intersection is bounded by the equator, the meridian at 45 and
    //     the meridian at 90, with interior angles pi/2, pi/2 and the pi/4
    //     between the two meridians at the pole: 5*pi/4 - pi = pi/4;
    //   * the union is bounded by the equator from azimuth 0 to 135 and by
    //     the meridian at 135, with interior angles pi/2, pi/2 and the 3*pi/4
    //     between the meridians at 0 and 135 at the pole: 7*pi/4 - pi = 3*pi/4.
    const diagonal = @sqrt(0.5);
    var xy = try s2.Polygon.init(&[_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    });
    defer xy.deinit();
    var rotated = try s2.Polygon.init(&[_][3]f64{
        .{ diagonal, diagonal, 0 },
        .{ -diagonal, diagonal, 0 },
        .{ 0, 0, 1 },
    });
    defer rotated.deinit();

    try testing.expect(try xy.isValid());
    try testing.expect(try rotated.isValid());
    try testing.expectApproxEqRel(std.math.pi / 2.0, try xy.area(), 1e-12);
    try testing.expectApproxEqRel(std.math.pi / 2.0, try rotated.area(), 1e-12);

    var both = try s2.Polygon.intersection(xy, rotated);
    defer both.deinit();
    var either = try s2.Polygon.unite(xy, rotated);
    defer either.deinit();

    // The two operations, against the areas derived above rather than against
    // whatever the library happened to produce.
    try testing.expectApproxEqRel(std.math.pi / 4.0, try both.area(), 1e-9);
    try testing.expectApproxEqRel(3 * std.math.pi / 4.0, try either.area(), 1e-9);

    // Points that decide the relationships, all strictly inside or outside so
    // that no answer depends on where a boundary point is counted: azimuth 22.5
    // is in the first wedge only, 112.5 in the second only, 67.5 in both, and
    // the south pole in neither.
    const only_xy = try s2.LatLng.fromDegrees(45, 22.5).toPoint();
    const only_rotated = try s2.LatLng.fromDegrees(45, 112.5).toPoint();
    const in_both = try s2.LatLng.fromDegrees(45, 67.5).toPoint();
    const in_neither = s2.Point{ .x = 0, .y = 0, .z = -1 };

    try testing.expect(try xy.containsPoint(in_both));
    try testing.expect(try rotated.containsPoint(in_both));
    try testing.expect(try both.containsPoint(in_both));
    try testing.expect(try either.containsPoint(in_both));

    try testing.expect(try xy.containsPoint(only_xy));
    try testing.expect(!try rotated.containsPoint(only_xy));
    try testing.expect(!try both.containsPoint(only_xy));
    try testing.expect(try either.containsPoint(only_xy));

    try testing.expect(!try xy.containsPoint(only_rotated));
    try testing.expect(try rotated.containsPoint(only_rotated));
    try testing.expect(!try both.containsPoint(only_rotated));
    try testing.expect(try either.containsPoint(only_rotated));

    try testing.expect(!try xy.containsPoint(in_neither));
    try testing.expect(!try rotated.containsPoint(in_neither));
    try testing.expect(!try both.containsPoint(in_neither));
    try testing.expect(!try either.containsPoint(in_neither));

    // Inclusion and exclusion as a supplement: |A| + |B| = |A union B| + |A
    // intersect B| holds for every measure, so it holds here too.
    try testing.expectApproxEqRel(
        (try xy.area()) + (try rotated.area()),
        (try either.area()) + (try both.area()),
        1e-9,
    );
    // The intersection is a proper subset of each, so it is smaller than
    // either, and the union is larger than either and smaller than the sphere.
    try testing.expect((try both.area()) < (try xy.area()));
    try testing.expect((try both.area()) < (try rotated.area()));
    try testing.expect((try both.area()) > 0);
    try testing.expect((try either.area()) > (try xy.area()));
    try testing.expect((try either.area()) > (try rotated.area()));
    try testing.expect((try either.area()) < 4 * std.math.pi);

    // The inputs are untouched by both operations.
    try testing.expectApproxEqRel(std.math.pi / 2.0, try xy.area(), 1e-12);
    try testing.expectApproxEqRel(std.math.pi / 2.0, try rotated.area(), 1e-12);
}

test "a boolean operation refuses an operand its own validator rejects" {
    // The square on cube face 0 with its four corners in an order that makes a
    // bow tie: (1,-1,-1), (1,1,1), (1,1,-1), (1,-1,1), each over sqrt(3).  The
    // first edge is one diagonal of the square and the third is the other, so
    // they cross at the face centre and the loop is not simple.  Every vertex
    // is a unit-length direction, which is why this polygon is built at all:
    // the crossing is topology, and topology is what `isValid` reports.
    const corner = 1.0 / @sqrt(@as(f64, 3));
    var bowtie = try s2.Polygon.init(&[_][3]f64{
        .{ corner, -corner, -corner },
        .{ corner, corner, corner },
        .{ corner, corner, -corner },
        .{ corner, -corner, corner },
    });
    defer bowtie.deinit();
    try testing.expect(!try bowtie.isValid());

    // It is also not something a boolean operation can be asked about.
    // Upstream's condition is explicit -- the `S2Error` overloads "should never
    // return an error provided that both input polygons are valid"
    // (`src/s2/s2polygon.h:385-388`) -- and the operation has no answer for
    // one that is not: it reads both operands as shape indexes
    // (`src/s2/s2polygon.cc:936-943`) and builds the result's loops stamped
    // with the *result's* debug override
    // (`src/s2/s2builderutil_s2polygon_layer.cc:99`), so a bad chain comes back
    // as the fatal `ABSL_CHECK(IsValid())` of `S2Loop::InitIndex`
    // (`src/s2/s2loop.cc:353-359`) rather than as a status.  The refusal is
    // therefore made before the operation runs, and it is the same
    // `InvalidArgument` any other rejected argument gets -- not a result, and
    // not an `Internal` the caller would read as "upstream failed on valid
    // input", which is what it never is.
    var wedge = try s2.Polygon.init(&[_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    });
    defer wedge.deinit();
    try testing.expect(try wedge.isValid());

    try testing.expectError(error.InvalidArgument, s2.Polygon.unite(bowtie, wedge));
    try testing.expectError(error.InvalidArgument, s2.Polygon.unite(wedge, bowtie));
    try testing.expectError(error.InvalidArgument, s2.Polygon.intersection(bowtie, wedge));
    try testing.expectError(error.InvalidArgument, s2.Polygon.intersection(bowtie, bowtie));

    // Every refusal left both operands exactly as it found them: the bow tie
    // is still the invalid polygon it was, and the wedge is still the octant of
    // pi/2 steradians that three right angles make it.  So what was refused is
    // the operand and not the operation -- a valid pair is unioned and
    // intersected successfully above, against areas derived from spherical
    // excess rather than from whatever the library produced.
    try testing.expect(!try bowtie.isValid());
    try testing.expect(try wedge.isValid());
    try testing.expectApproxEqRel(std.math.pi / 2.0, try wedge.area(), 1e-12);
}

test "a polygon with a hole subtracts the hole" {
    // A cap-like quadrilateral around the north pole, and a smaller one inside
    // it. Every vertex is a real latitude/longitude point converted to a
    // direction, and the two loops are both counter-clockwise seen from the
    // pole, so `InitNested` works out which is the shell and which is the hole
    // from the nesting depth alone (`src/s2/s2polygon.h:184-189`).
    var shell: [4][3]f64 = undefined;
    var hole: [4][3]f64 = undefined;
    const longitudes = [_]f64{ 0, 90, 180, -90 };
    for (&shell, longitudes) |*vertex, lng_deg| {
        const p = try s2.LatLng.fromDegrees(45, lng_deg).toPoint();
        vertex.* = .{ p.x, p.y, p.z };
    }
    for (&hole, longitudes) |*vertex, lng_deg| {
        const p = try s2.LatLng.fromDegrees(80, lng_deg).toPoint();
        vertex.* = .{ p.x, p.y, p.z };
    }

    var combined: [8][3]f64 = undefined;
    @memcpy(combined[0..4], &shell);
    @memcpy(combined[4..8], &hole);

    var shell_only = try s2.Polygon.init(&shell);
    defer shell_only.deinit();
    var hole_only = try s2.Polygon.init(&hole);
    defer hole_only.deinit();
    var with_hole = try s2.Polygon.initLoops(&combined, &.{ 4, 4 });
    defer with_hole.deinit();

    try testing.expect(try shell_only.isValid());
    try testing.expect(try hole_only.isValid());
    try testing.expect(try with_hole.isValid());
    try testing.expectEqual(@as(usize, 2), try with_hole.numLoops());
    try testing.expectEqual(@as(usize, 8), try with_hole.numVertices());
    try testing.expectEqual(@as(usize, 4), try with_hole.loopNumVertices(0));
    try testing.expectEqual(@as(usize, 4), try with_hole.loopNumVertices(1));

    // The hole is the smaller cap, so the difference is the shell minus it.
    const shell_area = try shell_only.area();
    const hole_area = try hole_only.area();
    try testing.expect(shell_area > hole_area);
    try testing.expectApproxEqRel(shell_area - hole_area, try with_hole.area(), 1e-9);

    // The north pole is inside the hole, so it is outside the holed polygon,
    // while it is inside the bare shell and inside the bare hole.
    const north = s2.Point{ .x = 0, .y = 0, .z = 1 };
    try testing.expect(try shell_only.containsPoint(north));
    try testing.expect(try hole_only.containsPoint(north));
    try testing.expect(!try with_hole.containsPoint(north));

    // A point below the hole but inside the shell is in the holed polygon.
    const between = try s2.LatLng.fromDegrees(60, 0).toPoint();
    try testing.expect(try shell_only.containsPoint(between));
    try testing.expect(!try hole_only.containsPoint(between));
    try testing.expect(try with_hole.containsPoint(between));

    // A length list that does not describe the vertex array is a caller error.
    try testing.expectError(error.InvalidArgument, s2.Polygon.initLoops(&combined, &.{ 4, 3 }));
    try testing.expectError(error.InvalidArgument, s2.Polygon.initLoops(&combined, &.{4}));
}

test "a length list that cannot be summed is refused, not overflowed" {
    // `Polygon.initLoops` totals the caller's lengths so it can check the sum
    // against the vertex array it was handed. The lengths are `usize`, and a
    // caller can perfectly well name one near the end of that range without
    // it being a vertex count the library could accept. Adding those wraps,
    // so the sum is guarded and the argument is refused instead: an
    // `InvalidArgument` a caller can handle, rather than a trap in Debug and
    // ReleaseSafe and a silently wrong total in ReleaseFast.
    //
    // The vertices below are real -- the octant through the positive axes --
    // and are never reached: the lengths are refused before the sum is
    // compared with them, and before the bridge is called at all, so no handle
    // is produced. The two cases differ in where the overflow would land, and
    // both matter: the first element is itself the impossible length, and the
    // second is a legal length that has already been added when the
    // impossible one arrives, so the guard is tested against a non-zero
    // running total.
    const octant = [_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    };
    try testing.expectError(
        error.InvalidArgument,
        s2.Polygon.initLoops(&octant, &.{ std.math.maxInt(usize), 3 }),
    );
    try testing.expectError(
        error.InvalidArgument,
        s2.Polygon.initLoops(&octant, &.{ 3, std.math.maxInt(usize) }),
    );
}

// ---------------------------------------------------------------------------
// Region covering
// ---------------------------------------------------------------------------

test "the coverer picks a published cell for a real Sydney coordinate" {
    // See testdata/upstream_coverer_sydney.txt. The coordinates, the options and
    // the 42 tokens are the ones src/s2/s2region_coverer_test.cc's
    // JavaCcConsistency test publishes for a polyline through the two points.
    // A cap of zero radius is a single point, so its covering at level 22 with
    // no cell-count limit is the one level-22 cell containing that point, and
    // that cell must be one of the published tokens.
    const points = [_]s2.LatLng{
        .{ .lat_deg = -33.8663457, .lng_deg = 151.1960891 },
        .{ .lat_deg = -33.866094000000004, .lng_deg = 151.19517439999998 },
    };

    var published: [64]s2.CellId = undefined;
    var published_len: usize = 0;
    {
        var lines = Lines{ .text = sydney_txt };
        while (lines.next()) |line| : (published_len += 1) {
            published[published_len] = try s2.CellId.fromToken(line);
        }
    }
    try testing.expectEqual(@as(usize, 42), published_len);

    const coverer = s2.Coverer{
        .min_level = 0,
        .max_level = 22,
        .level_mod = 1,
        .max_cells = std.math.maxInt(i32),
    };

    for (points) |point| {
        const cap = s2.Cap{ .center = point, .radius_deg = 0 };
        try testing.expectEqual(@as(usize, 1), try coverer.coveringCapCount(cap));

        var buf: [4]s2.CellId = undefined;
        const covering = try coverer.coveringCap(cap, &buf);
        try testing.expectEqual(@as(usize, 1), covering.len);
        try testing.expectEqual(@as(u8, 22), try covering[0].level());

        var found = false;
        for (published[0..published_len]) |candidate| {
            if (candidate.raw == covering[0].raw) found = true;
        }
        try testing.expect(found);

        // The chosen cell really does contain the coordinate.
        try testing.expect(try s2.Cell.init(covering[0]).containsPoint(
            try point.toPoint(),
        ));
    }

    // An empty buffer is refused and reports nothing as written.
    var empty_buf: [1]s2.CellId = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        coverer.coveringCap(.{ .center = points[0], .radius_deg = 0 }, empty_buf[0..0]),
    );
}

test "the covering of a cell is exactly that cell" {
    // Upstream's own fixture, with max_cells set to 1
    // (src/s2/s2region_coverer_test.cc:72-87).
    const cell = try s2.CellId.fromDebugString("2/033020001100");
    const coverer = s2.Coverer{ .max_cells = 1 };

    var buf: [8]s2.CellId = undefined;
    const covering = try coverer.coveringCell(cell, &buf);
    try testing.expectEqual(@as(usize, 1), covering.len);
    try testing.expectEqual(cell.raw, covering[0].raw);
    try testing.expectEqual(@as(usize, 1), try coverer.coveringCellCount(cell));
}

test "a covering obeys its options and actually covers its region" {
    // Upstream states the contract for a covering: every level is within
    // min_level..max_level and congruent to min_level modulo level_mod, and the
    // union of the cells contains the region
    // (src/s2/s2region_coverer.h:44-62, :113-160).
    const cap = s2.Cap{
        .center = .{ .lat_deg = 47.38, .lng_deg = 8.54 },
        .radius_deg = 0.5,
    };
    const coverer = s2.Coverer{
        .min_level = 2,
        .max_level = 18,
        .level_mod = 2,
        .max_cells = 8,
    };

    const required = try coverer.coveringCapCount(cap);
    try testing.expect(required >= 1);
    var buf: [64]s2.CellId = undefined;
    try testing.expect(required <= buf.len);
    const covering = try coverer.coveringCap(cap, &buf);
    try testing.expectEqual(required, covering.len);
    // This region does not touch six faces, so the requested bound holds; the
    // documented exception is for a region that needs the six face cells
    // (src/s2/s2region_coverer.h:78-84).
    try testing.expect(covering.len <= 8);

    const centre = try cap.center.toPoint();
    var covered = false;
    for (covering) |cell| {
        const level = try cell.level();
        try testing.expect(level >= coverer.min_level);
        try testing.expect(level <= coverer.max_level);
        try testing.expectEqual(
            @as(u8, 0),
            (level - coverer.min_level) % coverer.level_mod,
        );
        if (try s2.Cell.init(cell).containsPoint(centre)) covered = true;
    }
    try testing.expect(covered);

    // Contradictory options are refused here even though upstream only
    // debug-asserts them (`src/s2/s2region_coverer.cc:44-47`, `:60-83`), because
    // a debug assert is gone in ReleaseFast.
    try testing.expectError(error.InvalidArgument, (s2.Coverer{
        .min_level = 10,
        .max_level = 4,
    }).coveringCapCount(cap));
    try testing.expectError(error.InvalidArgument, (s2.Coverer{ .level_mod = 0 }).coveringCapCount(cap));
    try testing.expectError(error.InvalidArgument, (s2.Coverer{ .level_mod = 4 }).coveringCapCount(cap));
    try testing.expectError(error.InvalidArgument, (s2.Coverer{ .max_cells = 0 }).coveringCapCount(cap));
    try testing.expectError(error.InvalidArgument, (s2.Coverer{ .max_level = 31 }).coveringCapCount(cap));

    // A max_cells wider than the int32_t the bridge carries
    // (`zig/bridge.h:565`) is refused as an ordinary bad argument, so the
    // conversion cannot trap the call in Debug or ReleaseSafe.
    try testing.expectError(error.InvalidArgument, (s2.Coverer{
        .max_cells = @as(u32, @intCast(std.math.maxInt(c_int))) + 1,
    }).coveringCapCount(cap));

    // A cap that is not finite has no covering and is refused before any
    // coverer runs.
    try testing.expectError(
        error.InvalidArgument,
        coverer.coveringCapCount(.{
            .center = .{ .lat_deg = std.math.nan(f64), .lng_deg = 0 },
            .radius_deg = 1,
        }),
    );
}

test "coverings of a rectangle and of a polygon cover a point inside them" {
    var poly = try s2.Polygon.init(&[_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    });
    defer poly.deinit();

    const rect = s2.LatLngRect.fromBounds(0, 0, 90, 90);
    const coverer = s2.Coverer{ .max_cells = 16 };

    var rect_buf: [256]s2.CellId = undefined;
    const rect_covering = try coverer.coveringRect(rect, &rect_buf);
    try testing.expectEqual(try coverer.coveringRectCount(rect), rect_covering.len);
    try testing.expect(rect_covering.len > 0);

    var poly_buf: [256]s2.CellId = undefined;
    const poly_covering = try coverer.coveringPolygon(poly, &poly_buf);
    try testing.expectEqual(try coverer.coveringPolygonCount(poly), poly_covering.len);
    try testing.expect(poly_covering.len > 0);

    // A point in both regions must be inside at least one cell of each covering.
    const inside = try (s2.Point{ .x = 1, .y = 1, .z = 1 }).normalized();
    try testing.expect(try poly.containsPoint(inside));
    try testing.expect(try rect.containsLatLng(try inside.toLatLng()));

    var poly_covered = false;
    for (poly_covering) |cell| {
        if (try s2.Cell.init(cell).containsPoint(inside)) poly_covered = true;
    }
    try testing.expect(poly_covered);

    var rect_covered = false;
    for (rect_covering) |cell| {
        if (try s2.Cell.init(cell).containsPoint(inside)) rect_covered = true;
    }
    try testing.expect(rect_covered);

    // The point is the centre of the octant, so it is also inside the polygon
    // as an S2LatLng, which is the region query rather than the point query.
    try testing.expect(try poly.containsLatLng(.{ .lat_deg = 35.264389, .lng_deg = 45 }));
}

// ---------------------------------------------------------------------------
// Units and identities that must not drift
// ---------------------------------------------------------------------------

test "every unit in the facade is the one its name says" {
    // A quarter turn is pi/2 radians, which is 90 degrees. Reading one as the
    // other would be off by a factor of 57.3. The radian constructor is the
    // one that has to do a conversion here; the degree constructor only names
    // the unit its fields already carry.
    try testing.expectApproxEqAbs(
        @as(f64, 90),
        s2.LatLng.fromRadians(std.math.pi / 2.0, 0).lat_deg,
        1e-12,
    );

    // A face cell is a sixth of the sphere in steradians.
    const face_area = try s2.Cell.init(try s2.CellId.fromFace(0)).exactArea();
    try testing.expectApproxEqRel((4 * std.math.pi) / 6.0, face_area, 1e-12);

    // The octant's perimeter is pi/2 radians per edge, i.e. 270 degrees total.
    var loop = try s2.Loop.init(&[_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    });
    defer loop.deinit();
    const radians = try loop.perimeterRad();
    try testing.expectApproxEqRel(3 * std.math.pi / 2.0, radians, 1e-12);
    try testing.expectApproxEqRel(@as(f64, 270), radians * (180.0 / std.math.pi), 1e-9);
}

test "a cell can be rebuilt from its own face, position and level" {
    // `S2CellId::FromFacePosLevel` is upstream's inverse of `face()`, `pos()`
    // and `level()` taken together (`src/s2/s2cell_id.h:543-550`), so applying
    // it to a cell's own three accessors returns the cell. That is an identity
    // about the accessors, not a copy of anything.
    const ids = [_][]const u8{ "89c25", "1", "3fec", "6b12ae36313d", "5/31200" };
    for (ids) |text| {
        const cell = if (std.mem.startsWith(u8, text, "5/"))
            try s2.CellId.fromDebugString(text)
        else
            try s2.CellId.fromToken(text);

        const rebuilt = try s2.CellId.fromFacePosLevel(
            try cell.face(),
            try cell.pos(),
            try cell.level(),
        );
        try testing.expectEqual(cell.raw, rebuilt.raw);

        // The debug string is the library's third spelling of the same cell.
        var buf: [text_buf_len]u8 = undefined;
        const debug = try cell.toDebugString(&buf);
        try testing.expectEqual(cell.raw, (try s2.CellId.fromDebugString(debug)).raw);
    }
    // Upstream publishes "5/31200" as the debug string of 0xbb04000000000000
    // (src/s2/s2cell_id_test.cc:800-803 and golang/geo's TestCellIDString).
    var buf: [text_buf_len]u8 = undefined;
    const published = s2.CellId{ .raw = 0xbb04000000000000 };
    try testing.expectEqualStrings("5/31200", try published.toDebugString(&buf));
    for ([_]u8{ 6, 7 }) |face| {
        try testing.expectError(error.InvalidArgument, s2.CellId.fromFacePosLevel(face, 0, 0));
        var raw_id: u64 = 0xDEADBEEF;
        const invalid: s2.c.S2BridgeStatus = s2.c.S2BRIDGE_INVALID_ARGUMENT;
        try testing.expectEqual(invalid, s2.c.s2br_cell_from_face_pos_level(face, 0, 0, &raw_id));
        try testing.expectEqual(@as(u64, 0xDEADBEEF), raw_id);
    }
}

test "a cell named by its face, i and j matches the published corner neighbours" {
    // `S2CellId::FromFaceIJ` returns the leaf cell whose centre sits at (i, j)
    // on `face`, both in 0 .. 2^30 - 1 (`s2/s2cell_id.h:482-484`, with
    // `kMaxSize = 1 << kMaxLevel`, `s2/s2cell_id.h:102`). Upstream's own
    // TEST(S2CellId, Neighbors) states the four edge neighbours of the corner
    // cell `FromFaceIJ(1, 0, 0).parent(level)` as four more FromFaceIJ cells,
    // under the comment "These neighbors were determined manually using the
    // face and axis relationships defined in s2coords.cc"
    // (src/s2/s2cell_id_test.cc:584-596). That is a published answer about what
    // an (i, j) pair names, and `edgeNeighbors` reaches it from the other
    // direction: it decodes the id back to (face, i, j) and then applies the
    // cube's face-and-axis adjacency (`src/s2/s2cell_id.cc:499-512`), so a
    // wrong (i, j) -> id encoding cannot satisfy it. The pair also reaches both
    // ends of the documented i and j range.
    const kMaxIJ: u32 = (@as(u32, 1) << s2.max_level) - 1;
    for (@as(u8, 1)..s2.max_level + 1) |level| {
        const size_ij: u32 = @as(u32, 1) << @intCast(s2.max_level - level);
        const corner = try (try s2.CellId.fromFaceIJ(1, 0, 0)).parent(@intCast(level));
        try testing.expectEqual(level, try corner.level());

        const expected = [_]s2.CellId{
            try (try s2.CellId.fromFaceIJ(5, kMaxIJ, kMaxIJ)).parent(@intCast(level)),
            try (try s2.CellId.fromFaceIJ(1, size_ij, 0)).parent(@intCast(level)),
            try (try s2.CellId.fromFaceIJ(1, 0, size_ij)).parent(@intCast(level)),
            try (try s2.CellId.fromFaceIJ(0, kMaxIJ, 0)).parent(@intCast(level)),
        };
        const got = try corner.edgeNeighbors();
        try testing.expectEqual(expected.len, got.len);
        for (got, expected) |neighbor, want| {
            try testing.expectEqual(want.raw, neighbor.raw);
        }
    }

    // (0, 0) on face 0 is the face-0 corner leaf, which the fixture row
    // `cornervertex 0 0 30 0,4,5` already names by its Hilbert position
    // instead: `S2CellId::FromFacePosLevel(0, 0, kMaxLevel)`, described at
    // src/s2/s2cell_id_test.cc:610-611 as "the corner of faces 0, 4, and 5".
    // Two independent spellings must be one cell.
    try testing.expectEqual(
        (try s2.CellId.fromFacePosLevel(0, 0, s2.max_level)).raw,
        (try s2.CellId.fromFaceIJ(0, 0, 0)).raw,
    );

    // The documented range is 0 .. 2^30 - 1 inclusive, so one past either end
    // is refused rather than wrapped, and a face is 0..5 here even though
    // `fromFace` also names the invalid faces 6 and 7.
    try testing.expectError(error.InvalidArgument, s2.CellId.fromFaceIJ(0, kMaxIJ + 1, 0));
    try testing.expectError(error.InvalidArgument, s2.CellId.fromFaceIJ(0, 0, kMaxIJ + 1));
    try testing.expectError(error.InvalidArgument, s2.CellId.fromFaceIJ(6, 0, 0));
}

test "failed C covering sizing cannot retain a previous valid count" {
    const options = s2.c.S2BridgeCovererOptions{
        .min_level = 0,
        .max_level = 0,
        .level_mod = 1,
        .max_cells = 8,
    };
    const ok: s2.c.S2BridgeStatus = s2.c.S2BRIDGE_OK;
    const invalid: s2.c.S2BridgeStatus = s2.c.S2BRIDGE_INVALID_ARGUMENT;
    const face = try s2.CellId.fromFace(0);
    var count: usize = 0;
    try testing.expectEqual(ok, s2.c.s2br_coverer_covering_cell(face.raw, &options, null, 0, &count));
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(invalid, s2.c.s2br_coverer_covering_cell(0, &options, null, 0, &count));
    try testing.expectEqual(@as(usize, 0), count);
    try testing.expectEqual(ok, s2.c.s2br_coverer_covering_cell(face.raw, &options, null, 0, &count));
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(invalid, s2.c.s2br_coverer_covering_polygon(null, &options, null, 0, &count));
    try testing.expectEqual(@as(usize, 0), count);
}
