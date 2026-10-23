// SPDX-License-Identifier: Apache-2.0

//! Behavioral tests for the S2 facade against independent fixtures and geometric identities.
//! Fixture data records upstream and golang/geo sources.

const std = @import("std");
const s2 = @import("s2geometry");
const testing = std.testing;

/// Token/id pairs and malformed tokens (`golang/geo s2/cellid_test.go:343-425`).
const tokens_tsv = @embedFile("testdata/golang_cellid_tokens.tsv");

/// Cell-id and latitude/longitude pairs (`golang/geo s2/cellid_test.go:176-191`).
const latlng_tsv = @embedFile("testdata/golang_cellid_latlng.tsv");

/// Neighbor, hierarchy, containment and projection answers; sources are in the fixture header.
const neighbors_tsv = @embedFile("testdata/upstream_neighbors.tsv");

/// Published Sydney covering (`src/s2/s2region_coverer_test.cc:534-563`).
const sydney_txt = @embedFile("testdata/upstream_coverer_sydney.txt");

/// Polar-closure cases (`src/s2/s2latlng_rect_test.cc:416-423`).
const polar_tsv = @embedFile("testdata/upstream_polar_closure.tsv");

/// Normalization and validity answers (`golang/geo s2/latlng_test.go:32-92`).
const normalize_tsv = @embedFile("testdata/golang_latlng_normalize.tsv");

/// Iterates the non-empty lines of an embedded fixture.
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

/// Splits a tab-separated row and returns its field count; excess fields are not written.
fn fields(line: []const u8, out: [][]const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |field| {
        if (count < out.len) out[count] = field;
        count += 1;
    }
    return count;
}

/// Parses a fixture float or panics with the invalid field.
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

/// Buffer capacity for upstream tokens and debug strings (`src/s2/s2cell_id.cc:232,604-609`).
const text_buf_len = 64;

fn cellIdLessThan(_: void, a: s2.CellId, b: s2.CellId) bool {
    return a.raw < b.raw;
}

/// Compares cell multisets; upstream may append a corner neighbor more than once.
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

/// Environment variable naming a shared object that exports this package's bridge.
/// Upstream `libs2` alone is not a provider because it has no `s2br_*` symbols.
const provider_variable = "S2GEOMETRY_TEST_PROVIDER";

/// Loads the explicit provider in runtime-loading builds; linked builds need no load.
/// An unset provider path stops with the variable name.
fn nativeReady() void {
    if (comptime !s2.runtime_loaded) return;
    if (s2.loadedSource() != null) return;

    var buffer: [4096]u8 = undefined;
    const value = std.testing.environ.getAlloc(testing.allocator, provider_variable) catch
        missingProvider();
    defer testing.allocator.free(value);
    if (value.len == 0 or value.len > buffer.len) missingProvider();
    @memcpy(buffer[0..value.len], value);
    s2.load(.{ .path = buffer[0..value.len] }) catch |err| {
        std.debug.print(
            "tests.zig: loading " ++ provider_variable ++ " = \"{s}\" failed: {t}\n",
            .{ buffer[0..value.len], err },
        );
        @panic("tests.zig: the provider named by " ++ provider_variable ++
            " did not load; nothing below this line ran");
    };
}

fn missingProvider() noreturn {
    @panic(
        "tests.zig: this is a runtime-loading build and " ++ provider_variable ++
            " is not set. Point it at a shared build of this package's own bridge" ++
            " -- the image exporting the 93 s2br_* entry points of zig/bridge.h," ++
            " with libs2 and libabsl in its closure -- for example the one " ++
            "`zig build -Dlinkage=dynamic` installs, and export it for the whole " ++
            "`zig build` invocation: the build cannot inject a path into a " ++
            "run step's environment.",
    );
}

