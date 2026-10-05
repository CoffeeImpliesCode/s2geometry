# s2geometry — the real S2 library, built and packaged as a foundation SDK

This package compiles **google/s2geometry's own C++**. Upstream is tag
`v0.14.0` at commit `c24b368c67d0b8a2a109c5a75224e73a856bd8b7`, carried in
`src/`, with Abseil C++ LTS `20250814.1` at
`d38452e1ee03523a208362186fd42248ff2609f6` carried whole at
`vendor/abseil-cpp`. There is no S2 algorithm in this tree: no Hilbert curve,
no cell-id bit layout, no token codec, no covering strategy. Every answer it
returns was computed by those compiled sources and reached through the C bridge
in `zig/bridge.h`.

Three **native** libraries come out of one build graph, and nothing is
downloaded, no system copy is used, and no upstream build script is executed:

| Artifact (ELF targets) | Artifact (`x86_64-windows-gnu`) | Contents | Links |
|---|---|---|---|
| `libabsl.a` | `absl.lib` | the vendored Abseil closure, unit for unit as `build_support/absl_sources.zig` enumerates it | — |
| `libs2.a` | `s2.lib` | upstream's own `add_library(s2 …)` block, in upstream's order, as `build_support/s2_sources.zig` enumerates it | `libabsl` |
| `libs2bridge.a` | `s2bridge.lib` | this fork's C bridge — every entry point `zig/bridge.h` declares | `libs2` |

`-Dlinkage=dynamic` delivers those three as shared objects carrying upstream's
own sonames (`libabsl.so.2508`, `libs2.so.0`, `libs2bridge.so.0`); `static` is
the default, and both `package.nix`'s default and `flake.nix`'s `.default`
preserve it.

**On an ELF target with `-Dlinkage=dynamic` there is a fourth artifact, and it
is not one of this fork's own libraries.** It is the build compiler's own
shipped C++ runtime — libc++, libc++abi and libunwind, compiled from the pinned
Zig 0.16.0 source tree — published as `libs2cpp.so.0.16.0` with soname
`libs2cpp.so.0`, installed beside the three, named in `Libs` by the installed
`pkg-config` file, and shipped with the three upstream licence texts that cover
it. Its file version is the **compiler's** 0.16.0, not this package's 0.14.0,
so a consumer that pins by name should read the soname there exactly as it does
for the other three. Every other route keeps its ordinary C++ provider rules and
installs no `libs2cpp`: `static`, `wasm32-wasi`, Darwin and Windows included. §2
says why that one route needs it, and §4 what a consumer of it must do.

