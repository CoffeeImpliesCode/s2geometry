# CHANGELOG — fork-only divergences

Everything below is a change **this fork** made, not an upstream release.
`src/` is upstream's bytes except for one bounded, disclosed deviation (§50);
seven bounded Abseil deviations are disclosed in §45, §51 and §52, separately
Upstream's own `README.md`, `CONTRIBUTING.md` and `doc/` remain unchanged.

The pinned upstream is s2geometry `v0.14.0` at
`c24b368c67d0b8a2a109c5a75224e73a856bd8b7`, with Abseil C++ LTS `20250814.1`
at `d38452e1ee03523a208362186fd42248ff2609f6`. `UPSTREAM.md` covers both.

Sections are numbered and append-only. Nothing is renumbered when the pin
moves.

---

## 1. Removed upstream's inherited `.github/workflows/build.yml`

Upstream ships a GitHub Actions workflow that configures CMake with
`-DFETCH_ABSEIL=ON` (downloading Abseil), runs Bazel over upstream's own
workspace against the Bazel Central Registry, and — on a release tag — builds
Python wheels and publishes them to PyPI through `pypa/gh-action-pypi-publish`
under a `pypi` environment configured on Google's side of the release.

Keeping it would have meant that tagging a release in this repository attempts
an upload of s2geometry wheels under it, using another maintainer's release
infrastructure. It is **deleted**, not repointed: the Zig build is the only
build definition in this tree, and this fork's own
`.github/workflows/verify.yml` runs every mandatory gate. Nothing was
rewritten to "fix" it, because there was nothing in it worth keeping.

## 2. Added the Zig 0.16 package

`build.zig`, `build.zig.zon` and `build_support/`. The manifest declares
`.name = .s2geometry`, `.version = "0.14.0"`, `.minimum_zig_version = "0.16.0"`
and no dependencies: Abseil is vendored, so there is nothing to fetch and
nothing to resolve at build time.

`.version` is the **tag**, not `CMakeLists.txt`. Upstream's
`CMakeLists.txt:7-8` still says `project(s2-geometry VERSION 0.12.0)` inside
the v0.14.0 tag; that line is stale upstream and is left exactly as shipped.
The discrepancy is recorded in a comment next to `.version` so the next reader
does not "fix" one of the two by accident.

## 3. Replaced the build-time download with a vendored source

Upstream's CMake has `option(FETCH_ABSEIL … OFF)` and, when it is on, fetches
`https://github.com/abseil/abseil-cpp/archive/refs/tags/20250814.1.zip` at
configure time. This fork vendors that release whole at `vendor/abseil-cpp` and
compiles from the tree. `zig build` makes no network request of any kind, needs
no CMake, no Bazel and no installed s2, and is reproducible from a checkout
alone.

The tree is vendored **whole**, not cut to headers and not cut to the 153 units
this build needs, so that upstream's own CMake and Bazel builds still work from
it and so that the CMake/Bazel definitions the source list was transcribed from
travel with the source they describe.

## 4. Chose `20250814.1`, the CMake pin, over the other two versions the tag names

The v0.14.0 tree names three Abseil releases: `CMakeLists.txt:71-75` says
`20250814.1`, `README.md:59-61` says `20250814` (linking to the same
`20250814.1` tag), and `src/MODULE.bazel:11` says `20260107.1`. This fork uses
the CMake pin, because that is the build definition being replaced and because
`CMakeLists.txt:24-27` explains that a different Abseil configuration defines
`ABSL_HAVE_STD_STRING_VIEW` and friends differently — an ODR error, not a
warning. The Bazel pin is left in `src/MODULE.bazel` because this fork does not
build with Bazel; that file is upstream's and is unmodified.

## 5. Wrote the translation-unit lists out instead of globbing them

`build_support/s2_sources.zig` is the `add_library(s2 …)` block of
`CMakeLists.txt:141-249`, 108 entries, in upstream's order and spelling.
`build_support/absl_sources.zig` is every `absl_cc_library` `SRCS` entry in the
vendored tree except the fourteen that are `TESTONLY` or carry a `GTest::`
dependency in their own declaration: `atomic_hook_test_helper`,
`exception_safety_testing`, `spinlock_test_common`, `hash_generator_testing`,
`test_instance_tracker`, `stack_consumption`, `test_actions`, `test_helpers`,
`test_matchers`, `scoped_mock_log`, `status_matchers`, `pow10_helper`,
`per_thread_sem_test`, `time/internal/test_util`.

A glob over `vendor/abseil-cpp/absl/**/*.cc` would pick up 231 `*_test.cc`
files, every `*_benchmark.cc` and all fourteen excluded units, and would make
"the library, without its tests" an accident of a file-name pattern. Enumerating
makes it a recorded decision instead. `absl/random/internal/chi_square.cc` and
`distribution_test_util.cc` are **kept**: upstream declares them in
`absl_cc_library(random_internal_distribution_test_util)` with no `TESTONLY`
marker and no `GTest::` dependency, so they are library units.

`build.zig` asserts `s2_sources.source_count == 108` and
`absl_sources.sources.len == 153` at comptime, so a truncated list fails the
build rather than the link.

Abseil's platform variants — `crc_memcpy_fallback.cc` beside
`crc_memcpy_x86_arm_combined.cc`, `time_zone_libc.cc` beside
`time_zone_posix.cc`, and all five `*_waiter.cc` — are all listed
unconditionally and each selects itself with its own `#ifdef`, exactly as
upstream lists them. Adding one "for this target only" would be a new decision
upstream does not make.

## 6. Compiled Abseil as one static archive rather than ~150 CMake targets

A single `libabsl.a` holding the whole closure satisfies the same link as
upstream's target-per-library arrangement, and it means every object an S2
function can reach is compiled here rather than being hoped for by the linker.
The archive has the same content; only the packaging differs.

## 7. Installed the whole `src/s2` header tree

Upstream installs a hand-maintained subset of `src/s2/*.h`, which it
acknowledges is "only those transitively included by s2 headers we are
exporting". This package installs all 177 headers, under the same relative
layout, so `#include "s2/s2cell_id.h"` resolves identically here and in
upstream's install. A consumer that reaches a header upstream forgot to list
should not be told so by an install rule.

Abseil's install list is `.h` **and** `.inc`. The `.inc` is not optional:
Abseil headers `#include` their implementation fragments by name
(`spinlock_linux.inc`, `stacktrace_x86-inl.inc`, `symbolize_elf.inc`,
`spinlock_win32.inc`), so a `.h`-only filter would ship a header tree that
cannot compile.

## 8. Compiled the bridge's third-party headers as *system* includes

`zig/bridge.cc` reaches `src/` and `vendor/abseil-cpp` through
`addSystemIncludePath`; the Abseil and S2 libraries themselves keep ordinary
`addIncludePath`.

This is upstream's own published arrangement for this situation.
`CMakeLists.txt:46-49` defines `S2_USE_SYSTEM_INCLUDES` and describes it as
"Silence warnings in s2 headers by marking them as SYSTEM includes", and
`CMakeLists.txt:285-291` applies it to the `s2` target's **PUBLIC** include
directory — the one every consumer of the installed library is compiled with.
`zig/bridge.cc` is exactly such a consumer: it is the one translation unit of
this package that parses an upstream header as a *consumer* rather than as the
library's own unit.

The recorded Debug run of the bridge (129 compilation errors) split cleanly:
122 diagnostics came out of third-party headers — the `alignof(expr)`
GNU-extension pair at `src/s2/s2point_array.h:35,49` and
`-Wnullability-completeness` for every unannotated pointer in `s2loop.h`,
`s2builder.h`, `s2builder_graph.h`, `s2boolean_operation.h`, `s2polyline.h` and
`s2polygon.h` — and 7 were real semantic errors in `zig/bridge.cc` itself
(§13, §14).

**No warning switch was used.** `-Wno-nullability-completeness`,
`-Wno-gnu-alignof`, `-w` and `-pedantic-errors` would each silence the same
diagnostics in *this* repository's own `zig/bridge.cc`, and each would assert a
compiler warning policy that no run in this package has established. A system
include suppresses warnings from the headers it names; it does not suppress an
error, and it does not touch diagnostics in the main file, which stays fully
diagnosed.

## 9. Dropped `-fsized-deallocation` and the MSVC branch

`CMakeLists.txt:127` adds `-fsized-deallocation`, and its own comment scopes it
to "a bug with clang < 19" and says it can be removed once clang 19 is the
minimum. Zig always drives its own bundled clang, and every object this build
produces carries `DW_AT_producer: clang version 21.1.0` — read out of the S2
and Abseil objects in this package's own cache — two major versions past the
guarded bug. The flag is dead weight.

`CMakeLists.txt:108-114`'s MSVC branch (`-J`, `-D_USE_MATH_DEFINES`,
`-DNOMINMAX`) is inapplicable: this package never invokes `cl.exe`, and Zig's
C++ frontend is clang on every target. The `-D_USE_MATH_DEFINES` half is
reinstated for Windows in §10.

## 10. Added `-D_USE_MATH_DEFINES` on Windows targets

This is the one place the fork extends a flag beyond the condition upstream
states it under. Upstream pairs it with `if (MSVC)`; the reason MSVC needs it
is that `<math.h>` only defines `M_PI` and friends outside strict-ANSI mode,
and upstream's own `CMAKE_CXX_EXTENSIONS OFF` makes every target strict ANSI.
The S2 library uses `M_PI` in `src/s2/s1angle.cc`, `s1interval.cc`,
`s1chord_angle.cc`, `s2boolean_operation.cc` and `s2buffer_operation.cc`, and
Zig's bundled windows headers
(`lib/libc/include/any-windows-any/math.h`) gate it on the same condition, so
the define is required for `x86_64-windows-gnu` exactly as it is for MSVC.

## 11. Kept upstream's flag set and the Abseil floating-point contract

