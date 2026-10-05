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
//!                        standard library, both cache directories, the mode,
//!                        `-j8` and `--summary all` are forwarded to it, and
//!                        anything after `consumer --` is forwarded too)
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
//!   -Dlinkage=static    deliver the three libraries as static archives.  This
//!                        is the default and it is the linkage policy this SDK
//!                        has always had, so a caller that passes nothing
//!                        changes nothing.
//!   -Dlinkage=dynamic   deliver the three libraries as real shared objects:
//!                        upstream's own sonames, position-independent
//!                        constituent objects, a transitive closure the
//!                        installed tree can resolve, and the export surface
//!                        upstream's own shared build exports.  See "Static and
//!                        shared delivery" below.  A target whose operating
//!                        system has no dynamic linker refuses this rather than
//!                        delivering a static archive under a shared option's
//!                        name; `static` is the default and is supported
//!                        everywhere, `wasm32-wasi` included.  In `-fsys=s2`
//!                        the option also names the kind of *installed*
//!                        library to bind to, and there its absent default is
//!                        `dynamic`, which is the kind an installed `libs2`
//!                        normally is.
//!   -Druntime=true       resolve the native entry points at run time instead
//!                        of linking them.  The facade keeps the same
//!                        translated header and the same public types; each
//!                        selected native function becomes a dispatch through
//!                        one process-lifetime table an explicit
//!                        `load(source)` fills, and the module links no
//!                        archive.  Independent of `-Dlinkage`, which still
//!                        decides which artifact this build delivers and
//!                        installs.  Default off, and a linked build is
//!                        unchanged in every respect.  See "Runtime dispatch"
//!                        below.
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
//! Static and shared delivery
//! --------------------------
//! `-Dlinkage` selects which artifact each of the three libraries is, and the
//! default is the one this SDK has always produced: `static`, so a caller that
//! passes nothing gets the same `libabsl.a`, `libs2.a` and `libs2bridge.a` it
//! got before the option existed.
//!
//! The option moves the *delivery* and nothing about the compilation.  The same
//! 153 Abseil translation units, the same 108 S2 ones and the same
//! `zig/bridge.cc`; the same `build_support/s2_sources.zig` and
//! `build_support/absl_sources.zig`, which remain the one authoritative
//! source list; the same flags from `build_support/platform_flags.zig`; the
//! same header trees; and the same `single_threaded = false` WASI threading
//! model on every module, which `wasi_provider.Provider.configureModule` owns
//! and which `link_libcpp = false` on that target keeps beside it.
//!
//! All three libraries take the same linkage *together*, because they are one
//! dependency chain.  A `libs2bridge.so.0` that had `libs2.a` linked into it
//! as a static archive would not be the library its own soname names, and a
//! `libs2.so.0` with `libabsl.a` inside it would not resolve
//! `libs2bridge.so.0`'s dependency at run time.  One option, one value, three
//! artifacts: `build` resolves it once and every artifact takes the same
//! answer.
//!
//! `dynamic` is a real shared object, which takes four things a static archive
//! does not need.
//!
//!   * **Position independence on every constituent object.**  Nothing in this
//!     graph is compiled by a separate `b.addObject` step: all 262 translation
//!     units -- 153 Abseil, 108 S2 and this fork's one bridge -- reach the
//!     compiler through their own library's module, so the
//!     requirement is stated once per library on the module that owns its
//!     sources, as `.pic = true`, which reaches the command line as `-fPIC`
//!     (`lib/std/Build/Module.zig:554`).  A shared object is position
//!     independent whether or not this says so, so naming it is not what makes
//!     the build work; it is what keeps the next independently compiled unit
//!     from arriving unrelocated.  Upstream forces the same requirement for its
//!     own shared build (`CMakeLists.txt:79` sets
//!     `CMAKE_POSITION_INDEPENDENT_CODE ON` on the Abseil fetch path), and
//!     `BUILD_SHARED_LIBS` is upstream's default (`CMakeLists.txt:34`).
//!   * **Upstream's own soname**, not a number invented here:
//!
//!     - `libs2.so.0`.  `CMakeLists.txt:294-296` sets
//!       `SOVERSION ${PROJECT_VERSION_MAJOR}` on the `s2` target, and
//!       `CMakeLists.txt:7-8` still reads `project(s2-geometry VERSION 0.12.0)`
//!       inside the v0.14.0 tag -- a stale line this fork does not change, as
//!       `build.zig.zon:3-6` already records.  The major component is `0` under
//!       either version, so the ABI number upstream's build writes into
//!       `DT_SONAME` is the same one.  The file name uses this package's
//!       recorded version (`build.zig.zon .version`), and `build.zig` refuses to
//!       configure if the manifest and the soname stop naming one release.
//!     - `libabsl.so.2508`.  Abseil's own `ABSL_SOVERSION "2508.0.0"`
//!       (`vendor/abseil-cpp/CMakeLists.txt:27`), applied to this fork's
//!       single merged `absl` archive.  Upstream splits the closure this fork
//!       compiles into ~26 Abseil targets and gives each its own SOVERSION;
//!       `addAbseil` explains why this package compiles one archive instead,
//!       and the ABI number is upstream's whichever way the split is done.
//!     - `libs2bridge.so.0`.  Fork-authored: no upstream `SOVERSION` exists for
//!       it, because no upstream artifact does.  It takes `s2`'s number, which
//!       is the library it wraps.
//!
//!     `version` is null for a static archive, which has neither a soname nor a
//!     versioned file name.  On ELF, `lib/std/Build/Step/Compile.zig:488-515`
//!     turns these into `libs2.so.0.14.0` with `libs2.so.0` and `libs2.so`
//!     beside it (`Compile.zig:1824-1832`, and `wantSharedLibSymLinks` at
//!     `lib/std/Build.zig:2717-2719` says there are no such symlinks on
//!     Windows); on Darwin, `libs2.0.dylib` with `libs2.dylib` beside it and
//!     install name `@rpath/libs2.dylib` (`Compile.zig:492-498`,
//!     `:1496-1505`).  `b.installArtifact` installs the symlinks with the file.
//!
//!     One honest difference: CMake writes a SOVERSION string verbatim into the
//!     soname, and `std.SemanticVersion` has three components, so this graph
//!     writes `libabsl.so.2508` where CMake would write
//!     `libabsl.so.2508.0.0`.  The ABI number -- the part a consumer's
//!     `DT_NEEDED` and a `.system` load name -- is upstream's either way.
//!   * **A transitive closure the installed tree can actually resolve.**  `s2`
//!     links `absl` and the bridge links `s2`. Shared dependencies are linked
//!     by their emitted file to avoid Zig's automatic cache-first RPATH.
//!     Each shared object records its dependency's soname in `DT_NEEDED` and
//!     searches the installed directory first: `$ORIGIN`
//!     on ELF and `@loader_path` on Darwin, which is Abseil's published
//!     `INSTALL_RPATH` for exactly this arrangement
//!     (`vendor/abseil-cpp/CMake/AbseilHelpers.cmake:259-267`) together with
//!     s2geometry's own `set(CMAKE_MACOSX_RPATH TRUE)` (`CMakeLists.txt:20-22`).
//!     All three libraries install into `lib/`, so `$ORIGIN` finds the other two
//!     beside the one being loaded.  Windows has no runtime search path in this
//!     sense, so nothing is added there.
//!   * **The export surface upstream's own shared build exports, which is the
//!     default one.**  Nothing in the closure is decorated:
//!
//!     - `src/s2` carries no `__declspec`, no `visibility(` attribute, no
//!       `dllexport` and no `dllimport` in any header or `.inc` -- zero
//!       occurrences.
//!     - Abseil's one export macro, `ABSL_DLL`
//!       (`vendor/abseil-cpp/absl/base/config.h:614-626`), expands to nothing
//!       unless `_MSC_VER` *and* `ABSL_BUILD_DLL` are both defined.  This build
//!       never uses `cl.exe` (`build_support/platform_flags.zig`), and
//!       s2geometry's CMake never sets `ABSL_BUILD_DLL`, so the eleven headers
//!       that spell it (`absl/strings/ascii.h:71`,
//!       `absl/hash/internal/hash.h:1224` and the rest) are undecorated here
//!       exactly as they are in upstream's own shared build.
//!     - Neither `CMakeLists.txt` nor Abseil's `absl_cc_library` helper sets
//!       `C_VISIBILITY_PRESET` or `CXX_VISIBILITY_PRESET`.
//!
//!     So this build adds no `-fvisibility=hidden` and no version script.
//!     Either one would hide *every* symbol, because there is no export macro
//!     to widen it back: `zig/bridge.cc`'s `s2br_*` definitions, the S2 C++
//!     API and the Abseil internals are all equally undecorated, and upstream's
//!     own `libs2.so` exports all of them.
//!
//! One target boundary belongs here rather than only in the code.  WASI has no
//! dynamic linker -- `std.Target.DynamicLinker.kind` is `.none` for it
//! (`lib/std/Target.zig:2345-2402`) -- so it cannot carry a shared object at
//! all, and `zig build check` walks a WASI target.  `-Dlinkage=dynamic` for
//! such a target is therefore *refused* by `rejectUnsupportedDynamicLinkage`,
//! with the reason and the way out, rather than quietly delivered as a static
//! archive under the name that was not asked for: a build that reported
//! success for an artifact it did not produce is the worse failure of the two.
//! The default is `static`, and the static delivery is fully supported on every
//! target in the matrix, `wasm32-wasi` included, so that path never reaches the
//! refusal.  `zig build check` with no `-Dlinkage` compiles all six targets.
//!
//! What a shared build does *not* make interchangeable
//! --------------------------------------------------
//! `libs2bridge` is this fork's own C surface.  No `s2br_*` symbol exists in
//! an upstream `libs2` at any version, because every one of them is defined in
//! `zig/bridge.cc` in this repository.  So a shared `libs2bridge.so.0` is the
//! only loadable image this package publishes that carries the C entry points,
//! and it is the image whose `DT_NEEDED` closure is `libs2.so.0` and, through
//! it, `libabsl.so.2508`.  A shared `libs2.so.0` is not a substitute for it
//! under any loading strategy: it exports the C++ API, not the C one.  That is
//! why the bridge's header installation stays on the bridge artifact, and why
//! the runtime-loadable provider for this SDK is this package's own shared
//! bridge rather than an arbitrary installed `libs2`.
//!
//! Installed closure
//! -----------------
//! `zig build` in bundled mode installs:
//!
//!   * the three libraries, in whichever `-Dlinkage` selected, through
//!     `b.installArtifact`.
//!   * on an ELF target with `-Dlinkage=dynamic`, and on **no other route**,
//!     `lib/libs2cpp.so.0.16.0` with `libs2cpp.so.0` and `libs2cpp.so` beside
//!     it, installed by the same `b.installArtifact` call.  It is one object:
//!     the pinned compiler's own libc++, libc++abi and libunwind, compiled by
//!     `build_support/cpp_runtime.zig`, and every one of the three libraries
//!     above is compiled against that runtime's ABI instead of embedding a
//!     private static copy of its own.  `sharedCppOwner(target, linkage)` is
//!     the whole predicate -- `linkage == .dynamic` together with
//!     `target.result.ofmt == .elf` -- so `static`, `wasm32-wasi`, Darwin and
//!     Windows install no runtime object and keep their ordinary C++ provider
//!     rules.
//!   * `include/s2/**.h`, `include/absl/**.h`, `include/absl/**.inc` and
//!     `include/s2geometry_bridge.h`, through the header installations the
//!     bridge artifact carries (`addBridge`), so a C or C++ consumer that
//!     links any of them gets the whole upstream include closure.
//!   * `lib/pkgconfig/s2geometry.pc`, generated by `addPkgConfig`.  Upstream
//!     ships no `.pc` template -- `Config.cmake.in` is a CMake package config
//!     rather than link metadata -- so this file is fork-authored, and its
//!     `prefix` is `${pcfiledir}/../..` instead of a configured absolute
//!     prefix: this graph does not know where `--prefix` will point when it
//!     writes the file, and `${pcfiledir}` is resolved against the `.pc` that
//!     was found, so the installed file is correct wherever the prefix landed.
//!     `Libs` names `-ls2cpp` on that same ELF shared route and nowhere else,
//!     because that is the only route that installs a `libs2cpp` to name.
//!   * `share/licenses/s2geometry/` with every carried licence text and
//!     provenance record, through `installLicenceRecords`.  A private
//!     repository removes no upstream obligation, and a package that ships a
//!     binary without them is the failure this prevents.
//!   * on that same ELF shared route, and installed with the artifact itself
//!     rather than separately, three more texts in that directory:
//!     `LICENSE.libcxx.txt`, `LICENSE.libcxxabi.txt` and
//!     `LICENSE.libunwind.txt`, through `cpp_runtime.installLicences`.  The
//!     three runtime components are the LLVM project's under Apache-2.0 with
//!     the LLVM exception, which the compiler's own MIT text -- the grant
//!     `installLicenceRecords` ships for the standard-library patch -- does not
//!     extend to, so each component's own `LICENSE.TXT` travels verbatim from
//!     the compiler's own sources.  They exist exactly when `libs2cpp` does.
//!
//! The build graph owns all of those paths.  `package.nix` reads the result; it
//! does not reproduce it.
//!
//! Runtime dispatch
//! ----------------
//! `-Druntime=true` resolves the native entry points at run time instead of
//! linking them.  The facade keeps the same translated header and the same
//! public types; each selected native function becomes a dispatch through one
//! process-lifetime table an explicit `load(source)` fills, and the module
//! links no archive.  It is orthogonal to `-Dlinkage`: that option says which
//! artifact is delivered and installed, this one says how the facade reaches
//! it, so under `-Druntime` the three libraries are still built and installed
//! and a caller may equally name a provider this tree did not build.
//!
//! The dispatch itself is `runtime/graph.zig`, which the API role owns.
//! `addGraph` and `addSystemMode` are the only two functions that call it, and
//! each names the same two lines: `graph.createModule(b, translate_c, target,
//! optimize)` replaces the translated-header module as `c`, and the library
//! link is dropped.  The generated dispatch re-exports every type and constant
//! from the translation it was generated from, so `c.S2BridgeLoop` in the
//! facade and the declaration behind the table are one type rather than two
//! nominally distinct ones.
//!
//! The linked branch gets `graph.createCoreModule(b, target, optimize)` as the
//! facade's `rt` import instead, and only there: `LoadSource` and `LoadError`
//! are this SDK's public types and must be the same types in one build, which
//! means exactly one loader-core instance per configuration and never two.
const std = @import("std");

