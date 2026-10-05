//! Compiler flags for s2geometry and for its vendored Abseil, derived from the
//! resolved target rather than from the machine running the build.
//!
//! Every flag below is either copied out of an upstream build definition or
//! justified from the source that needs it.  Where this fork makes a
//! decision upstream does not, the decision is named here.
//!
//! Provenance of the shared flags
//! ------------------------------
//! * `-std=c++17` — `CMakeLists.txt:29-32` sets `CMAKE_CXX_STANDARD 17`,
//!   `CMAKE_CXX_STANDARD_REQUIRED ON` and `CMAKE_CXX_EXTENSIONS OFF`, which is
//!   `-std=c++17`, not `-std=gnu++17`.  `CMakeLists.txt:24-27` explains why the
//!   same standard must be used for Abseil: `ABSL_HAVE_STD_STRING_VIEW` and
//!   friends end up defined differently, which is an ODR error, not a warning.
//! * `-fsized-deallocation` — `CMakeLists.txt:122-127` requires it for
//!   Clang. Windows compile receipt 235 proves it is still necessary with
//!   Zig's Clang 21: bitmap.h:718 and coder.cc:62 explicitly call sized
//!   delete, but the default Windows frontend omits those declarations.
//!   The compiler version alone does not establish target-specific defaults.
//!   It is also applied to the Abseil closure here, which upstream does not
//!   do, because upstream issues it *after*
//!   `FetchContent_MakeAvailable(absl)` and so reaches S2's targets only.
//!   `abslFlags` is `s2Flags` for that reason; see the comment on
//!   `absl_flags`.
//! * `-DABSL_MIN_LOG_LEVEL=1` — `CMakeLists.txt:62`, a directory-scope
//!   `add_definitions` issued *before* `FetchContent_MakeAvailable(absl)`, so
//!   under the `-DFETCH_ABSEIL=ON` path Abseil is compiled with it too.
//!   That is the path this fork replaces, and it matters: `ABSL_MIN_LOG_LEVEL`
//!   changes inline code in `absl/log/log.h`, so Abseil objects and the s2
//!   objects that include those headers must agree.
//! * `-DNOMINMAX` — the only define in `absl/copts/copts.py`'s
//!   `ABSL_GCC_FLAGS` and `ABSL_LLVM_FLAGS` (both lists end with
//!   `# Don't define min and max macros`).  It is unconditional there, so it
//!   is unconditional here.
//! * `-fno-fast-math`, `-ffp-contract=off` — `src/s2/_fp_contract_off.h` says
//!   "S2 requires deterministic arithmetic for correctness", and the file is
//!   named with a leading underscore so it is included first among the s2
//!   headers.  Its `#pragma STDC FP_CONTRACT OFF` is a no-op on compilers that
//!   only implement the GNU form, so the command line carries the requirement
//!   for every translation unit including Abseil's.
//!
//! What is deliberately NOT answered with a flag
//! ----------------------------------------------
//! The recorded Debug run of `zig/bridge.cc` (129 compilation errors, receipt
//! `local://foundation-expansion-s2geometry-repaired-debug-24.log`) also
//! reported `-Wnullability-completeness` diagnostics for every unannotated
//! pointer in the upstream headers, and one `'alignof' applied to an
//! expression is a GNU extension` pair for `alignof(*p)` at
//! `src/s2/s2point_array.h:35,49`.  Neither is answered here, and neither
//! should be: `-Wno-nullability-completeness`, `-Wno-gnu-alignof`, `-w` and
//! `-pedantic-errors` would each silence the same diagnostics in *this*
//! repository's own `zig/bridge.cc`, which is where a real defect has to stay
//! visible, and choosing them would assert a compiler warning policy that no
//! run in this package has established.  The two upstream header trees are
//! compiled as *system* includes on that translation unit instead, which is
//! upstream's own arrangement for this exact situation
//! (`CMakeLists.txt:46-49`, applied at `:285-291`); see `addBridge` in
//! `build.zig`.  The Abseil and S2 libraries themselves keep ordinary include
//! paths, so every upstream translation unit is still diagnosed in full.
//!
//! What is deliberately NOT here
//! -----------------------------
//! * The MSVC branch of `CMakeLists.txt:108-114` (`-J`,
//!   `-D_USE_MATH_DEFINES`, `-DNOMINMAX`).  This package never invokes
//!   `cl.exe`; Zig's C++ frontend is clang on every target.
//! * Abseil's HWAES flags.  `absl/copts/AbseilConfigureCopts.cmake:56-79` selects
//!   `ABSL_RANDOM_HWAES_{X64,ARM64,ARM32}_FLAGS` per processor, but this pinned
//!   Abseil defines no such variable: `absl/copts/GENERATED_AbseilCopts.cmake`
//!   and `absl/copts/copts.py` contain no `HWAES` entry, so
//!   `ABSL_RANDOM_RANDEN_COPTS` expands to nothing for every processor and
//!   upstream compiles `randen_detect.cc`/`randen_hwaes.cc` with no extra ISA
//!   flag.  `absl/random/internal/platform.h:96-105` then derives
//!   `ABSL_HAVE_ACCELERATED_AES` from whatever the compiler already defines, so
//!   the resolved target's CPU features decide it, exactly as upstream.
//!
//! Windows
//! -------
//! `-D_USE_MATH_DEFINES` is added on Windows targets, and this is the one place
//! where the fork extends a flag beyond the condition upstream states it under.
//! Upstream pairs it with `if (MSVC)`; the reason MSVC needs it is that
//! `<math.h>` only defines `M_PI` and friends when the language mode is not
//! strict ANSI or `_USE_MATH_DEFINES` is set, and upstream's own
//! `CMAKE_CXX_EXTENSIONS OFF` means strict ANSI everywhere.  The s2 library
//! uses `M_PI` in `src/s2/s1angle.cc`, `src/s2/s1interval.cc`,
//! `src/s2/s1chord_angle.cc`, `src/s2/s2boolean_operation.cc` and
//! `src/s2/s2buffer_operation.cc`.  With Zig's bundled Windows headers
//! (`lib/libc/include/any-windows-any/math.h`) the guard is the same one, so
//! the define is required for the mingw-gnu target exactly as it is for MSVC.
//!
//! Threads
//! -------
//! `CMakeLists.txt:86` links `Threads::Threads` "for std::thread".  No explicit
//! system library is requested here: every required target gets its thread
//! implementation from the C library Zig already links (`libc` provides
//! `pthread_*` on the POSIX targets and `winpthreads` on windows-gnu).  Adding
//! a `-lpthread` of this fork's own would be a second answer to a question the
//! C library has already answered.

