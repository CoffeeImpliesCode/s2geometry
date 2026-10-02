# s2geometry — the real S2 library, built and wrapped in Zig

This is **google/s2geometry's own C++**, compiled by a Zig 0.16 build and
published through a thin C bridge and a small typed Zig facade. Upstream is
`v0.14.0` at commit `c24b368c67d0b8a2a109c5a75224e73a856bd8b7`, with an
Apache-2.0 project licence and embedded BSD-3-Clause notices, carried in
`src/`. Abseil C++ LTS `20250814.1` at
`d38452e1ee03523a208362186fd42248ff2609f6` is carried in `vendor/abseil-cpp`;
its Apache-2.0 project includes a public-domain CCTZ header and timezone data.
`README.md`, `NOTICE`, `AUTHORS`, `CONTRIBUTORS` and `LICENSE` are in the tree
unmodified; this file is the Zig-facing half, and it does not replace them.

`src/` is upstream's bytes except for **one** disclosed, bounded change:
`src/s2/util/math/exactfloat/bignum.cc` passes the string view's character
pointers to `std::from_chars` instead of its wrapped iterator, which the ABI-2
libc++ this package links on `wasm32-wasi` does not convert implicitly
(`CHANGELOG.md` §50). `vendor/abseil-cpp` carries **seven** disclosed changes,
each with a prominent notice and a pristine/current digest pair, and no
algorithm, ABI or fixture was substituted to get them (`CHANGELOG.md` §45, §51
and §52; `FORK-NOTES.md` decisions 18 and L24). The whole-tree comparison
against the canonical upstream archives observed exactly one S2 path and seven
Abseil paths, with no extra and no missing path
(`local://foundation-portability-canonical-source-provenance.json`).

There is no S2 algorithm in this package. No Hilbert curve, no cell-id bit
layout, no token codec, no spherical triangle area, no covering strategy. Every
answer below was computed by the compiled upstream C++ and reached through
`zig/bridge.h`. `UPSTREAM.md` names the revisions and explains the import;
`NOTICE.md` covers the licences.

## Requirements

* Zig **0.16.0** (`minimum_zig_version` in `build.zig.zon`). Nothing else: no
  CMake, no Bazel, no system s2, no system Abseil, and no network access at any
  point in the build. **The S2 and Abseil core objects** — the 108 S2 and 153
  Abseil translation units — come out of `src/` and `vendor/abseil-cpp/`, and
  this fork's own `zig/bridge.cc` comes out of `zig/`. The *C and C++ runtime*
  objects are a separate matter and are stated per target below: on every
  non-Darwin target they are Zig's own bundled libc/libc++, and on `wasm32-wasi`
  and the Darwin targets they come from an **external, installed SDK** that this
  package links but does not vendor.
* **`wasm32-wasi` only, two external providers.** Every non-Darwin target —
  native and all cross targets alike — needs nothing beyond the compiler, so
  this list is what `wasm32-wasi` adds on top of that:
  * a complete installed **WASI SDK 34** sysroot
    (`…/wasi-sysroot-34.0`, with `include/wasm32-wasip1-threads`,
    `include/c++/v1` and `lib/wasm32-wasip1-threads/eh`), named with
    `-Dwasi-sysroot=<path>`. That option is **this package's own**, introduced by
    this repair as an ordinary `b.option([]const u8, "wasi-sysroot", …)`; it is
    not a compiler option, and it is the only new build option here. The bundled
    Zig libc++ does not carry the filesystem/exception closure this source uses,
    so the graph refuses to compile `wasm32-wasi` without it rather than
    silently dropping facilities;
  * a **patched copy of the Zig 0.16 standard library**, selected with
    `--zig-lib-dir <dir>` — the compiler's **existing standard option**, not one
    this package adds and not a second custom option — and built from
    `build_support/wasi_stdlib.patch` applied to a pristine `<zig>/lib` root.
    Stock Zig 0.16 does not compile this threaded, libc-linked
    `wasm32-wasi` configuration at all; the two hunks that fix it are
    described under "The WASI provider" below and shipped verbatim in that
    file.
* **Apple targets need a real Apple SDK provider, not just the compiler.**
  `aarch64-macos-none`, `aarch64-maccatalyst`, `x86_64-macos` and
  `x86_64-maccatalyst` in the published matrix reach CCTZ's Apple
  default-timezone implementation, which uses CoreFoundation. This package
  declares and links that framework; it does not supply it. No Mac and no
  licensed Apple SDK are available on this host, so those cells remain an
  external boundary and no Apple result is claimed.
* **To run** a `wasm32-wasi` binary: a Wasmtime that still supports
  WASIp1 threads and standard Wasm exceptions. The only runtime provisioned and
  actually exercised here is **wasmtime 46.0.3** (`c5569e6aa`, published
  2026-08-20), invoked as `wasmtime run -Sthreads=y -Wexceptions=y
  -Wshared-memory=y -Wthreads=y …`. Two things are known about that version and
  nothing more: 46.0.3 prints a deprecation warning that `-Sthreads` becomes a
  hard error in **47.0.0**, and Wasmtime **49 and later dropped the threads
  feature** this provider needs. A 47 or 48 release is therefore *not claimed*
  here: a deprecation warning is not evidence that the remaining flags and this
  module still work on a runtime nobody ran. Only 46.0.3 has an observation
  behind it. No global tool on any machine was edited, and none needs to be.

## Commands

| Command | What it does |
|---|---|
| `zig build` | installs `libs2bridge.a`, `libs2.a`, `libabsl.a` (the same three as `s2bridge.lib`, `s2.lib`, `absl.lib` on `x86_64-windows-gnu`), the `include/s2/**`, `include/absl/**` and `include/s2geometry_bridge.h` trees, and **compiles** the smoke program without running it |
| `zig build test` | runs the 46 behavioural tests in `tests.zig` — 39 of published answers and geometric identities, plus 7 permanent regressions for the bridge and boundary defects that probes found — for the selected target, and hands the run to the build runner |
| `zig build test -Doptimize=ReleaseSafe` | the same tests with Zig's safety checks relaxed but the C++ library's behaviour unchanged |
| `zig build smoke` | runs `smoke.zig` and prints its output |
| `zig build check` | compiles the C++ library, the bridge, the translated header, the facade, `tests.zig` and `smoke.zig` for all six required targets and **runs nothing** |
| `zig build consumer` | builds the standalone `consumer/` package, and runs it when this build resolved an executor for the selected target and the build runner was told it may use one (`-fwasmtime`, `-fqemu`, `-fwine`, `-fdarling`, `-frosetta`); otherwise it installs only. See `addConsumerStep` |

`-Dtarget=<triple>` selects one target. `zig build check -Dtarget=…` then
compiles exactly that target instead of the six.

`-Dwasi-sysroot=<path>` supplies the WASI provider above and is meaningful only
for `wasm32-wasi`. It is **this package's own option**, added by this repair as
an ordinary `b.option([]const u8, "wasi-sysroot", …)`; it is not a compiler
option and it is the only new build option introduced here.
`--zig-lib-dir <dir>` is different in kind: it is the **compiler's existing
standard option**, used as-is to select the patched standard-library copy, with
no custom standard-library option of any kind.

### `test` always offers its run; the build runner decides

`zig build test -Dtarget=…` **always** exposes the test run, for every target,
native or foreign. Whether a binary for a foreign target can actually execute
on the machine running the build is not this build script's question — it is
the build runner's, and `std.Build.Step.Run` is where that answer is produced.
The graph's job is to offer the run and keep `has_side_effects`, so the answer
is whatever the runner really did.

**What a foreign run does when no runner exists is a failure, not a skip.**
`failForeign` (`lib/std/Build/Step/Run.zig:2753-2777`) returns
`error.MakeSkipped` only when the run step sets `skip_foreign_checks`;
otherwise it calls `run.step.fail` with
`unable to spawn foreign binary '<path>' (<triple>) on host system (<triple>)`
and the hint to use the matching runner flag or to enable
`skip_foreign_checks`. So the default outcome of "compiled everything, cannot
execute it" is a **named failure**. Deciding that is the harness's job, not
`std.Build`'s: `cross-test` supplies the runner, and a target it has no runner
for is classified by the harness itself. This package sets neither
`skip_foreign_checks` nor any other suppression, so no foreign run in this
package is quietly downgraded from a failure to a skip.

This is a correction, not a new capability claim. The step used to add its run
only when `target.query.isNative()`, and that predicate is narrower than "this
machine can run it": `Target.Query.isNative()` (`lib/std/Target/Query.zig:396-398`)
is `isNativeTriple() and ofmt == null`, and `isNativeTriple()` (`:392-394`)
requires `cpu_arch`, `os_tag` and `abi` all to be null — so `-Dtarget=x86_64-linux`
is **not** native even on an x86_64 Linux host. Observed 2026-10-02 on
`gruenau8` through `cross-test` (run `20261002-033134-17908-30770`): every object
compiled, `Build Summary: 9/9 steps succeeded`, `test success`, **no `run test`
line**, and the harness recorded `no_test_results` with exit 1. A green build
that executed nothing was being reported as a failed gate, which is at least
honest; what it cost is that no foreign target could ever report an executed
Zig API test.

The six-target `check` matrix is untouched by this. `check` attaches the
compile step only, so it remains the fast compile-only baseline it has always
been.

### The full 53-platform matrix

`cross-test` (`~/.local/bin/cross-test`) drives the published 53-platform Zig
0.16.0 tier table. Run it from this package's root:

```sh
cross-test
```

It discovers `cross-test.profile.sh` here, which defines three variables and
nothing else — `CROSS_BUILD_STEP=test`, `CROSS_BUILD_JOBS=4`,
`CROSS_BUILD_TIMEOUT=1800`. It deliberately defines **no** `CROSS_MATRIX` and
**no** `TARGETS`, so the full published matrix applies, and no `-Doptimize`, so
the gate is the default Debug build. Every one of those is a default the
driver's own flags override.

For each target the harness runs `zig build test -Dtarget=<target>` through its
own build runner, so a foreign target that has a runner is executed and a
foreign target that has none still compiles — and is reported as *build only*,
never as a pass. The four outcomes are kept apart on purpose: executed tests,
compile-only, partial execution, and unavailable runner.

**The current 53-cell status is PENDING and driver-owned.** Every whole-tree
gate over this repair wave — native Debug/ReleaseSafe, the six-target
baseline, the full matrix and the final fetched package — has to be re-run
against the current source before any of it is called current. Until the driver
does that, `FORKS.json.cross_test_wave.libraries.s2geometry` and
`local://foundation-cross-test-final-current-s2geometry.json` describe the
**previous** revision of this tree and are read as history here.

Two earlier sweeps are kept with their receipts, each at the revision it
observed: **18 pass, 22 fail, 13 build-only** at
`local://foundation-cross-test-matrix-s2geometry.json`, and a later composite of
**20 pass, 14 fail, 19 build-only** at
`local://foundation-cross-test-final-current-s2geometry.json`. Both were taken
before this wave's changes and neither is a current result. What the current
source contains is the four disclosed Abseil architecture corrections, the
NetBSD cctz feature-test exclusion, the OpenBSD/NetBSD PowerPC real-clock
selection, the real Windows DbgHelp link, the real CoreFoundation framework
declaration on Apple targets, the S2 `from_chars` repair and the WASI
LowLevelAlloc backend. No target, core unit, independent fixture or numerical
tolerance was removed. Bare Linux triples in this standard matrix select musl;
the GNU triples in the six-target baseline below are a separate compile-only
proof.

**How to drive one cell with the WASI provider.** The profile above defines no
target list and no provider path, on purpose: an explicit
`-Dwasi-sysroot=<path>` or `--zig-lib-dir <dir>` is a property of *this
machine's* installed providers, not of the package. The harness appends a
caller's build arguments **after** `--`, so they reach `zig build` verbatim
while the published 53-target list, `CROSS_BUILD_STEP=test`,
`CROSS_BUILD_JOBS=4` and `CROSS_BUILD_TIMEOUT=1800` stay exactly as the
profile states them:

```sh
cross-test wasm32-wasi -- -Dwasi-sysroot=/path/to/wasi-sysroot-34.0 \
  --zig-lib-dir /path/to/zig-wasi-stdlib/lib
```

`--zig-lib-dir` is the compiler's standard option and is forwarded by
`cross-test` the same way; nothing in `cross-test.profile.sh` bakes in a
provider path, and no build-time download is introduced to obtain one.

### `check` is a compile, not a run

For each of the six targets `check` compiles every Abseil translation unit,
every S2 translation unit, `zig/bridge.cc`, the translated bridge header, the
facade, `tests.zig` and `smoke.zig`. `tests.zig` calls every public facade
method with concrete argument types, and Zig only analyses a function body when
something calls it, so compiling that root is what makes `check` evidence about
the facade rather than about an unreferenced archive. Nothing runs: a
cross-compiled result is compile evidence and nothing more. Whether a given
target's prerequisites can be satisfied on a given machine is a question for
the gate, not for this script; all six are attempted unconditionally so that
whatever fails, fails visibly.

## The six targets

`zig build check` attempts exactly these six, and attempts all of them even
when an earlier one fails:

```
zig build check -Dtarget=x86_64-linux-gnu
zig build check -Dtarget=aarch64-linux-gnu
zig build check -Dtarget=aarch64-macos-none
zig build check -Dtarget=x86_64-windows-gnu
zig build check -Dtarget=riscv64-linux-gnu
zig build check -Dtarget=wasm32-wasi -Dwasi-sysroot=<sysroot> --zig-lib-dir <dir>
```

The last line needs its two providers, exactly as a `test` or `smoke` of that
target does. Without `-Dwasi-sysroot=` the graph does not compile a reduced
library: it fails the step with a message naming the missing provider and
saying that no core sources are omitted
(`wasi_provider.configureCompile`). No header is stubbed, no unit is dropped and
no diagnostic is suppressed to make that target go away.

**Current baseline: PENDING.** All six cells have to be re-run against this
wave's source by the driver; the table below is the **previous** revision's
result, kept at the revision that produced it, and its two red cells are not
the two red cells of the current tree.

| Target | Last observed, before this wave |
|---|---|
| `x86_64-linux-gnu` | **PASSED**, exit 0, 10/10 steps; `local://foundation-cross-test-final-baseline-s2geometry-x86_64-linux-gnu.log` |
| `aarch64-linux-gnu` | **PASSED**, exit 0, 10/10 steps; `local://foundation-cross-test-final-baseline-s2geometry-aarch64-linux-gnu.log` |
| `x86_64-windows-gnu` | **PASSED**, exit 0, 10/10 steps; real DbgHelp dependency linked; `local://foundation-cross-test-final-baseline-s2geometry-x86_64-windows-gnu.log` |
| `riscv64-linux-gnu` | **PASSED**, exit 0, 10/10 steps; real DbgHelp-free native path; `local://foundation-cross-test-final-baseline-s2geometry-riscv64-linux-gnu.log` |
| `aarch64-macos-none` | **FAILED**, exit 1: real `CoreFoundation/CFTimeZone.h` absent; `local://foundation-cross-test-final-baseline-s2geometry-aarch64-macos-none.log` |
| `wasm32-wasi` | **FAILED**, exit 1, against the *bundled* provider: 39 Abseil errors from `signal.h:2:2: "wasm lacks signal support"`; `local://foundation-cross-test-final-baseline-s2geometry-wasm32-wasi.log` |

### What changed for `wasm32-wasi`, and what is withdrawn

**`WITHDRAWN`:** "WASI has no signals and no `std::mutex`, and `<fstream>` is
unreachable, so this closure cannot be built there." That sentence described the
**bundled Zig libc++** provider at the revision of the table above. It is not a
statement about WASIp1-threads, and it is no longer this package's position.

What is actually observed now, each with its receipt:

* A complete **WASI SDK 34** `wasip1-threads` sysroot really does supply the
  facilities. A C++ program against the SDK's own EH runtime, imported/shared/
  exported memory and `-fno-single-threaded` ran under wasmtime 46.0.3 and
  printed `real full C++ provider: counter=10000 file=42.5 bad_alloc=1
  cleanup=1` — two threads, a real file stream, a caught `std::bad_alloc` and
  destructor unwinding
  (`local://foundation-portability-complete-cxx-provider-proof.json`). Its own
  `not_proven` line says it is not an S2 source-graph proof; it is used here
  only for the facility claim it makes.
* The **signals** are the SDK's own documented emulation: the Abseil module is
  compiled with `-D_WASI_EMULATED_SIGNAL=1` and linked against the SDK's
  `libwasi-emulated-signal.a`. That is a shipped SDK provider, not a stub this
  package wrote, and it is not a native POSIX signal namespace.
* **Threads** are real: every module this graph builds for `wasm32-wasi` sets
  `single_threaded = false`, and the whole 261-unit source closure links and
  runs.
* The **46 public tests pass** on the SDK provider — `run test s2-tests 46 pass
  (46 total)`, exit 0 — in
  `local://foundation-portability-s2-wasi-corrected-sdk-gates.log`. In the same
  run `install` succeeded for all three archives.
* The **standalone `consumer` package compiled and installed only — it was not
  run.** That log's `consumer package success` is the outer build step
  succeeding, not a consumer program executing: at that revision the nested
  step still chose `install` over `run` through the old `query.isNative()`
  predicate, which is false for `-Dtarget=wasm32-wasi` on this host. **No Zig
  consumer runtime has been proved on `wasm32-wasi`.** The source has since
  switched that decision to the resolved-target predicate and forwards
  `-fwasmtime` to the nested build, but no run has observed the result, so the
  executed consumer on this target stays **PENDING**.
* The **C++ consumer of the installed S2 archive** is a separate program and it
  really did compile and run on the same provider, printing
  `real S2 C++ consumer: decimal_sign_chunk_boundaries=5 invalid_inputs=2
  two_threads=2 allocation_cycles=128 outstanding_delete=refused
  final_delete=reclaimed`
  (`local://foundation-portability-s2-wasi-installed-cpp-proof.json`). That is
  the observed execution evidence for the installed library; it is never
  inferred from the outer consumer step.
* **Undefined behaviour still traps.** With `-fsanitize-c=trap` a mixed C++
  nonnull-return violation reached `cpp_nonnull` and the process died with a
  real Wasm `unreachable` trap, **exit 134**
  (`local://foundation-portability-wasi-ubsan-sdk-closure-proof.json`). That is
  the intended behaviour of a trap sanitizer, and it is why the provider
  selects `.trap` rather than Zig 0.16's `ubsan` runtime — whose Wasm
  `nonnull_return_v1` signature the runtime does not match. The trap is kept;
  the runtime that could not trap correctly is not.
* **Not yet green: the smoke program.** In that same run `zig build smoke` for
  `wasm32-wasi` **failed**, exit 134, with
  `panic: integer does not fit in destination type` at
  `Io.Threaded.fileWritePositional` through `Io.Writer.flush` and
  `smoke.main` (`local://foundation-portability-s2-wasi-corrected-sdk-gates.log`).
  That is an observed failure of the current tree and is recorded as one. It
  was **not** worked around by changing how `smoke.zig` writes: stdout is
  unchanged, no `Writer` buffering trick was introduced, and no TLS/errno
  workaround was added. Until the driver re-runs the target, **no full
  `wasm32-wasi` green claim is made**: the tests and the install passed, the
  smoke did not, and the consumer compiled and installed without being run. That
  split is the honest summary.

### `aarch64-macos-none`

The Apple failure is a **declared dependency, still without a provider here**.
Every bundled C++ module on a Darwin target now links the real
`CoreFoundation` framework, which is what CCTZ's Apple default-timezone
implementation (`absl/time/internal/cctz/src/time_zone_lookup.cc:22-23`) uses;
before that, the framework was used and never declared. Declaring it is not
obtaining it: **no Mac and no licensed Apple SDK are available on this Linux
host**, no macOS SDK was downloaded or used, and no macOS cell has been run
after the declaration. This stays an explicit platform boundary with no fake
macOS proof, and no CoreFoundation header, type or prototype was fabricated.

Upstream's own recorded runtime issue on Apple M1 — "On Apple M1,
`s2loop_measures_test` fails due to a 6% excess accumlated error" — is numerical
and unrelated to either of the above; `check` runs nothing, so it could not
observe that either way.

## Using it

### As a path dependency

```zig
// build.zig.zon
.dependencies = .{
    .s2geometry = .{ .path = "../s2geometry" },
},
```

```zig
// build.zig
const dep = b.dependency("s2geometry", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("s2geometry", dep.module("s2geometry"));
```

**On native that is the whole integration.** The module carries `link_libc`,
`link_libcpp` and the link against `libs2bridge.a` itself, so a dependent states
nothing about the bridge, the C++ archive or Abseil. `consumer/` is exactly this
and nothing more — it writes no include path, links no library, and is the
proof that the wiring works from outside the package that defines it.

### On `wasm32-wasi`, three more things and nothing else

The facade module is still the only import, and no C header, no C++ header, no
`.a` file and no `-I`/`-L` is re-declared by a dependent. Three properties of the
provider simply do not survive a module import, because Zig's build system
keeps them elsewhere, and `consumer/build.zig` is the working reference:

1. **Forward the real option to the dependency**, or the library silently builds
   a different thing than your executable does:

   ```zig
   const wasi_sysroot = b.option([]const u8, "wasi-sysroot",
       "Complete WASI SDK 34+ WASIp1-threads EH sysroot");
   const dep = if (wasi_sysroot) |root|
       b.dependency("s2geometry", .{
           .target = target,
           .optimize = optimize,
           .@"wasi-sysroot" = root,
       })
   else
       b.dependency("s2geometry", .{ .target = target, .optimize = optimize });
   ```

2. **Take the threading model from the module you actually link**, rather than
   restating a `true`/`false` of your own. `Module.single_threaded` is a plain
   field, so it is not propagated by an import; on every other target the
   library module leaves it null and so does yours:

   ```zig
   const s2_module = dep.module("s2geometry");
   const exe_mod = b.createModule(.{
       .root_source_file = b.path("src/main.zig"),
       .target = s2_module.resolved_target,
       .optimize = optimize,
   });
   exe_mod.single_threaded = s2_module.single_threaded;
   exe_mod.addImport("s2geometry", s2_module);
   ```

   This is not tidiness. Zig 0.16's `std.c` `errno` on `.wasi` is not the SDK's
   `__errno_location()`: `lib/std/c.zig` selects a private thread-local, so a
   module left at the `wasm32-wasi` single-threaded default ends up with a
   **second, unrelated** errno. Measured, before the fix: the C side wrote
   `errno = 28` at address `0x1000000` while the Zig side read `0` at address
   `0x0` on a call the SDK had reported as successful — run exit 86
   (`local://foundation-portability-wasi-sdk-errno-single-proof.json`).
   Matching the SDK libc's threading model is therefore an **ABI requirement**,
   not a preference, and it is why every module this graph builds for that
   target is `single_threaded = false`.

3. **Copy the final-link provider fields off the artifact that already has
   them.** `std.Build` holds these on `Step.Compile`, not on `Module`, so a
   module import never carries them:

   ```zig
   if (target.result.os.tag == .wasi) {
       const bridge = dep.artifact("s2bridge");
       exe.setLibCFile(bridge.libc_file);
       exe.import_memory = bridge.import_memory;
       exe.export_memory = bridge.export_memory;
       exe.shared_memory = bridge.shared_memory;
       exe.max_memory = bridge.max_memory;
   }
   ```

   `libc_file` is what selects the SDK's `include/wasm32-wasip1-threads` and
   `lib/wasm32-wasip1-threads`; the four memory fields are the documented
   shared-imported-memory ABI WASIp1 threads requires — a thread spawn
   instantiates the module again and must reach the **same** linear memory, so
   the module imports it, exports it, declares it shared, and caps it at 256 MiB.
   `s2bridge` is the artifact that already holds them, so reading them from
   there is what keeps a dependent from restating a path or a size that could
   drift.