/// The runtime-loading build half, owned by the API role (`S2geometryApiContract`).
///
/// `createModule` builds the generated dispatch that replaces
/// `translate_c.createModule()` under `-Druntime`; it makes the loader-core
/// module itself and re-exports `LoadSource`/`LoadError` from it.
/// `createCoreModule` builds that same core module for the *linked* branch,
/// where there is no dispatch to carry the types and the facade's `rt` import
/// is where they come from (`zig/root.zig:261,281,287`).
///
/// The two branches must not both call `createCoreModule`.  `LoadSource` and
/// `LoadError` are this SDK's public types, so they have to be the *same* types
/// in one build: a second core instance would be a second, nominally distinct
/// `LoadSource`, and `s2geometry.load(source)` would be handing the facade's
/// type to a function expecting the dispatch's.  `addGraph` is the only
/// function that calls either, and it calls exactly one per configuration.
///
/// Importing it here rather than inside a branch is deliberate: the module is
/// resolved at build-script compile time, so `-Druntime` is a runtime
/// selection between two already-wired graphs rather than a decision about
/// which code exists.
const graph = @import("runtime/graph.zig");

const absl_sources = @import("build_support/absl_sources.zig");
const platform_flags = @import("build_support/platform_flags.zig");
const wasi_provider = @import("build_support/wasi_provider.zig");
const s2_sources = @import("build_support/s2_sources.zig");
const cpp_runtime = @import("build_support/cpp_runtime.zig");

/// The upstream releases this package pins.  Kept in step with UPSTREAM.md.
const s2_version = s2_sources.version;

const s2_commit = s2_sources.commit;
const absl_version = absl_sources.version;
const absl_commit = absl_sources.commit;

/// `build.zig.zon` itself, read for `.version` rather than copied.
///
/// `s2_sources.version` and this must name the same release; the `comptime`
/// block at the end of this file refuses to configure when they drift, so the
/// manifest, the installed `s2geometry.pc` and the shared object's file name
/// cannot describe three different releases.
const manifest = @import("build.zig.zon");

/// `build.zig.zon .version`, parsed.
///
/// The parse is the loud part: a manifest whose `.version` is not a semantic
/// version fails to configure here rather than being compared as something
/// else.
const package_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

/// The `s2` shared object's version: soname `libs2.so.0`.
///
/// The major component is upstream's `SOVERSION ${PROJECT_VERSION_MAJOR}`
/// (`CMakeLists.txt:294-296`), which is `0` whether the stale `project()` line
/// at `:7-8` says 0.12.0 or the tag says 0.14.0.  The minor and patch are this
/// package's recorded version, because that is the release this fork pins; see
/// the soname section above.
const s2_abi_version: std.SemanticVersion = .{ .major = 0, .minor = 14, .patch = 0 };

