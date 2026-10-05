# FORK-NOTES — what was decided, and what it cost

Two kinds of record live here. **Decisions** are choices this fork made that a
reader could reasonably have made differently, with what each one cost.
**Lessons** are compact entries in a fixed shape — *condition / symptom / fix /
target bound* — for the faults that actually occurred while building this
package, so that the next person does not pay for them twice.

The last section separates what is **source-confirmed** (read out of the pinned
upstream, or out of a recorded receipt) from what is **observed** (actually
run). Nothing in the first category is promoted to the second.

---

## Decisions

### 1. Upstream's PyPI-publishing workflow is deleted, not repaired

**Decision.** Remove `.github/workflows/build.yml` — the file upstream ships —
from this tree. Do not repoint it, do not disable the publish job, do not
leave it beside this fork's own.

**Why.** That workflow configures CMake with `-DFETCH_ABSEIL=ON` (a build-time
download this fork eliminates), runs Bazel over upstream's workspace against
the Bazel Central Registry, and on a release tag builds Python wheels and
publishes them to PyPI through `pypa/gh-action-pypi-publish` under a `pypi`
environment configured on Google's side of the release. Keeping it means that
tagging a release *here* attempts an upload of s2geometry wheels under it,
using another maintainer's credentials and another maintainer's release
process. There is nothing in it worth porting: the Zig build replaces the
CMake and Bazel halves, and the Python bindings are behind upstream's
`WITH_PYTHON` option, which this package does not expose.

**Cost.** `git` history shows one upstream file removed from a fork, which is
exactly the kind of edit Apache-2.0 §4(b) asks to be disclosed. It is disclosed
in three places: `NOTICE.md` ("changes are indicated"), `CHANGELOG.md` §1 and
§28, and here. At this entry's revision no S2 `src/` file was modified, which is
what the S2-scoped Git diff then checked. **That is no longer the case:** `src/`
now carries exactly one disclosed change (`bignum.cc`, `CHANGELOG.md` §50), and
`vendor/abseil-cpp` carries **seven**
disclosed deviations rather than four. The pristine check is therefore the
canonical whole-closure comparison, not a diff-to-empty test.

### 2. The integrity record covers immutable bytes, not the working set

**Decision.** `UPSTREAM.sha256` covers **927** files: the 108 compiled S2
translation units, the 177 `src/s2` headers, the 153 compiled Abseil units,
the 382 Abseil headers and `.inc` fragments, 24 licence/notice/dependency
records, 17 s2geometry build definitions, 53 Abseil build definitions, the six
upstream oracle files the fixtures were transcribed from, this fork's six
fixture files, and — added with this wave — `build_support/zig-0.16-LICENSE.txt`,
the pinned compiler's own terms copied verbatim because the standard-library
patch next to it edits upstream Zig source. It pairs pristine/current digests
for the **one** disclosed S2 deviation and the **seven** disclosed Abseil ones;
it does not pin mutable fork build/API files.

**Why.** The point of the record is that a *silent edit to an input* fails
loudly. `zig/bridge.h`, `zig/bridge.cc`, `zig/root.zig`, `tests.zig`,
`smoke.zig`, `consumer/`, `build.zig`, `build.zig.zon` and `build_support/` are
fork-owned and mutable; hashing them would make an ordinary edit look like a
supply change and would push people towards disabling the check.

The one borderline case is `testdata/`. Those six files are this fork's
transcriptions, not upstream's bytes — but they are the *values the tests
compare against*, so an edit to one moves the oracle rather than breaking a
build, which is the same failure mode the record exists to catch. They are
included, and the header says so in as many words.

`build_support/s2_sources.zig` and `absl_sources.zig` are also fork-owned and
mutable, and are *not* hashed. What pins their effect is that the files they
name are: change the list and the build compiles a different set of bytes that
are still pinned, which shows up as a compile failure or a link failure rather
than as a silent substitution.

**Cost.** 927 records and a header comment that has to be kept true when the
source set changes. `wasi_stdlib.patch` and `wasi_provider.zig` are
fork-authored and mutable and are **not** hashed, like the other `build_support/`
files; what pins the patch's effect is that the upstream Zig files it edits live
outside this repository and are named by it. The sync procedure in
`UPSTREAM.md` step 6 handles the record.

### 3. The compile-unit list is written out, not globbed

**Decision.** Enumerate the S2 and Abseil translation units in `build_support/`,
in upstream's order, with a comment naming where each came from.

**Why.** A glob over `vendor/abseil-cpp/absl/**/*.cc` picks up 231 `*_test.cc`
files, every `*_benchmark.cc` and fourteen "test helper" units that upstream
marks `TESTONLY` or gives a `GTest::` dependency. That would make "the library,
without its tests" an accident of a file-name pattern, and it would mean
`zig build` demands a test framework the package deliberately does not require.
Enumerating also makes an Abseil bump a diffable change: you can see exactly
which upstream entry moved.

**Superseded in two parts by decision 26.** The Abseil list was originally
transcribed from `SRCS` only and asserted against a pinned length; it now
transcribes `SRCS` **and** `HDRS`, because upstream compiles both, and the
omitted unit was `absl/strings/internal/escaping.cc`. Both comptime count
assertions are gone. The reasoning here — enumerate rather than glob — stands.

### 4. `allNeighbors` keeps upstream's duplicates, and so do the tests

**Decision.** `CellId.allNeighbors` returns a slice and does **not**
deduplicate. The smoke program and the tests compare neighbour lists as
**multisets** (equal length, equal occurrence count per cell).

**Why.** `S2CellId::AppendAllNeighbors` says so itself: "for cells adjacent to
a face vertex, the same neighbor may be appended more than once"
(`src/s2/s2cell_id.h:469-475`). Only edge neighbours are guaranteed distinct
(`src/s2/s2cell_id.h:456-458`). Upstream's own fixture expects the repeat —
`3/0000`'s all-neighbours contain `2/3333` twice
(`src/s2/s2cell_id_test.cc:635-650`) — and upstream states the answer with
`UnorderedElementsAre` (`src/s2/s2cell_id_test.cc:648-663`). A facade that
silently deduplicated would make its list *look* like a set and lose the only
information that distinguishes an edge-adjacent cell from a corner-adjacent
one.

**Cost.** Neighbour comparisons need a multiset helper rather than
`std.mem.eql`, and the expectations have to be spelled with their repeats
(`{"1/","2/","2/","2/","4/","5/","5/","5/"}`), which reads worse than a set
literal and is true.

### 5. The bridge covers the primary operations, and says which ones it does not

**Decision.** 93 entry points: `S2CellId`, `S2LatLng`/`S2Point`, `S2Cell`
area and geometry, `S2Cap`, `S2LatLngRect`, `S2Loop`, `S2Polygon` including its
boolean operations, `S2RegionCoverer`, and two raw loop measures.
**Not** wrapped: closest-edge / closest-point / closest-cell queries, `S2Builder`
and `s2builderutil`, the fractals, the shape-index queries, the coded/encoded
vector and string types, the terminology indexers, and the C++ template
headers that need a C++ compiler to instantiate.

**Why.** The assignment made the extra surface conditional on the primary
operations, and the primary operations here are cell identification, coordinate
conversion, cell geometry and area, loops, polygons and their booleans, and
region covering. Nothing is lost: the **whole** upstream archive and **every**
upstream header are installed, and `libs2bridge.a` forwards both header
installations, so a C++ consumer reaches all of it through `#include <s2/…>`
and `#include <absl/…>` with nothing extra. A wrapper for a template-heavy
query class would add a large surface whose only consumer would be the wrapper.

**Cost.** A Zig caller who wants `S2ClosestEdgeQuery` has to drop to
`pub const c` — or to C++ entirely. Both routes are documented, and the escape
hatch is public on purpose.

### 6. Upstream's flags are quoted; a warning *selection* is not

**Decision.** Carry upstream's flag set with a line reference for each, across
two lists rather than one: `s2Flags` for the 108 S2 units and `zig/bridge.cc`,
`abslFlags` for the 153 Abseil units. Add exactly one flag
(`-D_USE_MATH_DEFINES` on Windows). Carry `-fsized-deallocation` on the S2 half
and **not** on the Abseil half. Do not carry `-Wno-attributes` or
`-Wno-deprecated-declarations`, and answer the upstream header diagnostics
with the include *kind* on one translation unit instead.

**Why, for `-fsized-deallocation`.** Upstream requires it
(`CMakeLists.txt:122-127`). An earlier revision of this file dropped it on the
strength of `DW_AT_producer: clang version 21.1.0` read from this package's own
objects — two majors past the "clang < 19" bug its own comment scopes it to.
That reasoning is `WITHDRAWN`, and the refutation is a compile:
`local://foundation-expansion-s2geometry-check-x86_64-windows-gnu-235.log`
records `compile lib s2` failing with `no matching function for call to
'operator delete[]'` at `src/s2/util/bitmap/bitmap.h:718` and `no matching
function for call to 'operator delete'` at `src/s2/util/coding/coder.cc:62`,
on a compile line that carries `-Wno-attributes` and
`-Wno-deprecated-declarations` and no `-fsized-deallocation`. With the flag
restored, `…-resume-check-x86_64-windows-gnu-254.log` compiles all of
`libabsl.a`, `libs2.a`, `s2bridge.lib` and the smoke program for the same
target. **A compiler version does not establish a target's defaults**; a
target's own declaration set does.

**Why the Abseil half omits it.** That is upstream's arrangement, not a second
opinion: upstream's `FetchContent_MakeAvailable(absl)` is at
`CMakeLists.txt:80` and `add_compile_options(-fsized-deallocation)` is
directory scope at `:127`, after it, so Abseil's targets are created before the
option exists. `build.zig` reproduces the ordering — `addAbseil` runs first
(`build.zig:181`) with `abslFlags`, then `addS2` (`:182`) with `s2Flags`, then
`addBridge` (`:183`) with `s2Flags` again, because the bridge is C++ that
includes the s2 headers and must be under the same sized-deallocation regime as
the library it calls.

**Why, for the warning selections.** A `-Wno-…` that silences a diagnostic in
an upstream header silences the same diagnostic in this repository's own
`zig/bridge.cc`, which is where a real defect has to stay visible. Upstream
already solved the header problem the way its own consumers are compiled:
`CMakeLists.txt:46-49` defines `S2_USE_SYSTEM_INCLUDES` and
`CMakeLists.txt:285-291` applies it to the `s2` target's PUBLIC include
directory. Reproducing that is copying upstream, not suppressing anything.

**Cost.** `-D_USE_MATH_DEFINES` is applied on a target upstream scopes it away
from (`x86_64-windows-gnu`), and the justification is a comment plus a table
row. Two flag lists instead of one means a flag added to `s2Flags` and not to
`abslFlags` is invisible until someone reads both — which is exactly why the
split has to be stated here rather than left to `build.zig`.

### 7. `max_cells` is bounded by the C type it is carried in

**Decision.** Reject `max_cells > maxInt(c_int)` as `error.InvalidArgument`,
in the facade, next to the other option checks.

**Why.** The facade's `max_cells` is a `u32`; the bridge's
`S2BridgeCovererOptions.max_cells` is an `int32_t` (`zig/bridge.h:565`). Without
the guard, `@intCast` traps in Debug and ReleaseSafe — so a value that a
caller can construct in a `Coverer` literal would be a panic rather than a
reported error, and the panic would come from a conversion, not from a check.
The check is one ordinary comparison in the same place as the other four.

**Cost.** A `u32` field whose top half is unusable. That is the truth of the C
type it crosses into, and naming it in the field's doc comment is cheaper than
a wider bridge field nobody needs.

### 8. Orientation is the caller's, and no constructor decides it

**Decision.** `Loop.init`, `Polygon.init` and `Polygon.initLoops` copy the
vertex order exactly. `normalize` and `invert` exist as explicit calls and are
never invoked implicitly.

**Why.** `S2Polygon::Init` hands the loop it is given straight through
(`src/s2/s2polygon.cc:406-414`), and `S2::GetArea` maps a negative signed area
to `area + 4π` (`src/s2/s2loop_measures.cc:51-55`). A constructor that
"helpfully" normalized would silently change which side of a loop is the
interior, and for a hole that is the difference between a polygon with a hole
and a polygon that covers the sphere. Callers who want the smaller of the two
can say so.

**Cost.** A caller that passes a clockwise shell gets a plausible number for
the wrong shape. That is upstream's behaviour too, and it is documented on
`Loop`, on `Polygon.init` and in the tests; making it silent would be worse.

### 9. `Polygon.unite`, not `Polygon.union`

**Decision.** The Zig method is `unite`, and every caller uses it.

**Why.** `union` is a keyword in some Zig-adjacent tooling and a reserved word
in the upstream C++ namespace, and a name that collides with a keyword is a
name that gets quoted or renamed later. There is no `union` alias left behind:
a shim for a name that never shipped is a second spelling to keep honest.

**Cost.** None, other than the divergence from upstream's `InitToUnion`, which
is cited in the doc comment on the method.

### 10. The system mode translates the installed header, not this repository's

**Decision.** `-fsys=s2` keeps `zig/bridge.cc` compiled from this tree, but
takes this repository's `src/` and `vendor/abseil-cpp` off **both** the compile
line and the `addTranslateC` line, and binds the installed closure through **one**
pkg-config package — the project's own `s2geometry`, `build.zig:403-407` —
whose installed `.pc` carries the libraries in dependency order. The earlier
revision of this decision transcribed upstream's own `s2` dependency list
(`CMakeLists.txt:253-278`) as individual `-l` stems, `absl_*` included. **That
transcription no longer exists in the graph, and the per-stem list is what this
decision's single-package form replaced.**

**Why.** Translating the bundled v0.14.0 header against an installed library
of unknown version would describe an ABI that may not be the one on disk —
which is exactly the failure a system mode exists to avoid. Keeping the bridge
compiled here is the opposite trade and is also right: an installed upstream
library exports no fork-only symbol, so a bridge built against upstream sources
would be a bridge to nothing.

**Cost.** One honest limit, stated rather than hidden: `zig/bridge.h` is plain
C99 over `<stddef.h>`/`<stdint.h>` and names no upstream type, so the
translation has nothing of ours to resolve and reads the same header in both
modes. The declarations that do cross the boundary — every `s2br_*` signature —
are compiled against the installed headers by `zig/bridge.cc` itself, which is
where a C++ compiler checks them against the installed library.

### 11. The tests are published answers and geometric identities

**Decision.** Every expected value in `tests.zig` and `smoke.zig` is either an
independent published answer or an identity that follows from geometry. No
test calls the library and then declares its own output correct, and no test
pins a version string, an export, a default, a forwarding path, a copy, or
"it did not throw".

**Why.** S2 is a codec *and* a geometry engine. A self-round-trip such as
`toToken(fromToken(x)) == x` proves only that the codec agrees with itself,
which is exactly what a wrong codec does. golang/geo is an independent
reimplementation of the same codec and publishes its own tables; that is the
oracle. Where nothing publishes a number — the sum of the six face areas, the
area of an octant, the boolean of two overlapping wedges — the tests hold the
library to 4π, π/2, π/4 and 3π/4, which follow from tiling and from spherical
excess rather than from a measurement.

**Cost.** Two facts had to be respected rather than worked around. No
implementation searched publishes a leaf cell for lat/lng (0,0), so the
projection origin is pinned by what *is* published — the level-0 cell
`0x1000000000000000` is Google's own literal for "the face centred at (0, 0)"
(`src/python/s2geometry_test.py:486-487`) and (0,0)'s leaf is on face 0
(`src/s2/s2cell_id_test.cc:90-95`) — and the level-30 token is deliberately
not asserted anywhere. And only **one** face's edge-neighbour list is published
upstream, for face 1 (`src/s2/s2cell_id_test.cc:574-580`), so only that row is
asserted; an earlier draft generalised it to all six faces and was removed as
invented data.

### 12. `.paths` decides what a dependent receives, and it is a hard error

**Decision.** `build.zig.zon`'s `.paths` names `README.zig.md`, `UPSTREAM.md`,
`NOTICE.md`, `CHANGELOG.md`, `FORK-NOTES.md` **and** `UPSTREAM.sha256`, and the
CI provenance job names `UPSTREAM.sha256` in its required-records loop, runs
`git diff --exit-code c24b368c… -- src`, and runs `sha256sum -c
UPSTREAM.sha256`.

**Why.** `.paths` is not documentation: Zig validates it at configure time, so
a path that does not exist makes every build of this package and of every
dependent fail before anything compiles. That is the right behaviour, and it
means the six records have to exist as files rather than as intentions. The
integrity record is in the same list because a dependent that receives the
headers without the record cannot check them, and `sha256sum -c` is in CI
because a record nothing ever checks is a comment.

**Status — done.** All three are in place. `build.zig.zon`'s `.paths` ends with
the six record paths under the comment "This fork's own records. A private
repository removes no upstream licence obligation.", and
`.github/workflows/verify.yml`'s `provenance` job has the seven-file
required-records loop (`LICENSE NOTICE NOTICE.md UPSTREAM.md UPSTREAM.sha256
CHANGELOG.md FORK-NOTES.md README.zig.md`), the `git diff` step and the
`sha256sum -c UPSTREAM.sha256` step. Both were then run by the driver and both
passed: `…-immutable-native-dependency-fixture-integrity-231.log` (exit 0, 926
records `OK`) and `…-pinned-native-pristine-diff-268.log` (exit 0, empty
output). The first two items of the pending list below are therefore closed.

**Cost.** One line in the manifest and two steps in CI, both owned by the
integration owner rather than by this role.

### 13. The seven-target confusion: six targets, and `-Dtarget` narrows

**Decision.** `check_targets` is exactly six:
`x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`,
`x86_64-windows-gnu`, `riscv64-linux-gnu`, `wasm32-wasi`. An explicit
`-Dtarget=` compiles only that one.

**Why.** All six are attempted unconditionally so that whatever fails, fails
visibly, and none carries `continue-on-error`. `wasm32-wasi` and
`aarch64-macos-none` have named, known risks; excluding them would make the
matrix green by omission. A cross `-Dtarget` check also needs the *private*
module form, because module names are registered against the whole build and
registering `s2geometry` once per cross target would leave only the last
reachable and silently stop checking the rest.

**Cost.** `check` on a machine without an SDK for one of those targets fails,
and the honest response is to record the compiler output in this file and name
the boundary in the failing step, not to mark it green. That has now happened
twice, and the two cases are different in kind: three targets stopped at one
Zig fixture line in `tests.zig`, and two stopped at a target capability Abseil
needs and this host does not have. See "What is source-confirmed, and what has
actually been run" below.

### 14. `test` exposes its run for every target; the runner decides

**Decision.** Both test graphs — the bundled one and `-fsys=s2` — build a run
artifact unconditionally and keep `has_side_effects = true`. The
`target.query.isNative()` guard is gone. The six-target `check` matrix is
unchanged: `addCheck` attaches the compile step and never had a run artifact.

**Why.** The guard was read as "this machine cannot execute a foreign binary",
but the predicate it actually tests is `Target.Query.isNative()`, which in the
pinned compiler is `isNativeTriple() and ofmt == null` with `isNativeTriple()`
requiring `cpu_arch`, `os_tag` and `abi` all **null**
(`lib/std/Target/Query.zig:392-398`). An explicit `-Dtarget=x86_64-linux` is
therefore not native even on an x86_64 Linux host. Observed 2026-10-02 on
`gruenau8` through `cross-test`, run `20261002-033134-17908-30770`: every object
compiled, `Build Summary: 9/9 steps succeeded`, `test success`, **no `run`
line**, and the harness recorded `no_test_results`, exit 1.