test "published token/id pairs decode and encode exactly" {
    nativeReady();
    var lines = Lines{ .text = tokens_tsv };
    var accepted: usize = 0;
    var rejected: usize = 0;
    while (lines.next()) |line| {
        var parts: [2][]const u8 = undefined;
        try testing.expectEqual(@as(usize, 2), fields(line, &parts));

        if (std.mem.eql(u8, parts[1], "1")) {
            // Malformed tokens must not alias `none` (`src/s2/s2cell_id.cc:249-250`).
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

        try testing.expect(decoded.isValid());
        accepted += 1;
    }
    try testing.expectEqual(@as(usize, 32), accepted);
    try testing.expectEqual(@as(usize, 5), rejected);
}

test "every face root has the token upstream's id layout implies" {
    nativeReady();
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
    nativeReady();
    const sentinel: u64 = 0xdead_beef_dead_beef;
    var out: u64 = sentinel;
    _ = s2.c.s2br_cell_from_token("nope!", 5, &out);
    try testing.expectEqual(sentinel, out);

    var too_long: u64 = sentinel;
    // Seventeen hex digits exceed upstream's token limit (`src/s2/s2cell_id.cc:236`).
    _ = s2.c.s2br_cell_from_token("0123456789abcdef0", 17, &too_long);
    try testing.expectEqual(sentinel, too_long);
}

test "a token buffer one byte short is refused and left alone" {
    nativeReady();
    const id = try s2.CellId.fromToken("89c25");
    var full: [text_buf_len]u8 = undefined;
    const token = try id.toToken(&full);
    try testing.expectEqual(@as(usize, 5), token.len);

    var short: [5]u8 = undefined;
    @memset(&short, 0xAA);
    try testing.expectError(error.BufferTooSmall, id.toToken(&short));
    try testing.expectEqual(@as(u8, 0xAA), short[0]);

    var exact: [6]u8 = undefined;
    try testing.expectEqualStrings("89c25", try id.toToken(&exact));
}

test "invalid cell ids are refused instead of answered with a number" {
    nativeReady();
    try testing.expect(!s2.CellId.none.isValid());
    try testing.expect(!s2.CellId.sentinel.isValid());
    try testing.expect(!(s2.CellId{ .raw = 2 }).isValid());

    // Upstream uses face indices 6 and 7 for invalid ids (`src/s2/s2cell_id_test.cc:335-336`).
    try testing.expect(!(try s2.CellId.fromFace(6)).isValid());
    try testing.expect(!(try s2.CellId.fromFace(7)).isValid());

    // Invalid id 0 has no level, so accessors refuse it (`src/s2/s2cell_id.h:596-601`).
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

test "published containment and intersection table" {
    nativeReady();
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
    nativeReady();
    // The inclusive id range defines containment (`src/s2/s2cell_id.h:290-295`).
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

    // Consecutive cells at one level differ by `2*lsb` (`src/s2/s2cell_id.h:714-716`).
    for (kids[1..], kids[0 .. kids.len - 1]) |next, prev| {
        const prev_range = try prev.range();
        const next_range = try next.range();
        try testing.expectEqual(prev_range[1].raw + 2, next_range[0].raw);
    }
}

test "published leaf cell ids round trip with published coordinates" {
    nativeReady();
    var lines = Lines{ .text = latlng_tsv };
    var rows: usize = 0;
    while (lines.next()) |line| {
        var parts: [3][]const u8 = undefined;
        try testing.expectEqual(@as(usize, 3), fields(line, &parts));

        const expected = s2.CellId{ .raw = parseU64(parts[0]) };
        const lat_deg = parseF64(parts[1]);
        const lng_deg = parseF64(parts[2]);
        const ll = s2.LatLng.fromDegrees(lat_deg, lng_deg);

        const leaf = try s2.CellId.fromLatLng(ll);
        try testing.expectEqual(expected, leaf);
        try testing.expect(leaf.isLeaf());

        const centre = try expected.toLatLng();
        try testing.expectApproxEqAbs(lat_deg, centre.lat_deg, 1e-8);
        try testing.expectApproxEqAbs(lng_deg, centre.lng_deg, 1e-8);

        const as_point = try ll.toPoint();
        try testing.expectEqual(expected, try s2.CellId.fromPoint(as_point));
        const back = try as_point.toLatLng();
        try testing.expectApproxEqAbs(lat_deg, back.lat_deg, 1e-8);
        try testing.expectApproxEqAbs(lng_deg, back.lng_deg, 1e-8);

        try testing.expect(try s2.Cell.init(leaf).containsPoint(as_point));
        rows += 1;
    }
    try testing.expectEqual(@as(usize, 14), rows);
}

test "the projection origin is on face 0 and its face cell is centred there" {
    nativeReady();
    // Published origin-cell answers (`src/python/s2geometry_test.py:486-487`; `src/s2/s2cell_id_test.cc:90-95`).
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
    nativeReady();
    // Cube face follows the axis with the largest component (`src/s2/s2coords.cc:29-41`).
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
        const face_centre = try face_cell.toPoint();
        try testing.expectApproxEqAbs(point.x, face_centre.x, 1e-15);
        try testing.expectApproxEqAbs(point.y, face_centre.y, 1e-15);
        try testing.expectApproxEqAbs(point.z, face_centre.z, 1e-15);
    }
}

test "published parent and child positions" {
    nativeReady();
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
    nativeReady();
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

    std.mem.sort(s2.CellId, from_iteration, {}, cellIdLessThan);
    std.mem.sort(s2.CellId, &kids, {}, cellIdLessThan);
    for (from_iteration, kids) |a, b| {
        try testing.expectEqual(b.raw, a.raw);
    }

    // Descendant targets must exceed this cell's level (`src/s2/s2cell_id.h:344-347`).
    try testing.expectError(error.InvalidArgument, parent.children(level - 2, &buf));
    try testing.expectError(error.InvalidArgument, parent.childrenCount(level - 2));
    try testing.expectError(error.InvalidArgument, parent.children(31, &buf));

    var too_small: [3]s2.CellId = undefined;
    for (&too_small) |*slot| slot.* = .{ .raw = 0xEE };
    try testing.expectError(error.BufferTooSmall, parent.children(level, &too_small));
    try testing.expectEqual(@as(u64, 0xEE), too_small[2].raw);

    const leaf = try s2.CellId.fromLatLng(.{ .lat_deg = 1, .lng_deg = 2 });
    try testing.expect(leaf.isLeaf());
    try testing.expectError(error.InvalidArgument, leaf.child(0));
}

test "a face cell reports its leaf-cell count without building any of them" {
    nativeReady();
    // A face has 4^30 = 2^60 descendants; count them without walking (`src/s2/s2cell_id.h:344-347,360-363`).
    // On 32-bit targets this count must return `InvalidArgument`, not wrap.
    const leaf_count: u64 = @as(u64, 1) << 60;
    var one_cell: [1]s2.CellId = undefined;

    // Face 5's range ends at `End(30)`, one past the last leaf (`src/s2/s2cell_id.h:741-743`).
    for ([_]u8{ 0, 5 }) |face_index| {
        const face = try s2.CellId.fromFace(face_index);
        if (leaf_count > std.math.maxInt(usize)) {
            // Counts wider than `usize` return `InvalidArgument`, not a wrapped value.
            try testing.expectError(error.InvalidArgument, face.childrenCount(30));
            try testing.expectError(error.InvalidArgument, face.children(30, &one_cell));
        } else {
            try testing.expectEqual(leaf_count, @as(u64, @intCast(try face.childrenCount(30))));
            var buf: [4]s2.CellId = undefined;
            for (&buf) |*slot| slot.* = s2.CellId.sentinel;
            try testing.expectError(error.BufferTooSmall, face.children(30, &buf));
            for (buf) |id| try testing.expectEqual(s2.CellId.sentinel.raw, id.raw);
        }
    }

    // Three levels below a cell yields 4^3 = 64 descendants.
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

    try testing.expectEqual(@as(usize, 1), try cell.childrenCount(8));
    try testing.expectEqual(cell.raw, (try cell.children(8, &one_cell))[0].raw);
    const leaf = try s2.CellId.fromLatLng(.{ .lat_deg = 1, .lng_deg = 2 });
    try testing.expect(leaf.isLeaf());
    try testing.expectEqual(@as(usize, 1), try leaf.childrenCount(30));
    try testing.expectEqual(leaf.raw, (try leaf.children(30, &one_cell))[0].raw);
}

test "next and prev walk the id space and stop at the ends" {
    nativeReady();
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

    // `next()` and `prev()` do not wrap (`src/s2/s2cell_id.h:351-355`).
    const first = try s2.CellId.fromFace(0);
    try testing.expect(!(try first.prev()).isValid());
    const last = try s2.CellId.fromFace(5);
    try testing.expect(!(try last.next()).isValid());
}

test "published edge, all-neighbour and vertex-neighbour answers" {
    nativeReady();
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
            // Published face-1 neighbors (`src/s2/s2cell_id_test.cc:572-580`).
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
            // Compare as a multiset because upstream may repeat corner neighbors.
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

            // Upstream sorts this fixture before comparison (`src/s2/s2cell_id_test.cc:637-641`).
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
    nativeReady();
    // All-neighbor levels span [cell.level(), max_level] (`src/s2/s2cell_id.cc:558`; `s2/s2cell_id.h:611-614`).
    const cell = try s2.CellId.fromDebugString("2/033020001100");
    const level = try cell.level();
    try testing.expect(level > 0);

    var buf: [16]s2.CellId = undefined;
    try testing.expectError(error.InvalidArgument, cell.allNeighbors(level - 1, &buf));
    try testing.expectError(error.InvalidArgument, cell.allNeighbors(31, &buf));

    // Vertex-neighbor level must be below this cell (`src/s2/s2cell_id.cc:516-518`).
    try testing.expectError(error.InvalidArgument, cell.vertexNeighbors(level, &buf));
    try testing.expect(level < 30);

    // Edge neighbors are four distinct cells (`src/s2/s2cell_id.h:455-459`).
    const edges = try cell.edgeNeighbors();
    for (edges, 0..) |edge, i| {
        try testing.expectEqual(level, try edge.level());
        try testing.expect(edge.raw != cell.raw);
        for (edges[0..i]) |earlier| {
            try testing.expect(earlier.raw != edge.raw);
        }
    }

    const count = try cell.vertexNeighborsCount(level - 1);
    try testing.expect(count == 3 or count == 4);
    const vertex = try cell.vertexNeighbors(level - 1, &buf);
    try testing.expectEqual(count, vertex.len);
    for (vertex) |neighbor| {
        try testing.expectEqual(level - 1, try neighbor.level());
    }
}

test "a leaf cell accepts level 30 as its neighbour level" {
    nativeReady();
    // Level-30 corner neighbors cross cube faces and may duplicate (`src/s2/s2cell_id_test.cc:610-617`).
    const leaf = try s2.CellId.fromFacePosLevel(0, 0, s2.max_level);
    try testing.expectEqual(s2.max_level, try leaf.level());

    // Largest leaf-grid index (`src/s2/s2coords.h:133-135`).
    const ij_max: u32 = (@as(u32, 1) << s2.max_level) - 1;

    // Upstream wraps corner neighbors across cube faces and may append the face-5 leaf twice.
    // Preserve the duplicate in the expected multiset (`src/s2/s2cell_id.h:470-474`).
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

    // Edge neighbors are four distinct cells from a separate upstream algorithm (`src/s2/s2cell_id.h:455-459`; `s2/s2cell_id.cc:499-511`).
    const edges = try leaf.edgeNeighbors();
    for (edges) |edge| {
        try testing.expectEqual(s2.max_level, try edge.level());
        var found = false;
        for (neighbors) |neighbor| {
            if (neighbor.raw == edge.raw) found = true;
        }
        try testing.expect(found);
    }

    // Published edge neighbors for the face-1 corner (`src/s2/s2cell_id_test.cc:582-596`).
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

test "the six faces partition the sphere exactly" {
    nativeReady();
    var total: f64 = 0;
    for (0..6) |face| {
        const id = try s2.CellId.fromFace(@intCast(face));
        total += try s2.Cell.init(id).exactArea();
    }
    try testing.expectApproxEqRel(4 * std.math.pi, total, 1e-12);
}

test "children tile their parent and the approximation stays within its bound" {
    nativeReady();
    const cell = try s2.CellId.fromFacePosLevel(2, 0x2468, 6);
    const exact = try s2.Cell.init(cell).exactArea();
    try testing.expect(exact > 0);

    var children_total: f64 = 0;
    var buf: [4]s2.CellId = undefined;
    for (try cell.children(7, &buf)) |kid| {
        children_total += try s2.Cell.init(kid).exactArea();
    }
    try testing.expectApproxEqRel(exact, children_total, 1e-12);

    // Upstream approximation error is at most 0.1% from level 5 (`src/s2/s2cell.h:227-232`).
    const approx = try s2.Cell.init(cell).approxArea();
    try testing.expectApproxEqRel(exact, approx, 1e-3);

    // Average area uses upstream's `kAvgArea` metric (`src/s2/s2metrics.cc:114`; `s2/s2metrics.h:53`).
    const average = try s2.Cell.averageAreaAtLevel(6);
    try testing.expectApproxEqRel(
        4 * std.math.pi,
        average * @as(f64, @floatFromInt(@as(u64, 6) << 12)),
        1e-12,
    );
    try testing.expectError(error.InvalidArgument, s2.Cell.averageAreaAtLevel(31));
}

test "a face cell spans the whole (u,v) square and has four distinct corners" {
    nativeReady();
    // Published whole-face UV bounds (`golang/geo s2/cellid_test.go`, `TestIJLevelToBoundUV`).
    const face = try s2.CellId.fromFace(0);
    const uv = try s2.Cell.init(face).boundUV();
    try testing.expectApproxEqAbs(@as(f64, -1), uv.u_lo, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1), uv.u_hi, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, -1), uv.v_lo, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 1), uv.v_hi, 1e-15);

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

    const finer = try s2.CellId.fromFacePosLevel(0, 0, 4);
    const finer_uv = try s2.Cell.init(finer).boundUV();
    try testing.expect(finer_uv.u_hi - finer_uv.u_lo < uv.u_hi - uv.u_lo);
    try testing.expect(try finer.sizeSt() < try face.sizeSt());
}