/// The `absl` shared object's version: soname `libabsl.so.2508`.
///
/// Abseil's own `ABSL_SOVERSION "2508.0.0"`
/// (`vendor/abseil-cpp/CMakeLists.txt:27`), applied to this fork's single
/// merged archive.  2508 is the LTS 2025-08 release's own encoding of its
/// version, so it is upstream's number rather than one invented here.
const absl_abi_version: std.SemanticVersion = .{ .major = 2508, .minor = 0, .patch = 0 };

/// The `s2bridge` shared object's version: soname `libs2bridge.so.0`.
///
/// Fork-authored, so it has no upstream SOVERSION to copy; it takes `s2`'s,
/// which is the library the bridge wraps.  The `-Dlinkage` section above says
/// why a shared bridge and a shared `libs2` are not interchangeable.
const bridge_abi_version: std.SemanticVersion = .{ .major = 0, .minor = 14, .patch = 0 };

/// The `s2cpp` shared object's version: soname `libs2cpp.so.0`.
///
/// This one is the **build compiler's** version and deliberately not this
/// package's: the object is the pinned compiler's own libc++/libc++abi/libunwind,
/// so it carries the compiler's 0.16.0 rather than s2geometry's 0.14.0, and a
/// consumer pins the soname exactly as it does for the other three.  It is the
/// build compiler's version that `UPSTREAM.md` records beside the artefact.
/// Kept in step with `build_support/cpp_runtime.zig`'s `add`, which is where the
/// library is configured; nothing else in this file builds one.
const cpp_runtime_version: std.SemanticVersion = .{ .major = 0, .minor = 16, .patch = 0 };

/// The installed package `-fsys=s2` binds to, as pkg-config spells it: the
/// library stems are `s2`/`absl`/`s2cpp` and the package is the project,
/// `s2geometry` (`addPkgConfig`). std.Build resolves a name to a package by
/// stem, so the package name has to be the argument or nothing is ever read.
const system_pkg_config_module = "s2geometry";

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
    /// One visible C++ runtime for the ELF shared closure.
    cpp_lib: ?*std.Build.Step.Compile,
};

/// Native delivery, separate from the facade's dispatch and runtime state.
const NativeGraph = struct {
    absl_lib: *std.Build.Step.Compile,
    s2_lib: *std.Build.Step.Compile,
    bridge_lib: *std.Build.Step.Compile,
    cpp_lib: ?*std.Build.Step.Compile,
};