The deeper reason is that the question was never the build script's to answer.
`std.Build.Step.Run` is the seam where "can this target execute here" is
decided, and the harness's own build runner is what answers it. Note what the
default outcome actually is when the answer is "no": `failForeign`
(`lib/std/Build/Step/Run.zig:2753-2777`) returns `error.MakeSkipped` **only**
when the run step sets `skip_foreign_checks`, and otherwise calls
`run.step.fail` naming the binary, the foreign triple, the host triple and the
flag to use. So `std.Build` reports a **named failure**, and it is the harness —
not `std.Build` — that classifies a target it has no runner for. This package
sets neither `skip_foreign_checks` nor anything equivalent, so no foreign run
here is downgraded from a failure to a skip. A script that decides in advance
replaces the real answer with a guess, and the guess is wrong in both
directions: it under-runs the host's own triple, and it forecloses foreign
execution entirely.

**Cost.** One behaviour change in each of two places, plus `cross-test.profile.sh`
and its `.paths` entry. No native source, no test, no public API. Outside the
harness's own build runner, `zig build test -Dtarget=<foreign>` now fails where
it used to quietly compile — which is the honest outcome, and the same failure
any `zig build run -Dtarget=<foreign>` already gave.

### 15. `wasm32-wasi` gets an installed SDK provider, not a smaller closure

**Decision.** `-Dwasi-sysroot=<path>` names a complete, already-installed WASI
SDK 34 sysroot with the **WASIp1-threads** ABI. That option is **this package's
own**, added by this repair as an ordinary
`b.option([]const u8, "wasi-sysroot", …)`; it is not a compiler option and it is
the only new build option here, separate in kind from the existing standard
`--zig-lib-dir` of decision 16. `build_support/wasi_provider.zig` is the one
place that reads it: it maps `include/wasm32-wasip1-threads`,
`…/eh/c++/v1`, `include/c++/v1`, `lib/wasm32-wasip1-threads` and `…/eh`, turns
that into a generated `wasi-libc.conf`, links the SDK's own
`libc++.a`/`libc++abi.a`/`libunwind.a` plus `libwasi-emulated-signal.a` and
`libwasi-emulated-getpid.a` as object files, sets `link_libcpp = false` on every
WASI module, adds the atomics/bulk-memory/exception-handling/reference-types/
multivalue CPU features, and sets the shared-memory link ABI. Without the
option, a `wasm32-wasi` compile fails with a message naming the provider and
stating that no core sources are omitted.

**Why.** The alternative shapes were all tried or reasoned about and all are
worse: a build-time download breaks the no-download rule and puts a network in
the gate; a filesystem shim replaces a real facility with a fake one; disabling
exceptions removes a facility the source genuinely uses; and a partial source
closure is exactly the "omit a unit to make a target green" move this
workspace forbids. The observed evidence that a real provider suffices is that
the whole 261-unit closure now compiles, links and runs its 46 public tests;
all three archives installed; the standalone consumer **compiled and installed
without being run**; and a separate installed S2 C++ consumer program actually
executed, printing
`decimal_sign_chunk_boundaries=5 invalid_inputs=2 two_threads=2
allocation_cycles=128 outstanding_delete=refused final_delete=reclaimed`.

**What it does not buy.** `getpid` and `signal`/`raise` are the SDK's own
**documented emulation**, linked because Zig 0.16's libc-linked nonsecure RNG
fallback references `getpid` and Abseil's synchronous signal handling needs
`raise`. They are advertised as that and nothing more: no host PID, no
independent process namespace, no POSIX signal semantics. WebAssembly
async-signal-safe support stays unsupported, which upstream already records.

**Cost.** `wasm32-wasi` is no longer buildable with the compiler alone: it needs
an installed SDK sysroot *and* a patched standard-library copy (decision 16).
That is a real dependency, stated rather than hidden, and it applies to that
one target only.

### 16. The Zig standard library is patched in a copy, selected with `--zig-lib-dir`

**Decision.** Stock Zig 0.16.0 **does not compile** a threaded, libc-linked
`wasm32-wasi` build. Two hunks fix it, and they ship as
`build_support/wasi_stdlib.patch`, applied by the user to a `cp -a` copy of
`<zig>/lib` and selected with the compiler's **existing standard**
`--zig-lib-dir`. The stock compiler is untouched; no global tool is edited; no
additional custom standard-library option is introduced (the one new build
option in this repair is the package's own SDK-provider `-Dwasi-sysroot`, of a
different kind); nothing is downloaded during a build; and no `errno` or
`stdout` workaround is used.

The two hunks, from the observed failure at
`local://foundation-portability-wasi-sdk-errno-multi-compile-failure.json`
(exit 1):

1. `std/Io/Threaded.zig:959` — the wasm `memory.atomic.wait32` timeout assigns a
   `u64` nanosecond count into an `i64`: `error: expected type 'i64', found
   'u64'`. Since any negative value there means "wait indefinitely", the fix
   saturates a finite `timeout_ns` to `maxInt(i64)` before conversion. `null`
   still means "no timeout" and is still `-1`, and every native branch and the
   parking-futex branch are byte-identical to stock.
2. `std/heap.zig:16` — `WasmAllocator` is `@compileError("unimplemented")` for
   `!builtin.single_threaded`, so selecting it as `page_allocator` is
   `error: unimplemented`, a hard failure rather than a weaker allocator. The
   new branch selects the real `c_allocator` for
   `arch.isWasm() and os.tag == .wasi and link_libc and !single_threaded`.
   `c_allocator` is stock Zig over the SDK's own thread-safe allocator and
   already satisfies the whole `Allocator` contract; on this target Zig's
   `have_posix_memalign` is false, so it applies its manual alignment strategy
   over that same real allocator. No other WebAssembly OS, and no native path,
   changes, and the "unimplemented" diagnostic still honestly reports the
   genuinely unsupported threaded non-libc case.

**Why a copy rather than a fork of the compiler.** The standard `--zig-lib-dir`
option already exists, is global, and is forwarded into the whole build graph
(`lib/compiler/build_runner.zig`), including into this package's nested
consumer build. Editing the installation would make the machine's compiler
disagree with every other package on it, and would be invisible in any record
of this repository.

**Cost.** Two external prerequisites for `wasm32-wasi`, one of which the user
must construct with `cp` + `patch -p1`. `README.zig.md` carries the exact
invocation; the one thing worth repeating here is that the source of the copy
must be named unambiguously: `ZIG_ROOT` is the **directory** holding the pinned
0.16.0 `zig` executable beside its `lib/`, and the script checks
`$ZIG_ROOT/zig` is executable and `$ZIG_ROOT/lib/std` exists before copying
`"$ZIG_ROOT/lib"`. In this workspace the compiler variable is normally the
absolute path of the *binary*, so a `$ZIG/lib` spelling would silently name the
wrong path. The patch file's plaintext prologue is documentation for a reader
and is skipped by `patch`/`git apply` before the first `--- a/std/heap.zig`
hunk. `zig-0.16-LICENSE.txt` ships beside it as the pinned compiler's own terms
copied verbatim, because the patch touches upstream Zig source; see "Recorded
boundaries" item 5.

### 17. The consumer inherits the provider's final link, and re-declares nothing

**Decision.** On `wasm32-wasi`, `consumer/build.zig` forwards `-Dwasi-sysroot`
into `b.dependency`, reads `single_threaded` off the library module rather than
restating it, and copies `libc_file`, `import_memory`, `export_memory`,
`shared_memory` and `max_memory` off `dep.artifact("s2bridge")`. It writes no
include path, names no C or C++ header, links no `.a`, and hardcodes no sysroot
path. Native stays module-only, exactly as before.

**Why each copy is necessary.** `std.Build` holds `libc_file` and the four memory
fields on `Step.Compile`, not on `Module`, so a module import never propagates
them; and `Module.single_threaded` is a plain field that an import does not carry
either. Restating any of them in a dependent would duplicate a fact the library
already owns and let the two drift. Copying from the artifact that holds them
keeps one source of truth.

**Why the threading model is an ABI requirement, not a preference.** Zig 0.16's
`std.c` `errno` on `.wasi` is not the SDK's `__errno_location()`:
`lib/std/c.zig:7096` selects `private.errnoFromThreadLocal`, returning the
address of `extern threadlocal var errno` declared at `lib/std/c.zig:11572`. A
module left at the `wasm32-wasi` single-threaded default compiles that storage
outside the SDK's shared-memory TLS. Measured, single-threaded:
`sdk_errno=28 zig_errno=0 sdk_addr=0x1000000 zig_addr=0`, run exit 86 — one
binary, two errnos, on a call the SDK had reported as successful
(`local://foundation-portability-wasi-sdk-errno-single-proof.json`). Note also
that a null `Module.single_threaded` emits no flag at all
(`lib/std/Build/Module.zig:546`, `addFlag` returns on null), which is why one
function decides it for every module rather than each call site.

**Cost.** The consumer's WASI path is no longer two lines. That is the price of
`std.Build` not propagating these four-plus-one properties, and it is paid in
one reference file rather than in every dependent.

**What is and is not observed about it.** On `wasm32-wasi` the consumer package
compiled and installed; it did **not** run. The `consumer package success` line
in `local://foundation-portability-s2-wasi-corrected-sdk-gates.log` is the
outer step succeeding, and at that revision the nested step still picked
`install` over `run` because the old `query.isNative()` predicate is false for
`-Dtarget=wasm32-wasi` on this host. The source has since switched that decision
to the resolved-target predicate and forwards `-fwasmtime`, but **no run has
observed the result**, so the executed Zig consumer on this target is
`PENDING-VERIFICATION`. The executed evidence for the installed library is the
separate installed C++ consumer program, and an outer step's success is never
read as an inner program's execution.

### 18. Abseil's LowLevelAlloc takes its WASI backing from the SDK libc

**Decision.** Under `#ifdef __wasi__`, the two vendored files obtain each arena
backing region from `posix_memalign(&new_pages, arena->pagesize,
new_pages_size)` instead of `mmap`, while the arena spinlock is **released**, and
publish the region into the free list only after the lock is retaken. Each
region header carries a `region_base` pointer in the header's existing
alignment slot; a split copies it to the remainder; `Coalesce` merges only when
the two `region_base` values are equal; `Next()` asserts the same invariant with
an ordinary comparison; and `DeleteArena` calls `std::free(region)` after
asserting `region->header.region_base == region`. Native header layout and
native code are unchanged outside those guards.

**Why the identity pointer is necessary.** Without it, two blocks from different
backing allocations could be coalesced once they become adjacent on the free
list, and the merged block would later be `free()`d at an interior pointer the
allocator never returned. That is a real corruption, not a leak, and it is why
the invariant is enforced at the merge site rather than assumed.

**Why not a file-mapping emulation.** The upstream code chose `mmap` and probed
`ABSL_HAVE_MMAP`; on this target that probe is false for a reason unrelated to
whether the SDK has an allocator, so faking the mapping would claim a capability
the platform does not have. The SDK libc's own aligned allocation is real, is
thread-safe, and does not re-enter Abseil's lock.

**Cost.** Two more vendored Abseil files in the deviation set, and no
asynchronous-signal-safety: upstream already records
`ABSL_LOW_LEVEL_ALLOC_ASYNC_SIGNAL_SAFE_MISSING` for WebAssembly and this change
does not alter that. No performance claim is made; the identity uses only the
header's existing padding.

### 19. "Named" is what the caller typed, not what the query resolved

**Decision.** `zig build check` branches on `target_was_named(b)`
(`build.zig:133-138`, used at `:235-239`), which asks `b.user_input_options`
whether any of the four names the standard library registers — `target`, `cpu`,
`ofmt`, `dynamic-linker` — was given. It does not ask whether the resolved query
is native.

**Why the resolved query cannot answer it.** `standardTargetOptionsQueryOnly`
(`lib/std/Build.zig:1473`) returns the empty query when none of the four was
given (`:1495-1496`) and parses `-Dtarget=native` into that *same* empty query at
`:1498`; `resolveTargetQuery` (`:2704-2707`) hands back `b.graph.host` for both,
and `Query.isNative` (`lib/std/Target/Query.zig:396-398`) is therefore true for
`-Dtarget=native`. The predicate and the option disagree by construction, which
is how `zig build check -Dtarget=native` compiled all six targets for a caller
that asked for one.

**Why the option map is the honest source.** Every `-Dname=value` the caller
passed is a key in `b.user_input_options` (`lib/std/Build.zig:1167`, filled by
`addUserInputOption` at `:1533-1541`), and the four names spelled here are the
standard library's own test for "nothing was named" (`:1474-1494`, `:1495-1496`).
So this asks exactly the question the pinned standard library asks and not a
broader one: `-Dcpu=` alone still narrows `check` to the host, which the matrix
branch would not do. As a dependency the map holds whatever the dependent
forwarded through `b.dependency`, which is the target it asked for — the same
answer by the other route.

**Cost.** Six lines of function (`build.zig:133-138`) whose name could be
mistaken for `Query.isNative`; the doc comment at `:108-132` exists to stop
exactly that. The six-target matrix itself is unchanged, and no target was added
to it or removed from it. The branch lives in the bundled graph — `-fsys=s2`
returns before it (`:159-162`) and compiles the selected target in its own
`check` (`:806-811`) — so the system mode is unaffected by it.

**What is and is not observed about it.** Nothing. No `check` gate has run over
the corrected source in either direction: the narrowing and the six-target
matrix are both unobserved, and the four baseline `check` receipts recorded in
the table below describe the previous revision.

### 20. The nested consumer build receives the caller's arguments verbatim

**Decision.** `addConsumerStep` forwards `b.args` after a `--` — the handover is
the last block of the function, `if (b.args) |args| { run.addArg("--");
run.addArgs(args); }` — after every option this package forwards and before
nothing else.

**Why it has to be forwarded at all.** `consumer/` is a separate `zig build`, and
its `run` step is the only place the consumer package's arguments become the
program's (`consumer/build.zig`: `const run_exe = b.addRunArtifact(exe);` and then
`if (b.args) |args| run_exe.addArgs(args);`). Without the forward,
`zig build consumer -- …` proved a narrower check than the caller asked for and
the build summary would not have shown it: the program receives `b.args`, and in
the nested build `b.args` is whatever *it* was given.

**Why the separator, and why last.** The build runner stops parsing its own
options at `--` and stores the remainder in `b.args`
(`lib/compiler/build_runner.zig:428-430`). A program argument placed before the
separator would be read as a build option, and the separator is emitted only
when there are arguments at all. Everything before it is this package's own
negotiation with the nested build — `run` or `install` as `hostCanExecute` decided,
then `-Dtarget=<triple>` and `-Dcpu=<cpu>` taken from the resolved **query**,
`-Doptimize`, `-Dlinkage` and `-Druntime` when the caller named them, `-fsys=s2`
or `-fno-sys=s2`, `-Dwasi-sysroot`, `--zig-lib-dir`, the executor switches,
`--libc-runtimes`, `-j8`, `--summary all`, `--cache-dir` with this build's local
cache and its `/consumer` subdirectory, `--global-cache-dir` with
`b.graph.global_cache_root.path` unchanged, and `--prefix` with this invocation's
`b.install_prefix` — made absolute against `b.graph.cache.cwd` when the value is
relative, and not sent at all when it is `<build root>/zig-out`, which is what a
caller who named no `--prefix` leaves behind — and this step never assembles
arguments of its own, so the two cannot be confused for each other.

**Cost.** The handover block itself, and one rule to remember for whoever adds the
next thing to that list: before the `--` is this package's, after it is the
caller's.

**What is and is not observed about it.** The forwarding itself is **observed**.
The parent's nested-delivery proof ran `zig build consumer -- --provider <abs
path>` in four cases, and in each the nested argv carries `--` followed by that
same pair verbatim, the receipt's `forwarded_arguments` is exactly those two
tokens, and the program ran and printed its published answers. **Still unobserved:**
the same forwarding under `-fsys=s2`, where the nested graph would resolve the
system integration option again against an installed library. The pre-wave 10/10
consumer receipt predates the change, and the `wasm32-wasi` result is an
install-only run of a different target; neither is evidence about the forwarding.

### 21. The consumer step runs only where `Step.Run` would run

**Decision.** `hostCanExecute` carries the second gate `Step.Run` applies *after*
the executor predicate: its `qemu_fixes_dl` option is
`candidate.isGnuLibC() and b.libc_runtimes_dir != null`, and its `.qemu` arm
answers `!(candidate.isGnuLibC() and b.libc_runtimes_dir == null)`.
`--libc-runtimes` is forwarded to the nested build by `addConsumerStep`.

**Why the predicate alone was a promise the step could not keep.** `Run` calls
`getExternalExecutor` (`lib/std/Build/Step/Run.zig:1268`; the function is
`lib/std/zig/system.zig:42`, its options struct `:30-38` where `qemu_fixes_dl`
defaults to `false` at `:36`) and then, in its QEMU arm, refuses for a
`need_cross_libc` target that was given no runtimes directory (`:1294-1311`, the
refusal at `:1310`; `failForeign` is `:2753-2777` and names both triples). The
`allow_*` options can carry the enable switches (`:1277`, `:1291`, `:1317`,
`:1325`) but not a refusal made after the predicate has already said yes. So on
a foreign GNU-libc target with no runtimes directory this step chose `run`, and
the nested run failed on a directory it did not have.

**Why the directory has to travel with the switch.** The nested `Run` reads
`b.libc_runtimes_dir` from its own graph. Had the directory not been forwarded,
the predicate would have read the outer graph's answer and the run the nested
graph's empty one, and the two graphs would have disagreed about the same
target. `--libc-runtimes` is the runner's own option
(`lib/compiler/build_runner.zig:323-325`); the executor switches beside it are
`:388-407`.

**Cost.** One condition in the options struct and one in the `.qemu` arm. A
foreign GNU-libc cell with no runtimes directory now installs the consumer
instead of running it — compile evidence, never an execution result. No other
QEMU case changes: a foreign architecture whose libc needs no cross runtime, a
musl consumer among them, and the native, Rosetta, Wine, Wasmtime and Darling
arms are untouched.

**What is and is not observed about it.** Narrower than it was, and no further.
Every case in the parent's nested-delivery proof is native, and in all nine the
predictor answered `run` and the program ran — so the native arm and the
`hostCanExecute` call itself are observed. **Still unobserved:** everything the
decision exists for. No consumer run has been seen on a foreign GNU-libc target
since the change, with or without a runtimes directory, so the `.qemu` second gate
this decision adds is still `NOT RUN`, and so is the install-only answer it
produces when it fires.

### 22. `-fsys=s2` states what the installed library's own build owns

**Decision.** The mode's own documentation (`build.zig:616-697`) records that
the three bundled providers are **not** hoisted into system mode, with the
reason for each (`:648-666`, `:668-680`), and that the mode is written for a
host whose installed archives satisfy their own link closure, because this build
neither inspects that closure nor names a system library on their behalf
(`:682-691`).

**Why the providers stay out.** `dbghelp` (`build.zig:363-364`) and
`CoreFoundation` (`:365-366`) are requirements of library translation units this
mode does not compile: the DbgHelp calls are in
`absl/debugging/symbolize_win32.inc`, reached only through
`absl/debugging/symbolize.cc:34-37`, and the CoreFoundation calls are in CCTZ's
`absl/time/internal/cctz/src/time_zone_lookup.cc`. The libraries the mode binds
are the ones the installed `s2geometry.pc` names, which is upstream's own `s2`
dependency closure (`CMakeLists.txt:253-278`); this build transcribes none of
them and links no `-l` stem by hand. That closure names neither
`absl_symbolizing`/`absl_stacktrace` nor `absl_time_cctz`/`absl_time`; naming
either here would add a dependency to no translation unit this mode compiles. The
third is not a link at all: `ABSL_USE_UNSCALED_CYCLECLOCK` (`configureClock`,
`:332-338`, called on all three bundled modules at `:361`, `:406`, `:507`)
chooses which *definition* of `CycleClock::Now()` exists, and the installed
`absl/base/internal/unscaledcycleclock_config.h:47-51` picks its own value under
the same `#if !defined(...)` guard — so the installed build's configuration is
the one that describes the installed archive, and forcing this build's value
onto the one translation unit this mode compiles would put it on a different
answer than the library it calls.

