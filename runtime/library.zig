// SPDX-License-Identifier: Apache-2.0
//
//! S2-specific descriptor for the runtime loader: bridge symbols, synchronization, and validation.
//! Providers must be this fork's C bridge, not upstream `libs2`.

const rt = @import("rt");

/// Synchronization symbols exported by this SDK's namespaced sync object.
/// Their prefix must match `sync_prefix` in `runtime/graph.zig`.
pub const Sync = struct {
    extern fn s2geometry_rt_lock() void;
    extern fn s2geometry_rt_unlock() void;
    extern fn s2geometry_rt_wait() void;
    extern fn s2geometry_rt_broadcast() void;
    // Matches the C `unsigned long long` type on every supported target.
    extern fn s2geometry_rt_thread_self() u64;

    pub fn lock() void {
        s2geometry_rt_lock();
    }
    pub fn unlock() void {
        s2geometry_rt_unlock();
    }
    pub fn wait() void {
        s2geometry_rt_wait();
    }
    pub fn broadcast() void {
        s2geometry_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return s2geometry_rt_thread_self();
    }
};

/// Configures the loader for the generated dispatch table.
/// The dispatch supplies its type, keeping the import graph one-way.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "s2geometry";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated header, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        /// One resolved address into one optional table field, and the empty
        /// case beside it. Both index `optional_symbols`, not `symbols`.
        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// Validates representative provider behavior before publishing the table.
        /// Returns a diagnostic when any check fails.
        pub fn validate(dst: *const table) ?[]const u8 {
            const ok = dispatch.S2BRIDGE_OK;

            // Token `1` is the published face-0 level-0 cell id.
            const face_zero: u64 = 0x1000000000000000;
            var decoded: u64 = 0;
            if (dst.s2br_cell_from_token("1", 1, &decoded) != ok) {
                return "s2br_cell_from_token(\"1\") did not report success, so this " ++
                    "provider is not computing the S2 cell ids this header describes";
            }
            if (decoded != face_zero) {
                return "s2br_cell_from_token(\"1\") produced a cell id other than the " ++
                    "face-0 level-0 cell 0x1000000000000000 that golang/geo publishes " ++
                    "for that token, so this provider's cell-id layout is not the one " ++
                    "this header was translated from";
            }

            var level: c_int = 0;
            if (dst.s2br_cell_level(face_zero, &level) != ok or level != 0) {
                return "s2br_cell_level did not report level 0 for the face-0 cell " ++
                    "that its own token codec just produced, so its int out-parameter " ++
                    "or its level decoding is not what this header describes";
            }
            var face: c_int = 0;
            if (dst.s2br_cell_face(face_zero, &face) != ok or face != 0) {
                return "s2br_cell_face did not report face 0 for that same cell, so " ++
                    "this provider's face decoding disagrees with its own codec";
            }

            // Verify that provider allocation, vertex access, and release work.
            const octant = [_][3]f64{
                .{ 1, 0, 0 },
                .{ 0, 1, 0 },
                .{ 0, 0, 1 },
            };
            var loop: ?*dispatch.S2BridgeLoop = null;
            if (dst.s2br_loop_create(@ptrCast(&octant), octant.len, &loop) != ok or
                loop == null)
            {
                return "s2br_loop_create did not build a loop from three unit " ++
                    "vertices, so this provider cannot allocate the opaque handle its " ++
                    "own free expects";
            }
            // Release the handle on every path after creation.
            defer dst.s2br_loop_destroy(loop);

            var vertices: c_int = 0;
            if (dst.s2br_loop_num_vertices(loop, &vertices) != ok or vertices != 3) {
                return "s2br_loop_num_vertices did not report the three vertices " ++
                    "s2br_loop_create was just given, so this provider's loop " ++
                    "handling is not what this header describes";
            }

            // A null buffer with zero capacity reports the covering size without writing.
            // This also checks the by-pointer options layout.
            const options: dispatch.S2BridgeCovererOptions = .{
                .min_level = 0,
                .max_level = 0,
                .level_mod = 1,
                .max_cells = 8,
            };
            var count: usize = 0;
            if (dst.s2br_coverer_covering_cell(face_zero, &options, null, 0, &count) != ok) {
                return "s2br_coverer_covering_cell did not accept its sizing call, so " ++
                    "this provider did not read S2BridgeCovererOptions where this " ++
                    "build's translation says its fields are";
            }
            if (count != 1) {
                return "s2br_coverer_covering_cell reported a covering of a single " ++
                    "cell that is not one cell long, so its out_count out-parameter " ++
                    "is not what this header describes";
            }
            return null;
        }
    };
}