pub fn build(b: *std.Build) void {
    const target = wasi_provider.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const wasi_sysroot = b.option([]const u8, "wasi-sysroot", "Complete WASI SDK 34+ sysroot with WASIp1-threads EH C/C++ providers");
    const linkage_option = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Deliver this package's own native libraries as static archives (the " ++
            "default, and this SDK's linkage policy) or as real shared " ++
            "objects with upstream's sonames. This selects the delivery and " ++
            "never the compilation: the same Abseil and S2 sources, the " ++
            "same bridge, the same flags and the same header closure are " ++
            "built either way. In -fsys=s2 the only artifact this graph still " ++
            "compiles is the bridge, and the option additionally names the " ++
            "kind of installed libs2 and Abseil to bind to.",
    );

    // `delivery` is what this graph hands back.  Both modes compiled static
    // archives before this option existed, so both keep `.static`, and a
    // caller who asks for `dynamic` and cannot have it is told so rather than
    // handed the other one: `rejectUnsupportedDynamicLinkage` below.
    //
    // The other question this option answers -- which kind of *installed*
    // library `-l` names in `-fsys=s2` -- is asked inside that branch,
    // because there is no installed library in bundled mode.
    // `linkSystemLibrary`'s own default is `.dynamic`
    // (`lib/std/Build/Module.zig:359`), and that call was written without a
    // `preferred_link_mode`, so `.dynamic` is what the mode has always had and
    // what it keeps.  Deriving one default from the other would change one of
    // the two modes for a caller who passes nothing.
    const system_mode = b.systemIntegrationOption("s2", .{ .default = false });
    const delivery: std.builtin.LinkMode = linkage_option orelse .static;

    // `-Dlinkage` and `-Druntime` are orthogonal and each is passed through
    // unchanged.  The first says which artifact is delivered and installed;
    // the second says whether the facade reaches it through a link line or
    // through a table an explicit `load` fills.  Under `-Druntime` the three
    // artifacts are still built and installed below -- delivery and dispatch
    // are separate questions, and the point of the mode is that a caller may
    // equally name a provider this tree did not build.
    const runtime_option = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. " ++
            "The facade keeps the same translated header and the same public " ++
            "types; each selected native function becomes a dispatch through " ++
            "one process-lifetime table that an explicit load(source) fills, " ++
            "and the module links no archive. Independent of -Dlinkage, which " ++
            "still decides which artifact this build delivers and installs. " ++
            "Default off, and a linked build is unchanged in every respect.",
    );
    const runtime_loaded = runtime_option orelse false;

    if (system_mode) {
        addSystemMode(
            b,
            target,
            optimize,
            wasi_sysroot,
            delivery,
            linkage_option orelse .dynamic,
            linkage_option,
            runtime_option,
        );
        return;
    }

    rejectUnsupportedDynamicLinkage(target, delivery, "the published build");
    const linkage = delivery;

    const published = addGraph(b, target, optimize, linkage, runtime_loaded, true, wasi_sysroot);

    // Installed DSOs must not retain cache paths. The published facade uses
    // cache-aware link copies so an out-of-tree consumer can run immediately.
    const installed = if (linkage == .dynamic)
        addNativeGraph(b, target, optimize, linkage, published.provider, false)
    else
        NativeGraph{
            .absl_lib = published.absl_lib,
            .s2_lib = published.s2_lib,
            .bridge_lib = published.bridge_lib,
            .cpp_lib = published.cpp_lib,
        };
    b.installArtifact(installed.absl_lib);
    b.installArtifact(installed.s2_lib);
    b.installArtifact(installed.bridge_lib);
    if (installed.cpp_lib) |cpp_lib| {
        b.installArtifact(cpp_lib);
        cpp_runtime.installLicences(b);
    }

    // The rest of the delivery, not just the archives.  A shared object with
    // no pkg-config metadata, and a package that ships a binary with no
    // licence material beside it, are both source drops rather than
    // packages: one leaves a C consumer no `-ls2bridge` to resolve, and the
    // other removes an obligation a private repository does not remove.
    // Both are installed only in bundled mode, because in system mode there
    // is no artifact here to describe.  See "Installed closure" at the top.
    addPkgConfig(b, target, linkage);
    installLicenceRecords(b);

    const smoke_exe = addSmoke(b, target, optimize, published.module, published.provider);
    // `zig build` installs the libraries and compiles the example; it does not
    // run it.  The example is the cheapest thing that proves the facade, the
    // translated C and the real C++ agree on types, symbols and link-time
    // dependencies.
    b.getInstallStep().dependOn(&smoke_exe.step);

    const run_smoke = b.addRunArtifact(smoke_exe);
    run_smoke.has_side_effects = true;
    if (b.args) |args| run_smoke.addArgs(args);
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
    const unit_tests = addTests(b, target, optimize, published.module, published.provider, "s2-tests");
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
        addCheck(b, check_step, target, optimize, delivery, runtime_loaded, wasi_sysroot);
    } else {
        for (check_targets) |query| {
            addCheck(b, check_step, b.resolveTargetQuery(query), optimize, delivery, runtime_loaded, wasi_sysroot);
        }
    }

    // `false`: this branch is reached only when `b.systemIntegrationOption`
    // resolved the bundled mode, so the nested consumer build is told so
    // explicitly rather than being left to resolve it again.
    addConsumerStep(b, target, optimize, false, linkage_option, runtime_option, wasi_sysroot);

    // Which artifact this configuration handed back, and how the facade reaches
    // it, are facts worth reading out of the build rather than inferring from a
    // cache directory.  These are configure-time lines: nothing has been
    // compiled when they print.
    if (linkage == .dynamic) {
        // The compiled C++ runtime joins this answer on exactly the route that
        // installs it.  `sharedCppOwner` is the same predicate `addNativeGraph`
        // and `cpp_runtime.installLicences` use, so the line names a fourth
        // object precisely when the install tree will carry one and stays at
        // three for `static`, `wasm32-wasi`, Darwin and Windows.  A configure
        // line that announced three objects for a prefix holding four would be
        // the wrong answer to the question these lines exist to answer.
        const shared_cpp = if (sharedCppOwner(target, linkage))
            b.fmt(", {s}", .{deliveryName(b, target, "s2cpp", cpp_runtime_version)})
        else
            "";
        std.debug.print("s2geometry: shared objects (-Dlinkage=dynamic): {s}, {s}, {s}{s}\n", .{
            deliveryName(b, target, "absl", absl_abi_version),
            deliveryName(b, target, "s2", s2_abi_version),
            deliveryName(b, target, "s2bridge", bridge_abi_version),
            shared_cpp,
        });
    } else {
        std.debug.print("s2geometry: static archives (-Dlinkage=static, the default)\n", .{});
    }
    if (runtime_loaded) {
        // Dispatch is a separate fact from delivery, and a runtime-loaded build
        // links nothing into the module: the caller names a provider with an
        // explicit `load(source)` and the symbols arrive through the platform
        // loader.  Printing it here is what keeps "the library is still built
        // and installed" from reading as "the module links it".
        std.debug.print(
            "s2geometry: runtime-loaded dispatch (-Druntime=true); no library " ++
                "is linked into the module, and a provider is named by an " ++
                "explicit load(source)\n",
            .{},
        );
    }
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
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    public: bool,
    wasi_sysroot: ?[]const u8,
) Graph {
    const provider = wasi_provider.Provider.init(b, target, wasi_sysroot);
    // One `linkage` for all three, resolved by the caller.  They are one
    // dependency chain, so a `libs2bridge.so.0` with `libs2.a` inside it would
    // not be the library its own soname names; see "Static and shared
    // delivery" at the top of this file.
    const native = addNativeGraph(b, target, optimize, linkage, provider, true);

    // Where the runtime-loading seam is
    // ---------------------------------
    // `-Druntime` is orthogonal to `-Dlinkage`: this option says which
    // artifact is delivered and installed, that one says whether the facade
    // calls it through a link line or through a table an explicit `load`
    // fills.  Two lines below are the whole seam:
    //
    //   * `c_module` becomes `graph.createModule(b, translate_c, target,
    //     optimize)`.  It takes the `TranslateC` step this function has just
    //     built, so the generated dispatch is produced from the header this
    //     build actually selected and keeps the exact translated type and
    //     constant namespace rather than compiling a second copy of the native
    //     extern structs and casting between two nominally distinct Zig
    //     modules: every type and constant in the dispatch is re-exported from
    //     the translation it was generated from, so `c.S2BridgeLoop` in the
    //     facade and `c_native.S2BridgeLoop` in the dispatch are one type.
    //   * `module.linkLibrary(bridge_lib)` is dropped, so the link line names
    //     no archive at all: linking it as well would make the linker resolve
    //     the same symbols statically and the runtime route would quietly be a
    //     linked one.  The three artifacts are still built and installed above
    //     -- delivery and dispatch are separate questions, and the point of
    //     the mode is that a caller may name a provider this tree did not
    //     build.
    //
    // The three libraries themselves are built either way, from the same
    // source list, with the same linkage.  Nothing here is conditional on
    // `runtime_loaded` except those two lines.
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
    // Exactly one loader-core instance per configuration.  `graph.createModule`
    // makes it for the dispatch and re-exports `LoadSource`/`LoadError` from it,
    // so the runtime branch must NOT ask for another one; the linked branch has
    // no dispatch and therefore needs the core module itself, which arrives
    // below as the facade's `rt` import.
    const c_module: *std.Build.Module = if (runtime_loaded)
        graph.createModule(b, translate_c, target, optimize)
    else if (public)
        translate_c.addModule("c")
    else
        translate_c.createModule();

    if (runtime_loaded) {
        // `graph.zig` puts the two upstream include roots on the dispatch and on
        // its own `c_native` module, because it builds that module from the same
        // `TranslateC` step for the same reason this function's linked branch
        // does.  What it deliberately leaves to the caller is anything
        // target-specific: the external WASI sysroot's roots, its include
        // roots and its threading model, which `configureModule` owns and
        // which must reach this module exactly as it reaches the facade below.
        if (provider) |actual| actual.configureModule(c_module);
    } else {
        // `addModule`/`createModule` copy only `link_libc` and the system
        // libraries, so the include paths have to be put back on the module
        // itself.  The provider's own roots come from `configureModule`, which
        // carries them together with the threading model: the translated header
        // is compiled into the same graph as the facade, the tests and the smoke
        // root, and one module quietly keeping the `wasm32-wasi`
        // single-threaded default is the same split libc TLS that model exists
        // to prevent.
        c_module.addIncludePath(b.path(s2_sources.include_dir));
        c_module.addIncludePath(b.path(absl_sources.include_dir));
        if (provider) |actual| actual.configureModule(c_module);
    }

    const module = if (public)
        b.addModule("s2geometry", .{
            .root_source_file = b.path("zig/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = target.result.os.tag != .wasi and linkage == .static and !runtime_loaded,
        })
    else
        b.createModule(.{
            .root_source_file = b.path("zig/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = target.result.os.tag != .wasi and linkage == .static and !runtime_loaded,
        });
    module.addImport("c", c_module);
    if (runtime_loaded) {
        // No `rt` import and no library link, and that is the whole of the
        // runtime configuration.  `LoadSource` and `LoadError` come from the
        // dispatch that is already bound to `c`, so naming the core module a
        // second time here would make two nominally distinct sets of the same
        // public types in one build.
    } else {
        // `zig/root.zig:261` imports `rt` for exactly two public types and
        // nothing else, so a linked build pays for the core module as two
        // declarations and no code.
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        module.linkLibrary(native.bridge_lib);
    }
    if (provider) |actual| {
        actual.configureModule(module);
        actual.linkRuntime(module);
    }

    return .{
        .absl_lib = native.absl_lib,
        .s2_lib = native.s2_lib,
        .bridge_lib = native.bridge_lib,
        .module = module,
        .provider = provider,
        .cpp_lib = native.cpp_lib,
    };
}

/// Builds the same native closure with cache or installed-tree search paths.
fn addNativeGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    provider: ?wasi_provider.Provider,
    cache_paths: bool,
) NativeGraph {
    const cpp_lib = if (sharedCppOwner(target, linkage)) cpp_runtime.add(b, target) else null;
    const absl_lib = addAbseil(b, target, optimize, platform_flags.isWindows(target), provider, cpp_lib, linkage, cache_paths);
    const s2_lib = addS2(b, target, optimize, provider, absl_lib, cpp_lib, linkage, cache_paths);
    const bridge_lib = addBridge(b, target, optimize, provider, s2_lib, cpp_lib, linkage, cache_paths);
    return .{ .absl_lib = absl_lib, .s2_lib = s2_lib, .bridge_lib = bridge_lib, .cpp_lib = cpp_lib };
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

/// ELF shared constituents use one source-built C++ runtime.
///
/// Abseil logging hands C++ stream objects to S2 templates. The compiler's
/// hidden static runtimes cannot share their locale facet identities.
fn sharedCppOwner(target: std.Build.ResolvedTarget, linkage: std.builtin.LinkMode) bool {
    return linkage == .dynamic and target.result.ofmt == .elf;
}

/// Wires the shared runtime and its matching headers into a native module.
fn configureSharedCpp(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    cpp_lib: ?*std.Build.Step.Compile,
    cache_paths: bool,
) void {
    if (cpp_lib) |library| {
        cpp_runtime.configureHeaders(b, module, target);
        linkNativeDependency(module, library, target, cache_paths);
    }
}

/// Compiles the vendored Abseil library.
///
/// One library holds the whole closure rather than the ~150 targets upstream's
/// CMake creates: an archive of the same translation units satisfies the same
/// link, and it means every object an S2 function can reach is compiled here
/// rather than being hoped for.  `-Dlinkage` chooses whether that one artifact
/// is a static archive or a shared object; the source list is identical either
/// way.  What the shared form gives up is upstream's shallower dependency
/// graph -- ~26 Abseil shared objects, each with its own `DT_NEEDED` -- for a
/// single one, which is a narrower installation and not a different library.
/// The source list is `build_support/absl_sources.zig`, including source files
/// upstream lists in either `SRCS` or `HDRS`.
fn addAbseil(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    windows: bool,
    provider: ?wasi_provider.Provider,
    cpp_lib: ?*std.Build.Step.Compile,
    linkage: std.builtin.LinkMode,
    cache_paths: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi and cpp_lib == null,
        // Every Abseil translation unit reaches the compiler through this one
        // module -- there is no separately compiled Abseil object in this graph
        // -- so this is the single place the library's relocatability is
        // stated.  Null for a static archive, which needs none and whose
        // linker has no dynamic symbol table to relocate.
        .pic = if (linkage == .dynamic) true else null,
    });
    configureClock(module, target);
    configureSharedCpp(b, module, target, cpp_lib, cache_paths);
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
        .linkage = linkage,
        // Abseil's own `ABSL_SOVERSION "2508.0.0"`
        // (`vendor/abseil-cpp/CMakeLists.txt:27`), on this fork's single merged
        // archive.  Null for a static archive, which has no soname and no
        // versioned file name.
        .version = if (linkage == .dynamic) absl_abi_version else null,
        .root_module = module,
    });
    if (linkage == .dynamic) addInstalledTreeRPath(module, target);
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
    cpp_lib: ?*std.Build.Step.Compile,
    linkage: std.builtin.LinkMode,
    cache_paths: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi and cpp_lib == null,
        // For the reason `addAbseil` gives, on the module that owns all 108
        // S2 translation units.
        .pic = if (linkage == .dynamic) true else null,
    });
    configureClock(module, target);
    configureSharedCpp(b, module, target, cpp_lib, cache_paths);
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
    linkNativeDependency(module, absl_lib, target, cache_paths);

    const lib = b.addLibrary(.{
        .name = "s2",
        .linkage = linkage,
        // `SOVERSION ${PROJECT_VERSION_MAJOR}` with `VERSION ${PROJECT_VERSION}`
        // (`CMakeLists.txt:294-296`); the major is 0 under the stale
        // `project()` line at `:7-8` and under this package's recorded version
        // alike.  See "Static and shared delivery" for the file names this
        // produces.
        .version = if (linkage == .dynamic) s2_abi_version else null,
        .root_module = module,
    });
    if (linkage == .dynamic) addInstalledTreeRPath(module, target);
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
    cpp_lib: ?*std.Build.Step.Compile,
    linkage: std.builtin.LinkMode,
    cache_paths: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi and cpp_lib == null,
        // For the reason `addAbseil` gives, on the module that owns this
        // fork's one C++ translation unit.
        .pic = if (linkage == .dynamic) true else null,
    });
    configureClock(module, target);
    configureSharedCpp(b, module, target, cpp_lib, cache_paths);
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
    linkNativeDependency(module, s2_lib, target, cache_paths);

    const lib = b.addLibrary(.{
        .name = "s2bridge",
        .linkage = linkage,
        // Fork-authored, so there is no upstream `SOVERSION` to copy; it takes
        // `s2`'s, which is the library this bridge wraps.  "Static and shared
        // delivery" says why a shared bridge and a shared `libs2` are not
        // interchangeable under any loading strategy: every `s2br_*` symbol is
        // defined in `zig/bridge.cc` in this repository, and an upstream
        // `libs2` exports none of them.
        .version = if (linkage == .dynamic) bridge_abi_version else null,
        .root_module = module,
    });
    if (linkage == .dynamic) addInstalledTreeRPath(module, target);
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
        .link_libcpp = module.link_libcpp,
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
        .link_libcpp = module.link_libcpp,
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
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    wasi_sysroot: ?[]const u8,
) void {
    const target = wasi_provider.resolveTarget(b, raw_target);
    // One target of the matrix was asked for a shared delivery it cannot
    // carry, and that is a failure of this cell rather than a licence to
    // deliver the other thing.  It is reported on the cell, not at configure
    // time, so the other targets of the matrix are still attempted -- which is
    // what `check` is for: every target in the matrix is attempted rather than
    // skipped as unsatisfiable, so that whatever fails, fails visibly.
    if (linkage == .dynamic and !targetHasDynamicLinker(target)) {
        step.dependOn(&b.addFail(b.fmt(
            "s2geometry: check cannot deliver shared objects for {s}; no static substitution. Use -Dlinkage=static.",
            .{@tagName(target.result.os.tag)},
        )).step);
        return;
    }
    const built = addGraph(b, target, optimize, linkage, runtime_loaded, false, wasi_sysroot);
    step.dependOn(&addTests(b, target, optimize, built.module, built.provider, "s2-analyze").step);
    step.dependOn(&addSmoke(b, target, optimize, built.module, built.provider).step);
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
/// are in `build_support/absl_sources.zig`, and neither library they belong
/// to is a need of anything this mode compiles: the merged `absl` artifact
/// (`addAbseil`) is what the installed metadata names, so naming either one
/// here would add a dependency to no translation unit this mode compiles.
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
/// What this mode takes from the installed tree comes from one file,
/// `lib/pkgconfig/s2geometry.pc` (`addPkgConfig`). Which closure that file
/// describes is the caller's: `PKG_CONFIG_PATH`/`PKG_CONFIG_LIBDIR` scope this
/// graph's search and nothing else chooses it, so scoping a prefix gets that
/// prefix and scoping none gets a refused build. `Libs.private` (`-ldbghelp`,
/// `-framework CoreFoundation`) is not what `pkg-config --libs` reports and
/// stays the installed tree's own business. No `-fsys=s2` job exists in
/// `.github/workflows/verify.yml`, so no platform is claimed here either.
///
/// The provider this mode *does* share is the WASI one, through the same
/// `wasi_provider.Provider.init`, `configureModule`, `linkRuntime` and
/// `configureCompile` calls the bundled graph uses: the installed headers are
/// still compiled and the installed archives still linked against a real
/// sysroot rather than against a single-threaded default.
///
/// `-Dlinkage` reaches this mode twice, and the two reaches are not the same
/// question.  `linkage` is the delivery of the one artifact this mode still
/// compiles -- the bridge, from `zig/bridge.cc`, with the same soname rule and
/// `installed_linkage` is what `preferred_link_mode` asks for on the
/// *installed* libraries, which this mode does not build;
/// `linkSystemLibrary`'s own default is `.dynamic`
/// (`lib/std/Build/Module.zig:359`), so `build` passes `.dynamic` when the
/// caller named nothing. It reaches that closure through one
/// `linkSystemLibrary` call now, and it also decides whether this mode binds
/// the installed `libs2cpp`.
/// `linkage_option` is the raw option, forwarded to the nested consumer build
/// only when the caller named it, for the reason `addConsumerStep` gives.
fn addSystemMode(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wasi_sysroot: ?[]const u8,
    linkage: std.builtin.LinkMode,
    installed_linkage: std.builtin.LinkMode,
    linkage_option: ?std.builtin.LinkMode,
    runtime_option: ?bool,
) void {
    const runtime_loaded = runtime_option orelse false;
    rejectUnsupportedDynamicLinkage(target, linkage, "-fsys=s2");
    const provider = wasi_provider.Provider.init(b, target, wasi_sysroot);
    // The installed closure carries the C++ runtime on the ELF shared route,
    // the one route whose `s2geometry.pc` names `-ls2cpp`. Same predicate
    // `addBridge` applies to `cpp_lib == null`, asked of `installed_linkage`.
    const installed_shared_cpp = sharedCppOwner(target, installed_linkage);
    const bridge_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi and !installed_shared_cpp,
        // This mode still compiles the bridge from `zig/bridge.cc`, so
        // `-Dlinkage` reaches it the same way it reaches the bundled graph's
        // three artifacts.  Nothing else in this mode is compiled here.
        .pic = if (linkage == .dynamic) true else null,
    });
    if (installed_shared_cpp) cpp_runtime.configureHeaders(b, bridge_module, target);
    if (provider) |actual| actual.configureModule(bridge_module);
    bridge_module.addCSourceFile(.{
        .file = b.path("zig/bridge.cc"),
        .flags = platform_flags.s2Flags(target),
        .language = .cpp,
    });
    // One package rather than 27 `-l` stems: the installed `s2geometry.pc`
    // carries the closure in dependency order and the one `-I` that selects
    // the installed `s2/`+`absl/` families. `.force`, because the package name
    // and the library stem differ here and `.yes` would fall back to a
    // `-ls2geometry` no install ever produced. `installed_linkage` is still
    // `preferred_link_mode`, which now decides `-l` inside that `-L`.
    bridge_module.linkSystemLibrary(system_pkg_config_module, .{
        .use_pkg_config = .force,
        .preferred_link_mode = installed_linkage,
    });

    const bridge_lib = b.addLibrary(.{
        .name = "s2bridge",
        .linkage = linkage,
        // Fork-authored, and it takes `s2`'s number for the same reason the
        // bundled graph gives; `addBridge` documents it.
        .version = if (linkage == .dynamic) bridge_abi_version else null,
        .root_module = bridge_module,
    });
    if (linkage == .dynamic) addInstalledTreeRPath(bridge_module, target);
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
    // The same package on the translation, for the reason `addGraph` puts the
    // bundled roots on its own line: declarations and the libraries they bind
    // to come from one metadata answer. `bridge.h` names no upstream type at
    // this pin, so nothing resolves from that `-I` today.
    translate_c.linkSystemLibrary(system_pkg_config_module, .{
        .use_pkg_config = .force,
        .preferred_link_mode = installed_linkage,
    });
    const facade_module = b.addModule("s2geometry", .{
        .root_source_file = b.path("zig/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // The same single-owner rule as the bridge module above: this value is
        // what `addTests` and `addSmoke` copy (:1167, :1188) and what every
        // dependent's module graph reports (Compile.zig:1053-1058), so a second
        // C++ runtime set here reaches the test binary, the smoke binary and
        // the consumer alike.
        .link_libcpp = target.result.os.tag != .wasi and !installed_shared_cpp,
    });
    // Header half of the same answer, for the same reason `addBridge` pairs it
    // with the library: on this route the installed `libs2cpp` is the runtime
    // this build is compiled against, and its headers are its own.
    if (installed_shared_cpp) cpp_runtime.configureHeaders(b, facade_module, target);
    // The same seam `addGraph` applies, and for the same reasons: under
    // `-Druntime` the dispatch replaces the translated header and nothing is
    // linked, so the installed `libs2` is the provider a caller names with an
    // explicit `load(source)` rather than something the module links.
    // `graph.createModule` puts the two upstream include roots on the dispatch
    // and on its own `c_native` module; what stays with the caller is the WASI
    // provider's roots and threading model, and it reaches either shape of
    // `c` module alike.
    const c_module: *std.Build.Module = if (runtime_loaded)
        graph.createModule(b, translate_c, target, optimize)
    else
        translate_c.addModule("c");
    if (provider) |actual| actual.configureModule(c_module);
    facade_module.addImport("c", c_module);
    if (!runtime_loaded) {
        // The linked branch and only the linked branch: the facade's `rt`
        // import is where its two public types come from, and the library link
        // is what it would otherwise not have.  Under `-Druntime` the dispatch
        // already carries the one core instance and re-exports them, so
        // naming the core module again here would make two nominally distinct
        // sets of the same types in one build.
        facade_module.addImport("rt", graph.createCoreModule(b, target, optimize));
        facade_module.linkLibrary(bridge_lib);
    }
    if (provider) |actual| {
        actual.configureModule(facade_module);
        actual.linkRuntime(facade_module);
    }

    const smoke_exe = addSmoke(b, target, optimize, facade_module, provider);
    b.getInstallStep().dependOn(&smoke_exe.step);

    const run_smoke = b.addRunArtifact(smoke_exe);
    run_smoke.has_side_effects = true;
    if (b.args) |args| run_smoke.addArgs(args);
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
    addConsumerStep(b, target, optimize, true, linkage_option, runtime_option, wasi_sysroot);

    // The same configure-time report the bundled graph prints, for the two
    // facts this mode answers differently: the bridge it compiled, and the
    // installed libraries it bound to.  Both defaults are pre-existing
    // behaviour (`build` says which), and neither is inferred from a cache
    // directory here.
    if (linkage == .dynamic) {
        std.debug.print("s2geometry: -fsys=s2, bridge as {s}, bound to {s} installed libraries\n", .{
            deliveryName(b, target, "s2bridge", bridge_abi_version),
            @tagName(installed_linkage),
        });
    } else {
        std.debug.print(
            "s2geometry: -fsys=s2, bridge as a static archive, bound to {s} " ++
                "installed libraries\n",
            .{@tagName(installed_linkage)},
        );
    }
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
/// The two caches travel as well, and they are two different arrangements.  The
/// local one is `--cache-dir` with a `/consumer` subdirectory of this build's
/// own (`b.cache_root.path`), because two build graphs must not write one
/// manifest directory: a process holding a manifest holds a lock on it
/// (`lib/std/Build/Cache.zig:482-491`, `:1120-1122`).  The global one is
/// `--global-cache-dir` with `b.graph.global_cache_root.path` **unchanged** --
/// the shared, content-addressed store every graph on the machine writes into,
/// and the very value `Step.Compile` hands every compilation this build makes
/// (`lib/std/Build/Step/Compile.zig:1477-1480`).  A subdirectory there would
/// not be a stricter cache; it would be a second one, and a re-fetch of
/// everything this build already has.  Both options are two tokens
/// (`lib/compiler/build_runner.zig:1674-1675`), the spelling the compiler's
/// own build script emits and the one this workspace's gates are written in.
///
/// The install prefix travels as well, and only when the caller named one.
/// `b.install_prefix` is the `--prefix` this invocation resolved, and a nested
/// `zig build` given no `--prefix` resolves `<its own build root>/zig-out` --
/// for this step `consumer/zig-out`, a build artefact inside a source package
/// (`AGENTS.md:122-124`).  A relative value would resolve against the nested
/// build's working directory, `consumer/`, and not against this build's root,
/// so it is made absolute before it is handed on; a caller who named no prefix
/// is left to the default both graphs resolve alike.  `DESTDIR` needs no
/// forwarding, because the nested build inherits the environment this one ran
/// with.
///
/// `-j8` and `--summary all` travel with them (`AGENTS.md:157-158`,
/// `README.md:447-449`), and they cannot come from anywhere else.  A `Run`
/// step's command is fixed once it is assembled, and the outer build runner has
/// consumed the caller's own copies of both for itself
/// (`lib/compiler/build_runner.zig:422-427`, `:262-269`) and forwards to a step
/// only what followed a `--` (`:428-429`), which is the consumer program's
/// arguments rather than the nested build's options.  Left to derive its own
/// width, the nested build runs at `cpu_count - 1`
/// (`lib/std/Io/Threaded.zig:1634-1639`) -- a different number on every
/// machine, and never the eight this workspace asks for -- and it prints the
/// one-line summary no consumer receipt here is read against.
///
/// And last, verbatim and behind a `--`: whatever the caller wrote after
/// `zig build consumer --`.  Those are this build's `b.args`, and the nested
/// build's `run` step hands its own `b.args` to the program (the `run` step of
/// `consumer/build.zig`, `run_exe.addArgs(b.args)`).  An argument this step
/// dropped would be an argument the consumer accepted on the outer command
/// line and then never saw, which is the outer build reporting a narrower check
/// than the one it was asked for.  Everything above is this package's own
/// bookkeeping with the nested build; everything after the `--` is the
/// program's, which is why the `--` follows all of them.
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
    linkage: ?std.builtin.LinkMode,
    runtime_loaded: ?bool,
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
    // `-Dlinkage` travels when the caller named it, spelled `@tagName` for the
    // same reason as `-Doptimize`.  `zig build consumer -Dlinkage=dynamic` that
    // installed the static archives and then proved the consumer against the
    // shared ones would report two builds as one -- and
    // `consumer/build.zig` passes it on to `b.dependency`, so the artifacts the
    // nested build links are the ones this build installed.
    //
    // A caller who named nothing gets no argument, and that is exact rather
    // than convenient: both graphs derive the same pair of defaults from the
    // same absent option (their own artifacts static, `-l` bindings to
    // installed libraries dynamic), so an argument invented here would be a
    // second answer to a question the caller had not asked.
    //
    // The requested value travels, not a re-resolved one, so the nested graph
    // makes the same decision this one did about the same target.
    if (linkage) |requested| run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(requested)}));
    // `-Druntime` under exactly the same rule, and for the same reason: the
    // dispatch is a property of this configuration, so a nested build that
    // resolved it differently would be evidence about a module this one never
    // built.  `-Dlinkage` and `-Druntime` stay orthogonal there too -- a
    // runtime-loaded build still delivers and installs the three artifacts,
    // and `consumer/build.zig` passes both on to `b.dependency` unchanged.
    if (runtime_loaded) |loaded| {
        run.addArg(b.fmt("-Druntime={s}", .{if (loaded) "true" else "false"}));
    }
    // Two of the four options `standardTargetOptions` registers do not travel,
    // and that is a boundary rather than an omission: those four names are
    // `-Dtarget`, `-Dcpu`, `-Dofmt` and `-Ddynamic-linker` (`:428-431`, and
    // the same four `target_was_named` reads at `:450`), and only the first
    // two are added above.  A caller who names `-Dofmt=` or
    // `-Ddynamic-linker=` has both resolved here -- `build()` takes this
    // graph's target from `b.standardTargetOptions(.{})` (`:481`) -- and the
    // nested `zig build` is given neither, so it has nothing but the triple to
    // resolve them from and resolves them from that, through its own
    // `b.standardTargetOptions(.{})` (`consumer/build.zig:43`).
    //
    // Forwarding them would split the pair rather than close the gap: the
    // nested build hands its library half to `b.dependency` with `.target`
    // and no float-ABI or dynamic-linker field (`consumer/build.zig:86-95`),
    // so an option carried to the nested build alone would give its consumer
    // executable a float ABI and a dynamic linker that the library it links
    // against never received.  Same rule and same reason as
    // `box3d/build.zig:1473-1477`, which is where this was read out of first.
    // What travels is the caller's own query rather than this graph's
    // resolved result, so an explicitly named `-Dtarget` is not answered
    // against this machine's own CPU feature range
    // (`box3d/build.zig:1460-1465`).
    //
    // So the sentence at `:1508-1509` is exact about the two strings it
    // names and is not a claim about the other two options.  What the
    // sub-build parses is what this build resolved for the target and the
    // CPU; what it does not parse is an object format or a dynamic linker
    // named on the outer command line as options of their own.
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
    // The job width and the summary this workspace reads every gate with
    // (`AGENTS.md:157-158`, `README.md:447-449`), because this command is the
    // only place they can be written.  Nothing reaches it from the caller's own
    // invocation: the outer build runner consumes `-j8` and `--summary all`
    // for itself (`lib/compiler/build_runner.zig:422-427`, `:262-269`) and
    // forwards to a `Run` step only what came after a `--`
    // (`:428-429`) -- which is the consumer program's arguments, not the nested
    // build's options.  A nested build left to derive its own width runs at
    // `cpu_count - 1` (`lib/std/Io/Threaded.zig:1634-1639`), so the consumer
    // this step proves would compile at a different width on whichever machine
    // ran the gate, and never at the eight this workspace asks for.  One
    // argument, because `-j8` is the spelling the runner parses:
    // `mem.cutPrefix(u8, arg, "-j")` (`:422-425`).
    run.addArg("-j8");
    // `--summary all` is two arguments, not one `--summary=all`: the runner
    // reads the mode as the argument after the option (`:262-269`).  It is the
    // nested build's own step list, and it is what makes a `consumer` receipt
    // name the steps the consumer package actually ran instead of printing one
    // line that no gate here reads.
    run.addArgs(&.{ "--summary", "all" });
    // When the outer build was given an explicit cache directory, the nested
    // one gets a subdirectory of it rather than sharing it: two build graphs
    // must not write the same manifest directory.  A null `path` means "the
    // current directory", and the working directory above is already the
    // consumer package.
    if (b.cache_root.path) |cache| {
        run.addArgs(&.{ "--cache-dir", b.fmt("{s}/consumer", .{cache}) });
    }
    // The global cache this build resolved: the same read as the local cache
    // above, and the one this helper did not make.  `--global-cache-dir [path]`
    // is a two-token option (`lib/compiler/build_runner.zig:1675`), and it is how
    // the compiler's own build script spells it when a build spawns
    // compilations: `zig_args.append("--global-cache-dir")` then
    // `zig_args.append(b.graph.global_cache_root.path …)`
    // (`lib/std/Build/Step/Compile.zig:1477-1480`), with
    // `Step.TranslateC.zig:179-180` as the second in-tree emitter.
    //
    // Without it, a `--global-cache-dir` the caller chose is invisible to the
    // nested `zig build`, which resolves a global cache of its own at a place
    // this command line never names -- and every compilation that graph makes
    // is spawned with that one (`Compile.zig:1478-1479`), so what it builds for
    // the compiler runtime, and anything it fetches, lands there.  Two
    // workspace rules then stop holding for the nested build: the approved
    // scratch root (`AGENTS.md:157-158`, and §11 on mandatory storage) does not
    // hold its cache, and the `$HOME` and repository trees may not hold one at all
    // (`AGENTS.md:270-272`).  A caller who named no `--global-cache-dir` is not
    // made worse off by this: the same driver then resolves the same default
    // in both processes, which is what the guard below leaves in place.
    //
    // No `/consumer` subdirectory here, unlike the local cache above: the global
    // cache is the shared, content-addressed store every graph on the machine
    // writes into, and this very path is what `Step.Compile` hands every
    // compilation the outer build makes (`Compile.zig:1479`).  A private
    // subdirectory would not be a stricter cache, it would be a second one --
    // and a re-fetch of everything this build already has.
    //
    // The guard is the field's own shape, not a decision made here:
    // `std.Build.Cache.Directory.path` is `?[]const u8` and "null means cwd",
    // and it exists to be handed to a child process
    // (`lib/std/Build/Cache/Directory.zig:10-14`) -- which is this line's whole
    // job.  Under the pinned runner the branch is never taken: the build runner
    // reads both cache directories from mandatory positionals and is `fatal`
    // without them (`lib/compiler/build_runner.zig:53-54`), then builds both
    // `Cache.Directory` values with `.path` set unconditionally (`:68-76`) and
    // assigns this one onto the graph (`:89`).  So the value is always there,
    // and when it is not there is nothing honest to forward.  A `"."` fallback
    // would name a cache inside the consumer package, which
    // `AGENTS.md:122-124` keeps out of the package; the compiler's own
    // `orelse "."` (`lib/std/Build/Step/Compile.zig:1479`) can afford that
    // because its working directory is a build root, and this step's is a
    // source package.
    if (b.graph.global_cache_root.path) |global_cache| {
        run.addArgs(&.{ "--global-cache-dir", global_cache });
    }
    // The caller's install prefix, when the caller named one.  Left to its own
    // resolution the nested build installs into `consumer/zig-out` -- a build
    // artefact inside a source package, which `AGENTS.md:122-124` keeps out of
    // one -- rather than into the directory this invocation was told to use.  A
    // relative `--prefix` would resolve against the working directory set
    // above, `consumer/`, and not against this build's root, so it is made
    // absolute before it is handed on.  A caller who named none is left as it
    // is: the nested build then resolves the same `zig-out` this graph would.
    // `DESTDIR` needs no forwarding, because the nested build inherits the
    // environment this one ran with.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        run.addArg("--prefix");
        run.addArg(prefix);
    }
    // The caller's own arguments, last and behind `--`.  `zig build consumer --
    // …` collects them in `b.args`, the nested build's `run` step hands
    // `b.args` to the program (`consumer/build.zig`, the `run` step's
    // `run_exe.addArgs(b.args)`), and that program is the consumer check.
    // Every argument above is this package's own bookkeeping with the nested
    // build; an argument the caller typed is forwarded verbatim or not at all,
    // and this `--` has to follow all of them because it ends the nested
    // build's option parsing.
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