test "published normalization answers for the poles and the antimeridian" {
    nativeReady();
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
    nativeReady();
    var lines = Lines{ .text = polar_tsv };
    var rows: usize = 0;
    while (lines.next()) |line| {
        // Each row contains four input bounds and an expected closure or `full`.
        var groups: [2][]const u8 = undefined;
        try testing.expectEqual(@as(usize, 2), fields(line, &groups));

        var in: [4]f64 = undefined;
        {
            var it = std.mem.tokenizeScalar(u8, groups[0], ' ');
            for (&in) |*value| value.* = parseF64(it.next().?);
        }
        // Fixture order is `lat_lo, lat_hi, lng_lo, lng_hi`; the facade takes lower then upper pairs.
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
    nativeReady();
    // The -180° endpoint is stored as +180°, so this interval crosses the date line (`src/s2/s1interval.h:229-232`; `s2/s2latlng_rect.h:143-145`).
    // Its area and containment tests distinguish the region from its complement.
    const r1 = s2.LatLngRect.fromBounds(0, -180, 90, 0);
    try testing.expect(try r1.isValid());
    try testing.expect(try r1.isInverted());
    try testing.expect(try r1.containsLatLng(.{ .lat_deg = 30, .lng_deg = -45 }));
    try testing.expect(!try r1.containsLatLng(.{ .lat_deg = 30, .lng_deg = 45 }));
    // Published rectangle corner cases (`src/s2/s2latlng_rect_test.cc:191-194`).
    try testing.expect(try r1.containsLatLng(.{ .lat_deg = 0, .lng_deg = -180 }));
    try testing.expect(try r1.containsLatLng(.{ .lat_deg = 90, .lng_deg = 0 }));
    // Rectangle area is longitude length times the sine difference (`src/s2/s2latlng_rect.cc:94-99`).
    try testing.expectApproxEqRel(std.math.pi, try r1.area(), 1e-12);

    // Inverted longitude bounds are legal and cross the date line (`src/s2/s2latlng_rect.h:145`).
    const crossing = s2.LatLngRect.fromBounds(0, 170, 10, -170);
    try testing.expect(try crossing.isValid());
    try testing.expect(try crossing.isInverted());
    try testing.expectApproxEqRel(
        (try s2.LatLngRect.fromBounds(0, 170, 10, 180).area()) +
            (try s2.LatLngRect.fromBounds(0, -180, 10, -170).area()),
        try crossing.area(),
        1e-9,
    );

    const bad = s2.LatLngRect.fromBounds(-100, 0, 100, 10);
    try testing.expect(!try bad.isValid());
}

test "a cap's area is its height and its complement covers the rest of the sphere" {
    nativeReady();
    // Upstream defines cap area as `2*pi*height` (`src/s2/s2cap.cc:48-50`).
    const cap = s2.Cap{ .center = .{ .lat_deg = 10, .lng_deg = 20 }, .radius_deg = 30 };
    const area = try cap.area();
    const height = try cap.height();
    try testing.expectApproxEqRel(2 * std.math.pi * height, area, 1e-12);

    const hemisphere = s2.Cap{ .center = .{ .lat_deg = 0, .lng_deg = 0 }, .radius_deg = 90 };
    try testing.expectApproxEqRel(2 * std.math.pi, try hemisphere.area(), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), try hemisphere.height(), 1e-12);

    // The complement's centre is the antipode (`src/s2/s2cap.cc:65-71`).
    const complement = try cap.complement();
    try testing.expectApproxEqRel(@as(f64, 150), complement.radius_deg, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -10), complement.center.lat_deg, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -160), complement.center.lng_deg, 1e-9);
    try testing.expectApproxEqRel(4 * std.math.pi - area, try complement.area(), 1e-12);

    // Use points clear of the rim to avoid rounded boundary ties (`src/s2/s2cap.cc:296-299`).
    const centre = try cap.center.toPoint();
    try testing.expect(try cap.containsPoint(centre));
    const inside = try s2.LatLng.fromDegrees(39, 20).toPoint();
    try testing.expect(try cap.containsPoint(inside));
    const outside = try s2.LatLng.fromDegrees(-60, 20).toPoint();
    try testing.expect(!try cap.containsPoint(outside));

    // Upstream treats zero/negative radii as empty (`src/s2/s2cap.h:70-80`).
    const point_cap = s2.Cap{ .center = .{ .lat_deg = 5, .lng_deg = 6 }, .radius_deg = 0 };
    try testing.expectApproxEqAbs(@as(f64, 0), try point_cap.area(), 1e-15);
    try testing.expect(try point_cap.containsPoint(try point_cap.center.toPoint()));

    // Upstream only debug-asserts unit vectors; reject scaled directions before that check (`src/s2/s2cap.cc:296-300`).
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
    nativeReady();
    // Distance answers and tolerances come from golang/geo's `TestLatLngDistance` table.
    const cases = [_]struct { a: s2.LatLng, b: s2.LatLng, want: f64, tol: f64 }{
        .{ .a = .{ .lat_deg = 0, .lng_deg = 0 }, .b = .{ .lat_deg = 45, .lng_deg = 0 }, .want = 45, .tol = 1e-12 },
        .{ .a = .{ .lat_deg = -37, .lng_deg = 25 }, .b = .{ .lat_deg = -66, .lng_deg = -155 }, .want = 77, .tol = 1e-9 },
        .{ .a = .{ .lat_deg = 0, .lng_deg = 165 }, .b = .{ .lat_deg = 0, .lng_deg = -80 }, .want = 115, .tol = 1e-9 },
    };
    for (cases) |case| {
        try testing.expectApproxEqAbs(case.want, try case.a.distanceDeg(case.b), case.tol);
        try testing.expectApproxEqAbs(case.want, try case.b.distanceDeg(case.a), case.tol);
    }

    const quarter = s2.LatLng.fromRadians(std.math.pi / 4.0, 0);
    try testing.expectApproxEqAbs(@as(f64, 45), quarter.lat_deg, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), quarter.lng_deg, 1e-12);
}

