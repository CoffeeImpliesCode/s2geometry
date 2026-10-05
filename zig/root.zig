// SPDX-License-Identifier: Apache-2.0

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
//! ## Import routes
//!
//! `@import("s2geometry")` is the only import a Zig consumer declares: the
//! module carries `link_libc`, the bridge artifact in whichever `-Dlinkage`
//! selected (`libs2bridge.a`, or `libs2bridge.so.0` under its own soname), and
//! the C++ runtime that route supplies -- see "Compiler, target and provider
//! boundary" below for which runtime each route gets, and why it is one
//! shared object rather than a private one per image. A dependent states no
//! include path and links no library. What it publishes is `Error`,
//! `max_level`, `num_faces`, the ten value types below,
//! `c`, and the five names the loader route needs in either configuration:
//! `runtime_loaded`, `LoadSource`, `LoadError`, `load` and `loadedSource`.
//! There is no other exported name. A C++ consumer is a separate route with a
//! separate surface -- it includes the installed upstream headers and links
//! the installed archive directly -- and this module does not describe it.

//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says which
//! at comptime.
//!
//! *Linked* is the default. `libs2bridge`, `libs2` and `libabsl` are linked,
//! `c` is the translated header, and every call below is a direct call with no
//! table and no check. That is the configuration every recorded gate in this
//! repository has exercised, including the `wasm32-wasi` one.
//!
//! *Runtime-loaded* is opt-in (`-Druntime=true`). No native archive is linked;
//! `c` is a dispatch generated from the same translation step's output, and all
//! **93** entry points `zig/bridge.h` declares are resolved through the
//! platform loader when the caller calls
//!
//! ```zig
//! try s2.load(.{ .path = "/opt/s2geometry/lib/libs2bridge.so.0" });
//! ```
//!
//! before using anything else. A call into a module that has not loaded stops
//! the program with a message naming the function, in every optimization mode.
//! That is a programming error rather than a recoverable condition: the table
//! does not exist yet and there is no partial state to fall back on.
//!
//! The provider is reached, never guessed. `.path` names a file and `.system`
//! names a library for the platform loader; neither falls back to the other,
//! there is no unload and no reset, and the module keeps the handle and its own
//! copy of the request to the end of the process.
//!
//! **What a provider has to be.** A shared build of *this* package's bridge,
//! `libs2bridge.so.0`. Every `s2br_*` symbol is defined in `zig/bridge.cc` in
//! this repository, so an installed upstream `libs2.so` exports none of them
//! and is refused with `MissingSymbol`: upstream has no `s2br_*` header at all,
//! because `addTranslateC` translates C and S2 is C++17
//! (`zig/bridge.h:11-17`). `runtime/library.zig` writes out the whole boundary
//! -- scalars, the `S2BridgeCovererOptions` layout, the opaque handles, the
//! single provider-side allocator -- and what the load actually checks.
//!
//! `wasm32-wasi` is a supported target for this SDK and stays one: the linked
//! configuration is exactly as complete there as anywhere else. Runtime loading
//! on that target is refused at run time with `error.UnsupportedTarget`,
//! because WASI has no `dlopen`; that is the loader's honest answer and it is
//! not a reason to exclude the target from the build.
//!
//! Everything below is identical in both configurations. `Point`, `LatLng`,
//! `CellId`, `Cell`, `Cap`, `LatLngRect`, `Loop`, `Polygon` and `Coverer` are
//! the same types either way, because every type and constant in the dispatch
//! is re-exported from the translation rather than restated.
//!
//! ## What this module does not wrap
//!
//! `S2Builder` and the `s2builderutil` family, the closest-point, closest-edge
//! and closest-cell queries, the fractal generators, the shape-index queries,
//! the coded and encoded vector and string types, the terminology indexers and
//! the C++ template headers. That is a coverage decision, not a gap in the
//! library: the build installs the whole upstream archive and every upstream
//! header, and a C++ consumer reaches all of it through `#include <s2/...>`.
//! `README.zig.md` records the decision and what it cost. `c` is the route to a
//! bridge entry point this facade does not name.
//!
//! ## Compiler, target and provider boundary
//!
//! Zig 0.16.0, which is the `minimum_zig_version` this package declares. The
//! bundled graph needs nothing else: `libs2`, `libabsl` and this fork's own
//! `libs2bridge` are compiled from this tree -- an archive for the static
//! delivery, a shared object with upstream's own soname for
//! `-Dlinkage=dynamic` -- and nothing is downloaded at build time.
//!
//! The C and C++ *runtime* is a separate provider, and which one is a fact
//! about the route rather than a choice a caller makes:
//!
//!   * A linked static delivery on a non-WASI target sets `link_libcpp`, so the
//!     C++ runtime is Zig's own ordinary static one. Two images each carrying
//!     it do not share one `std::locale` facet registry, which is why the
//!     route below exists at all.
//!   * On an ELF target with `-Dlinkage=dynamic`, and only there, `link_libcpp`
//!     is off and the graph links this package's own `libs2cpp.so.0` instead:
//!     the pinned compiler's shipped libc++, libc++abi and libunwind, compiled
//!     once with shared-library visibility and shared by every image in the
//!     process rather than embedded a second time.
//!   * `wasm32-wasi` keeps the installed SDK's C++ runtime and the Darwin
//!     targets the platform's own, and neither route compiles one. Apple
//!     targets additionally need a real CoreFoundation provider that this
//!     package declares and links but does not supply.
//!   * Under `-Druntime=true` the module links no native artifact at all, so it
//!     names no C++ runtime: the provider this module loads brings its own
//!     closure with it.
//!
//! `-fsys=s2` binds the same bridge to an installed S2 and Abseil instead of
//! the bundled core. `README.zig.md` states each mode, its options and its
//! recorded results; none of that is restated as a guarantee here, and no
//! target is claimed without the driver having run it.
//!
//! ## Allocation
//!
//! A `CellId`, a `LatLng`, a `Point`, a `Cell`, a `Cap` and a `LatLngRect` are
//! plain values: no allocation, nothing to free. `Loop` and `Polygon` own C++
//! storage and their `deinit` releases it through `s2br_*_destroy`; a `deinit`
//! after a failed `init` is safe, because the bridge accepts a null handle.
//! List-returning calls write into a buffer the caller owns and never allocate
//! on the Zig side; the one allocation they may perform is upstream's own, and
//! that is released before the call returns. Both `deinit` calls run in C++,
//! so a Zig leak checker never sees either the `Loop`/`Polygon` storage or its
//! release: reaching them is the caller's obligation, not something a test
//! framework can check for it.
//!
//! ## Ownership across the boundary
//!
//! The vertex arrays this module accepts are *borrowed for the call*: `Loop.init`,
//! `Polygon.init` and `Polygon.initLoops` read them and keep no reference,
//! because `S2Loop::Init` copies them (`s2/s2loop.cc:201-207`). The caller's
//! buffer is free to go out of scope the moment the call returns. Output buffers
//! are likewise borrowed for the duration of the call and written only inside
//! their own length.
//!
//! The value types are the other side of that rule: each is a plain struct of
//! scalars, so a copy is independent, shares nothing with the original and
//! needs no address to stay valid. `Loop` and `Polygon` are not values in that
//! sense -- see their own documentation for the one-owner rule.
//!
//! ## Shortest sequence
//!
//! ```zig
//! const std = @import("std");
//! const s2 = @import("s2geometry");
//!
//! pub fn main() !void {
//!     // A value: nothing to release, nothing retained.
//!     const sydney = s2.LatLng.fromDegrees(-33.8688, 151.2093);
//!     const cell = try s2.CellId.fromLatLng(sydney);
//!
//!     // A caller-owned buffer. The result borrows `token_buf` and stays
//!     // valid only while it does.
//!     var token_buf: [17]u8 = undefined;
//!     std.debug.print("{s}\n", .{try cell.toToken(&token_buf)});
//!
//!     // A two-pass list: ask for the count, size a buffer, then fill it.
//!     const cap = s2.Cap{ .center = sydney, .radius_deg = 0.5 };
//!     const coverer: s2.Coverer = .{ .max_cells = 8 };
//!     const n = try coverer.coveringCapCount(cap);
//!     const ids = try std.heap.page_allocator.alloc(s2.CellId, n);
//!     defer std.heap.page_allocator.free(ids);
//!     std.debug.print("{} cells\n", .{(try coverer.coveringCap(cap, ids)).len});
//!
//!     // An owned handle: exactly one `deinit`, on every path that owns it.
//!     const vertices = [3][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
//!     var loop = try s2.Loop.init(&vertices);
//!     defer loop.deinit();
//!     std.debug.print("{d}\n", .{(try loop.numVertices())});
//! }
//! ```
//!
//! Only `Loop` and `Polygon` are released by this module, once each, through
//! `deinit`. Every other value, buffer and count above belongs to the caller:
//! `token_buf` is a stack slot, and `ids` is freed by the allocator that made
//! it. A `deinit` reached on a failed `init` is safe, because the bridge
//! accepts a null handle; a second `deinit`, or a `deinit` of a copy that does
//! not own the storage, is a double free.
//!
//! ## Two-pass lists
//!
//! Every list-returning method is paired with a `…Count` method that is its own
//! bridge entry point and reports the length the list will have. That count is
//! how a caller sizes its buffer. The filling call is not itself a sizing
//! probe: a buffer shorter than the count -- an empty one included -- is
//! `error.BufferTooSmall`, with nothing written into it.
//!
//! The bridge does report the required length on the way to that refusal, and
//! that is what `zig/bridge.h` documents for the raw C surface. This module
//! does not pass it through: a caller of a filling call learns the error and
//! nothing else, which is why the count has to come from the `…Count` call
//! rather than from a failed fill. The two cannot disagree, and the pattern is
//! the three lines of `Shortest sequence` above.
//!
//! `CellId.toToken` and `CellId.toDebugString` follow the same rule with the
//! NUL counted, so `buf.len` must exceed the text's length rather than reach
//! it, and neither returns that length on the refusal: size `buf` from
//! `toToken`'s 17-byte bound.
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
//! which upstream turns on by default in debug-mode builds, including fastbuild
//! (`s2/s2debug.h:18-21`, `s2/s2debug.h:60-62`). The bridge therefore builds
//! every handle with `S2Debug::DISABLE`, the per-object opt-out upstream
//! documents for a caller that validates explicitly (`s2/s2debug.h:30-40`,
//! `s2/s2loop.h:111-124`, `s2/s2polygon.h:126-148`, `s2/s2loop.h:159-174`,
//! `s2/s2polygon.h:210-223`). What counts as invalid is still upstream's
//! answer, computed by upstream's validator; nothing here re-decides it.
//!
//! Two boundaries of that promise are worth stating. A vertex is required to
//! be a unit-length direction -- upstream says so (`s2/s2loop.h:126-130`) and
//! says that its own check comes too late to be one, because construction
//! reaches the exact predicate that assumes unit length
//! (`s2/s2loop.cc:228-231`, `s2/s2predicates.h:394`). `Loop.init`,
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
//! Everything except `Loop` and `Polygon` is a value: it holds no pointer and
//! keeps no state between calls, so copies of it are independent and may be
//! read from several threads at once. A `Loop` or `Polygon` owns a C++ object
//! with mutable state, and the upstream types carry no locking of their own, so
//! one handle belongs to one thread at a time. Whether two *different* handles
//! may be used concurrently is a question about upstream, and this module makes
//! no claim about it.
//!
//! ## Escape hatch
//!
//! `pub const c` is the translated bridge: this fork's own C surface over
//! upstream, not an upstream header, and reachable as a Zig namespace of
//! `extern "C"` functions, status constants, the `S2BridgeCovererOptions`
//! struct and the two opaque handle types. It exists for a caller who needs a
//! call this module does not name.
//!
//! Nothing above applies to it. A caller who goes through `c` owns every
//! guarantee themselves: the status-to-`Error` mapping, the checked indices,
//! the buffer contract, the single-owner rule and the borrow rules are all
//! implemented in the facade, not in the bridge. Its statuses and its
//! `NULL`-accepting destroy calls are the contract `zig/bridge.h` documents in
//! its own comments.
//!
//! In a runtime-loading build this module is a generated dispatch instead of
//! the translation step's own output. It publishes the same namespace: every
//! type, constant and entry point is re-exported or wrapped from the
//! translation rather than restated, so `Loop`'s `raw` handle is the same
//! nominal type either way. What differs is how a name reaches the library. In
//! the linked configuration it is a direct call; in the runtime-loaded one it
//! is a call through a table that `load` fills, and a call before that fill
//! stops the program.