`-std=c++17` (`CMakeLists.txt:29-32`, with `…_EXTENSIONS OFF`, so not
`-std=gnu++17`), `-DABSL_MIN_LOG_LEVEL=1` (`CMakeLists.txt:62`, issued *before*
`FetchContent_MakeAvailable(absl)` so it reaches Abseil too, which matters
because `ABSL_MIN_LOG_LEVEL` changes inline code in `absl/log/log.h` and the
Abseil objects and the S2 objects that include it must agree), `-DNOMINMAX` (the
only define in `absl/copts/copts.py`'s warning-flag lists), `-Wno-attributes`
and `-Wno-deprecated-declarations` (`CMakeLists.txt:119-121`), and
`-fno-fast-math -ffp-contract=off`, which
`src/s2/_fp_contract_off.h` requires for correctness and which has to be on the
command line for Abseil's units too because that file's
`#pragma STDC FP_CONTRACT OFF` is a no-op on compilers implementing only the
GNU form.

Abseil's own warning *selections* are not reproduced: they cannot change the
artifact, and this package does not build with `-Werror`. Abseil's HWAES flags
are not carried because this pinned release defines no
`ABSL_RANDOM_HWAES_*_FLAGS` in `absl/copts/copts.py` or
`absl/copts/GENERATED_AbseilCopts.cmake`, so upstream expands them to nothing
for every processor; `absl/random/internal/platform.h:96-105` then derives
`ABSL_HAVE_ACCELERATED_AES` from the resolved target's CPU features, which is
exactly upstream's behaviour.

## 12. Added the C bridge, the Zig facade, and the public module

`zig/bridge.h` (installed as `include/s2geometry_bridge.h`) is a plain-C99
`extern "C"` surface of **93** entry points; `zig/bridge.cc` implements each as
a validation with ordinary comparisons followed by exactly one upstream call.
`zig/root.zig` is the public Zig module, registered by `b.addModule` as
`s2geometry`, and re-exports the translated bridge as `pub const c`.

The install name is `s2geometry_bridge.h` rather than `bridge.h`: a bare
`bridge.h` at an include root is generic and collidable, and renaming at the
install layer keeps the namespaced name while the source stays where it is.

The bridge exists because `addTranslateC` translates C and the upstream library
is C++17 with classes, virtual `S2Region` dispatch and `absl::string_view`;
translating a C++ header is not something Zig 0.16 does. `zig/bridge.h` is
therefore `extern "C"`-guarded and plain C99, so it stays parseable by a C
translator and not only by a C++ compiler.

## 13. Repaired five C++ errors in the bridge translation unit

Each of these was a real semantic error in `zig/bridge.cc`, not a warning:

| Symptom | Fix |
|---|---|
| `template <typename Region> CoverRegion` declared inside `extern "C"` | dropped the template; `CoverRegion` now takes `const S2Region&`, since `S2Cap`, `S2LatLngRect`, `S2Polygon` and `S2Cell` are all `S2Region` subclasses, and added `#include "s2/s2region.h"` |
| `S2Cap cap;` redefined the `size_t cap` parameter of `s2br_coverer_covering_cap` | local renamed to `region` |
| `const S2Cell cell(S2CellId(id));` parsed as a function declaration | brace initialisation |
| `S2PointLoopSpan span(absl::MakeConstSpan(...))` had no viable constructor | both loop measures now use `loop->loop.vertices_span()`, which returns `S2PointLoopSpan` directly |
| `S2LatLng` passed to `S2Polygon::Contains` | converted with `S2LatLng::FromDegrees(…).ToPoint()`; `S2Polygon` overloads `Contains` for `S2Point`/`S2Cell`/`S2Polygon`/`S2Polyline` only |

## 14. Re-checked every upstream precondition that upstream only debug-asserts

`min_level <= max_level`, `level_mod` in 1..3, cell levels, `parent` level,
neighbour levels, the `i`/`j` range of `FromFaceIJ`, and the unit-length
requirement on `S2Cap::Contains`/`S2Polygon::Contains` are all
`ABSL_DCHECK`s upstream, and an `assert` is removed in ReleaseFast — a bound
check that vanishes is a bound check that lies. Each is re-checked here with an
ordinary comparison and reported as `S2BRIDGE_INVALID_ARGUMENT`.

The unit-length check uses upstream's own tolerance:
`S2::IsUnitLength` (`src/s2/s2pointutil.cc:32-40`) accepts
`|‖v‖² − 1| ≤ 5 * DBL_EPSILON`, and the bridge implements exactly that
(`zig/bridge.cc:120-123`). A non-finite component makes the squared norm
non-finite, so one comparison rejects both a wrong length and a non-finite
coordinate. Without it, a Debug build would abort on upstream's `ABSL_DCHECK`
and an optimized build would answer from undefined input.

## 15. Widened the `allNeighbors` neighbour-level bound to 30 inclusive

The bridge rejected `nbr_level >= 30`. Upstream's `S2CellId::AppendAllNeighbors`
accepts `kMaxLevel`: `GetSizeIJ(30)` is 1 (`src/s2/s2cell_id.h:611-614`), and
the only body checks are `ABSL_DCHECK_GE(nbr_level, level())`
(`src/s2/s2cell_id.cc:558`) and `nbr_size <= size`
(`src/s2/s2cell_id.cc:570`). The `level < kMaxLevel` bound at
`src/s2/s2cell_id_test.cc:551` belongs to the test helper `TestAllNeighbors`,
which then calls `child_begin(level + 1)` and needs one level of headroom that
`AppendAllNeighbors` itself does not. golang/geo's refusal of 30 is a Go-side
choice, not the C++ contract.

The bound is now this cell's own level **.. 30 inclusive**, and the facade
documents the same range.

## 16. Bound the `Coverer` options struct to a local, and capped `max_cells`

Two defects in the facade's four `covering*` methods and their four `…Count`
partners, both of which would have been caught by a compiler:

* `self.options()` returned a struct **by value**, and `try self.options()` was
  therefore passing a temporary's address to a C function that stores through
  it. All eight methods now bind `const native_options = try self.options();`
  immediately after their own local and pass `&native_options` in the original
  argument position. The local is named so it does not shadow the `options`
  helper, and it lives exactly as long as the synchronous C call needs it.
* `max_cells` is a `u32` in the facade and an `int32_t` in the bridge
  (`zig/bridge.h:565`). A value above `maxInt(c_int)` would trap the
  `@intCast` in Debug and ReleaseSafe rather than report anything, so it is now
  rejected as `error.InvalidArgument` next to the other option checks.

## 17. Renamed one `CellId` parameter that shadowed a method

`CellId.fromFacePosLevel`'s second parameter was `pos`, and `CellId` declares
`pub fn pos(self)`. Zig 0.16 rejects a function parameter that shadows a
declaration of the enclosing scope. Renamed to `hilbert_pos`, passed
positionally, with a doc comment saying what it is. `pub fn pos` and
`s2br_cell_pos` are untouched and no public method was renamed; every caller
passes positionally, so no caller needed an edit.

Every other `CellId` parameter was checked against all 37 declared `CellId`
names, and the other structs' parameters against their own declarations. `pos`
was the only collision.

## 18. Compared the bridge status by value, not by enum field

`S2BridgeStatus` is a C enum, and `translate-c` gives it the unnamed integer
type `c_uint` rather than a Zig enum — the generated module emits
`pub const enum_S2BridgeStatus = c_uint;` and the five enumerators as top-level
`c_int` constants. Switching on `.OK`-style fields does not compile. `check()`
compares the status against the emitted constants and maps an unrecognised
non-zero value to `error.Internal` rather than reading it as a pass, so a bridge
that grows a status value cannot silently succeed.

## 19. Made seven `comptime_float / comptime_int` divisions float divisions

`std.math.pi` is a bare `comptime_float`, so `std.math.pi / 2` is
`comptime_float / comptime_int` and Zig 0.16 rejects it as an ambiguous
coercion whenever the result has a non-zero remainder. Fixed in `smoke.zig`
(2), `consumer/src/main.zig` (2) and `tests.zig` (8) by dividing by `2.0`
instead. Every tolerance and every upstream citation is unchanged, and
`std/fmt/float.zig` widens `comptime_float` to `f128` for `{d}` rendering, so
the printed digits are identical.

## 20. Rebuilt the polygon-boolean demonstration on two positively oriented wedges

The demonstration asserted an overlap that did not exist. `S2Polygon::Init`
(`src/s2/s2polygon.cc:406-414`) hands the loop straight through and never
normalizes, and `S2::GetArea` (`src/s2/s2loop_measures.cc:51-55`) maps a
negative signed area to `area + 4π`; the second input
`(0,1,0), (0,0,1), (-1,0,0)` has determinant −1, is therefore read clockwise,
and measures 7π/2 — the whole sphere minus the triangle, not a partly
overlapping octant.

It is now two positively oriented wedges that genuinely overlap: `A` is the
octant through the positive axes (azimuth 0…90, north of the equator) and `B`
is `A` turned 45° about +z, built from `(a, a, 0)`, `(−a, a, 0)`, `(0, 0, 1)`
with `a = sqrt(0.5)`, whose determinant is `2a² = +1`. The expected areas come
from **spherical excess** — each wedge `3·(π/2) − π = π/2`, the intersection
`5π/4 − π = π/4`, the union `7π/4 − π = 3π/4` — so they are derived from
geometry rather than read off a run. The rotated wedge's equatorial vertices are
not exactly unit length in binary (`a² = 0.5000000000000001`, squared norm
`1.0000000000000002`, which is inside the `5·DBL_EPSILON` of §14), and the
comments say so.

Containment was extended with three strictly interior points that decide
A-only, both, and B-only, plus the south pole for neither, checked against `A`,
`B`, the union and the intersection. Labels were corrected from "two
overlapping octants" to "two overlapping wedges", and the test was renamed to
"union and intersection of two overlapping wedges give pi/4 and 3pi/4".

## 21. Replaced a false "all neighbours are distinct" invariant

`S2CellId::AppendAllNeighbors` explicitly allows a repeat:
"for cells adjacent to a face vertex, the same neighbor may be appended more
than once" (`src/s2/s2cell_id.h:469-475`). Only *edge* neighbours are guaranteed
distinct (`src/s2/s2cell_id.h:456-458`). Two things followed:

* `smoke.zig` no longer compares the all-neighbours of `3/` index by index. It
  compares **multisets** through a new `sameCellsMultiset` helper — equal
  lengths and equal occurrence counts per cell — with the expectation spelled in
  full upstream debug strings `{"1/","2/","2/","2/","4/","5/","5/","5/"}` so
  upstream's three face-2 and three face-5 repeats are preserved verbatim. The
  Zurich row keeps its full published eight-cell list and its per-occurrence
  printed line; only its check moved to the shared helper. The face-1 edge
  neighbours stay ordered, because `GetEdgeNeighbors` documents the order.
* The test that enumerated level-30 and level-29 neighbours asserted
  pairwise distinctness. It now asserts the exact source-derived corner
  multisets, which contain a real duplicate (the face-5 leaf `(0, 2³⁰−1)`,
  reached twice by the `(i−1, j−1)` and `(i, j−1)` corner wraps), built with
  `CellId.fromFaceIJ` and compared with a new `expectSameCellMultiset` helper.
  Upstream's own hand-derived corner-cell edge-neighbour list at `kMaxLevel`
  (`src/s2/s2cell_id_test.cc:582-596`) was added as an independent published
  level-30 answer.

Nothing was deduplicated, no fixture byte was changed, and the `2/3333` repeat
in the fixture-driven neighbour test is unchanged.

## 22. Added a `max_cells` regression test

Inside the existing covering test, `Coverer{ .max_cells = maxInt(c_int) + 1 }`
is rejected by `coveringCapCount` with `error.InvalidArgument`. It goes through
the real bridge call path, so it fails loudly if the guard of §16 is removed —
in which case the `@intCast` traps — or if the bridge is reached at all.

## 23. Added the independent fixture oracles

`testdata/` holds six files: 32 token/id pairs and 5 malformed tokens from
golang/geo; 14 leaf-cell ↔ lat/lng pairs from golang/geo; 17 neighbour,
containment and parent/child rows from `src/s2/s2cell_id_test.cc`,
`src/python/s2geometry_test.py` and golang/geo; the 42-cell level-22 Sydney
covering that `src/s2/s2region_coverer_test.cc`'s `JavaCcConsistency` test
publishes; 4 `PolarClosure` answers; and 9 normalization plus 10 validity
answers. Every row carries its source file and line in the file's own header,
and `NOTICE.md` credits each one.

Two facts that shaped them and are worth keeping: no published leaf cell for
lat/lng (0,0) exists in any of the implementations searched, so the projection
origin is pinned by what *is* published (the level-0 cell `0x1000000000000000`
is Google's own literal for "the face centred at (0,0)", and (0,0)'s leaf is on
face 0) and the level-30 token is deliberately not asserted; and only **one**
face's edge-neighbour list is published upstream, for face 1, so only that row
is asserted — an earlier draft generalised it to all six faces and was removed
as invented data.

## 24. Added the behavioural roots and the standalone consumer package

`tests.zig` holds 39 tests, every expected value an independent published
answer or a geometric identity, and between them they call every public facade
method — which is what makes `zig build check` a real compile of the facade
rather than of an unreferenced archive. `smoke.zig` is the deterministic
runnable program. `consumer/` is a separate package that depends on this one by
path through `dep.module("s2geometry")` and deliberately writes no include path,
links no library, and sets neither `link_libc` nor `link_libcpp` — a dependent
states its own requirements, and adding either here would hide a library that
forgot to declare it.

Upstream's own `src/s2/*_test.cc` are **not** run by `zig build test`; they
need GoogleTest, which this package deliberately does not require. They are
left intact in the tree and can still be built with upstream's CMake.

## 25. Added `-fsys=s2`, with the same five entry points

`-fsys=s2` links an installed `libs2` and the 26 `absl_*` libraries upstream's
`s2` links, and offers `install`, `test`, `smoke`, `check` and `consumer` — the
same five the bundled graph has, against the installed library and its installed
headers. Omitting any of them would leave the mode unproven where it matters
most: a system library whose facade compiles but whose behaviour differs from
this tree's is exactly what the mode exists to catch.

Two decisions inside it are deliberate and are stated in the code:
the bridge is still compiled from this repository (an installed upstream
library exports no fork-only symbol, so a system-mode bridge built against
upstream sources would be a bridge to nothing), and `zig/bridge.h` is
translated *without* this repository's include roots (translating the bundled
v0.14.0 header against an installed library of unknown version would describe
an ABI that may not be the one on disk, which is the failure a system mode
exists to avoid).

`-fsys` / `-fno-sys` feed `b.systemIntegrationOption` and are **not** an entry
in the `-D` map; an earlier draft of the `-fsys` documentation said `-Dsystem`,
which is wrong.

The mode's `check` compiles the selected target only, because the library and
the headers it binds to are this machine's. That limit is stated in the code
rather than left as a silent narrowing.

## 26. Forwarded the system-integration choice to the nested consumer build

`zig build consumer -fsys=s2` runs a **separate** `zig build` in `consumer/`,
which configures this package again as a path dependency. Without forwarding,
the nested build would resolve the mode to its own default: `consumer -fsys=s2`
would install the bundled library and then prove the consumer against the
installed one, reporting two builds as one. `addConsumerStep` now takes the
resolved mode and forwards `-fsys=s2` or `-fno-sys=s2` as an argument.

The nested build also gets a subdirectory of the outer build's cache when the
outer one was given an explicit cache directory, so two build graphs never
write the same manifest directory.

## 27. Rewrote `.github/workflows/verify.yml` into three jobs

* **`provenance`** — checks that `LICENSE`, `NOTICE`, `NOTICE.md`,
  `UPSTREAM.md`, `CHANGELOG.md`, `FORK-NOTES.md` and `README.zig.md` are
  present and non-empty; that `git diff --exit-code c24b368c… -- src` is clean;
  that `UPSTREAM.md` names both pinned revisions and both version labels; that
  the vendored Abseil carries `lts_20250814` in
  `absl/base/options.h`; and that the manifest ships `src` and `vendor` and
  does not ship `.zig-cache` or `zig-out`.
