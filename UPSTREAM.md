# UPSTREAM.md — what this fork is a fork of

This package is the **real upstream C++** of google/s2geometry, compiled by a
Zig 0.16 build, published through a thin C bridge and a small typed Zig facade.
Nothing in this tree reimplements S2. There is no Hilbert curve here, no
spherical-excess formula, no cell-id bit layout and no token codec; every answer
this package returns was computed by the compiled upstream sources in `src/s2`
and the compiled upstream Abseil in `vendor/abseil-cpp`, reached through
`zig/bridge.h`.

Eight upstream files are modified: one in `src/s2` and seven in the vendored
Abseil. Each is a bounded portability correction, each is itemised below with
pristine and current digests, each keeps its upstream licence header byte for
byte, and each carries a prominent change notice. Everything else is exactly
what upstream shipped.

Two upstream trees are carried, and the second is a dependency of the first. A
third work's **code is compiled but not carried** on one route — the build
compiler's own C++ runtime — and that is described where it belongs, below and
in `NOTICE.md`, rather than left to be found in a build comment.

## Upstream

### s2geometry

| Field | Value |
|---|---|
| Project | S2 Geometry Library |
| Canonical URL | `https://github.com/google/s2geometry` |
| Tag | `v0.14.0` |
| Commit | `c24b368c67d0b8a2a109c5a75224e73a856bd8b7` |
| Licence | Apache License 2.0 (`LICENSE`); three compiled `src/s2/util/gtl` headers also retain BSD-3-Clause text, itemised in `NOTICE.md`; upstream `NOTICE` names Google Inc. |
| Subdirectory carried | the whole repository root, not a subtree |

The tag is the version. `CMakeLists.txt:7-8` still says
`project(s2-geometry VERSION 0.12.0)`; that line is stale inside the v0.14.0
tag itself and this fork leaves it exactly as upstream shipped it.
`build.zig.zon` records `.version = "0.14.0"` for the same reason.

### Abseil C++ LTS 20250814.1

| Field | Value |
|---|---|
| Project | Abseil C++ |
| Canonical URL | `https://github.com/abseil/abseil-cpp` |
| Release | `20250814.1` (LTS) |
| Commit | `d38452e1ee03523a208362186fd42248ff2609f6` |
| Licence | Apache License 2.0 (`vendor/abseil-cpp/LICENSE`), with the CCTZ public-domain header and retained timezone/test notices itemised in `NOTICE.md`; this release ships no `NOTICE`, and `AUTHORS` names Google Inc. |
| Subdirectory carried | the whole repository root, at `vendor/abseil-cpp` |

The tree is vendored **whole**. It is not cut to headers, not cut to the
153 translation units this build happens to need, and not cut to any subset of
release: `absl/**` carries the `.h` headers *and* the `.inc` implementation
fragments those headers `#include` by name, and the CMake/Bazel build
definitions that enumerate the source set are carried too, so that upstream's
own CMake and Bazel builds still work from this tree.

### Why `20250814.1` and not the other two versions the tag names

The v0.14.0 tree names three different Abseil releases, and this fork uses the
one its own CMake fetches, because that is the build definition being
replaced:

| Where | Says | Used here |
|---|---|---|
| `CMakeLists.txt:71-75` (`FetchContent_Declare(absl URL …/20250814.1.zip)`) | `20250814.1` | **yes** |
| `README.upstream.md:59-61` (upstream's README, at `README.md` inside the pin) | `20250814` (link text points at the `20250814.1` tag) | no — same release, shorter label |
| `src/MODULE.bazel:11` (`bazel_dep(name = "abseil-cpp", version = "20260107.1")`) | `20260107.1` | no — a later release, for the Bazel build only |

`CMakeLists.txt:24-27` explains why the exact Abseil matters and not just the
major version: `ABSL_HAVE_STD_STRING_VIEW` and friends end up defined
differently between configurations, which is an ODR error, not a warning. The
CMake pin is also the one that reaches Abseil itself: `CMakeLists.txt:62`
issues `-DABSL_MIN_LOG_LEVEL=1` as a *directory-scope* `add_definitions`
**before** `FetchContent_MakeAvailable(absl)`, so under the `-DFETCH_ABSEIL=ON`
path upstream compiles Abseil with it. This fork keeps that relationship.

The tree is also self-identifying: `vendor/abseil-cpp/absl/base/options.h:152`
defines `ABSL_OPTION_INLINE_NAMESPACE_NAME lts_20250814`, and that macro ends up
in every Abseil symbol name. A different vendored release cannot pass the CI
check that reads it, and could not link against the `libs2` this build produces
even if it did.

## Archive receipt

`git archive` of the pinned s2geometry commit, as recorded by the driver in
`local://foundation-expansion-source-archives.json`:

```
6e49b320921abbf0294d783c30aad94fc73f4b04f5b8de6d3d9409024e393b20  s2geometry c24b368c67d0b8a2a109c5a75224e73a856bd8b7
```

That is a digest of the commit's tree as `git archive` serialises it, not a
digest of this working tree and not a Git object id. Its scope is the whole
s2geometry repository at that commit.

**Abseil.** The driver's source-archive set covers the eight top-level projects
(blake3, sheenbidi, lmdb, inchi, s2geometry, fast_float, ryu, pcre2) and carries
no entry for a nested dependency, so no digest of the Abseil revision was in
that set. One has since been taken, from a canonical clone rather than from
this tree, because `vendor/abseil-cpp` is a vendored archive with no `.git`
directory and Git therefore resolves any `git archive` aimed at it to the
**outer** s2geometry repository:

```
8b39fdb7c4a5d7ef0ee88b0b4eb3d23c77623d6f793579a5e0d0af7cf2ce6eaa  abseil-cpp d38452e1ee03523a208362186fd42248ff2609f6
```

`local://foundation-expansion-s2geometry-abseil-canonical-pin-acquisition-273.log`
(exit 0) records `git clone --depth 1 --branch 20250814.1 --bare
https://github.com/abseil/abseil-cpp.git …/abseil-canonical.git` into task
scratch, and
`local://foundation-expansion-s2geometry-abseil-canonical-archive-digest-275.log`
(exit 0) records `git --git-dir=…/abseil-canonical.git archive --format=tar
d38452e1… | sha256sum` under `set -o pipefail`. Same kind of number as the
s2geometry one above: a digest of the commit's tree as `git archive`
serialises it, not a digest of this working tree and not a Git object id.

The digest fixes the pinned release. The following comparison is **an earlier
receipt, taken before any authorised portability change**, and is kept as
history. It is not a current pristine-tree claim:

```
local://foundation-expansion-s2geometry-abseil-entire-vendored-tree-pristine-286.log
diff -qr …/session-01a0f400/abseil-reference \
         /vol/fob-vol7/mi19/gertullj/foundation-libs/s2geometry/vendor/abseil-cpp
```

exit 0, **empty output**, 2026-10-01 23:14:30Z. The reference tree was
extracted from the canonical bare clone at exactly
`d38452e1ee03523a208362186fd42248ff2609f6` (the same clone as 273, and the same
commit 275 digests), and `diff -qr` compared it with the entire vendored
directory — every file, not a selected subset, and including the `.inc`
fragments and packaging scaffolding. It established **zero** differences at that
time. Four authorised Abseil portability changes landed after it, and three more
since; the current delta is eight files and is disclosed below.

### Owner-authorised upstream portability changes

**One file under `src/` and seven under `vendor/abseil-cpp/`** differ from their
canonical pins. Eight, in total, and no others.

The single S2 file:

* `src/s2/util/math/exactfloat/bignum.cc`: `std::from_chars` is given the string
  view's character pointers, `s.data()` and `s.data() + s.size()`, instead of
  `s.cbegin()`/`s.cend()`. Upstream passes iterators, and
  `std::from_chars(const char*, const char*, …)` takes pointers, so the two meet
  through an implementation-specific iterator conversion. Nothing about the
  digit algorithm, the chunking, the sign handling or the rounding changes.

The seven Abseil files:

* `absl/base/internal/direct_mmap.h`: real Linux Hexagon `mmap2`, whose
  offsets use fixed 4096-byte units. A real two-page file and libc `mmap`
  independently confirm the nonzero offset: `page_size=65536 offset=65536:
  libc=B expected=B DirectMmap=B`. Byte-offset and `AT_PAGESZ`-unit variants
  failed before the correction.
* `absl/base/internal/low_level_alloc.cc`: on WASI, arena backing regions come
  from real SDK libc `posix_memalign` at the arena page size, because the stock
  path is `mmap` and `mmap` is not available. Each region carries its base
  pointer, so `Coalesce` never merges two blocks that came from different
  backing allocations, and a split block inherits its parent's base.
  `std::free` replaces `munmap` on the arena-teardown path. The split, freelist
  and ownership logic is unchanged on every non-WASI target.
* `absl/base/internal/low_level_alloc.h`: `ABSL_LOW_LEVEL_ALLOC_MISSING` is not
  defined for `__wasi__`, and the comment above that guard says where backing
  memory actually comes from on each target rather than asserting one
  requirement for all of them.
* `absl/debugging/internal/stacktrace_powerpc-inl.inc`: read embedded
  PowerPC32 musl `gregs`, retaining glibc and PowerPC64 paths.
* `absl/debugging/internal/examine_stack.cc`: use the real hosted Hexagon
  program counter and PowerPC32 musl register context.
* `absl/log/internal/conditions.h`: hosted Linux Hexagon uses `unistd.h`'s
  `_exit`, not the freestanding/Windows declaration path.
* `absl/time/internal/cctz/src/time_zone_format.cc`: NetBSD is added to the
  condition that keeps a BSD's native locale namespace, so `_XOPEN_SOURCE 500`
  is no longer selected for SUSv2 ahead of NetBSD's libc++, exactly as upstream
  already does for FreeBSD and OpenBSD.

Each of the eight retains its licence/copyright header byte for byte and carries
a prominent change notice immediately below it. **The notice wording differs per
path, and that is deliberate:** the six earlier Abseil files say
`Foundation fork change (2026-10-02): …`, while the CCTZ NetBSD guard and the
S2 pointer-iterator fix say `foundation-libs portability change: …`. Both are
prominent Apache-2.0 §4(b) notices. Neither variant is restyled onto the other:
the six files already carried the dated form, and rewriting them to match the
two newest would change bytes that no portability question asked about.

`UPSTREAM.sha256` pairs the pristine and current digest of each of the eight.
A whole-tree comparison against freshly pinned canonical trees — the s2geometry
`src/` tree and the entire Abseil tree, every file, directory and symlink target
— found **exactly these eight paths and no extra or missing path**
(`local://foundation-portability-canonical-source-provenance.json`,
`local://foundation-cross-test-s2-approved-vendor-diff.json` for the earlier
four-Abseil-only comparison). That is an observed eight-file delta, **not** a
pristine pass; pristine comparison 286 above is history and describes a tree
that no longer exists here.

Two build-only corrections use existing upstream facilities: OpenBSD
PowerPC/PowerPC64 selects `ABSL_USE_UNSCALED_CYCLECLOCK=0` consistently on all
three C++ modules, using the real `steady_clock` backend; Windows links real
`dbghelp` on Abseil. No invented clock frequency, replacement SDK header,
algorithm change, omitted core source or weakened fixture is involved.

**One earlier Abseil digest attempt is `WITHDRAWN` and must not be used.**
`local://foundation-expansion-s2geometry-abseil-immutable-archive-digest-272.log`
printed

```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  -
```

with exit 0, and that value is the SHA-256 of the **empty byte string**, not of
an Abseil archive. The pipeline had no `pipefail`, Git printed
`Schwerwiegend: Kein Tree-Objekt: d38452e1…` because it resolved the outer
repository, and `sha256sum` then hashed whatever the stream contained, which
was nothing. The driver withdrew it (`abseil-archive-proof-withdrawal`, same
receipt, `invalid_evidence`). An exit 0 from an empty-pipeline digest is not a
digest; it is recorded here only so the number is never mistaken for one.

The upstream pins are supported by the two tag/commit pairs, the
`lts_20250814` marker and the two canonical archive digests recorded above.
Current bytes have **exactly eight disclosed differences** — one in `src/`, seven
in `vendor/abseil-cpp/` — observed by the whole-tree comparison in
`local://foundation-portability-canonical-source-provenance.json`. Pristine
comparison 286 (zero differences), the four-file vendor comparison and
whole-record replay 231 are all earlier receipts and are named as history where
they are cited; the current 927-record replay is driver-owned under the package
closure and has not been run against this revision.

## Import mechanism

There is no import script and no submodule.

1. The s2geometry repository at the pinned commit is unpacked into this
   package's root, so `src/`, `CMakeLists.txt`, `LICENSE`, `NOTICE`, `AUTHORS`,
   `CONTRIBUTORS`, `CONTRIBUTING.md`, `Config.cmake.in`, `.clang-format`,
   `setup.py` and `pyproject.toml` are at the paths upstream put them at. The
   one exception is upstream's README: since 2026-10-04 those exact bytes live
   at `README.upstream.md`, and `README.md` is this fork's own README. The
   bytes are unchanged — `UPSTREAM.sha256` records the same digest under the
   new name — and no other file moved.
2. The Abseil `20250814.1` release is unpacked whole into
   `vendor/abseil-cpp`.
3. `src/` is byte-identical to the pin **except for one file**, and Abseil except
   for seven: the eight bounded portability changes disclosed above, each with
   its pristine and current fingerprint. CI does not check either tree with a
   zero-diff `git diff --exit-code <commit> -- src`. That step is gone, and
   deliberately so: it can only say "nothing changed", so it fails on the very
   file an authorised fix is about and cannot express "exactly these paths". CI
   instead extracts both canonical archives at their pinned digests and compares
   the whole trees path by path against the eight declared pairs, rejecting an
   extra path, a missing path, a re-edit inside a disclosed path, an altered
   licence header, and a missing or non-prominent notice.
   The separate inherited deletion is `.github/workflows/build.yml`,
   which this fork removed; see `FORK-NOTES.md` §1 and `NOTICE.md`.
4. Every fork-owned file is added around them, and every one of them is named
   in `NOTICE.md`.

### Reading upstream's README

`README.upstream.md` is upstream's file, kept byte-for-byte, and it is the
document to read for upstream's own build instructions, its Python bindings and
its API/ABI stability statement. This fork's `README.md` does not restate it and
does not contradict it: the Zig build, the C bridge and the Nix packaging exist
in addition to what upstream describes, and every fork-specific statement lives
in `README.md`, `FORK-NOTES.md` and `CHANGELOG.md`.

## What this fork is

### What is compiled

One graph, three native libraries, no network access and no system copy:

| Artifact (GNU/ELF targets) | Artifact (`x86_64-windows-gnu`) | Contents | Linkage |
|---|---|---|---|
| `libabsl.a` | `absl.lib` | 153 Abseil translation units | — |
| `libs2.a` | `s2.lib` | 108 s2geometry translation units | links `libabsl.a` |
| `libs2bridge.a` | `s2bridge.lib` | `zig/bridge.cc` | links `libs2.a`; forwards the two upstream header installs; installs `zig/bridge.h` as `s2geometry_bridge.h` |

That table is the static delivery, which is this SDK's default. `-Dlinkage=dynamic`
delivers the same three as shared objects with upstream's own sonames, and on an
**ELF target** adds a fourth, runtime-only artifact: `libs2cpp.so.0.16.0`, the
build compiler's own shipped libc++/libc++abi/libunwind, compiled and installed
by `build_support/cpp_runtime.zig`. The backend dependency closure below draws
the difference, and `CHANGELOG.md` §67 is the full account.

`build.zig` names each `addLibrary` `absl`/`s2`/`s2bridge`, and Zig appends the
target's own suffix, so the bridge archive is `libs2bridge.a` on the ELF
targets and `s2bridge.lib` on `x86_64-windows-gnu`. The link line in the
recorded Windows gate names the latter:
`local://foundation-expansion-s2geometry-resume-check-x86_64-windows-gnu-254.log`
passes `…/o/fa886598d79df189d142e4dba4e5d25c/s2bridge.lib` to the test
compile, while the Linux receipts name `libs2bridge.a`. The install step
publishes all three under `zig-out/lib`; the observed prefix install recorded
`local://foundation-expansion-s2geometry-installed-artifact-gruenau8-224.log`,
exit 0, "Build Summary: 12/12 steps succeeded", `install absl`, `install s2`,
`install s2bridge`.

The 108 are the `add_library(s2 ...)` block of `CMakeLists.txt:141-249`, in
upstream's order and spelling, copied verbatim into
`build_support/s2_sources.zig`. The list is the authority and no count guards
it: an earlier revision asserted both list lengths at comptime, that assertion
is what first exposed the one omitted Abseil unit, and it has since been
removed rather than corrected (`CHANGELOG.md` §66, `FORK-NOTES.md` decision 26).

The 153 are every `absl_cc_library` source entry in the vendored tree — from
`SRCS` **or** `HDRS`, because upstream's own `absl_cc_library` compiles both
together (`vendor/abseil-cpp/CMake/AbseilHelpers.cmake:234`, `:260`) — except
fourteen that are `TESTONLY` or carry a `GTest::` dependency in their own
declaration:

```
absl/base/internal/atomic_hook_test_helper.cc   absl/log/internal/test_actions.cc
absl/base/internal/exception_safety_testing.cc absl/log/internal/test_helpers.cc
absl/base/spinlock_test_common.cc               absl/log/internal/test_matchers.cc
absl/container/internal/hash_generator_testing.cc absl/log/scoped_mock_log.cc
absl/container/internal/test_instance_tracker.cc absl/status/internal/status_matchers.cc
absl/debugging/internal/stack_consumption.cc   absl/strings/internal/pow10_helper.cc
                                                absl/synchronization/internal/per_thread_sem_test.cc
                                                absl/time/internal/test_util.cc
```

`absl/random/internal/chi_square.cc` and
`absl/random/internal/distribution_test_util.cc` are **not** among them:
upstream declares them in `absl_cc_library(random_internal_distribution_test_util)`
with no `TESTONLY` marker and no `GTest::` dependency, so they are library
translation units here. The list is enumerated rather than globbed because a
glob over `vendor/abseil-cpp/absl/**/*.cc` picks up 231 `*_test.cc` files,
every `*_benchmark.cc` and all fourteen excluded units above — and it would make
"the library, without its tests" an accident of a file-name pattern rather than
a recorded decision.

Abseil's platform variants are all listed unconditionally, exactly as upstream
lists them, and each selects itself with its own `#ifdef`:
`crc_memcpy_fallback.cc` beside `crc_memcpy_x86_arm_combined.cc`,
`time_zone_libc.cc` beside `time_zone_posix.cc`, and all five `*_waiter.cc`
files. The genuinely target-selected Abseil settings are compiler *flags*, not
source files; see `build_support/platform_flags.zig`.

### With which switches

`build_support/platform_flags.zig` is the single place, and every flag there is
either copied out of an upstream build definition or justified from a recorded
compile. Two functions, because two translation-unit sets get two flag lists:
`s2Flags` is used for the 108 S2 units **and** for `zig/bridge.cc`, and
`abslFlags` is used for the 153 Abseil units. `addAbseil` is called first
(`build.zig:181`), then `addS2` (`:182`), then `addBridge` (`:183`).

| Flag | Used by | From |
|---|---|---|
| `-std=c++17` | both | `CMakeLists.txt:29-32` (`CMAKE_CXX_STANDARD 17`, `…_REQUIRED ON`, `…_EXTENSIONS OFF`) |
| `-fsized-deallocation` | `s2Flags` **only** | `CMakeLists.txt:122-127`; **required** here — see below |
| `-fno-fast-math`, `-ffp-contract=off` | both | `src/s2/_fp_contract_off.h` ("S2 requires deterministic arithmetic for correctness"); its `#pragma STDC FP_CONTRACT OFF` is a no-op on compilers with only the GNU form, so the command line carries it for every translation unit including Abseil's |
| `-DABSL_MIN_LOG_LEVEL=1` | both | `CMakeLists.txt:62`, issued before the Abseil fetch so it reaches Abseil too |
| `-DNOMINMAX` | both | the only define in `absl/copts/copts.py`'s `ABSL_GCC_FLAGS` / `ABSL_LLVM_FLAGS` |
| `-D_USE_MATH_DEFINES` (Windows targets only) | both | **this fork's one deliberate extension**, see below |
| `-isystem src`, `-isystem vendor/abseil-cpp` (bridge only) | bridge TU | `CMakeLists.txt:46-49` + `:285-291`, see below |

#### `-fsized-deallocation` is required, and only on the S2 half

Upstream requires it in the `else()` branch of `if (MSVC)`
(`CMakeLists.txt:122-127`), scoped by its own comment to "a bug with clang <
19" and marked removable once clang 19 is the minimum.

**An earlier revision of this file claimed the flag was dead weight** because
Zig drives its own bundled clang and every object here carries
`DW_AT_producer: clang version 21.1.0`, two majors past the guarded bug. That
claim is `WITHDRAWN`. `zig build check -Dtarget=x86_64-windows-gnu` observed
`local://foundation-expansion-s2geometry-check-x86_64-windows-gnu-235.log`:
with the flag omitted, `compile lib s2` failed with two errors —
`src/s2/util/bitmap/bitmap.h:718` `no matching function for call to 'operator
delete[]'` and `src/s2/util/coding/coder.cc:62` `no matching function for call
to 'operator delete'`, both reached through `s2shape_nesting_query.cc:30-113`.
The compile line printed in that receipt carries `-Wno-attributes` and
`-Wno-deprecated-declarations` and **no** `-fsized-deallocation`, so the
omission is what those two errors are about. With the flag restored the
identical target compiled `libabsl.a`, `libs2.a`, the bridge and the smoke
program: `local://foundation-expansion-s2geometry-resume-check-x86_64-windows-gnu-254.log`
records `compile lib s2 … success`, `compile lib s2bridge … success`,
`translate-c success` and `compile exe s2-smoke … success`. A compiler version
does not establish target-specific defaults; the target's own declaration set
does.

`abslFlags` deliberately omits it, and that follows upstream's own ordering
rather than adding a second decision: upstream's
`FetchContent_MakeAvailable(absl)` runs at `CMakeLists.txt:80`, while
`add_compile_options(-fsized-deallocation)` is directory scope at `:127`,
after it. Abseil's targets are created before the option exists and never see
it. This build reproduces that ordering by giving `addAbseil` its own flag
list, applied before `addS2` runs.

#### Two upstream selections are deliberately not carried

* `-Wno-attributes` and `-Wno-deprecated-declarations`
  (`CMakeLists.txt:120-121`) are **not** carried, and neither are Abseil's own
  warning-flag selections. A `-Wno-…` that silences a diagnostic in an
  upstream header silences the same diagnostic in this repository's own
  `zig/bridge.cc`, which is where a real defect has to stay visible, and
  carrying them would assert a compiler warning policy no run here has
  established. Nothing is substituted for them: the include *kind* is.
* The MSVC branch of `CMakeLists.txt:108-114` (`-J`, `-D_USE_MATH_DEFINES`,
  `-DNOMINMAX`) is not applicable, because this package never invokes
  `cl.exe`. Its `-D_USE_MATH_DEFINES` half is reinstated for Windows below,
  since the reason MSVC needs it applies to `x86_64-windows-gnu` too.

#### What is added, and how the header trees are included

* `-D_USE_MATH_DEFINES` is added on Windows targets. Upstream pairs it with
  `if (MSVC)`; the reason MSVC needs it is that `<math.h>` only defines `M_PI`
  and friends outside strict-ANSI mode or when the macro is set, and upstream's
  own `CMAKE_CXX_EXTENSIONS OFF` (`CMakeLists.txt:32`) means strict ANSI
  everywhere. The S2 library uses `M_PI` in `src/s2/s1angle.cc`,
  `s1interval.cc`, `s1chord_angle.cc`, `s2boolean_operation.cc` and
  `s2buffer_operation.cc`, and Zig's bundled windows headers
  (`lib/libc/include/any-windows-any/math.h`) gate it on the same condition, so
  the define is required for `x86_64-windows-gnu` exactly as it is for MSVC.
* The two upstream header trees are on the **bridge** translation unit as
  *system* includes, and are ordinary includes everywhere else. That is
  upstream's own published arrangement for this situation:
  `CMakeLists.txt:46-49` defines `S2_USE_SYSTEM_INCLUDES` as "Silence warnings
  in s2 headers by marking them as SYSTEM includes", and `CMakeLists.txt:285-291`
  applies it to the `s2` target's **PUBLIC** include directory — the one every
  consumer of the installed library is compiled with. `zig/bridge.cc` is exactly
  such a consumer. The Abseil and S2 libraries themselves keep ordinary include
  paths, so every upstream translation unit is still diagnosed in full.

No warning switch is used to silence the upstream headers.
`-Wno-nullability-completeness`, `-Wno-gnu-alignof`, `-w` and `-pedantic-errors`
would each also silence the same diagnostics in this repository's own
`zig/bridge.cc`, for the reason given above.

### The bridge and the facade, in one paragraph each

`zig/bridge.h` is a plain-C99 `extern "C"` surface of **93 entry points**,
because `addTranslateC` translates C and the upstream library is C++17 with
classes, virtual `S2Region` dispatch and `absl::string_view`. It is `S2CellId`,
`S2LatLng`/`S2Point`, `S2Cell` area and geometry, `S2Cap`, `S2LatLngRect`,
`S2Loop`, `S2Polygon` including its boolean operations, `S2RegionCoverer`, and
two raw loop measures. `zig/bridge.cc` is the same surface implemented: a
validation with ordinary comparisons followed by exactly one upstream call.
Not one of them computes geometry. Closest-edge, `S2Builder`, the fractal
generators, the shape-index queries and the coded/encoded vector types are
**not** wrapped; the whole upstream archive and every upstream header stay
reachable from a C++ consumer through the install set, and the coverage choice
is recorded in `FORK-NOTES.md` §5.

`zig/root.zig` is the public Zig module, registered as `s2geometry` by
`b.addModule`. It is a small facade over the bridge: units in every name
(`lat_deg`, `radius_deg`, `perimeterRad`), caller-owned output buffers with the
required length always reported, a closed error set cut at what the bridge can
report, and opaque `Loop`/`Polygon` handles whose `deinit` calls the matching
C++ free. `pub const c = @import("c")` re-exports the translated bridge as the
raw escape hatch.

It registers **104 public methods** across ten types — `CellId` 33, `Polygon`
20, `Loop` 17, `Cell` 8, `Coverer` 8, `LatLng` 6, `LatLngRect` 6, `Cap` 4,
`Point` 2, and `BoundUV` none, being a plain struct of values. Those 104
declarations carry **79 distinct names**, because `containsPoint`, `isValid`,
`deinit`, `area`, `normalize` and a handful of others legitimately recur on
several types. An earlier revision of this file said 79; that was the
distinct-name count presented as a method count, and it is wrong in the way
that matters — it understates the surface by a quarter.

Both numbers are **source facts counted from `zig/root.zig`, not evidence that
anything works**. A count says a declaration is written down; it says nothing
about whether the declaration compiles, whether its body is ever instantiated,
or whether the bridge call underneath returns what the doc comment promises.
The evidence for that is `zig build check`, which attaches `tests.zig` — where
every public method is called with concrete argument types — to every target's
step. The 93 bridge entry points are the same kind of count: 93 declarations in
`zig/bridge.h`, 93 definitions in `zig/bridge.cc`.

### The status and sizing contract

Of the 93 entry points, 91 return `S2BridgeStatus` and two
(`s2br_loop_destroy`, `s2br_polygon_destroy`) return `void` because they can
only release storage. The rules below are the whole error contract, and each one
exists because leaving it out turned a reported error into a process-killing
one:

* **A boolean answer is never the return value.** A predicate writes `0` or `1`
  through an `int*` out-parameter and still returns a status, so "the answer is
  false" and "the call was rejected" are different observations. That is why
  `CellId.contains`, `Cell.containsPoint`, `Cap.containsPoint`,
  `LatLngRect.containsLatLng`, `Loop.containsPoint` and `Polygon.containsPoint`
  are `Error!bool` in the facade and not `bool`: an invalid id, a
  non-unit-length vector or a `NULL` out-parameter produces an error, and none
  of those may be reported as "false".
* **An index is bounded before it is narrowed, never after.** The bridge checks
  every index against `num_vertices` with an ordinary comparison, but the
  facade takes those indices as `usize` and the bridge's own parameters are
  `c_int`, so a `@intCast` on the way across can trap before the bridge's check
  is ever reached. `Loop.vertex(maxInt(usize))` did exactly that: a panic at
  `zig/root.zig:956` — "integer does not fit in destination type" — where the
  value should have been `S2BRIDGE_INVALID_ARGUMENT`, and the caller had no way
  to write the failing line themselves. This is Decision 7's rule for
  `max_cells`, generalised: a field or parameter whose C type is narrower than
  the Zig type needs the same ordinary representability check, and the check has
  to sit on the Zig side of the conversion. Five methods were in scope —
  `Loop.vertex`, `Loop.vertexLatLng`, `Polygon.loopNumVertices`,
  `Polygon.loopVertex`, `Polygon.loopVertexLatLng` — and all five now call one
  private helper, `fn asIndex(i: usize) Error!c_int` (`zig/root.zig:145-148`),
  which reports `error.InvalidArgument` above `maxInt(c_int)` and converts
  otherwise. `Cell.vertex` takes a `u8` and cannot overflow a `c_int`, so it is
  not in scope — which is the test for whether a method is.
* **An unrecognised status is an error, never a pass.** The facade's `check`
  compares the returned value against the five enumerators and maps anything
  else to `error.Internal`. A bridge that grows a sixth status cannot turn into
  a silent success.
* **A list is two-pass, and the count is the count.** The count-only form is
  requested by passing a `NULL` buffer **or** a `cap` of `0` — either one, and
  the bridge treats them identically rather than making the caller pick a
  spelling. The count-only path writes the required length into `*out_count` and
  returns `S2BRIDGE_OK`; it writes no elements, because there is no buffer to
  write them into. Pass a real buffer and the entry point either fills it or
  returns `S2BRIDGE_BUFFER_TOO_SMALL` with the required length still in
  `*out_count`. The counting pass and the filling pass are one call with one
  bound, so the number reported is exactly the number a filling call would
  write: `CellId.childrenCount`/`CellId.children`,
  `vertexNeighborsCount`/`vertexNeighbors`,
  `allNeighborsCount`/`allNeighbors`, every `Coverer.covering…`/`…Count` pair,
  and `CellId.toToken`/`toDebugString`. A short buffer is refused **before** any
  traversal, so a rejected call never half-writes one.
* **"Nothing was written" is not a blanket any caller may rely on.** It holds
  for the element buffer on the count-only and too-small paths. It does **not**
  hold for the out-parameters on a rejected call: the bridge sets `*out` to
  `nullptr` and `*out_count` to `0` before it decides, so a
  `S2BRIDGE_INVALID_ARGUMENT` leaves those two holding defined values rather
  than whatever the caller left in them. `zig/bridge.h:102` currently states
  "Nothing was written" for that enumerator without the qualification, and the
  header is being corrected; this file records the behaviour the code has, not
  the blanket the header still carries.
* **Counting must not cost the thing being counted.** `s2br_cell_children`
  sizes in constant time: it takes `child_begin(level)` and `child_end(level)`
  and subtracts their `distance_from_begin()` — upstream's own count of `next()`
  steps from the level's first cell (`s2/s2cell_id.h:360-363`), which upstream
  documents as callable on `End()` as well as on valid ids. A face cell asked
  for level 30 spans 4³⁰ = 2⁶⁰ cells; that is not a list any caller can hold and
  not a walk any machine can finish, so the range is measured, not materialised.
  A span a `size_t` cannot represent is refused as
  `S2BRIDGE_INVALID_ARGUMENT` rather than reported wrapped.
* **Caller counts are checked before the arrays are read.** Every constructor
  that takes a vertex array first proves the count is one upstream can be told
  about at all: `count <= INT_MAX` (upstream stores vertex and loop counts in
  `int` — `s2/s2loop.cc:203`, `s2/s2polygon.cc:530`, `s2/s2polygon.h:248`) and
  `count <= SIZE_MAX / element_bytes`, so no `xyz + 3 * i` walk can wrap.
  `s2br_polygon_create_loops` also rejects a per-loop length below 3 and sums
  the lengths with an explicit carry check, then bounds the **total**, because a
  sum that is individually fine can still exceed what one `int` holds.
* **Caller vertices are checked for unit length before any of them reaches
  upstream.** `AllUnitPoints` walks the chain with upstream's own
  `S2::IsUnitLength` tolerance (`|Norm2() - 1| <= 5 * DBL_EPSILON`,
  `s2/s2pointutil.cc:32-40`), which one comparison also uses to reject a
  non-finite component. This is not redundant with `s2br_loop_is_valid`: upstream
  says so itself — "this check happens too late in debug mode, because
  `S2Loop` construction calls `s2pred::Sign` which expects vertices to be unit
  length" (`s2/s2loop.cc:225-230`) — and `Init` reaches the exact predicate
  through `InitOriginAndBound` (`s2/s2loop.cc:201-207`, `:271`), where
  `s2pred::TriageSign` debug-asserts `a.Norm2() <= 2`
  (`s2/s2predicates.h:394`). A vertex that is not a direction is an argument
  upstream does not accept, not a malformed loop for the validator to report.
* **A boolean operation validates its operands before it calls upstream.**
  `RequireValidOperand` asks upstream's own `S2Polygon::IsValid()` and maps a
  false answer to `S2BRIDGE_INVALID_ARGUMENT`, because `InitToOperation` hands
  both operands straight to `S2BooleanOperation` (`s2/s2polygon.cc:936-943`),
  which has no answer for a polygon its own validator rejects. It is asked
  rather than inferred from the outcome, and this bridge does not get to decide
  what a valid polygon is.
* **A result this bridge builds is never validated behind the caller's back.**
  `DeferValidation` sets `S2Debug`'s deferred-validation override on every loop
  and polygon this bridge constructs, so the fatal `ABSL_CHECK(IsValid())` in
  `S2Loop::InitIndex` (`s2/s2loop.cc:353-359`) does not run on a chain
  `s2br_polygon_is_valid` exists precisely to report. The result's own
  `InitToIntersection` / `InitToUnion` still decides what it emits, and
  `s2br_polygon_is_valid` still answers for it.

`S2BRIDGE_INTERNAL_ERROR` is what an upstream call reports when it fails through
a status type of its own rather than by throwing, and it is now **produced**.
`s2br_polygon_union` and `s2br_polygon_intersection` bind the `S2Error`
out-parameter overloads of `InitToIntersection` / `InitToUnion` — the ones that
take `s2builderutil::IdentitySnapFunction(S2::kIntersectionMergeRadius)`, the
snap function upstream's own two-argument overloads pass
(`s2/s2polygon.cc:955-957`, `:981-983`) — and map a `false` result to
`S2BRIDGE_INTERNAL_ERROR`. The choice is forced, not stylistic: the overloads
without the `S2Error` parameter report through
`ABSL_LOG(DFATAL) << … << error` (`s2/s2polygon.cc:945-951`), and DFATAL
aborts in every optimise mode, so they could not report this as anything at
all. Upstream's `S2Error` is still not surfaced as a Zig type — its message
text is not a contract this package can promise across upstream releases — but
the *fact* of its failure is, and the facade maps it, and any unrecognised
non-zero status, to `error.Internal`.

**All of this is now gated.** The three driver probes that found the counting,
constructor and boolean-operation defects are in `FORK-NOTES.md` (L19, L20)
with their receipts; the corrections answering them are in `zig/bridge.cc` with
permanent behavioural regressions, and the signatures are unchanged — 93 bridge
declarations, 104 facade methods, same ABI. The native Debug and ReleaseSafe
runs both report **45/45 tests passed** at that point
(`…-final-native-debug-393.log`,
`…-final-native-releasesafe-394.log`), and the six added tests are those
regressions. See "Where the build stands right now" below for the full set.

And a fourth defect, of a different kind, was found by running the facade
rather than by reading it. A throwaway index probe **compiled** against the
current facade and the installed C surface — `exit 0`, empty output
(`…-facade-index-before-compile-346.log`) — and then **died at run time, exit
134** on `loop.vertex(std.math.maxInt(usize))`
(`…-facade-index-before-run-347.log`):

```
thread 10211 panic: integer does not fit in destination type
…/zig/root.zig:956:51: in vertex (root.zig)
        try check(c.s2br_loop_vertex(self.handle, @intCast(i), &xyz));
…/s2-index-before.zig:6:20: in main
    if (loop.vertex(std.math.maxInt(usize))) |_| …
```

The library did nothing wrong here: the value was rejected, loudly, before any
upstream call. The fault is that a *caller* cannot construct the failing case
without killing their own process, which is the whole distinction `Error!`
exists to draw.

The same probe **after** the guard: compile `exit 0`
(`…-facade-index-after-compile-348.log`), run `exit 0`, printing
`oversized public vertex index rejected as InvalidArgument`
(`…-facade-index-after-run-349.log`). **What that covers is worth being exact
about**: the current `zig/root.zig` was linked against the **already-installed**
native archive, so on its own that receipt is evidence about the facade guard
and not about a recompiled bridge. The full native runs since then — 45/45
tests in both Debug and ReleaseSafe at that point, and **46/46** now (417,
418) — are what cover all four repairs together,
against a graph rebuilt from this tree.

### Current gates and historical boundary closure

**The native gates below are earlier receipts, not current results.** The runs
they name were taken before the CCTZ NetBSD guard, the `low_level_alloc`
WASI corrections and the `bignum.cc` pointer-iterator fix landed. Those three
are real source changes inside the compiled closure, so those runs are evidence
about an earlier tree.

For that earlier tree: native source gates passed 46/46 in Debug and
ReleaseSafe, with smokes, Debug installation and a real source consumer
(`local://foundation-cross-test-final-native-s2geometry.json`), and the six
compile-only cross targets gave four passes and two dependency failures.

**For the current tree the native matrix is observed, and everything else is
`PENDING-VERIFICATION`.** Sixteen cells — `-Dlinkage` (static, dynamic) ×
`-Druntime` (false, true) × Debug / ReleaseSafe / ReleaseFast / ReleaseSmall —
each `exit 0`, each printing "46/46 tests passed" and `smoke success`, with step
counts of 39/39 (native shared), 32/32 (native static), 36/36 (runtime-loaded
dynamic) and 33/33 (runtime-loaded static). The receipts are timestamped JSON
under `/home/tmp2/gertullj/scratch/foundation-libs/contract-physics-lua/current-native-evidence/`,
one per cell, with an index listing all sixteen.

**Not covered by those sixteen, and still open:** the six compile-only cross
targets, the full 53-cell `cross-test` matrix, the standalone `consumer/`
package, an installed C or C++ consumer compiled against the install set, a
**relocated** shared install actually loading its closure, the Nix derivations,
and the filtered fetch, integrity replay and materialised consumer. Those belong
to the driver under `FORKS.json.cross_test_wave` and are not inferred from the
earlier native rounds reproduced below.

#### Historical native/boundary rounds before the current eight upstream changes

**Green, on the native target in both optimisation modes and on four of the six
cross targets.** Observed 2026-10-02, all `exit 0`:

| Run | Command | Receipt | Result |
|---|---|---|---|
| native Debug | `zig build test smoke install -Doptimize=Debug --prefix …` | `…-final-native-debug-393.log` | exit 0, "Build Summary: 17/17 steps succeeded; 45/45 tests passed", `run test s2-tests 45 pass (45 total)`, `smoke success`, and all three archives installed |
| native ReleaseSafe | `zig build test smoke -Doptimize=ReleaseSafe` | `…-final-native-releasesafe-394.log` | exit 0, 45/45 tests and `smoke success`. **This run did not install** — `install` was not in its command, and the installation evidence is 393 alone |
| `check -Dtarget=x86_64-linux-gnu` | `zig build check -Dtarget=…` | `…-final-cross-x86_64-linux-gnu-397.log` | exit 0, "Build Summary: 10/10 steps succeeded" |
| `check -Dtarget=aarch64-linux-gnu` | | `…-final-cross-aarch64-linux-gnu-398.log` | exit 0, 10/10 |
| `check -Dtarget=x86_64-windows-gnu` | | `…-final-cross-x86_64-windows-gnu-399.log` | exit 0, 10/10 |
| `check -Dtarget=riscv64-linux-gnu` | | `…-final-cross-riscv64-linux-gnu-380.log` | exit 0, 10/10 |
| installed C bridge consumer | compile, then run | `…-final-installed-C-compile-402.log` (exit 0), `…-final-installed-C-smoke-403.log` (exit 0) | 71 numbered checks, all passing. Prints the face-0 id and token, its centre, the face area against 4π/6, the face id range and `next`, the four level-1 children, a 1-cell covering, the octant loop's area / signed area / perimeter, the octant polygon's centroid, and four containment decisions |
| installed C++/Absl consumer | compile, then run | `…-final-installed-Cpp-Absl-compile-404.log` (exit 0), `…-final-installed-Cpp-Absl-smoke-405.log` (exit 0) | 21 numbered checks. Prints the face-0 id, token, level and area, its centre, the Nuremberg level-30 leaf at 49.7034986790773, 11.7706815947448 deg, and the octant loop's area with the centre contained and the antipode outside |
| bounded-boundary probes | compile, then four runs | `…-final-installed-boundaries-compile-406.log` (exit 0), then 407, 408, 409, 410, 411 — **all exit 0** | see below |
| `zig fmt --check` on this fork's own eight source files | | `…-driver-final-eight-sdk-own-zig-format-395.log` | exit 0, empty output |
| `zig fetch` of the package | | `…-typed-final-filtered-package-fetch-396.log` | exit 0, `s2geometry-0.14.0-2Klt8f9eBwEyMQKeHLiAUZ2h680ivy01LNFmKgfhHvsU` |
| native Debug, after the boundary guards | `zig build test smoke install` | `…-boundary-closed-native-debug-417.log` | exit 0, "Build Summary: 17/17 steps succeeded; 46/46 tests passed", `run test s2-tests 46 pass (46 total)`, smoke, install |
| native ReleaseSafe, after the boundary guards | `zig build test smoke` | `…-boundary-closed-native-releasesafe-418.log` | exit 0, 13/13 steps, **46/46 tests**, smoke. Again no `install` in the command |
| `check -Dtarget=x86_64-linux-gnu` / `aarch64-linux-gnu` / `x86_64-windows-gnu` / `riscv64-linux-gnu`, after the boundary guards | | `…-boundary-closed-cross-x86_64-linux-gnu-419.log`, `-aarch64-linux-gnu-420.log`, `-x86_64-windows-gnu-421.log`, `-riscv64-linux-gnu-422.log` | exit 0 each, 10/10 steps |
| `zig fmt`, this fork's own sources, after the boundary guards | | `…-driver-post-boundary-eight-sdk-format-416.log` | exit 0, empty output |
| `zig fetch` of the package, current | | `…-boundary-closed-filtered-package-fetch-424.log` | exit 0, `s2geometry-0.14.0-2Klt8WOCBwFfUQlt-MA55F-8f7bo7bF9cgGyhEukOfSl` |

The bounded probes are the four source repairs, each answered from outside the
package, under a 256 MB address-space limit:

```
407  children status=0 count=1152921504606846976
408  short-buffer status=2 count=1152921504606846976
409  nonunit constructor status=1 handle=(nil)
410  unit bow-tie union status=1 out=(nil)
411  unit bow-tie intersection status=1 out=(nil)
```

`1152921504606846976` is 2⁶⁰ — the level-0-to-30 descendant count, now
answered with no allocation. Status 2 is `S2BRIDGE_BUFFER_TOO_SMALL` with the
required count still reported and the caller's buffer untouched. Status 1 is
`S2BRIDGE_INVALID_ARGUMENT` with a null handle and a null output. 410 and 411
also print two `s2polygon.cc:249] Shape 0 has one or more edges with interior on
the right` lines each — the upstream diagnostic for the bow-tie, emitted
before the status is returned.

**What 409 does and does not prove.** It shows the *constructor* now rejects
non-unit vertices and hands back a null handle. That is the bound L20 asked
for, on the input the probe used. It is **not** by itself a proof that a
boolean-typed build failure is impossible: the two are different inputs and
different call sites, and 410/411 cover the operations on a unit-length
self-crossing loop, not on a non-unit one. Treating the constructor's success
as the whole proof would be reading more into it than it says.

The full graph is in the Debug run: 153 Abseil units, 108 S2 units, the
bridge, the translated header, `smoke.zig`, 45 tests and all three installs.
The smoke sections still print their published and geometric answers — the
octant at π/2, the wedge boolean at π/4 for the intersection and 3π/4 for the
union, the level-22 Sydney covering found among the 42 cells the upstream
fixture publishes.

**46 tests now.** The count has moved twice: 39 originally, 45 after the six
permanent behavioural regressions for the defects above, and **46** since the
count-protocol state-transition test was added. `46/46` is the current result
(417, 418); `45/45` (393, 394) is kept above as the earlier statement about the
tree before the boundary guards — which is what makes a passing run evidence
about the repairs and not only about the library.

The green runs also print seven
upstream `E`-level log lines from Abseil — `s2latlng_rect.h:397 Invalid rect`,
`s2loop.cc:212 Edge 0 is degenerate (duplicate vertex)`, and
`s2polygon.cc:249 Shape 0 has one or more edges with interior on the right` six
times. Those are the *negative* tests exercising exactly the rejected inputs
above; the run is green and they are diagnostics, not failures. Recording that
here so a later reader does not mistake the log for a fault.

#### The 119-error build failure, and what is *not* known about its cause

For several iterations this package did not compile: `compile lib s2bridge`
reported 119 diagnostics — `-Wnullability-completeness` — from upstream headers
reached through `zig/bridge.cc`, first at `src/s2/s2builder.h:473:20`
(`…-final-native-debug-313.log`, `…-final-native-releasesafe-314.log`, and the
four cross runs 316, 317, 319, 320).

**This file has attributed that failure twice, and both attributions are
withdrawn.** The first attributed it to the system-include arrangement,
inferring from `build.zig` carrying `addSystemIncludePath` for both roots
(`:380-381`) alongside an ordinary `addIncludePath` for the same two (`:202-203`)
that the roots had stopped being classified as system headers. The second
attributed all 119 to two C++ typos — `BooleanOp.kIntersection` and
`BooleanOp.kUnion` instead of `::`, at `zig/bridge.cc:1368` and `:1378` — on the
reasoning that a translation unit which fails to parse takes its whole include
graph with it.

**Neither is established, and the record here does not choose between them.**
What is actually observed: the failing runs recorded **117 header diagnostics
alongside 2 errors in this repository's own C++**, the repair changed the
header ownership / system-include roots **and** the `::` syntax **together**,
and the next run was green. No isolated experiment varies one while holding the
other fixed, so the run establishes that the coupled change worked and **does
not** establish which half mattered, or whether the 117 were ever caused by the
two syntax errors at all. Both explanations remain `WITHDRAWN` rather than one
being promoted, and a future reader should not read either into this tree.

The lesson is kept because it cost something, and because it is the *narrower*
one: **a coupled correction does not attribute a cause, and a plausible
explanation is not a diagnosis.** This file stated a cause confidently twice —
once from a build definition, once from a mechanism that was merely plausible —
and the second statement was as unfounded as the first. `FORK-NOTES.md` L22
records it.

A second regression followed and is also fixed. Six assertions in `tests.zig`
compared a raw status against `s2.c.S2BRIDGE_INVALID_ARGUMENT`, which
`translate-c` emits as a signed `c_int` constant while the call returns a
`c_uint`-typed value; that comparison did not compile
(`…-corrected-native-releasesafe-durable-376.log`,
`…-tests-diagnostic-pipe-capture-392.log`). The fix is in the test file, not the
facade: `tests.zig:1401` declares
`const invalid_argument: s2.c.S2BridgeStatus = s2.c.S2BRIDGE_INVALID_ARGUMENT;`
and those six assertions compare against it, so both sides of each comparison
are the same type. `check`'s own parameter at `zig/root.zig:119` was **not**
changed and is not the fix. **No ABI change**: the C signature and every
`S2BridgeStatus` value are exactly as they were.

#### Two boundary holes, and how they were closed

A further review found two real gaps, and both are now fixed and gated. What
each looked like *before* is worth keeping, because the first was worse than the
review expected:

* **`FromFacePos` native `face 0..5`.** The before-probe did not merely return a
  wrong answer — it **died**: exit **-6** (SIGABRT) at
  `src/s2/s2cell_id.h:661] Check failed: is_valid()`, reached through
  `S2CellId::parent` on a face-6 id
  (`…-contract-boundaries-before-smoke-413.log`). That is stronger than the
  review's prediction of a wrong `INVALID_ARGUMENT`, and it is the reason the
  guard had to be an ordinary comparison *before* the native call. The guard is
  now in the bridge at `zig/bridge.cc:346` and `:355`
  (`if (face < 0 || face > 5) return S2BRIDGE_INVALID_ARGUMENT;`) **and** in the
  facade, so both the raw C surface and the typed entry point refuse it; the raw
  out-parameter is left unchanged on failure, so a caller that ignores the
  status reads what it wrote before the call. `FromFace`'s deliberate handling
  of faces 6 and 7 — which upstream uses to produce an *invalid* id, and which
  the facade documents — is **unchanged**; only `FromFacePos` is bounded.
* **the C count promise in `zig/bridge.h:107`.** The before-probe
  (`…-count-protocol-before-smoke-415.log`, exit 1) printed
  `invalid-cell status=1 count=7; null-polygon status=1 count=9` — an error
  **with the count retained**, which is not what a count-only call promises.
  `Coverer` region calls that fail early on a polygon or cell now report
  **count zero**, matching the header, and a new permanent test walks the raw
  sequence the promise is about: a valid count, then an invalid argument, then a
  valid count again, then a null handle — so the state transition is asserted,
  not just the final value.

Both guards are in this repository's own files: **no algorithm, ABI or upstream
native change**, and no upstream byte was touched — `git diff` (268) and the
whole-tree Abseil comparison (286) are unaffected by all of it.

#### Two fixes in the CI workflow's own consumers — not CI job proof

`.github/workflows/verify.yml` had two defects of its own, both found by running
its C and C++ consumers and both fixed in the file:

* the C driver built `FromFacePos`'s Hilbert position as an **ordinal** where
  the bridge takes the raw 61-bit position; line 297 now passes
  `(uint64_t)i << 59`;
* the C++ consumer's compile line lacked `-fsized-deallocation`, which is
  required on any target compiling S2 sources; line 551 now carries it.

**These are corrections to a workflow file, not evidence that a CI job passes.**
No CI job has been run here. They are recorded because the next reader of
`verify.yml` would otherwise have to rediscover both.

#### Historical closure proofs before the current eight upstream changes

Every row here describes an **earlier package**. The 926/926 integrity row is
that earlier record's own count; this tree's record is 927 and has not been
replayed.

| Run | Receipt | Result |
|---|---|---|
| `zig build consumer` | `…-live-consumer-423.log` | exit 0, "10/10" — the separate `consumer/` package resolves this one by path, builds the whole graph itself, runs, and prints its published golang/geo token/id pairs |
| `sha256sum -c UPSTREAM.sha256` inside the current materialised package | `…-current-filtered-integrity-425.log` | exit 0, **926/926 `OK`** — the record and the manifest now agree, with no file missing |
| `consumer` inside the current materialised package | `…-filtered-consumer-426.log` | exit 0, "10/10" |
| installed after-contract probes, compile / run | `…-installed-after-contract-compile-427.log` (exit 0), `…-run-428.log` (exit 0) | `invalid-cell status=1 count=0; null-polygon status=1 count=0` — the count promise holds. And `out-of-contract face=6 status=1 id=0x00000000deadbeef valid=1`: the status reports rejection, the raw out-parameter still holds the **sentinel the caller passed in, unchanged**, and that sentinel is itself a valid id (`valid=1`). It is not null and it is not invalid — the contract is "reject and leave the caller's bytes alone" |
| historical installed C bridge consumer | `…-latest-installed-C-compile-429.log` (exit 0), `…-smoke-430.log` (exit 0) | **71 numbered checks** against the pre-portability archives; no fresh installed-C proof is asserted |
| historical installed C++/Absl consumer | `…-latest-installed-Cpp-Absl-compile-431.log` (exit 0), `…-smoke-432.log` (exit 0) | **21 numbered checks** against the pre-portability archives |

That earlier eight-package round passed fetch, integrity and consumer gates
over 1518 records. Those package bytes predate the currently disclosed eight
upstream changes and the current documents; final closure belongs to the
driver-owned record.

**One distinction kept deliberately.** The `face=6` result above is a
**constructor-bound** proof: it shows `FromFacePos` refuses an out-of-contract
face and leaves the caller's out-parameter alone. It is **not** a
boolean-operation proof — the boolean case is a different call site with a
different input, and it is covered by 410/411 and by the permanent tests, not by
428. Reading one as the other would be reading more into it than it says.

#### Observed macOS and WASI dependency boundaries — earlier receipts

Both of the following are earlier receipts, taken before the WASI provider work
described below. They are recorded as evidence about the **stock** target and are
not claims about the current tree.

`check -Dtarget=aarch64-macos-none` stops in vendored Abseil at
`'CoreFoundation/CFTimeZone.h' file not found` — macOS's framework headers do
not exist on a Linux host, and no include path can supply them
(`…-closure-cross-aarch64-macos-none-355.log`, one error).

`check -Dtarget=wasm32-wasi` stops in vendored Abseil at
`signal.h:2:2: error: "wasm lacks signal support"`, 39 errors, with the mutex
and `<fstream>` failures behind it (`…-closure-cross-wasm32-wasi-358.log`).
That run passed **no** `-Dwasi-sysroot`, so `wasi_provider.Provider.init`
returned null and no provider was configured: stock Zig 0.16.0 wasm32-wasi libc,
no WASIp1-threads sysroot, stock single-threaded default. On that
configuration the stock target has neither POSIX threads nor signals, which is
what the diagnostic reports. It is **not** a statement that wasm32-wasi has no
threads in general — see the provider section below for the configuration that
does supply them.

These failures exposed real SDK/capability requirements. They remain attempted
targets; no diagnostic is suppressed and no core source is omitted. The
macOS boundary is unchanged and unresolved: nothing in this fork has supplied
`CoreFoundation`, and no current run is offered for it.

### The backend dependency closure

Complete, and it is exactly two **carried** trees. On `x86_64-windows-gnu` the
three archives carry the `.lib` spelling, and the graph is the same. On an ELF
target with `-Dlinkage=dynamic` one further installed object joins the closure;
it is not a third tree carried in this repository, and the second diagram below
says where it comes from:

```
  ELF targets                 x86_64-windows-gnu

  libs2bridge.a               s2bridge.lib   <- zig/bridge.cc
      |   links
  libs2.a                     s2.lib         <- 108 s2geometry TUs
      |   links
  libabsl.a                   absl.lib       <- 153 Abseil TUs
      \                       /
       -> libc / libc++ / winpthreads, per target
```

```
  -Dlinkage=dynamic, ELF         static, and every non-ELF delivery

  libs2bridge.so.0.14.0  --.
  libs2.so.0.14.0         DT_NEEDED
  libabsl.so.2508.0.0    --> libs2cpp.so.0.16.0  --> libc
                                 |
  libc, per target               the consumer's own C++ runtime,
                                 or the one named for the target
```

`libs2cpp` is the build compiler's own shipped C++ runtime — libc++, libc++abi
and libunwind from Zig 0.16.0 at source commit
`24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8`, following that compiler's own
`src/libs/libcxx.zig` — compiled by `build_support/cpp_runtime.zig` from
`b.graph.zig_lib_directory`, and installed with the three verbatim `LICENSE.TXT`
files that cover it. It exists because Zig's ordinary *static* C++ runtime
archive is built with hidden exports, and a hidden-exports archive reused across
images cannot preserve `std::locale` facet identity: the earlier shared closure
gave every image its own registry, and S2's log stream crossing an image
boundary died in `std::use_facet`. `libs2cpp` is therefore built with upstream's
own shared-library visibility annotations (`_LIBCPP_BUILDING_LIBRARY` beside
`-fvisibility=hidden`, so `_LIBCPP_EXPORTED_FROM_ABI` resolves to
`visibility("default")`, and without `_LIBUNWIND_HIDE_SYMBOLS`), and the three
S2/Abseil modules are compiled against its ABI (`_LIBCPP_ABI_VERSION=1`) instead
of embedding their own. No file in this repository is edited to do it, and no
other route builds it: `sharedCppOwner(target, linkage)` is `linkage == .dynamic`
together with `target.result.ofmt == .elf` (`build.zig:868-870`).

**The installed copy and the build-cache copy are different artifacts.** On that
route `addNativeGraph` runs twice: the published facade graph carries a
cache-aware runtime search path for the executables in this tree, and the
install graph carries `$ORIGIN` (ELF) or `@loader_path` (Darwin) and nothing
else, so no installed object names a build directory. The three libraries are
compiled a second time for the install tree; `libs2cpp` is configured
identically in both and is therefore one compile step.

* Apart from the compiler's own C++ runtime on the one route above — already
  credited in `NOTICE.md`, and named in the diagram with it — there is **no**
  googletest, Google Benchmark, OpenSSL, boringssl, pcre, zlib or any other
  third-party library in any compiled artifact. The only upstream file in this
  tree that mentions `<openssl/bn.h>` is
  `src/s2/util/math/exactfloat/bignum_test.cc`, and that is an upstream *test*
  this package does not compile.
* Thread support comes from the C library the build already links: `libc`
  provides `pthread_*` on the POSIX targets and `winpthreads` on
  `windows-gnu`, which is the same answer `CMakeLists.txt:86`'s
  `Threads::Threads` gives upstream. No `-lpthread` of this fork's own is
  requested, because that would be a second answer to a question the C library
  has already answered.
* `std::thread` appears in exactly two upstream files,
  `src/s2/thread_testing.cc` and `src/s2/mutable_s2shape_index_test.cc`, and
  neither is compiled here.

### The WASI provider, and the two Zig standard-library files it needs

`wasm32-wasi` reaches a real C and C++ runtime, and it needs two things this
fork supplies rather than fabricates. Neither is a stub, a shim or a silent
diagnostic suppression, and neither is fetched at build time.

**1. The C/C++ provider — external, complete, and opt-in.**
`build_support/wasi_provider.zig` configures a WASI SDK 34+ sysroot supplied on
the command line as `-Dwasi-sysroot=…`. It resolves that sysroot's real
headers, libraries and exception-handling archives; it links the real libc++
ABI-2 closure (`libc++.a`, `libc++abi.a`, `libunwind.a`) plus
`libwasi-emulated-signal.a`; and it sets `single_threaded = false` on **every**
module it configures — the three C++ libraries, the bridge, the translated
header, the facade, the tests and the smoke root. That last part is not
cosmetic: the whole threaded closure shares one SDK libc TLS, so a module left
at Zig's single-threaded default would silently disagree with its siblings about
`errno`. With no `-Dwasi-sysroot` the provider configures **nothing** and the
target falls back to the stock Zig wasm32-wasi libc — which is exactly the
configuration the earlier boundary receipt above describes.

**2. The Zig standard library — a two-hunk fork patch, with its licence
shipped.** The pinned Zig 0.16.0 stock `lib` tree does not compile a threaded
libc-linked wasm32-wasi build. `build_support/wasi_stdlib.patch` repairs exactly
two upstream Zig standard-library sources:

* `std/heap.zig` — a new `page_allocator` branch for the threaded, libc-linked
  WebAssembly build, selecting the real `c_allocator` instead of instantiating
  `WasmAllocator`, which is `@compileError("unimplemented")` for that
  combination. `c_allocator` is stock Zig code over the SDK's own thread-safe
  allocator and already satisfies the whole `Allocator` contract. The exact
  guard this branch tests is written in the patch itself and is the authority;
  what holds either way is that the single-threaded and non-libc WebAssembly
  cases still fall through to `WasmAllocator`, so the "unimplemented"
  diagnostic keeps reporting the genuinely unsupported threaded non-libc case,
  and that `root.os.heap.page_allocator` still takes precedence.
* `std/Io/Threaded.zig` — a finite wasm `memory.atomic.wait32` timeout saturates
  to `maxInt(i64)` instead of wrapping to a negative (indefinite) wait and
  trapping in `@intCast`. `null` still means "no timeout" and is still `-1`.
  Native branches stay byte-identical to stock.

The stock Zig 0.16.0 binary is **unmodified**; the patch is applied to a copy of
its `lib` tree, outside this package, and that copy is passed to the compiler
through `--zig-lib-dir`. There is no build-time download and no proprietary
Apple SDK anywhere in this tree. The complete MIT terms of the compiler — the
licence these two patched files are covered by — are carried verbatim at
`build_support/zig-0.16-LICENSE.txt` (MIT Expat, "Copyright (c) Zig
contributors", 21 lines, SHA-256
`5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177`) and that
file is recorded in `UPSTREAM.sha256` group J. It is a licence record, not a
build input, and it is the one file in `build_support/` the integrity record
carries; the patched `lib` tree itself is SDK-internal mutable state and is
deliberately not hashed there.

**What is not claimed.** These two repairs and the SDK 34 provider are landed
and recorded, but no gate in this package has yet run a full WASI build against
the patched provider, and this file asserts no result for one. Whether that
build compiles and passes is an open observation belonging to the driver's own
run. The native closure above is unaffected: none of this touches a non-WASI
translation unit, and `UPSTREAM.sha256`'s 927 records pin the shipped bytes
either way.

## What is upstream's and what changed

Everything under `src/` is upstream's except one file, and the vendored Abseil
is whole with exactly seven changes, all eight disclosed above. The inherited
top-level workflow deletion is separate. The install set publishes:

* `include/s2/**.h` — the **whole** `src/s2` header tree, 177 headers, under
  the same relative layout upstream uses, so `#include "s2/s2cell_id.h"`
  resolves identically. Upstream installs only a hand-maintained subset, which
  it acknowledges is "only those transitively included by s2 headers we are
  exporting". The subset is a packaging convenience; the tree is the truth, and
  a consumer that reaches a header upstream forgot to list should not be told so
  by an install rule.
* `include/absl/**.h` and `include/absl/**.inc` — the whole Abseil header
  tree. `.inc` is not optional: Abseil headers include their implementation
  fragments by name (`spinlock_linux.inc`, `stacktrace_x86-inl.inc`,
  `symbolize_elf.inc`, `spinlock_win32.inc`).
* `include/s2geometry_bridge.h` — this fork's own bridge, from `zig/bridge.h`.
  The install name is namespaced because a bare `bridge.h` at an include root
  is generic and collidable.

## What is carried but is not part of the package

* `src/s2/*_test.cc`, `src/s2/testing/*`, `src/python/*.cc`, `doc/`,
  `setup.py`, `pyproject.toml`, `.bazelrc`, the `BUILD.bazel` files and the
  whole `CMakeLists.txt`. These travel so that upstream's own CMake and Bazel
  builds still work from this tree, and so that the oracle line references in
  `testdata/` and in the test file resolve. `zig build` never reads them.
* `vendor/abseil-cpp/ci`, `vendor/abseil-cpp/.github`,
  `vendor/abseil-cpp/CMake/`, `vendor/abseil-cpp/conanfile.py` and
  `create_lts.py`. Abseil's own CI and packaging scaffolding.

## Integrity

`UPSTREAM.sha256` carries **927** records — the SHA-256 of every compiled
source, every installed header, every licence and dependency/build record, the
six upstream oracle files the fixtures were transcribed from, this fork's six
independent fixture files, and the Zig compiler's own MIT licence text carried
for the WASI standard-library patch. It is a raw-byte record of this working
tree, produced with SHA-256 from `node:crypto` in a Bun eval cell; no shell
hashing command and no `git` command produced it. Every one of the original 926
was re-derived from the written file with the same method and compared against it;
this revision changed four of those digests, added the licence record, and left
every other record untouched.

**The current 927-record replay has not been run against this revision, and no
result is claimed for it.** That gate belongs to the driver.

Current source and fetched integrity status lives outside these package bytes
in `FORKS.json.cross_test_wave.materialized_packages.s2geometry` and
`local://foundation-cross-test-package-regression.json`. The historical
926-record green receipt 231 predates every one of the current eight changes; it
does not verify the current record. The S2-scoped pristine diff receipt 268 is
likewise history: it was taken before `bignum.cc` was modified and speaks only
about `src LICENSE NOTICE CMakeLists.txt`.

Three different claims, kept apart:

1. **The canonical archive digests pin the two upstreams.** They are digests of
   each pinned commit's tree as `git archive` serialises it, not of this working
   tree and not Git object ids.
2. **The whole-tree comparison establishes exactly eight disclosed
   differences.** One in `src/`, seven in `vendor/abseil-cpp/`, no extra and no
   missing path, each with its pristine and current digest
   (`local://foundation-portability-canonical-source-provenance.json`). That is a
   delta, not a pristine pass.
3. **The record replay checks the shipped bytes against their current digests.**
   Different again, and it is a whole-tree hash comparison, not a delta
   comparison.

CI enforces 1 and 2 directly: it clones both upstreams at their pinned tags,
verifies each `git archive` digest before extracting, and compares the whole
trees path by path against the eight declared pristine/current pairs, rejecting
an extra path, a missing path, a deleted or renamed path, a re-edit inside a
disclosed path, an altered licence header, and a missing or non-prominent
notice. It then runs `sha256sum -c UPSTREAM.sha256` for 3. The whole workflow has
not been run; no job, publication or packaging result is claimed here.

## Synchronising with a new upstream release

The steps, in the order they have to happen:

1. Move `version` and `commit` in `build_support/s2_sources.zig` and
   `build.zig.zon`, and `version`/`commit` in `build_support/absl_sources.zig`.
2. Re-read the new `CMakeLists.txt` `add_library(s2 …)` block and replace
   `build_support/s2_sources.zig` **in upstream's order and spelling**. Diff
   the new list against the old one first: every change is a deliberate
   decision to record, not a reformat.
3. Re-read every `absl_cc_library` block in the new vendored tree, recount the
   `TESTONLY`/`GTest::` exclusions, and replace
   `build_support/absl_sources.zig`. Update the fourteen excluded paths in its
   header comment at the same time.
4. Re-check every CMake/Abseil fact that a comment in `build.zig`,
   `build_support/platform_flags.zig`, this file or `NOTICE.md` cites by line
   number: `CMAKE_CXX_STANDARD` and
   `CMAKE_CXX_EXTENSIONS` (`CMakeLists.txt:29-32`), the directory-scope
   `add_definitions` for `ABSL_MIN_LOG_LEVEL` (`:62`) and the fact that it
   precedes `FetchContent_MakeAvailable(absl)` (`:80`), `S2_USE_SYSTEM_INCLUDES`
   and where it is applied (`:46-49`, `:285-291`), the MSVC branch and the
   `else()` branch beside it (`:108-127`) — **including
   `-Wno-attributes`/`-Wno-deprecated-declarations` at `:120-121` and
   `-fsized-deallocation` at `:127`, and the fact that `:127` is *after* `:80`
   so Abseil never sees it** — the `FETCH_ABSEIL` URL (`:71-75`), the
   `Threads::Threads` line (`:86`) and the `add_library(s2 …)` block
   (`:141-249`). A moved line number makes a comment a lie, and a flag that
   changes scope silently changes which target receives it.
5. Replace both trees wholesale. Never hand-edit upstream source; a divergence
   that is not a fork decision belongs in `FORK-NOTES.md`, not in a diff.
6. Re-derive `UPSTREAM.sha256` with the same method and record the new count in
   its header. If the new release ships a different README, its bytes replace
   `README.upstream.md` and its digest replaces the record under that name; the
   fork's own `README.md` is not touched by a pin move.
7. Add a `CHANGELOG.md` section naming the move, and update the
   `lts_YYYYMMDD` expectation in the CI provenance job if the Abseil LTS
   changed.

## See also

* `README.zig.md` — how to build it, how to use it, every typed operation.
* `README.md` — this fork's README: the current deviations, the current
  matrix, and how to consume the package.
* `README.upstream.md` — upstream's README, preserved byte-for-byte.
* `FORK-LICENSE.md` — the licence of this fork's own files.
* `NOTICE.md` — the licences, the obligations, and every file this fork owns.
* `CHANGELOG.md` — the numbered fork-only divergences.
* `FORK-NOTES.md` — the decisions, what they cost, and what is still pending.