const std = @import("std");

/// The loader core, which is where a linked build's two public types come from.
///
/// It is imported only by the linked configuration. In a runtime-loading build
/// the dispatch carries its own copy of the same declarations and this module
/// is never referenced, so it is never resolved and never compiled. Either way
/// there is exactly one `LoadSource` and one `LoadError` in a build, which is
/// what keeps them one type for a consumer that names them.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where `libs2bridge` is linked and `c` is the
/// translated header itself. True when the build generated a dispatch that
/// resolves the same symbols through the platform loader, in which case `load`
/// is the call that makes the library usable.
///
/// It is a comptime constant, so a consumer can write two different code paths
/// and have only the one it chose analyzed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit file path and `.system` is an explicit name for the
/// platform loader. There is no path-to-system fallback and no implicit
/// fallback of any kind; a request that cannot be honoured is an error, not a
/// different library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside
/// the loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then
/// use this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `ProviderMismatch`, and the library already in use stays in use.
/// A failed attempt publishes nothing and can be retried explicitly by calling
/// this again: there is no automatic retry, and no implicit second source.
///
/// It keeps the process handle and its own copy of the request to the end of
/// the process. There is no unload and no reset, because the table is
/// process-global state that other code may already have called through.
///
/// Safe to call from any thread. A thread that arrives while an attempt for the
/// same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports
/// both configurations can tell the two apart at comptime instead of meeting
/// this at run time.
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

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life of
/// the process. Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (comptime !runtime_loaded) return null;
    return c.loadedSource();
}

/// The translated `zig/bridge.h`: this fork's own C surface over upstream C++,
/// not an upstream header, and the documented way to reach a call this module
/// does not wrap.
///
/// See `Escape hatch` in the module documentation for what a caller gives up
/// by using it: none of this module's checked indices, buffer contracts,
/// ownership rules or error mapping apply to a call made here.
pub const c = @import("c");