* **`native`** — `build`, `test` (Debug), `test -Doptimize=ReleaseSafe`,
  `smoke`, `check` and `consumer`, on Zig 0.16.0.
* **`cross`** — `zig build check -Dtarget=…` for all six required targets,
  compiled and never executed.

The cross job carries **no** `continue-on-error`. `wasm32-wasi` and
`aarch64-macos-none` are attempted anyway, with their known risks written into
the step: a target that genuinely cannot build must be recorded in
`FORK-NOTES.md` and named in the step that fails, not marked green.

There is deliberately **no** `-fsys=s2` job: a stock runner has neither an
installed `libs2` nor an Abseil, and this repository cannot name an install
package for them without guessing. A claim about that mode needs a machine that
has them, not this file.

**Not yet in this workflow, and required:** `UPSTREAM.sha256` is not yet named
in the required-records loop, and there is no `sha256sum -c UPSTREAM.sha256`
step. See `FORK-NOTES.md` §12 and the pending list.

## 28. Appended Zig entries to `.gitignore`

`.zig-cache/` and `zig-out/`, each with a comment saying why: `zig build`
writes the cache beside the package and the install prefix under `zig-out/`,
neither belongs in the repository, and neither may leak into the manifest's
`.paths`. Upstream's four lines are kept verbatim above them.

## 29. Added the provenance and documentation set

`UPSTREAM.md`, `UPSTREAM.sha256`, `NOTICE.md`, `CHANGELOG.md`, `FORK-NOTES.md`
and `README.zig.md`. `UPSTREAM.sha256` carries **926** SHA-256 records over
every compiled source, every installed header, every licence and
dependency/build record, the six upstream oracle files the fixtures were
transcribed from, and this fork's six fixture files. It was produced with
SHA-256 from `node:crypto` in a Bun eval cell — no shell hashing command, no
`git` command — and every one of the 926 records was re-derived from the
written file with the same method and compared against it.

`sha256sum -c UPSTREAM.sha256` has **not** been run in this workspace, and no
exit code is claimed for it.

## 30. Did not change upstream's stale CMake project version

`CMakeLists.txt:7-8` says `project(s2-geometry VERSION 0.12.0)` inside the
v0.14.0 tag. It is left exactly as upstream shipped it, with a comment in
`build.zig.zon` saying that the tag is the version and that this fork does not
change that line. Fixing it upstream is upstream's call.

## 31. Restored `-fsized-deallocation`, and stopped carrying upstream's `-Wno-*` selections

This section **supersedes §9 and §11**, which are kept above because this
changelog is append-only and because their claim was wrong in a way worth
keeping visible.

`CMakeLists.txt:122-127` requires `-fsized-deallocation` for Clang, in the
`else()` branch of `if (MSVC)`. §9 dropped it on the strength of
`DW_AT_producer: clang version 21.1.0` read from this package's own objects,
two majors past the "clang < 19" bug the upstream comment names. That reasoning
is **withdrawn**. `zig build check -Dtarget=x86_64-windows-gnu` observed
`local://foundation-expansion-s2geometry-check-x86_64-windows-gnu-235.log`:
without the flag, `compile lib s2` failed with `no matching function for call
to 'operator delete[]'` at `src/s2/util/bitmap/bitmap.h:718` and `no matching
function for call to 'operator delete'` at
`src/s2/util/coding/coder.cc:62`, both reached through
`src/s2/s2shape_nesting_query.cc:30-113`, on a compile line that carried
`-Wno-attributes` and `-Wno-deprecated-declarations` and no
`-fsized-deallocation`. Those two files call sized delete explicitly and the
target's default declaration set does not offer it. With the flag restored, the
same target compiled everything — `local://foundation-expansion-s2geometry-resume-check-x86_64-windows-gnu-254.log`
records `compile lib absl … cached`, `compile lib s2 … success 47s`,
`compile lib s2bridge … success 5s`, `translate-c success` and
`compile exe s2-smoke … success`. The lesson is in `FORK-NOTES.md` L18: **a
compiler version does not establish a target's defaults**.

`CMakeLists.txt:120-121`'s `-Wno-attributes` and
`-Wno-deprecated-declarations` — which §11 listed as carried — are now
**dropped**. They are warning *selections*, they cannot change the artifact,
and a `-Wno-…` that silences a diagnostic in an upstream header silences the
same diagnostic in this repository's own `zig/bridge.cc`, which is where a real
defect has to stay visible. Nothing replaces them: the two upstream header
trees are compiled as *system* includes on the bridge translation unit, which is
upstream's own arrangement (`CMakeLists.txt:46-49`, applied at `:285-291`).

## 32. Split the compiler flags into `s2Flags` and `abslFlags`

§9 and §11 described one flag list. There are two, because the Abseil half
correctly does **not** receive `-fsized-deallocation`, and that is upstream's
arrangement rather than a second opinion: upstream's
`FetchContent_MakeAvailable(absl)` is at `CMakeLists.txt:80` and
`add_compile_options(-fsized-deallocation)` is directory scope at `:127`,
**after** it, so Abseil's targets are created before the option exists.

`build.zig` reproduces the ordering: `addAbseil` runs first (`build.zig:181`)
with `abslFlags`, then `addS2` (`:182`) with `s2Flags`, then `addBridge` (`:183`)
with `s2Flags` again — the bridge is C++ that includes the s2 headers, so it
must be under the same sized-deallocation regime as the library it calls.

## 33. Wired `UPSTREAM.sha256` into the manifest and the CI provenance job

This section **supersedes the closing note of §27**, which said the record was
not yet in the required-records loop and that no `sha256sum -c` step existed.

`build.zig.zon`'s `.paths` now names `UPSTREAM.sha256` beside the other five
records. `.github/workflows/verify.yml`'s `provenance` job names it in its
required-records loop (`LICENSE NOTICE NOTICE.md UPSTREAM.md UPSTREAM.sha256
CHANGELOG.md FORK-NOTES.md README.zig.md`), runs `git diff --exit-code
c24b368c… -- src`, and runs `sha256sum -c UPSTREAM.sha256`. Both have since been
run by the driver and both passed: exit 0, 926 records `OK`
(`local://foundation-expansion-s2geometry-immutable-native-dependency-fixture-integrity-231.log`)
and exit 0 with empty output
(`local://foundation-expansion-s2geometry-pinned-native-pristine-diff-268.log`).
This also supersedes §29's closing sentence that `sha256sum -c` had never been
run. The workflow's comment explaining why no `-fsys=s2` job exists stays.

## 34. Stated the status and sizing contract the bridge and facade owe a caller

Documentation of a contract that is now being repaired, not a claim that it is
repaired. Three rules, all of them already true of the signatures, which are
unchanged:

* **A boolean answer is never the return value.** A predicate writes `0`/`1`
  through an `int*` and returns `S2BridgeStatus` separately, so "the answer is
  false" and "the call was rejected" are different observations. Every
  `Error!bool` in `zig/root.zig` exists because of this.
* **The count a two-pass call reports is the count it would write.** One entry
  point, one bound: the counting pass and the filling pass cannot drift.
  `childrenCount`/`children`, `vertexNeighborsCount`/`vertexNeighbors`,
  `allNeighborsCount`/`allNeighbors`, every `Coverer.covering…`/`…Count` pair,
  `toToken`/`toDebugString`.
* **`S2BRIDGE_INTERNAL_ERROR` is reserved, not produced.** Upstream ships
  `src/s2/s2error.h` and Abseil ships `Status`, so a bridge entry point needs
  somewhere honest to put an upstream-reported failure. No entry point among the
  93 returns it today. The facade maps it, and any unrecognised non-zero status,
  to `error.Internal`, so a bridge that grows a sixth status cannot turn into a
  silent success.

Three driver probes against the installed archives show the contract is not yet
met in practice — `s2br_cell_children`'s counting pass answers
`S2BRIDGE_OUT_OF_MEMORY` with `count = 0` (receipt
`…-review-before-children-278.log`), `s2br_polygon_create` has no ordinary
unit-length bound and aborts inside the constructor on finite non-unit vertices
(`…-review-before-union-279.log`, `…-review-before-intersection-280.log`), and
`s2br_polygon_union`/`s2br_polygon_intersection` abort inside `S2Loop::Init`
on a polygon whose edges cross, even though the constructor accepted it and
`s2br_polygon_is_valid` correctly called it invalid
(`…-review-topology-before-union-282.log`,
`…-review-topology-before-intersection-283.log`). Three distinct defects at
three depths; `FORK-NOTES.md` L19 and L20 record them and the pending list owns
them. None is fixed here and none is claimed to be.

## 35. Added an `installed-consumers` job to the CI workflow

This section **supersedes §27's "into three jobs"** and its three-bullet job
list. The workflow now has four jobs: `provenance`, `native`,
`installed-consumers`, and `cross`.

`installed-consumers` runs `zig build` to produce the install prefix, then
compiles, links and **runs** two programs that live entirely outside the build
graph and see only `zig-out/include` and `zig-out/lib`:

* a C11 translation unit that includes `<s2geometry_bridge.h>` and links
  `libs2bridge.a`, `libs2.a` and `libabsl.a`, and
* a C++17 translation unit that includes `<s2/s2cell_id.h>` and `<absl/…>` and
  links `libs2.a` and `libabsl.a` — the upstream headers and the upstream
  archive, with no Zig anywhere.

That is the whole point of installing a package: a declaration whose type is
wrong must fail to compile, a declaration the archive does not define must fail
to link, and a rejected argument that still wrote its out parameter must fail at
run time. `-lc++` appears on the C driver's line for the same reason
`build.zig` puts `link_libcpp` on every artifact: the archives are compiled from
C++ and carry C++ runtime references. Every expected value in the C driver is
written out by hand from the id layout in `src/s2/s2cell_id.h` and from the
geometry of a spherical octant, and where an independent implementation has
published the same number the comment names it — `testdata/golang_cellid_tokens.tsv`
carries golang/geo's own decodings of `"1"`, `"3"` and `"14"`, and its
malformed-token table lists `"876[ee99"` as an input the codec must reject.

Observed against the install set so far: the C++/Abseil consumer passed, exit 0
(`local://foundation-expansion-s2geometry-installed-native-Cpp-Absl-surface-238.log`);
the C bridge consumer compiled, linked and ran, then exited 17 on its own
`check 17` — the `s2br_cell_range` bound comparison
(`…-installed-C-bridge-surface-239.log`). That is a run-time assertion about one
hand-written expected value, not a build or link failure, and it is the
integration owner's to resolve.

## 36. Corrected the facade's method count, and said what a count is worth

`zig/root.zig` registers **104 public methods** across ten types — `CellId` 33,
`Polygon` 20, `Loop` 17, `Cell` 8, `Coverer` 8, `LatLng` 6, `LatLngRect` 6,
`Cap` 4, `Point` 2, `BoundUV` none. An earlier revision of these records
reported 79, which is the count of **distinct names**: `containsPoint`,
`isValid`, `deinit`, `area` and `normalize` legitimately recur on more than one
type, so 79 understates the surface by a quarter. `README.zig.md` and
`UPSTREAM.md` now state both numbers and say which is which, and the 93 bridge
entry points are now stated as 93 declarations in `zig/bridge.h` and 93
definitions in `zig/bridge.cc`.

The point of the correction is not the digits. Both counts are **source facts
read out of `zig/root.zig` and `zig/bridge.h`, and neither is evidence that
anything works**: a declaration being written down says nothing about whether it
compiles, whether its body is ever instantiated, or whether the bridge call
underneath returns what the doc comment promises. Presenting a count as if it
were a result is the failure this section exists to prevent — the same shape of
error as a `zig fmt` exit 0 offered as a gate, or `refAllDeclsRecursive`
offered as proof that a body was analysed. The evidence for the surface is
`zig build check`, which attaches `tests.zig` — where every public method is
called with concrete argument types — to every target's step, and that gate is
`PENDING` for the reasons in §34.

## 37. Repaired the three bridge defects the driver's probes found

This section **supersedes §34's closing sentence** ("None is fixed here and none
is claimed to be") and makes good on §34's third bullet, which described
`S2BRIDGE_INTERNAL_ERROR` as reserved rather than produced. It is now produced.

Three distinct defects, at three depths, each found by a driver probe against
the installed archives and each with its own depth of cause:

1. **A counting pass that materialised the list it was measuring.**
   `s2br_cell_children` walked `child_begin(level)` to `child_end(level)` into a
   `std::vector` before answering a question about its length, so asking a face
   cell for level 30 — 4³⁰ = 2⁶⁰ cells — returned `S2BRIDGE_OUT_OF_MEMORY`
   with `count = 0` (receipt `…-review-before-children-278.log`). It now
   subtracts `child_begin(level).distance_from_begin()` from
   `child_end(level).distance_from_begin()`: upstream's own count of `next()`
   steps from the level's first cell (`s2/s2cell_id.h:360-363`), which upstream
   documents as callable on `End()` as well as on valid ids. Constant time, no
   allocation, and a span a `size_t` cannot hold is refused as
   `S2BRIDGE_INVALID_ARGUMENT` rather than reported wrapped. A short buffer is
   refused before the traversal starts. **The ABI is unchanged**: `out ==
   nullptr` with `cap == 0` still means "tell me the count".