/// Whether this target's OS has a dynamic linker at all, and therefore whether
/// it can carry a shared object.
///
/// Windows uses its PE/COFF loader without an interpreter path.
/// Other shared targets need a dynamic linker. WASI has neither.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// Refuses a requested shared delivery this target cannot carry.
///
/// A `.so` on a target with no dynamic linker is a file nothing can load, so a
/// build that asked for `dynamic` and handed back a static archive would have
/// reported success for an artifact it was never asked to produce.  It is
/// refused instead, with the reason and the way out.
///
/// The default is `.static`, and the static delivery is fully supported on
/// every target in the matrix -- `wasm32-wasi` included -- which is why this is
/// reached at all only when a caller named `dynamic` for such a target.
/// Nothing about the sources, the header, the translation, the facade, the
/// tests or the example depends on which way this goes: they are the same
/// either way, and the default path never arrives here.
///
/// `where` names the configuration being built, so the failure says whether
/// the published graph or `-fsys=s2` asked for it.
fn rejectUnsupportedDynamicLinkage(
    target: std.Build.ResolvedTarget,
    linkage: std.builtin.LinkMode,
    where: []const u8,
) void {
    if (linkage != .dynamic or targetHasDynamicLinker(target)) return;
    // `@panic`, not a failing step: `b.addFail` only fails when its step runs,
    // and `zig build test -Dtarget=wasm32-wasi -Dlinkage=dynamic` never runs
    // the install step.  A refusal that some entry point could step around
    // would not be one.  This is the same idiom this file already uses for a
    // configuration it refuses to proceed with (the manifest version, above).
    std.debug.panic("s2geometry: {s} cannot deliver shared objects for {s}; no static substitution. Use -Dlinkage=static.", .{
        where, @tagName(target.result.os.tag),
    });
}

