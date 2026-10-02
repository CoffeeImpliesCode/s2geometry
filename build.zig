//! Zig 0.16 build for the S2 geometry fork.
//!
//! The library is the real, unmodified upstream C++: the 108 translation
//! units of s2geometry's own `add_library(s2 ...)` block, and the Abseil
//! LTS `20250814.1` tree vendored at `vendor/abseil-cpp`, which is the
//! version s2geometry's CMake fetches.  Nothing is downloaded, no system copy
//! is used, and no upstream build script is executed.
//!
//! Three artifacts come out of one graph:
//!
//!   libabsl            the vendored Abseil library, minus its tests
//!   libs2              the upstream S2 library, linking libabsl
//!   libs2_bridge       this fork's C bridge over S2, linking libs2
//!
//! The Zig facade `zig/root.zig` is registered as the public module
//! `s2geometry`; it imports the translated `zig/bridge.h` as `c` and links
//! all three libraries transitively, so a consumer reaches everything through
//! `dep.module("s2geometry")` with no extra wiring.
//!
//! Entry points
//! ------------
//!   zig build            install the three libraries, their headers and the
//!                        bridge header, and compile the smoke program
//!   zig build test       run the behavioural tests for the selected target
//!                        (the run step is always exposed; whether a foreign
//!                        binary executes is the build runner's answer, not
//!                        this script's)
//!   zig build smoke      run the smoke program and print its output
//!   zig build check      compile the whole C/C++ library, the facade, the
//!                        tests and the smoke program for every required
//!                        target without running anything
//!   zig build consumer   build the standalone `consumer/` package, and run it
//!                        when this build can execute the selected target (see
//!                        `addConsumerStep`: the executor switches, the
//!                        standard library and the mode are forwarded to it,
//!                        and anything after `consumer --` is forwarded too)
//!
//! Options
//! -------
//!   -fsys=s2            link an installed libs2 and its Abseil instead of
//!                        compiling this tree.  `b.systemIntegrationOption` is
//!                        fed by `-fsys=`/`-fno-sys=`, never by a `-D` option.
//!                        The mode offers the same five entry points as the
//!                        bundled graph -- install, `test`, `smoke`, `check`
//!                        and `consumer` -- against the installed library and
//!                        its installed headers.  Its `check` compiles the
//!                        selected target only, because the library and the
//!                        headers it binds to are this machine's; the six-target
//!                        matrix below is the bundled graph's.
//!   -Dtarget=<triple>    build for one target.  `zig build check -Dtarget=…`
//!                        then checks exactly that target instead of the six,
//!                        `native` included: naming the host is still naming
//!                        one target.
//!
//! What `check` is, precisely
//! -------------------------
//! It compiles, for each target: every Abseil translation unit, every S2
//! translation unit, `zig/bridge.cc`, the translated bridge header, the facade,
//! `tests.zig` and `smoke.zig`.  `tests.zig` calls every public facade method
//! with concrete argument types, and Zig only analyses a function body when
//! something calls it, so compiling that root is what makes `check` evidence
//! about the facade rather than about an unreferenced archive.  Nothing runs:
//! a cross-compiled result is compile evidence and nothing more.  What the
//! targets actually do is a question for the gate, not for this script; every
//! target in the matrix is attempted rather than skipped as unsatisfiable, so
//! that whatever fails, fails visibly.  A named target option narrows the six
//! to that one.
//!
//! `wasm32-wasi` needs a complete WASIp1-threads C/C++ EH sysroot supplied
//! with `-Dwasi-sysroot=…`. The full source closure uses filesystem streams,
//! Abseil synchronization and C++ exception unwinding. The graph keeps those
//! facilities and uses real providers; it neither stubs them nor drops units.
//! Every module that links that sysroot is built multi-threaded, and the one
//! place that decides it is `wasi_provider.Provider.configureModule`. Zig's
//! `std.c` errno on WASI is a thread-local of its own rather than the libc's
//! `__errno_location()`, so a binary whose two halves disagree about the
//! threading model reads two different errnos -- which is a wrong answer, not a
//! missing feature.

const std = @import("std");

const absl_sources = @import("build_support/absl_sources.zig");
const platform_flags = @import("build_support/platform_flags.zig");
const wasi_provider = @import("build_support/wasi_provider.zig");
const s2_sources = @import("build_support/s2_sources.zig");

/// The upstream releases this package pins.  Kept in step with UPSTREAM.md.
const s2_version = s2_sources.version;
const s2_commit = s2_sources.commit;
const absl_version = absl_sources.version;
const absl_commit = absl_sources.commit;