/// What this module reports, cut at the bridge's five statuses and the
/// conditions this code checks:
///
///  * `InvalidArgument` for an argument upstream rejects or has not defined:
///    a coordinate that is not finite, a token or debug string its parser
///    refuses, a level, face or index outside the documented range, a vertex
///    that is not a unit-length direction, a `Coverer` whose own fields
///    contradict each other, and an invalid operand of a boolean polygon
///    operation.
///  * `BufferTooSmall` for a caller buffer too short -- a required list length,
///    or a string and its NUL. Nothing is written into the buffer. A
///    zero-length buffer is a refusal like any other short one, not a sizing
///    call that succeeds, and the required length the bridge computed on the
///    way to refusing is not returned here. A list that is genuinely empty has
///    nothing to write, so it returns an empty slice rather than this error.
///  * `OutOfMemory` when an upstream C++ allocation failed: a real condition,
///    reported rather than swallowed.
///  * `Internal` when upstream reported failure through its own status -- a
///    boolean polygon operation that failed for two valid operands, which
///    upstream documents as not something that can happen
///    (`s2/s2polygon.h:385-388`) -- and also when the bridge returns a status
///    this set does not name.
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
/// caller of the raw surface learns. Slicing with the reported count before
/// this check would read past the end, which is why every list method goes
/// through here. This function turns that report into the error rather than
/// handing the count back, which is exactly why a zero-length buffer is a
/// refusal here and not a sizing call.
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
/// This is upstream's `S2Point` (`s2/s2point.h:31-36`), a plain 3-vector
/// (`s2/util/math/vector.h`). The bridge builds one
/// component at a time and hands one back the same way, so nothing here depends
/// on that layout being shared with anything. Upstream expects a point to be
/// unit length but says so only of some of its methods; the ones that require
/// it here say so on their own.
///
/// `Point` owns nothing, allocates nothing and borrows nothing: a copy is an
/// independent value that shares no storage with the original, and no method
/// keeps a reference to its receiver, so a stable address is never required.
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

    /// `S2LatLng(const S2Point&)` (`s2/s2latlng.h:60-61`): this direction as a
    /// latitude and longitude. Upstream accepts a vector that is not unit
    /// length here (`s2/s2latlng.h:60`).
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
///
/// `LatLng` owns nothing and borrows nothing, so a copy is an independent value
/// and no method needs a stable address. Any `f64` pair is a legal value:
/// neither `fromDegrees` nor a struct literal normalizes, clamps or checks, and
/// `isValid` is how a caller asks. Only a method that reaches an upstream
/// precondition of its own will report `InvalidArgument` for one.
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

    /// `S2LatLng::ToPoint` (`s2/s2latlng.h:125-126`): the equivalent unit-length
    /// direction vector. Both coordinates must be finite, which is upstream's
    /// precondition (`s2/s2latlng.h:121-123`); the bridge refuses a non-finite
    /// one as `error.InvalidArgument`.
    pub fn toPoint(self: LatLng) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_point_from_lat_lng_deg(self.lat_deg, self.lng_deg, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// `S2LatLng::GetDistance` (`s2/s2latlng.h:128-137`) in degrees, measured
    /// along the surface of the sphere. Named for its unit because a tolerance
    /// written against radians is not a tolerance against this.
    ///
    /// Upstream requires both operands normalized (`s2/s2latlng.h:136`); the
    /// bridge checks only that the four coordinates are finite, so an
    /// unnormalized pair is measured as given rather than refused. Call
    /// `normalized` first if that matters. Upstream also notes that this
    /// Haversine form is the faster and slightly less accurate of the two above
    /// 180 degrees (`s2/s2latlng.h:128-136`).
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
/// reports it. Each axis is a closed interval. A `BoundUV` copies
/// independently, owns nothing, and no address of it has to stay valid.
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
/// upstream stores (`s2/s2cell_id.h:242-243`). A copy is an independent value
/// and no address of it has to stay valid.
pub const CellId = struct {
    /// The underlying id, exactly as upstream stores it
    /// (`s2/s2cell_id.h:242-243`).
    ///
    /// Every `u64` is a legal field value: `CellId` is a plain integer wrapper
    /// and constructing one never validates. An id that is not valid is not an
    /// error to have, and upstream gives it answers of its own -- `isValid`
    /// reports false, `toToken` and `toDebugString` still spell it, and every
    /// method below that needs a real cell reports `InvalidArgument`. A field
    /// written directly is therefore a value this module cannot tell apart from
    /// one a constructor produced, and the same rules apply to both.
    raw: u64,

    /// An invalid id, upstream's `S2CellId::None()` (`s2/s2cell_id.h:127-128`).
    pub const none: CellId = .{ .raw = 0 };

    /// An invalid id guaranteed larger than every valid one, upstream's
    /// `S2CellId::Sentinel()` (`s2/s2cell_id.h:131-132`).
    pub const sentinel: CellId = .{ .raw = 0xffff_ffff_ffff_ffff };

    /// The leaf cell containing `point`
    /// (`S2CellId(const S2LatLng&)`, `s2/s2cell_id.h:121-123`).
    ///
    /// A coordinate that is not finite is `InvalidArgument`; upstream requires
    /// both components finite here (`s2/s2cell_id.h:122`), and an unnormalized
    /// one is accepted and names the cell that contains it.
    pub fn fromLatLng(point: LatLng) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_lat_lng_deg(point.lat_deg, point.lng_deg, &out));
        return .{ .raw = out };
    }

    /// The leaf cell containing a direction vector, which need not be unit
    /// length (`S2CellId(const S2Point&)`, `s2/s2cell_id.h:112-119`).
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

    /// `S2CellId::FromFacePosLevel` (`s2/s2cell_id.h:167-173`). `hilbert_pos`
    /// is the position along the Hilbert curve over that face, which is what
    /// `pos` reads back; it is named in full here because `pos` is this
    /// struct's own method.
    /// `face_index` must be 0..5 and `target_level` 0..`max_level`, as upstream
    /// requires for this constructor. `hilbert_pos` must fit
    /// `S2CellId::kPosBits` bits (`s2/s2cell_id.h:101`), that is 0 .. 2^61 - 1:
    /// upstream masks the position rather than reject it, so a wider one is
    /// `InvalidArgument` here instead of silently naming a different cell.
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

    /// `S2CellId::FromFaceIJ` (`s2/s2cell_id.h:482-484`), from the cell centre's
    /// i/j coordinates, each in 0 .. 2^30 - 1 (`s2/s2coords.h:133-135`).
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

    /// `S2CellId::FromToken` (`s2/s2cell_id.h:420-422`).
    ///
    /// A token upstream rejects is `error.InvalidArgument`, not the id 0:
    /// upstream answers a malformed token with `S2CellId::None()`
    /// (`s2/s2cell_id.cc:248-249`), and a caller must not have to tell that
    /// apart from a real cell.
    pub fn fromToken(token: []const u8) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_token(token.ptr, token.len, &out));
        return .{ .raw = out };
    }

    /// `S2CellId::FromDebugString` (`s2/s2cell_id.h:449-454`): the
    /// "face/childpos..." spelling upstream writes its own neighbour fixtures
    /// in (`s2/s2cell_id_test.cc:638`, `s2/s2cell_id_test.cc:666`).
    pub fn fromDebugString(text: []const u8) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_from_debug_string(text.ptr, text.len, &out));
        return .{ .raw = out };
    }

    /// Writes the token into `buf` and returns the part of `buf` holding it.
    ///
    /// The result borrows `buf` and is invalidated the next time the caller
    /// writes it. `buf` needs room for the token *and* its NUL; upstream's
    /// longest token is 16 characters (`s2/s2cell_id.h:409-411`,
    /// `s2/s2cell_id.cc:228-232`), so 17 bytes always suffice. Any shorter
    /// buffer -- an empty one included -- is `error.BufferTooSmall` with nothing
    /// written into it. A token is never empty, so no zero-length buffer
    /// succeeds, and the required length is not returned on the refusal: size
    /// `buf` from the constant above rather than from a failed call.
    pub fn toToken(self: CellId, buf: []u8) Error![]const u8 {
        var needed: usize = undefined;
        try check(c.s2br_cell_to_token(self.raw, buf.ptr, buf.len, &needed));
        if (buf.len <= needed) return error.BufferTooSmall;
        return buf[0..needed];
    }

    /// `S2CellId::ToString` (`s2/s2cell_id.h:439-447`), under the same buffer
    /// rule as `toToken`: the result borrows `buf`, and a buffer that cannot
    /// hold the text and its NUL is `error.BufferTooSmall` with nothing
    /// written, an empty `buf` included, and the required length is not
    /// returned on that refusal either.
    pub fn toDebugString(self: CellId, buf: []u8) Error![]const u8 {
        var needed: usize = undefined;
        try check(c.s2br_cell_to_debug_string(self.raw, buf.ptr, buf.len, &needed));
        if (buf.len <= needed) return error.BufferTooSmall;
        return buf[0..needed];
    }

    /// `S2CellId::is_valid` (`s2/s2cell_id.h:245-249`).
    ///
    /// Total, and the one answer an invalid `raw` gets rather than an error:
    /// upstream requires a valid id in every other method "unless otherwise
    /// specified" (`s2/s2cell_id.h:245-248`), and this is that exception.
    pub fn isValid(self: CellId) bool {
        return asBool(c.s2br_cell_is_valid(self.raw));
    }

    /// `S2CellId::level` (`s2/s2cell_id.h:258-259`), in 0 .. `max_level`.
    ///
    /// An id that is not valid is `InvalidArgument`: upstream derives the level
    /// from the lowest set bit and has no defined answer for id 0.
    pub fn level(self: CellId) Error!u8 {
        var out: c_int = undefined;
        try check(c.s2br_cell_level(self.raw, &out));
        return @intCast(out);
    }

    /// `S2CellId::face` (`s2/s2cell_id.h:251-252`), in 0..5.
    pub fn face(self: CellId) Error!u8 {
        var out: c_int = undefined;
        try check(c.s2br_cell_face(self.raw, &out));
        return @intCast(out);
    }

    /// `S2CellId::pos` (`s2/s2cell_id.h:254-256`): the cell centre's position
    /// along the Hilbert curve over its face, in 0 .. 2^61 - 1.
    pub fn pos(self: CellId) Error!u64 {
        var out: u64 = undefined;
        try check(c.s2br_cell_pos(self.raw, &out));
        return out;
    }

    /// `S2CellId::is_leaf` (`s2/s2cell_id.h:267-269`).
    pub fn isLeaf(self: CellId) bool {
        return asBool(c.s2br_cell_is_leaf(self.raw));
    }

    /// `S2CellId::is_face` (`s2/s2cell_id.h:271-273`).
    pub fn isFace(self: CellId) bool {
        return asBool(c.s2br_cell_is_face(self.raw));
    }

    /// The cell at `target_level` containing this one: `S2CellId::parent(int level)`
    /// (`s2/s2cell_id.h:322-325`), which requires `target_level` to be at or
    /// below this cell's own level. `null` means the immediate parent, which is
    /// what upstream's own zero-argument `parent()` is (`s2/s2cell_id.h:319-320`,
    /// `s2/s2cell_id.h:668-670`).
    pub fn parent(self: CellId, target_level: ?u8) Error!CellId {
        const target: u8 = if (target_level) |l| l else blk: {
            const here = try self.level();
            // A level-0 cell has no parent: upstream's zero-argument `parent()`
            // is `parent(level() - 1)` (`s2/s2cell_id.h:668-670`) and a negative
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
    /// `S2CellId::child(int position)` (`s2/s2cell_id.h:327-329`), which
    /// requires this cell not to be a leaf; a leaf is `InvalidArgument`.
    pub fn child(self: CellId, position: u8) Error!CellId {
        if (position > 3) return error.InvalidArgument;
        var out: u64 = undefined;
        try check(c.s2br_cell_child(self.raw, @intCast(position), &out));
        return .{ .raw = out };
    }

    /// Every descendant of this cell at `target_level`, in ascending Hilbert-curve
    /// order, written into `out`; returns the part of `out` that was filled,
    /// which borrows `out` and is invalidated when the caller writes it again.
    ///
    /// `target_level` must be 0..`max_level` and at or above this cell's own
    /// level (`s2/s2cell_id.h:344-347`). There are 4^(target_level - own level)
    /// of them, which is a number worth taking seriously: a face cell asked for
    /// level 30 has 2^60. Ask `childrenCount` for the number first unless the
    /// buffer is already known to be large enough -- a short buffer is
    /// `BufferTooSmall` with nothing written into it -- and expect the fill
    /// itself to cost no less than that count.
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
    /// `distance_from_begin` (`s2/s2cell_id.h:359-363`), which counts `next()`
    /// steps, is the length of the range. That is a constant-time answer, which
    /// is the only kind that exists for the 2^60 a face cell at level 30 names:
    /// nothing that walked or materialised the range could report it at all.
    ///
    /// A range longer than a `usize` can count -- 2^60 on a 32-bit target -- is
    /// `InvalidArgument` rather than a wrapped count. `children` writes exactly
    /// this many cells, so the two can never disagree.
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

    /// `S2CellId::next` (`s2/s2cell_id.h:350-351`): the next cell at the same level
    /// along the Hilbert curve. It does not wrap from the last face to the first;
    /// upstream says so on this method and puts the wrapping pair, which this
    /// module does not wrap, beside it (`s2/s2cell_id.h:365-370`).
    pub fn next(self: CellId) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_next(self.raw, &out));
        return .{ .raw = out };
    }

    /// `S2CellId::prev` (`s2/s2cell_id.h:352`), with the same no-wrap rule as
    /// `next`.
    pub fn prev(self: CellId) Error!CellId {
        var out: u64 = undefined;
        try check(c.s2br_cell_prev(self.raw, &out));
        return .{ .raw = out };
    }

    /// `S2CellId::contains` (`s2/s2cell_id.h:313-314`, `s2/s2cell_id.h:648-651`).
    /// Both ids must be valid; an invalid one on either side is
    /// `InvalidArgument`, never `false`.
    pub fn contains(self: CellId, other: CellId) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cell_contains(self.raw, other.raw, &out));
        return asBool(out);
    }

    /// `S2CellId::intersects` (`s2/s2cell_id.h:316-317`, `s2/s2cell_id.h:654-657`).
    /// Both ids must be valid; an invalid one on either side is
    /// `InvalidArgument`, never `false`.
    pub fn intersects(self: CellId, other: CellId) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cell_intersects(self.raw, other.raw, &out));
        return asBool(out);
    }

    /// The inclusive id range this cell spans, `S2CellId::range_min` and
    /// `range_max` (`s2/s2cell_id.h:285-311`). Upstream defines `contains` in
    /// terms of exactly this pair (`s2/s2cell_id.h:648-651`).
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
    /// into `out`: `S2CellId::AppendVertexNeighbors` (`s2/s2cell_id.h:461-468`).
    /// The returned slice borrows `out`.
    ///
    /// Three or four results, because a cell whose nearest vertex is one of the
    /// eight cube vertices has only three (`s2/s2cell_id.cc:547-553`), which is
    /// why this returns a slice and not a fixed array. `target_level` must be strictly
    /// below this cell's own level (`s2/s2cell_id.cc:516-518`). A short buffer is
    /// `BufferTooSmall` with nothing written into it; `vertexNeighborsCount` reports
    /// the three or four without keeping them.
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
    /// `S2CellId::AppendAllNeighbors` (`s2/s2cell_id.h:470-477`). The returned
    /// slice borrows `out`.
    ///
    /// Eight results normally, and upstream's own corner-cell fixture contains a
    /// duplicate among them (`s2/s2cell_id_test.cc:641-649`), so this reports
    /// what upstream produced rather than deduplicating it. `target_level` must be in
    /// this cell's own level .. `max_level` inclusive (`s2/s2cell_id.h:476`,
    /// `s2/s2cell_id.cc:556-558`): `max_level` is the top of the range here, not
    /// one past it. A short buffer is `BufferTooSmall` with nothing written into
    /// it; `allNeighborsCount` reports the same number without keeping them,
    /// though it still builds the list upstream side.
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

    /// `S2CellId::ToLatLng` (`s2/s2cell_id.h:239-240`): the centre of the cell.
    pub fn toLatLng(self: CellId) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_cell_to_lat_lng_deg(self.raw, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// `S2CellId::ToPoint` (`s2/s2cell_id.h:174-182`): the unit-length direction
    /// of the cell centre.
    pub fn toPoint(self: CellId) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_cell_to_point(self.raw, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// `S2CellId::GetSizeST` (`s2/s2cell_id.h:188-189`): the cell's edge length
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

/// An S2 cell, `S2Cell` (`s2/s2cell.h:39-46`): the two-dimensional region sense
/// of a cell, where `CellId` is the integer sense. Upstream says the cell is
/// always the region sense and the other constructors are conveniences over an
/// id (`s2/s2cell.h:72-74`); this keeps that split and stores only the id.
///
/// A `Cell` owns nothing and allocates nothing, so a copy is an independent
/// value and no address of it has to stay valid. `id` may name a cell that is
/// not valid; the methods below then report `InvalidArgument` rather than
/// compute from it.
pub const Cell = struct {
    /// The cell this value is the region sense of. Write it directly for the
    /// same result `init` gives, under the same rule: no validity is checked.
    id: CellId,

    /// `S2Cell(S2CellId)` (`s2/s2cell.h:72-74`): the region sense of `id`.
    ///
    /// Total and infallible -- it validates nothing and allocates nothing, so an
    /// invalid `id` yields a `Cell` whose methods report `InvalidArgument`. This
    /// constructor exists to name the upstream one; the struct literal is
    /// equally correct.
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

    /// `S2Cell::AverageArea(int level)` (`s2/s2cell.h:220-221`): the mean area of
    /// every cell at `level`, in steradians, one number per level. `level` must
    /// be 0..`max_level`; anything above is `InvalidArgument` rather than a
    /// number for a level the decomposition does not have.
    pub fn averageAreaAtLevel(level: u8) Error!f64 {
        if (level > max_level) return error.InvalidArgument;
        var out: f64 = undefined;
        try check(c.s2br_cell_average_area(@intCast(level), &out));
        return out;
    }

    /// `S2Cell::GetCenter` (`s2/s2cell.h:217`): the point at which the cell
    /// divides into four children, which is upstream's definition of "centre"
    /// and is not in general the middle of the (u,v) rectangle
    /// (`s2/s2cell.h:212-217`).
    pub fn center(self: Cell) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_cell_center(self.id.raw, &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// `S2Cell::GetVertex(int k)` (`s2/s2cell.h:132-139`): the k-th corner,
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

    /// `S2Cell::Contains(const S2Point&)` (`s2/s2cell.h:308`), which upstream
    /// also accepts for a vector that is not unit length (`s2/s2cell.h:307`).
    /// A cell id is a closed set, so a point on a shared boundary is contained
    /// by every cell that touches it (`s2/s2cell_id.h:107-112`).
    pub fn containsPoint(self: Cell, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_cell_contains_point(self.id.raw, point.x, point.y, point.z, &out));
        return asBool(out);
    }
};

/// A spherical cap, `S2Cap` (`s2/s2cap.h`): the points within `radius_deg` of
/// `center` along the sphere.
///
/// A `Cap` owns nothing and allocates nothing, so a copy is an independent
/// value and no address of it has to stay valid. There is no constructor here:
/// upstream's takes an `S1Angle` and clamps the radius at 180 degrees
/// (`s2/s2cap.h:247-252`), so a larger `radius_deg` is a full cap rather than an
/// error. That is upstream's own choice and the bridge passes it through
/// unchanged, so this struct accepts any finite triple.
pub const Cap = struct {
    /// Centre of the cap. Not normalized here; a method that needs it
    /// normalized says so.
    center: LatLng,
    /// Angular radius in degrees. Upstream clamps at 180, so any value at or
    /// above 180 is a full cap and 0 is the empty one.
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

    /// `S2Cap::height` (`s2/s2cap.h:103-105`): the distance from the centre to the
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

    /// `S2Cap::Contains(const S2Point&)` (`s2/s2cap.h:191-192`). Upstream
    /// REQUIRES a unit-length vector (`s2/s2cap.cc:296-299`), so `point` must
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

/// A latitude-longitude rectangle, `S2LatLngRect` (`s2/s2latlng_rect.h:63`).
///
/// `lng_lo_deg > lng_hi_deg` is a legal rectangle that crosses the 180 degree
/// line, not an error, and `isInverted` reports exactly that condition
/// (`s2/s2latlng_rect.h:143-145`).
///
/// A `LatLngRect` owns nothing and allocates nothing, so a copy is an
/// independent value and no address of it has to stay valid. Nothing here
/// normalizes, clamps or orders the four numbers: upstream's own constructor
/// requires both points normalized with `lo.lat() <= hi.lat()`
/// (`s2/s2latlng_rect.h:67-72`), and every method below re-checks the only
/// condition it cannot answer -- that the coordinates are finite -- before it
/// reaches upstream. `isValid` is how a caller asks about the rest.
pub const LatLngRect = struct {
    lat_lo_deg: f64,
    lng_lo_deg: f64,
    lat_hi_deg: f64,
    lng_hi_deg: f64,

    /// `S2LatLngRect(const S2LatLng& lo, const S2LatLng& hi)`
    /// (`s2/s2latlng_rect.h:67-72`): the rectangle with these two corners,
    /// inclusive of both.
    ///
    /// Total and infallible, and it reaches no upstream code: it stores the four
    /// numbers as given, so a value upstream's constructor would refuse is not
    /// refused here either. `isValid` reports what upstream's own check covers,
    /// and every other method refuses a coordinate that is not finite before it
    /// calls upstream at all.
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

    /// `S2LatLngRect::Area` (`s2/s2latlng_rect.h:160-161`) in steradians on the unit
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

    /// `S2LatLngRect::Contains(const S2LatLng&)` (`s2/s2latlng_rect.h:177-179`),
    /// whose argument upstream requires normalized (`s2/s2latlng_rect.h:178`).
    /// The answer is inclusive of the boundary, so upstream separates it from
    /// `InteriorContains` (`s2/s2latlng_rect.h:181-188`); this reports the
    /// inclusive one. `point` must be finite; it is not normalized here.
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

    /// `S2LatLngRect::is_inverted` (`s2/s2latlng_rect.h:143-145`): true when this
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

    /// `S2LatLngRect::is_valid` (`s2/s2latlng_rect.h:128-132`): the latitude
    /// bounds within +/-90 degrees and the longitude bounds within +/-180
    /// degrees, with an empty interval on one axis only if the other is empty
    /// too.
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
/// The loop's interior is the region on the *left* of the vertex chain
/// (`s2/s2loop.h:262-264`), and containment is defined so that every point of
/// the sphere belongs to exactly one face (`s2/s2loop.h:87-89`), which is why a
/// loop does not necessarily contain its own vertices.
///
/// A `Loop` owns a C++ object and is **single-owner**. Zig has no move-only
/// type, so assigning one copies the handle and both copies then name one
/// owner: releasing both is a double free, and a copy that is never released
/// leaks. Exactly one `Loop` per constructed loop calls `deinit`, exactly once.
/// A `const` receiver is a read-only borrow of that owner, not a second one.
pub const Loop = struct {
    /// The bridge's opaque pointer to the `S2Loop` it owns.
    ///
    /// Reachable, and `null` for a value whose construction never produced a
    /// handle. Every method below passes it straight through, so a handle
    /// replaced with an unrelated pointer is checked only as far as the bridge
    /// checks it. Do not write it except through `init`, `empty` and `full`.
    handle: ?*c.S2BridgeLoop,

    /// A loop through `vertices`, at least three of them
    /// (`S2Loop::Init(absl::Span<const S2Point>)`, `s2/s2loop.h:126-130`).
    ///
    /// The result is a new owner with an attached `deinit`. On error no handle
    /// is produced and there is nothing to release.
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
    /// (`s2/s2loop.cc:203`, `s2/s2loop.h:643-648`). The bridge rejects it before
    /// reading the buffer or allocating, so no handle is produced.
    pub fn init(vertices: []const [3]f64) Error!Loop {
        if (vertices.len < 3) return error.InvalidArgument;
        var out: ?*c.S2BridgeLoop = null;
        try check(c.s2br_loop_create(@ptrCast(vertices.ptr), vertices.len, &out));
        return .{ .handle = out.? };
    }

    /// `S2Loop::kEmpty` (`s2/s2loop.h:132-139`): a loop with no edges that
    /// contains no points. It is an owner like any other and needs a `deinit`.
    pub fn empty() Error!Loop {
        var out: ?*c.S2BridgeLoop = null;
        try check(c.s2br_loop_create_empty(&out));
        return .{ .handle = out.? };
    }

    /// `S2Loop::kFull` (`s2/s2loop.h:142-143`): a loop with no edges that
    /// contains every point. It is an owner like any other and needs a `deinit`.
    pub fn full() Error!Loop {
        var out: ?*c.S2BridgeLoop = null;
        try check(c.s2br_loop_create_full(&out));
        return .{ .handle = out.? };
    }

    /// Releases the C++ storage this value owns, and only that.
    ///
    /// The bridge accepts a null handle (`zig/bridge.h`, `s2br_loop_destroy`),
    /// so `deinit` on a `Loop` whose construction failed does nothing and is
    /// safe. It is not idempotent afterwards: the value is left undefined, and
    /// calling this again -- or calling it on a copy that does not own the
    /// storage -- is a double free. `normalize` and `invert` need no cleanup of
    /// their own; they mutate this same owner.
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

    /// `S2Loop::vertex(int i)` (`s2/s2loop.h:189-198`).
    ///
    /// `i` must be below `numVertices`, which is `InvalidArgument` otherwise and
    /// never a read past the end; an `i` past the largest `int` is likewise
    /// `InvalidArgument` rather than a narrowed index (see `asIndex`). Upstream
    /// itself documents the wider `0 <= i < 2 * num_vertices()` window
    /// (`s2/s2loop.h:192`); this module exposes only the first half of it.
    pub fn vertex(self: Loop, i: usize) Error!Point {
        var xyz: [3]f64 = undefined;
        try check(c.s2br_loop_vertex(self.handle, try asIndex(i), &xyz));
        return .{ .x = xyz[0], .y = xyz[1], .z = xyz[2] };
    }

    /// The vertex `i` as degrees, `S2LatLng(const S2Point&)`
    /// (`s2/s2latlng.h:60-61`), with the same `i` rules as `vertex`.
    pub fn vertexLatLng(self: Loop, i: usize) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_loop_vertex_lat_lng_deg(self.handle, try asIndex(i), &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// `S2Loop::GetArea` (`s2/s2loop.h:262-265`) in steradians, between 0 and 4*pi.
    /// May allocate upstream while it prunes degeneracies, so `OutOfMemory` is
    /// reachable.
    ///
    /// Unsigned: whether the loop is a shell or a hole is not part of the answer
    /// (`s2/s2loop.h:262-265`). Use `signedArea` when the sign is what matters.
    pub fn area(self: Loop) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_loop_area(self.handle, &out));
        return out;
    }

    /// `S2::GetSignedArea` over the vertices (`s2/s2loop_measures.h:78`) in
    /// steradians: negative when the interior is more than half the sphere
    /// (`s2/s2loop_measures.h:58-78`).
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

    /// `S2Loop::Contains(const S2Point&)` (`s2/s2loop.h:413-414`), which
    /// upstream accepts for a vector that is not unit length. `point` must be
    /// finite. May allocate upstream above its brute-force threshold, so
    /// `OutOfMemory` is reachable.
    pub fn containsPoint(self: Loop, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_contains_point(self.handle, point.x, point.y, point.z, &out));
        return asBool(out);
    }

    /// `S2Loop::IsNormalized` (`s2/s2loop.h:245-249`): whether the enclosed area
    /// is at most 2*pi.
    pub fn isNormalized(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_normalized(self.handle, &out));
        return asBool(out);
    }

    /// `S2Loop::Normalize` (`s2/s2loop.h:251-253`): inverts if necessary so the
    /// enclosed area is at most 2*pi. Mutates this owner in place; it does not
    /// transfer it and does not change who owns it.
    pub fn normalize(self: *Loop) Error!void {
        try check(c.s2br_loop_normalize(self.handle));
    }

    /// `S2Loop::Invert` (`s2/s2loop.h:255-260`). Mutates this owner in place, as
    /// `normalize` does.
    pub fn invert(self: *Loop) Error!void {
        try check(c.s2br_loop_invert(self.handle));
    }

    /// `S2Loop::is_empty` (`s2/s2loop.h:222-223`).
    pub fn isEmpty(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_empty(self.handle, &out));
        return asBool(out);
    }

    /// `S2Loop::is_full` (`s2/s2loop.h:225-226`).
    pub fn isFull(self: Loop) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_loop_is_full(self.handle, &out));
        return asBool(out);
    }

    /// `S2Loop::IsValid` (`s2/s2loop.h:176-179`): every loop precondition holds,
    /// including no self-intersection and no repeated vertex. Upstream builds
    /// the failure message with a `std::string` (`s2/s2loop.cc:232-236`), so
    /// `OutOfMemory` is reachable on the invalid path.
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
/// (`s2/s2polygon.h:172-183`).
///
/// A `Polygon` owns a C++ object and is **single-owner**, for the same reason
/// and with the same price as `Loop`: Zig has no move-only type, so a copy is a
/// second name for one owner, releasing both is a double free, and a copy that
/// is never released leaks. Every result of `complement`, `intersection` and
/// `unite` is a new owner and needs its own `deinit`.
pub const Polygon = struct {
    /// The bridge's opaque pointer to the `S2Polygon` it owns.
    ///
    /// Reachable, and `null` for a value whose construction never produced a
    /// handle. Every method below passes it straight through, so a handle
    /// replaced with an unrelated pointer is checked only as far as the bridge
    /// checks it. Do not write it except through the constructors below.
    handle: ?*c.S2BridgePolygon,

    /// A polygon whose interior is the single shell `vertices`,
    /// `S2Polygon::Init(std::unique_ptr<S2Loop>)` (`s2/s2polygon.h:192-196`).
    /// `vertices` is borrowed for the call and copied by upstream; see
    /// `Loop.init`.
    ///
    /// The result is a new owner with an attached `deinit`. On error no handle
    /// is produced and there is nothing to release.
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
    /// (`s2/s2polygon.h:172-183`).
    ///
    /// `vertices` holds every loop back to back and `loop_sizes` gives their
    /// lengths in order; both are borrowed for the call. The caller says
    /// nothing about which loops are shells and which are holes: upstream works
    /// that out from the nesting depth and reorders the loops into the
    /// preorder traversal `loopVertex` then reports
    /// (`s2/s2polygon.h:176-179`, `s2/s2polygon.h:254-259`). A `loop_sizes` that
    /// is empty, or whose lengths do not sum to `vertices.len`, is
    /// `InvalidArgument` and produces no handle.
    ///
    /// The result is a new owner with an attached `deinit`.
    ///
    /// Every vertex of every loop must be a unit-length direction, as in
    /// `init`.
    ///
    /// A length list upstream could not be told about is `InvalidArgument` as
    /// well: `S2Polygon::num_loops()` narrows the loop count to an `int`
    /// (`s2/s2polygon.h:248`), `S2Loop::Init` stores each length in one
    /// (`s2/s2loop.h:647`), and `S2Polygon::InitLoopProperties` sums them in
    /// another (`s2/s2polygon.cc:523-534`). The bridge rejects an impossible
    /// count before it reads `loop_sizes` or allocates, so no handle is produced.
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
    /// `s2/s2polygon.h:240-241`). It is an owner like any other.
    pub fn empty() Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_create_empty(&out));
        return .{ .handle = out.? };
    }

    /// `S2Polygon::MakeFull` (`s2/s2polygon.h:168-170`): the whole sphere. It is
    /// an owner like any other.
    pub fn full() Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_create_full(&out));
        return .{ .handle = out.? };
    }

    /// Releases the C++ storage this value owns. Exactly the `Loop.deinit`
    /// contract: safe once on a construction that failed, a double free
    /// afterwards or on a copy that does not own the storage.
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

    /// `S2Polygon::num_vertices` (`s2/s2polygon.h:250-252`), the total over all
    /// loops.
    pub fn numVertices(self: Polygon) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_polygon_num_vertices(self.handle, &out));
        return @intCast(out);
    }

    /// `S2Polygon::loop(k)->num_vertices` (`s2/s2polygon.h:254-259`).
    ///
    /// `loop_index` must be below `numLoops`, which is `InvalidArgument`
    /// otherwise and never a read past the end; a `loop_index` past the largest
    /// `int` is likewise `InvalidArgument` (see `asIndex`).
    pub fn loopNumVertices(self: Polygon, loop_index: usize) Error!usize {
        var out: c_int = undefined;
        try check(c.s2br_polygon_loop_num_vertices(self.handle, try asIndex(loop_index), &out));
        return @intCast(out);
    }

    /// `S2Polygon::loop(k)->vertex(i)` (`s2/s2polygon.h:254-259`,
    /// `s2/s2loop.h:189-198`). The loop index is the preorder traversal order
    /// `InitNested` produced (`s2/s2polygon.h:176-179`), not the order the
    /// loops were passed in.
    ///
    /// `loop_index` must be below `numLoops` and `vertex_index` below that
    /// loop's `loopNumVertices`; either out of range is `InvalidArgument` and
    /// never a read past the end. Either index past the largest `int` is
    /// likewise `InvalidArgument`, and the loop index is checked first; see
    /// `asIndex`.
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

    /// The same vertex as degrees (`S2LatLng(const S2Point&)`,
    /// `s2/s2latlng.h:60-61`), with the same two index rules as `loopVertex`.
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

    /// `S2Polygon::GetArea` (`s2/s2polygon.h:273-275`) in steradians, between 0 and
    /// 4*pi, with holes already subtracted.
    pub fn area(self: Polygon) Error!f64 {
        var out: f64 = undefined;
        try check(c.s2br_polygon_area(self.handle, &out));
        return out;
    }

    /// `S2Polygon::Contains(const S2Point&)` (`s2/s2polygon.h:653-654`). The
    /// point carries the same unit-length requirement as `Cap.containsPoint`
    /// (`s2/s2polygon.cc:704-706`). Reaches the polygon's shape index on first
    /// use (`s2/s2polygon.cc:727-728`), so `OutOfMemory` is reachable.
    pub fn containsPoint(self: Polygon, point: Point) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_contains_point(self.handle, point.x, point.y, point.z, &out));
        return asBool(out);
    }

    /// The same question asked of a normalized `S2LatLng`, which upstream's own
    /// `S2LatLng::ToPoint` (`s2/s2latlng.h:125-126`) turns into the unit vector
    /// that overload requires. `point` must be finite.
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
    /// (`s2/s2polygon.h:277-280`).
    pub fn centroidLatLng(self: Polygon) Error!LatLng {
        var lat: f64 = undefined;
        var lng: f64 = undefined;
        try check(c.s2br_polygon_centroid_lat_lng_deg(self.handle, &lat, &lng));
        return .{ .lat_deg = lat, .lng_deg = lng };
    }

    /// `S2Polygon::is_empty` (`s2/s2polygon.h:240-241`).
    pub fn isEmpty(self: Polygon) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_is_empty(self.handle, &out));
        return asBool(out);
    }

    /// `S2Polygon::is_full` (`s2/s2polygon.h:243-245`).
    pub fn isFull(self: Polygon) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_is_full(self.handle, &out));
        return asBool(out);
    }

    /// `S2Polygon::IsValid` (`s2/s2polygon.h:225-229`).
    ///
    /// Including the validity of every loop the polygon owns. Reachable for an
    /// invalid polygon precisely because `init` does not abort on one; see
    /// `Invalid geometry` above. The failure message is built with a
    /// `std::string` (`s2/s2polygon.cc:255-282`), so `OutOfMemory` is
    /// reachable on the invalid path.
    pub fn isValid(self: Polygon) Error!bool {
        var out: c_int = 0;
        try check(c.s2br_polygon_is_valid(self.handle, &out));
        return asBool(out);
    }

    /// `S2Polygon::InitToComplement` (`s2/s2polygon.h:496-497`): a new polygon
    /// covering everything `self` does not. `self` is untouched and stays owned
    /// by the caller; the result is a new owner that needs its own `deinit`. On
    /// error nothing is returned and there is nothing to release.
    pub fn complement(self: Polygon) Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_complement(self.handle, &out));
        return .{ .handle = out.? };
    }

    /// `S2Polygon::InitToIntersection` (`s2/s2polygon.h:389`): a new polygon
    /// covering the overlap of `a` and `b`. Neither input is modified and both
    /// stay owned by the caller; the result is a new owner that needs its own
    /// `deinit`.
    ///
    /// Both operands must be valid, which is upstream's stated precondition for
    /// the operation: its `S2Error` overloads "should never return an error
    /// provided that both input polygons are valid" (`s2/s2polygon.h:385-388`).
    /// An invalid operand is `InvalidArgument`, decided by `isValid` before the
    /// operation runs rather than by anything it does, and `Internal` is what a
    /// failure upstream did report comes back as. Either way no partial result
    /// is returned: the bridge releases the handle it had built rather than hand
    /// back half a polygon (`zig/bridge.cc:1345-1352`), so the only cleanup
    /// either way is the caller's.
    pub fn intersection(a: Polygon, b: Polygon) Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_intersection(a.handle, b.handle, &out));
        return .{ .handle = out.? };
    }

    /// `S2Polygon::InitToUnion` (`s2/s2polygon.h:396`): a new polygon covering
    /// `a` or `b`. Neither input is modified, both stay owned by the caller,
    /// both must be valid, and the result is a new owner needing its own
    /// `deinit`; see `intersection` above for what an invalid operand and an
    /// upstream failure are reported as.
    pub fn unite(a: Polygon, b: Polygon) Error!Polygon {
        var out: ?*c.S2BridgePolygon = null;
        try check(c.s2br_polygon_union(a.handle, b.handle, &out));
        return .{ .handle = out.? };
    }
};

