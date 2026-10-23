// SPDX-License-Identifier: Apache-2.0

//! Deterministic executable checks of the S2 facade against published values.
//! Runtime-loaded builds require an explicit provider via `--provider` or the environment.

const std = @import("std");
const s2 = @import("s2geometry");

/// Output buffer capacity for the smoke report.
const out_buffer_len = 4096;

/// Mismatches that make the smoke program exit with an error.
const SmokeError = error{
    TokenMismatch,
    IdMismatch,
    NeighborMismatch,
    AreaMismatch,
    ContainmentMismatch,
};

/// Environment variable naming the runtime provider when no path is passed.
const provider_variable = "S2GEOMETRY_TEST_PROVIDER";

/// Missing explicit provider in runtime-loaded mode.
const ConfigurationError = error{NoProviderConfigured};

/// Selects the explicit `--provider` path or environment value.
/// The file must export this package's `s2br_*` bridge symbols.
fn providerRequest(init: std.process.Init) ConfigurationError![]const u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch
        return noProvider();
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProvider();
            return args[index + 1];
        }
    }
    return init.environ_map.get(provider_variable) orelse
        return noProvider();
}

fn noProvider() ConfigurationError {
    std.debug.print(
        "smoke.zig: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export S2GEOMETRY_TEST_PROVIDER with a shared build of this " ++
            "package's own bridge -- the image exporting the 93 s2br_* entry " ++
            "points of zig/bridge.h, with libs2 and libabsl in its closure. " ++
            "Nothing is loaded by default and no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [out_buffer_len]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    try out.writeAll("s2geometry smoke\n");

    if (comptime s2.runtime_loaded) {
        try s2.load(.{ .path = try providerRequest(init) });
        try out.print("loaded provider: {s}\n", .{s2.loadedSource().?.path});
    } else {
        try out.writeAll("linked\n");
    }

    try faceRoots(out);
    try publishedTokens(out);
    try projectionOrigin(out);
    try neighborIdentities(out);
    try octantArea(out);
    try polygonBoolean(out);
    try coveringASydneyPoint(out);

    try out.flush();
}

/// Prints the six face-root ids and tokens from upstream's id layout (`src/s2/s2cell_id.h:59-67`).
fn faceRoots(out: *std.Io.Writer) !void {
    try out.writeAll("\nface roots (level 0):\n");
    const expected = [_][]const u8{ "1", "3", "5", "7", "9", "b" };
    for (expected, 0..) |want, face| {
        const id = try s2.CellId.fromFace(@intCast(face));
        var buf: [64]u8 = undefined;
        const token = try id.toToken(&buf);
        try out.print("  face {d}: id 0x{x:0>16} token {s}\n", .{ face, id.raw, token });
        if (!std.mem.eql(u8, token, want)) return SmokeError.TokenMismatch;
    }
}

/// Prints published token/id pairs from golang/geo (`s2/cellid_test.go`, `TestCellIDTokensNominal`).
fn publishedTokens(out: *std.Io.Writer) !void {
    try out.writeAll("\npublished token/id pairs (golang/geo TestCellIDTokensNominal):\n");
    const cases = [_]struct { token: []const u8, id: u64 }{
        .{ .token = "1", .id = 0x1000000000000000 },
        .{ .token = "3fec", .id = 0x3fec000000000000 },
        .{ .token = "52b8c", .id = 0x52b8c00000000000 },
        .{ .token = "48a23db9c2963e5b", .id = 0x48a23db9c2963e5b },
    };
    for (cases) |case| {
        const id = try s2.CellId.fromToken(case.token);
        var buf: [64]u8 = undefined;
        const token = try id.toToken(&buf);
        try out.print(
            "  {s:>16} <-> 0x{x:0>16}  level {d}, face {d}\n",
            .{ token, id.raw, try id.level(), try id.face() },
        );
        if (id.raw != case.id) return SmokeError.IdMismatch;
        if (!std.mem.eql(u8, token, case.token)) return SmokeError.TokenMismatch;
    }
}

/// Prints the origin-cell answers published by Python and C++ S2 tests.
fn projectionOrigin(out: *std.Io.Writer) !void {
    const origin = s2.LatLng.fromDegrees(0, 0);
    const leaf = try s2.CellId.fromLatLng(origin);
    var buf: [64]u8 = undefined;
    try out.print(
        "\nprojection origin (0, 0): leaf cell {s}, face {d}, level {d}\n",
        .{ try leaf.toToken(&buf), try leaf.face(), try leaf.level() },
    );
    try out.print("  face cell 0x1000000000000000 centres at ({d}, {d}) degrees\n", .{
        (try (s2.CellId{ .raw = 0x1000000000000000 }).toLatLng()).lat_deg,
        (try (s2.CellId{ .raw = 0x1000000000000000 }).toLatLng()).lng_deg,
    });
    if (!try (s2.CellId{ .raw = 0x1000000000000000 }).contains(leaf)) {
        return SmokeError.ContainmentMismatch;
    }
    if ((try leaf.face()) != 0) return SmokeError.IdMismatch;
}

/// Prints published neighbor identities; corner results are multisets with duplicates (`src/s2/s2cell_id.h:455-475`).
/// Edge-neighbor order follows down, right, up, left (`src/s2/s2cell_id.cc:499-511`).
fn neighborIdentities(out: *std.Io.Writer) !void {
    try out.writeAll("\nneighbours (google/s2geometry fixtures):\n");

    const face1_edges = try (try s2.CellId.fromFace(1)).edgeNeighbors();
    try out.writeAll("  edge neighbours of face 1: ");
    const expected_edge_faces = [_]u8{ 5, 3, 2, 0 };
    for (face1_edges, 0..) |neighbor, i| {
        const face = try neighbor.face();
        try out.print("{d}{s}", .{ face, if (i == 3) "\n" else ", " });
        if (face != expected_edge_faces[i]) return SmokeError.NeighborMismatch;
    }

    const top = try s2.CellId.fromDebugString("3/");
    var top_buf: [16]s2.CellId = undefined;
    const top_neighbors = try top.allNeighbors(try top.level(), &top_buf);
    try out.print("  all neighbours of 3/ ({d} cells): ", .{top_neighbors.len});
    for (top_neighbors, 0..) |neighbor, i| {
        var buf: [64]u8 = undefined;
        try out.print(
            "{s}{s}",
            .{ try neighbor.toDebugString(&buf), if (i + 1 == top_neighbors.len) "\n" else ", " },
        );
    }
    // Keep the duplicate corner neighbors in upstream's published fixture.
    const expected_top = [_][]const u8{ "1/", "2/", "2/", "2/", "4/", "5/", "5/", "5/" };
    var expected_top_ids: [expected_top.len]s2.CellId = undefined;
    for (expected_top, 0..) |text, i| expected_top_ids[i] = try s2.CellId.fromDebugString(text);
    if (!sameCellsMultiset(top_neighbors, &expected_top_ids)) return SmokeError.NeighborMismatch;

    const zurich = try s2.CellId.fromDebugString("2/033020001100");
    const expected_zurich = [_][]const u8{
        "2/033020001030", "2/033020001033", "2/033020001101",
        "2/033020001102", "2/033020001103", "2/033031110010",
        "2/033031110011", "2/033031110322",
    };
    var zurich_buf: [16]s2.CellId = undefined;
    const zurich_neighbors = try zurich.allNeighbors(try zurich.level(), &zurich_buf);
    var expected_zurich_ids: [expected_zurich.len]s2.CellId = undefined;
    for (expected_zurich, 0..) |text, i| expected_zurich_ids[i] = try s2.CellId.fromDebugString(text);
    if (!sameCellsMultiset(zurich_neighbors, &expected_zurich_ids)) return SmokeError.NeighborMismatch;
    try out.writeAll("  all neighbours of the Zurich cell 2/033020001100:\n");
    for (expected_zurich) |text| {
        const want = try s2.CellId.fromDebugString(text);
        var buf: [64]u8 = undefined;
        try out.print("    {s}  (level {d}, face {d})\n", .{
            try want.toDebugString(&buf),
            try want.level(),
            try want.face(),
        });
    }
}

/// Compares cell multiplicities without relying on result order.
fn sameCellsMultiset(got: []const s2.CellId, want: []const s2.CellId) bool {
    if (got.len != want.len) return false;
    for (want) |one| {
        var want_count: usize = 0;
        var got_count: usize = 0;
        for (want) |other| {
            if (other.raw == one.raw) want_count += 1;
        }
        for (got) |cell| {
            if (cell.raw == one.raw) got_count += 1;
        }
        if (want_count == 0 or got_count != want_count) return false;
    }
    return true;
}

/// Prints the exact octant area and perimeter identities (`src/s2/s2loop_measures_test.cc:238-241`).
fn octantArea(out: *std.Io.Writer) !void {
    const vertices = [_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    };
    var loop = try s2.Loop.init(&vertices);
    defer loop.deinit();

    const area = try loop.area();
    const perimeter = try loop.perimeterRad();
    try out.print(
        "\noctant triangle: area {d:.15} sr (pi/2 = {d:.15}), perimeter {d:.15} rad (3pi/2 = {d:.15})\n",
        .{ area, std.math.pi / 2.0, perimeter, 3 * std.math.pi / 2.0 },
    );
    if (!approximatelyEqual(area, std.math.pi / 2.0, 1e-12)) return SmokeError.AreaMismatch;
    if (!approximatelyEqual(perimeter, 3 * std.math.pi / 2.0, 1e-12)) return SmokeError.AreaMismatch;

    try out.print("  contains its own middle: {}\n", .{
        try loop.containsPoint(try (s2.Point{ .x = 1, .y = 1, .z = 1 }).normalized()),
    });
    try out.print("  contains the -y mirror:  {}\n", .{
        try loop.containsPoint(try (s2.Point{ .x = 1, .y = -1, .z = 1 }).normalized()),
    });
    if (!try loop.containsPoint(try (s2.Point{ .x = 1, .y = 1, .z = 1 }).normalized())) {
        return SmokeError.ContainmentMismatch;
    }
    if (try loop.containsPoint(try (s2.Point{ .x = 1, .y = -1, .z = 1 }).normalized())) {
        return SmokeError.ContainmentMismatch;
    }

    var face_total: f64 = 0;
    for (0..6) |face| {
        face_total += try s2.Cell.init(try s2.CellId.fromFace(@intCast(face))).exactArea();
    }
    try out.print("  eight octants = {d:.15} sr; six face cells = {d:.15} sr (4pi = {d:.15})\n", .{
        8 * area,
        face_total,
        4 * std.math.pi,
    });
    if (!approximatelyEqual(8 * area, 4 * std.math.pi, 1e-12)) return SmokeError.AreaMismatch;
    if (!approximatelyEqual(face_total, 4 * std.math.pi, 1e-12)) return SmokeError.AreaMismatch;
}

/// Checks union/intersection areas for overlapping spherical wedges using spherical excess.
/// Shells are counter-clockwise and inputs satisfy unit-length tolerance (`src/s2/s2polygon.cc:406-414`; `src/s2/s2pointutil.cc:32-40`).
fn polygonBoolean(out: *std.Io.Writer) !void {
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
    var overlap = try s2.Polygon.intersection(xy, rotated);
    defer overlap.deinit();
    var combined = try s2.Polygon.unite(xy, rotated);
    defer combined.deinit();

    const xy_area = try xy.area();
    const rotated_area = try rotated.area();
    const overlap_area = try overlap.area();
    const combined_area = try combined.area();
    try out.print(
        "\npolygon boolean on two overlapping wedges: |A| {d:.15} (pi/2 = {d:.15}), |B| {d:.15}\n",
        .{ xy_area, std.math.pi / 2.0, rotated_area },
    );
    try out.print(
        "  |A and B| {d:.15} (pi/4 = {d:.15}), |A or B| {d:.15} (3pi/4 = {d:.15})\n",
        .{ overlap_area, std.math.pi / 4.0, combined_area, 3 * std.math.pi / 4.0 },
    );
    try out.print(
        "  |A| + |B| = {d:.15}; |A or B| + |A and B| = {d:.15}\n",
        .{ xy_area + rotated_area, combined_area + overlap_area },
    );
    if (!approximatelyEqual(xy_area, std.math.pi / 2.0, 1e-12)) return SmokeError.AreaMismatch;
    if (!approximatelyEqual(rotated_area, std.math.pi / 2.0, 1e-12)) return SmokeError.AreaMismatch;
    if (!approximatelyEqual(overlap_area, std.math.pi / 4.0, 1e-9)) return SmokeError.AreaMismatch;
    if (!approximatelyEqual(combined_area, 3 * std.math.pi / 4.0, 1e-9)) {
        return SmokeError.AreaMismatch;
    }
    if (!approximatelyEqual(xy_area + rotated_area, combined_area + overlap_area, 1e-9)) {
        return SmokeError.AreaMismatch;
    }
    if (!(overlap_area > 0 and overlap_area < xy_area)) return SmokeError.AreaMismatch;

    const at_22_5 = try s2.LatLng.fromDegrees(45, 22.5).toPoint();
    const at_67_5 = try s2.LatLng.fromDegrees(45, 67.5).toPoint();
    const at_112_5 = try s2.LatLng.fromDegrees(45, 112.5).toPoint();
    const only_a = try xy.containsPoint(at_22_5) and !try rotated.containsPoint(at_22_5);
    const only_b = !try xy.containsPoint(at_112_5) and try rotated.containsPoint(at_112_5);
    const either = try xy.containsPoint(at_67_5) and try rotated.containsPoint(at_67_5);
    const south = s2.Point{ .x = 0, .y = 0, .z = -1 };
    const neither = !try xy.containsPoint(south) and !try rotated.containsPoint(south);
    try out.print(
        "  in A only: {}; in B only: {}; in both: {}; in neither: {}\n",
        .{ only_a, only_b, either, neither },
    );
    if (!only_a or !only_b or !either or !neither) return SmokeError.ContainmentMismatch;
    if (!try combined.containsPoint(at_22_5)) return SmokeError.ContainmentMismatch;
    if (!try combined.containsPoint(at_112_5)) return SmokeError.ContainmentMismatch;
    if (!try combined.containsPoint(at_67_5)) return SmokeError.ContainmentMismatch;
    if (try overlap.containsPoint(at_22_5)) return SmokeError.ContainmentMismatch;
    if (try overlap.containsPoint(at_112_5)) return SmokeError.ContainmentMismatch;
    if (!try overlap.containsPoint(at_67_5)) return SmokeError.ContainmentMismatch;
    if (try combined.containsPoint(south)) return SmokeError.ContainmentMismatch;

    var empty = try s2.Polygon.empty();
    defer empty.deinit();
    var empty_complement = try empty.complement();
    defer empty_complement.deinit();
    const complement_area = try empty_complement.area();
    try out.print("  empty polygon area {d:.15}, its complement {d:.15} (4pi = {d:.15})\n", .{
        try empty.area(),
        complement_area,
        4 * std.math.pi,
    });
    if (!approximatelyEqual(complement_area, 4 * std.math.pi, 1e-12)) {
        return SmokeError.AreaMismatch;
    }
}

/// Checks a level-22 Sydney cell against upstream's `JavaCcConsistency` fixture (`src/s2/s2region_coverer_test.cc:534-563`).
/// A zero-radius cap is one point, so its covering must contain that point.
fn coveringASydneyPoint(out: *std.Io.Writer) !void {
    const sydney = s2.LatLng.fromDegrees(-33.8663457, 151.1960891);
    const published = [_][]const u8{
        "6b12ae36313d", "6b12ae36313f", "6b12ae363141", "6b12ae363143",
        "6b12ae363145", "6b12ae363159", "6b12ae36315b", "6b12ae363343",
        "6b12ae363345", "6b12ae36334d", "6b12ae36334f", "6b12ae363369",
        "6b12ae36336f", "6b12ae363371", "6b12ae363377", "6b12ae363391",
        "6b12ae363393", "6b12ae36339b", "6b12ae36339d", "6b12ae3633e3",
        "6b12ae3633e5", "6b12ae3633ed", "6b12ae3633ef", "6b12ae37cc11",
        "6b12ae37cc13", "6b12ae37cc1b", "6b12ae37cc1d", "6b12ae37cc63",
        "6b12ae37cc65", "6b12ae37cc6d", "6b12ae37cc6f", "6b12ae37cc89",
        "6b12ae37cc8f", "6b12ae37cc91", "6b12ae37cc97", "6b12ae37ccb1",
        "6b12ae37ccb3", "6b12ae37ccbb", "6b12ae37ccbd", "6b12ae37cea5",
        "6b12ae37cea7", "6b12ae37cebb",
    };

    const coverer = s2.Coverer{
        .min_level = 0,
        .max_level = 22,
        .level_mod = 1,
        .max_cells = std.math.maxInt(i32),
    };
    const cap = s2.Cap{ .center = sydney, .radius_deg = 0 };

    var buf: [4]s2.CellId = undefined;
    const covering = try coverer.coveringCap(cap, &buf);
    var token_buf: [64]u8 = undefined;
    const token = try covering[0].toToken(&token_buf);
    try out.print(
        "\ncovering the Sydney point ({d}, {d}) at level 22: {s} (level {d})\n",
        .{ sydney.lat_deg, sydney.lng_deg, token, try covering[0].level() },
    );

    var found = false;
    for (published) |candidate| {
        if (std.mem.eql(u8, candidate, token)) found = true;
    }
    try out.print("  among the {d} cells the JavaCcConsistency fixture publishes: {}\n", .{
        published.len,
        found,
    });
    if (!found) return SmokeError.IdMismatch;
    if (covering.len != 1) return SmokeError.NeighborMismatch;
}

/// Uses an absolute tolerance floor when the expected value is zero.
fn approximatelyEqual(a: f64, b: f64, tolerance: f64) bool {
    const difference = @abs(a - b);
    if (difference <= tolerance) return true;
    return difference <= tolerance * @max(@abs(a), @abs(b));
}