/// The six targets `check` compiles, unless `-Dtarget` names one.
///
/// `aarch64-macos-none` is the ordinary macOS ABI: in Zig 0.16 the default ABI
/// for `.macos` is `.none`, which is not a libc-less target.  It is in the
/// matrix because it was asked for; whether a given machine can satisfy a
/// target's prerequisites is a gate observation, not a build-script assumption.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// Whether the caller named a target on the command line.
///
/// `target.query.isNative()` cannot answer that, and answering it the wrong
/// way is what this function exists to prevent.
/// `standardTargetOptionsQueryOnly` (`lib/std/Build.zig:1473-1498`) returns
/// the empty query when none of `-Dtarget`, `-Dcpu`, `-Dofmt` and
/// `-Ddynamic-linker` was given, and when `-Dtarget=native` was given it
/// parses the literal at `:1498` into that same empty query -- and
/// `resolveTargetQuery` (`:2704-2707`) then hands back `b.graph.host` for
/// both.  So `zig build check -Dtarget=native` resolved to a query for which
/// `isNative()` (`lib/std/Target/Query.zig:396-398`) was true, took the
/// matrix branch, and compiled all six targets while this package's own
/// documentation promised exactly one.
///
/// The raw option table can tell them apart: `standardTargetOptionsQueryOnly`
/// registers each option under exactly the name spelled here
/// (`lib/std/Build.zig:1474-1494`), and every `-Dname=value` the user passed
/// is a key in that map (`lib/std/Build.zig:1167`, filled by
/// `addUserInputOption` at `:1533-1541`).  The four names are the standard
/// library's own test for "nothing was named" at `:1495-1496`, so this asks
/// exactly the question that line asks and no broader one: `-Dcpu=` on its own
/// still narrows `check` to the host, which the matrix branch would not do.
/// As a dependency this table holds whatever the dependent forwarded through
/// `b.dependency`, which is the target it asked for -- the same answer by the
/// other route.
fn target_was_named(b: *const std.Build) bool {
    for ([_][]const u8{ "target", "cpu", "ofmt", "dynamic-linker" }) |name| {
        if (b.user_input_options.contains(name)) return true;
    }
    return false;
}

/// Everything one target's graph produces.
const Graph = struct {
    /// The vendored Abseil library.
    absl_lib: *std.Build.Step.Compile,
    /// The upstream S2 library.
    s2_lib: *std.Build.Step.Compile,
    /// This fork's compiled bridge over S2.
    bridge_lib: *std.Build.Step.Compile,
    /// The Zig facade.  `c` holds the translated bridge header.
    module: *std.Build.Module,
    /// The matching external WASI provider, absent on other targets.
    provider: ?wasi_provider.Provider,
};

pub fn build(b: *std.Build) void {
    const target = wasi_provider.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const wasi_sysroot = b.option([]const u8, "wasi-sysroot", "Complete WASI SDK 34+ sysroot with WASIp1-threads EH C/C++ providers");

    if (b.systemIntegrationOption("s2", .{ .default = false })) {
        addSystemMode(b, target, optimize, wasi_sysroot);
        return;
    }

    const graph = addGraph(b, target, optimize, true, wasi_sysroot);

    // Install the three libraries.  The installed header root travels with the
    // bridge (`addBridge`), so this is also what puts the upstream S2 and
    // Abseil header trees under `include/` for anything that links this
    // package's installed artifacts.
    b.installArtifact(graph.absl_lib);
    b.installArtifact(graph.s2_lib);
    b.installArtifact(graph.bridge_lib);

    const smoke_exe = addSmoke(b, target, optimize, graph.module, graph.provider);
    // `zig build` installs the libraries and compiles the example; it does not
    // run it.  The example is the cheapest thing that proves the facade, the
    // translated C and the real C++ agree on types, symbols and link-time
    // dependencies.
    b.getInstallStep().dependOn(&smoke_exe.step);

    const run_smoke = b.addRunArtifact(smoke_exe);
    run_smoke.has_side_effects = true;
    b.step("smoke", "Run the deterministic S2 smoke program").dependOn(&run_smoke.step);

    // `zig build test` runs the tests, for whatever target was selected.
    //
    // The run step is unconditional.  It used to be guarded by
    // `target.query.isNative()`, on the reasoning that a foreign binary cannot
    // be executed on the build machine; that guard was wrong twice over.
    //
    // First, `Target.Query.isNative()` (`lib/std/Target/Query.zig:396-398`) is
    // `isNativeTriple() and ofmt == null`, and `isNativeTriple()` (`:392-394`)
    // demands `cpu_arch`, `os_tag` and `abi` all be null -- so `-Dtarget=x86_64-linux`
    // is *not* native even on an x86_64 Linux host, and `zig build test
    // -Dtarget=<host triple>` silently degraded to compile-only.  Observed: the
    // 2026-10-02 `cross-test` run on `x86_64-linux` built every object and
    // reported `Build Summary: 9/9 steps succeeded` with `test success` and no
    // `run test` line at all -- `no_test_results`, exit 1
    // (`/home/tmp2/gertullj/scratch/foundation-libs/cross-test-01a0f400/before/
    // s2geometry/cross-test-summary.json`, run 20261002-033134-17908-30770).
    //
    // Second, whether a foreign binary *can* run is not this script's question.
    // It is the build runner's, and `std.Build` says so on the function itself:
    // `addRunArtifact`'s own comment (`lib/std/Build.zig:937-939`) reads
    // "It doesn't have to be native. We catch that if you actually try to run
    // it. Consider that this is declarative; the run step may not be run unless
    // a user option is supplied."  `Step.Run` carries that machinery: it asks
    // `std.zig.system.getExternalExecutor` (`lib/std/Build/Step/Run.zig:1268`)
    // for an executor and runs the binary under one when there is one -- the
    // host itself, Rosetta, QEMU user, Wine or Wasmtime -- and when there is
    // none it fails the step and names the target
    // (`lib/std/Build/Step/Run.zig:2753-2777`).  That failure is the honest
    // outcome for a target this machine cannot execute, and reporting it is the
    // runner's job: deciding it here would replace the runner's answer with a
    // guess about a target this script has not resolved.  `addConsumerStep`
    // asks the same question of the same function, for the same reason.
    const test_step = b.step("test", "Run the behavioural tests");
    const unit_tests = addTests(b, target, optimize, graph.module, graph.provider, "s2-tests");
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    test_step.dependOn(&run_tests.step);

    // An explicit target option means exactly that target, and nothing else.
    // Without one, the six required targets are all attempted.
    //
    // The test is whether an option was named, not whether the resolved query
    // is native: `-Dtarget=native` parses to the same empty query as no option
    // at all, so the resolved-query test put it on the matrix branch and
    // compiled all six targets for a caller that asked for one.  See
    // `target_was_named`.
    const check_step = b.step(
        "check",
        "Compile the C++ library, bridge, facade, tests and example for every required target without running them",
    );
    if (target_was_named(b)) {
        addCheck(b, check_step, target, optimize, wasi_sysroot);
    } else {
        for (check_targets) |query| addCheck(b, check_step, b.resolveTargetQuery(query), optimize, wasi_sysroot);
    }

    // `false`: this branch is reached only when `b.systemIntegrationOption`
    // resolved the bundled mode, so the nested consumer build is told so
    // explicitly rather than being left to resolve it again.
    addConsumerStep(b, target, optimize, false, wasi_sysroot);
}

