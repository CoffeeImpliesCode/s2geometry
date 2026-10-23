# Fork licence

**SPDX-License-Identifier: `Apache-2.0`**

This file covers only files authored by this fork. It does not restate or extend
upstream licences: `s2geometry` and Abseil C++ keep their terms and per-file
exceptions; the Zig compiler's C++ runtime, compiled and shipped by one route,
keeps LLVM terms. `NOTICE.md` holds the inventory.

## Authorization

On **2026-10-04** the project's owner authorized a licence for the
fork-authored additions matching the primary upstream terms where appropriate;
for this project that term is Apache-2.0, because both upstreams are. The owner
is the holder of this grant, not either upstream, and no upstream author is
credited with any file below.

The copyright holder is named as the fork's contributors. No individual
identity is invented here: the holder is the project's owner, identified in the
private repository that carries this work.

The Apache-2.0 text is at root `LICENSE`; it is the same text governing
upstream's work.

## Grant covers

Every file upstream did not ship:

| Category | Files |
|---|---|
| Build definition | `build.zig`, `build.zig.zon`, `build_support/s2_sources.zig`, `build_support/absl_sources.zig`, `build_support/platform_flags.zig`, `build_support/wasi_provider.zig`, `build_support/cpp_runtime.zig`, `build_support/wasi_stdlib.patch`, `cross-test.profile.sh`, `.gitignore` |
| C bridge | `zig/bridge.h`, `zig/bridge.cc` |
| Typed facade | `zig/root.zig` |
| Runtime route | `runtime/loader.zig`, `runtime/library.zig`, `runtime/generate.zig`, `runtime/graph.zig`, `runtime/sync.c`, `runtime/sync.h` |
| Tests, example, consumer | `tests.zig`, `smoke.zig`, `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig` |
| Packaging | `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc` |
| Transcribed fixture data | the six files in `testdata/` |
| Records | `README.md`, `README.zig.md`, `CHANGELOG.md`, `FORK-NOTES.md`, `FORK-LICENSE.md`, `NOTICE.md`, `UPSTREAM.md`, `UPSTREAM.sha256` |

## Grant exclusions

* **Upstream source.** `src/` and `vendor/abseil-cpp/` remain under upstream's Apache-2.0 licence. Apache §4(b) requires prominent change notices; `NOTICE.md` lists the eight modified files.
* **Upstream per-file exceptions.** Three compiled headers under `src/s2/util/gtl` carry BSD-3-Clause. CCTZ's compiled `tzfile.h` and retained timezone data carry public-domain notices. `vendor/abseil-cpp/absl/crc/internal/crc.cc` carries third-party source attributions. These terms travel with their files.
* **Upstream records.** `LICENSE`, `NOTICE`, `AUTHORS`, `CONTRIBUTORS`, `vendor/abseil-cpp/LICENSE` and `vendor/abseil-cpp/AUTHORS` are reproduced verbatim.
* **External providers.** The WASI SDK 34 sysroot, Wasmtime and CoreFoundation keep their own terms.
* **C++ runtime built by one route.** `build_support/cpp_runtime.zig` is fork-authored and Apache-2.0. For ELF with `-Dlinkage=dynamic`, it compiles the pinned compiler's shipped libc++, libc++abi and libunwind into `libs2cpp.so.0`; those components remain under Apache License 2.0 with the LLVM exception. No compiler source is copied or edited, and no compiler installation is modified. Their `LICENSE.TXT` files install verbatim as `LICENSE.libcxx.txt`, `LICENSE.libcxxabi.txt` and `LICENSE.libunwind.txt`. The LLVM grant is unaffected by this authorization or by the MIT text for the standard-library patch. `NOTICE.md` records these terms.

## Special paths

**`build_support/wasi_stdlib.patch`** is fork-authored and Apache-2.0. It changes no upstream copyright line, licence line or comment; the edited files retain MIT (Expat), **"Copyright (c) Zig contributors"**. The full text is in `build_support/zig-0.16-LICENSE.txt` and recorded in `UPSTREAM.sha256`. The patched tree is prepared outside this package, selected with the compiler's `--zig-lib-dir`, and not shipped or installed.

**`testdata/`** contains transcriptions of published numeric answers. It is fork-authored and Apache-2.0; each file names its source and credit. Some answers come from golang/geo (BSD-3-Clause, © The Go Authors); no golang/geo source is redistributed.
