# NOTICE

This package redistributes and compiles two Apache-2.0 upstream works, with
the embedded BSD-3-Clause and public-domain notices itemised below, and — on one
route only — a third work: the build compiler's own C++ runtime, under the LLVM
project's Apache-2.0-with-LLVM-exception terms, credited in its own section
below. This file states their retained notices and every file this fork owns. A
private repository removes no upstream obligation, and a Zig build script
removes none either: what is compiled here is upstream's code, so upstream's
licence governs the compiled artifact exactly as it would govern a CMake build.

## Upstream work

### S2 Geometry Library

```
S2 Geometry Library
Copyright 2017 Google Inc.  All Rights Reserved.

This product includes software developed at
Google (https://www.google.com/).
```

That text is upstream's `NOTICE`, carried verbatim at `NOTICE`.

* Copyright holders for copyright purposes: the entries in `AUTHORS` —
  Aurora Innovation, Dan Larkin-York (`dan@arangodb.com`), Google Inc.,
  Koordinates Limited, Mike Playle (`mike@mythik.co.uk`), Tiago Brito
  (`tiago.brito@90poe.io`).
* Individual contributors who have signed a CLA are listed in `CONTRIBUTORS`.
  Google employees are deliberately **not** in `CONTRIBUTORS`; Google holds the
  copyright, as that file's own header explains.
* Licence: `LICENSE`, the Apache License 2.0 in full.
* Source: `https://github.com/google/s2geometry` at tag `v0.14.0`, commit
  `c24b368c67d0b8a2a109c5a75224e73a856bd8b7`, carried whole.

**An upstream file that is wrong, carried anyway.** `AUTHORS` opens with
"This is the official list of glog authors for copyright purposes." That is a
copy-paste artefact from `glog`, present in the v0.14.0 tag itself, and the
names it lists are the S2 project's. It is recorded here rather than silently
repaired, because editing an upstream licence or attribution file is a bigger
change than a private repository is worth making: the text is a comment, it
names the correct copyright holders below it, and `NOTICE` above is the notice
that actually governs. A redistributor who wants it fixed should fix it
upstream.

### Abseil C++ (LTS 20250814.1)

Abseil 20250814.1 ships **no `NOTICE` file**. Its `AUTHORS` is the whole of its
attribution record:

```
# This is the list of Abseil authors for copyright purposes.
#
# This does not necessarily list everyone who has contributed code, since in
# some cases, their employer may be the copyright holder.  To see the full list
# of contributors, see the revision history in source control.
Google Inc.
```

* Copyright holder: Google Inc.
* Licence: `vendor/abseil-cpp/LICENSE`, the Apache License 2.0 in full.
* Source: `https://github.com/abseil/abseil-cpp` release `20250814.1`, commit
  `d38452e1ee03523a208362186fd42248ff2609f6`, carried whole at
  `vendor/abseil-cpp`.

### Zig 0.16.0 — the build compiler, its two patched standard-library files, and the C++ runtime one route compiles

This is a third work in the tree, and it is recorded here rather than left to be
discovered. Nothing of it is redistributed as source. What this fork carries is
licence text — one for the standard-library patch, three more for the C++ runtime
an ELF shared build compiles — and what it does at build time is modify two files
of the compiler's standard library, in a copy it never installs.

* The compiler itself is **not** redistributed. `build.zig.zon` declares
  `.minimum_zig_version = "0.16.0"`; the build runs whatever Zig 0.16.0 the
  machine supplies. **The stock binary is unmodified**: there is no patched
  compiler here, no build-time download, and no proprietary SDK.
* The complete terms are carried verbatim at
  `build_support/zig-0.16-LICENSE.txt` — MIT Expat, "Copyright (c) Zig
  contributors", 21 lines, a byte-for-byte copy of the `LICENSE` beside the
  pinned compiler (SHA-256
  `5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177`). MIT
  requires that notice to travel with copies and substantial portions of the
  software, so it travels.
* `build_support/wasi_stdlib.patch` is **fork-authored** and modifies exactly
  two upstream Zig standard-library sources: `std/heap.zig`, so a threaded
  libc-linked `wasm32-wasi` page allocator uses the real `c_allocator` instead of
  the `@compileError("unimplemented")` `WasmAllocator`, and `std/Io/Threaded.zig`,
  so a finite wasm `memory.atomic.wait32` timeout saturates to `maxInt(i64)`
  instead of wrapping to a negative, i.e. indefinite, wait. **Licensing of that
  patch:** it is fork-authored, and since the owner's authorization of
  2026-10-04 it is licensed **Apache-2.0** over the patch file itself, exactly
  like every other fork-authored file in this tree; see `FORK-LICENSE.md`. It
  alters no upstream licence, copyright or comment line, and the unmodified
  original copyright and licence context of each patched file is retained inside
  the patched file. The patched files keep their own terms, and the full upstream
  terms for them are the MIT text in `build_support/zig-0.16-LICENSE.txt`, which
  travels in the package.