**Why the link closure is not inspected.** The mode links archives it did not
build. What those archives reference belongs to whoever built and installed
them — their CMake export, their pkg-config file, or the consumer's own link
line — and inferring it here would be this build naming system libraries on
another build's behalf.

**Cost.** Two paragraphs of documentation and no behaviour change. The mode is
written for the host that already has an installed `libs2` and the Abseil
archives its `s2geometry.pc` names beside it for the target being built, and its
`check` compiles the selected target only, because the library and the headers it
binds to are this machine's (`:630-638`, `:806-811`).

**What is and is not observed about it.** Nothing, and nothing changed. The mode
is still **NOT RUN**: no installed `libs2` or Abseil was observed on any machine
in this workspace. This is a stated boundary, not a result.

### 23. The README became the fork's own, and upstream's was preserved beside it

**Decision.** Write this fork's `README.md` in the contract's order — current
native-source deviations, current native-build deviations with a dated history
link, the current build/run/test matrix, then consumption — keep the Zig
interface documentation in `README.zig.md` alone, and move **upstream's** README
bytes to `README.upstream.md` unchanged.

**Why.** `README.md` was upstream's file, byte for byte, since the import, so the
fork had no README of its own and its deviations, its status and its consumption
were spread over five documents. Preserving the upstream bytes at a second path
is what lets the fork README be replaced without losing them: the record's
digest moves with the bytes, so the pin survives the move.

**Cost.** One record in `UPSTREAM.sha256` is renamed rather than deleted, the
new path has to appear in `build.zig.zon`'s `.paths` (the build graph's file, not
this one's), and every sentence that cited `README.md` as upstream's — the
Abseil-pins table in `UPSTREAM.md` and in `CHANGELOG.md`, the cryptographic-
sufficiency note in `NOTICE.md` — now cites the path where those bytes live.

**What is and is not observed about it.** No gate has run against the relocated
record; `sha256sum -c UPSTREAM.sha256` over the renamed path is **PENDING**, and
the driver's replay is what would confirm it.

### 24. The fork's own files are Apache-2.0, by the owner's authorization

**Decision.** License every fork-authored file — build graph, bridge, facade,
tests, fixtures, packaging, records — under the Apache License 2.0, record the
authorization and the grant in `FORK-LICENSE.md`, and state in `NOTICE.md` that
the grant is separate from upstream's and asserts nothing over upstream's bytes.

**Why.** The owner's authorization for this wave is a per-project licence for
the fork's additions, matching the primary upstream terms where appropriate, and
this project's primary upstream term is Apache-2.0 — both upstreams. The
per-file exceptions stay exactly where they are: three compiled S2 headers also
carry BSD-3-Clause text, the compiled CCTZ header and retained timezone data
carry public-domain notices, the pinned Zig compiler's MIT terms travel because
the standard-library patch edits two of its files, and golang/geo's BSD-3-Clause
still is not shipped because none of its source is.

**Cost.** No personal copyright identity is invented, so `FORK-LICENSE.md` names
the fork's contributors as the holder and says that the owner is identified in
the private repository. Two rows need their own sentence rather than the
package label: the standard-library patch and the transcribed fixture data.

**What is and is not observed about it.** A licence is not a gate. Nothing here
has been run, and nothing here changes what CI already checks — the CI job that
requires the fork's records to be present must now include `FORK-LICENSE.md`,
which is a change to the workflow file, not to this decision.

### 25. One derivation, variants at the entry points, tools-only shell

**Decision.** `package.nix` is one uncurried function taking injected
`lib`/`stdenv`/`zig` and `linkage ? "static"`, and returns one derivation.
`flake.nix` publishes `static`, `shared` and `default` from it; `devenv.nix`
publishes the same derivation as lazy `outputs.static` and `outputs.shared`. The
development shell carries tools only.

**Why.** Two build graphs for one library would be two SDK modules pretending to
be one. Lazy outputs keep `devenv shell` free of the SDK while
`devenv build outputs.static` stays the real packaging route; a shell that has to
build the package to be entered is a build gate, not a shell.

**Cost, stated as dependencies rather than hidden.**

* The derivation passes `-Dlinkage=static|dynamic`, which the build graph is
  gaining for the shared variant. Until it exists, only the static variant
  builds, and the install-phase check **fails a shared build** rather than
  describing a static archive as a shared one (L37).
* `zig build` is given no `-Dtarget`, so a Nix cross-compilation — where the
  builder is not the target — is refused. A native build on a remote builder is
  an ordinary native build and stays valid.
* The build graph owns the native install, so `s2geometry.pc` and the licence
  directory are written only when the graph has not installed them: one writer
  per path.

**What is and is not observed about it.** Both flake outputs have now been
built: in the driver's Nix/devenv acceptance run of 2026-10-04, `nix:build`
completed `exit 0` for `path:…s2geometry#static` and `#shared`, with two
`drvPath`s and two realised outputs and no reasons recorded. **The devenv half of
that same run was a failure**: every devenv gate exited 1 on the parse error
`CHANGELOG.md` §70 records, before any task body could run, and `CHANGELOG.md`
§73 replaces that receipt with a later one. A devenv shell **has** since been
entered and all eight devenv gates pass
(`…/20261004T215554Z/s2geometry-index.json`), so this half is observed now and
was not then; `sdk:build`, `sdk:test`, `sdk:smoke`, `sdk:check` and `sdk:fmt`
were not exercised in that run either, and `nix:build` is `gates_not_run` in it.
`flake.lock` exists, created by the driver from that observed build;
`devenv.lock` is derived from `devenv.yaml`
inputs no SDK ships, and the driver writes it under the scratch project
directory it invokes `devenv` from rather than into this repository —
`repo:untouched` passed with no canonical-config change.

### 26. The upstream source list, transcribed — and the pin over it, removed

**Decision.** `build_support/absl_sources.zig` is transcribed from the vendored
tree's `absl_cc_library` blocks, and since this correction it is transcribed from
**`SRCS` and `HDRS` together**, because upstream compiles both
(`vendor/abseil-cpp/CMake/AbseilHelpers.cmake:234`, `:260`:
`target_sources(${_NAME} PRIVATE ${ABSL_CC_LIB_SRCS} ${ABSL_CC_LIB_HDRS})`).
`absl/strings/internal/escaping.cc` — which upstream lists under the
`strings_internal` target's `HDRS` at
`vendor/abseil-cpp/absl/strings/CMakeLists.txt:126` while its `SRCS` names only
`ostringstream.cc` and `utf8.cc` — is now in the list, unchanged. The two
comptime assertions over the list lengths are gone from `build.zig`.

**Why.** Transcribing `SRCS` alone under-reads what upstream builds. A `.cc`
under `HDRS` compiles, and omitting one leaves the closure short a unit that
every symbol the rest of it declares can reach. Enumerating rather than globbing
is still the right call (L2): a glob would pull in 231 upstream test files and
demand a test framework this package refuses to download. But an enumeration
faithful to `SRCS` and unfaithful to `HDRS` is not an enumeration of upstream's
build.

**On the pin, specifically.** The assertion was right. It fired the moment the
real unit was added
(`local://foundation-contract-s2geometry-shared-full-Abseil-HDRS-source-closure-origin-first-install.log`,
`error: reached unreachable code` at the old
`std.debug.assert(absl_sources.sources.len == 153)`) and that is how the omission
was found. It is gone anyway, because a number that must be hand-edited whenever
a genuine source is added is a second place for the closure to be wrong, and it
turns a closure correction into a configure failure before anyone can see the
build. The catalog's own header documents the exclusion rules; the list is the
authority.

**Cost, and what it bought.** One more Abseil translation unit per target and per
optimisation mode, and the loss of a check that could only ever say "the number
moved", never "the number moved because a source was added". The documentation
consequences were larger than the code change: `README.md` and `README.zig.md`
dropped their pinned source counts, bridge-entry tally, method tally and record
length, because each was a figure that had been true of one revision and would
have had to be corrected by hand the next time any of them moved. Where a
receipt printed a test or step count, the count stays: that is what the run said.

**What is observed.** `zig build install -Dlinkage=dynamic` over the corrected
closure, "Build Summary: 25/25 steps succeeded", `install success`
(`local://foundation-contract-s2geometry-shared-origin-first-complete-native-closure-source-count-pin-removed.log`).
It installs; it does not run the suite. Nothing else about this entry is gated,
and the closure correction itself is `SOURCE-CONFIRMED` from the upstream CMake
and `SOURCE-CONFIRMED` again by the canonical whole-tree comparison of §1's
disclosed paths, which is unchanged by adding a path to a build list.

### 27. One visible C++ runtime for the ELF shared closure, and an install tree that names no build directory

**Decision.** `-Dlinkage=dynamic` on an ELF target produces **four** installed
objects: upstream's three — `libabsl.so.2508`, `libs2.so.0`,
`libs2bridge.so.0`, each with upstream's own soname — and one this fork does not
own, `libs2cpp.so.0.16.0`, which is the pinned compiler's shipped libc++,
libc++abi and libunwind compiled by `build_support/cpp_runtime.zig` from
`b.graph.zig_lib_directory` and installed with its three verbatim `LICENSE.TXT`
files. The three libraries are compiled against that runtime's ABI
(`_LIBCPP_ABI_VERSION=1`) and link it by name; nothing in the package embeds a
private static C++ runtime on that route. The same route also builds the native
closure **twice**: a cache-aware graph for the facade, the smoke program and the
tests, and a pure install graph whose runtime search path is `$ORIGIN` on ELF
and `@loader_path` on Darwin and nothing after it. No other route builds the
runtime artifact, and no native source is edited.

**Why.** Both halves correct a claim the records were making rather than adding
ambition. §66 promised that "the build-cache directory is appended **after**"
the installed-tree token, which put a build directory into every installed
object, and `NOTICE.md` promised that no compiler runtime is compiled at all,
which the ELF shared closure contradicted the first time it ran. The need was
observed three times over, each `exit 1` on
`zig build test smoke install -Druntime=false -Dlinkage=dynamic -Doptimize=Debug`
and all three receipts kept under
`/home/tmp2/gertullj/scratch/foundation-libs/contract-physics-lua/s2-current-evidence/`:
an undefined `_ZTTNSt3__119basic_ostringstream<...>` out of `libs2.so.0`
(13:50:09), an undefined `_ZNSt3__15ctypeIcE2idE` out of `libabsl.so.2508`
(13:57:39), and an undefined `_Unwind_Resume` (14:12:42). The structural cause
is that Zig's ordinary static C++ runtime is compiled with **hidden exports**:
each image that links its own copy gets its own `std::locale` facet registry,
and an S2 log stream crossing an image boundary dies in `std::use_facet` — which
is what the driver's earlier shared-Debug run reported, 43 passing tests and
three such segfaults across the invalid-rect, repeated-vertex and
boolean-rejection paths.

**Cost, and what it bought.** On that one route: a second compilation of the
three libraries for the install tree, one more object to install, and one more
compile step in the graph. The Debug shared cell is 39 steps against 32 for the
static one; `compile lib s2cpp ReleaseFast native` took 36 s at MaxRSS 417 MB
against an empty per-target cache, and `install absl` compiles its own copy (28 s)
rather than reusing the tests'. Bought: an ELF shared closure that links, loads
and runs its own suite, and an install tree in which every runtime search path is
the installed directory, so relocation depends on nothing outside the prefix.
`static` pays none of it — one graph, compiled once and installed, and no
`s2cpp` step anywhere in its tree.

**What is observed, and what is not.** Sixteen native cells, all `exit 0`, all
printing "46/46 tests passed" and `smoke success`: `-Dlinkage` × `-Druntime` ×
Debug / ReleaseSafe / ReleaseFast / ReleaseSmall, receipts under
`…/contract-physics-lua/current-native-evidence/` with an index of all sixteen.
**Not observed:** a relocated prefix loading its own closure, an installed C or
C++ consumer compiled against any of these artifacts, and an installed
`s2geometry.pc` carrying `-ls2cpp` inside a gate — that metadata landed during
the sweep, and no one of the sixteen receipts prints the generated `.pc`.

---

## Lessons

Each entry is *condition* (when it arises) / *symptom* (what you see) / *fix*
(what to do) / *target bound* (what it is and is not bound to).

### L1 — Upstream headers are noisy on a stricter compiler, and upstream already has the answer

* **Condition.** A translation unit that `#include`s a third-party header as a
  *consumer* of the library, on a toolchain that reports the header's warnings
  as errors.
* **Symptom.** 122 diagnostics, none of them in your own code: the
  `alignof(expr)` GNU-extension pair at `src/s2/s2point_array.h:35,49`, and
  `-Wnullability-completeness` for every unannotated pointer in `s2loop.h`,
  `s2builder.h`, `s2builder_graph.h`, `s2boolean_operation.h`, `s2polyline.h`
  and `s2polygon.h`. Receipt:
  `local://foundation-expansion-s2geometry-repaired-debug-24.log` (129 errors
  total; the other 7 were real, see L7).
* **Fix.** Use a *system* include for the third-party roots on that one
  translation unit, and keep ordinary includes everywhere else. A system
  include suppresses warnings from the headers it names; it does not suppress
  an error and it does not touch the main file, which stays fully diagnosed.
  Do **not** reach for `-Wno-nullability-completeness`, `-Wno-gnu-alignof`,
  `-w` or `-pedantic-errors`: each silences the same diagnostics in your own
  source. Check the upstream build definition first — it may already define the
  arrangement (here: `S2_USE_SYSTEM_INCLUDES`).
* **Target bound.** The bridge translation unit, in every target. The S2 and
  Abseil libraries keep ordinary includes in all six, so every upstream
  translation unit is still diagnosed in full. Depends on `-Wsystem-headers`
  being absent from the driver's command line; if a future Zig adds it, this
  does nothing and the arrangement has to be revisited.

### L2 — 87 "compilation errors" that are a filesystem symptom

* **Condition.** A build cache directory on a volume that cannot hold the
  intermediate files the compiler writes.
* **Symptom.** A wall of `-Wnullability-completeness` warnings followed by
  `error: error opening '…/tmp/2784ce27afe5c1d5-s2builder.o.d': No such file or
  directory` and `error: 87 compilation errors`, on a source tree that compiles.
  Receipt: `local://foundation-expansion-s2geometry-neighbor-smoke-153.log`.
* **Fix.** Move the cache onto a volume that can create the directory, and
  re-run. Do not "fix" it with `-fno-sanitize` or a warning switch: the
  diagnostics above the fatal one are warnings, and the fatal one is a path
  that does not exist.
* **Target bound.** None — it is where the cache lives, not what is being
  built. It appeared on the native x86_64-linux Debug run and would appear on
  any target.

### L3 — `translate-c` gives a C enum the unnamed integer type

* **Condition.** Switching on a C enum that came through `addTranslateC`.
* **Symptom.** `error: type 'c_uint' has no members` at the `switch`, on the
  field names. The generated module contains
  `pub const enum_S2BridgeStatus = c_uint;` and the enumerators as top-level
  `c_int` constants, not as an enum type.
* **Fix.** Compare the status against the emitted top-level constants, and give
  the comparison an `else` that maps an unrecognised non-zero value to an error
  rather than to success. Otherwise a bridge that grows a status value becomes
  a silent pass.
* **Target bound.** Every target. The translation is the same on all six; only
  the C types behind the constants vary.

### L4 — A parameter may not shadow a declaration of the enclosing scope

* **Condition.** A method parameter named the same as a method, a field or a
  constant of the same struct.
* **Symptom.** `error: function parameter shadows declaration of 'face'` and
  `error: function parameter shadows declaration of 'pos'`, each with a note
  pointing at the other declaration. Receipt:
  `local://foundation-expansion-s2geometry-latest-smoke-89.log`.
* **Fix.** Rename the parameter. `CellId.fromFacePosLevel(face_index,
  hilbert_pos, target_level)` was the only collision in this package, found by
  checking every parameter of every struct against all 37 declared `CellId`
  names.
* **Target bound.** Every target. This is a compile-time error in the facade,
  independent of architecture.

### L5 — `std.math.pi / 2` is `comptime_float / comptime_int`

* **Condition.** Dividing `std.math.pi` (a bare `comptime_float`) by an integer
  literal in any context that needs a result type.
* **Symptom.** `error: ambiguous coercion of division operands 'comptime_float'
  and 'comptime_int'; non-zero remainder '1.1415926535897933'`.
* **Fix.** Divide by `2.0`. `std/fmt/float.zig` widens `comptime_float` to
  `f128` for `{d}` rendering, so the printed digits are unchanged — which is
  worth checking, not assuming, before leaving a fixed-precision expectation
  alone. In this package: 2 in `smoke.zig`, 2 in `consumer/src/main.zig`, 8 in
  `tests.zig`.
* **Target bound.** Every target, and every optimisation mode: it is a
  comptime evaluation, so it fails the same way everywhere.

### L6 — `try self.options()` hands a temporary's address to C

* **Condition.** A helper that returns a struct **by value**, whose result is
  then passed to a C function that takes a pointer to it.
* **Symptom.** `error: expected type '[*c]const T', found 'T'`, naming the
  `try self.options()` expression. Receipt:
  `local://foundation-expansion-s2geometry-api-smoke-proof-111.log`.
* **Fix.** Bind the value to a `const` local that outlives the synchronous
  call, and pass its address: `const native_options = try self.options(); …
  &native_options`. Name the local so it does not shadow the helper. This is
  also the shape a C++ reviewer expects — the pointer must be to storage, not
  to a temporary whose lifetime ends at the end of the full expression.
* **Target bound.** Every target; all eight `Coverer` methods were affected.

### L7 — An upstream precondition that is only a debug assert vanishes in ReleaseFast

* **Condition.** A public upstream function whose only guard is an
  `ABSL_DCHECK` or an `assert`.
* **Symptom.** In Debug, the process aborts on upstream's assert. In an
  optimized build, the same input silently produces an answer from undefined
  state.
* **Fix.** Re-check the condition in the bridge with an ordinary comparison and
  report `S2BRIDGE_INVALID_ARGUMENT`. Every one of these was a real error in
  the first bridge compile: `min_level <= max_level`, `level_mod` in 1..3, the
  cell level, the `parent` level, the neighbour levels, the `i`/`j` range of
  `FromFaceIJ`, and the unit-length requirement on `S2Cap::Contains` and
  `S2Polygon::Contains`. For the last one, use upstream's own tolerance —
  `S2::IsUnitLength` accepts `|‖v‖² − 1| ≤ 5 * DBL_EPSILON`
  (`src/s2/s2pointutil.cc:32-40`) — because a different tolerance would reject
  points upstream accepts, including the `sqrt(0.5)` vertices the wedge
  demonstration needs.
* **Target bound.** Every target, and it is *worse* in the optimized modes,
  which is the opposite of the usual intuition about assertions.

### L8 — A test helper can carry a bound the API does not

* **Condition.** Reading a precondition off an upstream *test* rather than off
  the implementation.
* **Symptom.** `allNeighbors(30, …)` is refused as `InvalidArgument`, and the
  only published justification — `level < kMaxLevel` at
  `src/s2/s2cell_id_test.cc:551` — reads like a real limit.