2. **A constructor with no unit-length bound.** A triangle whose vertices have
   squared norm 2 reached upstream's exact predicate through
   `S2Loop::Init` → `InitOriginAndBound` (`s2/s2loop.cc:201-207`, `:271`) and
   died at `s2predicates.h:394] Check failed: a.Norm2() <= 2 (4 vs. 2)`, so
   `s2br_polygon_create` never returned a status at all (receipts
   `…-review-before-union-279.log`, `…-review-before-intersection-280.log`).
   `AllUnitPoints` now checks the whole chain with upstream's own
   `S2::IsUnitLength` tolerance (`|Norm2() - 1| <= 5 * DBL_EPSILON`,
   `s2/s2pointutil.cc:32-40`) before any vertex becomes an `S2Point`, and
   `NativeCountFits` proves the count is one upstream's `int` and the caller's
   `size_t` can both hold before the array is read at all. This is upstream's
   own point made plainly: "this check happens too late in debug mode, because
   `S2Loop` construction calls `s2pred::Sign` which expects vertices to be unit
   length" (`s2/s2loop.cc:225-230`).
3. **A boolean operation that asserted over its own output.** Four unit-length
   vertices are enough to build a self-crossing loop; the constructor returned
   `S2BRIDGE_OK` and `s2br_polygon_is_valid` correctly called the polygon
   invalid — and then `s2br_polygon_union` / `s2br_polygon_intersection` died
   validating the loop they were about to emit, at
   `s2loop.cc:357] Check failed: IsValid()` (receipts
   `…-review-topology-before-union-282.log`,
   `…-review-topology-before-intersection-283.log`). `RequireValidOperand` now
   asks upstream's own `S2Polygon::IsValid()` of each operand *before*
   `InitToOperation` and maps a false answer to `S2BRIDGE_INVALID_ARGUMENT`;
   `DeferValidation` sets the deferred-validation override on every loop and
   polygon this bridge constructs, so `S2Loop::InitIndex`'s fatal
   `ABSL_CHECK(IsValid())` never runs on a chain the validator is there to
   report.

The boolean entry points also now bind the **`S2Error` out-parameter overloads**
of `InitToIntersection` / `InitToUnion`, with the snap function upstream's own
two-argument overloads pass (`s2builderutil::IdentitySnapFunction(S2::kIntersectionMergeRadius)`,
`s2/s2polygon.cc:955-957`, `:981-983`). The choice is forced, not stylistic:
the overloads without the `S2Error` parameter report through
`ABSL_LOG(DFATAL) << … << error` (`s2/s2polygon.cc:945-951`), and DFATAL
aborts in every optimise mode, so they could not report anything at all. A
false result is `S2BRIDGE_INTERNAL_ERROR`; the partial output is held in a
`std::unique_ptr` and released on that path, so a failure leaves `*out` null
rather than handing back a half-built polygon. `s2br_polygon_create_loops` also
rejects a per-loop length below 3, bounds each length, and sums them with an
explicit carry check before bounding the **total** — a sum that is individually
fine can still exceed what one `int` holds.

`Polygon.initLoops` is guarded the same way, and permanent behavioural
regressions were added for each of these. **Signatures are unchanged**: 93
bridge declarations and 104 facade methods, as in §36, and the buffer ABI is the
one §34 described. **None of this is gated.** `zig build test`, the six `check`
targets, `zig build consumer` and the installed C bridge consumer have not been
re-run since, so this section records what changed in the source and nothing
about what it does at run time.

## 38. The bridge stopped compiling, and the package stopped shipping three recorded files

**This section records a regression, not a fix.** §37 landed and nothing has
been gated since, so this is what the next full pass actually observed — and it
is red.

`compile lib s2bridge` now fails on native Debug (313), native ReleaseSafe
(314) and four of the six cross targets (316, 317, 319, 320) with **119
`-Wnullability-completeness` errors** from upstream headers reached through this
repository's own bridge:

```
…/s2/s2builder.h:473:20: error: pointer is missing a nullability type specifier
                     (_Nonnull, _Nullable, or _Null_unspecified)
    S2MemoryTracker* memory_tracker() const;
…/zig/bridge.cc:30:10: note: in file included from …
```

This is §8's arrangement failing, and §8 is `L1` in `FORK-NOTES.md`: upstream
headers are noisy on a stricter compiler, and upstream's own answer — mark the
third-party roots as *system* includes on the one translation unit that
includes them as a *consumer* — is what must not have been lost.
**Source-confirmed, and explicitly not established as the mechanism:**
`build.zig` gives the bridge module `addSystemIncludePath` for both
`s2_sources.include_dir` and `absl_sources.include_dir` (`:380-381`) *and* an
ordinary `addIncludePath` for the same two roots (`:202-203`), so each root is
reachable as an ordinary include as well. No compiler run in this workspace
confirms that this is what changed the classification. The `-I` / `-isystem`
repair is in flight; the result is a gate observation, not a claim. **No
diagnostic is to be silenced with `-Wno-`** — the whole point of the system
include is that it silences them in the headers and nowhere else, which is the
property §8 argued for and which a `-Wno-nullability-completeness` would throw
away.

Separately, the package no longer ships everything its own integrity record
lists. `zig fetch` succeeds — exit 0, `s2geometry-0.14.0-2Klt8ad7BgHn48ePhMt9wVpq4AaLEZRMwJvKFkIwx4qC`
(`…-external-driver-package-fetch-325.log`), which supersedes the earlier
`IllegalFileTypeInPackage` — but running the record *inside* the fetched package
reports **923 records `OK` and 3 files missing**: `.clang-format`,
`pyproject.toml`, `setup.py` (334). Those three are in `UPSTREAM.sha256` and not
in `build.zig.zon`'s `.paths`. Every byte that *was* present matched, so this is
a packaging gap and not a content mismatch — but a dependent that resolves this
package is handed a record it cannot fully run, which is a worse outcome than
either adding the three paths or dropping the three records. The materialised
package's own consumer then fails to build for the unrelated 119-error reason
above (341).

Two targets are unchanged in kind and are not part of this:
`aarch64-macos-none` still stops in vendored Abseil at
`'CoreFoundation/CFTimeZone.h' file not found` (318), and `wasm32-wasi` still
stops in vendored Abseil — now at the signal barrier rather than the mutex one,
`signal.h:2:2: error: "wasm lacks signal support"`, 39 errors (321). Those are
platform capabilities this host does not have.

## 39. Bounded every public index on the Zig side of the narrowing

A fourth defect, of a different kind from §37's three, and found by **running**
the facade rather than by reading it. Five methods take a `usize` index and pass
it to a bridge parameter declared `int`:

| Method | `zig/root.zig` |
|---|---|
| `Loop.vertex` | `try check(c.s2br_loop_vertex(self.handle, try asIndex(i), &xyz));` |
| `Loop.vertexLatLng` | `try check(c.s2br_loop_vertex_lat_lng_deg(self.handle, try asIndex(i), &lat, &lng));` |
| `Polygon.loopNumVertices` | `try check(c.s2br_polygon_loop_num_vertices(self.handle, try asIndex(loop_index), &out));` |
| `Polygon.loopVertex` | `try asIndex(loop_index)`, `try asIndex(vertex_index)` |
| `Polygon.loopVertexLatLng` | `try asIndex(loop_index)`, `try asIndex(vertex_index)` |

Each used to be a bare `@intCast`, and a caller who wrote down
`maxInt(usize)` killed their own process instead of getting an error. A
throwaway probe **compiled** (346, `exit 0`) and then **died at run time, exit
134** (`…-facade-index-before-run-347.log`):

```
thread 10211 panic: integer does not fit in destination type
…/zig/root.zig:956:51: in vertex (root.zig)
        try check(c.s2br_loop_vertex(self.handle, @intCast(i), &xyz));
…/s2-index-before.zig:6:20: in main
    if (loop.vertex(std.math.maxInt(usize))) |_| …
```

The interesting part is that the bridge *does* bound the index — it compares
`i` against `num_vertices` with an ordinary comparison — and never runs,
because the narrowing on the Zig side traps first. A check on the far side of a
conversion that can fail is not a check. This is §16's `max_cells` rule
arriving again in a different place, and `FORK-NOTES.md` records it as L21.

The fix is one private helper,

```zig
fn asIndex(i: usize) Error!c_int {
    if (i > @as(usize, @intCast(std.math.maxInt(c_int)))) return error.InvalidArgument;
    return @intCast(i);
}
```

at `zig/root.zig:145-148`, called by all five. `Cell.vertex` takes a `u8`,
cannot overflow a `c_int`, and was never in scope — which is the test for
whether a method is. **No public API and no native change**: still 104 facade
methods, 93 bridge declarations, identical signatures.

The same probe **after** the fix: compile `exit 0`
(`…-facade-index-after-compile-348.log`), run **`exit 0`**, printing
`oversized public vertex index rejected as InvalidArgument`
(`…-facade-index-after-run-349.log`). This is the only repair in this wave with
an after-run, and its scope is worth stating rather than rounding up: the
current `zig/root.zig` was linked against the **already-installed** native
archive, so it is evidence about the facade guard alone. It does not recompile
the bridge, it is not a package gate, and the three §37 repairs still have no
after-run.

## 40. A coupled correction went green, and this file retracted two wrong causes

§38 recorded a build failure and, in the same section, an explanation for it.
**That explanation is retracted, and so is the one that replaced it.**

The failure: `compile lib s2bridge` reported 119 diagnostics —
`-Wnullability-completeness` — from upstream headers reached through
`zig/bridge.cc`, first at `src/s2/s2builder.h:473:20`, on native Debug and
ReleaseSafe and four cross targets (313, 314, 316, 317, 319, 320).

§38 blamed the system-include arrangement in `build.zig` losing its
classification. This section then blamed all 119 on two C++ typos in the code
§37 had just added — `BooleanOp.kIntersection` and `BooleanOp.kUnion` instead
of `::`, at `zig/bridge.cc:1368` and `:1378` — on the reasoning that a
translation unit which fails to parse takes its whole include graph with it.

**Neither is established, and this section does not choose between them.** What
is actually recorded: those runs reported **117 header diagnostics alongside 2
errors in this repository's own C++**; the repair changed the header ownership
/ system-include roots **and** the `::` syntax **together**; and the next run
was green. No experiment varied one while holding the other fixed, so the
evidence establishes that the coupled change worked and **does not** establish
which half mattered, or whether the 117 were ever caused by the two syntax
errors. Both remain withdrawn; neither is promoted over the other, and "the
include classification is disproven" would be exactly as unfounded as "the
typos caused everything".

The lesson is in `FORK-NOTES.md` as **L22**, and it is the narrow one: a coupled
correction does not attribute a cause, and a plausible explanation is not a
diagnosis. This changelog asserted a cause confidently twice, and the second
assertion was as unfounded as the first. Both retractions are kept rather than
edited out, because the cost was real — a repair was scoped and queued against
each of them in turn.

A separate regression is fixed in a different place than it was first reported.
Six assertions in `tests.zig` compared a raw status against
`s2.c.S2BRIDGE_INVALID_ARGUMENT`, which `translate-c` emits as a signed `c_int`
constant while the call returns a `c_uint`-typed value; that comparison did not
compile (`…-corrected-native-releasesafe-durable-376.log`,
`…-tests-diagnostic-pipe-capture-392.log`). The fix is in the test file:
`tests.zig:1401` declares
`const invalid_argument: s2.c.S2BridgeStatus = s2.c.S2BRIDGE_INVALID_ARGUMENT;`
and those six assertions compare against it. The facade's `check` parameter at
`zig/root.zig:119` was **not** changed and is not the fix. **No ABI change**: the
C signature and every `S2BridgeStatus` value are exactly as they were, which the
green runs below confirm.

Also closed here: `build.zig.zon`'s `.paths` now names `.clang-format`,
`pyproject.toml` and `setup.py`, so the integrity record and the manifest agree
— the gap §38 reported as 923 `OK` and 3 missing. The package hash changed as a
result, and `zig fetch` is green on the new one.

## 41. Closed the two boundary holes, with their before-evidence

This section **supersedes §41 as first written**, which recorded two gaps a
further review had found. Both are fixed and gated; the before-evidence is kept
because the first was worse than the review expected.

* **`FromFacePos` native `face 0..5`.** The before-probe did not return a wrong
  status — it **died**: exit **-6** (SIGABRT) at
  `src/s2/s2cell_id.h:661] Check failed: is_valid()`, reached through
  `S2CellId::parent` on a face-6 id
  (`local://foundation-expansion-s2geometry-contract-boundaries-before-smoke-413.log`).
  The guard is now an ordinary comparison in the bridge at `zig/bridge.cc:346`
  and `:355` — `if (face < 0 || face > 5) return S2BRIDGE_INVALID_ARGUMENT;` —
  and in the facade, so both the raw C surface and the typed entry point refuse
  it, with the **raw out-parameter left unchanged on failure**.
  `FromFace`'s deliberate handling of faces 6 and 7, which upstream uses to
  produce an invalid id and which the facade documents, is **unchanged**; only
  `FromFacePos` is bounded.