Installed public headers: `include/s2/**.h` (the whole `src/s2` header tree,
not upstream's hand-maintained subset), `include/absl/**.h` **and** `**.inc`
from `vendor/abseil-cpp/absl`, and `include/s2geometry_bridge.h`.

**Zig interface documentation is separate: [`README.zig.md`](README.zig.md)** —
the typed facade's types and methods, the raw escape hatch, the bridge,
allocator and configuration ABI boundaries, the linked and the runtime-loaded
route, the build modes and the test approach. This file is the fork README:
what deviates from upstream, what the current status is, and how to consume the
package.

---

## 1. Current native-source deviations

**Not none.** Exactly **eight** upstream files are modified — one under
`src/`, seven under `vendor/abseil-cpp/` — each a bounded portability
correction, each keeping its Apache-2.0 header byte for byte and carrying a
prominent change notice inside its first twenty-two lines. Per-file pristine and
current digests are in `UPSTREAM.sha256`; the whole-tree comparison against the
canonical upstream archives is in `UPSTREAM.md`.

### The one S2 file

| Path | Change |
|---|---|
| `src/s2/util/math/exactfloat/bignum.cc` | `std::from_chars` receives the string view's character pointers (`s.data()`, `s.data() + s.size()`) rather than `s.cbegin()`/`s.cend()` iterators, whose conversion is implementation-specific. No change to the digit algorithm, chunking, sign handling or rounding. |

### The seven Abseil files

| Path below `vendor/abseil-cpp/` | Change |
|---|---|
| `absl/base/internal/direct_mmap.h` | Linux Hexagon uses the real `mmap2` syscall with fixed 4096-byte offset units, not byte offsets or `AT_PAGESZ` units. |
| `absl/base/internal/low_level_alloc.cc` | On WASI, arena backing regions come from the SDK libc's real `posix_memalign` instead of `mmap`, which is unavailable; each region keeps its base pointer, so distinct regions are never coalesced and a split block keeps its owner. |
| `absl/base/internal/low_level_alloc.h` | WASI is exempted from `ABSL_LOW_LEVEL_ALLOC_MISSING`, and the comment above that guard now says where backing memory actually comes from. |
| `absl/debugging/internal/stacktrace_powerpc-inl.inc` | PowerPC32 musl reads the embedded `gregs`; the glibc and PowerPC64 branches remain intact. |
| `absl/debugging/internal/examine_stack.cc` | Reads the real hosted Hexagon program counter and the PowerPC32 musl register context. |
| `absl/log/internal/conditions.h` | Hosted Linux Hexagon includes `unistd.h`'s existing `_exit` declaration; the freestanding/Windows branch remains. |
| `absl/time/internal/cctz/src/time_zone_format.cc` | NetBSD joins FreeBSD and OpenBSD in keeping its native locale namespace, instead of having `_XOPEN_SOURCE 500` selected for SUSv2 before libc++. |

**The two notice wordings are deliberate and are not restyled onto each other.**
Six Abseil files say `Foundation fork change (2026-10-02): …`; the CCTZ NetBSD
guard and the S2 pointer-iterator fix say `foundation-libs portability
change: …`. Both are prominent Apache-2.0 §4(b) notices, and the canonical
comparison models the variant per path.

### Also not a modification

* `.github/workflows/build.yml` — upstream's inherited GitHub Actions workflow
  is **deleted**, not modified: it configures CMake with a build-time Abseil
  download, runs Bazel against the Bazel Central Registry, and on a release tag
  publishes Python wheels to PyPI through another maintainer's credentials.
* No algorithm, ABI, fixture, oracle row or numerical tolerance was removed,
  substituted or widened to reach any of the above. Nothing upstream compiles
  for its own libraries is dropped: the compiled closure is every `absl_cc_library`
  source the vendored tree names, in either its `SRCS` or its `HDRS` list, plus
  upstream's whole `add_library(s2 …)` block.

---

## 2. Current native-build deviations, and the dated history

Upstream's `CMakeLists.txt` and Bazel definitions are carried unchanged for
provenance. The build that actually runs is this fork's Zig 0.16 graph in
`build.zig`, and it differs from upstream's build in these ways.

### Source selection

* The S2 units are the `add_library(s2 …)` block of `CMakeLists.txt:141-249` in
  upstream's order and spelling, written out in `build_support/s2_sources.zig`.
* The Abseil list is transcribed from **`SRCS` and `HDRS` alike**, because
  upstream's own `absl_cc_library` compiles both together
  (`vendor/abseil-cpp/CMake/AbseilHelpers.cmake:234`, `:260`:
  `target_sources(${_NAME} PRIVATE ${ABSL_CC_LIB_SRCS} ${ABSL_CC_LIB_HDRS})`).
  A `.cc` file that upstream lists under `HDRS` is therefore a translation unit,
  not a header. `absl/strings/internal/escaping.cc` is exactly that case —
  `vendor/abseil-cpp/absl/strings/CMakeLists.txt:126` lists it under the
  `strings_internal` target's `HDRS` while `:131-133` lists only two `.cc` files
  under `SRCS` — and it was the one unit this fork's list omitted. It is now
  compiled, **unchanged**: the closure correction is one more path in
  `build_support/absl_sources.zig` and not one changed byte anywhere.
* The Abseil units are every `absl_cc_library` source entry in the vendored
  tree, from `SRCS` or `HDRS`, except the fourteen that are `TESTONLY` or carry
  their own `GTest::` dependency. No test framework is compiled, downloaded or
  demanded.
* **The enumerated list is the authority, and no count guards it.** An earlier
  revision asserted the list lengths at comptime, and that assertion is what
  first exposed the missing `internal/escaping.cc`: adding the unit the upstream
  list actually names made the pin fail
  (`local://foundation-contract-s2geometry-shared-full-Abseil-HDRS-source-closure-origin-first-install.log`,
  `error: reached unreachable code` at the old
  `std.debug.assert(absl_sources.sources.len == 153)`). A number that must be
  edited every time a real source is added is a second place for the closure to
  be wrong, so the pin is gone and the transcribed list stands on its own.
* No `FETCH_ABSEIL`: the release upstream's own CMake fetches is vendored
  whole, not cut to headers and not cut to the units this build happens to need.

### Linkage and artifacts

* `-Dlinkage=static|dynamic` is the one option that moves the delivery.
  `static` is the default and is this SDK's linkage policy; `package.nix`'s
  default and `flake.nix`'s `default` both preserve it.
* `dynamic` delivers the same three libraries as real shared objects, and it
  changes no source, flag or header to do it: the same source lists, the same
  flags, the same header trees.
  What it adds is position-independent code on the module that owns each
  library's own sources, upstream's own sonames
  (`CMakeLists.txt:294-296` for S2, `vendor/abseil-cpp/CMakeLists.txt:27`
  `ABSL_SOVERSION` for Abseil, and `s2`'s number for the fork's bridge, which
  upstream has no version for), and an installed tree that can resolve its own
  closure. `build.zig` "Static and shared delivery" is the full statement.
* **Two native graphs on the shared route, and only one of them is installed.**
  Every shared object records its dependency's soname in `DT_NEEDED`. The copy
  that is installed is linked with **no build-cache search path at all**:
  `$ORIGIN` on ELF and `@loader_path` on Darwin — Abseil's published
  `INSTALL_RPATH` (`vendor/abseil-cpp/CMake/AbseilHelpers.cmake:259-267`)
  together with s2geometry's `set(CMAKE_MACOSX_RPATH TRUE)`
  (`CMakeLists.txt:20-22`) — and nothing after it. A relocated prefix
  therefore resolves its whole closure beside itself and can never name a
  directory that exists only on the machine that built it. The facade, the
  smoke program and the tests link a **second, cache-aware** copy of the same
  sources, whose runtime search path is `$ORIGIN` first and the build-cache
  directory second, so an in-tree binary still finds its separately emitted
  peer before anything is installed (`addNativeGraph`, `build.zig:835-849`,
  called with `cache_paths = false` for the install tree at `:548-549` and
  `true` for the published one at `:544` and `:711`). That is also why the dynamic receipts
  below carry more steps than the static ones: the three libraries are compiled
  a second time for the install tree, and `static` compiles one graph and
  installs that same one. Windows adds no runtime search path of any kind,
  because the loader finds a dependency by name beside the DLL that names it.
* **One visible C++ runtime on the ELF shared closure, taken from the
  compiler's own shipped sources.** There, the graph compiles the pinned
  compiler's complete threaded C++ runtime into `libs2cpp.so.0` and compiles
  the Abseil, S2 and bridge modules against **that** ABI
  (`_LIBCPP_ABI_VERSION=1`, `_LIBCPP_ABI_NAMESPACE=__1`) instead of letting
  each of them embed a private copy of the compiler's ordinary *static* C++
  runtime. Zig's ordinary static archive is built with hidden exports, and a
  hidden-exports archive reused across images cannot preserve `std::locale`
  facet identity: each image got its own facet registry, and S2's log stream
  crossing an image boundary then died in `std::use_facet`. `libs2cpp` is
  therefore built with upstream's own shared-library visibility annotations
  (`_LIBCPP_BUILDING_LIBRARY`, so `_LIBCPP_EXPORTED_FROM_ABI` resolves to
  `visibility("default")` beside `-fvisibility=hidden`, and without
  `_LIBUNWIND_HIDE_SYMBOLS`), which is what makes it a shared object with a
  real export surface instead of a relinked archive. The facade and every
  executable reach that one object by name, so no image in this package
  carries a second private static C++ runtime on that route.
  `build_support/cpp_runtime.zig` is the whole of it, and **no native source
  is edited**: the sources are the compiler's, read from the same
  `zig_lib_directory` the compiler itself compiles them from, and the runtime's
  three licence texts are installed verbatim from beside them.
* A target whose operating system has no dynamic linker **refuses**
  `-Dlinkage=dynamic` by name (`rejectUnsupportedDynamicLinkage`) rather than
  delivering a static archive under the option that was not asked for. `static`
  stays supported there, `wasm32-wasi` included.

### Compiler flags, each with its upstream source

`-std=c++17`, `-DABSL_MIN_LOG_LEVEL=1` and `-DNOMINMAX` come from upstream's own
definitions (`CMakeLists.txt:29-32`, `:62`, `absl/copts/copts.py`);
`-fsized-deallocation` from `CMakeLists.txt:122-127`, and it is still required
with Zig's clang; `-fno-fast-math` and `-ffp-contract=off` from
`src/s2/_fp_contract_off.h`, which says S2 requires deterministic arithmetic for
correctness. `-D_USE_MATH_DEFINES` is the one flag this fork adds beyond the
condition upstream states it under: upstream pairs it with `if (MSVC)`, and the
same `<math.h>` guard applies to Zig's bundled Windows headers, which the S2
library needs for `M_PI` in five translation units.

**What is deliberately not answered with a flag.** The upstream headers are
noisy under this frontend — `-Wnullability-completeness` and the `alignof(expr)`
GNU-extension pair — and no `-Wno-…`, `-w` or `-pedantic-errors` is added: each
would silence the same diagnostics in this fork's own `zig/bridge.cc`. Instead
the two upstream header trees are **system includes on the bridge translation
unit only**, which is upstream's own published arrangement
(`CMakeLists.txt:46-49`, applied to the `s2` target's PUBLIC include directory
at `:285-291`). The Abseil and S2 libraries keep ordinary includes, so every
upstream translation unit is still diagnosed in full.

### Platform providers the build declares

| Target condition | What the graph does | Where it comes from |
|---|---|---|
| Windows | links real `dbghelp` | Abseil's MinGW dependency; the calls are in `absl/debugging/symbolize_win32.inc` |
| Darwin | links the real `CoreFoundation` framework | CCTZ's Apple default-timezone path, `time_zone_lookup.cc` |
| OpenBSD/NetBSD PowerPC | selects `ABSL_USE_UNSCALED_CYCLECLOCK=0` on all three C++ modules | OpenBSD and NetBSD expose no supported timebase-frequency query here |
| `wasm32-wasi` | `_WASI_EMULATED_SIGNAL`, `-fwasm-exceptions`, libc++ from an installed SDK, `single_threaded = false` on every module | the SDK 34 `wasip1-threads` provider, named with `-Dwasi-sysroot=` |

Threads are not named as a system library: every required target gets its thread
implementation from the C library the build already links (`libc` supplies
`pthread_*`, `winpthreads` on `windows-gnu`), and adding `-lpthread` would be a
second answer to a question the C library has already answered.

### The bridge owns the installed upstream header root

`libs2bridge` declares both upstream header installations, and reaches
`include/s2` and `include/absl` through its emitted tree. It is declared there
rather than on `libs2`/`libabsl` because a linked library puts its *installed*
header tree on the linking module's include path as an ordinary `-I`, and clang
resolves `#include "…"` against `-I` ahead of `-isystem` whatever the order — the
recorded runs show both halves of that directly.

### Build options

| Option | What it selects |
|---|---|
| `-Dtarget=<triple>` | one target; `check` then compiles that target instead of the six |
| `-Dlinkage=static` / `-Dlinkage=dynamic` | which artifact each of the three libraries is, and — on an ELF target with `dynamic` — whether the fourth, runtime-only artifact is built at all; the default is this SDK's static policy, and a target with no dynamic linker refuses `dynamic` by name |
| `-Druntime=true` | how the **facade** reaches the library, not what is delivered: under it the module links no archive and every entry point goes through one process-lifetime table that an explicit `load(source)` fills. Independent of `-Dlinkage`, so all four combinations exist and a caller may equally name a provider this tree did not build |
| `-Dwasi-sysroot=<path>` | the installed WASI SDK 34 sysroot for `wasm32-wasi`; without it the graph fails naming the missing provider and says that no core sources are omitted |
| `-fsys=s2` / `-fno-sys=s2` | link an installed `libs2` and its Abseil instead of compiling this tree. **Unexercised**: no installed `libs2` or Abseil was observed on any machine here, so this mode has no result — a statement about what is installed, not about the package |
| `--zig-lib-dir <dir>` | the compiler's own standard option, selecting the patched standard-library copy |

### Packaging

`package.nix` is the one source-only derivation; both entry points call it with
`zig` injected. `flake.nix` publishes `packages.<system>.static` and `.shared`,
with `.default` preserving the static policy; `devenv.nix` publishes the same
derivation as **lazy** `outputs.static` and `outputs.shared`, so entering the
shell never builds the SDK (`devenv build outputs.static` does). The shell
itself carries tools only. `flake.lock` and `devenv.lock` are the driver's to
create and pin; no hash is invented in this repository.

### Dated history

The full numbered account, with each change dated, is `CHANGELOG.md`: §1 the
deleted upstream workflow, §2–§3 the Zig package and the vendored Abseil, §4
the `20250814.1` pin, §7 the whole `src/s2` header tree, §8 the bridge's system
includes, §10–§11 the flag decisions and the Abseil floating-point contract,
§23 the independent fixture oracles, §25 `-fsys=s2`, §37/§39/§41 the bridge
defects and the boundary guards, §43 the per-file licence inventory, §44 the
unconditional test run and the `cross-test` profile, §45 the bounded Abseil
portability corrections, §48 the WASI SDK 34 provider, §49 the standard-library
patch, §50 the S2 `from_chars` repair, §51–§53 the WASI `LowLevelAlloc`
backend, the NetBSD cctz guard and the CoreFoundation/signal declarations, §61
the Zig API contract alignment (2026-10-03), §62–§65 the contract migration of
2026-10-04 — this README and the preserved upstream copy, the licence grant for
the fork's own files, and the Nix packaging — **§66 the closure and delivery
corrections of 2026-10-04**: the one Abseil translation unit this fork's list
had omitted, the removal of the source-count pin, and the installed-tree-first
runtime search path, whose build-cache half §67 supersedes — and **§67 the ELF
shared-runtime repair of 2026-10-04**: the compiler-shipped C++ runtime as a
fourth artifact, the pure installed graph beside the cache-aware one, and the
records that had to move with them.
`FORK-NOTES.md` holds the decisions and what each cost, the lessons (`L1`–`L39`)
and the recorded boundaries and owner decisions.

---

## 3. Build, run and test matrix

**Sixteen gates are current observations over this tree; every other row below
is pending.** They are the whole native matrix of `-Dlinkage` (two values) ×
`-Druntime` (two values) × four optimisation modes, each run as
`zig build test smoke install -j8` by the driver and quoted with its own
timestamped receipt. No other row is a current result: it carries a landed
change and no gate behind it yet. A row that quotes a receipt describes the
revision named in that receipt and is **history**, not this tree.

### Commands

| Command | What it does |
|---|---|
| `zig build` | installs the three libraries, their header trees and `s2geometry_bridge.h`, and — on an ELF shared build — `libs2cpp.so.0` with its three licence texts; it **compiles** the smoke program without running it |
| `zig build test` | runs the 46 behavioural tests for the selected target; the run step is exposed for every target and the build runner decides what a foreign binary can do |
| `zig build smoke` | runs `smoke.zig` and prints its output |
| `zig build check` | compiles the C++ library, the bridge, the translated header, the facade, `tests.zig` and `smoke.zig` for the six required targets, and **runs nothing** |
| `zig build consumer` | builds the standalone `consumer/` package by path, and runs it when this build resolved an executor for the selected target. `addConsumerStep` hands the nested build the target triple and CPU taken from the resolved query, `-Doptimize`, `-Dlinkage` and `-Druntime` when you named them, `-fsys=s2`/`-fno-sys=s2`, `-Dwasi-sysroot`, `--zig-lib-dir`, the executor switches, `--libc-runtimes`, `-j8`, `--summary all`, both cache directories, your `--prefix` when you named one, and then your own arguments verbatim behind a `--` |
| `cross-test` | drives the published 53-platform matrix through `cross-test.profile.sh` |

Inside the devenv shell the same commands are available as namespaced tasks, run
with `devenv tasks run sdk:<name>` for `sdk:build`, `sdk:test`,
`sdk:test-release-safe`, `sdk:smoke`, `sdk:check`, `sdk:consumer`, `sdk:fmt` and
`sdk:integrity`. Each one runs in **this repository's** directory rather than in
the caller's, because `devenv tasks run` and `devenv shell -- <name>` inherit
the working directory the command was typed in, and that directory holds
devenv's own state rather than this package. Only `sdk:build` runs the install
step, and it installs under the storage **you** exported — `$ZIG_LOCAL_CACHE_DIR`,
or `$TMPDIR` when that is what you exported — instead of into `zig-out/`; a shell
that exported neither is told which two variables were missing and the task
stops, rather than being handed a location this repository picked. No canonical
task writes a delivered artifact into this repository, onto the volume it lives
on, or into a system temporary filesystem. Caller flags travel last, so a named
`--prefix`, `-Doption` or `-j` is the one that takes effect. `sdk:consumer`
installs nothing in *this* graph, and its nested `consumer/` build follows the
prefix you passed: name one and the consumer's own artifacts land there, name
none and they land in `consumer/zig-out`, inside this repository. That last
case is build output, and no canonical task installs it deliberately.

### Current status

| Gate | State | What still has to run |
|---|---|---|
| Native **shared** closure, `zig build test smoke install -Druntime=false -Dlinkage=dynamic`, Debug / ReleaseSafe / ReleaseFast / ReleaseSmall | **OBSERVED** | four cells, all `exit 0`, each printing "Build Summary: 39/39 steps succeeded; 46/46 tests passed", `smoke success` with every published answer, and `install success` for `libabsl.so.2508`, `libs2.so.0`, `libs2bridge.so.0` **and** `libs2cpp.so.0.16.0`, together with the three compiler licence texts and `s2geometry.pc`. The dynamic tree shows the second native graph directly: `install absl` compiles its own copy rather than reusing the one the tests linked |
| Native **static** closure, the same command with `-Dlinkage=static`, four modes | **OBSERVED** | four cells, all `exit 0`, "Build Summary: 32/32 steps succeeded; 46/46 tests passed", `smoke success`, `install success` for the three archives, and **no `s2cpp` step anywhere in the tree** — the runtime artifact belongs to the ELF shared route alone, and one graph is compiled and installed |
| Runtime-loaded, `-Druntime=true`, both deliveries × four modes, against this package's own installed shared provider | **OBSERVED** | eight cells, all `exit 0`. `S2GEOMETRY_TEST_PROVIDER` named the installed `…/s2geometry-shared/lib/libs2bridge.so` on the command line, so each load crossed an image boundary, and that provider's own `lib/` carries `libs2cpp.so.0` beside it; "36/36 steps succeeded; 46/46 tests passed" for the dynamic delivery, "33/33" for the static one, `smoke success` in both, each printing `loaded provider: …/libs2bridge.so`. Which file the loader picked for the runtime is not printed by any of them |
| Standalone `consumer/` package over the current source, as a dependency isolation gate | **OBSERVED** | the standalone package was built and **run** over this tree in eight cases — `-Dlinkage` static and dynamic × `-Druntime` false and true × default and explicit target — each `exit 0` with the program printing its published answers, and a ninth refusal case that exited 1 with `error: NoProviderConfigured` because it was given no provider. That is the first gate anywhere in this workspace to exercise the `-Dlinkage`/`-Druntime` forwarding, which the row is about. The `devenv:consumer` task also passed over this tree (`sdk:consumer`, `exit 0`). Earlier 10/10, `local://…-live-consumer-423.log`, is the previous revision |
| Windows cells, `zig build check -Dtarget=x86_64-windows-gnu` and the Windows rows of the matrix | **PENDING** | the four pre-migration `check` receipts cover `x86_64-windows-gnu` at the **previous** revision only; the shared delivery adds nothing Windows-specific to the search path by design, and no cell has run since |
| `zig build consumer` (native, path dependency) | **OBSERVED** | the eight cases above, on both linkages and both dispatch modes, plus the refusal case. Every nested build printed the global cache unchanged, the local cache with its `/consumer` subdirectory, `-j8`, `--summary all` and the caller's `--prefix`; the four loaded cases forwarded `--provider <path>` past the `--` to the program with no provider environment variable present at all. **Still unobserved:** the system-mode consumer (`-fsys=s2`), a cross target, a relative `--prefix`, and a run that names no prefix at all — the suppression branch |
| `zig build check`, `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-windows-gnu`, `riscv64-linux-gnu` | **PENDING** | four cells passed pre-migration, exit 0, 10/10 steps each; receipts 397/398/399/380 |
| `zig build check`, `aarch64-macos-none` | **PENDING** | red pre-migration for an external reason: no `CoreFoundation/CFTimeZone.h` on this host. The framework is now declared and is still unavailable here; no Apple SDK was obtained and no Apple cell has run since |
| `zig build check`, `wasm32-wasi` | **PENDING** | red pre-migration **against the bundled Zig libc++ provider** (`signal.h:2:2: "wasm lacks signal support"`). With the SDK 34 sysroot and the patched standard library the full closure compiles, the public tests pass and all three archives install; the smoke run **fails**, exit 134, in `Io.Threaded.fileWritePositional`. None of that is a whole-target green claim, and `-Dlinkage=dynamic` on this target is refused by name |
| Full 53-platform Zig API matrix | **PENDING** | two earlier sweeps are kept as history and neither is current: **18 pass / 22 fail / 13 build-only** at `local://foundation-cross-test-matrix-s2geometry.json`, and a later **20 / 14 / 19** at `local://foundation-cross-test-final-current-s2geometry.json`. Both describe the **previous** revision of this tree |
| Six-target `check`, **current source-bound baseline** — `baseline-s2geometry-check`, baseline run `20261005T014547Z-797a73f2`, 2026-10-05 | **OBSERVED — exit 1** | `Build Summary: 44/60 steps succeeded (6 failed)`, `failure_reason: the gate exited 1`, six declared targets seen. The six failures are the `wasm32-wasi` steps of this graph's **own** refusal: `error: UnsupportedWasiProvider: wasm32-wasi requires -Dwasi-sysroot=<complete WASI SDK 34+ sysroot with WASIp1-threads EH C/C++ providers>; bundled libc++ lacks the filesystem/exception closure. No core sources are omitted.` The gate invocation passes no `-Dwasi-sysroot=`, so this is a missing flag in the gate, not a source defect and not a platform verdict. The five non-WASI cells of the same run compiled and linked |
| Full 53-platform Zig API matrix, **current source-bound run** — `cross-test --jobs 8 --build-jobs 8`, run `20261004T221720228710Z-45046`, receipt `s2geometry-53-target-8.json`, source stamp `14c785720d6a…` identical before and after | **OBSERVED — exit 1** | **20 pass, 28 build-only, 5 build failures, 0 run failures** of 53, 20 cells executed at 46 tests each. `x86_64-linux`, `aarch64-linux`, `aarch64_be-linux`, `arm-linux`, `armeb-linux`, `hexagon-linux`, `loongarch64-linux`, `mips-linux`, `mipsel-linux`, `mips64-linux`, `mips64el-linux`, `powerpc-linux`, `powerpc64-linux`, `powerpc64le-linux`, `riscv32-linux`, `riscv64-linux`, `s390x-linux`, `thumb-linux`, `thumbeb-linux` and `x86-linux` each ran all 46 tests clean. **No cell failed its run.** A build-only cell compiled and had no runner, so it is coverage and not a pass |
| The five build failures of that run | **bounded** | `aarch64-macos`, `x86_64-macos`, `aarch64-maccatalyst` and `x86_64-maccatalyst` fail at `error: unable to find framework 'CoreFoundation'. searched paths:  none`, which is the link-stage form of the Apple-SDK dependency this graph declares at `build.zig:933` and cannot supply on a Linux host: no Apple SDK was obtained and none is invented. `wasm32-wasi` fails with the `UnsupportedWasiProvider` refusal above, because the profile names no `-Dwasi-sysroot=`. Four external-provider cells and one deliberate refusal |
| Native final wave — `native-final-evidence/20261004T233628757747Z-69351` | **OBSERVED** | eight cells, both linkages × `Debug`, ReleaseSafe, ReleaseFast, ReleaseSmall, `zig build test smoke install -Druntime=false`: eight `exit 0`, each `32/32 steps succeeded` static and `39/39` dynamic, each `46/46 tests passed`. Native and linked only |
| Own-loaded wave — `loaded-final-evidence/20261004T232823091897Z-23133` | **OBSERVED** | the same eight shapes under `-Druntime=true`: eight `pass`, each `33/33 steps succeeded` static and `36/36` dynamic, each `46/46 tests passed` |
| What those four do not cover | — | Each holds one source stamp for its whole run, and the stamps differ. Every build-graph, header, helper and normalisation edit made after a stamp describes a tree that run never saw. The `-ls2cpp` `pkg-config` metadata, the system-mode consumer (`-fsys=s2`), any `-fsys=s2` command at all, a cross `-Dtarget` through the `consumer` step, the whole-record integrity replay and the filtered package round still have no receipt over this tree |
| Installed C and C++ consumers against the install set | **PENDING** | earlier runs exist against pre-migration archives (71 and 21 numbered checks) and an installed S2 C++ consumer ran on the WASI SDK provider |
| Fetched filtered package, materialised consumer, whole-record integrity replay | **PENDING / driver-owned** | `FORKS.json.cross_test_wave.materialized_packages.s2geometry` |
| `package.nix` static variant | **OBSERVED** | `nix build .#static` completed `exit 0`; the flags it passes are `-Doptimize=ReleaseSafe -Dcpu=baseline -Dlinkage=static -fno-sys=s2`. Taken at the revision before the configure-time banner print and the documentation changes; a final build over the frozen source is the driver's to take, and the final store hash belongs to the root ledger, not to this file |
| `package.nix` shared variant | **OBSERVED** | `nix build .#shared` completed `exit 0` with `-Dlinkage=dynamic`. The delivery the derivation asked for is what it built, and the install-phase check that used to fail a shared build rather than mislabel it now passes. This is also the run that resolved the earlier `check-meta` unfree failure (`CHANGELOG.md` §68) |
| `devenv shell`, `devenv build outputs.static` / `outputs.shared` | **PENDING** | the eight **devenv** gates all pass — `devenv:info`, `devenv:tasks-list`, `devenv:canonical-integrity-mapping`, `devenv:shell-zig-version`, `devenv:shell-zig-env`, `devenv:consumer`, `devenv:integrity` and `repo:untouched`, `status: "pass"`, `gates_failed: []` (run epoch `20261004T215554Z`, scope `devenv`) — so a devenv shell **has** been entered, driven from a scratch project directory with `--from path:…` rather than from this tree. Still outstanding: `devenv.lock` does not exist, no `sdk:build`/`sdk:test`/`sdk:check` task ran, and `nix:build` is `gates_not_run` in that run, so `outputs.static` and `outputs.shared` are unexercised. `flake.lock` exists, created by the driver from the observed flake build |

### Earlier observations, kept at the revision they describe

Two receipts from before the runtime repair are still evidence, and both
describe a **three**-object closure that no longer exists. They are history
here, and neither is restated as a current result:

| Gate, at its own revision | What it printed |
|---|---|
| Shared-delivery install, `zig build install -Dlinkage=dynamic` | "Build Summary: 25/25 steps succeeded", `install success`, the three shared objects, the header tree, the `.pc` and every licence record; `local://foundation-contract-s2geometry-shared-origin-first-complete-native-closure-source-count-pin-removed.log`. An install receipt, not a behavioural one: no test and no smoke step is in that command |
| Runtime-loaded static delivery, `zig build smoke -Dlinkage=static -Druntime=true` against a separately supplied installed provider | "Build Summary: 6/6 steps succeeded", `smoke success`, provider `…/s2geometry-shared/lib/libs2bridge.so.0.14.0`, every section printing its published answer; `local://foundation-contract-s2geometry-real-complete-installed-shared-provider-runtime-static.log`. One delivery and one route, on the previous graph |

**Where the sixteen receipts are.** Each is a timestamped JSON file under
`/home/tmp2/gertullj/scratch/foundation-libs/contract-physics-lua/current-native-evidence/`,
named `s2geometry-current-<native|loaded>-<linkage>-<mode>-<ISO timestamp>.json`,
with the full command, cwd, start, finish, exit code and output; the two index
files beside them list all sixteen with their exit codes. They are scratch
receipts, not package bytes, and the package identity that a fresh gate would
record belongs to the driver.

**What those sixteen do not cover, and what is still unobserved.** The installed
`pkg-config` metadata that appends `-ls2cpp` to `Libs` landed *during* that
sweep: no one of the sixteen receipts prints the generated `.pc`, and the copy
installed under the native-dynamic prefix at the time did not yet name it. The
metadata itself is `SOURCE-CONFIRMED` from `addPkgConfig` and observable in an
installed file under the runtime-loaded dynamic prefix, which no gate quoted.
Equally unobserved: a **relocated** prefix actually loading its closure, an
installed C or C++ consumer compiled against these artifacts, every Windows cell,
all six `check` targets, the full
53-platform matrix, the Nix derivations, and the filtered fetch, integrity
replay and materialised consumer. The standalone `consumer/` package was on that
list too and has since left it: a later run built and ran it over this tree in
eight cases across both linkages and both dispatch modes, plus a refusal case
that exited 1 by design, which is the row in the table above.

### Build timing, for planning a cold build

From the recorded Debug run with a warm global cache and an empty per-target
cache: 3 minutes for the Abseil units, 5 minutes for the S2 units and 18 seconds
for `zig/bridge.cc` (`local://foundation-expansion-s2geometry-isolated-cache-smoke-157.log`). Plan
ten minutes, not two.

An ELF **shared** build is larger than that, and the current receipts say by
how much: `compile lib s2cpp ReleaseFast native` took 36 s at MaxRSS 417 MB
against an empty per-target cache, and the install tree compiles the Abseil, S2
and bridge libraries a second time — 28 s and 1 m respectively in the Debug
cell, with `compile lib s2cpp` reused by both graphs because the two are
configured identically. Plan the shared variant at roughly double the static
one, not at the same cost with four files instead of three.

---

## 4. Consumption

### As a Zig path dependency

```nix
# build.zig.zon
.dependencies = .{ .s2geometry = .{ .path = "../s2geometry" } };
```

```zig
// build.zig
const dep = b.dependency("s2geometry", .{ .target = target, .optimize = optimize });
const mod = dep.module("s2geometry");
exe.root_module.addImport("s2geometry", mod);
```

```zig
// main.zig
const s2 = @import("s2geometry");
const cell = s2.Cell.init(s2.CellId.fromToken("1/2/3"));
```

### As a runtime-loaded Zig consumer

Add `-Druntime=true` to the dependency's own options. The module then links no
archive: every entry point goes through one process-lifetime table that a
single explicit call fills.

```zig
try s2.load(.{ .path = "/opt/s2geometry/lib/libs2bridge.so.0" });
```

`runtime_loaded` is a comptime constant, so a program that supports both
configurations branches at comptime and only the branch it chose is analysed.
There is no fallback from `.path` to `.system`, no search path of this
package's own, no automatic retry and no unload; a call through the table before
the load has published it stops the program with a message naming the function,
in every optimisation mode. `-Dlinkage` still decides what is delivered and
installed — the two options are orthogonal, and a caller may name a provider
this tree did not build. [`README.zig.md`](README.zig.md) "The two
configurations" is the full contract, and `runtime/library.zig` writes out the
boundary a provider has to satisfy.

The module publishes one error set, the constants, the value types and handles
listed in [`README.zig.md`](README.zig.md), `pub const c` as the raw translated
bridge, and the five names the runtime route needs in either configuration:
`runtime_loaded`, `LoadSource`, `LoadError`, `load` and `loadedSource`.
[`README.zig.md`](README.zig.md) documents every method, the counting protocol,
the ownership rules, the bridge/allocator/configuration ABI boundaries and the
linked and runtime-loaded routes.

### As a C or C++ consumer of the install set

The installed `pkg-config` file is the route, and it is relocatable: its
`prefix` is `${pcfiledir}/../..`, so the file is correct wherever `--prefix`
pointed.

```sh
cc $(pkg-config --cflags s2geometry) main.c $(pkg-config --libs s2geometry)
```

Include `<s2geometry_bridge.h>` for the C entry points, or include `<s2/…>`
and `<absl/…>` directly and call upstream's C++ API. `Libs` lists
`-ls2bridge -ls2 -labsl` in dependency order, plus **`-ls2cpp` on an ELF shared
install**.

* **A C consumer** links what `Libs` names and needs nothing else from this
  package. The header tree is the whole upstream closure, `include/s2/**.h` and
  `include/absl/**.h` plus `**/**.inc`.
* **A C++ consumer on an ELF shared install needs the matching C++ runtime**:
  libc++ headers at `_LIBCPP_ABI_VERSION=1`, the ABI the three libraries were
  compiled against, and the shipped `libs2cpp.so.0` that `Libs` already names.
  What must **not** happen is a second private static libc++ from another build,
  or `libstdc++`: the symbols crossing this boundary are libc++'s, and two C++
  runtimes in one process mean two `std::locale` facet registries, which is
  exactly the failure `libs2cpp.so.0` exists to remove.
* **A static consumer** installs no `libs2cpp` and uses its own C++ standard
  library, as before, plus the platform extras recorded in `Libs.private`
  (`-ldbghelp` on Windows, `-framework CoreFoundation` on Apple targets). A
  consumer compiled by `zig cc` / `zig c++` gets its C++ runtime from the same
  toolchain that built the package.
* **Both** need `-fsized-deallocation`, because `libs2.a` contains sized
  `delete` calls.

### From a Nix output

`package.nix` installs, in one prefix:

* `lib/libabsl.a`, `lib/libs2.a`, `lib/libs2bridge.a` — or the shared form of the
  same three under `linkage = "dynamic"`, carrying upstream's own sonames and a
  `$ORIGIN` (ELF) or `@loader_path` (Darwin) runtime search path, so a **moved**
  prefix resolves its own closure beside itself;
* under `linkage = "dynamic"` on an ELF target, `lib/libs2cpp.so.0.16.0` with
  `libs2cpp.so.0` and `libs2cpp.so` beside it — the pinned compiler's shipped
  C++ runtime, which makes the shared variant's `Libs` line
  `-ls2bridge -ls2 -labsl -ls2cpp`;
* `include/s2/**.h`, `include/absl/**.h`, `include/absl/**.inc`,
  `include/s2geometry_bridge.h`;
* `lib/pkgconfig/s2geometry.pc` — `Libs: -L${libdir} -ls2bridge -ls2 -labsl`
  (plus `-ls2cpp` on an ELF shared install), `Cflags: -I${includedir}`, and the
  platform extras in `Libs.private`;
* `share/licenses/s2geometry/` — `LICENSE`, `NOTICE`, `AUTHORS`, `CONTRIBUTORS`,
  `NOTICE.md`, `FORK-LICENSE.md`, Abseil's `LICENSE` and `AUTHORS`, the pinned
  Zig compiler's MIT terms, and — on an ELF shared install — `LICENSE.libcxx.txt`,
  `LICENSE.libcxxabi.txt` and `LICENSE.libunwind.txt`, installed verbatim from
  beside the compiler's own sources.

No tool is installed: this package builds no executable, and upstream's Python
bindings are behind upstream's `WITH_PYTHON`, which this build does not expose.
No data file is installed either; `testdata/` is test input, not package
content.

### The four ABI boundaries

**The C++ bridge boundary.** Everything a consumer reaches through this package
is `extern "C"` (`zig/bridge.h`), and the scalars crossing it are `double`,
`uint64_t`, `int32_t`, `int` and `size_t`. A cell id *is* the whole 64-bit
integer; nothing here re-derives the face and Hilbert-position layout, which is
upstream's. One struct crosses by pointer and its field order is the ABI:
`S2BridgeCovererOptions` is four `int32_t` in the order `min_level`, `max_level`,
`level_mod`, `max_cells`. Two types are **incomplete** — `S2BridgeLoop` and
`S2BridgePolygon` — so their storage is allocated and freed by C++ on the other
side and no caller ever dereferences one.

**The allocator boundary.** There is exactly one allocator in the picture and it
is the provider's: the input vertex arrays are *borrowed for the call* because
`S2Loop::Init` copies them, list-returning entry points destroy their upstream
`std::vector` before returning, and every list return writes into a **caller**
buffer. No heap block crosses the boundary, so there is no cross-runtime
allocator requirement; a `std::bad_alloc` never travels outward either, because
the bridge catches that one exception itself and reports it as a status.

**The configuration boundary.** What reaches the library is decided by two
orthogonal options and nothing else: `-Dlinkage` says which artifact is
delivered and installed, `-Druntime` says whether the facade links it or
dispatches through a table an explicit `load` fills. A provider is named, never
guessed.

**The C++ runtime boundary.** Every boundary above is crossed through one
compiler. On an ELF shared install the three libraries and the runtime facade
are bound to a single `libs2cpp.so.0`, built from the pinned compiler's shipped
libc++, libc++abi and libunwind sources at `_LIBCPP_ABI_VERSION=1`, and no image
in the package carries a second private static C++ runtime. A consumer of that
install set therefore compiles against the same ABI version and links that
object; a consumer on a different ELF C++ runtime is not reading this package's
ABI, it is reading its own. `static`, `wasm32-wasi`, Darwin and Windows keep
their ordinary provider rules, install no runtime artifact, and are bounded by
the provider named for them.

**An installed upstream S2 exports no fork bridge ABI.** Every `s2br_*` symbol
is defined in `zig/bridge.cc` in this repository, so a runtime-loaded provider
for this SDK can only be this package's own shared build of `libs2bridge`, read
through the installed `s2geometry_bridge.h`; naming an installed `libs2` is
refused with `MissingSymbol` at the first lookup. `package.nix` encodes that
requirement as an install-time check; the provider's symbol table is a property
of the shared variant and is not described here.

The same boundary applies to every other provider this package links or invokes
without shipping: the WASI SDK 34 sysroot, Wasmtime, CoreFoundation. Their terms
are their own; see `NOTICE.md`.

---

## 5. Licensing

Fork-authored files, including this one, are **Apache-2.0** by the project
owner's authorization of 2026-10-04 — see [`FORK-LICENSE.md`](FORK-LICENSE.md)
for the grant, its scope and the two rows that need their own sentence. Upstream's
work keeps its own terms: Apache-2.0 for both projects, with three compiled S2
`util/gtl` headers additionally carrying BSD-3-Clause text, a public-domain CCTZ
header and timezone data, and the pinned Zig compiler's MIT terms travelling
because the standard-library patch edits two of its files.

One more set of terms travels with the ELF shared variant, and it is not the
pinned compiler's MIT text: the three components compiled into `libs2cpp.so.0`
are the LLVM project's **Apache License 2.0 with the LLVM exception**, and
their own `LICENSE.TXT` files are installed verbatim as `LICENSE.libcxx.txt`,
`LICENSE.libcxxabi.txt` and `LICENSE.libunwind.txt` beside the other records.
`NOTICE.md` names all three and their source pin; nothing upstream is edited to
ship them.

[`NOTICE.md`](NOTICE.md) is the per-file inventory and the obligations table; a
private repository removes none of them.

---

## 6. Where the rest of the record lives

| File | What it holds |
|---|---|
| [`README.zig.md`](README.zig.md) | the Zig interface: facade API, the bridge/allocator/configuration ABI boundaries, the linked and runtime-loaded routes, build modes, testing approach, and the detailed verification tables |
| [`README.upstream.md`](README.upstream.md) | upstream's README, byte-preserved (SHA-256 `d91df72a…`) |
| [`UPSTREAM.md`](UPSTREAM.md) | the pinned revisions, the canonical archive digests, the import mechanism and the sync procedure |
| [`NOTICE.md`](NOTICE.md) | licences, per-file exceptions, obligations, and the complete inventory of fork-owned files |
| [`FORK-LICENSE.md`](FORK-LICENSE.md) | the licence of this fork's own files |
| [`CHANGELOG.md`](CHANGELOG.md) | numbered, dated, append-only fork-only divergences |
| [`FORK-NOTES.md`](FORK-NOTES.md) | decisions, lessons, and the recorded boundaries and owner decisions |
| [`UPSTREAM.sha256`](UPSTREAM.sha256) | one SHA-256 record per immutable source, licence and oracle byte this tree compiles, installs, reads or licenses |
| `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc` | the one derivation, its two entry points and the canonical development shell |
| `LICENSE`, `NOTICE`, `AUTHORS`, `CONTRIBUTORS`, `doc/` | upstream's own records and documentation, unmodified |