`getpid` and the signal emulation are **advertised only as the SDK's own
documented emulation**, never as native POSIX behaviour. `getpid` is linked
solely because Zig 0.16's libc-linked nonsecure RNG fallback references it:
without the SDK archive, the runtime refused the module with `unknown import:
env::getpid has not been defined`
(`local://foundation-portability-wasi-ubsan-trap-runtime-proof.json`). It
returns the SDK's emulated identifier. It is **not** a host PID, and this
package offers no independent process namespace on WASI.

Running it also needs the same patched standard library and the same runtime as
the library itself: `--zig-lib-dir <dir>` and a Wasmtime with threads and
exceptions enabled. `zig build consumer` forwards `--zig-lib-dir`, `-Dwasi-sysroot`,
`-fwasmtime` and the other executor switches to the nested build from the
compiler this build resolved, so one command and its sub-build agree.

### A first program

```zig
const std = @import("std");
const s2 = @import("s2geometry");

pub fn main() !void {
    // The leaf cell containing a coordinate, straight from upstream's codec.
    const sydney = s2.LatLng.fromDegrees(-33.8688, 151.2093);
    const cell = try s2.CellId.fromLatLng(sydney);

    // A token is at most 16 characters plus a NUL, and the buffer you pass has
    // to be longer than the token itself.
    var token_buf: [17]u8 = undefined;
    const token = try cell.toToken(&token_buf);
    std.debug.print("{s}\n", .{token});

    // A real covering: which cells contain that point.
    var cells: [8]s2.CellId = undefined;
    const cap = s2.Cap{ .center = sydney, .radius_deg = 0.0 };
    const covering = try (s2.Coverer{ .min_level = 0, .max_level = 22 }).coveringCap(cap, &cells);
    std.debug.print("{} cells\n", .{covering.len});
}
```

Simpler, and the shape most code wants: iterate a covering into a
caller-owned buffer and then over its filled prefix.

```zig
const coverer = s2.Coverer{ .min_level = 0, .max_level = 12, .max_cells = 64 };
var buf: [64]s2.CellId = undefined;
const n = try coverer.coveringPolygonCount(polygon);
if (n > buf.len) return error.BufferTooSmall;
const cells = try coverer.coveringPolygon(polygon, &buf);
```

## The API

`@import("s2geometry")` gives ten types, **104 public methods**, one error
set, two constants, and the raw C surface. Nothing else is exported, and
nothing is a reimplementation of an upstream algorithm.

The 104 are spread as `CellId` 33, `Polygon` 20, `Loop` 17, `Cell` 8,
`Coverer` 8, `LatLng` 6, `LatLngRect` 6, `Cap` 4, `Point` 2, and `BoundUV`
none — a plain struct of values. They carry 79 *distinct* names, because
`containsPoint`, `isValid`, `deinit`, `area` and `normalize` genuinely recur on
more than one type; 79 is the number of names, not the size of the surface, and
an earlier revision of this file quoted it as the latter. Both figures are
counted from `zig/root.zig`: they say a declaration is written down, not that it
compiles or that its bridge call behaves. `zig build check` is what covers
that, because it attaches `tests.zig` — where every public method is called
with concrete argument types — to every target's step.

### Conventions that hold everywhere

* **Units are in the names.** `_deg` for degrees of latitude, longitude or
  angle; `Steradians` spelled out in the doc; `perimeterRad` for radians;
  `signedArea` for a signed steradian measure; `sizeSt` for a projection-space
  length that is neither an angle nor a distance. Upstream stores radians
  internally (`s2/s2latlng.h:95-96`) and the bridge is the one place the two
  units meet.
* **`raw` is upstream's integer.** `CellId.raw` is exactly the `uint64_t`
  `S2CellId` stores. Nothing in this package reads or writes the face and
  Hilbert-position layout; that is upstream's, and `face()`, `pos()` and
  `level()` ask upstream for it.
* **Values are values.** `Point`, `LatLng`, `BoundUV`, `CellId`, `Cell`, `Cap`
  and `LatLngRect` allocate nothing and own nothing. `Loop` and `Polygon` own
  C++ storage and have a `deinit` that calls the matching C++ free.
* **Input arrays are borrowed.** `Loop.init` and `Polygon.init` read the vertex
  array and keep no reference, because `S2Loop::Init` copies it
  (`s2/s2loop.cc:201-207`). The caller's buffer may go out of scope the moment
  the call returns.
* **Output buffers are borrowed for the duration of the call** and are written
  only inside their own length. A list-returning call is two-pass: pass a zero
  length to learn the required count, or pass a buffer and get
  `error.BufferTooSmall` with the required count reported. See "Two rules that
  the whole surface obeys" below.
* **Threading.** Everything but `Loop` and `Polygon` is shareable. A `Loop` or
  `Polygon` holds mutable C++ state and belongs to one thread at a time; the
  upstream types carry no locking of their own.

### `Error`

A closed set, cut at what the bridge can actually report and what this code
checks:

| Error | Means |
|---|---|
| `InvalidArgument` | a non-finite coordinate, a token or debug string upstream's parser rejects, a level outside the range upstream documents, an argument that must be unit length and is not, a `Coverer` whose options contradict each other, or a caller string buffer too small for a result and its NUL |
| `BufferTooSmall` | a caller buffer too short for a required list length |
| `OutOfMemory` | an upstream C++ allocation failed — a real condition, reported rather than swallowed |
| `Internal` | upstream reported failure through its own status, or the bridge returned a status this module does not recognise. `Polygon.unite` and `Polygon.intersection` produce the first case: they bind upstream's `S2Error`-reporting overloads, and a false result is `Internal` |

The last case matters: an unrecognised non-zero status maps to `Internal`
rather than being read as a pass, so a bridge that grows a status value cannot
silently succeed.

#### Three rules that the whole surface obeys

**A boolean answer is never bare.** Every predicate that answers `true`/`false`
is `Error!bool`, and the bridge never returns the answer in its return value: it
writes `0` or `1` through an `int*` out-parameter and returns a status
separately. That is the only way "the answer is false" can be told apart from
"the call was rejected". `CellId.contains` with an invalid id,
`Cap.containsPoint` and `Polygon.containsPoint` with a vector that is not unit
length, and any call with a null out-parameter all report an error; none of
them may report `false`, and none of them does.

**The count a two-pass call reports is the count it would write.** The counting
pass and the filling pass are one entry point with one bound, so ask
`childrenCount` and `children` writes exactly that many, ask `coveringCapCount`
and `coveringCap` writes exactly that many, and the two can never drift apart.
And **counting must not cost the thing being counted**: `childrenCount` measures
the range in constant time rather than building it, because a face cell at level
30 spans 2⁶⁰ cells — a list no caller can hold and a walk no machine can finish.
That is a property worth stating rather than assuming; the previous
implementation did build the list, and the driver's probe caught it answering
`OutOfMemory` with `count = 0` where a count was owed. A buffer too short is
refused before anything is traversed, and a count the platform cannot represent
is `InvalidArgument` rather than a wrapped number. A `Coverer` `…Count` call
really does run the coverer, which is the documented cost of sizing exactly
instead of over-allocating.

**An out-of-range index is an error you return, not a panic you raise.** The
bridge checks every index against `numVertices` with an ordinary comparison —
but these methods take the index as a `usize`, and the bridge's own parameter
is a C `int`, so the value has to be narrowed on the way across. A caller who
passed `maxInt(usize)` to `Loop.vertex` got `thread … panic: integer does not
fit in destination type` at `zig/root.zig:956` and their process died; the right
answer is `error.InvalidArgument`, because the index is out of range whatever
the width of the type it arrived in. Five methods take a `usize` index and are
in scope — `Loop.vertex`, `Loop.vertexLatLng`, `Polygon.loopNumVertices`,
`Polygon.loopVertex`, `Polygon.loopVertexLatLng` — and all five now go through
one private helper that returns `error.InvalidArgument` above `maxInt(c_int)`.
`Cell.vertex` takes a `u8` and cannot overflow a C `int`, so it was never
affected. No signature changed. Treat an index parameter as
`InvalidArgument`-bounded; the guard has so far only been exercised against the
already-installed native archive, so the first full recompile is still the
confirmation.

### The types and every method on them

#### `Point` — a unit-sphere direction, `x`, `y`, `z`

| Method | Upstream | Notes |
|---|---|---|
| `normalized(self) Error!Point` | `S2Point::Normalize` (`s2/s2point.h:157`) | the way to get a vector the `containsPoint` methods will accept |
| `toLatLng(self) Error!LatLng` | `S2LatLng(const S2Point&)` (`s2/s2latlng.h:64-65`) | |

#### `LatLng` — `lat_deg`, `lng_deg`

| Method | Upstream | Notes |
|---|---|---|
| `fromDegrees(lat_deg, lng_deg) LatLng` | `S2LatLng::FromDegrees` | total: it cannot fail, because upstream's constructor cannot either |
| `fromRadians(lat_rad, lng_rad) LatLng` | `S2LatLng::FromRadians` | the only place the facade converts *into* degrees |
| `isValid(self) bool` | `S2LatLng::is_valid` | latitude in ±90, longitude in ±180, both inclusive |
| `normalized(self) Error!LatLng` | `S2LatLng::Normalized` | clamps latitude to ±90 and wraps longitude into [-180, 180]; a non-finite input is `InvalidArgument` |
| `toPoint(self) Error!Point` | `S2LatLng::ToPoint` | requires finite coordinates |
| `distanceDeg(self, other) Error!f64` | `S2LatLng::GetDistance` | **degrees**, along the surface. Both points must already be normalized — that is upstream's precondition, and the name says which unit a tolerance must be written in |

#### `CellId` — `raw: u64`

