# s2geometry

This package builds Google S2 Geometry Library `v0.14.0` with Abseil C++ LTS `20250814.1`.
This package uses a Zig 0.17.0 build graph to compile upstream C++ behind this fork's C bridge and typed Zig facade.

## Source deviations from upstream

Eight upstream source files have bounded portability changes. Their upstream licence headers remain intact.

| Path | Change |
|---|---|
| `src/s2/util/math/exactfloat/bignum.cc` | Pass `string_view` character pointers to `std::from_chars` for portable overload selection. |
| `vendor/abseil-cpp/absl/base/internal/direct_mmap.h` | Use Hexagon `mmap2`'s fixed 4096-byte offset units rather than page-size units. |
| `vendor/abseil-cpp/absl/base/internal/low_level_alloc.cc` | Use SDK `posix_memalign` because WASI lacks `mmap`; track region ownership to prevent invalid coalescing. |
| `vendor/abseil-cpp/absl/base/internal/low_level_alloc.h` | Exempt WASI from the missing-allocator guard; its companion supplies backing memory. |
| `vendor/abseil-cpp/absl/debugging/internal/stacktrace_powerpc-inl.inc` | Read embedded `gregs` because PowerPC32 musl stores registers there. |
| `vendor/abseil-cpp/absl/debugging/internal/examine_stack.cc` | Read hosted Hexagon and PowerPC32 musl register contexts for their native layouts. |
| `vendor/abseil-cpp/absl/log/internal/conditions.h` | Use Linux Hexagon's existing `unistd.h` declaration for `_exit`. |
| `vendor/abseil-cpp/absl/time/internal/cctz/src/time_zone_format.cc` | Preserve NetBSD's native locale namespace, avoiding SUSv2 selection before libc++. |

`UPSTREAM.md` records the pinned trees and per-file changes. The facade adds no S2 algorithm; calculations remain in upstream C++.

## Build deviations

- `build.zig` compiles the source lists in `build_support/s2_sources.zig` and `build_support/absl_sources.zig`. The Abseil list includes upstream `SRCS` and `HDRS`, except test-only and GTest units.
- The graph does not run upstream CMake or Bazel and does not download sources. It builds the C++ libraries, this fork's C bridge and the Zig facade.
- It installs the complete `src/s2` header tree, Abseil headers and `.inc` files, and `s2geometry_bridge.h`.
- Static delivery is the default. Shared delivery adds position-independent code and relocatable runtime paths (`$ORIGIN` on ELF, `@loader_path` on Darwin); Windows resolves DLL dependencies beside each DLL.
- The linked facade and runtime-loaded facade are separate routes. Runtime loading uses an explicit provider and does not change which libraries are delivered.

## Platform support matrix

| Target or mode | Provider and boundary |
|---|---|
| ELF targets | Static or shared delivery. Shared delivery includes `libs2cpp.so.0`, built from the pinned Zig compiler's C++ runtime sources. |
| `x86_64-windows-gnu` | Abseil links `dbghelp`; DLL dependencies resolve beside the DLL that names them. |
| Darwin | CCTZ needs Apple's `CoreFoundation` framework, supplied by an installed Apple SDK. |
| `wasm32-wasi` | Static only; requires a WASI SDK 34+ WASIp1-threads sysroot and the existing patched Zig 0.16.0 standard-library copy, which is not ported to this Zig 0.17.0 package. Wasmtime 46.0.3 is the only version exercised; its `-Sthreads` warning says the flag becomes an error in 47.0.0, and Wasmtime 49+ lacks threads. Smoke output currently traps in Zig's threaded writer. |
| OpenBSD/NetBSD PowerPC | Uses Abseil's unscaled cycle clock; these targets lack the required timebase-frequency query. |
| `-fsys=s2` | Requires an installed `s2geometry` pkg-config package and its S2/Abseil libraries. |

The WASI SDK provides documented `getpid` and signal emulation, not a host PID or POSIX signal semantics. Running WASI binaries also requires a runtime with threads and Wasm exceptions.

## Consumption

### Zig dependency

Add a path dependency in `build.zig.zon`:

```zig
.dependencies = .{
    .s2geometry = .{ .path = "../s2geometry" },
},
```

Import the module in `build.zig`:

```zig
const dep = b.dependency("s2geometry", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("s2geometry", dep.module("s2geometry"));
```

The module is named `s2geometry`. Its linked route supplies the native dependencies. The separate `consumer/` package demonstrates this interface.

### Installed libraries

ELF static archives are `libabsl.a`, `libs2.a` and `libs2bridge.a`; Windows GNU exposes `absl.lib`, `s2.lib` and `s2bridge.lib`. On ELF, shared artifacts use sonames `libabsl.so.2508`, `libs2.so.0` and `libs2bridge.so.0`; ELF shared delivery also installs `libs2cpp.so.0`. The `s2geometry` pkg-config file lists the closure. Include `<s2geometry_bridge.h>` for the C bridge, or use the installed `<s2/...>` and `<absl/...>` C++ headers.

```sh
cc $(pkg-config --cflags s2geometry) main.c $(pkg-config --libs s2geometry)
```

### Build options

| Option | Effect |
|---|---|
| `-Dtarget=<triple>` | Select one target. |
| `-Dlinkage=static\|dynamic` | Select installed artifacts; defaults to `static`. Dynamic linkage is refused when the target has no dynamic linker. |
| `-Druntime=true` | Route facade calls through the explicit runtime loader; independent of linkage. |
| `-fsys=s2` | Link installed S2 and Abseil instead of compiling the bundled core; the fork bridge remains. |
| `-Dwasi-sysroot=<path>` | Supply the WASI SDK 34+ threads sysroot for `wasm32-wasi`. |
| `--zig-lib-dir <dir>` | Select the patched standard-library copy with Zig's standard option. |

`README.zig.md` documents the facade API, ownership and error contracts.