test "point normalization preserves direction and yields unit length" {
    nativeReady();
    const scaled = try (s2.Point{ .x = 3, .y = 4, .z = 12 }).normalized();
    const length = @sqrt(
        scaled.x * scaled.x + scaled.y * scaled.y + scaled.z * scaled.z,
    );
    try testing.expectApproxEqAbs(@as(f64, 1), length, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 3.0 / 13.0), scaled.x, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 4.0 / 13.0), scaled.y, 1e-15);
    try testing.expectApproxEqAbs(@as(f64, 12.0 / 13.0), scaled.z, 1e-15);
}

test "an octant triangle has exactly pi/2 steradians" {
    nativeReady();
    // The positive-axis octant has area pi/2 and perimeter 3*pi/2 (`src/s2/s2loop_measures_test.cc:238-241`).
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

    const inside = try (s2.Point{ .x = 1, .y = 1, .z = 1 }).normalized();
    try testing.expect(try loop.containsPoint(inside));
    const outside = try (s2.Point{ .x = 1, .y = -1, .z = 1 }).normalized();
    try testing.expect(!try loop.containsPoint(outside));

    const v0 = try loop.vertex(0);
    try testing.expectApproxEqAbs(@as(f64, 1), v0.x, 1e-15);
    const v0_ll = try loop.vertexLatLng(0);
    try testing.expectApproxEqAbs(@as(f64, 0), v0_ll.lat_deg, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), v0_ll.lng_deg, 1e-12);
    try testing.expectError(error.InvalidArgument, loop.vertex(3));
    try testing.expectError(error.InvalidArgument, loop.vertexLatLng(3));

    try loop.invert();
    try testing.expectApproxEqRel(4 * std.math.pi - std.math.pi / 2.0, try loop.area(), 1e-12);
    try testing.expect(!try loop.isNormalized());
    try testing.expect(try loop.containsPoint(outside));
    try testing.expect(!try loop.containsPoint(inside));
    try loop.normalize();
    try testing.expect(try loop.isNormalized());
    try testing.expectApproxEqRel(std.math.pi / 2.0, try loop.area(), 1e-12);
    try testing.expect(try loop.containsPoint(inside));

    try loop.normalize();
    try testing.expectApproxEqRel(std.math.pi / 2.0, try loop.area(), 1e-12);
}