const std = @import("std");
const wasi_provider = @import("wasi_provider.zig");

const s2_flags = [_][]const u8{
    "-std=c++17",
    "-fsized-deallocation",
    "-fno-fast-math",
    "-ffp-contract=off",
    "-DABSL_MIN_LOG_LEVEL=1",
    "-DNOMINMAX",
};
// Abseil's flags are the S2 flags.  `-fsized-deallocation` is the reason the
// two lists are one: `absl/**.h` and `s2/**.h` are one header closure compiled
// into two separate shared objects, and the flag changes the code the compiler
// emits for `delete` on a sized type.  Compiling one image with the flag and
// the other without gives the same inline header function two different
// bodies, and both are `WEAK`/`DEFAULT`, so the dynamic linker is free to bind
// one image's caller to the other image's copy.  A recorded run shows exactly
// that: `absl::Status::Status(Status&&)` 186 bytes in `libabsl.so` against 184
// in `libs2.so`, `absl::flags_internal::Flag<bool>::Get` 487 against 494, and
// `std::string::begin` 113 against 95.
//
// Upstream does not have to state this.  `CMakeLists.txt:80` calls
// `FetchContent_MakeAvailable(absl)` and `CMakeLists.txt:127` adds
// `-fsized-deallocation` afterwards, so upstream's directory-scoped
// `add_compile_options` reaches S2's targets and not Abseil's.  Here both
// closures are compiled by this one graph into artifacts that interpose on
// each other, so they have to agree; the flag is what makes them agree.
const absl_flags = s2_flags;
const s2_windows_flags = s2_flags ++ [_][]const u8{"-D_USE_MATH_DEFINES"};
const absl_windows_flags = absl_flags ++ [_][]const u8{"-D_USE_MATH_DEFINES"};
const s2_wasi_flags = s2_flags ++ wasi_provider.cpp_flags;
const absl_wasi_flags = absl_flags ++ wasi_provider.cpp_flags;

/// True when the resolved target is a Windows target, whatever its ABI.
pub fn isWindows(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows;
}

/// Flags for compiling s2geometry's own sources, and this fork's bridge.
///
/// `zig/bridge.cc` is C++ that includes s2 headers, so it takes the same
/// standard, the same floating-point contract and the same Abseil log level as
/// the library it calls into; a bridge compiled under different floating-point
/// rules than S2 could disagree with the exact predicates it wraps.
pub fn s2Flags(target: std.Build.ResolvedTarget) []const []const u8 {
    return switch (target.result.os.tag) {
        .windows => &s2_windows_flags,
        .wasi => &s2_wasi_flags,
        else => &s2_flags,
    };
}

/// Flags for compiling the vendored Abseil sources.
///
/// Abseil's own warning lists (`ABSL_LLVM_FLAGS`, `ABSL_GCC_FLAGS`) are not
/// reproduced: they are warning selections, they cannot change the artifact,
/// and this fork does not build with `-Werror`.  The one define from those
/// lists that does matter, `NOMINMAX`, is carried, as is the C++ standard and
/// the floating-point contract, which `CMakeLists.txt:24-27` makes a joint
/// requirement of s2 and Abseil.  The deprecation-ABI flag is carried too, for
/// the reason `absl_flags` gives.
pub fn abslFlags(target: std.Build.ResolvedTarget) []const []const u8 {
    return switch (target.result.os.tag) {
        .windows => &absl_windows_flags,
        .wasi => &absl_wasi_flags,
        else => &absl_flags,
    };
}