* **the C count promise in `zig/bridge.h:107`.** The before-probe
  (`…-count-protocol-before-smoke-415.log`, exit 1) printed
  `invalid-cell status=1 count=7; null-polygon status=1 count=9` — an error with
  the count **retained**, which is not what a count-only call promises. A
  `Coverer` call that fails early on a polygon or cell now reports **count
  zero**, matching the header, and a new permanent test walks the raw sequence
  the promise is actually about — a valid count, then an invalid argument, then
  a valid count again, then a null handle — so the **state transition** is
  asserted and not just the final value.

Both guards are in this repository's own files. **No algorithm, ABI or
upstream-native change**, and no upstream byte was touched: `git diff` (268) and
the whole-tree Abseil comparison (286) are unaffected.

## 42. Two targets red against immutable dependencies, one optional mode unexercised

`check -Dtarget=aarch64-macos-none` stops in vendored Abseil at
`'CoreFoundation/CFTimeZone.h' file not found` (355, one error), and
`check -Dtarget=wasm32-wasi` stops in vendored Abseil at
`signal.h:2:2: error: "wasm lacks signal support…"`, 39 errors, with the mutex
and `<fstream>` failures behind it (358).

Both are red **against immutable dependencies** — vendored Abseil and the
platform's own headers and libc — and neither is a thing this fork may edit.
They are **not** an unfinished SDK checkout and **not** a pending gate: the SDK
is absent or complete, and the answer it gives is the answer. A green result
there needs a host with the capability, not a change here.

`-fsys=s2` is the one mode with no result, and the reason is that nothing is
installed for it: no machine in this workspace has an installed `libs2` or
Abseil. That is an **optional system-integration path**, not unfinished native
work, and it is recorded that way.

Finally, and separately: **no CI job has been run.** The two defects fixed in
`.github/workflows/verify.yml` — the C driver's Hilbert input built as an
ordinal where the bridge takes the raw 61-bit position, and the C++ consumer's
compile line missing `-fsized-deallocation` — are corrections to the workflow
file. The corrected C excerpt compiled and ran with exit 0 at 433/434, and the
C++ excerpt at 435/436, against the installed prefix. Those are local program
runs, **not** a CI job execution; no runner or job pass is claimed.

---

## Historical gate summary before the Abseil portability changes

Recorded from the driver's evidence set, with receipts, in
`local://foundation-expansion-evidence.json` and the logs it names. This fork
runs no gates; these are the driver's observations.

This was the earlier expansion-round verdict, not the current source/package
state. Uniform 45-test native rows, pristine Abseil comparison 286 and package
425/426 below are historical; later boundary runs reached 46 tests. Current
native and six-target source gates are §46; current Abseil delta is §45.
Final matrix/package statuses are driver-owned outside this package.