* The patched standard-library tree is **not** shipped and **not** recorded in
  `UPSTREAM.sha256`: it is prepared outside this package, applied to a copy of
  the compiler's own `lib` tree, and passed to the compiler through
  `--zig-lib-dir`. Hashing SDK-internal mutable bytes inside a record about
  pinned upstreams would be a different claim from the one this record makes.

**The C++ runtime one route compiles.** With `-Dlinkage=dynamic` on an ELF
target, `build_support/cpp_runtime.zig` compiles the pinned compiler's own libc++,
libc++abi and libunwind sources into `libs2cpp.so.0.16.0` and installs it beside
the three libraries. That is a distribution of compiler-shipped code, so it is
attributed here rather than left in a build comment:

* **Source pin.** Zig 0.16.0, source commit
  `24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8`, recorded in
  `build_support/cpp_runtime.zig:4-5`. The compiled unit lists follow that
  compiler's own `src/libs/libcxx.zig` — its base and threaded libc++ units, its
  libc++abi units, its libunwind units — and are read at build time from
  `b.graph.zig_lib_directory`, the directory the running compiler itself
  compiles those sources from.
* **Terms.** The three components are the LLVM project's, under **Apache License
  2.0 with the LLVM exception**. Each component's own `LICENSE.TXT` is installed
  **verbatim**, from beside those sources, as
  `share/licenses/s2geometry/LICENSE.libcxx.txt`,
  `share/licenses/s2geometry/LICENSE.libcxxabi.txt` and
  `share/licenses/s2geometry/LICENSE.libunwind.txt`. That is the same obligation
  the two Apache-2.0 texts above carry, met the same way: the notice travels with
  the binary. Those three files are **not** covered by the compiler's MIT terms
  this package already carries for the standard-library patch, and neither grant
  is extended to cover the other.
* **What was not done.** No compiler source is copied into this repository, none
  is edited, no upstream notice or copyright line is altered, and the compiler
  installation on the machine is not modified: the runtime is built from what the
  compiler already ships, and nothing about it is patched.
* **Route.** ELF shared delivery only. `static`, `wasm32-wasi`, Darwin and Windows
  compile no Zig C++ runtime at all and install no `libs2cpp`.
* **Not in the integrity record.** `UPSTREAM.sha256` covers the bytes of this
  working tree, and these sources are not in it for the same reason the patched
  standard library is not in it. No digest is invented for a file this tree does
  not hold; the obligation those texts discharge is §4(a) above, not a hash in
  that record.

**The three licence files are installed, and CI now requires them.** The shared-
delivery job of `.github/workflows/verify.yml` runs on an ELF target with
`-Dlinkage=dynamic`, requires all three, and `cmp`s each one byte for byte
against `<lib_dir>/<runtime>/LICENSE.TXT` taken from `zig env`, failing
non-zero when `lib_dir` cannot be read (`verify.yml:1024-1057`). The same job's
installed-consumers step checks the **static** prefix for the opposite truth: no
`zig-out/lib/libs2cpp.*` and none of the three texts (`verify.yml:326-349`).
That closes the gap this file recorded earlier — the loop named only
`LICENSE.zig-0.16.0.txt` and the workflow did not enforce these three. **No CI
job has been run**, so this is a statement about what the workflow now requires,
not an observed pass.

**What is and is not observed for the patched provider.** The two-hunk repair
is landed and recorded, and the WASI target's recorded gates — the closure
compiling and linking under the SDK 34 sysroot, the 46 public tests, the three
installs, and the red `smoke` cell — are in `UPSTREAM.md` under "The WASI
provider", with their receipts. What remains an open observation is a **whole
target** gate over `wasm32-wasi` at the current revision; this file asserts
none.

### No other third-party code is compiled

This is a complete statement, not a summary. The compiled closure is
`libs2bridge → libs2 → libabsl` plus the platform C and C++ runtimes, and on one
route — `-Dlinkage=dynamic` on an ELF target — one further object,
`libs2cpp.so.0`, which is the LLVM project's own libc++, libc++abi and libunwind
compiled from the pinned compiler's shipped sources and credited immediately
above. Apart from those, there is no googletest, no Google Benchmark, no OpenSSL,
no boringssl, no zlib, no pcre, no pthreads package of our own, and no vendored
copy of anything else in any installed artifact.