* **Fix.** Read `AppendAllNeighbors` itself
  (`src/s2/s2cell_id.cc:556-598`): the only body checks are
  `ABSL_DCHECK_GE(nbr_level, level())` and `nbr_size <= size`, and
  `GetSizeIJ(30)` is 1 (`src/s2/s2cell_id.h:611-614`), so level 30 is inside the
  range. The `level < kMaxLevel` in the test belongs to the helper
  `TestAllNeighbors`, which then calls `child_begin(level + 1)` and needs one
  level of headroom the API does not. golang/geo's refusal of 30 is a Go-side
  choice, not the C++ contract.
* **Target bound.** Every target; the bound is in the bridge, which is compiled
  the same way everywhere.

### L9 — A published fixture is a list, not a set

* **Condition.** A test that compares a neighbour enumeration against a
  published answer.
* **Symptom.** "all neighbours are distinct" fails on a corner cell, and
  deduplicating the actual result to make it pass would be the wrong fix.
* **Fix.** State the contract (`src/s2/s2cell_id.h:469-475` allows a repeat at
  a face vertex; only edge neighbours are distinct,
  `src/s2/s2cell_id.h:456-458`) and compare multisets: equal length and equal
  occurrence count per cell. A set comparison is *too weak* here — it would
  pass a result that dropped a duplicate.
* **Target bound.** Every target; the repetition is a property of the
  geometry, not of the build.

### L10 — A constructor that does not normalize makes orientation the caller's

* **Condition.** Building an `S2Polygon` from a vertex chain and reading an
  area.
* **Symptom.** A triangle of solid angle π/2 measures 7π/2 — the whole sphere
  minus the triangle. Receipt:
  `local://foundation-expansion-s2geometry-isolated-cache-smoke-157.log`
  (`error: AreaMismatch` at the overlap assertion, with
  `|X or Y| = 10.995574287564276` where π/2 ≈ 1.5708 was expected).
* **Fix.** Order the vertices counter-clockwise seen from outside.
  `S2Polygon::Init` hands the loop through unchanged
  (`src/s2/s2polygon.cc:406-414`) and `S2::GetArea` maps a negative signed area
  to `area + 4π` (`src/s2/s2loop_measures.cc:51-55`). Check orientation with the
  determinant of the first three vertices: positive means a shell.
* **Target bound.** Every target. A second, quieter form of the same fault is
  that a *hole* with all four of its boundary arcs on the equator is a
  degenerate great circle, not a hole; that one was caught in review, not at
  run time.

### L11 — A stale version line inside a tag is upstream's, not this fork's

* **Condition.** Reading a version out of an upstream build definition when the
  package manifest needs one.
* **Symptom.** `build.zig.zon` says `0.14.0`; `CMakeLists.txt:7-8` says
  `project(s2-geometry VERSION 0.12.0)` inside the v0.14.0 tag.
* **Fix.** Use the tag, leave the CMake line exactly as shipped, and put a
  comment next to `.version` saying which is which. "Fixing" one of the two
  by accident is worse than the inconsistency.
* **Target bound.** None — this is a record-keeping fact.

### L12 — Two integrity checks answer two different questions

* **Condition.** Wanting to know whether the tree is still the pinned upstream.
* **Symptom.** Reaching for one check and thinking it covers the other.
* **Fix.** Keep both, and say what each is.
  `git diff --exit-code c24b368c… -- src` answers "is `src/` still the pinned
  commit?". `sha256sum -c UPSTREAM.sha256` answers "are the bytes this build
  compiles, installs, reads and licenses the recorded ones?". Neither is a
  signature, neither is a Git object id, and the `git archive` digest
  `6e49b320…` in `UPSTREAM.md` is a third number again — a digest of the
  commit's tree as `git archive` serialises it. The Abseil archive digest
  `8b39fdb7…` is a fourth, for the same reason. An integrity record over a
  subset and an archive digest over a whole tree are different numbers and must
  not be presented as one.
* **Target bound.** Neither is a signature and neither depends on a target.
  Both have now been run and both passed — `…-pinned-native-pristine-diff-268.log`
  (exit 0, empty output) and `…-immutable-native-dependency-fixture-integrity-231.log`
  (exit 0, 926 records `OK`) — and both are wired into the CI `provenance` job
  (§12). An earlier revision of this entry said neither had been run and that
  `sha256sum -c` was not wired into CI at all; that was true when written and is
  kept here only to show the record was behind the tree.

### L13 — `-fsys` is fed by the build runner, not by the `-D` map

* **Condition.** Forwarding a system-integration choice to a nested build.
* **Symptom.** `zig build consumer -fsys=s2` installs the bundled library and
  then proves the consumer against the installed one, reporting two builds as
  one. The nested graph calls `b.systemIntegrationOption` again and falls back
  to this package's own default.
* **Fix.** Forward `-fsys=s2` or `-fno-sys=s2` as an *argument* to the nested
  invocation, and give the nested build a subdirectory of the outer cache
  directory so two graphs never write the same manifest directory. Do not
  document this option as `-Dsystem=…`: `systemIntegrationOption` is not an
  entry in the `-D` map.
* **Target bound.** Native runs of the consumer step. A cross target only
  *builds* the consumer, because a foreign binary cannot be executed here.

### L14 — An inherited workflow that publishes to another maintainer's infrastructure is deleted

* **Condition.** A fork whose upstream ships a release workflow targeting
  infrastructure this repository cannot own.
* **Symptom.** A tag in this repository attempts an upload of s2geometry wheels
  to PyPI under Google's `pypi` environment.
* **Fix.** Delete the file. Do not repoint it, do not gate it off, do not leave
  it beside this fork's own — an inherited workflow is not a starting point to
  adapt when its whole job is someone else's release.
* **Target bound.** None. See Decision 1 for the disclosure.

### L15 — A generalisation past a published fixture is invented data

* **Condition.** One upstream publishes an answer for one case, and the
  pattern suggests it holds for the others.
* **Symptom.** A fixture row for "edge neighbours of face 3" that nobody ever
  published. The same shape appears in "the covering of a cell is exactly that
  cell" (published, `src/s2/s2region_coverer_test.cc:72-87`) versus "the leaf
  cell of (0,0) is 1000000000000001" (never published anywhere).
* **Fix.** Publish the row that exists and leave the other alone, and say in
  the fixture header *why* it is absent. An oracle that contains an invented
  row is worse than a smaller oracle, because it will fail for the wrong
  reason.
* **Target bound.** None — this is a fixture-integrity rule. Both cases were
  caught by reading the sources, not by running anything.

### L16 — A green smoke root proves only what the smoke root called

* **Condition.** Treating a passing example as evidence about the library.
* **Symptom.** `smoke.zig` was green while `tests.zig` had seven compile
  errors, because `smoke.zig` and `tests.zig` are separate roots from the same
  published module and only one of them calls every method.
* **Fix.** `zig build check` attaches **both** roots to every target's step, so
  a facade that only one root references is still analysed. The two roots are
  separate on purpose: `smoke.zig` compiles the facade the way an ordinary
  program would, through the published module only.
* **Target bound.** Every target. On a cross target nothing runs, so the
  evidence is compile evidence and nothing more.

### L17 — Optimisation mode is not a workaround

* **Condition.** A Debug failure that a ReleaseSafe or ReleaseFast build
  survives.
* **Symptom.** The temptation to record "passes in ReleaseSafe" as a pass.
* **Fix.** Record the mode the fault appeared in and the mode it disappears in,
  and claim neither. In this package the recorded Debug run shows the library,
  the bridge and the facade compiling and linking while `tests.zig` alone
  failed to compile — which is a statement about the test file, not about the
  library, and about Debug, not about the code.
* **Target bound.** Every target and every mode; the point of the rule is that
  the *claim* has to name the mode, whatever the target.

### L18 — A compiler version does not establish a target's defaults

* **Condition.** Deciding that an upstream compiler flag is unnecessary because
  the compiler this build drives is newer than the bug the flag's comment names.
* **Symptom.** `-fsized-deallocation` was dropped on the strength of
  `DW_AT_producer: clang version 21.1.0` in this package's own objects, against
  an upstream comment scoped to "a bug with clang < 19". `zig build check
  -Dtarget=x86_64-windows-gnu` then failed with two errors —
  `no matching function for call to 'operator delete[]'` at
  `src/s2/util/bitmap/bitmap.h:718` and `no matching function for call to
  'operator delete'` at `src/s2/util/coding/coder.cc:62` — because
  `src/s2/util/coding/coder.cc:62` and `bitmap.h:718` call sized delete
  explicitly and the target's default declaration set does not declare it.
  Receipt: `local://foundation-expansion-s2geometry-check-x86_64-windows-gnu-235.log`.
  Restoring the flag: `…-resume-check-x86_64-windows-gnu-254.log`.
* **Fix.** Read the declarations the target actually offers, not the compiler's
  version banner. `DW_AT_producer` is evidence about which compiler ran, and
  nothing about which language features that target enables by default. Keep the
  flag when upstream requires it and let a compile on the *narrowest* target
  decide, not a banner.
* **Target bound.** Every target Zig compiles for, but it surfaced on
  `x86_64-windows-gnu` first and would not have surfaced at all on the ELF
  targets. Bound to the version claim, not to the flag: the same reasoning
  applies to any upstream flag justified by a compiler-version comment.

### L19 — A counting pass that materialises the list cannot answer the count

* **Condition.** A two-pass buffer API whose counting pass walks the whole
  result to discover its length, when the length has a closed form.
* **Symptom.** `s2br_cell_children(0x1000000000000000, 30, nullptr, 0, &count)`
  — a counting call with no buffer — printed `children status=3 count=0`:
  `S2BRIDGE_OUT_OF_MEMORY`, and no required count. Level 0 to level 30 is
  4³⁰ = 2⁶⁰ cells; the implementation built a `std::vector` of all of them
  before answering a question about its length. Receipt:
  `local://foundation-expansion-s2geometry-review-before-children-278.log`,
  run under `ulimit -v 262144`.
* **Fix.** Answer the length without building the list, and only build it on the
  filling pass. The count and the fill must still agree exactly, so derive the
  count from the same upstream range the fill walks — here `child_begin`/`child_end`
  (`s2/s2cell_id.h:344-347`), which is what the facade already documents. A
  counting pass that can fail where a filling pass would not is worse than no
  counting pass, because the caller has no way to size a buffer at all.
  **Implemented in this tree, ungated.** `s2br_cell_children` now subtracts
  `child_begin(level).distance_from_begin()` from
  `child_end(level).distance_from_begin()` — upstream's own constant-time count
  of `next()` steps (`s2/s2cell_id.h:360-363`), documented as callable on
  `End()` as well as on valid ids — allocates nothing, and refuses a span a
  `size_t` cannot represent instead of reporting it wrapped. A short buffer is
  refused before the traversal begins. The ABI is unchanged: `out == nullptr`
  with `cap == 0` still means "tell me the count". **No gate has observed it.**
* **Target bound.** Every target; the arithmetic is the same everywhere. The
  observed failure is specific to a bounded address space, which is how the
  probe exposed it rather than a target property.

### L20 — An invalid polygon must not reach a `CHECK`

* **Condition.** Caller data reaches an upstream assertion, either while an
  upstream constructor computes an orientation, or while a boolean operation
  validates the loop it is about to build — and in both cases the only
  validation in between is an `ABSL_DCHECK` or a constructor that accepts
  anything.
* **Symptom.** Two aborts, both exit 134, and they are **different bugs at
  different depths**:
  * *In the constructor.* A triangle with finite vertices of squared norm 2
    reaches `s2pred::OrderedCCW`, which CHECKs `a.Norm2() <= 2`, and dies at
    `s2predicates.h:394] Check failed: a.Norm2() <= 2 (4 vs. 2)` through
    `s2pred::TriageSign` ← `s2pred::Sign`. `s2br_polygon_create` never returns,
    so there is no status to map and no handle to free. Receipts
    `…-review-before-union-279.log`, `…-review-before-intersection-280.log`.
  * *In the boolean operation.* Four **unit-length** vertices with
    `k = 1/√3` are accepted: `s2br_polygon_create` returns `S2BRIDGE_OK` and
    `s2br_polygon_is_valid` correctly reports the polygon invalid. The abort
    comes later, validating the operation's **output** loop —
    `s2polygon.cc:249] Shape 0 has one or more edges with interior on the
    right.`, `s2loop.cc:212] Edge 0 crosses edge 2`, then
    `s2loop.cc:357] Check failed: IsValid()`, which is `S2Loop::Init` asserting
    on the index its own `FindValidationError` just produced. Receipts
    `…-review-topology-before-union-282.log`,
    `…-review-topology-before-intersection-283.log`.
* **Fix.** Validate in the bridge with ordinary comparisons and report a
  status; never let caller data reach an assertion. This is L7's rule, and it
  applies at two different places, which is the whole point: the constructor
  needs the unit-length bound that upstream only asserts, and the boolean
  operation needs a validity check on its *inputs* so that upstream never gets
  far enough to assert on its output. An abort is not a report — it kills the
  caller's process — so the contract that says "upstream failure is
  `S2BRIDGE_INTERNAL_ERROR`, caller error is `S2BRIDGE_INVALID_ARGUMENT`, and
  `*out` stays null" is only meaningful if nothing aborts first.
* **Target bound.** Every target; both checks are in the bridge, compiled the
  same way everywhere. The two must not be merged: the first is a missing bound
  on the constructor's own vertices, the second a missing validity check before
  a boolean operation, and a fix for either alone leaves the other aborting.
  **Implemented in this tree, ungated, in three pieces.**
  `AllUnitPoints` checks the whole vertex chain against upstream's own
  `S2::IsUnitLength` tolerance before any vertex is turned into an `S2Point`,
  and `NativeCountFits` proves the count is one upstream's `int` and the
  caller's `size_t` can both hold before the array is read at all.
  `RequireValidOperand` asks `S2Polygon::IsValid()` of each operand *before*
  `InitToOperation` and maps a false answer to `S2BRIDGE_INVALID_ARGUMENT`, and
  `DeferValidation` sets the deferred-validation override on every loop and
  polygon this bridge constructs, so `S2Loop::InitIndex`'s fatal
  `ABSL_CHECK(IsValid())` never runs on a chain `s2br_polygon_is_valid` exists
  to report. The boolean overloads that are bound take upstream's `S2Error`
  out-parameter and its documented snap function, and a failed build is
  `S2BRIDGE_INTERNAL_ERROR` with the partial output released through a
  `unique_ptr` and `*out` left null. **No gate has observed any of it.**

### L21 — A narrowing on the way across undoes the check on the other side

* **Condition.** A Zig parameter that is wider than the C type the bridge
  declares, where the bridge *does* bound the value — so the bound looks
  covered when you read the C side.
* **Symptom.** `loop.vertex(std.math.maxInt(usize))` kills the process:
  `thread 10211 panic: integer does not fit in destination type` at
  `zig/root.zig:956`, on `try check(c.s2br_loop_vertex(self.handle, @intCast(i), &xyz));`.
  Receipt: `local://foundation-expansion-s2geometry-facade-index-before-run-347.log`,
  exit 134; the same probe compiled clean first
  (`…-facade-index-before-compile-346.log`, exit 0). The bridge's own guard
  compares `i` against `num_vertices` with an ordinary comparison — and never
  runs, because the `@intCast` traps first.
* **Fix.** Bound the value on the **Zig** side of the conversion, with an
  ordinary comparison against the C type's range, and report
  `error.InvalidArgument`. Decision 7 is the same rule for `Coverer.max_cells`
  and was written down before this happened; the generalisation is that any
  parameter or field crossing into a narrower C type needs the check where the
  conversion is, not where the value is used. Five methods take a `usize` index
  and are in scope: `Loop.vertex`, `Loop.vertexLatLng`, `Polygon.loopNumVertices`,
  `Polygon.loopVertex`, `Polygon.loopVertexLatLng`. `Cell.vertex` takes a `u8`
  and cannot overflow a `c_int`, so it was never affected — which is the test
  for whether a given method is in scope at all.
  **Implemented in this tree.** One private helper, `fn asIndex(i: usize)
  Error!c_int` (`zig/root.zig:145-148`), returning `error.InvalidArgument`
  above `maxInt(c_int)` and converting otherwise; all five methods call it, and
  no signature changed. **Gated only against the already-installed bridge**: the
  after-probe compiled (348, exit 0) and ran (349, exit 0, `oversized public
  vertex index rejected as InvalidArgument`) with the current `root.zig` linked
  to a native archive that predates it. A full recompile-and-gate is still open.
* **Target bound.** Every target; the trap is in the facade and compiles the
  same way everywhere. The *panic* only aborts in Debug and ReleaseSafe, where
  Zig's safety checks are on — in ReleaseFast the narrowed value would instead
  be an out-of-range index for the C side to reject, which is the quieter and
  worse failure. That inversion is the same shape as L7.

### L22 — A coupled correction does not attribute a cause

* **Condition.** A build fails; the fix touches more than one thing at once; the
  next run is green. The temptation is to write down which part mattered, and
  the temptation is strongest when one part *has* a story that explains the
  symptom exactly.
* **Symptom.** `compile lib s2bridge` failed with 119 diagnostics —
  `-Wnullability-completeness` from upstream headers reached through
  `zig/bridge.cc:30`, `src/s2/s2builder.h:473` first — on native Debug and
  ReleaseSafe and four cross targets (313, 314, 316, 317, 319, 320). What was
  actually recorded in those runs is **117 header diagnostics alongside 2
  errors in this repository's own C++** (`BooleanOp.kIntersection` and
  `BooleanOp.kUnion` instead of `::`, at `zig/bridge.cc:1368` and `:1378`). The
  repair changed the header ownership / system-include roots **and** the `::`
  syntax together, and the next run was green. This revision's author then
  wrote a confident cause into four documents — first the system-include
  classification, then, when told that was wrong, the two typos and the
  plausible mechanism that "a failed parse takes the whole include graph with
  it". **Neither is established.** No experiment varied one correction while
  holding the other fixed.
* **Fix.** When two things change together and the symptom goes away, record
  *that the coupled change worked* and nothing more. Do not promote one half to
  a cause, and do not retire the other half either — "the system-include
  classification is disproven" is exactly as unfounded as "the typos caused all
  119". If the cause matters, the way to get it is a run that changes one
  thing; without one, both stories stay open. The second failure here was not
  being wrong twice by accident: the first retraction was accepted and replaced
  with an equally confident new story, which is the same error at a different
  address.
* **Target bound.** None. The mechanism is not about C++ or include paths at
  all; it is about what a green run after a coupled change does and does not
  license you to write. It bound hardest here because both available stories
  were *plausible*, and plausibility is what makes a story get written down
  confidently.

### L23 — "Is this target the host?" and "can the host run this target?" are different questions

* **Condition.** A build script branches on the selected target to decide
  whether to *run* something, and the branch reads like a capability check —
  "a cross-compiled binary cannot be executed here".
* **Symptom.** The step compiles, `test success` is printed, the build summary
  is all green, and **nothing executed**. Observed here through `cross-test`
  on `x86_64-linux` — the host's own triple — run `20261002-033134-17908-30770`:
  `Build Summary: 9/9 steps succeeded`, `compile test s2-tests Debug
  x86_64-linux success`, no `run` line, harness reason `no_test_results`, exit 1.
  The branch was `target.query.isNative()`, which reads as "native" but is
  `isNativeTriple() and ofmt == null`; `isNativeTriple()` demands `cpu_arch`,
  `os_tag` and `abi` all null (`lib/std/Target/Query.zig:392-398`), so *any*
  explicit `-Dtarget=` is false, including `-Dtarget=x86_64-linux` on x86_64
  Linux. The name is accurate; the assumption that it answers the question the
  branch was asking is not.
