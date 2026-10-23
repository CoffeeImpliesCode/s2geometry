// SPDX-License-Identifier: Apache-2.0

//! Consumer example for the published `s2geometry` module.
//! It compares cell, polygon, and covering results with upstream fixtures.
//! Runtime mode requires an explicit bridge provider; linked mode does not.

const std = @import("std");
const s2 = @import("s2geometry");

const ConsumerError = error{
    TokenMismatch,
    IdMismatch,
    NeighborMismatch,
    AreaMismatch,
    CoveredByWrongCell,
};

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// Environment variable used when `--provider <path>` is absent.
const provider_variable = "S2GEOMETRY_TEST_PROVIDER";

/// Returns the provider path from `--provider <path>` or the environment.
/// Requires an explicit path; it never searches or falls back to linked mode.
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
        "consumer: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export S2GEOMETRY_TEST_PROVIDER with a shared build of this " ++
            "package's own bridge -- the image exporting the 93 s2br_* entry " ++
            "points of zig/bridge.h, with libs2 and libabsl in its closure.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    try out.writeAll("s2geometry consumer\n");

    // Print the selected configuration and load only in runtime mode.
    if (comptime s2.runtime_loaded) {
        try s2.load(.{ .path = try providerRequest(init) });
        try out.print("loaded provider: {s}\n", .{s2.loadedSource().?.path});
    } else {
        try out.writeAll("linked\n");
    }

    // 1. The token codec, against golang/geo's published table.
    try out.writeAll("\npublished token/id pairs (golang/geo TestCellIDTokensNominal):\n");
    const token_cases = [_]struct { token: []const u8, id: u64 }{
        .{ .token = "1", .id = 0x1000000000000000 },
        .{ .token = "094", .id = 0x0940000000000000 },
        .{ .token = "166c4d1954", .id = 0x166c4d1954000000 },
        .{ .token = "48a23db9c2963e5b", .id = 0x48a23db9c2963e5b },
    };
    for (token_cases) |case| {
        const id = try s2.CellId.fromToken(case.token);
        var buf: [64]u8 = undefined;
        const token = try id.toToken(&buf);
        try out.print("  {s:>16} <-> 0x{x:0>16}  level {d}, face {d}\n", .{
            token,
            id.raw,
            try id.level(),
            try id.face(),
        });
        if (id.raw != case.id) return ConsumerError.IdMismatch;
        if (!std.mem.eql(u8, token, case.token)) return ConsumerError.TokenMismatch;
    }

    // A malformed token must be refused, not turned into the id 0.
    if (s2.CellId.fromToken("876b e99")) |_| {
        return ConsumerError.TokenMismatch;
    } else |_| {}

    // Leaf-cell results match golang/geo's published table.
    try out.writeAll("\npublished leaf cells (golang/geo TestCellIDLatLng):\n");
    const latlng_cases = [_]struct { id: u64, lat: f64, lng: f64 }{
        .{ .id = 0x47a1cbd595522b39, .lat = 49.703498679, .lng = 11.770681595 },
        .{ .id = 0x2b2bfd076787c5df, .lat = -25.285264027, .lng = 133.823116966 },
        .{ .id = 0xb112966aaaaaaaab, .lat = -69.219262171, .lng = 49.670072392 },
    };
    for (latlng_cases) |case| {
        const ll = s2.LatLng.fromDegrees(case.lat, case.lng);
        const leaf = try s2.CellId.fromLatLng(ll);
        const centre = try leaf.toLatLng();
        try out.print(
            "  ({d:.9}, {d:.9}) -> 0x{x:0>16}; cell centre ({d:.9}, {d:.9})\n",
            .{ case.lat, case.lng, leaf.raw, centre.lat_deg, centre.lng_deg },
        );
        if (leaf.raw != case.id) return ConsumerError.IdMismatch;
        if (@abs(centre.lat_deg - case.lat) > 1e-8) return ConsumerError.IdMismatch;
        if (@abs(centre.lng_deg - case.lng) > 1e-8) return ConsumerError.IdMismatch;
    }

    // Compare edge neighbors in order; compare all-neighbors as an unordered multiset.
    // The upstream fixtures specify order only for the edge-neighbor case.
    try out.writeAll("\nneighbours (google/s2geometry fixtures):\n");
    const face1_edges = try (try s2.CellId.fromFace(1)).edgeNeighbors();
    const expected_edge_faces = [_]u8{ 5, 3, 2, 0 };
    try out.writeAll("  edge neighbours of face 1: ");
    for (face1_edges, 0..) |neighbor, i| {
        const face = try neighbor.face();
        try out.print("{d}{s}", .{ face, if (i == 3) "\n" else ", " });
        if (face != expected_edge_faces[i]) return ConsumerError.NeighborMismatch;
    }

    const top = try s2.CellId.fromDebugString("3/");
    var neighbor_buf: [16]s2.CellId = undefined;
    const top_neighbors = try top.allNeighbors(try top.level(), &neighbor_buf);
    const expected_top_faces = [_]u8{ 1, 2, 2, 2, 4, 5, 5, 5 };
    if (top_neighbors.len != expected_top_faces.len) return ConsumerError.NeighborMismatch;
    try out.writeAll("  all neighbours of 3/: ");
    var got_top_faces: [expected_top_faces.len]u8 = undefined;
    for (top_neighbors, 0..) |neighbor, i| {
        got_top_faces[i] = try neighbor.face();
        try out.print("{d}{s}", .{ got_top_faces[i], if (i + 1 == got_top_faces.len) "\n" else ", " });
    }
    // Sort to compare the unordered fixture as a multiset, including duplicates.
    std.mem.sort(u8, &got_top_faces, {}, std.sort.asc(u8));
    for (expected_top_faces, 0..) |want, i| {
        if (got_top_faces[i] != want) return ConsumerError.NeighborMismatch;
    }

    // The positive-axis triangle is an octant of area pi/2 steradians.
    // Inclusion-exclusion checks its union with a neighboring octant.
    var octant = try s2.Polygon.init(&[_][3]f64{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    });
    defer octant.deinit();
    var neighbour = try s2.Polygon.init(&[_][3]f64{
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
        .{ -1, 0, 0 },
    });
    defer neighbour.deinit();
    var combined = try s2.Polygon.unite(octant, neighbour);
    defer combined.deinit();
    var overlap = try s2.Polygon.intersection(octant, neighbour);
    defer overlap.deinit();

    const octant_area = try octant.area();
    try out.print("\noctant area {d:.15} sr (pi/2 = {d:.15})\n", .{
        octant_area,
        std.math.pi / 2.0,
    });
    if (@abs(octant_area - std.math.pi / 2.0) > 1e-12) return ConsumerError.AreaMismatch;

    const combined_area = try combined.area();
    const overlap_area = try overlap.area();
    try out.print("union {d:.15} + intersection {d:.15} = {d:.15}; |A| + |B| = {d:.15}\n", .{
        combined_area,
        overlap_area,
        combined_area + overlap_area,
        octant_area + (try neighbour.area()),
    });
    if (@abs((combined_area + overlap_area) - (octant_area + (try neighbour.area()))) > 1e-12) {
        return ConsumerError.AreaMismatch;
    }

    // Match the upstream Sydney covering fixture with a level-22 zero-radius cap.
    // The containing cell must be one of the published tokens.
    const published_sydney_tokens = [_][]const u8{
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
    const sydney = s2.LatLng.fromDegrees(-33.8663457, 151.1960891);
    const coverer = s2.Coverer{
        .min_level = 0,
        .max_level = 22,
        .level_mod = 1,
        .max_cells = std.math.maxInt(i32),
    };
    var covering_buf: [4]s2.CellId = undefined;
    const covering = try coverer.coveringCap(
        .{ .center = sydney, .radius_deg = 0 },
        &covering_buf,
    );
    var token_buf: [64]u8 = undefined;
    const sydney_token = try covering[0].toToken(&token_buf);
    try out.print(
        "\ncovering Sydney ({d:.7}, {d:.7}) at level 22: {s} (level {d}, {d} cell)\n",
        .{
            sydney.lat_deg,
            sydney.lng_deg,
            sydney_token,
            try covering[0].level(),
            covering.len,
        },
    );

    var published_match = false;
    for (published_sydney_tokens) |candidate| {
        if (std.mem.eql(u8, candidate, sydney_token)) published_match = true;
    }
    if (!published_match) return ConsumerError.CoveredByWrongCell;
    if (covering.len != 1) return ConsumerError.CoveredByWrongCell;

    // The six face areas tile the sphere and sum to 4*pi.
    var faces_total: f64 = 0;
    for (0..6) |face| {
        const id = try s2.CellId.fromFace(@intCast(face));
        faces_total += try s2.Cell.init(id).exactArea();
        const centre = try s2.Cell.init(id).center();
        if (!try s2.Cell.init(id).containsPoint(centre)) {
            return ConsumerError.AreaMismatch;
        }
    }
    try out.print("six face cells: {d:.15} sr (4pi = {d:.15})\n", .{
        faces_total,
        4 * std.math.pi,
    });
    if (@abs(faces_total - 4 * std.math.pi) > 1e-12) return ConsumerError.AreaMismatch;

    try out.writeAll("\nall consumer checks agree with their published sources\n");
    try out.flush();
}