test "the empty and full loops are exact opposites" {
    nativeReady();
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

    // Empty and full loops each have one special vertex (`src/s2/s2loop.h:84-87,139-143`).
    try testing.expectEqual(@as(usize, 1), try empty.numVertices());
    try testing.expectEqual(@as(usize, 1), try full.numVertices());
    try testing.expect(try empty.isValid());
    try testing.expect(try full.isValid());
}

test "a loop with a repeated vertex is constructible but invalid" {
    nativeReady();
    // Upstream constructs the vertex chain before checking loop validity (`src/s2/s2loop.cc:201-221`).
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
    nativeReady();
    // Non-unit vertices reach an upstream exact-predicate assumption (`src/s2/s2predicates.h:394`).
    // Reject them before construction rather than relying on its debug-only check.
    const not_a_direction = [_][3]f64{
        .{ 2, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    };
    try testing.expectError(error.InvalidArgument, s2.Loop.init(&not_a_direction));
    try testing.expectError(error.InvalidArgument, s2.Polygon.init(&not_a_direction));
    try testing.expectError(error.InvalidArgument, s2.Polygon.initLoops(&not_a_direction, &.{3}));

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
    nativeReady();
    // Upstream stores loop/vertex counts as `int`; bridge inputs exceeding that range are refused before reads.
    // Direct C calls assert invalid status and a null handle without allocating.
    const octant = [_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    };
    const octant_ref: *const [3][3]f64 = &octant;

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

    // Test each native count bound separately: loop count, per-loop length, and total length.
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

    // Individually valid loop lengths may overflow their accumulated `int` total.
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

    // Each vertex is three doubles, so `3 * n` must fit the addressable span.
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
    nativeReady();
    // Upstream indices are `int`; larger `usize` values must be refused, not narrowed.
    // These checks use real handles to isolate the invalid indices (`s2/s2loop.h:193`; `s2/s2polygon.h:259`).
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

    try testing.expectError(error.InvalidArgument, loop.vertex(one_past));
    try testing.expectError(error.InvalidArgument, loop.vertex(beyond));
    try testing.expectError(error.InvalidArgument, loop.vertexLatLng(one_past));
    try testing.expectError(error.InvalidArgument, loop.vertexLatLng(beyond));

    try testing.expectError(error.InvalidArgument, poly.loopNumVertices(one_past));
    try testing.expectError(error.InvalidArgument, poly.loopNumVertices(beyond));
    try testing.expectError(error.InvalidArgument, poly.loopVertex(one_past, 0));
    try testing.expectError(error.InvalidArgument, poly.loopVertex(0, one_past));
    try testing.expectError(error.InvalidArgument, poly.loopVertex(beyond, beyond));
    try testing.expectError(error.InvalidArgument, poly.loopVertexLatLng(one_past, 0));
    try testing.expectError(error.InvalidArgument, poly.loopVertexLatLng(0, one_past));
    try testing.expectError(error.InvalidArgument, poly.loopVertexLatLng(beyond, beyond));

    try testing.expectEqual(@as(usize, 3), try loop.numVertices());
    try testing.expectEqual(@as(f64, 1.0), (try loop.vertex(0)).x);
    try testing.expectEqual(@as(usize, 3), try poly.loopNumVertices(0));
    try testing.expectEqual(@as(usize, 3), try poly.numVertices());
}

test "a quadrilateral has twice the area of the triangle that halves it" {
    nativeReady();
    // A cube-face square has area 4*pi/6, and its diagonal halves it (`src/s2/s2metrics.cc:114-115`).
    // Use non-antipodal corners so the loop remains valid.
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

    try testing.expect(try quad.containsPoint(.{ .x = 1, .y = 0, .z = 0 }));
    try testing.expect(!try quad.containsPoint(.{ .x = -1, .y = 0, .z = 0 }));
    try testing.expect(try quad.containsLatLng(.{ .lat_deg = 0, .lng_deg = 0 }));
    try testing.expect(!try quad.containsLatLng(.{ .lat_deg = 0, .lng_deg = 180 }));

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

    const centroid = try quad.centroidLatLng();
    try testing.expectApproxEqAbs(@as(f64, 0), centroid.lat_deg, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), centroid.lng_deg, 1e-9);
}