/// Compiles the whole library for one target.
///
/// `public` chooses between the package module set, which is what a dependent
/// reaches through `dep.module("s2geometry")`, and a private module.  A cross
/// target check needs the private form: module names are registered against
/// the whole build, so registering `s2geometry` once per cross target would
/// leave only the last of them reachable and silently stop checking the rest.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    public: bool,
    wasi_sysroot: ?[]const u8,
) Graph {
    const windows = platform_flags.isWindows(target);

    const provider = wasi_provider.Provider.init(b, target, wasi_sysroot);
    const absl_lib = addAbseil(b, target, optimize, windows, provider);
    const s2_lib = addS2(b, target, optimize, provider, absl_lib);
    const bridge_lib = addBridge(b, target, optimize, provider, s2_lib);

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("zig/bridge.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // `zig/bridge.h` is plain C99 over `<stddef.h>` and `<stdint.h>`, so the
    // translation needs no upstream header at all today.  The two roots go on
    // the line anyway so that the translator sees exactly the include
    // environment the compiled side sees: a bridge header is allowed to name
    // an upstream type, and a translation that could not resolve it would
    // describe an interface the compiled bridge does not implement.
    translate_c.addIncludePath(b.path(s2_sources.include_dir));
    translate_c.addIncludePath(b.path(absl_sources.include_dir));
    if (provider) |actual| translate_c.addIncludePath(actual.include_dir);
    const c_module = if (public) translate_c.addModule("c") else translate_c.createModule();
    // `addModule`/`createModule` copy only `link_libc` and the system
    // libraries, so the include paths have to be put back on the module
    // itself.  The provider's own roots come from `configureModule`, which
    // carries them together with the threading model: the translated header is
    // compiled into the same graph as the facade, the tests and the smoke root,
    // and one module quietly keeping the `wasm32-wasi` single-threaded default
    // is the same split libc TLS that model exists to prevent.
    c_module.addIncludePath(b.path(s2_sources.include_dir));
    c_module.addIncludePath(b.path(absl_sources.include_dir));
    if (provider) |actual| actual.configureModule(c_module);

    const module = if (public)
        b.addModule("s2geometry", .{
            .root_source_file = b.path("zig/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = target.result.os.tag != .wasi,
        })
    else
        b.createModule(.{
            .root_source_file = b.path("zig/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = target.result.os.tag != .wasi,
        });
    module.addImport("c", c_module);
    module.linkLibrary(bridge_lib);
    if (provider) |actual| {
        actual.configureModule(module);
        actual.linkRuntime(module);
    }

    return .{
        .absl_lib = absl_lib,
        .s2_lib = s2_lib,
        .bridge_lib = bridge_lib,
        .module = module,
        .provider = provider,
    };
}

// OpenBSD and NetBSD expose no supported PowerPC timebase-frequency query here.
// Select Abseil's documented steady_clock backend in every bundled C++ module.
// The define changes which definitions an Abseil header emits, so it belongs to
// a tree this build compiles; `-fsys=s2` compiles no Abseil of its own and
// takes the installed build's value instead -- see `addSystemMode`.
fn configureClock(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .openbsd and target.result.os.tag != .netbsd) return;
    switch (target.result.cpu.arch) {
        .powerpc, .powerpc64 => module.addCMacro("ABSL_USE_UNSCALED_CYCLECLOCK", "0"),
        else => {},
    }
}

/// Compiles the vendored Abseil library.
///
/// One static library holds the whole closure rather than the ~150 targets
/// upstream's CMake creates: a static archive of the same translation units
/// satisfies the same link, and it means every object an S2 function can reach
/// is compiled here rather than being hoped for.  The source list is
/// `build_support/absl_sources.zig`, which names the upstream `SRCS` block
/// each entry came from.
fn addAbseil(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    windows: bool,
    provider: ?wasi_provider.Provider,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi,
    });
    configureClock(module, target);
    if (provider) |actual| actual.configureModule(module);
    // Matches Abseil's MINGW -ldbghelp and MSVC dbghelp.lib dependency.
    if (windows) module.linkSystemLibrary("dbghelp", .{});
    // CCTZ's Apple default-timezone implementation uses real CoreFoundation.
    if (target.result.os.tag.isDarwin()) module.linkFramework("CoreFoundation", .{});
    // Both are needs of the vendored closure, not of the bridge or of S2: the
    // calls are in `symbolize_win32.inc` and `time_zone_lookup.cc`, library
    // translation units this graph compiles and this mode does not.
    // Abseil already excludes unsupported asynchronous WASI signal facilities.
    // These sources still use the shipped synchronous signal/raise provider.
    if (target.result.os.tag == .wasi) {
        module.addCMacro("_WASI_EMULATED_SIGNAL", "1");
    }
    module.addIncludePath(b.path(absl_sources.include_dir));
    module.addCSourceFiles(.{
        .root = b.path(absl_sources.include_dir),
        .files = &absl_sources.sources,
        .flags = platform_flags.abslFlags(target),
        .language = .cpp,
    });

    const lib = b.addLibrary(.{
        .name = "absl",
        .linkage = .static,
        .root_module = module,
    });
    wasi_provider.configureCompile(b, lib, provider);
    return lib;
}