* **Fix.** Do not answer the capability question in the build script. Build the
  run artifact unconditionally, set `has_side_effects`, and let the build
  runner resolve it — it is the component that owns foreign execution. Be
  precise about what it does: `std.Build` on its own **fails**, naming the
  binary, both triples and the flag to use, unless the run step sets
  `skip_foreign_checks` (`lib/std/Build/Step/Run.zig:2753-2777`). It is the
  **harness's** build runner that distinguishes "ran" from "could not run here"
  and classifies the latter itself. So a harness driving
  `zig build <step> -Dtarget=…` through such a runner gets real per-target
  execution counts for the targets it can run and honest compile-only results
  for the ones it cannot — which is exactly the distinction a test gate exists
  to make — while a bare `zig build test -Dtarget=<foreign>` with no runner
  fails loudly, naming the target. Guarding the run is doubly wrong: it loses
  the host's own triple whenever the gate names a target explicitly, and it
  forecloses foreign execution completely.
* **Target bound.** Bound to the build-API shape, not to a target: any Zig
  version whose `Target.Query.isNative()` means "no target was named" behaves
  this way, and it is bound to *any* explicit `-Dtarget=`, including the host's
  own. It is not bound to C++, to this package, or to the harness — a plain
  `zig build test -Dtarget=<foreign>` outside a cross harness simply fails,
  which is honest and is what `zig build run -Dtarget=<foreign>` has always
  done. A gate that never passes a target at all will not see this at all, so
  a package can look correct for a long time and be wrong the first time it is
  driven with `-Dtarget=` on the machine that can run it.

### L24 — A syscall offset unit is not the machine's page size

* **Condition.** The full matrix exposed Linux Hexagon's missing hosted
  context/exit paths and real `mmap2` ABI, alongside PowerPC32 musl's embedded
  register context.
* **Symptom.** A real file-offset probe failed with the byte-offset branch.
  An initial `mmap2` branch using `AT_PAGESZ` units also failed, `errno=22`.
* **Fix.** Use fixed 4096-byte syscall units on Hexagon, as pinned musl does.
  With `page_size=65536 offset=65536`, libc and DirectMmap both read `B`.
  The other three bounded native changes use the actual PPC32 musl/Hexagon
  context fields and hosted `unistd.h` `_exit` declaration; glibc/PPC64 and
  freestanding branches remain.
* **Target bound.** The causal nonzero-offset proof is real Hexagon execution,
  not a preprocessor alias or a zero-offset mmap. At this entry's revision
  exactly four native files differed from the canonical whole-vendor pin, each
  with a prominent change notice and pristine/current SHA pair; **the current
  deviation set is 1 S2 path + 7 Abseil paths** (decisions 18, L25–L28, and
  `CHANGELOG.md` §§50–52), so the four-file guard this entry names is scoped,
  not current. No math, ABI, fixture or source closure was replaced. Receipts:
  `local://foundation-cross-test-evidence.json`,
  `local://foundation-cross-test-hexagon-mmap-proof.cc`,
  `local://foundation-cross-test-s2-approved-vendor-diff.json` and
  `local://foundation-portability-canonical-source-provenance.json`.

### L25 — A missing platform capability is not a missing platform

* **Condition.** A target's own headers refuse a facility, and the whole
  vendored closure cascades the refusal from many files.
* **Symptom.** `wasm32-wasi` reported `signal.h:2:2: error: "wasm lacks signal
  support"` plus 38 more, with missing `std::mutex` and `<fstream>` behind it.
  Read literally, that says the target cannot host the closure.
* **Fix.** Check whether a *real provider* for that target exists before
  concluding it cannot host it. WASI SDK 34 with the WASIp1-threads ABI
  supplies all three — its `libwasi-emulated-signal.a` for the synchronous
  signal path, a real EH libc++ for `std::mutex` and `<fstream>`. The
  compile-time consequence is the opposite of the earlier reading: with a
  complete provider installed, the whole 261-unit closure links and runs.
* **Target bound.** Bound to "this target's **stock bundled** provider", not to
  the target. The earlier sentence is `WITHDRAWN` as a statement about WASI. It
  is still exactly true of a build that supplies no `-Dwasi-sysroot`, and the
  two provider libraries are the SDK's **documented emulation**, so this is not
  a claim about a POSIX signal namespace or a host PID. Receipts:
  `local://foundation-portability-complete-cxx-provider-proof.json`,
  `local://foundation-portability-s2-wasi-corrected-sdk-gates.log`.

### L26 — Two halves of one binary must agree about the libc's threading model

* **Condition.** A build links some modules against a foreign libc while other
  modules keep the language runtime's defaults.
* **Symptom.** A call the C side reported as successful returned a wrong answer
  to the Zig side, with no diagnostic: measured single-threaded,
  `sdk_errno=28 zig_errno=0 sdk_addr=0x1000000 zig_addr=0`, run exit 86. Two
  different addresses for one `errno` means two different variables, not a
  stale read.
* **Fix.** Match the libc's threading model on **every** module that shares it,
  in one function, not at call sites. `lib/std/c.zig:7096` selects
  `private.errnoFromThreadLocal` on `.wasi`, which is not the SDK's
  `__errno_location()`. `sizeof(SDK errno)` being right is irrelevant when the
  address is wrong. Also note that a **null** `Module.single_threaded` emits no
  flag at all (`lib/std/Build/Module.zig:546`, `addFlag` returns on null), so a
  module left unset silently keeps the target default while its siblings are
  told otherwise.
* **Target bound.** Bound to `wasm32-wasi` + libc in Zig 0.16, but the shape is
  general: any target whose default threading model differs from the libc you
  linked. Receipt: `local://foundation-portability-wasi-sdk-errno-single-proof.json`.

### L27 — A module import propagates neither `libc_file` nor a link ABI

* **Condition.** A dependent links an artifact built by a dependency and needs
  the dependency's final-link configuration to be valid.
* **Symptom.** The library's own tests pass and a dependent executable built
  from the same module does not link correctly, or links with a different
  memory model.
* **Fix.** `std.Build` keeps `libc_file`, `import_memory`, `export_memory`,
  `shared_memory` and `max_memory` on `Step.Compile`, not on `Module`, so no
  import carries them. Copy them off `dep.artifact("…")` — the artifact that
  already holds them — instead of restating the sysroot path and the size in
  the dependent. Two hardcoded copies of one fact is how a dependent ends up
  claiming a 256 MiB shared memory the library never allocated.
* **Target bound.** Bound to Zig 0.16's `std.Build` field placement, not to a
  target. The *values* are WASI-specific; the rule is not. A future build
  system that moves these onto `Module` removes the copy, not the rule.

### L28 — Stock Zig 0.16 cannot compile a threaded libc-linked `wasm32-wasi` build

* **Condition.** Target `wasm32-wasi` with libc, `single_threaded = false`, and
  the SDK's shared-memory threading model.
* **Symptom.** Two hard compile errors in the standard library itself:
  `lib/std/Io/Threaded.zig:959:50: error: expected type 'i64', found 'u64'` — the
  wasm `memory.atomic.wait32` timeout assigns a `u64` nanosecond count to an
  `i64`, where any negative value means *wait indefinitely* — and
  `lib/std/heap.zig:16:74: error: unimplemented`, because `WasmAllocator` is
  `@compileError("unimplemented")` for `!builtin.single_threaded`.
* **Fix.** Two hunks in a copy of `lib`, selected with the standard
  `--zig-lib-dir`: saturate a finite timeout to `maxInt(i64)` (`null` stays
  `-1`), and select the real `c_allocator` for
  `arch.isWasm() and os.tag == .wasi and link_libc and !single_threaded`
  instead of instantiating `WasmAllocator`. Ship it as a patch file with its
  upstream terms copied verbatim beside it; never edit the installation.
* **Target bound.** Bound to Zig 0.16.0 and this one target combination. Every
  other WebAssembly OS, every native path, the single-threaded and non-libc
  cases, and the `root.os.heap.page_allocator` override keep upstream's
  selection, so the "unimplemented" diagnostic still honestly reports the
  genuinely unsupported case. Receipt:
  `local://foundation-portability-wasi-sdk-errno-multi-compile-failure.json`.

### L29 — A trap sanitizer's trap is the evidence; a mismatched runtime signature is not

* **Condition.** Enabling C/C++ UB detection on `wasm32-wasi`.
* **Symptom.** Zig 0.16's `ubsan` runtime emits a one-argument
  `nonnull_return_v1` Wasm signature the runtime does not match. Silently
  choosing `.off` would remove real detection; keeping `ubsan` does not
  compile.
* **Fix.** Select `.trap`, which preserves fatal UB detection without that
  runtime. Measured: a mixed C++ nonnull-return violation reached
  `cpp_nonnull` and died with a real Wasm `unreachable` trap, exit **134**
  (`local://foundation-portability-wasi-ubsan-sdk-closure-proof.json`). The
  trap is the evidence, so it is kept; the runtime that could not trap
  correctly is what got dropped.
* **Target bound.** Bound to Zig 0.16's UBSan runtime signature on Wasm. The
  exit-134 trap is the same shape a native `-fsanitize=undefined` trap has, so
  the rule generalises even though the signature bug does not.

### L30 — A provider prerequisite can be a plain command-line option

* **Condition.** A runtime deprecates a flag this package's binaries need.
* **Symptom.** wasmtime 46.0.3 prints, on every run,
  ``WARNING: the `-Sthreads` flag will be a hard error in Wasmtime 47.0.0 on
  2026-07-20`` — and Wasmtime **49 and later dropped the threads feature**
  entirely, so a newer runtime cannot run a WASIp1-threads module at all.
* **Fix.** State exactly what was observed and nothing more: the runtime
  actually provisioned and exercised here is **46.0.3**, and it is the only one
  with a receipt behind it. Record that 46.0.3 deprecates `-Sthreads` into a
  hard error in 47.0.0 and that 49+ dropped threads, and then stop. **Do not
  convert those two facts into a tested range** — a deprecation warning is not
  evidence that the remaining flags and this module still work on a release
  nobody ran, so "46, 47 or 48" would be a compatibility claim with no
  observation under it. Any broader range is a hypothesis until a run makes it
  one. Keep the standard `-Sthreads=y` switch and edit no global tool to silence
  the warning; the warning is accurate.
* **Target bound.** Bound to Wasmtime's own release history. Nothing in this
  repository depends on a patched runtime, and the package's build does not
  download one.

### L31 — A std.Build flag is not propagated by a module import either

* **Condition.** A provider's contract includes a property that must agree
  across the library and every dependent, and Zig models it as a plain field.
* **Symptom.** A dependent that reads `exe_mod.single_threaded` from its own
  target resolution rather than from the library module disagrees with the
  library the moment either side gains a branch.
* **Fix.** Read it from `dep.module("s2geometry").single_threaded` — one
  property, one owner — and use `s2_module.resolved_target` for the dependent
  root's target so the two agree by construction rather than by coincidence.
* **Target bound.** Bound to `Module.single_threaded` being a non-propagating
  field in Zig 0.16. See L26 for the measured reason it matters and L27 for the
  fields that have no module-side copy to read at all.

### L32 — A named option and a resolved query are two different questions

* **Condition.** A build script branches on what the caller asked for, and it
  tries to read that back out of the resolved `Target.Query`.
* **Symptom.** `zig build check -Dtarget=native` compiled every target in the
  matrix. The literal `native` parses to the same empty query as no option at
  all (`lib/std/Build.zig:1498`, against the nothing-given test at `:1495-1496`),
  `resolveTargetQuery` returns the host for both (`:2704-2707`), and
  `Query.isNative` (`lib/std/Target/Query.zig:396-398`) is therefore true — for
  a caller who named exactly one target.
* **Fix.** Ask the question the option poses, over the option map:
  `b.user_input_options` holds every `-Dname=value` the caller passed
  (`lib/std/Build.zig:1167`), and the four names to look for are the standard
  library's own. Answering "was anything named" is not the same question as
  "is this the host", and a resolved target cannot recover which one the caller
  meant.
* **Target bound.** Bound to `standardTargetOptionsQueryOnly` parsing `native`
  into the default query in Zig 0.16. In a dependency the same map holds what
  the dependent forwarded, so the answer is the target it asked for either way.
  See Decision 19; the fix is unobserved.

### L33 — An outer build step is not the program's argument vector

* **Condition.** A step that shells out to a second `zig build` and expects that
  build to run a program.
* **Symptom.** `zig build consumer -- …` reported success and the program had
  received no arguments at all. The outer step forwarded its own options and
  dropped `b.args`; the nested run handed the *nested* build's `b.args` to the
  program (`consumer/build.zig`: `const run_exe = b.addRunArtifact(exe);` and then
  `if (b.args) |args| run_exe.addArgs(args);`), which was empty. The check that ran
  was narrower than the check that was asked for, and the summary showed neither.
* **Fix.** Forward `b.args` verbatim behind a `--`, after every option the outer
  step passes on its own. The runner ends option parsing at `--` and keeps the
  rest (`lib/compiler/build_runner.zig:428-430`), so the separator is what makes
  the remainder program arguments instead of build options — and it should be
  emitted only when there are any.
* **Target bound.** None; this is argument plumbing, and it is silent when it is
  wrong. See Decision 20; the forwarding is observed and the system-mode route is not.

### L34 — A predicate that says yes is not a gate that says yes

* **Condition.** A build script asks the standard library's executor predicate
  and then does something other than what `Step.Run` would do with the answer.
* **Symptom.** `consumer` chose `run` for a foreign GNU-libc target that had no
  runtimes directory, and the nested run failed afterwards. `Run` applies a
  second, refusal-shaped gate once the predicate has already said yes — its
  QEMU arm fails for `need_cross_libc` with no `--libc-runtimes`
  (`lib/std/Build/Step/Run.zig:1294-1311`) — and the `allow_*` options can carry
  the enable switches but not that refusal.
* **Fix.** Ask the question `Run` asks, with the options `Run` fills in:
  `qemu_fixes_dl` set from the same two facts, and the second gate mirrored in
  the arm that depends on it. Prefer installing over running a step that would
  fail, and say in the summary which happened. Forward the directory itself
  (`--libc-runtimes`) so the two graphs cannot disagree about the same target.
* **Target bound.** Bound to `Step.Run`'s own refusal list in Zig 0.16. A
  predicate that gains a new refusal later needs a matching arm here. See
  Decision 21; the native arm is observed and the fix is unobserved on any foreign
  GNU-libc target.

### L35 — A system mode links what is installed, and cannot own its closure

* **Condition.** A build script offers a system-library mode that links
  archives it did not compile.
* **Symptom.** The mode either hoists the bundled graph's providers into it — a
  framework and a system library required only by translation units it no longer
  compiles — or starts inspecting and completing the installed archives'
  dependencies on the host's behalf. Both replace a stated boundary with a
  guess: the first links a dependency no compiled unit needs, the second
  silently decides what another build's install is allowed to require.