test "the empty and full polygons complement each other" {
    nativeReady();
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
    nativeReady();
    // Spherical excess fixes areas at pi/2 per wedge, pi/4 intersection, and 3*pi/4 union.
    // Shells are counter-clockwise; vertices satisfy unit-length tolerance (`src/s2/s2polygon.cc:406-414`; `s2/s2pointutil.cc:32-40`).
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

    try testing.expectApproxEqRel(std.math.pi / 4.0, try both.area(), 1e-9);
    try testing.expectApproxEqRel(3 * std.math.pi / 4.0, try either.area(), 1e-9);

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

    try testing.expectApproxEqRel(
        (try xy.area()) + (try rotated.area()),
        (try either.area()) + (try both.area()),
        1e-9,
    );
    try testing.expect((try both.area()) < (try xy.area()));
    try testing.expect((try both.area()) < (try rotated.area()));
    try testing.expect((try both.area()) > 0);
    try testing.expect((try either.area()) > (try xy.area()));
    try testing.expect((try either.area()) > (try rotated.area()));
    try testing.expect((try either.area()) < 4 * std.math.pi);

    try testing.expectApproxEqRel(std.math.pi / 2.0, try xy.area(), 1e-12);
    try testing.expectApproxEqRel(std.math.pi / 2.0, try rotated.area(), 1e-12);
}