| Gate | Observed |
|---|---|
| `zig build test smoke install` (Debug, native) | **PASSED**, exit 0. `local://foundation-expansion-s2geometry-final-native-debug-393.log`: "Build Summary: 17/17 steps succeeded; 45/45 tests passed", `run test s2-tests 45 pass (45 total)`, `smoke success`, and `install absl` / `install s2` / `install s2bridge`. The whole graph is in this run — 153 Abseil units, 108 S2 units, the bridge, the translated header and the smoke program. |
| `zig build test smoke -Doptimize=ReleaseSafe` | **PASSED**, exit 0, **45/45 tests** and `smoke success`. `…-final-native-releasesafe-394.log`. Read the command literally: `test smoke` — this run **did not install**. 393 is the only installation evidence |
| `zig build check -Dtarget=x86_64-linux-gnu` | **PASSED**, exit 0, "Build Summary: 10/10 steps succeeded". `…-final-cross-x86_64-linux-gnu-397.log` |
| `zig build check -Dtarget=aarch64-linux-gnu` | **PASSED**, exit 0, 10/10. `…-final-cross-aarch64-linux-gnu-398.log` |
| `zig build check -Dtarget=x86_64-windows-gnu` | **PASSED**, exit 0, 10/10 — and the target where `-fsized-deallocation` was needed (§31). `…-final-cross-x86_64-windows-gnu-399.log` |
| `zig build check -Dtarget=riscv64-linux-gnu` | **PASSED**, exit 0, 10/10. `…-final-cross-riscv64-linux-gnu-380.log` |
| `zig fmt --check`, this fork's own eight source files | **PASSED**, exit 0, empty output. `…-driver-final-eight-sdk-own-zig-format-395.log` |
| `zig fetch` (materialised package) | **PASSED**, exit 0 — `s2geometry-0.14.0-2Klt8f9eBwEyMQKeHLiAUZ2h680ivy01LNFmKgfhHvsU`. Supersedes `2Klt8ad7…` (§325) and the original `IllegalFileTypeInPackage` (§261). `…-typed-final-filtered-package-fetch-396.log` |
| `sha256sum -c UPSTREAM.sha256` | **PASSED**, exit 0, all 926 records `OK`. `…-immutable-native-dependency-fixture-integrity-231.log` |
| `git diff --exit-code c24b368c… -- src LICENSE NOTICE CMakeLists.txt` | **PASSED**, exit 0, empty output. `…-pinned-native-pristine-diff-268.log` |
| Abseil vendored tree vs the pinned commit | **PASSED**, exit 0, **empty output**. `diff -qr` of the entire `vendor/abseil-cpp` against a reference extracted from a canonical bare clone at exactly `d38452e1ee03523a208362186fd42248ff2609f6` (clone 273; that commit's `git archive` digest `8b39fdb7c4a5d7ef0ee88b0b4eb3d23c77623d6f793579a5e0d0af7cf2ce6eaa`, 275). `…-abseil-entire-vendored-tree-pristine-286.log` |
| `zig build check -Dtarget=aarch64-macos-none` | exit 1 — **a platform barrier in vendored Abseil, not a fork defect**: `'CoreFoundation/CFTimeZone.h' file not found`, one error. Unchanged across every run; needs an macOS SDK. `…-closure-cross-aarch64-macos-none-355.log` |
| `zig build check -Dtarget=wasm32-wasi` | exit 1 — **a platform barrier**: `signal.h:2:2: error: "wasm lacks signal support…"`, 39 errors, with the missing `std::mutex` and `<fstream>` behind it. Unchanged. `…-closure-cross-wasm32-wasi-358.log` |
| `zig build consumer` | **PASSED**, exit 0, "10/10". `…-live-consumer-423.log`: the separate package resolves this one by path, builds the whole graph itself, runs, and prints its published golang/geo answers. The earlier `error: NeighborMismatch` (230) is history |
| installed C bridge consumer | **PASSED**, **71 numbered checks**. Latest: compile exit 0 (`…-latest-installed-C-compile-429.log`), run exit 0 (`…-latest-installed-C-smoke-430.log`). Earlier runs at 402/403; the original exit 17 on `check 17` (§239) is superseded |
| installed C++/Absl consumer | **PASSED**, **21 numbered checks**. Latest: compile exit 0 (`…-latest-installed-Cpp-Absl-compile-431.log`), run exit 0 (`…-latest-installed-Cpp-Absl-smoke-432.log`) |
| bounded-boundary probes, from outside the package | **PASSED**, all exit 0, under a 256 MB address-space limit. Compile `…-final-installed-boundaries-compile-406.log`, then 407 `children status=0 count=1152921504606846976`; 408 `short-buffer status=2 count=1152921504606846976`; 409 `nonunit constructor status=1 handle=(nil)`; 410 `unit bow-tie union status=1 out=(nil)`; 411 `unit bow-tie intersection status=1 out=(nil)`. These are the four source repairs answered from outside the package. **409 covers the constructor's bound on that input only** and is not proof that a boolean-typed build failure is impossible |
| `zig build test smoke install` (Debug, native), after the boundary guards | **PASSED**, exit 0. `…-boundary-closed-native-debug-417.log`: "Build Summary: 17/17 steps succeeded; 46/46 tests passed", `run test s2-tests 46 pass (46 total)`, smoke, install |
| `zig build test smoke -Doptimize=ReleaseSafe`, after the boundary guards | **PASSED**, exit 0, 13/13 steps, **46/46 tests**, smoke. **No `install` in the command.** `…-boundary-closed-native-releasesafe-418.log` |
| `zig build check` — four targets, after the boundary guards | **PASSED** each, exit 0, 10/10 steps. `…-boundary-closed-cross-x86_64-linux-gnu-419.log`, `-aarch64-linux-gnu-420.log`, `-x86_64-windows-gnu-421.log`, `-riscv64-linux-gnu-422.log` |
| `zig fmt`, this fork's own sources, after the boundary guards | **PASSED**, exit 0, empty output. `…-driver-post-boundary-eight-sdk-format-416.log` |
| `zig fetch`, current snapshot | **PASSED**, exit 0 — `s2geometry-0.14.0-2Klt8WOCBwFfUQlt-MA55F-8f7bo7bF9cgGyhEukOfSl`. Supersedes 396's hash. `…-boundary-closed-filtered-package-fetch-424.log` |
| the two boundary guards, **before** | `FromFacePos` on a face-6 id **aborted** — exit **-6** (SIGABRT) at `src/s2/s2cell_id.h:661] Check failed: is_valid()`, reached through `S2CellId::parent`, worse than the review predicted. `…-contract-boundaries-before-smoke-413.log`. Count promise: exit 1, `invalid-cell status=1 count=7; null-polygon status=1 count=9`, an error with the count retained. `…-count-protocol-before-smoke-415.log` |
| installed after-contract probes | **PASSED**, both exit 0. Compile `…-installed-after-contract-compile-427.log`; run `…-run-428.log` prints `invalid-cell status=1 count=0; null-polygon status=1 count=0` — the count promise holds — and `out-of-contract face=6 status=1 id=0x00000000deadbeef valid=1`: rejection reported, the caller's sentinel left **unchanged**, and that sentinel is itself a valid id. Not null, not invalid. This is a **constructor-bound** result; the boolean case is 410/411 and a different call site |
| materialised-package integrity | **PASSED**, exit 0, **926/926 `OK`** — the record and the manifest now agree. `…-current-filtered-integrity-425.log` |
| materialised-package consumer | **PASSED**, exit 0, "10/10". `…-filtered-consumer-426.log` |
| any `-fsys=s2` command | **NOT RUN**, and no installed `libs2` or Abseil was observed on any machine here. An optional system-integration path with nothing installed for it — not unfinished native work |

**46 tests now.** The count has moved twice: 39 originally, 45 after the six
permanent behavioural regressions for §37's three defects and §39's index guard,
and **46** since the count-protocol state-transition test was added. `46/46` is
the current result (417, 418); `45/45` (393, 394) is kept above as the earlier
statement about the tree before the boundary guards. Those added tests are what
make a green run evidence about the repairs rather than only about the
library. The runs also print seven upstream
`E`-level log lines — `s2latlng_rect.h:397 Invalid rect`, `s2loop.cc:212 Edge 0
is degenerate (duplicate vertex)`, and `s2polygon.cc:249 Shape 0 has one or more
edges with interior on the right` six times. Those are the *negative* tests
exercising exactly the rejected inputs; the runs are green and the log is not a
fault.

## 43. Record embedded source licences separately from the project labels

The retained-source audit found Apache-2.0 headers followed by BSD-3-Clause
text in `src/s2/util/gtl/{dense_hash_set,densehashtable,hashtable_common}.h`.
Those headers participate in compiled S2 code and are installed. Abseil's
compiled CCTZ header `tzfile.h` has Arthur David Olson's public-domain notice;
retained timezone test data has its own public-domain declarations. The
Apache-2.0 spinlock test source separately credits Bob Jenkins' public-domain
`lookup2` hash and is not compiled.

`NOTICE.md` now itemises these paths, distinguishes compiled from retained
test material, and reproduces the BSD notice for accompanying materials.
Neither native tree nor its licence text was edited. The fork-authored files'
licence remains owner-unassigned; an upstream project label does not grant
rights over them.

## 44. `zig build test` exposes its run for every target, and added `cross-test.profile.sh`

`build.zig` added the test run only when `target.query.isNative()`, and dropped
to the compile step otherwise. That predicate is narrower than "this machine
can execute the binary": `Target.Query.isNative()` in the pinned compiler is
`isNativeTriple() and ofmt == null`, and `isNativeTriple()` requires `cpu_arch`,
`os_tag` and `abi` all to be **null** (`lib/std/Target/Query.zig:392-398`). An
explicit `-Dtarget=x86_64-linux` is therefore not native even on an x86_64
Linux host.

Observed 2026-10-02 on `gruenau8`, Zig 0.16.0, through `cross-test`, run
`20261002-033134-17908-30770`, receipt
`/home/tmp2/gertullj/scratch/foundation-libs/cross-test-01a0f400/before/s2geometry/cross-test-summary.json`.
It covered one target, `x86_64-linux`, with `target_jobs` 1,
`jobs_per_build` 4 and `build_timeout_seconds` 1800, and its recorded
`profile` is the empty string — the harness had loaded none, which is what
`--no-profile` leaves in the summary. Its result: exit **1**, `build` pass exit
0, `run` fail, `tests` null, reason `no_test_results`, 500.96 s wall. The build
log prints
`Build Summary: 9/9 steps succeeded`, `test success` and
`compile test s2-tests Debug x86_64-linux success 873ms` — and no `run` line at
all. Every object compiled; no test executed.

The guard is gone from both test graphs, the bundled one and `-fsys=s2`. Each
now builds its run artifact unconditionally and keeps `has_side_effects = true`.
Whether a foreign binary can execute here is the build runner's answer, not the
build script's, and `std.Build.Step.Run` is the seam. One clarification this
entry originally got wrong and that is corrected here: with no runner, `std.Build`
does **not** silently skip. `failForeign`
(`lib/std/Build/Step/Run.zig:2753-2777`) returns `error.MakeSkipped` only when
the run step sets `skip_foreign_checks`; otherwise it calls `run.step.fail`,
naming the binary, the foreign triple, the host triple and the flag to use. It
is the **harness's** build runner that classifies a target it has no runner for.
This package sets neither `skip_foreign_checks` nor anything equivalent.
Offering the run unconditionally is what lets the published 53-platform matrix
report an executed Zig API test for a target with a runner, and a compile-only
result for one without, instead of never executing anything.

The six-target `check` matrix is **not** touched. `addCheck` attaches
`&addTests(...).step`, the compile step, and never had a run artifact; it
remains the fast compile-only baseline.

New file `cross-test.profile.sh`, named in `build.zig.zon`'s `.paths` so a
materialised package carries it. It is ordinary Bash variable definitions and
nothing else:

* `CROSS_BUILD_STEP=test` — the standard build mode, stated in the package.
* `CROSS_BUILD_JOBS=4` and `CROSS_BUILD_TIMEOUT=1800` — defaults for a graph of
  153 Abseil plus 108 S2 translation units. The driver's own `--build-jobs`
  and `--build-timeout` still override them.

No `CROSS_MATRIX` and no `TARGETS`: the full published 53-platform Zig 0.16.0
tier table applies. No `-Doptimize`: the gate is the default Debug build. No
`cross_build_command`/`cross_artifact` hooks, no runner policy, and no path to
any machine. `NOTICE.md` lists it as fork-authored with **no licence
asserted**.

**HISTORY at this entry's first landing:** the unconditional-run/profile change
itself touched no native source and was not yet gated. Later full-matrix
attempts and the four separately authorised Abseil changes are recorded below.
The macOS CoreFoundation and WASI capability failures were explicit *then*; §48
records the real WASI provider that replaced the bundled one, and §53 records
the CoreFoundation framework declaration.

## 45. Bounded Abseil portability corrections, not algorithm substitutions

The first full 53-platform sweep observed **18 pass, 22 fail and 13
build-only**. Native/core algorithms and all independent fixtures were retained.
Observed architecture/link failures justified four native-file corrections,
which is **the deviation set at this entry's revision**:

* `absl/base/internal/direct_mmap.h`: real Linux Hexagon `mmap2`, with
  fixed 4096-byte syscall offset units.
* `absl/debugging/internal/stacktrace_powerpc-inl.inc`: PowerPC32 musl
  embedded `gregs`, retaining the existing glibc/PowerPC64 paths.
* `absl/debugging/internal/examine_stack.cc`: real hosted Hexagon/PPC32
  musl register-context fields.
* `absl/log/internal/conditions.h`: hosted Linux Hexagon gets `_exit`
  from the existing `unistd.h` path.

Each file carries a prominent change notice; `UPSTREAM.sha256` keeps pristine
and current digests. At this entry's revision the whole-vendor diff gave exactly
those four differences and no extra/missing paths (exit 1, **not** a pristine
pass), and the workflow's exact-four-file byte/change-notice guard passed
locally; no whole CI job was executed. Receipt:
`local://foundation-cross-test-s2-approved-vendor-diff.json`.

**Superseded in scope, not withdrawn.** §51 and §52 added three more Abseil
deviations — the LowLevelAlloc WASI backend and the cctz feature-test exclusion
— so the current Abseil delta is **seven** paths. §53 is build configuration
only and changes no vendored byte. The current provenance statement is
`local://foundation-portability-canonical-source-provenance.json`:
`abseil_difference_count = 7`, `s2_difference_count = 1`,
`extra_missing_paths = false`, every license prefix unchanged and a change
notice on all eight. The four-path guard above is scoped history, and it has
not been re-executed over the wider set.

The mmap correction has failing-before/passing-after semantic evidence:
byte-offset and `AT_PAGESZ`-unit variants fail; real libc `mmap` and DirectMmap
both read `B` at offset 65536 on a 65536-byte-page Hexagon runner using fixed
4096-byte syscall units. The retained probe and result are
`local://foundation-cross-test-hexagon-mmap-proof.cc` and the diagnostic probe
in `local://foundation-cross-test-evidence.json`.

Build corrections use upstream facilities only: link real Windows `dbghelp`,
and select `ABSL_USE_UNSCALED_CYCLECLOCK=0` for OpenBSD PowerPC/PowerPC64 on
all three C++ modules. The latter uses real `steady_clock`, not invented CPU
frequency or a substitute `sysctl` value. All 108 S2 and 153 Abseil units stay.

## 46. Driver-owned gates and package closure, at the revision they observed

**At this entry's revision**, on the then-current source, native Debug
test/smoke/install passed **46/46**, 17/17 steps; ReleaseSafe test/smoke passed
**46/46**, 13/13; the source consumer passed 10/10. Those receipts are
`local://foundation-cross-test-final-native-s2geometry.json` and
`local://foundation-cross-test-final-s2geometry-native-{Debug,ReleaseSafe,consumer}.log`,
and the six-target compile-only baseline was **four passes, two failures** at
`local://foundation-cross-test-final-baseline.json`.

**None of that is a current result.** §48–§55 changed the source under those
gates, and no whole-tree gate has been re-run since. The rows above are kept
because their receipts are evidence; §55 is the current status.

The full 53-cell result lives in
`FORKS.json.cross_test_wave.libraries.s2geometry` and
`local://foundation-cross-test-final-current-s2geometry.json`, and is never
replaced by C smoke, partial coverage or a compile-only success called a pass.
Final filtered fetch, source/fetched integrity, identical profile, complete
`.paths` file closure and real materialised-consumer status live in
`FORKS.json.cross_test_wave.materialized_packages.s2geometry` and
`local://foundation-cross-test-package-regression.json`. Final identities stay
outside this package: documentation bytes contribute to their identity.

## 47. Completed the per-file attribution and integrity-exclusion inventory

The record now names omitted Abseil test, benchmark, testing-helper and CCTZ
timezone-fixture families explicitly; they remain retained, not compiled or
read by this SDK. The compiled `crc/internal/crc.cc` attribution to Andrew
Kadatch and Bob Jenkins is itemised in `NOTICE.md`, under the file's existing
Apache-2.0 terms. No separate licence for their cited method is invented.
**At this entry's revision** the record carried 926 data records and four native
deviations, all executable inputs unchanged, and that inventory was not
disturbed by it. §55 records the current 927 records and the 1 + 7 deviation
set; final package status remains external to these identity inputs.

## 48. Gave `wasm32-wasi` a real installed WASI SDK 34 provider

`build_support/wasi_provider.zig` and the `-Dwasi-sysroot=<path>` build option.
That option is **this package's own**, added by this repair as an ordinary
`b.option([]const u8, "wasi-sysroot", …)`; it is a new **SDK-specific**
installed-sysroot option, not a compiler option, and it is the only new build
option here. `--zig-lib-dir` (§49) is different in kind: an **existing compiler
standard option**, used as-is, with no additional custom standard-library
option.

The bundled Zig libc++ was being asked to supply facilities it does not have;
this entry names an **already-installed** WASI SDK 34 sysroot with the
**WASIp1-threads** ABI instead, and uses it for the whole 261-unit closure. That
SDK is linked, never vendored or redistributed.

The provider reads exactly six locations out of that sysroot:
`include/wasm32-wasip1-threads`, `include/wasm32-wasip1-threads/eh/c++/v1`,
`include/c++/v1`, `lib/wasm32-wasip1-threads`,
`lib/wasm32-wasip1-threads/eh` and the generated `wasi-libc.conf`. Headers and
archives come from **one** sysroot, and the C++ runtime is the SDK's own:
`libc++.a`, `libc++abi.a` and `libunwind.a` are linked by object file with
`link_libcpp = false` on every WASI module, `-nostdinc++`, `-fwasm-exceptions`
and `-mllvm -wasm-use-legacy-eh=false`, so Zig's bundled libc++ is never mixed
in. The three archives are added exactly once, on the facade module.
`libwasi-emulated-signal.a` and `libwasi-emulated-getpid.a` are linked as well —
both are the SDK's own **documented emulation**. `getpid` exists only because
Zig 0.16's libc-linked nonsecure RNG fallback references it; without it the
runtime refuses the module with `unknown import: env::getpid has not been
defined`. It is not a host PID, this package offers no independent process
namespace on WASI, and the signal library is not POSIX signal semantics.

The target also gains the atomics, bulk-memory, exception-handling,
reference-types and multivalue CPU features, and the shared-memory link ABI:
`import_memory`, `export_memory`, `shared_memory` and `max_memory = 256 MiB`,
because a WASIp1 thread spawn instantiates the module again and must reach the
**same** linear memory.

Every module this graph builds for `wasm32-wasi` is `single_threaded = false`,
decided in the single function `Provider.configureModule` rather than at
individual call sites. That is an **ABI requirement**, not a preference: Zig
0.16's `std.c` `errno` on `.wasi` is not the SDK's `__errno_location()`, so a
module left at the target's single-threaded default compiles its own
thread-local. Measured single-threaded before the fix:
`sdk_errno=28 zig_errno=0 sdk_addr=0x1000000 zig_addr=0`, run exit 86
(`local://foundation-portability-wasi-sdk-errno-single-proof.json`). A null
`Module.single_threaded` emits no flag at all
(`lib/std/Build/Module.zig:546`), so a module left unset keeps the default while
its siblings are told otherwise.

Without `-Dwasi-sysroot`, a `wasm32-wasi` compile fails with a message naming
the missing provider and stating that no core sources are omitted. Nothing is
downloaded at build time, no unit is dropped, no diagnostic is suppressed and no
header is stubbed. **Observed** with the provider installed: all three archives
compile, link and install; `run test s2-tests 46 pass (46 total)`; the
standalone consumer **compiled and installed but was not run**; and a separate
installed S2 C++ consumer program really did execute, printing
`real S2 C++ consumer: decimal_sign_chunk_boundaries=5 invalid_inputs=2
two_threads=2 allocation_cycles=128 outstanding_delete=refused
final_delete=reclaimed`. The consumer's `consumer package success` is the outer
build step succeeding, never an inner program's execution (§54). Receipts
`local://foundation-portability-s2-wasi-corrected-sdk-gates.log` and
`local://foundation-portability-s2-wasi-installed-cpp-proof.json`. The separate
facility probe on the same sysroot printed
`real full C++ provider: counter=10000 file=42.5 bad_alloc=1 cleanup=1`
(`local://foundation-portability-complete-cxx-provider-proof.json`), whose own
`not_proven` field excludes the S2 source graph and is not used as if it did
not.

### 48a. UB still traps on that provider

`Provider.configureModule` selects `sanitize_c = .trap` for WASI. Zig 0.16's
UBSan runtime emits a one-argument `nonnull_return_v1` Wasm signature the
runtime does not match; turning detection **off** would have removed real
detection, so the trap is used instead. **Observed**: a mixed C++ nonnull-return
violation reached `cpp_nonnull` and died with a real Wasm `unreachable` trap,
exit **134** (`local://foundation-portability-wasi-ubsan-sdk-closure-proof.json`).
The trap is retained; only the mismatched runtime is not.

### 48b. The runtime requirement: one tested version, and no global tool changed

Executing a `wasm32-wasi` module needs a Wasmtime that still supports WASIp1
threads and standard Wasm exceptions. **46.0.3** (`c5569e6aa`, published
2026-08-20) is the only runtime provisioned and actually exercised here, with
`-Sthreads=y -Wexceptions=y -Wshared-memory=y -Wthreads=y`; it is the only one
with an observation behind it. Two further facts are recorded and nothing is
built on them: 46.0.3 prints a deprecation warning that `-Sthreads` becomes a
hard error in **47.0.0**, and **Wasmtime 49 and later dropped the threads
feature** this provider needs.

**A working range is deliberately not claimed.** A deprecation warning is not
evidence that the remaining flags and this module still work on a release
nobody ran, so "46, 47 or 48 works" would be a compatibility claim with no
observation under it. Any broader range is a hypothesis until a run makes it
one. No global tool on any machine was edited to obtain a runtime, and none
needs to be.

## 49. Carried a patched copy of the Zig 0.16 standard library, selected with `--zig-lib-dir`

Stock Zig 0.16.0 **does not compile** a threaded, libc-linked `wasm32-wasi`
build. Both failures are observed in one run, exit 1
(`local://foundation-portability-wasi-sdk-errno-multi-compile-failure.json`):

* `lib/std/Io/Threaded.zig:959:50: error: expected type 'i64', found 'u64'` —
  the wasm `memory.atomic.wait32` timeout assigns a `u64` nanosecond count into
  an `i64`, where any negative value means *wait indefinitely*;
* `lib/std/heap.zig:16:74: error: unimplemented` — `WasmAllocator` is
  `@compileError("unimplemented")` for `!builtin.single_threaded`, so selecting
  it as `page_allocator` is a hard compile failure, not a weaker allocator.

`build_support/wasi_stdlib.patch` is the whole repair, in two hunks:

1. a finite `timeout_ns` is saturated to `maxInt(i64)` before conversion, so a
   finite timeout can never wrap into a negative — that is, indefinite — wait,
   and `@intCast` cannot trap on an absurd duration. `null` still means "no
   timeout" and is still `-1`. Only the wasm branch of
   `Thread.futexWaitInner` changes; the parking-futex branch and every native
   OS branch are byte-identical to stock.
2. `page_allocator` selects the real `c_allocator` for
   `arch.isWasm() and os.tag == .wasi and link_libc and !single_threaded`,
   instead of instantiating `WasmAllocator`. `c_allocator` is stock Zig over the
   SDK's own thread-safe malloc/realloc/free and already satisfies the whole
   `Allocator` contract including arbitrary alignment and `OutOfMemory`; Zig's
   `have_posix_memalign` is false for `.wasi`, so on this target it applies its
   manual alignment strategy over that same real allocator. Emscripten and every
   other non-`.wasi` wasm OS keep the upstream selection even when threaded and
   libc-linked, so the "unimplemented" diagnostic still honestly reports the
   genuinely unsupported threaded non-libc case, `WasmAllocator` is a lazy
   declaration this path never analyses, the `root.os.heap.page_allocator`
   override still wins, and no native `PageAllocator` path changes.

It is applied by the **user**, to a copy, with the compiler's existing standard
option. `ZIG_ROOT` is the **directory** holding the pinned 0.16.0 `zig`
executable beside its `lib/`; it is deliberately a different name from the
compiler binary, which in this workspace is normally the absolute path of the
executable itself:

```sh
ZIG_ROOT=/path/to/zig-0.16.0-install   # the DIRECTORY: zig and lib/ inside it
STDLIB_COPY=/path/to/zig-wasi-stdlib   # a fresh directory you own

test -x "$ZIG_ROOT/zig" || { echo "no compiler at $ZIG_ROOT/zig"; exit 1; }
test -d "$ZIG_ROOT/lib/std" || { echo "no stdlib at $ZIG_ROOT/lib"; exit 1; }

mkdir -p "$STDLIB_COPY"
cp -a "$ZIG_ROOT/lib" "$STDLIB_COPY/lib"      # the complete lib tree
patch -p1 -d "$STDLIB_COPY/lib" < build_support/wasi_stdlib.patch

"$ZIG_ROOT/zig" build --zig-lib-dir "$STDLIB_COPY/lib" \
  -Dtarget=wasm32-wasi \
  -Dwasi-sysroot=/path/to/wasi-sysroot-34.0 test
```

`cp -a` copies the whole `lib` tree, so both patched files exist before the
patch runs; the stock installation is never written to. `patch -p1` skips the
plaintext prologue above the first `--- a/std/heap.zig` hunk; that prose is
documentation for a reader, not patch input, and `git apply -p1` accepts the
file identically. No build-time download, no shim, no `errno` workaround and no
`stdout` workaround is involved, and **the stock compiler beside the copy is
unchanged**. `--zig-lib-dir` is the compiler's existing option used as-is; the
one new build option in this repair is the package's own SDK-specific
`-Dwasi-sysroot`, a different kind of thing.

## 50. Corrected one S2 source file for the ABI-2 libc++ iterator type

`src/s2/util/math/exactfloat/bignum.cc` — the **only** change this fork has
made to `src/`. `std::from_chars` takes character pointers, and the ABI-2
`std::string_view::const_iterator` this package links on `wasm32-wasi` is a
wrapped iterator with no implicit conversion to `const char*`, so the file did
not compile there. The repair passes `s.data()` and `s.data() + s.size()`,
retaining the existing sign arithmetic, chunking and error checks. The Apache
header and the license prefix are unchanged and a prominent change notice was
added, as Apache-2.0 requires. **This is the one S2 path in the canonical
comparison**, `s2_difference_count = 1`, pristine
`e00b9e178322bba37a8f3352937c94b9c3a295ee87c5eeecf3e4fa553f17d6f3` → current
`89a2379f0aa5c3c1ac20a6c98b18718bf637d825d249da2befa5091943fdad16`
(`local://foundation-portability-canonical-source-provenance.json`). No
algorithm, fixture, tolerance or API changed.

## 51. Gave Abseil's LowLevelAlloc an honest WASI backend

`vendor/abseil-cpp/absl/base/internal/low_level_alloc.{h,cc}` — two of the seven
current Abseil deviations, both with prominent change notices and unchanged
Apache-2.0 headers. Upstream takes each arena's backing region from `mmap`,
which WASI does not have, and the `ABSL_HAVE_MMAP` probe there is false for a
reason unrelated to whether the SDK has an allocator. Under `#ifdef __wasi__`:

* the region comes from `posix_memalign(&new_pages, arena->pagesize,
  new_pages_size)` **with the arena spinlock released**, and is published into
  the free list only after the lock is retaken — so the SDK allocator is never
  re-entered from inside an Abseil lock;
* each region header carries a `region_base` pointer in the header's existing
  alignment slot, so no per-client cost is added. A split copies it to the
  remainder, and `Coalesce` merges only when the two `region_base` values are
  equal: **coalescing can never cross two backing allocations**, because such a
  merge would later hand `free()` an interior pointer the allocator never
  returned. `Next()` asserts the same invariant with an ordinary comparison;
* `DeleteArena` releases each region with `std::free(region)` after asserting
  `region->header.region_base == region`, i.e. that the arena is back to exactly
  its original allocation. The existing refusal to delete a non-empty arena
  (`allocation_count != 0`) is unchanged.

Native header layout and native code are untouched outside those guards. No
asynchronous-signal-safety is claimed — upstream already records
`ABSL_LOW_LEVEL_ALLOC_ASYNC_SIGNAL_SAFE_MISSING` for WebAssembly and this does
not alter that — and no performance claim is made. No emulated file-mapping
shim was introduced.

## 52. Extended the cctz feature-test exclusion to NetBSD

`vendor/abseil-cpp/absl/time/internal/cctz/src/time_zone_format.cc`, the seventh
current Abseil deviation. Its
`#if !defined(_XOPEN_SOURCE) && !defined(__FreeBSD__) && !defined(__OpenBSD__)`
guard omitted `__NetBSD__`, so on NetBSD the translation unit opened with
`_XOPEN_SOURCE 500` before any libc header reached `sys/featuretest.h`;
`featuretest.h` then took that arm and set `_POSIX_C_SOURCE 199506L`, hiding
every `locale_t` / `*_l` / `MB_CUR_MAX_L` declaration and reproducing the
observed `bsd_like.h:51` error. The repair adds `&& !defined(__NetBSD__)` to
that one guard. It is the **only** major-feature-test-macro definition in the
vendored Abseil closure, and there is none in `s2geometry/src`, so no other
translation unit is affected. Preserving `_XOPEN_SOURCE` rather than suppressing
it keeps `strptime`, which `time_zone_format.cc` needs and NetBSD declares under
`_NETBSD_SOURCE`. **Observed**: all nine corrected NetBSD targets build
(`ALL_9_COMPLETE_SDK_BUILDS_PASSED`,
`local://foundation-portability-netbsd-targeted.json`); runtime is unavailable
on this host, so **0 executed pass claims** are made.

## 53. Declared the real CoreFoundation framework, and the SDK's signal emulation

Every bundled C++ module on a Darwin target now links `CoreFoundation`, which
is what CCTZ's Apple default-timezone implementation actually uses
(`absl/time/internal/cctz/src/time_zone_lookup.cc:22-23`). Before this the
framework was used and never declared. **That is the whole change, and it is
not a macOS result**: no Mac and no licensed Apple SDK are available on this
Linux host, no Apple SDK was downloaded or used, no macOS cell was run after the
declaration, and no CoreFoundation header, type or prototype was fabricated.
macOS stays an explicit platform boundary with no fake proof.

The Abseil module is compiled with `-D_WASI_EMULATED_SIGNAL=1` for `wasm32-wasi`
and linked against the SDK's `libwasi-emulated-signal.a`, which is the shipped
synchronous signal/raise provider. Abseil already excludes the asynchronous
WASI signal facilities it cannot support; nothing was disabled to get there.

## 54. Taught the standalone consumer the WASI final-link contract

`consumer/build.zig`. Native stays module-only and states nothing. On
`wasm32-wasi` it does exactly three more things and re-declares nothing:

1. forwards `-Dwasi-sysroot` into `b.dependency`, so the library and the
   executable cannot end up built against different providers;
2. reads `single_threaded` off `dep.module("s2geometry")` rather than restating
   it, and takes the root's target from `s2_module.resolved_target`;
3. copies `libc_file`, `import_memory`, `export_memory`, `shared_memory` and
   `max_memory` off `dep.artifact("s2bridge")`, because `std.Build` holds those
   on `Step.Compile` and no module import propagates them.

It writes **no** include path, names **no** C or C++ header, links **no**
`.a` file and hardcodes **no** sysroot path: `s2bridge` is the artifact that
already carries the provider's settings, so copying from it keeps one source of
truth. `zig build consumer` also forwards `--zig-lib-dir`, `-fwasmtime` and the
other executor switches to the nested build, using the compiler this build
resolved. **Observed — INSTALL ONLY, NOT RUN**: the consumer package compiled
and installed on `wasm32-wasi` under the SDK provider (2m,
`local://foundation-portability-s2-wasi-corrected-sdk-gates.log`). Its
`consumer package success` is the **outer** build step succeeding. At that
revision the nested step still chose `install` over `run` because the old
`query.isNative()` predicate is false for `-Dtarget=wasm32-wasi` on this host,
so **no Zig consumer runtime has been proved on this target**. The source has
since switched that decision to the resolved-target predicate and forwards
`-fwasmtime`; that correction is unobserved, so the runtime stays
PENDING-VERIFICATION. An outer step's success is never read as an inner
program's execution.

## 55. Current repair-wave status: every whole-tree gate is PENDING

This entry exists so no earlier entry in this file can be read as a current
result. §§48–54 changed the compiled source, the build graph and the provider
contract, so **every** whole-tree gate over this package has to be re-run, and
none has been:

| Gate | State |
|---|---|
| native Debug `test smoke install` | **PENDING** — the 46/46 receipt is pre-wave |
| native ReleaseSafe `test smoke` | **PENDING** — the 46/46 receipt is pre-wave |
| native source `consumer` | **PENDING** — the 10/10 receipt is pre-wave |
| six-target `check`, WASI cell given its two providers | **PENDING** |
| `wasm32-wasi` `smoke` | **FAILED, not re-run** — exit 134 at `Io.Threaded.fileWritePositional`; the full cell is therefore not green |
| `wasm32-wasi` consumer **runtime** | **PENDING** — the package only compiled and installed; the corrected run predicate and forwarded `-fwasmtime` are unobserved |
| full 53-platform `cross-test` matrix | **PENDING** — 20/14/19 and 18/22/13 describe the previous revision |
| filtered fetch, integrity replay, materialised consumer | **PENDING** |

Observed for the current wave, and deliberately narrower than a green cell:

* `wasm32-wasi`: the complete 261-unit closure compiles and links under the SDK
  34 provider; **46/46** public tests pass; all three archives install; the
  standalone consumer **compiles and installs but was not run**; a separate
  installed S2 C++ consumer program really did execute its decimal/sign/chunk
  boundaries and two-thread arena work; UB still traps at exit 134 under
  `-fsanitize-c=trap`.
* `wasm32-wasi` **`smoke` FAILED**, exit 134, `panic: integer does not fit in
  destination type` at `Io.Threaded.fileWritePositional` ← `Io.Writer.flush` ←
  `smoke.main`, in the same run. That is recorded as an observed failure of the
  current tree. `smoke.zig`'s output is unchanged, **no `Writer` streaming
  workaround was introduced**, and no TLS/`errno` workaround was added. Until the
  driver re-runs the target there is **no full `wasm32-wasi` green claim**.
* macOS: no provider, no run, no result.

Integrity: `UPSTREAM.sha256` now carries **927** records — the previous 926 plus
`build_support/zig-0.16-LICENSE.txt`, the pinned compiler's MIT (Expat) terms
copied verbatim beside the patch that edits upstream Zig source. Across the eight
SDKs the total moves 1518 → 1519; this package is the only one that changed.
The canonical source comparison **PASSED** at 1 S2 path + 7 Abseil paths with no
extra and no missing path
(`local://foundation-portability-canonical-source-provenance.json`). Every
receipt in §§45–47 predates this wave and is kept as history at its own revision.

Licence and terms: the WASI SDK sysroot and CoreFoundation keep their own
providers' terms — nothing here is vendored, redistributed or relicensed, and no
compatibility with either is asserted. `build_support/wasi_stdlib.patch` is
fork-authored and carries the unchanged upstream Zig context it edits;
`build_support/zig-0.16-LICENSE.txt` is the compiler's terms copied verbatim, and
no licence is invented for the patch itself. `cross-test.profile.sh`,
`wasi_provider.zig` and `wasi_stdlib.patch` are fork-authored with **no licence
asserted**. Package identity stays outside this package, in the root ledger.

Runtime scope: **wasmtime 46.0.3 is the only runtime provisioned and exercised**
in this wave. The `-Sthreads` deprecation into 47.0.0 and the removal of
threads in 49+ are recorded as facts about Wasmtime, not as a tested version
range; no 47 or 48 execution or compatibility is claimed here.

Option provenance: `-Dwasi-sysroot` is a **new, SDK-specific option belonging to
this package** (`b.option([]const u8, "wasi-sysroot", …)`). `--zig-lib-dir` is the
**compiler's existing standard option**, used as-is; no additional custom
standard-library option exists.

Object provenance: the 108 S2 and 153 Abseil translation units come from `src/`
and `vendor/abseil-cpp/`, and the bridge from `zig/bridge.cc`. The C and C++
**runtime** is a separate provider — Zig's own bundled libc/libc++ on non-Darwin
targets, the external installed SDK's on `wasm32-wasi` and the Darwin targets —
and is linked, never vendored by this package.

## 56. Gave the nested consumer build the caller's own arguments

`zig build consumer -- …` forwarded everything except the arguments. The outer
step passed its own bookkeeping — the target triple, the CPU, the optimize mode,
`-fsys=s2`/`-fno-sys=s2`, `-Dwasi-sysroot`, `--zig-lib-dir`, the executor
switches, `--libc-runtimes`, `--cache-dir` — and dropped the one thing the caller
typed, so the program received whatever `b.args` happened to be in the *nested*
build, which was nothing. An argument the consumer accepts on the outer command
line and never sees is the outer build reporting a narrower check than the one
it was asked for.

`build.zig:948-958` closes the handover, and the two facts around it are
load-bearing:

```zig
if (b.args) |args| {
    run.addArg("--");
    run.addArgs(args);
}
```

* The handover exists on the other side and is one line:
  `consumer/build.zig:87-88` — `const run_exe = b.addRunArtifact(exe);` and then
  `if (b.args) |args| run_exe.addArgs(args);`. That is the only place the
  consumer package's arguments become the program's, so they have to be
  forwarded there; `b.args` everywhere else is the *nested* build's own.
* The `--` is emitted only when there are arguments, and it follows every
  forwarded option. The build runner ends its own option parsing at `--` and
  puts the rest in `b.args` (`lib/compiler/build_runner.zig:428-430`), so a
  program argument placed before it would be read as a build option.

Nothing here assembles the program's arguments: everything before the `--` is
this package's negotiation with the nested build, everything after it is the
caller's, and the two cannot be confused for each other.

**PENDING-VERIFICATION.** No gate has run this step with a caller argument over
the corrected source. The pre-wave `consumer` receipt (10/10, exit 0) predates
the change, and the `wasm32-wasi` result in §54 is an install-only run of a
different target; neither is evidence about the forwarding.

## 57. Made `-Dtarget=native` narrow `check` to one target

`zig build check -Dtarget=native` compiled all six required targets. The option
was named, this package's own documentation promised exactly one, and the build
did the other thing.

The cause is that "the caller named a target" and "the resolved query is native"
are two questions, and only the second was being asked.
`standardTargetOptionsQueryOnly` (`lib/std/Build.zig:1473`) returns the empty
query when none of `-Dtarget`, `-Dcpu`, `-Dofmt` and `-Ddynamic-linker` was
given (`:1495-1496`), and `-Dtarget=native` parses the literal at `:1498` into
**that same empty query**; `resolveTargetQuery` (`:2704-2707`) then hands back
`b.graph.host` for both. `Query.isNative` (`lib/std/Target/Query.zig:396-398`) is
true for `-Dtarget=native` for exactly that reason, so a matrix branch guarded
on it took the named host with the unnamed default.

`build.zig:133-138` asks the question the option actually poses, and `:235-239`
branches on that answer instead:

```zig
fn target_was_named(b: *const std.Build) bool {
    for ([_][]const u8{ "target", "cpu", "ofmt", "dynamic-linker" }) |name| {
        if (b.user_input_options.contains(name)) return true;
    }
    return false;
}
```

`b.user_input_options` holds every `-Dname=value` the caller passed
(`lib/std/Build.zig:1167`, filled by `addUserInputOption` at `:1533-1541`), and
the standard library registers each of those four options under exactly these
names (`:1474-1494`) — the four names are its own test for "nothing was named"
at `:1495-1496`. So this asks the same question that line asks and not a
broader one: `-Dcpu=` on its own still narrows `check` to the host, which the
matrix branch would not do, and `-Dofmt=` and `-Ddynamic-linker=` count as
naming a target for the same reason the standard library counts them. As a
dependency the table holds whatever the dependent forwarded through
`b.dependency`, which is the target it asked for — the same answer by the other
route. The branch belongs to the bundled graph alone: `-fsys=s2` returns before
it (`:159-162`) and compiles the selected target in its own `check` instead
(`:806-811`), for the reason §59 gives. No target was added to or removed from
the six-target matrix by this change.

**PENDING-VERIFICATION.** No `check` gate has been run since the branch
changed, in either direction: the six-target matrix and the named-target
narrowing are both unobserved over this source.

## 58. Made the consumer step ask the executor question `Step.Run` asks

`zig build consumer` decided "run, or only install" with
`std.zig.system.getExternalExecutor` and read every answer as a yes. On a
foreign GNU-libc target reached through `-fqemu` that answer was a promise the
nested build could not keep: `Step.Run` asks the same predicate and then applies
a second gate of its own, and this step did not carry it. The step would choose
`run`, and the run would fail on a directory this build never had.

`build.zig:987-1018` is the predicate; two fields of its options struct are the
whole correction:

```zig
.qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
…
.qemu => !(candidate.isGnuLibC() and b.libc_runtimes_dir == null),
```

`Run` fills `qemu_fixes_dl` from `need_cross_libc`
(`lib/std/Build/Step/Run.zig:1264-1266`) and `b.libc_runtimes_dir` (`:1269`),
calls `getExternalExecutor` (`:1268`; the function is
`lib/std/zig/system.zig:42`, its options struct `:30-38`, where `qemu_fixes_dl`
defaults to `false` at `:36`), and then — **after** the predicate has already
said yes — its QEMU arm returns `failForeign` for a `need_cross_libc` target
that was given no `--libc-runtimes` (`:1294-1311`, the refusal at `:1310`;
`failForeign` is `:2753-2777` and names the foreign and host triples in its
message, `:2764-2771`). No `allow_*` option can carry a refusal that is made
after the predicate, which is why the answer on that arm is not simply `true`.
This step installs the consumer instead, which is compile evidence and never an
execution result. Every other QEMU case is untouched — a foreign architecture
whose libc needs no cross runtime, a musl consumer among them — and still runs.

`--libc-runtimes` now travels to the nested build (`build.zig:939`, the runner's
own option at `lib/compiler/build_runner.zig:323-325`), beside the executor
switches (`:934-938`, from `:388-407`). Without that forward the predicate would
read the outer graph's runtimes directory and the run would read the nested
graph's empty one, and the two would disagree about the same target.

`hostCanExecute` answers only which sub-command to run. The run itself remains
`Step.Run`'s decision, the other `allow_*` gates (`Run.zig:1277`, `:1291`,
`:1317`, `:1325`) are carried rather than re-implemented, and this step claims
no result it did not observe.