/// Compiles the upstream S2 library and links Abseil into it.
fn addS2(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    provider: ?wasi_provider.Provider,
    absl_lib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi,
    });
    configureClock(module, target);
    if (provider) |actual| actual.configureModule(module);
    // Upstream `include_directories(src)`, plus the Abseil root, because the
    // s2 headers include `absl/...` by name.
    module.addIncludePath(b.path(s2_sources.include_dir));
    module.addIncludePath(b.path(absl_sources.include_dir));
    module.addCSourceFiles(.{
        // The source paths already start at `src/`, so no `root` is needed:
        // `addCSourceFiles` resolves relative paths against the package
        // directory when `root` is absent.
        .files = &s2_sources.sources,
        .flags = platform_flags.s2Flags(target),
        .language = .cpp,
    });
    module.linkLibrary(absl_lib);

    const lib = b.addLibrary(.{
        .name = "s2",
        .linkage = .static,
        .root_module = module,
    });
    wasi_provider.configureCompile(b, lib, provider);
    return lib;
}

/// Compiles this fork's bridge and installs it with the upstream headers.
///
/// The bridge is compiled from this repository in every mode, including
/// `-fsys=s2`: an installed upstream library exports no fork-only symbols, so
/// a system-mode bridge built against upstream sources would be a bridge to
/// nothing.
///
/// Why its include paths are *system* paths, and the libraries' are not
/// --------------------------------------------------------------
/// The two upstream header trees are on this translation unit as system
/// includes, which is upstream's own published arrangement for exactly this
/// situation: `CMakeLists.txt:46-49` defines `S2_USE_SYSTEM_INCLUDES` and
/// describes it as "Silence warnings in s2 headers by marking them as SYSTEM
/// includes", and `CMakeLists.txt:285-291` applies it to the `s2` target's
/// PUBLIC include directory -- the one every consumer of the installed library
/// is compiled with.  `zig/bridge.cc` is that consumer, and it is the one
/// translation unit of this package that parses an upstream header as a
/// consumer rather than as the library's own translation unit.
///
/// What that costs and does not cost.  A system include suppresses *warnings*
/// from the headers it names; it does not suppress an error, and it does not
/// touch diagnostics in `zig/bridge.cc` itself, which is the main file and is
/// always diagnosed.  Observed, in the recorded Debug run of the bridge
/// (`zig build-lib -cflags -std=c++17 ... -x c++ zig/bridge.cc`, 129
/// compilation errors), every one of those diagnostics came out of a
/// third-party header: the GNU-extension pair on `alignof(*p)` in
/// `src/s2/s2point_array.h:35,49`, and the nullability-completeness set in
/// `s2/s2loop.h`, `s2/s2builder.h`, `s2/s2builder_graph.h`,
/// `s2/s2boolean_operation.h`, `s2/s2polyline.h` and `s2/s2polygon.h`.  The
/// bridge diagnostics stay errors. The same compiler's installed C++ probe
/// reports the header diagnostics as warnings, while `zig build-lib` makes
/// them fatal here. Follow upstream's published system-include arrangement;
/// do not disable diagnostics in this fork's own translation unit.
///
/// The Abseil and S2 libraries themselves keep ordinary include paths
/// (`addAbseil`, `addS2` above), which is upstream's default arrangement: every
/// upstream translation unit keeps full diagnostics, and nothing about how the
/// library is compiled changes.
///
/// Why this artifact owns the installed upstream header root
/// -------------------------------------------------------
/// A linked library also puts its *installed header tree* on the linking
/// module's include path, and the Zig Build API has exactly one spelling for
/// that: `Module.IncludeDir.other_step` becomes an ordinary `-I`
/// (`std/Build/Module.zig:184`), never an `-isystem`.  Clang resolves an
/// `#include "…"` against `-I` roots ahead of `-isystem` roots whatever order
/// they appear in on the command line, and the recorded runs show that
/// directly: `…-final-cross-x86_64-linux-gnu-316.log` prints the bridge's own
/// command line as `-isystem src -isystem vendor/abseil-cpp -I
/// <cache>/o/<hash>`, while every diagnostic in
/// `…-materialized-package-consumer-341.log` names
/// `<cache>/o/<hash>/s2/s2builder.h`, not `src/s2/s2builder.h`. Declaring the
/// header installations on the bridge avoids this competing ordinary root.
///
/// Declaring the two header installations here instead leaves `libs2` and
/// `libabsl` with empty emitted trees, so the `-I` that `linkLibrary` adds
/// resolves nothing and the two source roots above are the only way this
/// translation unit reaches an upstream header.  Nothing else moves: the same
/// two archives are linked in the same order, the installed header tree under
/// `include/` holds the same files under the same two names -- this artifact
/// already forwarded both installations to itself -- and `zig/root.zig` still
/// reaches `s2/` and `absl/` through this artifact's emitted tree, which no C
/// or C++ translation unit is compiled against.
fn addBridge(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    provider: ?wasi_provider.Provider,
    s2_lib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi,
    });
    configureClock(module, target);
    if (provider) |actual| actual.configureModule(module);
    // System includes, and only here: see this function's doc comment. The
    // paths are the same two directories the libraries compile against, so the
    // bridge sees the headers it was written against; only their *kind* on this
    // translation unit differs.
    module.addSystemIncludePath(b.path(s2_sources.include_dir));
    module.addSystemIncludePath(b.path(absl_sources.include_dir));
    module.addCSourceFile(.{
        .file = b.path("zig/bridge.cc"),
        .flags = platform_flags.s2Flags(target),
        .language = .cpp,
    });
    module.linkLibrary(s2_lib);

    const lib = b.addLibrary(.{
        .name = "s2bridge",
        .linkage = .static,
        .root_module = module,
    });
    wasi_provider.configureCompile(b, lib, provider);
    // The upstream header root this artifact ships, declared here rather than
    // on `s2_lib`/`absl_lib`: see this function's doc comment.  The installed
    // tree holds the same files either way, and a C++ consumer that links this
    // artifact gets `#include <s2/s2cell_id.h>` and
    // `#include <absl/base/config.h>` for free, without reaching into this
    // repository's tree.
    //
    // The whole `src/s2` header tree, laid out under `include/s2`, so
    // `#include "s2/s2cell_id.h"` resolves exactly as it does upstream.  The
    // source of the install is `src/s2`, not `src`: pointing it at the
    // include root would install `include/s2/s2/s2cell_id.h` and break every
    // include in the tree.
    lib.installHeadersDirectory(
        b.path(s2_sources.header_dir),
        "s2",
        .{ .include_extensions = &.{".h"} },
    );
    // `.inc` matters: Abseil headers include their implementation fragments
    // by name, so installing only `.h` would ship a header tree that cannot
    // compile.  See `absl_sources.header_extensions`.
    lib.installHeadersDirectory(
        b.path(absl_sources.header_dir),
        "absl",
        .{ .include_extensions = &absl_sources.header_extensions },
    );
    lib.installHeader(b.path("zig/bridge.h"), "s2geometry_bridge.h");
    return lib;
}

