# UPSTREAM

This package builds the upstream S2 Geometry Library through a Zig build, C bridge and typed Zig facade. It carries S2 and its pinned Abseil dependency, with eight disclosed portability changes to upstream source.

## Pinned upstream trees

| Project | Upstream identity | Licence and scope |
|---|---|---|
| S2 Geometry Library | `https://github.com/google/s2geometry`, tag `v0.14.0`, commit `c24b368c67d0b8a2a109c5a75224e73a856bd8b7` | Apache License 2.0; three compiled `src/s2/util/gtl` headers also retain BSD-3-Clause text. |
| Abseil C++ | `https://github.com/abseil/abseil-cpp`, LTS release `20250814.1`, commit `d38452e1ee03523a208362186fd42248ff2609f6` | Apache License 2.0; CCTZ and retained test-data exceptions are listed in `NOTICE.md`. |

S2's tag is the upstream version. The Abseil release is the version selected by S2's CMake dependency declaration. Both source trees are imported whole: S2 at the package root and Abseil at `vendor/abseil-cpp`.

## Source acquisition and layout

The S2 source tree was acquired from a `git archive` of its pinned commit. Abseil's `20250814.1` release was unpacked whole from its pinned commit. There is no import script or submodule. Upstream's `README.md` is preserved byte-for-byte as `README.upstream.md`; the fork's README occupies `README.md`.

The SHA-256 archive digests identify each pinned commit's tree as serialized by `git archive`; they are not Git object IDs or digests of this working tree.

| Tree | Archive SHA-256 |
|---|---|
| S2 Geometry Library | `6e49b320921abbf0294d783c30aad94fc73f4b04f5b8de6d3d9409024e393b20` |
| Abseil C++ | `8b39fdb7c4a5d7ef0ee88b0b4eb3d23c77623d6f793579a5e0d0af7cf2ce6eaa` |

### Removed or relocated upstream paths

- `.github/workflows/build.yml` — removed.
- `README.md` — relocated byte-for-byte to `README.upstream.md`.

## Upstream source changes

Exactly eight upstream source files differ from the pins. Each retains its upstream licence and copyright header and carries a prominent change notice. `UPSTREAM.sha256` records the pristine and current digests for each.

| Path | Change and reason |
|---|---|
| `src/s2/util/math/exactfloat/bignum.cc` | Pass `string_view` character pointers to `std::from_chars`, avoiding implementation-specific iterator conversion. |
| `vendor/abseil-cpp/absl/base/internal/direct_mmap.h` | Use Linux Hexagon `mmap2` with fixed 4096-byte offset units. |
| `vendor/abseil-cpp/absl/base/internal/low_level_alloc.cc` | Back WASI arena regions with SDK libc `posix_memalign` and preserve region ownership. |
| `vendor/abseil-cpp/absl/base/internal/low_level_alloc.h` | Enable the WASI allocator and state its backing-memory source. |
| `vendor/abseil-cpp/absl/debugging/internal/stacktrace_powerpc-inl.inc` | Read embedded PowerPC32 musl registers while retaining glibc and PowerPC64 paths. |
| `vendor/abseil-cpp/absl/debugging/internal/examine_stack.cc` | Read hosted Hexagon and PowerPC32 musl register contexts. |
| `vendor/abseil-cpp/absl/log/internal/conditions.h` | Use the hosted Linux Hexagon `_exit` declaration. |
| `vendor/abseil-cpp/absl/time/internal/cctz/src/time_zone_format.cc` | Preserve NetBSD's native locale namespace. |

## Integrity record

`UPSTREAM.sha256` contains 927 current-byte records for selected source, installed headers, licences, build/dependency records and independent test fixtures. It pairs pristine and current digests for the eight modified upstream source files. The record excludes external compiler and SDK files that are not carried in this package.