/// Keep installed dependencies ahead of the separate build-cache directories.
fn linkNativeDependency(
    module: *std.Build.Module,
    dependency: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    cache_paths: bool,
) void {
    if (dependency.linkage == .dynamic and target.result.os.tag != .windows) {
        // addObjectFile accepts the emitted shared library without adding the
        // cache-first RPATH that linkLibrary would insert automatically.
        module.addObjectFile(dependency.getEmittedBin());
        addInstalledTreeRPath(module, target);
        if (cache_paths) module.addRPath(dependency.getEmittedBin().dirname());
    } else {
        module.linkLibrary(dependency);
    }
}

/// The installed tree's own runtime search path, for a shared library.
///
/// `$ORIGIN` on ELF and `@loader_path` on Darwin, which is Abseil's own
/// published `INSTALL_RPATH` for shared builds
/// (`vendor/abseil-cpp/CMake/AbseilHelpers.cmake:259-267`) together with
/// s2geometry's `set(CMAKE_MACOSX_RPATH TRUE)` (`CMakeLists.txt:20-22`).  All
/// three libraries install into `lib/`, so `libs2bridge.so.0` finds
/// `libs2.so.0` beside it and `libs2.so.0` finds `libabsl.so.2508`.
///
/// Shared dependencies add this before their build-cache search directory.
/// Installed libraries therefore resolve their closure beside themselves;
/// cache-only build artifacts can still find their separately emitted peers.
///
/// Windows has no runtime search path in this sense -- the loader records a
/// dependency by name in the same directory as the DLL that names it -- and
/// `Module.addRPathSpecial` emits a bare `-rpath`
/// (`lib/std/Build/Module.zig:626-635`) with no target test, so adding one
/// there would hand LLD a switch it does not take.  Nothing is added.
fn addInstalledTreeRPath(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .windows => {},
        else => module.addRPathSpecial(if (target.result.os.tag.isDarwin())
            "@loader_path"
        else
            "$ORIGIN"),
    }
}