* **Fix.** Name the providers that stay out and give the reason for each
  (requirement of a unit that is not compiled; a define that the installed
  build's own guard already resolves), then state the boundary in terms of the
  host: this build does not inspect the installed archives' link closure, does
  not name a system library on their behalf, and claims no result for a platform
  where they are not installed. The owner of an installed library owns its
  closure, through its export, its pkg-config file or its own link line.
* **Target bound.** A statement about scope, not a platform limit: it is true on
  every host, and it is what makes "the mode is unexercised" a fact about what
  is installed rather than about this package. See Decision 22.

### L36 — A relocated upstream file is renamed in the record, not dropped from it

* **Condition.** A fork replaces a file at a path upstream shipped, and keeps
  upstream's bytes somewhere else, while a whole-tree integrity record pins that
  path's digest.
* **Symptom.** Two wrong answers, in opposite directions. Leave the record's old
  path and `sha256sum -c` reports the file as modified — the relocation itself
  breaks the gate, and a reader "fixes" it by deleting the line, which drops the
  pin on upstream's bytes entirely and turns a loud failure into a silent hole.
* **Fix.** Move the record to the new path with the **same digest**, since the
  bytes are the same bytes; say in the record's own header that a rename happened
  and why, and list the new fork-authored files in the exclusion list by name so
  the next reader knows the omissions are deliberate. Re-derive only what
  actually changed — a rename is not a re-derivation.
* **Target bound.** Bound to record formats that name paths (`sha256sum -c`,
  manifest lists), not to any hashing algorithm. A record that stores content
  addressed by digest alone has no such field and needs no such move.

### L37 — A packaging layer that names a variant must verify the variant

* **Condition.** A wrapper passes an option to a build script — `-Dlinkage=`, a
  mode flag, an install flavour — and the build script does not define it (yet).
* **Symptom.** Nothing. The build runner ignores the unknown option, compiles the
  default graph, and the wrapper installs that under the name the variant
  advertises. The consumer then links a static archive where a shared object was
  promised, or the wrong architecture, and every intermediate report says green.
* **Fix.** Check the artifacts the requested variant must have produced, in the
  wrapper's own install phase, and fail the build when they are absent — before
  writing any metadata that describes them. Then say so in the documentation and
  the changelog as a named dependency on the build graph, with its exact option
  spelling, so the gap is visible to whoever owns `build.zig`.
* **Target bound.** Bound to wrappers around a build system whose unknown
  `-D` options are tolerated rather than rejected. Where the runner rejects an
  unknown option outright, the same check is redundant rather than wrong.

### L38 — The runtime search path must name the installed tree before the build cache

* **Condition.** A shared object that depends on another shared object the same
  build produces, where the loader's search order decides whether the result
  works after the install tree is moved.
* **Symptom.** It works in the build directory and fails, or silently loads a
  different copy, once the prefix is relocated — because the RPATH names a build
  cache directory that will not exist on the consumer's machine. Zig makes this
  the default shape: `module.linkLibrary(dependency)` inserts the dependency's
  own emitted-binary directory as a cache-first RPATH.
* **Fix.** Add the installed tree's own search token **before** the cache
  directory, and add it in an order you control — `$ORIGIN` on ELF,
  `@loader_path` on Darwin, matching what upstream's own shared build installs
  (`INSTALL_RPATH "$ORIGIN"` plus `CMAKE_BUILD_RPATH_USE_ORIGIN ON` in
  `vendor/abseil-cpp/CMakeLists.txt:44-46`). Taking the dependency's emitted
  object through `addObjectFile` instead of `linkLibrary` is what leaves the
  order under your control; then `addRPathSpecial` for the installed tree and
  `addRPath` for the cache, in that order. A test that moves the prefix after
  the build is the only thing that observes this; a build that passes in place
  observes nothing.
  A later repair took this one step further and split the two into separate
  artifacts, so that the installed object carries no build-cache path at all;
  that is L39, and it supersedes the ordering advice here for this package's own
  graph.
* **Target bound.** Bound to ELF and Darwin runtimes with a real search path.
  Windows resolves a dependency by name in the directory of the DLL that names
  it and has no equivalent knob, and `Module.addRPathSpecial` emits a bare
  `-rpath` with no target test, so adding one there hands the linker a switch it
  does not take — the correct action there is to add nothing. WASI has no dynamic
  loader at all and refuses shared delivery by name instead.

### L39 — An installed artifact and an in-tree artifact are two builds, not one RPATH

* **Condition.** One build script produces two consumers of the same sources: a
  library it installs, and executables that run from the build tree before
  anything is installed. The two need different runtime search paths, and only
  one of them should ever name a build directory.
* **Symptom.** Ordering `$ORIGIN` before the cache directory is not enough. The
  installed object still names a directory that will not exist on a consumer's
  machine, so a relocated prefix either falls back to a loader default or —
  worse — silently resolves a different copy if one happens to exist there. The
  build looks correct, and the defect appears only in the artifact that ships.
* **Fix.** Build the closure twice and let each consumer take the path it needs.
  The install graph gets the installed tree's token and **nothing else**; the
  in-tree graph gets that token plus the build-cache directory. Pass the choice
  as a parameter into the graph builder rather than deriving it from the
  delivery option, so both graphs come from one function and the two policies
  cannot drift apart. Configure the two identically where you can: Zig's runner
  reuses a compile whose inputs already match, so the duplicates you pay for are
  only the ones whose configuration actually differs.
* **Target bound.** Bound to build systems that can produce two artifacts from
  one source list. Where an install step can transform or copy a single output
  instead, that is cheaper and the lesson reduces to "the shipped object must not
  inherit the build tree's search path". Windows resolves a dependency by name
  in the directory of the DLL that names it and has no equivalent knob, and WASI
  has no dynamic linker at all; on both, the correct action is to add nothing.

### L40 — A devenv task inherits the caller's directory, not the SDK's

* **Condition.** A `devenv.nix` module whose canonical commands address a package
  by relative path — `zig build`, a `consumer/` subdirectory, an
  `UPSTREAM.sha256` — while the tool that runs them is invoked from somewhere
  else: a scratch project directory, a CI checkout, or another SDK's directory
  in one loop over many SDKs.
* **Symptom.** `error: no build.zig file found, in the current directory or any
  parent directories`, `cd: consumer: No such file or directory`,
  `sha256sum: UPSTREAM.sha256: No such file or directory`. The task ran, the
  command was right, and the directory was wrong. `DEVENV_ROOT` looks like the
  fix and is not: it names that same caller-side directory, because that is
  where devenv keeps `.devenv` and `devenv.lock`, and keeping its state out of
  the repository is right. A task-level `cwd` covers only the task: devenv
  materialises each `scripts` entry as a `/nix/store/…-<name>` program that
  inherits the caller's directory the same way.
* **Fix.** Every exec body starts by changing into a path the module computes
  for itself — `cd ${lib.escapeShellArg (builtins.toString ./.)}` — and
  `builtins.toString`, not `${./.}`: the second gives each generated program a
  store context, so the read-only store copy of the whole SDK becomes the tree
  the task reads, installs from and writes into, and it is a different tree from
  the one the integrity records describe. Two rules travel with it. A command
  that *installs* names an external `--prefix` under a location **the caller
  exported** — `$ZIG_LOCAL_CACHE_DIR`, else `$TMPDIR`, and an honest error naming
  both missing variables when neither is set — because the default is a `zig-out/`
  inside the package, and a package on a volume is not scratch storage. A fixed
  default such as `${TMPDIR:-/tmp}` is not that: it invents a storage location on
  the caller's behalf, and a system temporary filesystem is forbidden for build
  output. And a command that only compiles or runs is left alone rather than
  handed a prefix it would never use — with one case now recorded, because
  `sdk:consumer` installs nothing in *this* graph while the nested `consumer/`
  build it spawns does install: `addConsumerStep` forwards a caller-named
  `--prefix` to that build, so a prefix supplied to the task reaches it, and a
  task that supplies none leaves the nested build on its own
  `consumer/zig-out`.
* **Target bound.** Bound to devenv 2.4.1 modules driven from outside the SDK
  directory, and to package directories on storage the caller did not choose for
  build output. A task run from inside the SDK is unaffected — the `cd` is then a
  no-op — and nothing here argues for putting devenv's state in the repository,
  which is the opposite of what this workspace does.

---

## What is source-confirmed, and what has actually been run

Two columns, and the left one does not become the right one by being true.

| Claim | Source-confirmed | Observed |
|---|---|---|
| the pinned tree is upstream v0.14.0 at `c24b368c…` | yes, by the `git archive` digest in `UPSTREAM.md`; `UPSTREAM.sha256` carries a pristine/current pair for every compiled byte | **Historical only.** The S2-scoped `git diff --exit-code c24b368c… -- src LICENSE NOTICE CMakeLists.txt` was exit 0 with empty output at its revision (`…-pinned-native-pristine-diff-268.log`). It is no longer a valid pristine test, because `src/` now carries exactly one disclosed change. The current whole-closure comparison is `OBSERVED_CANONICAL_SOURCE_COMPARISON_PASSED`: **1 S2 path + 7 Abseil paths**, `extra_missing_paths = false`, every license prefix unchanged and a change notice on all eight — `local://foundation-portability-canonical-source-provenance.json` |
| Abseil pin and current deviation | Canonical `20250814.1`, commit `d38452e1…`, archive digest `8b39fdb7…`; **seven** disclosed native paths | **OBSERVED**: the canonical comparison names all seven with pristine/current SHA-256 pairs and `license_prefix_unchanged: true` on each. The older four-path whole-vendor receipt (`…-s2-approved-vendor-diff.json`) is scoped history; pristine receipt 286 and the 926-record receipt 231 likewise predate this wave |
| the S2 units, in upstream's order | yes, transcribed from the `add_library(s2 …)` block at `CMakeLists.txt:141-249` into `build_support/s2_sources.zig` | `libs2.a` was produced and linked in every run below. The old comptime assertion that guarded the list length no longer exists (decision 26) |
| the Abseil units, and the fourteen test/dependency exclusions | yes, against every `absl_cc_library` block in the vendored tree, now from `SRCS` **and** `HDRS` because `AbseilHelpers.cmake:234,260` compiles both | Compiled and linked in the observed native/baseline cells, and in the `wasm32-wasi` closure with the SDK provider. The one unit this fork's list had omitted — `absl/strings/internal/escaping.cc` — is in it now, unchanged, and the complete core list is retained rather than truncated to avoid a target failure. `local://foundation-contract-s2geometry-shared-origin-first-complete-native-closure-source-count-pin-removed.log` is the observed shared delivery of that corrected list: 25/25 steps, `install success` |
| the bridge entry points | the whole declared C surface of `zig/bridge.h`, counted from that header — a source fact, **not** evidence that it compiles | **YES**, compiled and linked in the green native and cross runs (393, 394, 397, 398, 399, 380, and again 417–422 after the boundary guards), after the 119-error interval (313/314/316/317/319/320). Every one of them resolves through the dispatch in a runtime-loaded build, and none is optional |
| the public facade methods | counted from `zig/root.zig` — a source fact, **not** evidence that any of them works | compiled in every green run, and `tests.zig` calls each with concrete argument types; **46/46 tests pass** in both modes (417, 418) |
| the tests, the fixtures and the smoke sections | read from the sources | **YES** — 46/46 in Debug and ReleaseSafe (417, 418), and every smoke section printed its published answer in the runtime-loaded 6/6 receipt |
| `-fsized-deallocation` is required on the S2 half | yes, `CMakeLists.txt:122-127` | **YES in both directions** — 235 fails without it, 254 compiles with it |
| `zig build smoke` passes with the published answers | — | **YES**, exit 0, `local://foundation-expansion-s2geometry-wedge-smoke-169.log` |
| `zig build install` produces the three archives | — | **YES**, exit 0, 12/12 steps, `…-installed-artifact-gruenau8-224.log` |
| the ELF shared closure's four objects | upstream's own sonames (`CMakeLists.txt:294-296`, `vendor/abseil-cpp/CMakeLists.txt:27`), `.pic` on the module that owns each library's sources, no export decoration anywhere in `src/s2` or in the vendored tree, and — on ELF only — `libs2cpp.so.0` from the pinned compiler's shipped libc++/libc++abi/libunwind with `_LIBCPP_ABI_VERSION=1` and upstream's shared-library visibility annotations (`build_support/cpp_runtime.zig`, `sharedCppOwner`, `configureSharedCpp`) | **OBSERVED, 2026-10-04**: sixteen native cells, all `exit 0` — "39/39 steps succeeded; 46/46 tests passed" native shared, "32/32" native static, "36/36" runtime-loaded dynamic, "33/33" runtime-loaded static, each with `smoke success` and `install success`. Every dynamic cell installs `s2cpp` and the three `LICENSE.*.txt` records; no static cell contains a `s2cpp` step. Receipts under `…/contract-physics-lua/current-native-evidence/`, index of all sixteen |
| the same, before the runtime artifact | as it was at that revision | **Historical.** The three-object shared install, "25/25 steps succeeded", `install success`, is `local://foundation-contract-s2geometry-shared-origin-first-complete-native-closure-source-count-pin-removed.log`. It installs; it runs no test and no smoke step, and its closure no longer exists |
| runtime-loaded static delivery, `-Dlinkage=static -Druntime=true`, against a separately supplied installed provider | one process-lifetime table per module, `LoadSource` naming `.path` or `.system` with no fallback, publication only after every symbol resolves and the SDK's own validation passes, no unload and no reset (`runtime/loader.zig`, `runtime/library.zig`) | **Historical — the previous, three-object closure.** "Build Summary: 6/6 steps succeeded", `smoke success`, provider `…/s2geometry-shared/lib/libs2bridge.so.0.14.0` named on the command line, every section printing its published answer — `local://foundation-contract-s2geometry-real-complete-installed-shared-provider-runtime-static.log`. **Superseded** by the eight runtime-loaded cells in the row above, which cover both deliveries × four optimisation modes. **Not observed:** retry after failure, a second provider after a success, concurrent callers, reentrancy, or the pre-load panic |
| standalone `consumer/` as a dependency-isolation gate | a real `.path = ".."` dependency that writes no include path and links no library, with `-Dlinkage` and `-Druntime` forwarded verbatim | **OBSERVED over this source, twice over and at two levels.** The `devenv:consumer` task exited 0 in 63.647 s, and the parent's nested-delivery proof then ran the standalone package itself in **eight** cases — both linkages × both dispatch modes × default and explicit target — with `-Dlinkage` and `-Druntime` carried to the nested build on every one, which is the forwarding this row is about. The pre-migration 10/10 (`…-live-consumer-423.log`) is the previous revision and stays history. `CHANGELOG.md` §74 |
| the canonical devenv tasks, as a gate | `zigTask` in `devenv.nix` takes `args` as a mandatory parameter, so every caller names its step; `sdk:build` names `args = ""`, which is "the default step, no step name", and the parameter keeps no default so a future omission cannot recur silently | **OBSERVED, bounded, 2026-10-04 — `"scope": "devenv"`, `"gates_not_run": ["nix:build"]` in both runs.** Before `…/20261004T215136Z/s2geometry-index.json` (`21:51:36Z`, `"status": "fail"`): seven gates `exit 1` and no catalogue at all — an evaluation error, so a declared task the observed catalogue lacked (`"sdk:integrity is not observed: tasks list --json"` beside its own `declared_in_devenv_nix` hit) is a symptom, not a missing task. After `…/20261004T215554Z/s2geometry-index.json` (`21:55:55Z`–`21:57:14Z`, `"status": "pass"`, `"gates_failed": []`, `"problems": []`): all eight gates `exit 0` — `devenv:info` 3.86 s, `devenv:tasks-list` 2.07 s, `devenv:canonical-integrity-mapping`, `devenv:shell-zig-version` 4.926 s, `devenv:shell-zig-env` 0.496 s, `devenv:consumer` 63.647 s, `devenv:integrity` 1.023 s, `repo:untouched` (`identical: true`, 4650 entries, no canonical-config change). The catalogue the failing run could not produce is now observed: 13 task names, 5 packages. **Not exercised:** `sdk:build`, `sdk:test`, `sdk:test-release-safe`, `sdk:smoke`, `sdk:check`, `sdk:fmt`, and `nix:build`, so the §70 `--prefix` and the install stay unobserved. `CHANGELOG.md` §73 |
| Windows cells | the graph adds no runtime search path on Windows by design (`Module.addRPathSpecial` has no target test), and `dbghelp` is the declared MinGW dependency | **NOT RUN** over this source. The four pre-migration `check` receipts cover `x86_64-windows-gnu` at the previous revision, and nothing has observed a shared delivery, a runtime load or an installed C consumer on Windows since |
| `zig build test` passes | — | **YES, over the current source, in all sixteen native cells.** 46/46 in each of `-Dlinkage` × `-Druntime` × Debug/ReleaseSafe/ReleaseFast/ReleaseSmall, each run as `zig build test smoke install -j8`. **Still unobserved:** the same suite on any cross target of the current revision, on a foreign runner, or against an installed artifact |
| `zig build check`, four targets | — | **Historical.** `x86_64-linux-gnu` 397, `aarch64-linux-gnu` 398, `x86_64-windows-gnu` 399, `riscv64-linux-gnu` 380 — exit 0, "Build Summary: 10/10 steps succeeded" each, against the pre-wave source. The current four must be re-run |
| `zig build check`, the two platform targets | — | **Both rows changed, and neither has been re-run.** `aarch64-macos-none`: `CoreFoundation` is now *declared* for Darwin targets (CCTZ's Apple timezone path uses it), so the declaration is real — but no Mac and no licensed Apple SDK exist on this host, no SDK was downloaded, and no cell was run after the change. It stays an external boundary with no fake macOS proof. `wasm32-wasi`: the old red cell (`signal.h:2:2`, 39 errors, receipts 318/321/355/358) described the **bundled** provider; with `-Dwasi-sysroot` the closure compiles and the 46 tests pass — see the `wasm32-wasi` rows below. The earlier claim that WASI cannot host this closure is `WITHDRAWN` (L25) |
| `test` exposes its run for every target | Unconditional run artifacts in both graphs; harness owns runner policy | Initial corrected full matrix executes the complete suite on 18 cells; old `no_test_results` receipt is history, not the current graph |
| Full 53-platform matrix | Profile contains no target list, artifact hook, runner override **or provider path**; caller arguments travel after `--` | **PENDING.** The last observed composite was 20 pass / 14 fail / 19 build-only (`local://foundation-cross-test-final-current-s2geometry.json`) and the sweep before it 18/22/13; both describe the **previous** revision of this tree. A `wasm32-wasi` cell is driven as `cross-test wasm32-wasi -- -Dwasi-sysroot=… --zig-lib-dir …`, which keeps the full published 53-target list and the profile's three variables exactly as they are |
| Native Debug/ReleaseSafe over this wave's source | — | **OBSERVED**, in all sixteen native cells: `zig build test smoke install -j8` at `-Dlinkage` × `-Druntime` × four optimisation modes, each `exit 0` at 46/46 with `smoke success`. The pre-wave receipts (417, 418) and the 10/10 consumer (423) are history; the standalone `consumer/` has since run over this source only through `devenv:consumer`, at task level, with none of its forwarding exercised |
| GNU-libc foreign execution | Standard bare Linux matrix uses musl; the three GNU Linux baseline triples compile only | No full GNU runtime suite is claimed; providing a real loader is a separate harness prerequisite |
| an oversized public index is `InvalidArgument`, not a panic | yes — `fn asIndex(i: usize) Error!c_int` (`zig/root.zig:145-148`), called by all five `usize`-index methods | **YES.** Before: compile 0 (346), run **134** (347). After: compile 0 (348), run **0**, `oversized public vertex index rejected as InvalidArgument` (349) — and the after-run links the current `root.zig` to an **already-installed** archive, so on its own it covers the facade only; the 46/46 native runs cover it against a graph rebuilt from this tree |
| Final filtered package | Complete `.paths`, record and profile included | **PENDING.** Driver-owned: `FORKS.json.cross_test_wave.materialized_packages.s2geometry`. These documentation bytes contribute to the identity, so the identity is recorded in the root ledger and never inside this package |
| Current source/fetched record replay | The record is now **927** current-byte entries: the previous 926 plus `build_support/zig-0.16-LICENSE.txt`, the upstream Zig licence copied verbatim beside the standard-library patch. Across the eight SDKs the total moves 1518 → 1519; this package is the only one that changed | **PENDING.** The last observed replay is 425's **926/926 `OK`**, which predates this source and these documents. Driver-owned current result: `local://foundation-cross-test-package-regression.json` |
| Materialised consumer | Real `.path = ".."` dependency inside the filtered copy | Current result under the same driver-owned closure; earlier 426 is historical |
| Installed C and C++ consumers | Separate installed-artifact proof, not source-consumer forwarding | Historical 429/430 and 431/432 passed 71 and 21 numbered checks before the Abseil portability changes; no fresh installed-C/C++ result is asserted |
| the count promise and the face guard, from outside the package | — | **YES**, exit 0 (427, 428). `invalid-cell status=1 count=0; null-polygon status=1 count=0`; and `out-of-contract face=6 status=1 id=0x00000000deadbeef valid=1` — rejection reported, the caller's sentinel left **unchanged**, and that sentinel is itself a valid id. Not null, not invalid. This is a **constructor-bound** result; the boolean case is covered by 410/411 and is a different call site |
| the four source repairs, from outside the package | — | **YES**, all exit 0 under a 256 MB limit: 407 `children status=0 count=1152921504606846976` (2⁶⁰, no allocation); 408 `short-buffer status=2 count=1152921504606846976` (required count reported, buffer untouched); 409 `nonunit constructor status=1 handle=(nil)`; 410/411 unit bow-tie `union`/`intersection` `status=1 out=(nil)`. 409 covers the constructor's bound on that input only; it is **not** proof that a boolean-typed build failure is impossible |
| `zig build consumer` | — | **YES.** exit 0, "10/10" (`…-live-consumer-423.log`) — the separate package resolves this one by path, builds the whole graph itself, runs, and prints its published golang/geo answers. The earlier `error: NeighborMismatch` (230) is history |
| two boundary holes a further review found | — | **CLOSED and gated.** `FromFacePos` is bounded to `face 0..5` in the raw bridge (`zig/bridge.cc:346`, `:355`) and in the facade, raw out-parameter unchanged on failure; `FromFace`'s deliberate faces-6-and-7 handling unchanged. `Coverer` calls failing early on a polygon or cell report **count zero** per `zig/bridge.h:107`, with a new permanent test asserting the raw valid → invalid → valid → null sequence. Before: exit **-6** SIGABRT at `s2cell_id.h:661] Check failed: is_valid()` (413), and `status=1 count=7` / `status=1 count=9` (415). After: in the 46/46 (417, 418) |
| `wasm32-wasi`, complete source closure, SDK 34 provider | `-Dwasi-sysroot` selects the SDK's WASIp1-threads sysroot; `single_threaded = false` on every module; ABI-2 EH libc++ linked by object file | **OBSERVED**: `libabsl.a`, `libs2.a` and `libs2bridge.a` all compile and link; the three installs succeed. Receipt `local://foundation-portability-s2-wasi-corrected-sdk-gates.log` |
| `wasm32-wasi`, 46 public tests | — | **OBSERVED, green**: `run test s2-tests 46 pass (46 total)`, exit 0, `Build Summary: 18/20 steps succeeded`. The count is the same 46 as native; nothing was dropped to make it fit |
| `wasm32-wasi`, standalone `consumer` package | Real `.path = ".."` dependency, provider forwarded, final link copied off `s2bridge` | **OBSERVED — INSTALL ONLY, NOT RUN.** `consumer package success` is the outer step succeeding; at that revision the nested step still chose `install` because the old `query.isNative()` predicate is false for `-Dtarget=wasm32-wasi` on this host. The consumer compiled and installed; no executed Zig consumer on this target exists. The corrected resolved-target predicate and the forwarded `-fwasmtime` are unobserved, so the runtime stays **PENDING** |
| `wasm32-wasi`, `smoke` | — | **OBSERVED, RED**: exit 134, `panic: integer does not fit in destination type` at `Io.Threaded.fileWritePositional` ← `Io.Writer.flush` ← `smoke.main`, same receipt. Recorded as a failure of the current tree. `smoke.zig`'s stdout is unchanged, no `Writer` streaming workaround was introduced, and no TLS/`errno` workaround was added. **No full `wasm32-wasi` green claim until the driver re-runs it** |
| Installed S2 C++ consumer on the WASI provider | Linked against the *installed* `libs2.a`/`libabsl.a`, not the sources | **OBSERVED**: compile no output, run printed `real S2 C++ consumer: decimal_sign_chunk_boundaries=5 invalid_inputs=2 two_threads=2 allocation_cycles=128 outstanding_delete=refused final_delete=reclaimed`. Receipt `local://foundation-portability-s2-wasi-installed-cpp-proof.json` |
| Full C++ provider on the SDK sysroot | SDK EH runtime, shared imported/exported memory, `-fno-single-threaded`, wasmtime 46.0.3 | **OBSERVED**: `real full C++ provider: counter=10000 file=42.5 bad_alloc=1 cleanup=1`. Its own `not_proven` line says the S2 source graph is not covered by it, and this table does not use it for that |
| UB trap under `-fsanitize-c=trap` | `wasi_provider.configureModule` selects `.trap`, not Zig 0.16's `ubsan` runtime | **OBSERVED**: `cpp_nonnull` → Wasm `unreachable`, **exit 134**. The trap is the point and is retained |
| Single-thread TLS/errno disagreement | measured before the threading model was set | **OBSERVED**: `sdk_errno=28 zig_errno=0 sdk_addr=0x1000000 zig_addr=0`, run exit 86. L26 |
| Stock Zig 0.16 threaded WASI compile | — | **OBSERVED, RED**: `Threaded.zig:959` `expected type 'i64', found 'u64'` and `heap.zig:16` `error: unimplemented`, exit 1. Both are what `build_support/wasi_stdlib.patch` fixes. L28 |
| NetBSD corrected provider, nine targets | cctz feature-test exclusion extended to NetBSD, plus the PowerPC steady-clock selection | **OBSERVED**: `ALL_9_COMPLETE_SDK_BUILDS_PASSED`; runtime unavailable on this host, so **0 executed pass claims**. `local://foundation-portability-netbsd-targeted.json` |
| `-fsys=s2` | Its boundary is **stated**, not hoisted: the bundled providers stay out with a reason each (`build.zig:648-666`, `:668-680`), and the mode does not inspect the installed archives' link closure, name a system library for them, or claim a platform where they are not installed (`:682-691`) | **NOT RUN**, and unchanged by that entry: no installed `libs2` or Abseil was observed on any machine in this workspace. A stated boundary is not a result. Decision 22, L35 |
| `zig build consumer -- <args>` | `b.args` is forwarded verbatim behind a `--`, after every option `addConsumerStep` passes on; the nested run hands them to the program (`consumer/build.zig`: `if (b.args) |args| run_exe.addArgs(args);`), which is the only handover | **YES.** In the four `loaded` cases of the nested-delivery proof the caller wrote `-- --provider <abs path>`, the nested argv carries `--` followed by that same pair verbatim, the receipt's `forwarded_arguments` is exactly those two tokens, and the program ran. **The provider reached the program as an argument and by no other route**: `S2GEOMETRY_TEST_PROVIDER` was excluded from the child environment and `provider_variables_absent_from_child` is true. Decision 20, L33, `CHANGELOG.md` §74 |
| `zig build consumer --prefix <dir>` | `addConsumerStep` forwards `--prefix` as two tokens after the `--global-cache-dir` block, with `b.install_prefix` made absolute against `b.graph.cache.cwd` when relative, and sends nothing when that value is this graph's own `<build root>/zig-out`, which is what a caller who named none leaves behind. With no `--prefix` on either side the nested build still resolves `consumer/zig-out`, because that is its working directory | **The named-prefix case is OBSERVED, the other two are not.** All nine cases of the nested-delivery proof named a prefix, and each records it `present: true`, `propagated: true`, `resolves_into_sdk_tree: false`; the check's own note says a nested build resolving its own `zig-out` inside the SDK tree would not count. **Still `PENDING-VERIFICATION`:** a *relative* `--prefix` (every prefix in that epoch is absolute), and the suppression branch, which needs one run naming no prefix at all. `CHANGELOG.md` §§72, 74 |
| the nested consumer delivery, as a whole | `addConsumerStep` hands the nested build the query-derived target and CPU, `-Doptimize`, the caller-named `-Dlinkage`/`-Druntime`, the system mode, `--zig-lib-dir`, `--libc-runtimes` where set, `-j8`, `--summary all`, both cache directories and the caller's `--prefix`, then the caller's own arguments behind a `--` | **OBSERVED, bounded, epoch `20261004T220323250122Z-515d06adcbbf`: 9/9 pass, and `s2geometry` is in no non-pass row.** Eight semantic cases `exit 0` ("the program ran and every expected pattern appeared in its own output"), one refusal case `exit 1` by design with `error: NoProviderConfigured`. The nested argv in every case carries `-fno-sys=s2` matching the declared flags exactly, `--zig-lib-dir`, `-j8`, `--summary all`, `--cache-dir <SDK cache root>/consumer`, the caller's `--global-cache-dir` unchanged, and `--prefix`. Default cases recorded `-Dtarget=native -Dcpu=native` without judging them; explicit cases named `x86_64-linux-gnu`/`baseline` and were judged and matched. Source closure unchanged across the epoch (2023 files, same stable hash before and after). **Not established, and not claimed:** no consumer-cache alias is configured for this SDK (`not_configured`) and **no cache-fallback guard is claimed to have passed**; every case is native, so decision 21's foreign second gate, `--libc-runtimes`, a cross target, and the `-fsys=s2` system-mode consumer all stay unobserved; `compile_side_signals` reports no compile error and `source_diagnostic_count` 0 throughout. `CHANGELOG.md` §74 |
| `zig build check` with a named target | `target_was_named` reads the caller's option map rather than the resolved query (`build.zig:133-138`, used at `:235-239`), so `-Dtarget=native` narrows `check` to one target instead of the six | **NOT RUN**, in either direction: the named-target branch and the six-target matrix are both unobserved over this source, and the four baseline `check` receipts describe the previous revision. Decision 19, L32 |
| the six-target `check` and the 53-platform matrix, current epoch | both run over this tree with the harness's own `--jobs 8 --build-jobs 8`; the baseline label is `baseline-s2geometry-check` in baseline run `20261005T014547Z-797a73f2`, and the matrix is run `20261004T221720228710Z-45046`, receipt `s2geometry-53-target-8.json`, source stamp `14c785720d6a…` identical before and after | **Both OBSERVED, and neither is green.** The `check` baseline exited 1 with `Build Summary: 44/60 steps succeeded (6 failed)`: the six failures are the `wasm32-wasi` steps of this graph's own `UnsupportedWasiProvider` refusal, because the gate invocation names no `-Dwasi-sysroot=`. That is a missing flag in the gate and not a source defect, and the five non-WASI cells compiled and linked. The matrix exited 1 with **20 pass, 28 build-only, 5 build failures, 0 run failures**, 20 cells executed at 46 tests each and every executed cell passing all 46. The five build failures are the four Apple cells (`aarch64-macos`, `x86_64-macos`, `aarch64-maccatalyst`, `x86_64-maccatalyst`, each `unable to find framework 'CoreFoundation'. searched paths:  none` — an absent Apple SDK) and `wasm32-wasi`. **`hexagon-linux` is a pass in this run**, 46 of 46, with the vendored Abseil compiled from this tree; no Hexagon cell is red. A build-only cell compiled and had no runner, so it is coverage and not a pass. This row supersedes the row above for these two gates only, and each run holds one source stamp, so every edit made after a stamp is outside it |
| the two eight-cell native waves | `native-final-evidence/20261004T233628757747Z-69351` and `loaded-final-evidence/20261004T232823091897Z-23133` | **OBSERVED, 8 of 8 each.** Native and linked: eight `exit 0`, `32/32` static and `39/39` dynamic steps, `46/46 tests` each. Own-loaded: eight `pass`, `33/33` static and `36/36` dynamic, `46/46 tests` each. They say nothing about any cell that did not execute, and nothing about `-fsys=s2`, the `-ls2cpp` `pkg-config` metadata inside a gate, the integrity replay or the filtered package round |
| foreign GNU-libc `consumer` under `-fqemu` | `hostCanExecute` mirrors `Step.Run`'s second gate — its `qemu_fixes_dl` field and its `.qemu` arm — and `addConsumerStep` forwards `--libc-runtimes`; the refusal it carries is `lib/std/Build/Step/Run.zig:1294-1311` | **NOT RUN.** Neither a run nor the install-only answer the second gate now produces has been observed on a foreign GNU-libc target. Decision 21, L34 |
| `package.nix` licence metadata, and both derivations | one top-level compound, `AND [ asl20 (WITH asl20 llvm-exception) bsd3 mit ]`, `licenseFile = "LICENSE"` (`package.nix:286-315`). nixpkgs answers a single attrset with `isFree` (`pkgs/stdenv/generic/check-meta.nix:118-122`) and a **list** with `any (l: !l.free or false)` (`:131-133`), and a `WITH` result carries no `free` attribute, so as a list element the LLVM exception reads as unfree | **The failure and then the fix are both observed.** The earlier field stopped in `check-meta` as unfree; after the correction `nix build .#static` and `nix build .#shared` each completed `exit 0`. Scope: the flake outputs only — no devenv shell, no `devenv.lock`, and the run predates the banner print and these documents. Store hashes belong to the root ledger. `CHANGELOG.md` §68 |
| the workflow requires the runtime licence records | the shared-delivery job requires all three and `cmp`s each against `<lib_dir>/<runtime>/LICENSE.TXT` from `zig env`, non-zero if `lib_dir` is unreadable (`verify.yml:1024-1057`); its installed-consumers step asserts the static prefix has no `libs2cpp.*` and none of the three texts (`verify.yml:326-349`) | **NOT RUN.** That is what the workflow now requires, read out of the file; no job has been executed here, so it is not an observed pass |
| anything else | — | **NOT RUN** |

### Gates that passed, at the revision they observed

`zig build smoke`, Debug, on an isolated cache, exit 0, "10/10 steps
succeeded" / "smoke success"
(`local://foundation-expansion-s2geometry-wedge-smoke-169.log`). The seven
sections printed the six face roots; four published golang/geo token/id pairs;
the projection origin; the neighbour identities compared as multisets,
including upstream's three face-2 and three face-5 repeats for `3/` and the
eight published neighbours of the Zurich cell `2/033020001100`; the octant
triangle at area `1.570796326794897` (π/2) and perimeter `4.712388980384690`
(3π/2) with eight octants and six face cells both summing to 4π; the two-wedge
boolean with `|A and B| = 0.785398163397448` (π/4) and `|A or B| =
2.356194490192345` (3π/4) plus the inclusion–exclusion identity and four
containment decisions; and the level-22 covering of the Sydney coordinate
`6b12ae37cebb`, found among the 42 cells the upstream fixture publishes.

`zig build install --prefix …`, Debug, exit 0, "Build Summary: 12/12 steps
succeeded", `install absl` / `install s2` / `install s2bridge`
(`…-installed-artifact-gruenau8-224.log`). The combined
`zig build test smoke install` run reproduces both in one invocation
(`…-resume-debug-smoke-install-249.log`, `install success` for all three and
`smoke success`, exit 1 only because of the test root).

`sha256sum -c UPSTREAM.sha256`, exit 0, all **926** records `OK` at that
revision (`…-immutable-native-dependency-fixture-integrity-231.log`), and
`git diff --exit-code c24b368c… -- src LICENSE NOTICE CMakeLists.txt`, exit 0,
empty output (`…-pinned-native-pristine-diff-268.log`). Both ran on 2026-10-01.
Neither describes this tree: the record is now 927 entries, and the S2-scoped
`git diff` is no longer a pristine test because `src/` carries one disclosed
change. The current provenance statement is the canonical whole-closure
comparison (1 S2 + 7 Abseil, no extra and no missing path), and the current
record replay is **PENDING**.

An installed C++/Abseil consumer, `zig c++ -std=c++17` against the installed
`include/` linking the installed `libs2.a` and `libabsl.a`, exit 0
(`…-installed-native-Cpp-Absl-surface-238.log`): face-0 id `0x1000000000000000`,
token `1`, centre at lat 0 / lng 0 deg, the Nuremberg leaf
`0x47a1cbd595522b39` at level 30, and the octant loop at
`1.5707963267949 sr`.

### Current verdict

**Sixteen native cells are current observations. Every cross-target, consumer,
package and relocation gate is still PENDING.** The landed changes and the
observed evidence behind each are in the table above and in decisions 15–27;
the gates that still have to run are:
* `zig build check` for all six targets, with the `wasm32-wasi` cell given
  `-Dwasi-sysroot` and `--zig-lib-dir`,
* the full published 53-platform `cross-test` matrix,
* the filtered fetch, the whole-record source/fetched integrity replay and the
  materialised consumer inside it.
* `zig build consumer` in both linkages **and** both dispatch modes, and once
  with arguments after a `--`: **discharged** by the nested-delivery proof,
  which runs the step eight ways and forwards `--provider` to the program in the
  four loaded ones — but still owed in the **system mode** (`-fsys=s2`), where
  the forwarded option would instead put the consumer on an installed library,
  and in the `--prefix` suppression branch;
* `zig build check` with a named target, `-Dtarget=native` included: the
  narrowing in decision 19 is unobserved in **both** directions,
* a foreign GNU-libc `consumer` cell under `-fqemu`, with and without
  `--libc-runtimes`: neither the run nor the install-only answer decision 21
  produces has been seen,
* the standalone `consumer/` package over this source — the dependency-isolation
  gate — and every Windows cell, neither of which has run since this revision,
* a **relocated** shared install actually loading its closure. The `$ORIGIN`-first
  order is `SOURCE-CONFIRMED` from the build graph and from upstream's own
  published `INSTALL_RPATH`; the receipt that exercises it would move the prefix
  after the build, and no such run has happened here,
* the runtime loader's failure and concurrency paths: retry after a failed
  attempt, a different provider after a success, concurrent callers, reentrancy,
  and the pre-load panic in each optimisation mode,

The four corrections in decisions 19–22 changed `build.zig` and its
documentation, and **none of them has been observed by a gate**. Decision 26
did change the compiled closure — it added the one upstream translation unit the
list had omitted, unchanged — and decision 27 changed it again, by adding one
runtime object and one second native graph on the ELF shared route alone. The
facade surface and the suite did not move for either. Nothing in this file
upgrades a row because a source correction landed; what upgraded these rows is
the sixteen runs.

Those are the driver's, not this file's, and none of them is inferred from the
pre-wave native 46/46, the four-pass baseline, the 20/14/19 matrix composite or
the 926-record replay, all of which describe the **previous** revision.

What *is* observed for the current wave, and is narrower than a green cell: the
whole native matrix — both linkages, both routes, four optimisation modes — each
cell `exit 0` at 46/46 tests with `smoke success` and a real install; on the ELF
shared route that install is **four** objects, the three upstream sonames plus
`libs2cpp.so.0` and its three licence texts, and its step tree shows the pure
install graph compiling separately from the one the tests linked. The
runtime-loaded cells name their provider explicitly and load it across an image
boundary whose `libs2cpp.so.0` neighbour resolves beside it. The `wasm32-wasi`
closure compiles and links under the SDK 34 provider, the 46 public tests pass
there, all three archives install, the standalone consumer compiles and installs
but was **not run**, a separate installed S2 C++ consumer program executed its
decimal/sign/chunk boundaries and its two-thread arena work, UB still traps under
`-fsanitize-c=trap`, and `zig build smoke` for that target **failed**, exit 134,
in Zig's `Io.Threaded` writer. macOS has no provider here and has not been run
since `CoreFoundation` was declared, no Windows cell has run over this revision
at all, and no prefix was ever moved after it was installed.

#### Historical verdict before this repair wave

**`VERIFIED` for the native target in both optimisation modes and for four of
the six cross targets.** Observed 2026-10-02, all `exit 0`:

* `zig build test smoke install`, Debug — "Build Summary: 17/17 steps succeeded;
  45/45 tests passed", `run test s2-tests 45 pass (45 total)`, `smoke success`,
  and all three archives installed (`…-final-native-debug-393.log`).
* `zig build test smoke -Doptimize=ReleaseSafe` — **45/45 tests** and `smoke
  success` (`…-final-native-releasesafe-394.log`). Read the command: it was
  `test smoke`, so this run **did not install**; 393 is the only installation
  evidence.
* `zig build check -Dtarget=` `x86_64-linux-gnu` (397), `aarch64-linux-gnu`
  (398), `x86_64-windows-gnu` (399), `riscv64-linux-gnu` (380) — "Build Summary:
  10/10 steps succeeded" each.
* installed C bridge consumer — compile exit 0 (402), run exit 0 with **71
  numbered checks** (403).
* installed C++/Absl consumer — compile exit 0 (404), run exit 0 with **21
  numbered checks** (405).
* bounded-boundary probes from outside the package, all exit 0 under a 256 MB
  address-space limit: compile 406, then `children status=0
  count=1152921504606846976` (407), `short-buffer status=2
  count=1152921504606846976` (408), `nonunit constructor status=1
  handle=(nil)` (409), `unit bow-tie union status=1 out=(nil)` (410), `unit
  bow-tie intersection status=1 out=(nil)` (411). 409 proves the *constructor's*
  bound on that input; it is **not** proof that a boolean-typed build failure is
  impossible, which is a different input at a different call site.
* `zig fmt --check` on this fork's own eight source files (395) — exit 0, empty.
* `zig fetch` (396) — exit 0, `s2geometry-0.14.0-2Klt8f9eBwEyMQKeHLiAUZ2h680ivy01LNFmKgfhHvsU`.
* **after the boundary guards** — `zig build test smoke install`, Debug: "Build
  Summary: 17/17 steps succeeded; 46/46 tests passed", `run test s2-tests 46
  pass (46 total)`, smoke and all three installs (417); `zig build test smoke`,
  ReleaseSafe: 13/13 steps, **46/46**, smoke and **no install**, since
  `install` was not in the command (418); `check -Dtarget=` for
  `x86_64-linux-gnu` (419), `aarch64-linux-gnu` (420), `x86_64-windows-gnu`
  (421) and `riscv64-linux-gnu` (422), 10/10 steps each; `zig fmt` on this
  fork's own sources, exit 0 and empty (416); and `zig fetch`, exit 0,
  `s2geometry-0.14.0-2Klt8WOCBwFfUQlt-MA55F-8f7bo7bF9cgGyhEukOfSl` (424) —
  which supersedes 396's hash.

**46 tests now.** The count has moved twice: 39 originally, 45 after the six
permanent behavioural regressions for the four source defects below, and **46**
since the count-protocol state-transition test was added. `46/46` was the result
at that revision (417, 418); `45/45` (393, 394) is the earlier statement about
the tree before the boundary guards. **The count is unchanged by this repair
wave** — no test was added, removed or relaxed to accommodate a new platform —
and the same 46 pass on the `wasm32-wasi` SDK provider today. The native 46/46
over the current source is still **PENDING**. The added tests are what make a
green run evidence about the repairs rather than only about the library. The
runs also print seven upstream `E`-level log lines — `s2latlng_rect.h:397 Invalid
rect`, `s2loop.cc:212 Edge 0 is degenerate (duplicate vertex)`, and
`s2polygon.cc:249 Shape 0 has one or more edges with interior on the right` six
times. Those are the *negative* tests exercising exactly the rejected inputs.
In the runs quoted here the log is not a fault, and it is recorded so the next
reader does not think it is.

**Not green at that revision, and one of those two is no longer the same
statement:**

* `check -Dtarget=aarch64-macos-none` — `'CoreFoundation/CFTimeZone.h' file not
  found`, one error in `libabsl.a` (`…-closure-cross-aarch64-macos-none-355.log`).
  That remains an external boundary and is still the reason the cell is red: no
  Mac and no licensed Apple SDK exist on this host, and no include path can
  supply Apple's framework. What changed is that the framework is now
  **declared** (`module.linkFramework("CoreFoundation")` on every Darwin C++
  module, which CCTZ's Apple default-timezone implementation actually uses), so
  the missing piece is the SDK and nothing else. No Apple header, type or
  prototype was fabricated, no SDK was downloaded, and no macOS cell was run
  after the declaration.
* `check -Dtarget=wasm32-wasi` — `signal.h:2:2: error: "wasm lacks signal
  support…"`, 39 errors, with the missing `std::mutex` and `<fstream>` behind it
  (`…-closure-cross-wasm32-wasi-358.log`). This was true **of the bundled Zig
  libc++ provider**, and as a statement about the platform it is `WITHDRAWN`
  (L25): with `-Dwasi-sysroot` naming an installed SDK 34 WASIp1-threads sysroot
  the closure compiles, links and runs its 46 tests. It is also the reason the
  smoke cell is still red on that target — see the table above.
* Both were inside vendored Abseil; the macOS one still is, and the WASI one now
  has a real provider behind it rather than an edit to Abseil.

**Nothing was pending when that paragraph was written, and a great deal is now.**
At that revision the last open runs had landed: `zig build consumer` "10/10"
(423), the materialised package's integrity **926/926 `OK`** (425) and its
consumer "10/10" (426), the installed after-contract probes (427, 428), and the
latest installed C and C++ consumers with **71** and **21** numbered checks
(429–432). Each was its own run. This repair wave then opened a new list — the
four whole-tree gates named under "Current verdict" — and none of them has run
yet. The 926-record integrity result is also superseded by a 927-record file.

**The two boundary holes are closed.** `FromFacePos` is bounded to `face 0..5`
in the raw bridge (`zig/bridge.cc:346`, `:355`) **and** in the facade, the raw
out-parameter is left unchanged on failure, and `FromFace`'s deliberate handling
of faces 6 and 7 is unchanged. `Coverer` calls that fail early on a polygon or
cell report **count zero**, matching `zig/bridge.h:107`, and a new permanent
test asserts the whole raw sequence rather than the final value. Before the
guards, `FromFacePos` on a face-6 id **aborted** — exit **-6** at
`src/s2/s2cell_id.h:661] Check failed: is_valid()`, reached through
`S2CellId::parent`, which is worse than the review predicted — and the count
promise failed as `invalid-cell status=1 count=7; null-polygon status=1
count=9`. After: 46/46 in 417 and 418. No algorithm, ABI or upstream-native
change was involved, and `git diff` (268) and the Abseil whole-tree comparison
(286) are unaffected.

**Two fixes in the CI workflow's own consumers, and they are not CI job proof.**
`.github/workflows/verify.yml`'s C driver built `FromFacePos`'s Hilbert position
as an ordinal where the bridge takes the raw 61-bit position — line 297 now
passes `(uint64_t)i << 59` — and the C++ consumer's compile line lacked
`-fsized-deallocation`, now present at line 551. Both are corrections to a
workflow file, found by running its consumers; **no CI job has been run here.**

**The interval in between, and two withdrawn explanations.** For several
iterations `compile lib s2bridge` failed with 119 diagnostics —
`-Wnullability-completeness` from upstream headers reached through
`zig/bridge.cc`, first diagnostic `src/s2/s2builder.h:473:20` — on native Debug
and ReleaseSafe and four cross targets (313, 314, 316, 317, 319, 320). What those
runs actually recorded is **117 header diagnostics alongside 2 errors in this
repository's own C++**. The repair changed the header ownership / system-include
roots **and** the `BooleanOp::` syntax together, and the next run was green.

**This file asserted a cause twice, and both assertions are `WITHDRAWN`.** The
first was the system-include classification; the second was the two C++ typos
and the plausible mechanism that a failed parse takes the whole include graph
with it. **No experiment varied one correction while holding the other fixed**,
so neither is established — and "the classification is disproven" is exactly as
unfounded as "the typos caused all 119". The only established fact is that the
coupled change worked. The lesson is **L22**.

A second regression is fixed in a different place than it was first reported
here. Six assertions in `tests.zig` compared a raw status against
`s2.c.S2BRIDGE_INVALID_ARGUMENT`, which `translate-c` emits as a signed `c_int`
constant while the call returns a `c_uint`-typed value; that comparison did not
compile (`…-corrected-native-releasesafe-durable-376.log`,
`…-tests-diagnostic-pipe-capture-392.log`). The fix is in the **test file**:
`tests.zig:1401` declares
`const invalid_argument: s2.c.S2BridgeStatus = s2.c.S2BRIDGE_INVALID_ARGUMENT;`
and those six assertions compare against it. `check`'s own parameter at
`zig/root.zig:119` was **not** changed and is not the fix. **No ABI change**:
the C signature and every `S2BridgeStatus` value are as they were, which the
green runs confirm.

**The packaging gap is fixed and its re-run is pending.** `.paths` now names
`.clang-format`, `pyproject.toml` and `setup.py`, which it did not when 334
reported 923 `OK` and 3 missing. The new package hash differs from the one 325
fetched, which is what a changed manifest looks like.

**The four source defects, before and after.** Kept because each is a
before-and-after, not a claim:

* `s2br_cell_children`'s counting pass answered `S2BRIDGE_OUT_OF_MEMORY` with
  `count = 0` for a level-30 range, having built the whole 2⁶⁰-element list to
  learn its length (278). L19. Now counted in the 46/46.
* `s2br_polygon_create` had no ordinary unit-length bound, so finite non-unit
  vertices **aborted inside the constructor** at `s2predicates.h:394` and never
  returned a status (279, 280). L20. Now rejected as `InvalidArgument`.
* On a polygon whose vertices *are* unit length but whose edges cross, the
  constructor succeeded and `s2br_polygon_is_valid` correctly said invalid —
  and the abort came later, inside `s2br_polygon_union` /
  `s2br_polygon_intersection`, validating their **output** loop at
  `s2loop.cc:357` (282, 283). L20. Now `RequireValidOperand` plus the
  `S2Error`-reporting overloads.
* `Loop.vertex(maxInt(usize))` panicked at `zig/root.zig:956` instead of
  returning `error.InvalidArgument` (346, 347). L21. Now `asIndex`, proven by
  the after-probe (348, 349) and by the 46/46.

Both bridge probe binaries had compiled and linked cleanly against the install
set before any of these (277, 281, exit 0, each linking `-ls2bridge -ls2 -labsl`
with `-fsized-deallocation` on the consumer's own compile line), so none of the
four was ever a build problem.

### Cold-build cost, for planning

With a warm global cache and an empty per-target cache, Debug on
`x86_64-linux-gnu`: Abseil 3 min (MaxRSS 259 MB), S2 5 min (MaxRSS 464 MB),
bridge 18 s (MaxRSS 274 MB), `translate-c` 3 min
(`local://foundation-expansion-s2geometry-isolated-cache-smoke-157.log`).
Warm rebuilds of the three libraries are sub-second. Plan a cold build at
ten minutes, not two.

An ELF **shared** build costs more and its own receipts say by how much:
`compile lib s2cpp ReleaseFast native` 36 s at MaxRSS 417 MB, plus a second
compilation of the three libraries for the install tree (Abseil 28 s, S2 1 m,
bridge 13 s in the observed Debug cell) — 39 steps against 32 for the static
delivery, which compiles one graph and installs it. `libs2cpp` is configured
identically in both graphs, so the runner compiles it once.

---

## Recorded boundaries and owner decisions

Current native/provenance integration is recorded above; final matrix and
package statuses are driver-owned, not borrowed from historical green copies.

1. **macOS is an observed dependency boundary; `wasm32-wasi` now has a real
   provider.**
   *macOS*: the framework CCTZ's Apple default-timezone path uses is now
   **declared** (`module.linkFramework("CoreFoundation")` on every bundled C++
   module for a Darwin target). What is still missing is the SDK itself:
   `LICENSED_MAC_PROVIDER_UNAVAILABLE`, no Mac and no Apple SDK on this Linux
   host, no SDK downloaded or used, and no macOS cell run since the
   declaration. No CoreFoundation header, type or prototype was fabricated and
   no macOS result is claimed. Upstream's own recorded Apple M1 numerical
   accuracy issue is unrelated and unobserved here.
   *WASI*: the earlier statement — historical receipt 355's missing framework
   and receipt 358's `signal.h` refusal, with threading and file-stream limits
   behind it — described the **bundled** provider and is `WITHDRAWN` as a
   platform claim (L25). `-Dwasi-sysroot` now names a complete installed WASI
   SDK 34 WASIp1-threads sysroot, the threading model is one ABI-wide ABI
   requirement (L26), and the two stock-standard-library blockers are fixed in a
   copy selected with `--zig-lib-dir` (L28). What remains open on that target is
   the **red smoke cell** (exit 134 in `Io.Threaded.fileWritePositional`) and
   the fact that no gate over the whole target has been re-run. The provider's
   `getpid` and signal handling are the SDK's documented *emulation*; they are
   not a host PID, a process namespace or POSIX signals, and WebAssembly
   async-signal-safety remains unsupported.
2. **`-fsys=s2` is unexercised, and that is the whole of it.** No installed
   `libs2` or Abseil was observed on any machine in this workspace, so the mode
   has no result — a statement about what is installed, not about the package.
   This is an optional system-integration path, not unfinished native work.
   Owner: whoever has a machine with the libraries installed.
   Its **boundary** is stated rather than inferred (decision 22): the bundled
   providers — `dbghelp`, the `CoreFoundation` framework and the
   `ABSL_USE_UNSCALED_CYCLECLOCK` selection — are not hoisted into the mode,
   each for a recorded reason (`build.zig:648-666`, `:668-680`), and the mode
   does not inspect the installed archives' link closure, name a system library
   on their behalf, or claim a platform where they are not installed
   (`:682-691`). It is written for a host that already has an installed `libs2`
   and the Abseil archives its `s2geometry.pc` names beside it for the target
   being built; the mode names no `-l` stem of its own. That is a scope statement
   and not a result: nothing about it has been exercised, and stating it changed
   no step.
3. **The fork-authored files' licence is now decided: Apache-2.0
   (2026-10-04).** The owner authorized a licence for the fork's own additions,
   matching the primary upstream terms where appropriate; for this project that
   term is Apache-2.0, because both upstreams are. `FORK-LICENSE.md` records the
   authorization, the grant and its scope. **What this list said before the
   decision is history and stays in the tree:** the retained-source notice audit
   found the three S2 `util/gtl` headers carrying Apache-2.0 plus BSD-3-Clause
   text, the compiled CCTZ public-domain `tzfile.h`, and retained public-domain
   timezone data and test provenance; `NOTICE.md` itemises those exceptions and
   preserves their notices, and it still does not assert a single licence for
   the whole tree. `cross-test.profile.sh`, `build_support/wasi_provider.zig`,
   `build_support/wasi_stdlib.patch`, the packaging files and every record in
   this file are fork-authored, and they are now Apache-2.0 — a separate grant by
   a different holder, which borrows nothing from upstream and credits no
   upstream author with them.
4. **Each external provider keeps its own terms, and this package asserts none
   of them.** The WASI SDK sysroot is the SDK provider's own distribution under
   its own licence; it is not vendored, redistributed or relicensed here, and no
   compatibility with it is claimed. Wasmtime is invoked, not shipped. The
   standard-library patch edits upstream Zig source and therefore carries that
   source's unchanged context: the pinned compiler's terms — MIT (Expat),
   "Copyright (c) Zig contributors" — are copied verbatim into
   `build_support/zig-0.16-LICENSE.txt` and recorded in `UPSTREAM.sha256`. The
   patch file itself is fork-authored and, since 2026-10-04, Apache-2.0 like the
   rest of this fork's additions; the MIT terms above remain the terms of the
   files it edits, unchanged and travelling. The stock compiler beside it is
   unchanged. CoreFoundation and every other Apple API remain Apple's, under
   Apple's terms.
5. **The full matrix is driver-owned and currently PENDING.** The earlier
   corrected 53-cell sweeps report 18 pass / 22 fail / 13 build-only and
   20 pass / 14 fail / 19 build-only; both describe the **previous** revision of
   this tree. Current source adds the four architecture corrections, the NetBSD
   cctz feature-test exclusion, the OpenBSD/NetBSD PowerPC real-clock selection,
   real DbgHelp linkage, the CoreFoundation framework declaration, the S2
   `from_chars` repair and the WASI LowLevelAlloc backend. Per-cell outcomes are
   `FORKS.json.cross_test_wave.libraries.s2geometry` and
   `local://foundation-cross-test-final-current-s2geometry.json`, and they are
   stale until the driver re-runs the sweep. A `wasm32-wasi` cell is driven with
   the provider supplied after `--`, which keeps the full published 53-target
   list and the profile's three variables untouched; the profile bakes in no
   provider path. Missing runtimes are never executed passes; native,
   compile-only or package evidence does not substitute for the complete public
   Zig API matrix.

6. **The C++ runtime artifact is ELF-shared-route only, and its licences travel
   with it.** `libs2cpp.so.0` is the pinned compiler's own libc++, libc++abi and
   libunwind, compiled by `build_support/cpp_runtime.zig` and installed on ELF
   targets with `-Dlinkage=dynamic` — nowhere else: `static`, `wasm32-wasi`,
   Darwin and Windows keep their ordinary provider rules and install no runtime
   object. Its terms are the LLVM project's Apache-2.0-with-LLVM-exception, and
   each component's own `LICENSE.TXT` is installed verbatim as
   `LICENSE.libcxx.txt`, `LICENSE.libcxxabi.txt` and
   `LICENSE.libunwind.txt`. Two items still attach to it. **Closed:** the CI gap
   is closed — the shared-delivery job of `.github/workflows/verify.yml` now
   requires all three texts and `cmp`s each against `<lib_dir>/<runtime>/LICENSE.TXT`
   from `zig env` (`verify.yml:1024-1057`), and its installed-consumers step
   asserts the static prefix carries neither the object nor the three texts
   (`verify.yml:326-349`); no CI job has been run, so that is what the workflow
   requires, not an observed pass. **Open:** the installed `pkg-config` file's
   `-ls2cpp` metadata is `SOURCE-CONFIRMED` only, because it landed during the
   observed sweep. The compiler's own installation is never modified and no
   compiler source is copied or edited. Decision 27, L39, `CHANGELOG.md` §§67
   and 68.

**A metadata correction, and it is now gated.** `package.nix`'s `license` is one
top-level compound, `AND [ asl20 (WITH asl20 llvm-exception) bsd3 mit ]`,
replacing a plain four-element list. The failure that motivated it was observed:
with the list, nixpkgs' unfree check answered the elements instead of the
expression, a `WITH` result carries no `free` attribute, and the derivation
stopped in `check-meta` as unfree. Under the compound the `WITH` resolves as
`license && exception`, which is free. The grant is unchanged — `WITH asl20
llvm-exception` is the same Apache-2.0-with-LLVM-exception §67 attributes to the
compiler-shipped runtime — and no source file, licence text or attribution record
moved. **Then both derivations were built**: `nix build .#static` and `nix build
.#shared` each completed `exit 0`, which resolves the unfree failure. The scope of
that observation is the flake outputs: the canonical devenv shell has not been
entered and `devenv.lock` does not exist, the run was taken before the
configure-time banner print and these documentation changes, and the store hashes
that identify it belong to the root ledger, never to these documents.
`CHANGELOG.md` §68.

**No CI job has been run.** The two defects fixed in
`.github/workflows/verify.yml` — the C driver's Hilbert input built as an
ordinal instead of the raw 61-bit position, and the C++ consumer's compile
line missing `-fsized-deallocation` — are corrections to the workflow file.
The corrected C excerpt compiled and ran with exit 0 at 433/434, and the C++
excerpt at 435/436, against the installed prefix. These are local program runs,
**not** a CI job execution; no runner or job pass is claimed.

Closed since the last revision of this list:

* **The bridge compiles again.** The 119-error interval is over, and its cause
  is **not** established: the failing runs recorded 117 header diagnostics
  alongside 2 errors in this repository's own C++, the repair changed the header
  ownership / system-include roots **and** the `BooleanOp::` syntax together,
  and no experiment varied one while holding the other fixed. L22 records the
  narrow lesson and both withdrawals. `compile lib absl`, `compile lib s2`,
  `compile lib s2bridge`, `translate-c` and the smoke program all compile on the
  native target and on four cross targets.
* **The two boundary holes are closed and gated.** `FromFacePos` bounded to
  `face 0..5` in the raw bridge and the facade with the caller's out-parameter
  untouched, `FromFace`'s faces 6/7 handling unchanged; `Coverer`'s early
  failures report count zero per `zig/bridge.h:107`, with a permanent test for
  the raw valid → invalid → valid → null sequence. Before: SIGABRT -6 at
  `s2cell_id.h:661` (413) and retained counts 7/9 (415).
* **`zig build consumer` and the materialised package's runs were done** at that
  revision — "10/10" (423), 926/926 `OK` (425), "10/10" (426), after-contract
  probes (427, 428), and the latest installed consumers at 71 and 21 numbered
  checks (429–432). All of that predates this wave; the 927-record replay and
  the materialised consumer must be re-run before either is called current. The
  consumer *on the `wasm32-wasi` provider* did run this wave, and passed.
* **The driver's bridge probes are superseded** by 407–411 and 427–428, which
  answer the same questions from outside the package against the current
  archives; the probes themselves remain the before-half of each
  before-and-after.
* **The enum-signedness regression is fixed** in `tests.zig:1401`, not in the
  facade's `check`, whose signature never changed. No ABI change.
* **All four source defects are repaired and gated** — the `children` count
  (L19), the constructor's unit-length bound (L20), the boolean operations'
  operand validity and `S2Error` overloads (L20), and the `usize` index
  narrowing (L21). They were gated by the 46/46 native runs at that revision, and
  the same 46 regressions pass on the `wasm32-wasi` SDK provider this wave. The
  native 46/46 over the current source is PENDING.
* **`tests.zig` compiles and runs** — the `tests.zig:1306` `f64` typing is in and
  the 46/46 counts it.
* **`build.zig.zon`'s `.paths` names `.clang-format`, `pyproject.toml` and
  `setup.py`**, so the record and the manifest agree; the re-run that proves it
  is item 1.
* `UPSTREAM.sha256` is in `build.zig.zon`'s `.paths`, and the CI `provenance`
  job names it in its required-records loop and runs `sha256sum -c
  UPSTREAM.sha256`.
* **Historical integrity/source receipts:** 231 passed 926 records before
  this wave; 268 passed over S2 `src LICENSE NOTICE CMakeLists.txt` as they
  stood then. Neither is a current record replay, and 268 is no longer a
  pristine test because `src/` now carries one disclosed change.
* **Abseil upstream pin and current delta:** the canonical archive digest is
  `8b39fdb7c4a5d7ef0ee88b0b4eb3d23c77623d6f793579a5e0d0af7cf2ce6eaa`. Pristine
  whole-vendor comparison 286 is pre-patch history, and the four-path guard
  receipt at `local://foundation-cross-test-s2-approved-vendor-diff.json`
  observes exactly the four architecture paths it was written for. The **current**
  whole-closure comparison is `local://foundation-portability-canonical-source-provenance.json`:
  `OBSERVED_CANONICAL_SOURCE_COMPARISON_PASSED`, `s2_difference_count = 1`,
  `abseil_difference_count = 7`, `extra_missing_paths = false`, every license
  prefix unchanged and a change notice on all eight deviations. Current
  source/fetched replay status belongs to the driver-owned package closure and is
  **PENDING** against the 927-record file. The earlier empty-string digest
  attempt 272 remains withdrawn.

