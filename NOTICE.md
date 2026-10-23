# NOTICE

This package contains the S2 Geometry Library and Abseil C++ under Apache License 2.0, with the per-path exceptions below. An ELF shared build also ships the Zig compiler's C++ runtime under Apache License 2.0 with the LLVM exception. Fork-authored additions have a separate owner-authorized Apache-2.0 grant in `FORK-LICENSE.md`; it does not cover upstream bytes or compiler runtime code.

## Upstream works

### S2 Geometry Library

```
S2 Geometry Library
Copyright 2017 Google Inc.  All Rights Reserved.

This product includes software developed at
Google (https://www.google.com/).
```

The S2 repository root is imported from `https://github.com/google/s2geometry`, tag `v0.14.0`, commit `c24b368c67d0b8a2a109c5a75224e73a856bd8b7`; the upstream README is preserved as `README.upstream.md`. Its Apache-2.0 text is `LICENSE`; upstream `NOTICE`, `AUTHORS` and `CONTRIBUTORS` are retained. Copyright holders listed in `AUTHORS` are Aurora Innovation, Dan Larkin-York (`dan@arangodb.com`), Google Inc., Koordinates Limited, Mike Playle (`mike@mythik.co.uk`) and Tiago Brito (`tiago.brito@90poe.io`); individual CLA signatories are in `CONTRIBUTORS`. The opening label in `AUTHORS` says “glog”; that upstream text is preserved unchanged.

### Abseil C++

The whole `20250814.1` release is carried at `vendor/abseil-cpp` from `https://github.com/abseil/abseil-cpp`, commit `d38452e1ee03523a208362186fd42248ff2609f6`. It has no `NOTICE`; its `AUTHORS` names Google Inc. Its Apache-2.0 text and attribution record are retained verbatim.

```
# This is the list of Abseil authors for copyright purposes.
#
# This does not necessarily list everyone who has contributed code, since in
# some cases, their employer may be the copyright holder.  To see the full list
# of contributors, see the revision history in source control.
Google Inc.
```

### Zig compiler files and runtime

The Zig 0.16.0 compiler is not redistributed or modified. `build_support/wasi_stdlib.patch` is fork-authored and changes only `std/heap.zig` and `std/Io/Threaded.zig` in an external compiler-library copy. Those compiler files retain their MIT (Expat) terms; their complete licence text, “Copyright (c) Zig contributors”, is copied verbatim to `build_support/zig-0.16-LICENSE.txt`. The patch itself is covered by the fork's Apache-2.0 grant, not by that MIT text.

On ELF with `-Dlinkage=dynamic`, the build compiles the compiler-shipped libc++, libc++abi and libunwind sources into `libs2cpp.so.0.16.0`. Each component keeps the LLVM project's Apache-2.0-with-LLVM-exception terms; its `LICENSE.TXT` is installed verbatim as `LICENSE.libcxx.txt`, `LICENSE.libcxxabi.txt` and `LICENSE.libunwind.txt`. Static, WASI, Darwin and Windows builds do not ship this runtime. The WASI SDK sysroot, Wasmtime and CoreFoundation are not redistributed.

## Upstream changes

Eight upstream source files differ from their pins. Each retains its original licence and copyright header and carries a prominent change notice. The pristine and current digests are paired in `UPSTREAM.sha256`.

| Path | Change |
|---|---|
| `src/s2/util/math/exactfloat/bignum.cc` | Pass `string_view` character pointers to `std::from_chars`. |
| `vendor/abseil-cpp/absl/base/internal/direct_mmap.h` | Use Linux Hexagon `mmap2` with fixed 4096-byte offset units. |
| `vendor/abseil-cpp/absl/base/internal/low_level_alloc.cc` | Use WASI `posix_memalign` regions and preserve allocation ownership. |
| `vendor/abseil-cpp/absl/base/internal/low_level_alloc.h` | Enable the WASI allocator and identify its backing memory. |
| `vendor/abseil-cpp/absl/debugging/internal/stacktrace_powerpc-inl.inc` | Read embedded PowerPC32 musl registers. |
| `vendor/abseil-cpp/absl/debugging/internal/examine_stack.cc` | Read hosted Hexagon and PowerPC32 musl register contexts. |
| `vendor/abseil-cpp/absl/log/internal/conditions.h` | Use the hosted Linux Hexagon `_exit` declaration. |
| `vendor/abseil-cpp/absl/time/internal/cctz/src/time_zone_format.cc` | Preserve NetBSD's native locale namespace. |

## Per-path notices