Two constants: `CellId.none` (upstream's `S2CellId::None()`, id 0) and
`CellId.sentinel` (upstream's `S2CellId::Sentinel()`).

| Method | Upstream | Bounds and errors |
|---|---|---|
| `fromLatLng(point) Error!CellId` | `S2CellId(const S2LatLng&)` | |
| `fromPoint(point) Error!CellId` | `S2CellId(const S2Point&)` | the vector need not be unit length |
| `fromFace(face_index: u8) Error!CellId` | `S2CellId::FromFace` | 0..7; 6 and 7 produce an *invalid* id, which is what upstream's own tests use them for |
| `fromFacePosLevel(face_index, hilbert_pos, target_level) Error!CellId` | `S2CellId::FromFacePosLevel` | `hilbert_pos` is masked to `kPosBits` upstream, so the facade rejects a wider one rather than let the caller believe it chose the cell it asked for |
| `fromFaceIJ(face_index, i, j) Error!CellId` | `S2CellId::FromFaceIJ` | `face_index` 0..5; `i` and `j` each 0..2³⁰−1 |
| `fromToken(token: []const u8) Error!CellId` | `S2CellId::FromToken` | a token upstream rejects is `InvalidArgument`, **not** id 0: upstream answers `S2CellId::None()` and a caller must not have to tell that apart from a real cell |
| `fromDebugString(text: []const u8) Error!CellId` | `S2CellId::FromDebugString` | the `"face/childpos…"` spelling; rejected for the same reason a bad token is |
| `toToken(self, buf: []u8) Error![]const u8` | `S2CellId::ToToken` | at most 16 characters plus a NUL; `buf` must be `len > needed`, or `BufferTooSmall` |
| `toDebugString(self, buf: []u8) Error![]const u8` | `S2CellId::ToString` | same contract |
| `isValid(self) bool` | `S2CellId::is_valid` | total |
| `level(self) Error!u8` | `S2CellId::level` | 0..30; an id that is not valid is `InvalidArgument` because upstream computes the level from the lowest set bit and has no defined answer for id 0 |
| `face(self) Error!u8` | `S2CellId::face` | 0..5 |
| `pos(self) Error!u64` | `S2CellId::pos` | the position along the face's Hilbert curve |
| `isLeaf(self) bool`, `isFace(self) bool` | | total |
| `parent(self, target_level: ?u8) Error!CellId` | `S2CellId::parent(int)` | `null` means upstream's zero-argument `parent()`, which is `level()-1` and is therefore `InvalidArgument` on a level-0 cell; an explicit level must be ≤ this cell's own level |
| `child(self, position: u8) Error!CellId` | `S2CellId::child(int)` | `position` 0..3 and the cell must not be a leaf |
| `children(self, target_level: u8, out: []CellId) Error![]CellId` | `child_begin(level)`…`child_end(level)` | two-pass; returns the filled prefix of `out` |
| `childrenCount(self, target_level: u8) Error!usize` | | how many `children` produces |
| `next(self)`, `prev(self) Error!CellId` | `S2CellId::next`, `::prev` | |
| `contains(self, other) Error!bool` | `S2CellId::contains` | both ids must be valid |
| `intersects(self, other) Error!bool` | `S2CellId::intersects` | both ids must be valid |
| `range(self) Error![2]CellId` | `range_min` / `range_max` | the inclusive pair `contains` is *defined* by, in its primitive form |
| `edgeNeighbors(self) Error![4]CellId` | `S2CellId::GetEdgeNeighbors` | always four **distinct** cells, in the order that method defines; allocates nothing |
| `vertexNeighbors(self, target_level: u8, out: []CellId) Error![]CellId` | `S2CellId::AppendVertexNeighbors` | three or four results, because a cell whose nearest vertex is one of the eight cube vertices has only three; `target_level` must be **strictly below** this cell's own level |
| `vertexNeighborsCount(self, target_level) Error!usize` | | |
| `allNeighbors(self, target_level: u8, out: []CellId) Error![]CellId` | `S2CellId::AppendAllNeighbors` | `target_level` is this cell's own level **.. 30 inclusive** — 30 is the top of the range, not one past it, because `GetSizeIJ(30)` is 1. Eight results normally; a cell adjacent to a face vertex repeats one, and this reports the multiset upstream produced rather than deduplicating it |
| `allNeighborsCount(self, target_level) Error!usize` | | |
| `toLatLng(self) Error!LatLng` | `S2CellId::ToLatLng` | the cell centre |
| `toPoint(self) Error!Point` | `S2CellId::ToPoint` | |
| `sizeSt(self) Error!f64` | `S2CellId::GetSizeST` | edge length in (s,t) projection space — not an angle, not a distance on the sphere |
| `boundUV(self) Error!BoundUV` | `S2CellId::IJLevelToBoundUV` | |

#### `Cell` — the two-dimensional region sense of a cell

`Cell.init(id: CellId) Cell`.

| Method | Upstream | Notes |
|---|---|---|
| `approxArea(self) Error!f64` | `S2Cell::ApproxArea` | steradians; upstream bounds the error at 3%, and 0.1% at level 5 and finer |
| `exactArea(self) Error!f64` | `S2Cell::ExactArea` | steradians, accurate to six digits even for a leaf cell |
| `averageAreaAtLevel(level: u8) Error!f64` | `S2Cell::AverageArea` | the mean area of all cells at that level; 0..30 |
| `center(self) Error!Point` | `S2Cell::GetCenter` | the point at which the cell divides into four children |
| `vertex(self, k: u8) Error!Point` | `S2Cell::GetVertex` | `k` 0..3, counter-clockwise from the lower-left corner of the (u,v) square |
| `boundUV(self) Error!BoundUV` | `S2Cell::GetBoundUV` | |
| `containsPoint(self, point) Error!bool` | `S2Cell::Contains(const S2Point&)` | |

#### `Cap` — `center: LatLng`, `radius_deg: f64`

| Method | Upstream | Notes |
|---|---|---|
| `area(self) Error!f64` | `S2Cap::GetArea` | steradians, `2*pi*height` |
| `height(self) Error!f64` | `S2Cap::height` | a multiple of the sphere radius |
| `complement(self) Error!Cap` | `S2Cap::Complement` | the complement of a full cap is the empty cap and vice versa, so the result's radius is 180 for an empty cap and 0 for a full one |
| `containsPoint(self, point) Error!bool` | `S2Cap::Contains(const S2Point&)` | **upstream requires a unit-length vector and debug-asserts it.** Anything not within upstream's own `5 * DBL_EPSILON` tolerance of unit length is `InvalidArgument` rather than a value computed from an input upstream never defined |

A `Cap` is a plain struct literal: `.{ .center = …, .radius_deg = … }`. Its
constructor takes an `S1Angle` and clamps at 180 degrees, so a larger radius is
a full cap, not an error — that is upstream's choice and the bridge passes it
through unchanged.

#### `LatLngRect` — `lat_lo_deg`, `lng_lo_deg`, `lat_hi_deg`, `lng_hi_deg`

`lng_lo_deg > lng_hi_deg` is a **legal** rectangle that crosses the 180 degree
line, not an error, and `isInverted` reports exactly that condition.

| Method | Upstream | Notes |
|---|---|---|
| `fromBounds(…) LatLngRect` | | total; a struct literal is equally fine |
| `area(self) Error!f64` | `S2LatLngRect::Area` | steradians on the unit sphere |
| `containsLatLng(self, point) Error!bool` | `S2LatLngRect::Contains` | |
| `polarClosure(self) Error!LatLngRect` | `S2LatLngRect::PolarClosure` | the smallest rectangle with the same interior: a rectangle touching a pole widens to every longitude; one touching no pole comes back unchanged |
| `isInverted(self) Error!bool` | `S2LatLngRect::is_inverted` | |
| `isValid(self) Error!bool` | `S2LatLngRect::is_valid` | |

#### `Loop` — an owned, opaque `S2Loop`

The interior is the region on the **left** of the vertex chain, and
containment is defined so that every point of the sphere belongs to exactly one
face — which is why a loop does not necessarily contain its own vertices.

**Every constructor that takes vertices checks its arguments before any of
them reaches upstream, and that is not the same check as `isValid`.** `init`
and `Polygon.init` and `Polygon.initLoops` require every vertex to be a
unit-length direction —
upstream's own tolerance, `|‖v‖² − 1| ≤ 5 · DBL_EPSILON` — and require the vertex
count to be one upstream can be told about at all (`≤ INT_MAX`, and small
enough that no `+ 3·i` walk can wrap). `initLoops` additionally requires each
loop's length to be at least 3 and sums them with an explicit carry check.
All of that is `InvalidArgument`.

`isValid` asks a different question and is asked *after* the object exists:
upstream's `S2Loop::IsValid` / `S2Polygon::IsValid` answer whether the
topology is sound — no self-intersection, no repeated vertex, no interior on
the wrong side. A loop of perfectly unit-length vertices that crosses itself
is therefore **accepted by the constructor and reported invalid by `isValid`**,
which is the only way to say so, because upstream's own validator "happens too
late in debug mode, since `S2Loop` construction calls `s2pred::Sign` which
expects vertices to be unit length" (`src/s2/s2loop.cc:225-230`). A
non-unit-length vertex is not a malformed loop to be reported later; it is an
argument upstream never accepts, and the process would die inside the exact
predicate before any validator could speak.

| Method | Upstream | Notes |
|---|---|---|
| `init(vertices: []const [3]f64) Error!Loop` | `S2Loop::Init` | at least 3 vertices; `vertices` is **borrowed** and copied by upstream |
| `empty() Error!Loop` | `S2Loop::kEmpty` | no edges, contains nothing |
| `full() Error!Loop` | `S2Loop::kFull` | no edges, contains everything |
| `deinit(self: *Loop) void` | `s2br_loop_destroy` | releases the C++ storage; safe after a failed `init` (the bridge accepts a null handle) and not idempotent afterwards, so call it exactly once |
| `numVertices(self) Error!usize` | `S2Loop::num_vertices` | |
| `vertex(self, i: usize) Error!Point` | `S2Loop::vertex(int)` | `i < numVertices()`, else `InvalidArgument` |
| `vertexLatLng(self, i: usize) Error!LatLng` | `S2LatLng(const S2Point&)` | |
| `area(self) Error!f64` | `S2Loop::GetArea` | steradians, 0..4π. **Unsigned**: whether the loop is a shell or a hole is not part of the answer |
| `signedArea(self) Error!f64` | `S2::GetSignedArea` | steradians, negative when the interior is more than half the sphere. Use this when the sign is what matters |
| `perimeterRad(self) Error!f64` | `S2::GetPerimeter` | **radians** |
| `containsPoint(self, point) Error!bool` | `S2Loop::Contains` | |
| `isNormalized(self) Error!bool` | `S2Loop::IsNormalized` | whether the enclosed area is at most 2π |
| `normalize(self: *Loop) Error!void` | `S2Loop::Normalize` | inverts if necessary; **mutates** |
| `invert(self: *Loop) Error!void` | `S2Loop::Invert` | **mutates** |
| `isEmpty(self) Error!bool`, `isFull(self) Error!bool` | | |
| `isValid(self) Error!bool` | `S2Loop::IsValid` | every loop precondition, including no self-intersection and no repeated vertex |

**Orientation is the caller's, always.** Neither `init` nor `initLoops` calls
`Normalize`, and no constructor in this package reverses a vertex order. That
is deliberate: `S2Polygon::Init` hands the loop it is given straight through
(`s2/s2polygon.cc:406-414`) and `S2::GetArea` maps a negative signed area to
`area + 4π` (`s2/s2loop_measures.cc:51-55`), so a clockwise list is measured as
the whole sphere minus your shape. If you want a shell, pass the vertices
counter-clockwise seen from outside; if you want a hole, pass them the other
way and let `Polygon` work out the nesting. `Loop.normalize` exists for the
case where you really do want the smaller of the two.

#### `Polygon` — an owned, opaque `S2Polygon`

A set of nested loops whose interior is the points contained by an odd number
of them.

| Method | Upstream | Notes |
|---|---|---|
| `init(vertices: []const [3]f64) Error!Polygon` | `S2Polygon::Init` | one shell; at least 3 vertices; `vertices` is **borrowed** |
| `initLoops(vertices: []const [3]f64, loop_sizes: []const usize) Error!Polygon` | `S2Polygon::InitNested` | every loop back to back in `vertices`, their lengths in `loop_sizes`; the two lengths must agree, or `InvalidArgument`. The caller says nothing about which loops are shells and which are holes: upstream works that out from the nesting depth and reorders into the traversal order `loopVertex` reports |
| `empty() Error!Polygon` | default-constructed `S2Polygon` | `numLoops() == 0` |
| `full() Error!Polygon` | `S2Polygon::MakeFull` | the whole sphere |
| `deinit(self: *Polygon) void` | `s2br_polygon_destroy` | as `Loop.deinit` |
| `numLoops(self) Error!usize` | `S2Polygon::num_loops` | |
| `numVertices(self) Error!usize` | `S2Polygon::num_vertices` | the total over all loops |
| `loopNumVertices(self, loop_index) Error!usize` | `S2Polygon::loop(k)->num_vertices` | |
| `loopVertex(self, loop_index, vertex_index) Error!Point` | `S2Polygon::loop(k)->vertex(i)` | loop index is upstream's traversal order, not the order you passed |
| `loopVertexLatLng(self, loop_index, vertex_index) Error!LatLng` | | |
| `area(self) Error!f64` | `S2Polygon::GetArea` | steradians, 0..4π, holes already subtracted |
| `containsPoint(self, point) Error!bool` | `S2Polygon::Contains(const S2Point&)` | same unit-length requirement as `Cap.containsPoint` |
| `containsLatLng(self, point) Error!bool` | `S2Polygon::Contains` over a normalized `S2LatLng` | `S2LatLng::ToPoint` is the conversion upstream defines, and it is what makes the vector unit length for that overload |
| `centroidLatLng(self) Error!LatLng` | `S2Polygon::GetCentroid` | normalized, in degrees |
| `isEmpty(self) Error!bool`, `isFull(self) Error!bool` | | a statement about upstream's internal representation; prefer `area` or `containsPoint` when you mean the geometry |
| `isValid(self) Error!bool` | `S2Polygon::IsValid` | whether the topology is sound. The constructor accepted it anyway — see the note above `Loop.init` |
| `complement(self) Error!Polygon` | `S2Polygon::InitToComplement` | allocates a new handle; `self` is untouched |
| `intersection(a, b) Error!Polygon` | `S2Polygon::InitToIntersection` | static: neither input is modified. Both operands are validated first — `InvalidArgument` if either fails `isValid`. A result upstream itself fails to build is `Internal`, and the handle is released rather than half-returned |
| `unite(a, b) Error!Polygon` | `S2Polygon::InitToUnion` | as `intersection`. The name is `unite`, a keyword in no dialect this package targets, and there is no `union` alias left behind |

Every result that is a new `Polygon` is a new handle **you** must `deinit`.

#### `Coverer` — `S2RegionCoverer::Options`

| Field | Default | Upstream |
|---|---|---|
| `min_level: u8` | 0 | cells below this level are never returned, even if that means more of them |
| `max_level: u8` | `max_level` (30) | cells above this level are never returned |
| `level_mod: u8` | 1 | only levels where `(level - min_level)` is a multiple of this are used |
| `max_cells: u32` | 8 | the desired maximum number of cells; upstream publishes a table of the accuracy this buys |

All eight methods validate these with ordinary comparisons before any native
call, and report the ordinary `error.InvalidArgument` when they contradict:
`min_level ≤ max_level`, `max_level ≤ 30`, `level_mod` in 1..3, `max_cells ≥ 1`,
and `max_cells ≤ maxInt(c_int)` — the last because the bridge carries
`max_cells` as an `int32_t`, and a `u32` above that would trap the conversion
in Debug and ReleaseSafe rather than report anything. Each method holds its
options in a `const` local for exactly the duration of the synchronous call.

| Method | Region | Notes |
|---|---|---|
| `coveringCap(cap, out) Error![]CellId` | `S2Cap` | two-pass |
| `coveringCapCount(cap) Error!usize` | | runs the coverer, keeps nothing |
| `coveringRect(rect, out) Error![]CellId` | `S2LatLngRect` | two-pass |
| `coveringRectCount(rect) Error!usize` | | |
| `coveringPolygon(polygon, out) Error![]CellId` | `S2Polygon` | two-pass |
| `coveringPolygonCount(polygon) Error!usize` | | |
| `coveringCell(cell, out) Error![]CellId` | `S2Cell` | upstream's own covering of a cell is exactly that one cell |
| `coveringCellCount(cell) Error!usize` | | |

A covering is an **approximation and not a partition**, and upstream warns that
the output may change between library versions and must not be relied on for
stability (`s2/s2region_coverer.h:57-63`). `…Count` sizes `out` exactly, at
the cost of running the coverer twice.

#### The raw escape hatch

`pub const c = @import("c")` is the translated `zig/bridge.h`: **93**
`extern "C"` entry points, the `S2BridgeStatus` enumerators, the
`S2BridgeCovererOptions` struct, and the two opaque handle types. It is public
on purpose. Going through it gives upstream behaviour with none of the
guarantees above, which is exactly the trade a caller who needs a call this
facade does not wrap is making.

The full bridge surface, so a reader knows what is available without opening
the header: `CellId` construction and inspection (`fromLatLng`, `fromPoint`,
`fromFace`, `fromFacePosLevel`, `fromFaceIJ`, `fromToken`, `toToken`,
`isValid`, `level`, `face`, `pos`, `fromDebugString`, `toDebugString`,
`isLeaf`, `isFace`, `parent`, `child`, `children`, `next`, `prev`, `contains`,
`intersects`, `range`, `edgeNeighbors`, `vertexNeighbors`, `allNeighbors`,
`toLatLng`, `toPoint`, `sizeSt`, `boundUV`); `LatLng` and `Point` conversions
and `distanceDeg`; `Cell` area, centre, vertex, `boundUV` and
`containsPoint`; `Cap` area, height, complement and `containsPoint`;
`LatLngRect` area, `containsLatLng`, `polarClosure`, `isInverted`, `isValid`;
`Loop` construction, destruction and every accessor plus `normalize` and
`invert`; `Polygon` construction, destruction, loop accessors, `area`,
`containsPoint`, `containsLatLng`, `centroidLatLng`, `complement`,
`intersection` and `union`; the four `coverer_covering_*` entry points; and
`loop_perimeter_rad` and `loop_signed_area`.

### What the facade deliberately does not wrap

Closest-edge, closest-point and closest-cell queries, `S2Builder` and the
whole `s2builderutil` family, the fractal generators, the shape-index
queries, the coded/encoded vector and string types, the terminology
indexers, and the C++ template headers that need a C++ compiler to instantiate.

That is a coverage decision, not a gap in the library: the **whole** upstream
archive (`libs2.a`, all 108 translation units) and **every** upstream header are
installed, so a C++ consumer reaches all of it through
`#include <s2/…>` and `#include <absl/…>` with nothing extra. The facade covers
the primary operations — cell identification, coordinate conversion, cell
geometry and area, loops, polygons and their boolean operations, and region
covering. `FORK-NOTES.md` §5 records the decision and what it cost.

## The escape hatch is not a second API

`pub const c` is the translated bridge, and nothing in this package's own code
depends on a name the bridge does not have. A C++ consumer, by contrast, gets
the upstream headers and the upstream archive directly: the bridge library
forwards both header installations, so linking `libs2bridge.a` gives you
`#include <s2/s2cell_id.h>`, `#include <absl/base/config.h>` and
`#include <s2geometry_bridge.h>` for free.

## Build modes

### The bundled graph (default)

Compiles `libabsl.a`, `libs2.a` and `libs2bridge.a` from this tree, installs
their headers, and registers the public module `s2geometry`. **The S2 and Abseil
libraries are always bundled**: nothing is downloaded at build time and no
installed S2 or Abseil is ever used for them. That statement covers the library
only. The C and C++ *runtime* below it is a separate provider — Zig's own on
non-Darwin targets, an installed SDK's on `wasm32-wasi` and the Darwin targets —
and is described per target under "The `wasm32-wasi` provider, in full".

### `-fsys=s2`: link an installed s2 instead

```sh
zig build test -fsys=s2
zig build smoke -fsys=s2
zig build check -fsys=s2
zig build consumer -fsys=s2
```

`-fsys=` / `-fno-sys=` feed `b.systemIntegrationOption`, which is not an entry
in the `-D` map; that is why the option is spelled this way and why
`consumer/` receives `-fsys=s2` (or `-fno-sys=s2`) as a forwarded argument
rather than as `-Dsystem=…`.

The mode offers the same five entry points as the bundled graph — `install`,
`test`, `smoke`, `check` and `consumer` — against the installed library and its
installed headers. It links `-ls2` and the 26 `absl_*` libraries upstream's
`s2` links, spelled as installed library names. Two things follow from that, and
both are deliberate:

* The bridge is **still compiled from this repository**. An installed upstream
  library exports no fork-only symbol, so a system-mode bridge built against
  upstream sources would be a bridge to nothing.
* `zig/bridge.h` is translated **without** this repository's `src/` and
  `vendor/abseil-cpp` on the translation line. Translating the bundled v0.14.0
  header against an installed library of unknown version would describe an ABI
  that may not be the one on disk, which is the failure a system mode exists to
  avoid. `zig/bridge.cc` therefore reaches `<s2/…>` and `<absl/…>` through the
  target's own system include path, next to the installed libraries it links
  with.

What the mode cannot offer is the six-target matrix: the library and the headers
it binds to are installed for this machine, so `check` compiles the selected
target and reports on that, and a cross `-Dtarget` compiles without running.

**This mode has not been exercised in this workspace. No installed `libs2` or
Abseil was observed, the set of libraries actually available on a given machine
is unknown, and no result is claimed for any of the four commands above.** The
CI workflow deliberately has no `-fsys=s2` job for the same reason: a stock
runner has neither an installed `libs2` nor an Abseil, and this repository
cannot name an install package for them without guessing. A claim about this
mode needs a machine that has them.

### The `wasm32-wasi` provider, in full

This is a build mode like `-fsys=s2` in that it changes which C/C++ provider the
same 261 source units bind to, but unlike `-fsys=s2` it is **not** optional and
it is **not** a system library lookup: the sysroot is an explicit installed
tree, and nothing is fetched, shimmed or narrowed to make the target work.

**What `-Dwasi-sysroot=<path>` must point at.** A complete WASI SDK 34 sysroot
with the **WASIp1-threads** ABI selected, carrying *matching* C++ headers and
archives:

| Path inside the sysroot | Used for |
|---|---|
| `include/wasm32-wasip1-threads` | libc headers, and `crt1.o`/crt objects in the sibling `lib/` |
| `include/wasm32-wasip1-threads/eh/c++/v1` | the EH libc++ headers |
| `include/c++/v1` | the common libc++ headers |
| `lib/wasm32-wasip1-threads/eh/libc++.a`, `libc++abi.a`, `libunwind.a` | the ABI-2 libc++ / libc++abi / unwinder archives |
| `lib/wasm32-wasip1-threads/libwasi-emulated-signal.a` | the SDK's documented signal emulation |
| `lib/wasm32-wasip1-threads/libwasi-emulated-getpid.a` | the SDK's documented identifier emulation |

Headers and archives must come from **one** sysroot. The C++ runtime is the
SDK's own, linked by object file rather than through Zig's `link_libcpp`, so
Zig's bundled libc++ is never mixed in (`link_libcpp = false` on every WASI
module, `-nostdinc++`, `-fwasm-exceptions` with
`-mllvm -wasm-use-legacy-eh=false`). The three libc++ archives are added
exactly once, on the facade module, so no other unit can pull in a second copy.

**Why the threading model is an ABI requirement.** Zig 0.16's `std.c` `errno`
on `.wasi` is not the SDK's `__errno_location()`; `lib/std/c.zig` selects
`private.errnoFromThreadLocal`, returning the address of
`extern threadlocal var errno`. A module left at the `wasm32-wasi`
single-threaded default therefore compiles that storage somewhere other than
the SDK's shared-memory TLS, and one binary ends up with two errnos. A null
`Module.single_threaded` emits no flag at all
(`lib/std/Build/Module.zig:546`, `addFlag` returns on null), which is why one
function — `wasi_provider.Provider.configureModule` — sets
`single_threaded = false` on **every** module the provider configures: the
three C++ libraries, the bridge, the translated header, the facade, the tests
and the smoke root. See "On `wasm32-wasi`, three more things and nothing else"
above for the measurement this came from.

**The patched standard library copy, and how to reproduce it.** Stock Zig
0.16.0 does not compile this configuration. A threaded, libc-linked
`wasm32-wasi` build fails twice against stock, and both failures are recorded
at `local://foundation-portability-wasi-sdk-errno-multi-compile-failure.json`,
exit 1:

* `lib/std/Io/Threaded.zig:959:50: error: expected type 'i64', found 'u64'` —
  the wasm `memory.atomic.wait32` timeout assigns a `u64` nanosecond count
  straight into an `i64`, and any negative value there means "wait
  indefinitely";
* `lib/std/heap.zig:16:74: error: unimplemented` —
  `WasmAllocator` is `@compileError("unimplemented")` for
  `!builtin.single_threaded`, so selecting it as `page_allocator` is a hard
  compile failure, not a weaker allocator.

`build_support/wasi_stdlib.patch` is the whole fix, in two hunks, and it
touches only those two upstream files:

1. `std/Io/Threaded.zig`: a finite `timeout_ns` is saturated to
   `maxInt(i64)` before conversion, so a finite timeout can never wrap into a
   negative — that is, indefinite — wait, and `@intCast` cannot trap on an
   absurd duration. `null` still means "no timeout" and is still `-1`. Only the
   wasm branch of `Thread.futexWaitInner` changes; the parking-futex branch and
   every native OS branch are byte-identical to stock.
2. `std/heap.zig`: `page_allocator` selects the real `c_allocator` for
   `cpu.arch.isWasm() and os.tag == .wasi and link_libc and
   !single_threaded`, instead of instantiating `WasmAllocator`. `c_allocator`
   is stock Zig code over the SDK's own thread-safe
   malloc/realloc/free — Zig's `have_posix_memalign` is false for `.wasi`, so
   on this target it applies its manual alignment strategy over that same real
   allocator — and it already satisfies the whole `Allocator` contract
   including arbitrary alignment and `OutOfMemory`. Emscripten and every other
   non-`.wasi` wasm OS keep the upstream selection below the new branch even
   when threaded and libc-linked, so the "unimplemented" diagnostic still
   honestly reports the genuinely unsupported threaded non-libc case, and
   `WasmAllocator` is a lazy declaration this path never analyses. No native
   `PageAllocator` path changes, and the `root.os.heap.page_allocator`
   override still takes precedence.

Reproduce the copy exactly, from a complete `<zig>/lib` root. `ZIG_ROOT` is a
**directory** holding the real pinned 0.16.0 `zig` binary beside its `lib/`;
it is deliberately not the same variable name as the compiler binary, which in
this workspace is normally the absolute path of the executable itself:

```sh
ZIG_ROOT=/path/to/zig-0.16.0-install   # the DIRECTORY, containing zig and lib/
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

`cp -a` copies the whole `lib` tree, so `$STDLIB_COPY/lib/std/Io/Threaded.zig`
and `$STDLIB_COPY/lib/std/heap.zig` exist before the patch runs; the copy is
never taken from the stock installation in place, and the stock installation is
never written to. `patch -p1` skips the plaintext prologue above the first
`--- a/std/heap.zig` hunk — that prose is documentation for a reader, not patch
input. Either `git apply -p1` or `patch -p1` accepts the file; both apply
exactly the two hunks and touch no other standard-library file.

There is no build-time download, no shim, no global tool edit, no `errno` or
`stdout` workaround, and **no additional custom standard-library option**:
`--zig-lib-dir` is the compiler's existing standard option, used as-is.
`-Dwasi-sysroot` is this package's own SDK-provider option, separate in kind.
The observed provider copy `providers/zig-wasi-stdlib/lib` is exactly this tree.

**One honest allocation backend, not a file-mapping emulation.** Abseil's
`LowLevelAlloc` normally gets its backing regions from `mmap`, which WASI does
not have. Under `#ifdef __wasi__` the two vendored files instead take them from
the SDK libc:

* the region is allocated with `posix_memalign(&new_pages, arena->pagesize,
  new_pages_size)` **while the arena spinlock is released**, and published into
  the arena's free list after it is retaken — so the SDK allocator is never
  re-entered from inside an Abseil lock;
* each region's header carries a `region_base` pointer, stored in the header's
  existing alignment slot so no per-client cost is added. A split copies it to
  the remainder, and `Coalesce` merges only when `a->header.region_base ==
  n->header.region_base`. **Coalescing can never cross two backing
  allocations**, because a merge that did would hand `free()` a pointer it
  never allocated. `Next()` asserts the same invariant with an ordinary
  comparison, and `ABSL_RAW_CHECK`s fire on the failure instead of a corrupt
  free;
* `DeleteArena` releases each region with `std::free(region)` and first asserts
  `region->header.region_base == region`, i.e. that the arena is back to
  exactly its original allocation. The existing
  `arena->allocation_count != 0` refusal to delete a non-empty arena is
  unchanged, and the native header layout and native code are untouched
  outside those guards.

No asynchronous-signal-safety is claimed: upstream already records
`ABSL_LOW_LEVEL_ALLOC_ASYNC_SIGNAL_SAFE_MISSING` as unsupported for WebAssembly,
and this change does not alter that. No performance claim is made either.

## Examples

* `smoke.zig` — the runnable, deterministic demonstration. No input, no clock,
  no random seed, no host dependency, so the same lines come out every time.
  Every printed number is an **expected** answer rather than a value the
  program produced and then called correct: cell ids, tokens and neighbour sets
  are the ones google/s2geometry and golang/geo publish for those inputs, and
  the areas are exact values of spherical geometry printed with enough digits to
  see the identity hold. A mismatch prints both sides and exits non-zero, so
  this is a check and not a demo. Its seven sections are the six face roots, the
  published golang/geo token table, the projection origin, the neighbour
  identities, the octant triangle, the polygon boolean on two overlapping
  wedges, and a real covering of a Sydney coordinate.
* `consumer/src/main.zig` — the same facade reached from a **separate package**
  that depends on this one by path and writes no include path and links no
  library.
* `tests.zig` — 46 behavioural tests, which double as the worked examples for
  every method, because between them they call all of them. Seven of the 46 are
  permanent regressions for defects that probes found rather than for the
  library's own behaviour; the other 39 are published answers and identities.

## Testing approach

Every expected value is either an **independent published answer** or a
**geometric identity**. Nothing calls the library and then declares its own
output correct; nothing pins a version string, an export, a default, a
forwarding path or a copy.

The fixtures under `testdata/` are values some other implementation published:
32 token/id pairs and five malformed tokens from golang/geo's
`TestCellIDTokensNominal` and `TestCellIDFromTokensErrorCases`; 14 leaf-cell
id ↔ lat/lng pairs from golang/geo's `TestCellIDLatLng`; 17 neighbour,
containment and parent/child rows from `src/s2/s2cell_id_test.cc`,
`src/python/s2geometry_test.py` and golang/geo; the 42-cell level-22 covering
that `src/s2/s2region_coverer_test.cc`'s `JavaCcConsistency` test publishes for
a polyline through two real Sydney coordinates; four `PolarClosure` answers; and
nine normalization plus ten validity answers. Every row carries its source file
and line in the fixture's own header. golang/geo is an independent
reimplementation of the same codec, which is what makes it an oracle rather
than a restatement.

Where no number is published, the tests hold the implementation to identities
that follow from geometry rather than from a measurement: the six cube faces
tile the sphere so their exact areas sum to 4π; four children tile their
parent; the octant through the three positive axes has solid angle exactly π/2
and perimeter exactly 3π/2; a spherical polygon's area is the excess of its
interior angles over (n−2)π, which fixes the π/2, π/4 and 3π/4 that two
overlapping wedges are held to.

Round trips are used only as supplements, and never as the only evidence for
something: `toToken(fromToken(x)) == x` proves the codec agrees with itself,
which is a different and much weaker claim.

## Verification status

Every row is a gate the **driver** ran, with its receipt and its exit code.
This fork's own role runs no gate. The per-target matrix is in "The six targets"
above.

### Current

**The whole-tree gates over this repair wave have not been re-run. They are
PENDING, not green.** What follows separates the two honestly: the rows marked
`OBSERVED` were actually executed, against the source named in the row; the
rows marked `PENDING` have a landed change and no gate behind it yet. Nothing in
this table is inferred from an earlier green run of a different tree.

| Gate | State | Result / what still has to run |
|---|---|---|
| Native Debug `test smoke install` | **PENDING** | The last observed run is pre-wave: **46/46**, 17/17 steps, `local://foundation-cross-test-final-s2geometry-native-Debug.log`. Must be re-run on this source. |
| Native ReleaseSafe `test smoke` | **PENDING** | Same: the pre-wave receipt records 46/46, 13/13, no install in that command. |
| Source consumer (native) | **PENDING** | The pre-wave receipt records 10/10 through the `.path = ".."` dependency. |
| Six-target `check` | **PENDING** | All six, with the WASI cell given its two providers. See [The six targets](#the-six-targets). |
| Full 53-platform Zig API matrix | **PENDING** | The last observed composite was 20 pass / 14 fail / 19 build-only and predates this source. |
| `zig build consumer`, `-Dtarget=wasm32-wasi` | **OBSERVED — INSTALL ONLY** | The nested build **compiled and installed** the consumer; it was **not run**. `consumer package success` in `local://foundation-portability-s2-wasi-corrected-sdk-gates.log` is the outer step succeeding, and at that revision the nested step still chose `install` because the old `query.isNative()` predicate is false for `-Dtarget=wasm32-wasi`. No executed Zig consumer on this target; the corrected predicate and forwarded `-fwasmtime` are unobserved, so the runtime stays **PENDING** |
| `wasm32-wasi` 46-test public gate | **OBSERVED** | `run test s2-tests 46 pass (46 total)`, exit 0, same receipt |
| `wasm32-wasi` smoke | **OBSERVED — FAILED** | exit 134, `panic: integer does not fit in destination type` at `Io.Threaded.fileWritePositional`, same receipt. No `Writer`/stdout workaround was added |
| `wasm32-wasi` install of all three archives | **OBSERVED** | `install absl`, `install s2`, `install s2bridge`, all cached-success, same receipt |
| Installed S2 C++ consumer on the SDK provider | **OBSERVED** | `decimal_sign_chunk_boundaries=5 invalid_inputs=2 two_threads=2 allocation_cycles=128 outstanding_delete=refused final_delete=reclaimed`; `local://foundation-portability-s2-wasi-installed-cpp-proof.json` |
| C++ facility provider on the SDK sysroot | **OBSERVED** | `counter=10000 file=42.5 bad_alloc=1 cleanup=1` under wasmtime 46.0.3; `local://foundation-portability-complete-cxx-provider-proof.json`. Its own `not_proven` excludes the S2 graph |
| UB trap under `-fsanitize-c=trap` | **OBSERVED** | `cpp_nonnull` → Wasm `unreachable`, exit 134; `local://foundation-portability-wasi-ubsan-sdk-closure-proof.json` |
| Single-thread TLS errno probe | **OBSERVED** | `sdk_errno=28 zig_errno=0 sdk_addr=0x1000000 zig_addr=0`, exit 86; `local://foundation-portability-wasi-sdk-errno-single-proof.json` |
| Stock Zig 0.16 threaded WASI compile | **OBSERVED — FAILED** | Two stock standard-library blockers, exit 1; `local://foundation-portability-wasi-sdk-errno-multi-compile-failure.json` |
| NetBSD corrected provider, all nine targets | **OBSERVED** | All nine complete SDK builds passed; runtime unavailable on this host, so **0 executed pass claims**; `local://foundation-portability-netbsd-targeted.json` |
| Canonical source comparison | **OBSERVED** | Exactly **1 S2** and **7 Abseil** changed paths, no extra and no missing path, every license prefix unchanged and every change notice present; `local://foundation-portability-canonical-source-provenance.json` |
| Whole-Abseil vendor delta (four-path guard) | **OBSERVED, superseded in scope** | That receipt observes exactly four disclosed paths; the current delta is **seven** Abseil paths. `local://foundation-cross-test-s2-approved-vendor-diff.json` |
| Profile syntax and scope | **OBSERVED, pre-wave** | `bash -n`, `cross-test --list` and `--no-profile --list`, all exit 0, identical ordered 53-platform lists; `local://foundation-cross-test-final-profile-verification.json`. The profile file itself is unchanged by this wave |
| Final filtered package and integrity replay | **PENDING** | The record is now **927** entries (the 926 below plus the copied upstream Zig licence). Fetch, replay, materialised consumer and identity are driver-owned: `FORKS.json.cross_test_wave.materialized_packages.s2geometry` |
| macOS / CoreFoundation | **NOT RUN** | No Mac and no licensed Apple SDK on this host; no macOS cell has run since the framework declaration |
| `-fsys=s2` / whole CI / publication | NOT RUN / NOT RUN / NOT AUTHORISED | Unchanged from the statement above |

**Package identity is external to this package, and so is the authoritative
status.** These documentation bytes contribute to the filtered package's
identity, so the final identities live in the root ledger, not here. When the
driver runs the four pending whole-tree gates, the authoritative record is the
root ledger's **`portability_repair_wave`** block for this package; until it is
updated, nothing in this file is a current result. A status here never becomes a
package result, and a package result never rewrites a row here without the
receipt that produced it.

### Historical rounds

Every row below was observed at the revision named in its own command and
receipt. **None of them is a current result for this tree**, and the two rows
about `wasm32-wasi` describe the *bundled* provider that this wave replaced —
they are kept because the receipts are evidence, and they are qualified here so
they are not read as a statement about WASIp1-threads.

| Command | Observed |
|---|---|
| `zig build test smoke install` (Debug, native) | **PASSED**, exit 0. `local://foundation-expansion-s2geometry-final-native-debug-393.log`: "Build Summary: 17/17 steps succeeded; 45/45 tests passed", `run test s2-tests 45 pass (45 total)`, `smoke success`, and all three archives installed. The whole graph is in that run: 153 Abseil units, 108 S2 units, the bridge, the translated header and the smoke program. |
| `zig build test smoke -Doptimize=ReleaseSafe` | **PASSED**, exit 0, **45/45 tests** and `smoke success`. `…-final-native-releasesafe-394.log`. Read the command literally: it was `test smoke`, so this run **did not install**. The installation evidence is 393 alone |
| `zig build check` — `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-windows-gnu`, `riscv64-linux-gnu` | **PASSED** each, exit 0, "Build Summary: 10/10 steps succeeded". `…-final-cross-x86_64-linux-gnu-397.log`, `-aarch64-linux-gnu-398.log`, `-x86_64-windows-gnu-399.log`, `-riscv64-linux-gnu-380.log` |
| `zig fmt --check` on this fork's own eight source files | **PASSED**, exit 0, empty output. `…-driver-final-eight-sdk-own-zig-format-395.log` |
| `zig fetch` of the package | **PASSED**, exit 0 — `s2geometry-0.14.0-2Klt8f9eBwEyMQKeHLiAUZ2h680ivy01LNFmKgfhHvsU`. The package materialises. `…-typed-final-filtered-package-fetch-396.log` |
| `sha256sum -c UPSTREAM.sha256` | **PASSED**, exit 0, all 926 records `OK`. `…-immutable-native-dependency-fixture-integrity-231.log` |
| `git diff --exit-code c24b368c… -- src LICENSE NOTICE CMakeLists.txt` | **PASSED**, exit 0, empty output. `…-pinned-native-pristine-diff-268.log` |
| Abseil vendored tree vs the pinned commit | **PASSED**, exit 0, empty output. `diff -qr` of the whole tree against a reference extracted from the canonical bare clone at `d38452e1ee03523a208362186fd42248ff2609f6`; commit archive digest `8b39fdb7c4a5d7ef0ee88b0b4eb3d23c77623d6f793579a5e0d0af7cf2ce6eaa`. `…-abseil-entire-vendored-tree-pristine-286.log`, `…-abseil-canonical-archive-digest-275.log` |
| historical installed C bridge consumer | **PASSED**, 71 numbered checks at 429/430, against pre-portability archives, not the current source-built install; earlier 402/403 and red 239 retained |
| historical installed C++/Absl consumer | **PASSED**, 21 numbered checks at 431/432 against pre-portability archives; no fresh installed-C++ proof asserted |
| bounded-boundary probes, run from outside the package | **PASSED**, all exit 0, under a 256 MB address-space limit. Compile `…-final-installed-boundaries-compile-406.log`, then: `children status=0 count=1152921504606846976` (407, a 2⁶⁰ descendant count answered with no allocation); `short-buffer status=2 count=1152921504606846976` (408, `BUFFER_TOO_SMALL`, required count reported, buffer untouched); `nonunit constructor status=1 handle=(nil)` (409); `unit bow-tie union status=1 out=(nil)` (410); `unit bow-tie intersection status=1 out=(nil)` (411). **409 proves the constructor's bound, not that a boolean-typed build failure is impossible** — different input, different call site |
| `zig build test smoke install` (Debug, native), after the boundary guards | **PASSED**, exit 0. `…-boundary-closed-native-debug-417.log`: "Build Summary: 17/17 steps succeeded; 46/46 tests passed", `run test s2-tests 46 pass (46 total)`, smoke, install |
| `zig build test smoke -Doptimize=ReleaseSafe`, after the boundary guards | **PASSED**, exit 0, 13/13 steps, **46/46 tests**, smoke. No `install` in the command. `…-boundary-closed-native-releasesafe-418.log` |
| `zig build check`, four targets, after the boundary guards | **PASSED** each, exit 0, 10/10 steps. `…-boundary-closed-cross-x86_64-linux-gnu-419.log`, `-aarch64-linux-gnu-420.log`, `-x86_64-windows-gnu-421.log`, `-riscv64-linux-gnu-422.log` |
| `zig fmt` on this fork's own sources, after the boundary guards | **PASSED**, exit 0, empty output. `…-driver-post-boundary-eight-sdk-format-416.log` |
| `zig fetch`, current snapshot | **PASSED**, exit 0 — `s2geometry-0.14.0-2Klt8WOCBwFfUQlt-MA55F-8f7bo7bF9cgGyhEukOfSl`. Supersedes 396's hash. `…-boundary-closed-filtered-package-fetch-424.log` |
| the two boundary guards, **before** | `FromFacePos` on a face-6 id **aborted**: exit **-6** (SIGABRT) at `src/s2/s2cell_id.h:661] Check failed: is_valid()`, reached through `S2CellId::parent` — worse than the review's predicted wrong status. `…-contract-boundaries-before-smoke-413.log`. The count promise: exit 1, `invalid-cell status=1 count=7; null-polygon status=1 count=9` — an error with the count retained. `…-count-protocol-before-smoke-415.log` |
| the two boundary guards, **after** | in the 46/46 runs. `FromFacePos` is bounded to `face 0..5` in the raw bridge (`zig/bridge.cc:346`, `:355`) **and** in the facade, with the raw out-parameter unchanged on failure; `FromFace`'s deliberate handling of faces 6 and 7 is unchanged. `Coverer` calls that fail early on a polygon or cell now report **count zero** per the header's promise, and a new permanent test asserts the whole raw sequence — valid count → invalid → valid count → null handle |
| `zig build consumer` | **PASSED**, exit 0, "10/10". `…-live-consumer-423.log`: the separate `consumer/` package resolves this one by path, builds the whole graph itself, runs, and prints its published golang/geo token/id pairs |
| `sha256sum -c UPSTREAM.sha256` inside the materialised package | **PASSED**, exit 0, **926/926 `OK`** — the record and the manifest now agree, nothing missing. `…-current-filtered-integrity-425.log` |
| `consumer` inside the materialised package | **PASSED**, exit 0, "10/10". `…-filtered-consumer-426.log` |
| installed after-contract probes | **PASSED**, both exit 0. Compile `…-installed-after-contract-compile-427.log`; run `…-run-428.log` prints `invalid-cell status=1 count=0; null-polygon status=1 count=0` — the count promise holds — and `out-of-contract face=6 status=1 id=0x00000000deadbeef valid=1`: rejection is reported, the caller's sentinel is left **unchanged**, and that sentinel is itself a valid id. Not null, not invalid |
| `check -Dtarget=aarch64-macos-none` | exit 1 at that revision — **a missing SDK**, not a defect in this package: `CoreFoundation/CFTimeZone.h` not found, one error in `libabsl.a`. The framework is now *declared* for Darwin targets; it is still not *available* here, so the cell is still red for the same external reason. `…-closure-cross-aarch64-macos-none-355.log` |
| `check -Dtarget=wasm32-wasi` | exit 1 at that revision, **against the bundled Zig libc++ provider**: `"wasm lacks signal support"`, 39 errors, with the missing `std::mutex` and `<fstream>` behind it. That was a statement about the bundled provider, and it is `WITHDRAWN` as a statement about the platform — see "What changed for `wasm32-wasi`, and what is withdrawn". `…-closure-cross-wasm32-wasi-358.log` |
| any `-fsys=s2` command | **NOT RUN**, and no installed `libs2` or Abseil was observed anywhere in this workspace. |
| `cross-test`, one target (`x86_64-linux`), **before** the unconditional run step | **FAILED**, exit 1. Run `20261002-033134-17908-30770`, `/home/tmp2/gertullj/scratch/foundation-libs/cross-test-01a0f400/before/s2geometry/cross-test-summary.json`: `build` pass exit 0, `run` fail, `tests` null, reason `no_test_results`, 500.96 s wall, `profile` empty. The build log shows `Build Summary: 9/9 steps succeeded`, `test success` and `compile test s2-tests Debug x86_64-linux success 873ms` — and no `run` line at all |
| `cross-test`, full 53-platform matrix, **after** the unconditional run step | **SUPERSEDED.** The correction was source-ready with no gate of its own at that point, and the "expected" behaviour described there is what the two later sweeps actually reported (18/22/13, then 20/14/19) — both against the *previous* revision of this tree. See "The full 53-platform matrix" above for why the current cell is PENDING |
| `cross-test` on a GNU-libc Linux target | **DEPENDENT ON A MISSING PREREQUISITE.** The harness passes `--libc-runtimes` only when `CROSS_LIBC_RUNTIMES` is set; without it the build runner cannot supply the dynamic loader QEMU user needs and reports the run as skipped. Provisioning that directory is the driver's decision and no run below depends on this fork's source |

**46 tests now.** The count has moved twice: 39 originally, 45 after the six
permanent behavioural regressions for the defects listed below, and **46** since
the count-protocol state-transition test was added. Those added tests are what
made those runs evidence about the repairs rather than only about the library.
They also print seven upstream `E`-level log lines — `s2latlng_rect.h:397 Invalid
rect`, `s2loop.cc:212 Edge 0 is degenerate (duplicate vertex)`, and
`s2polygon.cc:249 Shape 0 has one or more edges with interior on the right` six
times. They are the *negative* tests exercising exactly those rejected inputs;
in the runs quoted below the suite was green and those lines are diagnostics,
not failures — and the same 46 pass on the WASI SDK provider today. The native
46/46 over *this* source is still PENDING, so nothing here is a current native
result.

### How it got here, kept because the receipts are evidence

The four source defects below were each found by a probe and each has a
permanent regression now counted in the 46. Their *before* rows are kept, and
the *after* rows, so the record is a before-and-after rather than a claim:

| Defect | Before | After |
|---|---|---|
| `s2br_cell_children`'s counting pass built the whole 2⁶⁰-element descendant list to learn its length, answering `S2BRIDGE_OUT_OF_MEMORY` with `count = 0` under `ulimit -v 262144` | exit 1, `children status=3 count=0`. `…-review-before-children-278.log` | counted in the 46/46, by the `distance_from_begin` measurement; and answered from outside the package at 407, `children status=0 count=1152921504606846976` |
| `s2br_polygon_create` had no ordinary unit-length bound, so finite non-unit vertices reached `s2pred::OrderedCCW` and aborted at `s2predicates.h:394] Check failed: a.Norm2() <= 2 (4 vs. 2)` **inside the constructor** | exit **134**, both `union` and `intersection`. `…-review-before-union-279.log`, `…-review-before-intersection-280.log` | counted in the 46/46; rejected as `InvalidArgument`, and answered from outside the package at 409, `nonunit constructor status=1 handle=(nil)` |
| `s2br_polygon_union` / `intersection` reached `S2Loop::Init` on a polygon whose edges cross, aborting at `s2loop.cc:357] Check failed: IsValid()`. The constructor returned OK and `is_valid` correctly said invalid | exit **134**, both. `…-review-topology-before-union-282.log`, `…-review-topology-before-intersection-283.log` | counted in the 46/46; `RequireValidOperand` and the `S2Error` overload, and answered from outside the package at 410/411, `status=1 out=(nil)` |
| the facade `@intCast`ed a `usize` index into the bridge's C `int`, so `Loop.vertex(maxInt(usize))` panicked instead of erroring | compile 0, run **exit 134**, panic at `zig/root.zig:956`. `…-facade-index-before-compile-346.log`, `…-facade-index-before-run-347.log` | probe compile 0 / run **exit 0**, `oversized public vertex index rejected as InvalidArgument` (`…-facade-index-after-compile-348.log`, `…-facade-index-after-run-349.log`) — linked against the already-installed archive, so facade-only — plus the 46/46 for the whole graph |

Both probe binaries had compiled and linked cleanly against the install set
before any of these (`…-review-regression-probe-compile-277.log`,
`…-review-topology-probe-compile-281.log`, exit 0, each linking
`-ls2bridge -ls2 -labsl` with `-fsized-deallocation` on the consumer's own
compile line), so none of the four was ever a build problem.

### The build failure in between, and two withdrawn explanations

For several iterations the package did not compile at all: `compile lib
s2bridge` reported 119 diagnostics — `-Wnullability-completeness` — from
upstream headers reached through `zig/bridge.cc`, first at
`src/s2/s2builder.h:473:20` (`…-final-native-debug-313.log`,
`…-final-native-releasesafe-314.log`, and cross runs 316, 317, 319, 320).

**This file has explained that failure twice, and both explanations are
withdrawn.** The first blamed the system-include arrangement, inferring from
`build.zig` carrying both `addSystemIncludePath` and an ordinary
`addIncludePath` for the same two roots (`:380-381` and `:202-203`) that the
roots had stopped being classified as system headers. The second blamed all
119 on two C++ typos — `BooleanOp.kIntersection` and `BooleanOp.kUnion` instead
of `::`, at `zig/bridge.cc:1368` and `:1378` — reasoning that a translation
unit which fails to parse takes its whole include graph with it.

**Neither is established.** What is observed: the failing runs recorded **117
header diagnostics alongside 2 errors in this repository's own C++**; the
repair changed the header ownership / system-include roots **and** the `::`
syntax together; the next run was green. No experiment varied one while holding
the other fixed, so the run shows the coupled change worked and does **not**
show which half mattered, or whether the 117 were ever caused by the two
syntax errors. Neither explanation is promoted over the other, and a later
reader should not read either into this tree.

The lesson is in `FORK-NOTES.md` as **L22**, and it is the narrow one: a coupled
correction does not attribute a cause, and a plausible explanation is not a
diagnosis. This file asserted a cause confidently twice; the second was as
unfounded as the first.

A separate regression is fixed in a different place than it was first
reported. Six assertions in `tests.zig` compared a raw status against
`translate-c`'s signed `c_int` enumerator and did not compile (376, 392). The
fix is `tests.zig:1401`, a typed local compared against by those six
assertions — not the facade's `check`, whose signature was unchanged.

### The verdict

**Nothing over this repair wave has been gated end to end yet.** The honest
summary is one sentence: *the sources and the provider contract are landed and
individually exercised; the whole-tree gates over them are still to be run by
the driver.*

**`wasm32-wasi` is no longer a categorical impossibility, and is not yet a
green cell either.** With the installed SDK 34 sysroot and the patched
standard library, the complete 261-unit source closure compiles and links, the
46 public tests pass, all three archives install, the standalone consumer
**compiles and installs but was not run**, and a separate installed S2 C++
consumer program really did execute its decimal/sign/chunk boundaries and
two-thread arena work. The same run's `smoke` **failed**, exit 134, in Zig's
`Io.Threaded` writer. Both of those are recorded as they happened, not written
around, and until the driver re-runs the target it has no full green claim.

**macOS stays a declared-but-unavailable dependency.** `CoreFoundation` is now
linked on Darwin targets because CCTZ's Apple timezone implementation uses it;
no Mac and no licensed Apple SDK exist on this host, no SDK was downloaded, and
no macOS cell was run after the declaration. There is no fake macOS proof and
no fabricated header.

**Every native, baseline, matrix and package gate is PENDING.** The pre-wave
native 46/46 Debug and ReleaseSafe runs, the four-pass/two-fail baseline, the
20/14/19 matrix composite and the 926-record integrity replay all describe the
**previous** revision of this tree. They are kept in the Current and Historical
tables with their receipts and are not restated here as current. Missing
runtimes are not executed passes, and no target or core source is omitted to
hide a failure.

**One thing is optional and unexercised**: `-fsys=s2`. No installed `libs2` or
Abseil was observed on any machine here, so that mode has no result — which is
a statement about what is installed, not about the package.

**No whole CI job has been run.** The earlier installed C/C++ consumer excerpts
and the four-file Abseil guard are local excerpt proofs only, and that guard's
scope is now seven Abseil paths.

Build timing, for planning a cold build: with a warm global cache and an empty
per-target cache, the recorded Debug run took 3 minutes for the 153 Abseil
translation units, 5 minutes for the 108 S2 translation units and 18 seconds
for `zig/bridge.cc` — `local://foundation-expansion-s2geometry-isolated-cache-smoke-157.log`.
Plan a cold build at ten minutes, not two.

## Integrity

`UPSTREAM.sha256` carries **927** SHA-256 records: every compiled source, every
installed header, every licence and dependency/build record, the six upstream
oracle files the fixtures were transcribed from, this fork's six fixture files,
and — new in this wave — the copied verbatim upstream Zig licence
`build_support/zig-0.16-LICENSE.txt` that ships with the standard-library
patch. It is a raw-byte record of this working tree, produced with SHA-256 from
`node:crypto` in a Bun eval cell; no shell hashing command and no `git` command
produced it, and every record is re-derived from the written file with the same
method and compared against it. The **927th** record is the only addition; the
other 926 are unchanged, and across the eight SDKs the total goes from 1518 to
1519 because this package gained exactly one.

Two checks cover the same tree and answer different questions:

```sh
# Are the bytes this build compiles, installs, reads and licenses the recorded ones?
sha256sum -c UPSTREAM.sha256

# Does the compiled closure still differ from the pinned upstreams by exactly
# the disclosed paths?  This is a *comparison*, not a diff-to-empty check:
# 1 path under src/, 7 under vendor/abseil-cpp/, and no other difference.
```

The second check is the one that matters now. `git diff --exit-code c24b368c… --
src` used to be the "is `src/` still pristine?" question and **is no longer a
valid form of it**, because `src/` now carries exactly one disclosed change; a
clean result from it would mean the repair had been reverted. The current
question is answered by comparing the whole compiled closure against the
canonical upstream archives, over the entire `src/s2` tree and the entire Abseil
tree — file types, symlink targets, directories and SHA-256 — and that
comparison **PASSED**: `s2_difference_count = 1`,
`abseil_difference_count = 7`, `extra_missing_paths = false`, every license
prefix unchanged, and a change notice present on all eight
(`local://foundation-portability-canonical-source-provenance.json`; canonical
archive digests `6e49b320…` for S2 and `8b39fdb7…` for Abseil). The one S2
path is `src/s2/util/math/exactfloat/bignum.cc`; the seven Abseil paths are
`direct_mmap.h`, `low_level_alloc.h`, `low_level_alloc.cc`,
`examine_stack.cc`, `stacktrace_powerpc-inl.inc`, `conditions.h` and
`cctz/src/time_zone_format.cc`.

**The public surface did not move to get there.** The API is still ten types,
**104 public methods**, one error set and two constants; `tests.zig` still has
**46** behavioural tests, and `smoke.zig` still has its seven sections. No
fixture under `testdata/` changed, no published oracle was re-transcribed, no
tolerance was widened and no test was added, removed or relaxed to accommodate a
new platform — the same 46 pass on the `wasm32-wasi` provider that pass on
native. The complete closure is still **108 S2 + 153 Abseil** translation
units; nothing was dropped to make a target green.

The earlier whole-record replay 231 passed 926 records **before** this wave's
changes; it does not verify the current 927-record file. Current source/fetched
replay status is in the driver-owned package closure. The S2-scoped Git diff 268
passed over `src LICENSE NOTICE CMakeLists.txt` at its revision and said nothing
about modified Abseil.

The vendored Abseil tree is checked the same way, and its check needed two
pieces rather than one. `vendor/abseil-cpp` is an unpacked release with no
`.git`, so a `git archive` aimed at it resolves to the **outer** repository and
digests the wrong tree; the driver therefore cloned the tag canonically
(`…-abseil-canonical-pin-acquisition-273.log`, exit 0) and took
`git --git-dir=… archive --format=tar d38452e1… | sha256sum` under
`set -o pipefail` — `8b39fdb7c4a5d7ef0ee88b0b4eb3d23c77623d6f793579a5e0d0af7cf2ce6eaa`,
exit 0 (`…-abseil-canonical-archive-digest-275.log`). It pins the upstream
release. Pristine whole-vendor comparison 286 is **pre-patch history**, and the
four-path guard receipt at
`local://foundation-cross-test-s2-approved-vendor-diff.json` observes exactly
the four architecture paths it was written for — its scope, not the tree, is
what has moved. The earlier empty-string digest attempt is withdrawn in
`UPSTREAM.md`.

## Licence

Apache License 2.0 is both upstreams' project licence, not a licence for every
file. Three compiled S2 hashtable headers also carry BSD-3-Clause text; the
compiled Abseil CCTZ `tzfile.h` and retained timezone data carry public-domain
notices. `NOTICE.md` itemises their paths and use and reproduces the BSD
conditions. The full project texts and original attribution files remain
unchanged. No upstream grant is asserted over the fork-authored files; their
licence is the owner's unassigned decision.

The build's external providers keep **their own** terms, and this package
asserts nothing over them:

* **WASI SDK 34.** The sysroot named by `-Dwasi-sysroot=` is the SDK
  provider's own distribution, licensed on its own terms, and it is not
  redistributed, vendored or relicensed here. This package asserts no
  compatibility with, and no licence over, that SDK. Those terms are read from
  the SDK itself, not from this file.
* **Wasmtime.** The runtime used to execute `wasm32-wasi` modules is
  Bytecode Alliance's own distribution under its own licence (Apache-2.0 with
  LLVM exceptions as shipped); it is invoked, not linked or shipped.
* **The patched standard library.** `build_support/wasi_stdlib.patch` is
  fork-authored and touches two upstream Zig source files, so it carries their
  original context unchanged: no upstream copyright line, licence line or
  comment is altered, and **no licence is invented for the patch** or asserted
  beyond that unchanged upstream context. The complete terms of the pinned
  compiler — MIT (Expat), "Copyright (c) Zig contributors" — are copied
  verbatim into the sibling file `build_support/zig-0.16-LICENSE.txt` and are
  recorded in `UPSTREAM.sha256`. The stock compiler installed beside it is
  **unchanged**; the patch is applied to a copy selected with the standard
  `--zig-lib-dir`, never to the installation and never to a global tool.
* **CoreFoundation / macOS.** The framework is *linked* on Darwin targets; it
  is Apple's, under Apple's terms, and no Apple header, type or prototype is
  reproduced here. No Apple SDK was obtained on this host.
* **The forked Abseil files.** Each of the seven carries its Apache-2.0 header
  intact plus a prominent change notice, as Apache-2.0 requires; `NOTICE.md`
  records them per file.

## See also

* `UPSTREAM.md` — revisions, archive receipt, import mechanism, sync procedure.
* `NOTICE.md` — licences, obligations, fork-owned files.
* `CHANGELOG.md` — numbered fork-only divergences.
* `FORK-NOTES.md` — decisions, what they cost, and the pending list.
* `README.md`, `doc/` — upstream's own documentation, unmodified.