test "a boolean operation refuses an operand its own validator rejects" {
    nativeReady();
    // This unit-vertex bow tie crosses at the face centre; `isValid` checks its topology.
    const corner = 1.0 / @sqrt(@as(f64, 3));
    var bowtie = try s2.Polygon.init(&[_][3]f64{
        .{ corner, -corner, -corner },
        .{ corner, corner, corner },
        .{ corner, corner, -corner },
        .{ corner, -corner, corner },
    });
    defer bowtie.deinit();
    try testing.expect(!try bowtie.isValid());

    // Boolean operations require valid inputs, so reject invalid operands first (`src/s2/s2polygon.h:385-388`).
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

    try testing.expect(!try bowtie.isValid());
    try testing.expect(try wedge.isValid());
    try testing.expectApproxEqRel(std.math.pi / 2.0, try wedge.area(), 1e-12);
}

test "a polygon with a hole subtracts the hole" {
    nativeReady();
    // `InitNested` classifies shells and holes by nesting depth (`src/s2/s2polygon.h:184-189`).
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

    const shell_area = try shell_only.area();
    const hole_area = try hole_only.area();
    try testing.expect(shell_area > hole_area);
    try testing.expectApproxEqRel(shell_area - hole_area, try with_hole.area(), 1e-9);

    const north = s2.Point{ .x = 0, .y = 0, .z = 1 };
    try testing.expect(try shell_only.containsPoint(north));
    try testing.expect(try hole_only.containsPoint(north));
    try testing.expect(!try with_hole.containsPoint(north));

    const between = try s2.LatLng.fromDegrees(60, 0).toPoint();
    try testing.expect(try shell_only.containsPoint(between));
    try testing.expect(!try hole_only.containsPoint(between));
    try testing.expect(try with_hole.containsPoint(between));

    try testing.expectError(error.InvalidArgument, s2.Polygon.initLoops(&combined, &.{ 4, 3 }));
    try testing.expectError(error.InvalidArgument, s2.Polygon.initLoops(&combined, &.{4}));
}

test "a length list that cannot be summed is refused, not overflowed" {
    nativeReady();
    // Loop lengths are `usize`; reject accumulated overflow before comparing with the vertex span.
    // Invalid lengths must return `InvalidArgument` without producing a handle.
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

test "the coverer picks a published cell for a real Sydney coordinate" {
    nativeReady();
    // The fixture and its 42 expected tokens come from upstream's Sydney `JavaCcConsistency` test (`src/s2/s2region_coverer_test.cc:534-563`).
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

        try testing.expect(try s2.Cell.init(covering[0]).containsPoint(
            try point.toPoint(),
        ));
    }

    var empty_buf: [1]s2.CellId = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        coverer.coveringCap(.{ .center = points[0], .radius_deg = 0 }, empty_buf[0..0]),
    );
}

