// SPDX-License-Identifier: Apache-2.0
//
//! S2 geometry's side of the runtime loader: the names its synchronization
//! binding has, and what it requires of a provider beyond resolving its symbols.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig` is
//! the state machine and the platform layer; `runtime/generate.zig` builds the
//! dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them this
//! SDK's, and it is the file another SDK replaces.
//!
//! ## What a provider must be
//!
//! All **93** entry points `zig/bridge.h` declares, all of them, because that
//! header *is* the library's whole declared C surface and a caller reaching
//! `s2.CellId` or the raw `s2.c` namespace behind it must find the same image
//! behind every name it can see.
//!
//! 88 of them return `S2BridgeStatus`: the `s2br_cell_*`, `s2br_latlng_*`,
//! `s2br_point_*`, `s2br_cap_*`, `s2br_rect_*`, `s2br_loop_*`,
//! `s2br_polygon_*` and `s2br_coverer_covering_*` families, each one declared
//! `S2BridgeStatus s2br_…` at the head of a line in `zig/bridge.h`. Three
//! return `int` and are total functions rather than fallible ones
//! (`zig/bridge.h:182`, `:211`, `:214`): `s2br_cell_is_valid`,
//! `s2br_cell_is_leaf` and `s2br_cell_is_face`. Two return `void`
//! (`zig/bridge.h:484`, `:596`): `s2br_loop_destroy` and
//! `s2br_polygon_destroy`, the matching frees for the two opaque handles.
//!
//! `zig/bridge.cc` defines 93, with the same names. Nothing is optional, and
//! nothing is configuration-dependent: `S2BRIDGE_MAX_LEVEL` is a macro
//! (`zig/bridge.h:122`), so it is a translated constant rather than an object a
//! provider has to export, and the header declares no `extern` variable at all,
//! so the table has no data entry and the dispatch has no `…Addr()` accessor.
//!
//! ## Which image a provider is
//!
//! Every one of those 93 symbols is defined in `zig/bridge.cc`, in this
//! repository. An upstream `libs2` at any version exports **none** of them:
//! upstream has no `s2br_*` header, and `zig/bridge.h:11-17` says why one is
//! needed at all -- `addTranslateC` translates C, and upstream's library is
//! C++17 with classes, virtual `S2Region` dispatch and `absl::string_view`.
//!
//! So the loadable provider for this SDK is a shared **bridge**: this
//! package's own `libs2bridge.so.0` (`.dylib` / `s2bridge.dll`), whose
//! `DT_NEEDED` closure carries `libs2.so.0` and, through it, `libabsl.so.2508`.
//! Naming an installed `libs2.so` is not a weaker provider, it is not a provider
//! at all: the load refuses it with `MissingSymbol` at the first lookup, which
//! is the honest answer rather than a half-working configuration.
//!
//! In `-fsys=s2` mode the situation is the same and for the same reason: that
//! mode still compiles the bridge from `zig/bridge.cc` against installed headers
//! (`build.zig`, `addSystemMode`), because a bridge built against installed
//! sources would be a bridge to nothing. What changes is which S2 and which
//! Abseil the loaded `libs2bridge` closes over.
//!
//! ## The ABI boundary, stated honestly
//!
//! A provider must be this fork's bridge, built from a `zig/bridge.h` identical
//! to the one this build translated, over an S2 and an Abseil it can actually
//! link. The facts that make that more than a sentence:
//!
//!   * **Scalars.** The surface is `double`, `uint64_t`, `int32_t`, `int` and
//!     `size_t` (`zig/bridge.h` throughout). A cell id *is* the whole 64-bit
//!     integer (`zig/bridge.h:133-136`), so nothing about the cell-id layout is
//!     re-derived on this side of the boundary and the width is the ABI.
//!   * **Layout.** `S2BridgeCovererOptions` is four `int32_t` in the order
//!     `min_level`, `max_level`, `level_mod`, `max_cells`
//!     (`zig/bridge.h:701-706`) and is passed by pointer. The provider reads
//!     that struct; a different field order is a different program.
//!   * **Opaque handles.** `S2BridgeLoop` and `S2BridgePolygon` are incomplete
//!     struct types (`zig/bridge.h:125`, `:128`): the storage is allocated and
//!     freed by C++ on the provider's side (`zig/bridge.h:75-78`). No caller and
//!     no Zig code ever dereferences one; a provider whose `s2br_*_create`
//!     returns something other than a pointer it can free is a provider whose
//!     free will fault.
//!   * **Allocator.** There is exactly one allocator in the picture and it is
//!     the provider's: `S2Loop::Init` copies its input and allocates through
//!     C++ `new` (`s2/s2loop.cc:201-207`), and every list-returning entry point
//!     destroys upstream's `std::vector` before it returns
//!     (`zig/bridge.h:80-83`). Nothing crosses the boundary as a heap block, so
//!     there is no cross-runtime allocator requirement and no `std::bad_alloc`
//!     can travel outward -- the bridge maps that one exception itself
//!     (`zig/bridge.h:64-67`).
//!   * **Calling convention and target.** Plain C, through `extern "C"` guards
//!     (`zig/bridge.h:95-97`, `:757-759`), so the platform's C ABI is the
//!     requirement -- including that a provider built for a different
//!     architecture is not a provider for this one.
//!
//! What is deliberately **not** part of the boundary:
//!
//!   * Which SIMD or ABI variant of Abseil the provider was compiled with.
//!   * Whether the provider's S2 was built with `--s2debug` on. The bridge
//!     disables it per object (`zig/bridge.h:39-63`), so that flag is upstream's
//!     behaviour rather than this route's, and nothing in the 93 declarations
//!     depends on it.
//!   * The C++ runtime the provider links. It is the provider's own business;
//!     the boundary here is C.
//!
//! ## What is checked at load time, and what is not
//!
//! Resolving the symbols and translating the header are the boundary. They are
//! not proof that a provider is compatible, and this file does not pretend to
//! add one. Seven calls are made after every symbol resolved and before
//! anything is published, in four checks, and each one asks the entry points to
//! *behave* rather than to name a version:
//!
//!   * `s2br_cell_from_token("1", 1, …)` must answer `S2BRIDGE_OK` and produce
//!     `0x1000000000000000`. That is the face-0 level-0 cell, the first row of
//!     the token table golang/geo publishes for the same codec
//!     (`s2/cellid_test.go` `TestCellIDTokensNominal`, recorded in this
//!     repository as `testdata/golang_cellid_tokens.tsv`), so a provider that
//!     answers with anything else is not computing the S2 cell ids this header
//!     describes.
//!   * `s2br_cell_level` and `s2br_cell_face` on that id must answer `0` and
//!     `0`. Together with the previous check they exercise the `int *`
//!     out-parameter and the `uint64_t` scalar argument at once.
//!   * `s2br_loop_create` over the three positive axes must answer
//!     `S2BRIDGE_OK`, `s2br_loop_num_vertices` must answer `3`, and
//!     `s2br_loop_destroy` must accept the handle. That is a real allocation
//!     and a real release inside the provider, which is what proves the loaded
//!     image carries a working S2 and Abseil closure rather than resolving
//!     93 names and then failing on the first call.
//!
//! A fourth check covers the one layout fact that a scalar round trip does not:
//! `s2br_coverer_covering_cell` is called as the sizing pass -- a `NULL`
//! buffer and `cap == 0` -- with an `S2BridgeCovererOptions` this file builds
//! itself. `OK` with `*out_count == 1` means the provider read the struct
//! fields where this build's translation says they are. It is the documented
//! two-pass contract (`zig/bridge.h:69-74`) and the same call `tests.zig`
//! asserts, so it is the shape every list-returning entry point has.
//!
//! None of that proves the whole 93, and none of it can: a load-time check is
//! this file talking to the provider, and it only knows the header. It does not
//! inspect S2's internal layout, and no check here could.

