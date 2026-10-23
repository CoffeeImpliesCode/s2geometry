# Fork Notes

## Source deviations

| Upstream path | Change and reason |
|---|---|
| `src/s2/util/math/exactfloat/bignum.cc` | Pass `string_view` character pointers to `std::from_chars` for portable overload selection. |
| `vendor/abseil-cpp/absl/base/internal/direct_mmap.h` | Use Hexagon `mmap2` offsets in fixed 4096-byte units because the syscall does not use page-size units. |
| `vendor/abseil-cpp/absl/base/internal/low_level_alloc.cc` | Use SDK `posix_memalign` on WASI because `mmap` is unavailable, and track region bases to prevent invalid frees after coalescing. |
| `vendor/abseil-cpp/absl/base/internal/low_level_alloc.h` | Exclude WASI from the missing-allocator guard because its companion implementation supplies backing memory. |
| `vendor/abseil-cpp/absl/debugging/internal/stacktrace_powerpc-inl.inc` | Read the embedded `gregs` context on PPC32 musl because that ABI stores registers there. |
| `vendor/abseil-cpp/absl/debugging/internal/examine_stack.cc` | Read hosted Hexagon and PPC32 musl register contexts to support their native layouts. |
| `vendor/abseil-cpp/absl/log/internal/conditions.h` | Use hosted Hexagon's existing `unistd.h` declaration for `_exit`, preserving freestanding and Windows branches. |
| `vendor/abseil-cpp/absl/time/internal/cctz/src/time_zone_format.cc` | Keep NetBSD's native locale namespace because `_XOPEN_SOURCE=500` selects SUSv2 before libc++. |

## Build graph

- `build_support/s2_sources.zig` lists S2 translation units in upstream order. `absl_sources.zig` includes upstream `SRCS` and `HDRS` entries, except test-only and GTest units.
- `build.zig` compiles those lists directly. It does not run upstream CMake or Bazel, or fetch source during a build.
- The fork adds `zig/bridge.cc` and `zig/bridge.h` as a C bridge, with `zig/root.zig` as the typed facade. The translated C declarations and upstream headers remain available to consumers.
- C++ sources use upstream flags. Windows adds `-D_USE_MATH_DEFINES`. Only the bridge uses upstream headers as system includes, so diagnostics in fork code remain active.
- `zig build check` compiles the C++ libraries, bridge, facade, tests and example for six targets. It does not run the binaries.
- `-Dlinkage=static` is the default. `-Dlinkage=dynamic` builds shared libraries with ABI versions. The ELF shared route also builds `libs2cpp.so.0.16.0` from the pinned compiler's libc++, libc++abi and libunwind.
- The installed shared graph uses `$ORIGIN` on ELF and `@loader_path` on Darwin. It has no build-cache search path. Windows resolves DLL dependencies beside the DLL that names them.
- `-Druntime=true` selects explicit provider loading through a process-lifetime dispatch table. It is independent of linkage and does not link native archives into the facade.
- `-fsys=s2` keeps the fork bridge and links an installed `s2geometry` pkg-config package instead of compiling bundled S2 and Abseil. It does not inspect or supply that package's dependency closure.
- `package.nix` supplies the static and shared variants for both `flake.nix` and `devenv.nix`. The development shell carries tools only.
- The consumer step runs native/Rosetta targets; the Zig 0.17 configurer cannot read optional emulator flags, so it installs other cross-targets instead.
- Nested consumer installs use the outer build's install prefix, which Zig 0.17 exposes only as a make-time path.
- `build_support/consumer.zig` forwards make-time paths through `ZIG_LIB_DIR` and `ZIG_GLOBAL_CACHE_DIR`; Zig 0.17 rejects their former `zig build` flags.

## Platform boundaries

| Target or mode | Boundary |
|---|---|
| `wasm32-wasi` | The checked-in patch targets Zig 0.16.0's standard library. Dynamic linkage is unavailable. |
| Darwin | CCTZ needs Apple's CoreFoundation framework. The graph declares the framework but does not provide an Apple SDK. |
| Windows | Abseil needs `dbghelp`. The loader resolves DLL dependencies by name beside each DLL. |
| OpenBSD/NetBSD PowerPC | Abseil uses the unscaled cycle clock because these targets lack a supported timebase-frequency query. |
| `-fsys=s2` | Requires installed S2 and Abseil libraries for the selected target. The package does not infer their system dependencies. |

On WASI, the SDK supplies documented `getpid` and synchronous signal emulation, not a host PID or POSIX signal semantics. Async-signal-safe support is unavailable. The smoke program's output path trapped in Zig's threaded `Io.Threaded.fileWritePositional` (observed with Zig 0.16; not rechecked on 0.17).