| Path | Licence or attribution | Distribution/use |
|---|---|---|
| `src/s2/util/gtl/dense_hash_set.h`, `densehashtable.h`, `hashtable_common.h` | Apache-2.0 and BSD-3-Clause; Google Inc. copyrights | Compiled headers, installed with S2 headers. |
| `vendor/abseil-cpp/absl/time/internal/cctz/src/tzfile.h` | Public-domain declaration by Arthur David Olson, clarified 1996-06-05 | Included by CCTZ and installed. |
| `vendor/abseil-cpp/absl/time/internal/cctz/testdata/zoneinfo/iso3166.tab`, `zone1970.tab`, `zonenow.tab` | Public-domain declarations and Paul Eggert source attributions | Retained timezone data. |
| `vendor/abseil-cpp/absl/base/spinlock_test_common.cc` | Apache-2.0 file; public-domain `lookup2` attribution to Bob Jenkins | Retained, not compiled. |
| `vendor/abseil-cpp/absl/crc/internal/crc.cc` | Apache-2.0; method attributed to Andrew Kadatch and Bob Jenkins | Compiled Abseil source. |
| `vendor/abseil-cpp/absl/hash/internal/city.h` | Apache-2.0 | No separate CityHash licence is assumed. |

The three S2 headers retain both Apache-2.0 and BSD-3-Clause notices. The BSD-3-Clause text follows verbatim:

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

The comments in `src/s2/s2predicates.cc` mention OpenSSL/BSD and former MPFR/LGPL; neither library is compiled or linked here, and no separate licence grant is included for them.

The six fixture files in `testdata/` are fork-authored transcriptions of published numeric answers, covered by the fork grant. Their sources and credits are:

| File | Source and attribution |
|---|---|
| `testdata/golang_cellid_tokens.tsv` | `github.com/golang/geo/s2/cellid_test.go`; golang/geo, Google Inc., BSD-3-Clause. |
| `testdata/golang_cellid_latlng.tsv` | `github.com/golang/geo/s2/cellid_test.go`; golang/geo and Google Inc. |
| `testdata/upstream_neighbors.tsv` | S2 and golang/geo test tables; Google Inc. and golang/geo. |
| `testdata/upstream_coverer_sydney.txt` | S2 `s2region_coverer_test.cc`; Google Inc. |
| `testdata/upstream_polar_closure.tsv` | S2 `s2latlng_rect_test.cc`; Google Inc. |
| `testdata/golang_latlng_normalize.tsv` | golang/geo and S2 lat/lng tests; golang/geo and Google Inc. |

Only published numeric answers are transcribed; no golang/geo source is redistributed, so its BSD-3-Clause licence text is not included.

## Fork-authored files

The owner-authorized Apache-2.0 grant in `FORK-LICENSE.md` covers the fork-authored additions below, not upstream bytes. It does not cover the compiler's C++ runtime or the external patched Zig standard-library files. The `build_support/zig-0.16-LICENSE.txt` file is a verbatim compiler MIT licence copy, not a fork-authored file. The moved `README.upstream.md` is upstream's file and is not covered by the fork grant.

| Group | Covered files |
|---|---|
| Build | `build.zig`, `build.zig.zon`, `cross-test.profile.sh`, `build_support/s2_sources.zig`, `build_support/absl_sources.zig`, `build_support/platform_flags.zig`, `build_support/wasi_provider.zig`, `build_support/cpp_runtime.zig`, `build_support/wasi_stdlib.patch`, fork-added `.gitignore` entries, `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc`. |
| C bridge and facade | `zig/bridge.h`, `zig/bridge.cc`, `zig/root.zig`. |
| Runtime | `runtime/loader.zig`, `runtime/library.zig`, `runtime/generate.zig`, `runtime/graph.zig`, `runtime/sync.c`, `runtime/sync.h`. |
| Tests and consumer | `tests.zig`, `smoke.zig`, `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig`. |
| Fixtures | `testdata/golang_cellid_tokens.tsv`, `testdata/golang_cellid_latlng.tsv`, `testdata/upstream_neighbors.tsv`, `testdata/upstream_coverer_sydney.txt`, `testdata/upstream_polar_closure.tsv`, `testdata/golang_latlng_normalize.tsv`. |
| Records | `README.md`, `README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `FORK-LICENSE.md`, `NOTICE.md`, `UPSTREAM.md`, `UPSTREAM.sha256`. |

The upstream records `LICENSE`, `NOTICE`, `AUTHORS`, `CONTRIBUTORS`, `vendor/abseil-cpp/LICENSE` and `vendor/abseil-cpp/AUTHORS` are retained verbatim and are not covered by the fork grant. The grant also does not extend to upstream files under `src/` or `vendor/abseil-cpp/`; their Apache-2.0 terms and embedded per-path exceptions remain in force.