/// Builds one target's test binary and example.
fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    provider: ?wasi_provider.Provider,
    comptime name: []const u8,
) *std.Build.Step.Compile {
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi,
    });
    test_module.addImport("s2geometry", module);
    if (provider) |actual| actual.configureModule(test_module);
    const tests = b.addTest(.{ .name = name, .root_module = test_module });
    wasi_provider.configureCompile(b, tests, provider);
    return tests;
}

fn addSmoke(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    provider: ?wasi_provider.Provider,
) *std.Build.Step.Compile {
    const exe_module = b.createModule(.{
        .root_source_file = b.path("smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi,
    });
    exe_module.addImport("s2geometry", module);
    if (provider) |actual| actual.configureModule(exe_module);
    const exe = b.addExecutable(.{ .name = "s2-smoke", .root_module = exe_module });
    wasi_provider.configureCompile(b, exe, provider);
    return exe;
}

/// Compiles the library, the facade, the tests and the example for one target
/// and attaches both to `step`.  Nothing is run.
fn addCheck(
    b: *std.Build,
    step: *std.Build.Step,
    raw_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wasi_sysroot: ?[]const u8,
) void {
    const target = wasi_provider.resolveTarget(b, raw_target);
    const graph = addGraph(b, target, optimize, false, wasi_sysroot);
    step.dependOn(&addTests(b, target, optimize, graph.module, graph.provider, "s2-analyze").step);
    step.dependOn(&addSmoke(b, target, optimize, graph.module, graph.provider).step);
}

/// `-fsys=s2`: link an installed libs2 and the Abseil it was built against.
///
/// Nothing from this tree is compiled into the library here.  The bridge is
/// still built from `zig/bridge.cc`, and the bridge header is still translated
/// -- but from the *installed* headers, by not putting this repository's
/// `src/` and `vendor/abseil-cpp` on either the compile line or the
/// translation line.  Translating the bundled v0.14.0 headers against an
/// installed library of unknown version would describe an ABI that may not be
/// the one on disk, which is exactly the failure a system mode exists to
/// avoid.  `zig/bridge.cc` therefore reaches `<s2/...>` and `<absl/...>`
/// through the target's own system include path, next to the installed
/// libraries it is linked with, so the code compiled and the ABI bound are
/// the ones that are actually on disk.
///
/// Step coverage is the same five entry points the bundled graph has:
/// `install`, `test`, `smoke`, `check` and `consumer`.  Omitting any of them
/// would leave the mode unproven where it matters most -- a system library
/// whose facade compiles but whose behaviour differs from this tree's is
/// exactly what this mode exists to catch -- and a step that only exists in
/// the bundled graph cannot tell an installed library apart from this
/// repository's.  What the mode cannot offer is the six-target matrix: the
/// library and the headers it binds to are installed for this machine, so
/// `check` compiles the selected target and reports on that.
///
/// One honest limit, stated rather than hidden: `zig/bridge.h` is plain C99
/// over `<stddef.h>` and `<stdint.h>` and names no upstream type, so the
/// translation has nothing of ours to resolve and reads the same header in
/// both modes.  The declarations that do cross the mode boundary -- every
/// `s2br_*` signature -- are compiled against the installed headers by the
/// bridge translation unit itself, which is where the C++ compiler checks
/// them against the installed library.
///
/// The three providers the bundled graph carries and this one does not
/// -------------------------------------------------------------
/// The bundled graph links `dbghelp` on Windows, links the `CoreFoundation`
/// framework on Apple targets, and selects Abseil's steady_clock backend on
/// OpenBSD/NetBSD PowerPC.  All three are properties of the vendored Abseil
/// closure this mode does not compile, and none of them is carried here.  That
/// is a decision with a reason behind each, not an omission.
///
/// `dbghelp` and `CoreFoundation` are requirements of library translation
/// units rather than of headers.  The DbgHelp calls are in
/// `absl/debugging/symbolize_win32.inc`, which only
/// `absl/debugging/symbolize.cc:34-37` includes; the CoreFoundation calls are in
/// `absl/time/internal/cctz/src/time_zone_lookup.cc:22-26,208-215`.  Both units
/// are in `build_support/absl_sources.zig`, and neither upstream library they
/// belong to appears in the set this mode links: `absl_libraries` below is
/// upstream's `s2` target's Abseil dependency list, `CMakeLists.txt:253-278`,
/// name for name, and it names neither `absl_symbolizing`/`absl_stacktrace` nor
/// `absl_time_cctz`/`absl_time`.  Naming either library here would add a
/// dependency to no translation unit this mode compiles.
///
/// `ABSL_USE_UNSCALED_CYCLECLOCK` chooses *which definition* of
/// `CycleClock::Now()` and `Frequency()` exists: inline in the header under the
/// macro (`absl/base/internal/cycleclock.h:105-138`) or out of line in the
/// library, on `std::chrono::steady_clock` (`cycleclock.cc:56-68`).  A define
/// that changes which definitions a header emits has to hold for every
/// translation unit compiled from the same tree, which is why `configureClock`
/// is called on all three bundled modules.  The installed
/// `absl/base/internal/unscaledcycleclock_config.h:47-51` picks its own value
/// under `#if !defined(...)` -- the guard that also makes the bundled define
/// effective -- so the installed build's configuration is the one that describes
/// the installed archive, and forcing this build's value onto the single
/// translation unit it compiles would put that unit on a different answer than
/// the library it calls.
///
/// What is left is the boundary, stated rather than papered over.  This mode
/// links installed archives, so what those archives reference is the business of
/// whoever built and installed them: their CMake export, their pkg-config file,
/// or the consumer's own link line.  This build does not inspect the installed
/// archives' link closure, does not name a system library on their behalf, and
/// claims nothing for a platform on which they are not installed.  The host it
/// is written for is the one that already has an installed `libs2` and the 26
/// `absl_*` archives beside it for the target being built; no `-fsys=s2` job
/// exists in `.github/workflows/verify.yml` for exactly that reason, so no
/// result is claimed here for any platform.
///
/// The provider this mode *does* share is the WASI one, through the same
/// `wasi_provider.Provider.init`, `configureModule`, `linkRuntime` and
/// `configureCompile` calls the bundled graph uses: the installed headers are
/// still compiled and the installed archives still linked against a real
/// sysroot rather than against a single-threaded default.
fn addSystemMode(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wasi_sysroot: ?[]const u8,
) void {
    // The `absl::` targets upstream's `s2` links, spelled as the installed
    // library names: an `absl_cc_library(NAME foo)` installs `libabsl_foo.a`.
    const absl_libraries = [_][]const u8{
        "absl_absl_vlog_is_on",
        "absl_base",
        "absl_btree",
        "absl_check",
        "absl_config",
        "absl_core_headers",
        "absl_dynamic_annotations",
        "absl_endian",
        "absl_fixed_array",
        "absl_flags",
        "absl_flat_hash_map",
        "absl_flat_hash_set",
        "absl_hash",
        "absl_inlined_vector",
        "absl_int128",
        "absl_log",
        "absl_log_severity",
        "absl_memory",
        "absl_span",
        "absl_status",
        "absl_statusor",
        "absl_str_format",
        "absl_strings",
        "absl_type_traits",
        "absl_utility",
        "absl_vlog_is_on",
    };

    const provider = wasi_provider.Provider.init(b, target, wasi_sysroot);
    const bridge_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi,
    });
    if (provider) |actual| actual.configureModule(bridge_module);
    bridge_module.addCSourceFile(.{
        .file = b.path("zig/bridge.cc"),
        .flags = platform_flags.s2Flags(target),
        .language = .cpp,
    });
    bridge_module.linkSystemLibrary("s2", .{});
    for (absl_libraries) |name| bridge_module.linkSystemLibrary(name, .{});

    const bridge_lib = b.addLibrary(.{
        .name = "s2bridge",
        .linkage = .static,
        .root_module = bridge_module,
    });
    wasi_provider.configureCompile(b, bridge_lib, provider);
    b.installArtifact(bridge_lib);
    bridge_lib.installHeader(b.path("zig/bridge.h"), "s2geometry_bridge.h");

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("zig/bridge.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (provider) |actual| translate_c.addIncludePath(actual.include_dir);
    const facade_module = b.addModule("s2geometry", .{
        .root_source_file = b.path("zig/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi,
    });
    const c_module = translate_c.addModule("c");
    if (provider) |actual| actual.configureModule(c_module);
    facade_module.addImport("c", c_module);
    facade_module.linkLibrary(bridge_lib);
    if (provider) |actual| {
        actual.configureModule(facade_module);
        actual.linkRuntime(facade_module);
    }

    const smoke_exe = addSmoke(b, target, optimize, facade_module, provider);
    b.getInstallStep().dependOn(&smoke_exe.step);

    const run_smoke = b.addRunArtifact(smoke_exe);
    run_smoke.has_side_effects = true;
    const smoke_step = b.step("smoke", "Run the deterministic S2 smoke program against the installed library");
    smoke_step.dependOn(&run_smoke.step);

    // `zig build test` runs the tests against the installed library, exactly as
    // the bundled graph does; see the `test` step there for why the run is not
    // guarded on the target being native.  A mode that offered only "compile"
    // in every case would not be running the library's behaviour against the
    // installed one at all.
    const test_step = b.step("test", "Run the behavioural tests against the installed library");
    const unit_tests = addTests(b, target, optimize, facade_module, provider, "s2-tests");
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    test_step.dependOn(&run_tests.step);

    // `check` compiles and runs nothing: the bridge against the installed
    // headers, the facade, `tests.zig` and `smoke.zig`, for the selected
    // target.  Both roots are attached, not only the example, because a facade
    // that only compiles is evidence about an unreferenced archive.
    const check_step = b.step(
        "check",
        "Compile the bridge, facade, tests and example against the installed libraries",
    );
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&smoke_exe.step);

    // The consumer package is a separate `zig build` invocation that
    // configures this package again as a path dependency, so the mode has to
    // travel with the arguments: without `-fsys=s2` there, `consumer` would
    // prove the bundled library while claiming to prove the installed one.
    addConsumerStep(b, target, optimize, true, wasi_sysroot);
}