/// The file name a shared library of this name and version carries on
/// `target`, spelled the way `Compile` spells it.
///
/// `lib/std/Build/Step/Compile.zig:488-515` builds the versioned name from the
/// library prefix, the artifact name, the target's shared-library suffix and
/// the version's major component; the message says so on the configure line
/// rather than leaving a reader to infer it from a cache directory.
fn deliveryName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    version: std.SemanticVersion,
) []const u8 {
    if (target.result.os.tag == .windows) {
        // Windows has no soname: the DLL is `s2bridge.dll` and the import
        // library beside it is `s2bridge.lib` (`Compile.zig:499-501`, and
        // `InstallArtifact.create` puts the DLL under `bin/` and the import
        // library under `lib/`).
        return b.fmt("{s}.dll (+ {s}.lib)", .{ name, name });
    }
    if (target.result.os.tag.isDarwin()) {
        return b.fmt("{s}{s}.{d}.dylib", .{ target.result.libPrefix(), name, version.major });
    }
    return b.fmt("{s}{s}.so.{d}", .{ target.result.libPrefix(), name, version.major });
}

/// The carried licence and provenance material `zig build` installs under
/// `share/licenses/s2geometry/`.
///
/// Two upstreams and two kinds of record.  s2geometry is Apache-2.0
/// (`LICENSE`) with a BSD-3-Clause notice for the three compiled `s2/util/gtl`
/// headers (`NOTICE`), and Abseil is Apache-2.0 as well
/// (`vendor/abseil-cpp/LICENSE`) with its own `AUTHORS`.  The MIT terms of the
/// pinned Zig compiler travel too, because `build_support/wasi_stdlib.patch`
/// edits two files of its standard library and a private repository removes no
/// obligation.  The rest are this fork's own records: what it did to upstream
/// (`UPSTREAM.md`, `UPSTREAM.sha256`), under what grant (`FORK-LICENSE.md`,
/// `NOTICE.md`), and what it changed (`CHANGELOG.md`, `FORK-NOTES.md`).
///
/// The upstream texts keep upstream's own names and Abseil's keep a `.abseil`
/// suffix, so nothing here can be mistaken for the other upstream's.  These
/// are the same paths and the same basenames `package.nix` copies, which is
/// what lets its `install -Dm644` guards be an idempotent skip of these bytes
/// rather than a second copy.
const licence_records = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "LICENSE", .to = "LICENSE" },
    .{ .from = "NOTICE", .to = "NOTICE" },
    .{ .from = "AUTHORS", .to = "AUTHORS" },
    .{ .from = "CONTRIBUTORS", .to = "CONTRIBUTORS" },
    .{ .from = "vendor/abseil-cpp/LICENSE", .to = "LICENSE.abseil" },
    .{ .from = "vendor/abseil-cpp/AUTHORS", .to = "AUTHORS.abseil" },
    .{ .from = "build_support/zig-0.16-LICENSE.txt", .to = "LICENSE.zig-0.16.0.txt" },
    .{ .from = "NOTICE.md", .to = "NOTICE.md" },
    .{ .from = "FORK-LICENSE.md", .to = "FORK-LICENSE.md" },
    .{ .from = "UPSTREAM.md", .to = "UPSTREAM.md" },
    .{ .from = "UPSTREAM.sha256", .to = "UPSTREAM.sha256" },
    .{ .from = "CHANGELOG.md", .to = "CHANGELOG.md" },
    .{ .from = "FORK-NOTES.md", .to = "FORK-NOTES.md" },
};