**PENDING-VERIFICATION.** No consumer run has been observed on a foreign
GNU-libc target, with or without a runtimes directory, since the change; neither
has the install-only answer the second gate now produces. Nothing about the
native or `wasm32-wasi` results recorded in §54 changes.

## 59. `-fsys=s2` states its boundary instead of guessing the host's link closure

Two changes to the mode's own documentation, both in `build.zig:616-697`, and
both about what this build is not entitled to decide for a host it did not
build for. No step, no option and no link line changes.

**The bundled providers are not hoisted into system mode.** The bundled graph
links `dbghelp` on Windows (`build.zig:363-364`), links the `CoreFoundation`
framework on Darwin targets (`:365-366`), and selects Abseil's steady-clock
backend with `ABSL_USE_UNSCALED_CYCLECLOCK` on OpenBSD/NetBSD PowerPC
(`configureClock`, `:332-338`, called on all three bundled modules at `:361`,
`:406` and `:507`). None of the three is carried into `-fsys=s2`, and
`:648-666` gives the reason for the two that look like link requirements: the
DbgHelp calls are in `absl/debugging/symbolize_win32.inc`, which only
`absl/debugging/symbolize.cc:34-37` includes, and the CoreFoundation calls are
in `absl/time/internal/cctz/src/time_zone_lookup.cc` — both library translation
units this mode does not compile. The `absl_*` names the mode does link are
upstream's own `s2` dependency list, `CMakeLists.txt:253-278`, name for name
(`build.zig:706-733`), and that list names neither
`absl_symbolizing`/`absl_stacktrace` nor `absl_time_cctz`/`absl_time`; naming
either here would add a dependency to no translation unit this mode compiles.
For the define, `:668-680` records that which **definition** of
`CycleClock::Now()` exists is chosen by the macro, that the installed
`absl/base/internal/unscaledcycleclock_config.h:47-51` picks its own value under
`#if !defined(...)` — the guard that also makes the bundled define effective —
and that forcing this build's value onto the one translation unit this mode
compiles would put it on a different answer than the archive it calls.

