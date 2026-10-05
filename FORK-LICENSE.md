# FORK-LICENSE.md — the licence of this fork's own files

**SPDX-License-Identifier: `Apache-2.0`**

This file covers the files **this fork authored** and nothing else. It does not
restate or extend any upstream licence: `s2geometry` and Abseil C++ keep their
own terms and their per-file exceptions, the Zig compiler's own C++ runtime —
which one route compiles and ships — keeps the LLVM project's, and `NOTICE.md` is
the per-file inventory.

## The authorization

Earlier revisions recorded that **no licence was asserted** over these files,
because the choice had not been made. That is history and it stays in the tree
as such. On **2026-10-04** the project's owner authorized a licence for the
fork-authored additions matching the primary upstream terms where appropriate;
for this project that term is Apache-2.0, because both upstreams are. The owner
is the holder of this grant, not either upstream, and no upstream author is
credited with any file below.

The complete licence text is not restated here: it is `LICENSE`, at the root,
which is the same text that governs upstream's work. Apache-2.0's own terms
apply in full — the §2 copyright permission, the §3 patent grant and its
termination on the filing date of patent litigation, the §4 conditions (the
licence travels with the files, modifications are marked where they occur, the
NOTICE is reproduced), and the §6 trademark carve-out, which grants no right to
use the names or logos of Google, of the S2 Geometry Library or of Abseil.

The copyright holder is named as the fork's contributors. No individual
identity is invented here: the holder is the project's owner, identified in the
private repository that carries this work.

## What the grant covers

Every file upstream did not ship:

| Category | Files |
|---|---|
| Build definition | `build.zig`, `build.zig.zon`, `build_support/s2_sources.zig`, `build_support/absl_sources.zig`, `build_support/platform_flags.zig`, `build_support/wasi_provider.zig`, `build_support/cpp_runtime.zig`, `build_support/wasi_stdlib.patch`, `cross-test.profile.sh`, `.gitignore`, `.github/workflows/verify.yml` |
| C bridge | `zig/bridge.h`, `zig/bridge.cc` |
| Typed facade | `zig/root.zig` |
| Runtime route | `runtime/loader.zig`, `runtime/library.zig`, `runtime/generate.zig`, `runtime/graph.zig`, `runtime/sync.c`, `runtime/sync.h` |
| Tests, example, consumer | `tests.zig`, `smoke.zig`, `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig` |
| Packaging | `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc` |
| Transcribed fixture data | the six files in `testdata/` |
| Records | `README.md`, `README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `FORK-LICENSE.md`, `NOTICE.md`, `UPSTREAM.md`, `UPSTREAM.sha256` |

Two rows need their own sentence: the standard-library patch and the fixture
data, below.

## What the grant does not cover

* **Upstream's bytes.** `src/` and `vendor/abseil-cpp/` keep upstream's
  Apache-2.0 grant, and §4(b) of that licence is why each of the eight modified
  files carries a prominent change notice. `NOTICE.md` lists them.
* **Per-file exceptions inside upstream's work.** Three compiled
  `src/s2/util/gtl` headers also carry BSD-3-Clause text; the compiled CCTZ
  `tzfile.h` and the retained timezone data carry public-domain notices;
  `vendor/abseil-cpp/absl/crc/internal/crc.cc` carries source attributions to
  third parties. Those travel with their files and are not replaced by any label
  here.
* **Upstream's own records.** `LICENSE`, `NOTICE`, `AUTHORS`, `CONTRIBUTORS`,
  `vendor/abseil-cpp/LICENSE` and `vendor/abseil-cpp/AUTHORS` are reproduced
  verbatim.
* **Providers this package links or invokes without shipping.** The WASI SDK 34
  sysroot, Wasmtime and CoreFoundation keep their own terms.
* **The compiler's own C++ runtime, compiled by one route.** `build_support/cpp_runtime.zig` is
  fork-authored and Apache-2.0 like every other file this fork writes, but what
  it *builds* is not: on an ELF target with `-Dlinkage=dynamic` it compiles the
  pinned compiler's shipped libc++, libc++abi and libunwind sources into
  `libs2cpp.so.0`, and those components are the LLVM project's under **Apache
  License 2.0 with the LLVM exception**. No compiler source is copied here, none
  is edited, and the compiler's own installation is not modified. Each
  component's `LICENSE.TXT` is installed verbatim beside the other records as
  `LICENSE.libcxx.txt`, `LICENSE.libcxxabi.txt` and `LICENSE.libunwind.txt`.
  That grant is the LLVM project's, it is unaffected by the authorization below,
  and the compiler's MIT text already carried for the standard-library patch does
  not extend to it either way. `NOTICE.md` records all of this.
* **The build compiler's standard library.** The patched copy lives outside this
  package and is never installed, and the files it edits keep the MIT (Expat)
  terms quoted under "Two rows with their own sentence" below.

## Two rows with their own sentence

**`build_support/wasi_stdlib.patch`** is fork-authored and Apache-2.0 like the
rest of this fork's additions. It alters no upstream copyright line, licence
line or comment in either file it edits, and retains each file's original
context. Those files keep **MIT (Expat), "Copyright (c) Zig contributors"**,
whose complete text ships at `build_support/zig-0.16-LICENSE.txt` and is
recorded in `UPSTREAM.sha256`. The patched standard-library tree is not shipped
here: it is prepared outside the package and selected with the compiler's own
`--zig-lib-dir`, so no compiler installation is modified.

**`testdata/`** holds transcriptions of published numeric answers, so it is
fork-authored and Apache-2.0. Each file names its source and the credit due for
the data. golang/geo (BSD-3-Clause, © The Go Authors) supplies some of those
answers; no golang/geo source is redistributed, so its licence text is
deliberately not shipped. If this package ever carries golang/geo source,
`LICENSE-BSD-3-CLAUSE-go` must be added and this section rewritten.

## See also

* `NOTICE.md` — upstream works, per-file exceptions, obligations, and the
  complete inventory of fork-owned files.
* `LICENSE` — the Apache-2.0 text itself.
* `UPSTREAM.md` — the pinned revisions and the eight disclosed modifications.
* `README.md` §5 — this fork's licence summary.