/// Writes `lib/pkgconfig/s2geometry.pc` and installs it.
///
/// Upstream ships no `.pc` template -- `Config.cmake.in` is a CMake package
/// config (`CMakeLists.txt:719-745`), not link metadata -- so this file is
/// fork-authored, and two of its fields are decisions rather than copies:
///
///   * `prefix` is `${pcfiledir}/../..`, not a substituted absolute prefix.
///     This graph does not know where `--prefix` will point when it writes the
///     file, and pkg-config resolves `${pcfiledir}` against the `.pc` it found,
///     so the installed file is correct wherever the prefix landed -- including
///     a Nix store path that is only known at build time.
///   * `Libs.private` names the two platform providers the compiled closure
///     itself needs: Abseil's MinGW dependency
///     (`absl/debugging/symbolize_win32.inc` -> `-ldbghelp`) and CCTZ's Apple
///     default-timezone lookup (`time_zone_lookup.cc` -> `CoreFoundation`).
///     They are `PRIVATE` because a consumer of the shared libraries does not
///     re-link them -- the shared object records them itself -- and they are
///     absent from `Libs` for the same reason.
///
/// `Libs` lists the native libraries in dependency order. ELF shared delivery
/// also names `s2cpp`, the matching libc++/libc++abi/libunwind runtime. Static
/// delivery uses the consumer's normal C++ runtime and installs no `s2cpp`.
fn addPkgConfig(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    linkage: std.builtin.LinkMode,
) void {
    // Keyed to the *target*, not to the host: the file describes the
    // libraries this build produced for the platform they were produced for,
    // and a cross `--prefix` tree consumed on the build machine is not the
    // only consumer there is.
    const platform_private =
        if (platform_flags.isWindows(target))
            "-ldbghelp"
        else if (target.result.os.tag.isDarwin())
            "-framework CoreFoundation"
        else
            "";
    const shared_cpp = if (sharedCppOwner(target, linkage)) " -ls2cpp" else "";
    const install = b.addInstallFileWithDir(
        b.addWriteFiles().add("s2geometry.pc", b.fmt(
            \\# Written by build.zig.  Upstream ships no pkg-config template:
            \\# `Config.cmake.in` is a CMake package config, not link
            \\# metadata, so this file is fork-authored.  `prefix` is
            \\# relative to this file's own directory on purpose, so the
            \\# installed file is correct wherever `--prefix` pointed.
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: s2geometry
            \\Description: S2 Geometry Library (google/s2geometry v{d}.{d}.{d}) with vendored Abseil C++ LTS {s} and this fork's C bridge -- {s} libraries
            \\URL: https://github.com/google/s2geometry
            \\Version: {f}
            \\
            \\Requires:
            \\Libs: -L"${{libdir}}" -ls2bridge -ls2 -labsl{s}
            \\Cflags: -I"${{includedir}}"
            \\Libs.private: {s}
            \\
        , .{
            package_version.major,
            package_version.minor,
            package_version.patch,
            absl_version,
            @tagName(linkage),
            package_version,
            shared_cpp,
            platform_private,
        })),
        .lib,
        "pkgconfig/s2geometry.pc",
    );
    b.getInstallStep().dependOn(&install.step);
}

/// Installs every carried licence text and provenance record under
/// `share/licenses/s2geometry/`.
///
/// `libunibreak`'s `build.zig:588-590`, `erfa`'s `build.zig:814-815` and
/// blake3's `install_licence_records` install the same way, so this is the
/// workspace's convention rather than one invented here.
///
/// This is the unconditional set: it installs on every bundled route.  The
/// three texts that cover the ELF shared route's `libs2cpp` are deliberately
/// not in it.  They are installed by `cpp_runtime.installLicences`, beside the
/// artifact, under the same `sharedCppOwner` predicate that builds that
/// artifact -- they are the LLVM project's grant over components this package
/// compiles only on that one route, and nothing else installed here is covered
/// by them.
fn installLicenceRecords(b: *std.Build) void {
    for (licence_records) |record| {
        const install = b.addInstallFileWithDir(
            b.path(record.from),
            .prefix,
            b.fmt("share/licenses/s2geometry/{s}", .{record.to}),
        );
        b.getInstallStep().dependOn(&install.step);
    }
}

comptime {
    // One release, named in four places: the manifest, the source lists, the
    // installed `s2geometry.pc` and the shared object's file name.  A
    // manifest edited without the sources it describes fails to configure
    // here rather than producing a package that describes two releases.
    std.debug.assert(std.mem.eql(u8, manifest.version, s2_version));
    std.debug.assert(package_version.order(s2_abi_version) == .eq);
    std.debug.assert(package_version.order(bridge_abi_version) == .eq);
    // The Abseil soname carries Abseil's own `ABSL_SOVERSION` encoding of the
    // LTS 2025-08 release (`vendor/abseil-cpp/CMakeLists.txt:27`), which is a
    // different number from either upstream's calendar version, so it is not
    // compared against `absl_version`.  What must hold is that it is not the
    // default-constructed zero a forgotten constant would leave behind.
    std.debug.assert(absl_abi_version.major == 2508);
}