/// How much of the sphere a covering may use: `S2RegionCoverer::Options`
/// (`s2/s2region_coverer.h:74-162`).
///
/// A `Coverer` is a value of four settings and nothing else: it owns no
/// handle, allocates nothing, and a copy is independent with no address of it
/// kept. The defaults are upstream's own -- every level, every level modulo
/// one, and eight cells (`s2/s2region_coverer.h:105-106`,
/// `s2/s2region_coverer.h:157-162`).
///
/// The four fields are read at the start of every call below and a combination
/// upstream cannot use is `error.InvalidArgument` before any upstream code
/// runs: `min_level` no above this value's `max_level` field, that field no
/// above the module's `max_level` constant (30), `level_mod` in 1..3
/// (`s2/s2region_coverer.h:140-144`) and `max_cells >= 1`, plus `max_cells` no
/// wider than the `int32_t` the bridge carries it as. Change a field and every
/// later call sees the new value; nothing is cached.
pub const Coverer = struct {
    /// Cells below this level are never returned, even if that means more of
    /// them (`s2/s2region_coverer.h:85-87`, `s2/s2region_coverer.h:120-122`).
    /// 0..`max_level`.
    min_level: u8 = 0,
    /// Cells above this level are never returned; the value upstream documents
    /// is `S2CellId::kMaxLevel` (`s2/s2region_coverer.h:132-135`). 0..30.
    max_level: u8 = max_level,
    /// Only levels where `(level - min_level)` is a multiple of this are used
    /// (`s2/s2region_coverer.h:140-148`). Upstream allows 1, 2 or 3, giving
    /// branching factors of 4, 16 and 64; anything else is
    /// `error.InvalidArgument`.
    level_mod: u8 = 1,
    /// The desired maximum number of cells; upstream publishes a table of the
    /// accuracy this buys (`s2/s2region_coverer.h:93-100`). A bound on the work
    /// as much as on the output: up to six cells may still be returned where
    /// that is the minimum, and `min_level` wins over it.
    max_cells: u32 = 8,

    fn options(self: Coverer) Error!c.S2BridgeCovererOptions {
        if (self.min_level > self.max_level) return error.InvalidArgument;
        if (self.max_level > max_level) return error.InvalidArgument;
        if (self.level_mod < 1 or self.level_mod > 3) return error.InvalidArgument;
        if (self.max_cells < 1) return error.InvalidArgument;
        // The bridge carries `max_cells` as an `int32_t`
        // (`zig/bridge.h:705`), so a `u32` above `maxInt(c_int)` would trap
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

    /// `S2RegionCoverer::GetCovering` over a cap
    /// (`s2/s2region_coverer.h:190-193`), written into `out`; returns the part of
    /// `out` that was filled, which borrows `out`. `cap`'s coordinates must be
    /// finite.
    ///
    /// A buffer shorter than the covering is `error.BufferTooSmall` with nothing
    /// written into it. The covering is an approximation and not a partition:
    /// upstream warns that the output may change between library versions and
    /// must not be relied on for stability (`s2/s2region_coverer.h:60-62`).
    /// `coveringCapCount` reports exactly this many, at the cost of running the
    /// coverer twice and building the list it then discards.
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

    /// How many cells `coveringCap` produces.
    ///
    /// This really does run the coverer and build the list in order to count
    /// it, because upstream's own answer is the list. It keeps nothing, so the
    /// buffer this sizes is the caller's to allocate and free.
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

    /// The cells whose union contains `rect`, under the same buffer rule,
    /// borrow and stability rules as `coveringCap`. `rect`'s four coordinates
    /// must be finite, or `error.InvalidArgument` and nothing written.
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

    /// How many cells `coveringRect` produces; see `coveringCapCount` for what
    /// that call costs.
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

    /// The cells whose union contains `polygon`, under the same buffer rule,
    /// borrow and stability rules as `coveringCap`. `polygon` is read, not
    /// retained or transferred, and stays owned by the caller.
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

    /// How many cells `coveringPolygon` produces; see `coveringCapCount` for
    /// what that call costs.
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

    /// The cells whose union contains a single cell, under the same buffer
    /// rule, borrow and stability rules as `coveringCap`. `cell` must be a
    /// valid id. Upstream's own covering of a cell is exactly that one cell
    /// (`s2/s2region_coverer_test.cc:84-86`).
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

    /// How many cells `coveringCell` produces; see `coveringCapCount` for what
    /// that call costs.
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