/// `zig build consumer` builds the standalone `consumer/` package, which
/// depends on this package by path through `b.dependency`, and runs it when
/// this host can execute the selected target.
///
/// What has to reach the nested build
/// ---------------------------------
/// `consumer/` is a separate `zig build` invocation, so everything it must
/// agree with this build on travels as command-line arguments.  The options go
/// one argument each, which is the form the build runner parses, and the target
/// and CPU strings come from `Target.Query.zigTriple` and
/// `Target.Query.serializeCpuAlloc`, the two functions `standardTargetOptions`
/// itself uses to report this build's resolved target, so the sub-build parses
/// precisely what this build resolved.
///
/// The mode travels as `-fsys=s2`/`-fno-sys=s2` rather than as a `-D` option,
/// because `b.systemIntegrationOption` is fed by the build runner's `-fsys=`
/// and `-fno-sys=` flags and is not an entry in the `-D` map.  Both spellings
/// are forwarded, so the nested build resolves the same mode this build did
/// instead of falling back to its own default: `zig build consumer
/// -fsys=s2` that installed the bundled library and then proved the consumer
/// against the installed one would report two builds as one.
///
/// The standard library travels as `--zig-lib-dir`, given the directory this
/// build's compiler actually selected (`b.graph.zig_lib_directory`, the same
/// value `Step.Compile` forwards for every compilation at
/// `lib/std/Build/Step/Compile.zig:1658-1667`) and spelled as two arguments the
/// way the pinned standard library spells it.  Without it the nested build
/// resolves the standard library that sits beside the compiler rather than the
/// one this build used, so the consumer would be evidence about a different
/// `std` than the graph that produced the library -- and both build summaries
/// would still report themselves green, because each one would be right about
/// the build it actually ran.
///
/// And last, verbatim and behind a `--`: whatever the caller wrote after
/// `zig build consumer --`.  Those are this build's `b.args`, and the nested
/// build's `run` step hands its own `b.args` to the program
/// (`consumer/build.zig:87-88`).  An argument this step dropped would be an
/// argument the consumer accepted on the outer command line and then never
/// saw, which is the outer build reporting a narrower check than the one it
/// was asked for.  Everything above is this package's own bookkeeping with
/// the nested build; everything after the `--` is the program's, which is
/// why the `--` follows all of them.
///
/// Run, or only install
/// --------------------
/// The question is whether *this host* can execute the selected target.  It is
/// asked of the resolved target by `std.zig.system.getExternalExecutor`
/// (`lib/std/zig/system.zig:42`), the same function `std.Build.Step.Run` calls
/// when a spawned binary turns out to be foreign
/// (`lib/std/Build/Step/Run.zig:1268`).  That replaces a predicate which could
/// not answer it: `Target.Query.isNative()`
/// (`lib/std/Target/Query.zig:396-398`) is `isNativeTriple() and ofmt == null`,
/// and `isNativeTriple()` (`:392-394`) demands `cpu_arch`, `os_tag` and `abi`
/// all be null, so `-Dtarget=x86_64-linux` was never native on an x86_64 Linux
/// host -- this step took the `install` branch and silently built the consumer
/// without running it, which is the one thing this step exists to prevent.
///
/// An external executor counts as available only when the build runner was
/// told it may use one: `-fwasmtime`, `-fqemu`, `-fwine` and `-fdarling` are
/// the build runner's own switches for that
/// (`lib/compiler/build_runner.zig:388-407`, exposed as `b.enable_wasmtime` and
/// friends, `lib/std/Build.zig:71-79`), and each names a separate program whose
/// presence on `PATH` this script cannot know.  `-frosetta` names none and
/// `std.Build` reads `enable_rosetta` nowhere, so it is forwarded for fidelity
/// and never gates the decision; `hostCanExecute` says why.  Forwarding the
/// switches makes the decision and the nested run agree on one executor: an
/// explicitly enabled Wasmtime executes a `wasm32-wasi` consumer here, exactly
/// as it executes the smoke program, and without it the step installs only.  A
/// target that still has no executor builds and installs, which is compile
/// evidence and nothing more.
///
/// Forwarding `--libc-runtimes` is the same arrangement one step later.  The
/// nested `Run` step reads `b.libc_runtimes_dir` from its own graph, so the
/// directory has to travel; and `hostCanExecute` then has to ask the question
/// `Run` asks, including the refusal `Run` makes once the predicate has
/// already said yes.  That is why a QEMU'd GNU libc target with no runtimes
/// directory installs here rather than running there and failing.
fn addConsumerStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_system: bool,
    wasi_sysroot: ?[]const u8,
) void {
    const query = target.query;
    const triple = query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    const cpu = query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // `b.graph.zig_exe` is the compiler running this build script, so the
    // nested build uses the same toolchain instead of whatever is on PATH.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // `-fsys=s2` when this build resolved the system mode, `-fno-sys=s2`
    // otherwise: the nested graph calls `b.systemIntegrationOption` again, and
    // the default it would fall back to is this package's, not this build's.
    run.addArg(if (use_system) "-fsys=s2" else "-fno-sys=s2");
    if (wasi_sysroot) |root| run.addArg(b.fmt("-Dwasi-sysroot={s}", .{root}));
    // The compiler's own standard library, not a guess at one: `zig build
    // --zig-lib-dir=…` selects it for this build, and the nested build is a
    // different `zig build` that would otherwise resolve its own.
    if (b.graph.zig_lib_directory.path) |lib_dir| {
        run.addArgs(&.{ "--zig-lib-dir", lib_dir });
    }
    // The executor switches this build resolved, so the nested build runs under
    // the same one `hostCanExecute` decided with: `-fwasmtime` is how a WASI
    // consumer executes here, and `--libc-runtimes` is the QEMU integration's
    // dynamic-linker support (`lib/compiler/build_runner.zig:325`).
    if (b.enable_darling) run.addArg("-fdarling");
    if (b.enable_qemu) run.addArg("-fqemu");
    if (b.enable_rosetta) run.addArg("-frosetta");
    if (b.enable_wasmtime) run.addArg("-fwasmtime");
    if (b.enable_wine) run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| run.addArgs(&.{ "--libc-runtimes", runtimes });
    // When the outer build was given an explicit cache directory, the nested
    // one gets a subdirectory of it rather than sharing it: two build graphs
    // must not write the same manifest directory.  A null `path` means "the
    // current directory", and the working directory above is already the
    // consumer package.
    if (b.cache_root.path) |cache| {
        run.addArgs(&.{ "--cache-dir", b.fmt("{s}/consumer", .{cache}) });
    }
    // The caller's own arguments, last and behind `--`.  `zig build consumer --
    // …` collects them in `b.args`, the nested build's `run` step hands
    // `b.args` to the program (`consumer/build.zig:87-88`), and that program is
    // the consumer check.  Every argument above is this package's own
    // bookkeeping with the nested build; an argument the caller typed is
    // forwarded verbatim or not at all, and this `--` has to follow all of
    // them because it ends the nested build's option parsing.
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.has_side_effects = true;
    b.step(
        "consumer",
        "Build the consumer/ package, and run it when this host can execute the selected target",
    ).dependOn(&run.step);
}