test "the covering of a cell is exactly that cell" {
    nativeReady();
    // Upstream covering fixture with `max_cells = 1` (`src/s2/s2region_coverer_test.cc:72-87`).
    const cell = try s2.CellId.fromDebugString("2/033020001100");
    const coverer = s2.Coverer{ .max_cells = 1 };

    var buf: [8]s2.CellId = undefined;
    const covering = try coverer.coveringCell(cell, &buf);
    try testing.expectEqual(@as(usize, 1), covering.len);
    try testing.expectEqual(cell.raw, covering[0].raw);
    try testing.expectEqual(@as(usize, 1), try coverer.coveringCellCount(cell));
}

test "a covering obeys its options and actually covers its region" {
    nativeReady();
    // Covering levels and containment follow the upstream contract (`src/s2/s2region_coverer.h:44-62,113-160`).
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
    // `max_cells` may be exceeded when a region needs the six face cells (`src/s2/s2region_coverer.h:78-84`).
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

    // Validate options before upstream's debug-only checks (`src/s2/s2region_coverer.cc:44-47,60-83`).
    try testing.expectError(error.InvalidArgument, (s2.Coverer{
        .min_level = 10,
        .max_level = 4,
    }).coveringCapCount(cap));
    try testing.expectError(error.InvalidArgument, (s2.Coverer{ .level_mod = 0 }).coveringCapCount(cap));
    try testing.expectError(error.InvalidArgument, (s2.Coverer{ .level_mod = 4 }).coveringCapCount(cap));
    try testing.expectError(error.InvalidArgument, (s2.Coverer{ .max_cells = 0 }).coveringCapCount(cap));
    try testing.expectError(error.InvalidArgument, (s2.Coverer{ .max_level = 31 }).coveringCapCount(cap));

    // `max_cells` must fit the bridge's `int32_t` parameter (`zig/bridge.h:565`).
    try testing.expectError(error.InvalidArgument, (s2.Coverer{
        .max_cells = @as(u32, @intCast(std.math.maxInt(c_int))) + 1,
    }).coveringCapCount(cap));

    try testing.expectError(
        error.InvalidArgument,
        coverer.coveringCapCount(.{
            .center = .{ .lat_deg = std.math.nan(f64), .lng_deg = 0 },
            .radius_deg = 1,
        }),
    );
}

test "coverings of a rectangle and of a polygon cover a point inside them" {
    nativeReady();
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

    try testing.expect(try poly.containsLatLng(.{ .lat_deg = 35.264389, .lng_deg = 45 }));
}

test "every unit in the facade is the one its name says" {
    nativeReady();
    try testing.expectApproxEqAbs(
        @as(f64, 90),
        s2.LatLng.fromRadians(std.math.pi / 2.0, 0).lat_deg,
        1e-12,
    );

    const face_area = try s2.Cell.init(try s2.CellId.fromFace(0)).exactArea();
    try testing.expectApproxEqRel((4 * std.math.pi) / 6.0, face_area, 1e-12);

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
    nativeReady();
    // `FromFacePosLevel` inverts `face`, `pos`, and `level` (`src/s2/s2cell_id.h:543-550`).
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

        var buf: [text_buf_len]u8 = undefined;
        const debug = try cell.toDebugString(&buf);
        try testing.expectEqual(cell.raw, (try s2.CellId.fromDebugString(debug)).raw);
    }
    // Published debug spelling `5/31200` (`src/s2/s2cell_id_test.cc:800-803`; golang/geo `TestCellIDString`).
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
    nativeReady();
    // Upstream manually publishes edge neighbors across cube faces (`src/s2/s2cell_id_test.cc:584-596`; `src/s2/s2cell_id.cc:499-512`).
    // These indices cover both ends of the 0..2^30-1 range.
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

    // Upstream identifies the face-0 corner across faces 0, 4, and 5 (`src/s2/s2cell_id_test.cc:610-611`).
    try testing.expectEqual(
        (try s2.CellId.fromFacePosLevel(0, 0, s2.max_level)).raw,
        (try s2.CellId.fromFaceIJ(0, 0, 0)).raw,
    );

    // Valid grid indices are 0..2^30-1 and face indices are 0..5 (`src/s2/s2cell_id.h:482-484`).
    try testing.expectError(error.InvalidArgument, s2.CellId.fromFaceIJ(0, kMaxIJ + 1, 0));
    try testing.expectError(error.InvalidArgument, s2.CellId.fromFaceIJ(0, 0, kMaxIJ + 1));
    try testing.expectError(error.InvalidArgument, s2.CellId.fromFaceIJ(6, 0, 0));
}

test "failed C covering sizing cannot retain a previous valid count" {
    nativeReady();
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