**What "the C and C++ runtime" means on each route.** `static`, and every
non-ELF delivery, uses the consumer's own or the compiler's ordinary C++
runtime and distributes none of it. `wasm32-wasi` links the installed WASI SDK 34
sysroot's own `libc++.a`, `libc++abi.a` and `libunwind.a`, which this package
does not redistribute. Darwin and Windows use the platform's own. The ELF shared
route is the single exception, and it exists because Zig's ordinary *static* C++
runtime archive is compiled with hidden exports, which cannot preserve
`std::locale` facet identity across images; the shipped sources are therefore
compiled here as one shared object, so that a single runtime serves the whole
closure instead of each image carrying a private copy.

**One qualification, stated here rather than left to be found.** For the
`wasm32-wasi` target, the Zig standard library *is* compiled into the test,
smoke and consumer executables. Those are not redistributed library artifacts,
so they are not part of the closure a consumer of this package receives, but the
code is compiled and its origin is owed a credit. It is built from the pinned
Zig 0.16.0 compiler with the two-hunk fork patch recorded above, whose MIT terms
travel verbatim in `build_support/zig-0.16-LICENSE.txt`. Apart from the ELF shared
route's `libs2cpp`, no compiler C++ runtime is compiled anywhere else, and no
Zig package and no vendored Zig library is part of any artifact.

Two upstream things that *look* like dependencies and are not:

* `src/s2/util/math/exactfloat/bignum_test.cc` is the only file in the S2 tree
  that includes `<openssl/bn.h>`. It is an upstream unit test, and this package
  does not compile it (see `UPSTREAM.md`, "What is carried but is not part of
  the package").
* `src/s2/*_test.cc` and `src/s2/testing/test_main.cc` need GoogleTest. None
  is compiled. `zig build` therefore never downloads or demands a test
  framework, which is one of the reasons the build has no network access at
  all.

Because the bridge and the facade are this fork's own code, they are not
"third-party credits". They are listed under "What this fork changed" below.

## The grant, and which licence applies where

Apache License 2.0 is both upstreams' project licence. It is not the only
notice in the compiled headers or retained data; the per-file exceptions below
travel with their original files and are not replaced by that project label.

### The grant

`LICENSE` §2 grants the copyright permissions; §3 grants the patent licence.
The full terms, including their conditions and termination provisions, are
retained verbatim rather than replaced by this record.

For **s2geometry** the Work is the whole repository at the pinned commit; for
**Abseil** it is the whole release at the pinned commit, of which this package
redistributes the whole tree.

Everything else in this package — `build.zig`, `build.zig.zon`,
`cross-test.profile.sh`, `build_support/` other than the one verbatim licence
copy named above, `zig/bridge.h`, `zig/bridge.cc`, `zig/root.zig`, `tests.zig`,
`smoke.zig`, `consumer/`, `package.nix`, `flake.nix`, `devenv.nix`,
`devenv.yaml`, `.envrc`, `.github/workflows/verify.yml`, `.gitignore`, the six
`testdata/` fixture files, this `README.md`, `README.zig.md` and the other
records under "This fork's own records" below — is **fork-authored, and is
licensed under the Apache License 2.0** by the project owner's authorization of
2026-10-04, matching this project's primary upstream terms. The grant, its
scope, its §3 patent-termination clause and the two rows that need their own
sentence are in `FORK-LICENSE.md`; the SPDX identifier for these files is
`Apache-2.0`.

That grant is **not** borrowed from either Apache upstream above and asserts
nothing over their files: upstream's terms govern upstream's bytes, this one
governs this fork's additions, and the two are separate grants over separate
files. An earlier revision of this file offered the upstream licence over the
fork-authored files, and that offer is **withdrawn**; a later revision recorded
that no licence was asserted over them, which described the state before the
owner's decision rather than a claim that none would be made.

### Embedded notices in compiled and retained files

| Retained path | Notice and attribution | Use in this package |
|---|---|---|
| `src/s2/util/gtl/dense_hash_set.h`, `densehashtable.h` | Copyright 2005 Google Inc.; Apache-2.0 at lines 3–13 followed by the full BSD-3-Clause text at lines 18–42 | Compiled header code, through `sequence_lexicon.h` / `value_lexicon.h` and the hashtable include chain; installed with the S2 headers |
| `src/s2/util/gtl/hashtable_common.h` | Copyright 2010 Google Inc.; the same Apache-2.0 and BSD-3-Clause texts at lines 3–13 and 18–42 | Compiled header code included by `densehashtable.h`; installed |
| `vendor/abseil-cpp/absl/time/internal/cctz/src/tzfile.h` | Public-domain declaration by Arthur David Olson, clarified 1996-06-05, lines 7–10 | Included by the compiled CCTZ `time_zone_info.h`; installed with the Abseil headers |
| `vendor/abseil-cpp/absl/time/internal/cctz/testdata/zoneinfo/iso3166.tab`, `zone1970.tab`, `zonenow.tab` | Their own public-domain declarations and Paul Eggert source attributions remain in the files | Retained timezone test data, not compiled or read by this fork's gates |
| `vendor/abseil-cpp/absl/base/spinlock_test_common.cc` | Apache-2.0 file with a comment at lines 68–69 crediting the public-domain Bob Jenkins `lookup2` hash | Retained upstream test source; not compiled |
| `vendor/abseil-cpp/absl/crc/internal/crc.cc` | Apache-2.0 file; lines 27–30 attribute the interleaved word-by-word CRC method to Andrew Kadatch and Bob Jenkins and name their paper | Compiled Abseil translation unit; the source attribution is retained, without inventing a separate licence for the cited method |

The three S2 headers carry both texts without an explicit alternative selector.
This record does not invent an `OR`: both notices and their disclaimers are
retained. For binary redistribution, the BSD notice requires its copyright,
conditions and disclaimer in accompanying documentation or other materials.
The unchanged source/header files ship those texts; the BSD conditions are:

> Copyright 2005 Google Inc. All Rights Reserved.
> Copyright 2010 Google Inc. All Rights Reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are met:
>
> * Redistributions of source code must retain the above copyright notice,
>   this list of conditions and the following disclaimer.
> * Redistributions in binary form must reproduce the above copyright notice,
>   this list of conditions and the following disclaimer in the documentation
>   and/or other materials provided with the distribution.
> * Neither the name of Google Inc. nor the names of its contributors may be
>   used to endorse or promote products derived from this software without
>   specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
> AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
> IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
> ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
> LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
> CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
> SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
> INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
> CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
> ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
> POSSIBILITY OF SUCH DAMAGE.

The inspected Abseil `hash/internal/city.h` is Apache-2.0, not assumed MIT
from the separate CityHash project's licence. The `s2predicates.cc:270–273`
OpenSSL/BSD and former-MPFR/LGPL comment is not a bundled OpenSSL or MPFR
licence grant: no such library is compiled or linked here.

### The conditions, and how this package meets them

| §4 condition | Obligation | How this package meets it |
|---|---|---|
| keep all copyright, patent, trademark and attribution notices | reproduce them | `LICENSE` and `NOTICE` are carried verbatim at the package root; `vendor/abseil-cpp/LICENSE` and `vendor/abseil-cpp/AUTHORS` are carried verbatim in the vendored tree. `README.zig.md` and this file name the copyright holder for each work. |
| include a copy of the Licence | ship the text | Both full Apache-2.0 texts ship, and `build.zig` installs `src/s2` and `vendor/abseil-cpp/absl` header trees that sit beside them. `package.nix` installs `LICENSE`, `NOTICE`, `AUTHORS`, `CONTRIBUTORS`, `NOTICE.md`, `FORK-LICENSE.md`, Abseil's `LICENSE` and `AUTHORS` and the pinned Zig compiler's MIT terms together under `share/licenses/s2geometry/`, so a Nix consumer receives every text this package can reach in one directory. On an ELF **shared** build `build.zig` installs three more there, verbatim from the compiler's own tree: `LICENSE.libcxx.txt`, `LICENSE.libcxxabi.txt` and `LICENSE.libunwind.txt`, covering the `libs2cpp.so.0` that build ships |
| mark modified files as changed | say what changed | **Exactly eight upstream files are modified**: one under `src/` and seven under `vendor/abseil-cpp/`. Every one retains its Apache-2.0 header verbatim and carries a prominent change notice; the per-file paths, the pristine and current digests and the notice wording are disclosed below and in `UPSTREAM.sha256`, and CI enforces that exact 1 + 7 set against freshly pinned canonical archives. The separate inherited workflow deletion is also disclosed. Fork-authored files are listed below and are licensed Apache-2.0 by the owner's authorization of 2026-10-04 (`FORK-LICENSE.md`), a grant separate from upstream's that reaches none of upstream's files |
| retain all notices in the NOTICE file | ship the NOTICE | Shipped verbatim. This file adds the Abseil attribution Abseil does not ship for itself. |
| give any prominent notices in the Work a fair chance to appear | surface them | `README.md` and `README.zig.md` open by naming both upstreams, their licences and their revisions before describing anything about this fork. |

### Apache-2.0 patent grant and termination

Both shipped `LICENSE` texts, §3 (`:74-88`), grant a **perpetual** Contributor
patent licence, subject to the licence terms, for claims necessarily infringed
by its Contributions alone or with the Work. There is **no 12-month expiry**.
If **You** institute patent litigation against any entity, including a
cross-claim or counterclaim, alleging that the Work or an incorporated
Contribution infringes a patent, patent licences granted to You for that Work
terminate on the filing date. Redistributing the licence does not remove this
clause. This file states the shipped Apache-2.0 terms, not a separate Google
policy or a new grant over fork-authored files.

The related trademark carve-out is honoured: neither `LICENSE` nor this package
grants any right to use the names or logos of Google, of the S2 Geometry
Library, or of Abseil, other than as required to reproduce the notices above.

### The "changes are indicated" obligation, precisely

Apache-2.0 §4(b) requires modified files to carry prominent notices stating that
you changed them. This package's position is:

* `src/**` — **exactly one modified file**, an authorised bounded portability
  correction:

  | Path | Change |
  |---|---|
  | `src/s2/util/math/exactfloat/bignum.cc` | `std::from_chars` receives the string view's character pointers (`s.data()`, `s.data() + s.size()`) rather than `s.cbegin()`/`s.cend()` iterators, whose type is implementation-specific |

* `vendor/abseil-cpp/**` — **exactly seven modified files**, authorised bounded
  portability corrections:

  | Path below `vendor/abseil-cpp/` | Change |
  |---|---|
  | `absl/base/internal/direct_mmap.h` | Linux Hexagon uses the real `mmap2` syscall with fixed 4096-byte offset units, not byte offsets or `AT_PAGESZ` units |
  | `absl/base/internal/low_level_alloc.cc` | On WASI, arena backing regions come from real SDK libc `posix_memalign` instead of `mmap`; each region keeps its base pointer, so distinct regions are never coalesced and split blocks keep their owner |
  | `absl/base/internal/low_level_alloc.h` | WASI is exempted from `ABSL_LOW_LEVEL_ALLOC_MISSING`, and the comment above that guard now says where backing memory actually comes from |
  | `absl/debugging/internal/stacktrace_powerpc-inl.inc` | PowerPC32 musl reads embedded `gregs`; the glibc and PowerPC64 branches remain intact |
  | `absl/debugging/internal/examine_stack.cc` | Read the real hosted Hexagon program counter and PowerPC32 musl register context |
  | `absl/log/internal/conditions.h` | Hosted Linux Hexagon includes the existing `unistd.h` declaration of `_exit`; the freestanding/Windows branch remains |
  | `absl/time/internal/cctz/src/time_zone_format.cc` | NetBSD joins FreeBSD and OpenBSD in keeping its native locale namespace, instead of having `_XOPEN_SOURCE 500` selected for SUSv2 before libc++ |

* `.github/workflows/build.yml` — **one deleted file**, not a modified one.
  §4(b) speaks of modification, and a deletion of an inherited CI workflow is
  disclosed in three places regardless.

**The notice wording differs per path, and that is deliberate.** Six Abseil
files carry `Foundation fork change (2026-10-02): …`; the CCTZ NetBSD guard and
the S2 pointer-iterator fix carry `foundation-libs portability change: …`. Both
are prominent notices under §4(b): each sits immediately below the retained
licence header, within the file's first twenty-two lines. Neither wording is
restyled onto the other, because the files already differ and rewriting six of
them to match the two newest would change bytes that no portability question
asked about. CI models the variant **per path**, so a path that loses its
notice, or takes another path's wording, fails.

**What CI enforces.** Both upstream trees are extracted from a `git archive` of
their pinned commit, each at the canonical archive digest recorded in
`UPSTREAM.md`, then compared whole: every file, directory and symlink target,
keyed by relative path. The check rejects an extra path, a missing path, a
deleted or renamed path, any byte change inside a disclosed path, an altered or
removed licence header, and a missing or non-prominent notice. A whole-tree
comparison against freshly pinned canonical trees found exactly these eight
paths, with no extra and no missing path
(`local://foundation-portability-canonical-source-provenance.json`). Pristine
and current digests are paired for all eight in `UPSTREAM.sha256`.

That is an observed eight-file delta, **not** a pristine-tree pass. The earlier
whole-vendor exit-0 receipt 286, which found zero differences, and the later
four-file-delta comparison in
`local://foundation-cross-test-s2-approved-vendor-diff.json` are **history**:
both predate the CCTZ, `low_level_alloc` and `bignum.cc` corrections, and
neither describes the current tree. The canonical archive digests are
6e49b320921abbf0294d783c30aad94fc73f4b04f5b8de6d3d9409024e393b20 for
s2geometry and
8b39fdb7c4a5d7ef0ee88b0b4eb3d23c77623d6f793579a5e0d0af7cf2ce6eaa for Abseil.

**Two prior claims are withdrawn.** Earlier revisions of this file stated that
`src/` was byte-identical to the pin and that the CI step
`git diff --exit-code c24b368c67d0b8a2a109c5a75224e73a856bd8b7 -- src` was the
direct check. The first is now false: `bignum.cc` is modified, with the reason
in the table above. The second no longer exists: a zero-diff check cannot
express "exactly these paths", so it passed only while nothing at all was
modified and would fail on the very file a disclosed fix is about. It is
replaced by the canonical-archive comparison described above, whose digest pins
and exact-set rule are in `UPSTREAM.md`.

## What this fork changed

Every file below is this fork's own. None of them existed upstream.

### Build definition

| File | What it is |
|---|---|
| `build.zig` | the Zig 0.16 build: three native libraries, the public module, five entry points, six-target `check`, and — on an ELF target with `-Dlinkage=dynamic` only — a fourth, runtime-only object compiled from the build compiler's own C++ sources. `static` is this package's linkage policy and the default; `-Dlinkage=static\|dynamic` selects the delivery, is exercised by the sixteen native cells recorded in `FORK-NOTES.md`, and reaches the packaging through `package.nix`, whose own derivation is still `PENDING-VERIFICATION` |
| `build.zig.zon` | the package manifest: `.name`, `.fingerprint`, `.version = "0.14.0"`, `.paths` |
| `cross-test.profile.sh` | this fork's `cross-test` profile: the build step (`test`) and two build defaults for the published 53-platform matrix. Variable assignments only — no target list, no runner policy, no machine path |
| `build_support/s2_sources.zig` | the 108 upstream S2 translation units, enumerated, with their provenance |
| `build_support/absl_sources.zig` | the 153 Abseil translation units, enumerated, with their provenance |
| `build_support/platform_flags.zig` | every compiler flag, with the upstream line each one comes from |
| `build_support/wasi_provider.zig` | the external WASIp1-threads C/C++ provider configuration: the `-Dwasi-sysroot=…` option, the SDK 34 header, library and EH-archive paths, the per-module `single_threaded = false` decision, and the libc++/libunwind link closure. It supplies real providers and invents none: with no sysroot it configures nothing at all |
| `build_support/cpp_runtime.zig` | the ELF shared route's C++ runtime: the pinned compiler's libc++, libc++abi and libunwind unit lists, their feature macros (`_LIBCPP_ABI_VERSION=1`, `_LIBCPP_ABI_NAMESPACE=__1`, hardening `NONE`) and the visibility configuration that gives the object a real export surface, built as `libs2cpp.so.0` and installed with its three verbatim `LICENSE.TXT` files. It reads the compiler's own `lib` tree at build time and edits nothing |
| `build_support/wasi_stdlib.patch` | the two-hunk fork repair of the pinned Zig 0.16.0 standard library — `std/heap.zig` and `std/Io/Threaded.zig` — with each hunk's reason and the patch's licensing in its own header. Its MIT context travels in `zig-0.16-LICENSE.txt` |
| `build_support/zig-0.16-LICENSE.txt` | **not fork-authored.** A verbatim copy of the pinned compiler's own MIT Expat licence text, "Copyright (c) Zig contributors", carried because the patch above modifies two files that text covers. It is a licence record rather than a build input, and it is the one file in `build_support/` that `UPSTREAM.sha256` records |
| `.gitignore` | this fork's ignore rules, appended to upstream's |
| `.github/workflows/verify.yml` | this fork's CI, four jobs: licence/provenance integrity, native gates, the six-target cross matrix, and two consumers compiled and run against the install set alone |
| `package.nix` | the one source-only Nix derivation both `flake.nix` and `devenv.nix` call, with injected `zig` and a `linkage` argument. It filters the source so no cache, VCS directory or output reaches the store, checks the requested variant's libraries and the public header closure, and fills in `lib/pkgconfig/s2geometry.pc` and `share/licenses/s2geometry/` only while the build graph does not install those paths itself |
| `flake.nix` | `packages.<system>.static`, `.shared` and `.default` (the existing static policy), plus a `devShells.default` that imports `devenv.nix`. It adds no build logic and writes no lock |
| `devenv.nix` | the canonical development shell: the pinned Zig 0.16.0 toolchain and three tools, lazy `outputs.static`/`outputs.shared` built on request, no override of the caller's scratch variables, and one `assertion` on the Zig version |
| `devenv.yaml` | the pinned devenv nixpkgs input, one revision |
| `.envrc` | `use devenv`, for direnv |

### The C bridge

| File | What it is |
|---|---|
| `zig/bridge.h` | 93 `extern "C"` entry points over upstream's C++ types, each citing the upstream `file:line` it wraps. Installed as `include/s2geometry_bridge.h`. |
| `zig/bridge.cc` | the implementation: a validation with ordinary comparisons, then exactly one upstream call. Catches `std::bad_alloc` and nothing else. Every loop and polygon it constructs carries a deferred-validation override so upstream's fatal loop-validity check never runs on caller data, and the two polygon booleans bind the `S2Error`-reporting overloads so an upstream failure is a returned status rather than an abort. |

### The Zig facade

| File | What it is |
|---|---|
| `zig/root.zig` | the public `s2geometry` module: 104 public methods over `Point`, `LatLng`, `CellId`, `BoundUV`, `Cell`, `Cap`, `LatLngRect`, `Loop`, `Polygon` and `Coverer`, plus `pub const c` as the raw escape hatch. It bounds a `usize` index on its own side of the narrowing into the bridge's C `int`, so an out-of-range index is a returned `error.InvalidArgument` rather than a panic |

### The runtime route

| File | What it is |
|---|---|
| `runtime/loader.zig` | the reusable loader half: `LoadSource`/`LoadError`, the readiness flag and its ordinary panic, the process-global attempt state machine, and the platform layer (`dlopen`/`dlsym`, `dlclose`) |
| `runtime/library.zig` | this SDK's side of that loader: the synchronization names it supplies and what it requires of a provider beyond resolving its symbols. The file another SDK replaces |
| `runtime/generate.zig` | the build-time generator: reads what `b.addTranslateC` actually produced and writes the dispatch module, so no native name in the dispatch is hand-written |
| `runtime/graph.zig` | the build half: the four modules and two generated files, and the one loader-core instance per configuration |
| `runtime/sync.c`, `runtime/sync.h` | the process-global mutex, condition variable and thread identity the loader needs, weakly defined per `RT_SYNC_PREFIX` so two SDKs in one binary keep distinct symbols |

### Tests, example, consumer

| File | What it is |
|---|---|
| `tests.zig` | 46 behavioural tests: 39 whose expected values are an independent published answer or a geometric identity, and 7 permanent regressions for defects that probes found in this fork's own bridge. No upstream test is modified or removed |
| `smoke.zig` | the deterministic runnable program `zig build smoke` executes |
| `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig` | a separate package that consumes this one by path through `dep.module("s2geometry")` |

### The independent fixture oracles

These are not upstream's bytes, and they are not a licence question either —
they are transcribed data, and they are hashed in `UPSTREAM.sha256` because a
silent edit to one of them would move the oracle rather than break a build.
Every row carries its source and line in the file's own header.

| File | Rows | Transcribed from | Credit |
|---|---|---|---|
| `testdata/golang_cellid_tokens.tsv` | 32 token/id pairs + 5 malformed | `github.com/golang/geo`, `s2/cellid_test.go`, `TestCellIDTokensNominal` and `TestCellIDFromTokensErrorCases` | golang/geo, Google Inc., BSD-3-Clause — an independent reimplementation of the same codec, used as the oracle for the S2 codec |
| `testdata/golang_cellid_latlng.tsv` | 14 leaf-cell id ↔ lat/lng pairs | `github.com/golang/geo`, `s2/cellid_test.go`, `TestCellIDLatLng`, whose own comment records that the rows came from the C++ `s2cellid2latlngtestcase` program | golang/geo, Google Inc., BSD-3-Clause; the underlying data is Google Inc.'s |
| `testdata/upstream_neighbors.tsv` | 17 rows in six row kinds | `src/s2/s2cell_id_test.cc`, `src/python/s2geometry_test.py`, and two golang/geo tables | Google Inc. and golang/geo |
| `testdata/upstream_coverer_sydney.txt` | 2 coordinates, 4 options, 42 level-22 tokens | `src/s2/s2region_coverer_test.cc`, `TEST(JavaCcConsistency, CheckCovering)` | Google Inc. |
| `testdata/upstream_polar_closure.tsv` | 4 rows | `src/s2/s2latlng_rect_test.cc`, `TEST(S2LatLngRect, PolarClosure)` | Google Inc. |
| `testdata/golang_latlng_normalize.tsv` | 9 normalization + 10 validity rows | `github.com/golang/geo` `s2/latlng_test.go` `TestLatLngNormalized`, and `src/s2/s2latlng_test.cc` | golang/geo, Google Inc., BSD-3-Clause |

golang/geo (`github.com/golang/geo`) is licensed BSD-3-Clause, copyright The Go
Authors. Its licence text is **not** redistributed here, because none of its
source is redistributed: only a small number of published numeric answers are
quoted as test data, each attributed at the point of use. If this package is
ever made to carry golang/geo source, `LICENSE-BSD-3-CLAUSE-go` must be added
and this section rewritten; that is stated here so the omission is a recorded
decision rather than an oversight.

### This fork's own records

| File | What it is |
|---|---|
| `UPSTREAM.md` | what this is a fork of, the archive receipt, the import mechanism, the sync procedure |
| `UPSTREAM.sha256` | 927 current-byte SHA-256 records, including the eight disclosed upstream deviations (one `src/` file, seven Abseil files) with each pristine digest kept beside its current digest, and the Zig compiler licence copy in group J. Historical `.paths` gap: 923 `OK` and three missing files at receipt 334, closed at 425. Final source/fetched integrity and package identity belong to `FORKS.json.cross_test_wave.materialized_packages.s2geometry` and `local://foundation-cross-test-package-regression.json`, outside these self-hashing documents |
| `NOTICE.md` | this file |
| `CHANGELOG.md` | numbered fork-only divergences |
| `FORK-NOTES.md` | decisions, what they cost, and the pending list |
| `README.zig.md` | how to build, how to use, every typed operation |
| `README.md` | this fork's README: current native-source deviations, current native-build deviations with dated history, the current build/run/test matrix, and consumption |
| `FORK-LICENSE.md` | the licence of this fork's own files, the owner's authorization and its scope |
| `README.upstream.md` | **not fork-authored.** Upstream's README, byte-preserved at that name since 2026-10-04 (SHA-256 `d91df72a…`) when this fork's README took over the `README.md` path. `UPSTREAM.sha256` records it under that name |

The files in that table are this fork's own records about upstream's work, and
they are licensed Apache-2.0 like the rest of this fork's additions
(`FORK-LICENSE.md`). That does not make them a licence question about upstream:
upstream's terms govern upstream's bytes, and the gap recorded against
`UPSTREAM.sha256` is a packaging disagreement, not a licence question.
`README.upstream.md` is the exception in kind rather than in licence — it is
upstream's own file, listed here because the relocation moved it.

**That packaging gap is now closed.** The record lists `.clang-format`,
`pyproject.toml` and `setup.py`; `build.zig.zon`'s `.paths` did not, so a
dependent that resolved this package received a record it could not fully run —
923 records `OK` and 3 reported missing
(`local://foundation-expansion-s2geometry-materialized-package-integrity-334.log`,
exit 1). Every byte that *was* present matched, so no recorded digest was ever
wrong; the manifest was the incomplete half. `.paths` now names all three, the
package hash changed accordingly, and the record has been **re-run inside the
materialised package and passed: exit 0, 926/926 records `OK`**
(`local://foundation-expansion-s2geometry-current-filtered-integrity-425.log`).
The consumer resolved from that same package is "10/10"
(`…-filtered-consumer-426.log`). Record and manifest agree, and that agreement
is observed rather than asserted.

Receipts 425 and 426 describe the package **before** the currently disclosed
eight native portability changes and the current documents; the 926/926 above is
that earlier package's own count and stays as history. Final filtered fetch,
source/fetched 927-record integrity, profile closure and materialised consumer
status live in the driver-owned ledger above. No current identity, package hash
or replay result is asserted here.

## Cryptographic suitability

Nothing in this package is a cryptographic primitive and nothing here is
suitable for one. Upstream's own `README.upstream.md` and `CMakeLists.txt`
document that the release line is 0.x with "no API or ABI stability guarantees"
and that a 0.x release is explicitly outside SemVer, so the compiled `libs2.a`
and `libs2bridge.a` are not a stable ABI. `UPSTREAM.md` and `build.zig.zon`
record the revision those artifacts were built from, which is what a consumer
has to match for the ABI to be the one it expects.

## See also

* `UPSTREAM.md` — revisions, import mechanism, sync procedure.
* `CHANGELOG.md` — every fork-only divergence, numbered.
* `FORK-NOTES.md` — decisions, costs and the pending list.
* `LICENSE`, `NOTICE`, `AUTHORS`, `CONTRIBUTORS` — upstream's own records.
* `vendor/abseil-cpp/LICENSE`, `vendor/abseil-cpp/AUTHORS` — Abseil's.
* `README.md` — this fork's README: current native-source deviations, current
  native-build deviations with dated history, the current matrix, consumption.
* `FORK-LICENSE.md` — the licence of this fork's own files, and the owner
  authorization behind it.
* `README.upstream.md` — upstream's README, preserved byte-for-byte at its new
  name since 2026-10-04.