/// True when this build can execute `target`'s binaries.
///
/// `std.zig.system.getExternalExecutor` (`lib/std/zig/system.zig:42`) is the
/// predicate `std.Build.Step.Run` asks about the artifact it is about to spawn
/// (`lib/std/Build/Step/Run.zig:1268`).  Both options `Run` fills in from that
/// artifact are filled in here from the same facts: the consumer executable
/// links libc because its library module requires it, and QEMU reaches a
/// foreign dynamic linker only with `--libc-runtimes`.
///
/// `Run` allows every executor in the predicate and then gates the answer on
/// this build's own switches (`:1277`, `:1291`, `:1317`, `:1325`); carrying
/// those switches in `allow_*` asks the identical question and answers it
/// without a second switch.  What an `allow_*` option cannot carry is a
/// refusal `Run` makes *after* the predicate has already said yes: its QEMU
/// arm returns `failForeign` for a `need_cross_libc` target that was given no
/// `--libc-runtimes` (`:1294-1311`).  That second gate is the `.qemu` arm
/// below, and it is why the answer there is not simply `true`.  Rosetta is
/// left at its default, as `Run` leaves it: `-frosetta` resolves, but nothing
/// in `std.Build` reads `b.enable_rosetta`, because on an Apple Silicon host
/// it is the operating system that runs the binary rather than a program this
/// build would have to find.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        // `Run`'s `need_cross_libc` (`lib/std/Build/Step/Run.zig:1264-1266`) is
        // `exe.is_linking_libc` and a test of the target itself; its musl half
        // additionally asks for `exe.linkage == .dynamic`, and `consumer/`
        // builds its executable with `b.addExecutable` and no linkage, so that
        // field is null there and the half never contributes.
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        // Reachable only for an executor the switches above enabled.
        .wine, .wasmtime, .darling => true,
        // `.qemu` is not a yes on its own: the second gate above.  A GNU libc
        // target with no runtimes directory is a step `Run` fails after this
        // function said yes to it, so this step installs it instead.  Every
        // other QEMU case -- a foreign architecture whose libc needs no cross
        // runtime, a musl consumer among them -- still runs, exactly as this
        // arm ran before.
        .qemu => !(candidate.isGnuLibC() and b.libc_runtimes_dir == null),
        // Same OS and CPU with no dynamic linker to load, or an architecture
        // and system this build has no enabled executor for.
        .bad_dl, .bad_os_or_cpu => false,
    };
}

// The pinned revisions, restated here so a `zig build` that succeeds has
// still said out loud which upstream it compiled.
comptime {
    std.debug.assert(s2_version.len > 0 and absl_version.len > 0);
    std.debug.assert(s2_commit.len == 40 and absl_commit.len == 40);
}

comptime {
    // The source lists are this package's contract with upstream.  A count
    // that drifts from upstream's own block is a bug in this file, not a
    // surprise to be discovered at link time.
    std.debug.assert(s2_sources.source_count == 108);
    std.debug.assert(absl_sources.sources.len == 153);
}