const rt = @import("rt");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.h` compiled with
/// `RT_SYNC_PREFIX=s2geometry_rt`, which is what `runtime/graph.zig` passes.
/// Two spellings of that prefix have to agree: this file names the symbols,
/// and graph.zig defines the macro. A build where they disagree does not link,
/// and that is the whole error report: there is no runtime path that could hide
/// it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which is
/// what lets two SDKs, or two configurations of one SDK, hold their own loader
/// state in one process without sharing any of it.
pub const Sync = struct {
    extern fn s2geometry_rt_lock() void;
    extern fn s2geometry_rt_unlock() void;
    extern fn s2geometry_rt_wait() void;
    extern fn s2geometry_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK targets: 64 bits on x86_64, aarch64, riscv64 and wasm32.
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

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch itself
/// so that this file never has to import it. The direction is one-way on
/// purpose: the descriptor knows what the loader needs, the dispatch knows what
/// the header said, and neither imports the other.
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

        /// The checks, run after every symbol resolved and before anything is
        /// published.
        ///
        /// Each one asks the provider to compute a fact this file can state
        /// independently: the level-0 cell the token `1` names, what face and
        /// level that cell reports, how many vertices an octant loop has, and
        /// how many cells cover one cell. The answers come from golang/geo's
        /// published codec table, from the id layout `zig/bridge.h:133-136`
        /// documents, and from `tests.zig`; none of them is a version string,
        /// and none of them is a value this file asks the provider to echo back.
        pub fn validate(dst: *const table) ?[]const u8 {
            const ok = dispatch.S2BRIDGE_OK;

            // The token `1` is the face-0 level-0 cell, published by golang/geo
            // for the same codec this bridge wraps. A provider that computes
            // S2 cell ids answers with exactly this integer.
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

            // A real allocation and a real release inside the provider. The
            // octant through the three positive axes is the loop `tests.zig`
            // builds, so three vertices is the answer upstream's own
            // `S2Loop::Init` gives for it.
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
            // From here the handle exists, so every path out of this function
            // has to release it. A provider that answered `OK` and then cannot
            // read the loop back is refused, and it is released first.
            defer dst.s2br_loop_destroy(loop);

            var vertices: c_int = 0;
            if (dst.s2br_loop_num_vertices(loop, &vertices) != ok or vertices != 3) {
                return "s2br_loop_num_vertices did not report the three vertices " ++
                    "s2br_loop_create was just given, so this provider's loop " ++
                    "handling is not what this header describes";
            }

            // The one struct this boundary passes by pointer, read back through
            // the documented two-pass sizing call (`zig/bridge.h:69-74`): a NULL
            // buffer and `cap == 0` report the length and write nothing. A cell
            // covers itself, so the length is one cell.
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