**The mode is restricted to hosts whose installed archives satisfy their own
link closure.** `:682-691`: this mode links installed archives, so what those
archives reference belongs to whoever built and installed them — their CMake
export, their pkg-config file, or the consumer's own link line. This build does
**not** inspect the installed archives' link closure, does **not** name a system
library on their behalf, and claims nothing for a platform on which they are not
installed. The host it is written for is the one that already has an installed
`libs2` and the 26 `absl_*` archives beside it for the target being built. What
the mode does share is the WASI provider, through the same
`Provider.init`/`configureModule`/`linkRuntime`/`configureCompile` calls
(`:735`, `:742`, `:756`, `:766`, `:775`, `:779-780`).

This is a boundary, not a defect, and it moves no gate. `-fsys=s2` is still
**NOT RUN**: no installed `libs2` or Abseil was observed on any machine in this
workspace. In this mode `check` compiles the selected target only, because
the library and the headers it binds to are this machine's (`:630-638`,
`:806-811`).

## 60. Current runner-execution status: four corrections, no new gate

§§56–59 changed `build.zig` and its documentation. **None of the four has been
observed by a gate, and none of them changes the compiled closure**: the lists
are still **108** S2 and **153** Abseil translation units, asserted at comptime
by `build.zig:1031-1032`; the facade still publishes **104** methods under **79**
distinct names; and the suite is still **46** tests. No test was added, removed
or relaxed, no source was narrowed, no unit was dropped and no diagnostic was
suppressed.

| Gate | State |
|---|---|
| native bundled `consumer` | **PENDING** — the 10/10 receipt is pre-wave |
| `consumer -- <args>` | **PENDING** — the argument forwarding is unobserved (§56) |
| `check` with a named target, `-Dtarget=native` included | **PENDING** — the narrowing is unobserved (§57) |
| six-target `check` matrix | **PENDING** |
| foreign GNU-libc `consumer` under `-fqemu`, with and without `--libc-runtimes` | **PENDING** — neither the run nor the install-only answer has been observed (§58) |
| `-fsys=s2`, any step | **NOT RUN** — its boundary is stated, not its result (§59) |
| `wasm32-wasi` `smoke` | **FAILED, not re-run** — exit 134 at `Io.Threaded.fileWritePositional`, as in §55 |
| native Debug/ReleaseSafe `test smoke install`, 53-platform matrix, 927-record replay | **PENDING**, as in §55 |

Everything §55 records stands as it is written: its gate table, its licence and
option provenance, its integrity record and its receipts are history at their
own revisions, and none of them is refreshed here. The rows above are the
additions. No earlier row is upgraded, because a landed source correction is not
a gate.
