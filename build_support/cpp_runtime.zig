// SPDX-License-Identifier: Apache-2.0
//! One visible libc++/libc++abi for the ELF shared S2 closure.
//!
//! Sources and configuration follow Zig 0.17.0, src/libs/libcxx.zig.
//! Zig's normal static runtime is built with hidden exports. Reusing that
//! archive across images cannot preserve std::locale facet identity. Compile
//! the same shipped sources with their upstream shared-library annotations.
const std = @import("std");

/// Configures headers against the same ABI and feature set as the runtime.
pub fn configureHeaders(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    for ([_][]const u8{ "libcxx", "libcxxabi" }) |directory| {
        // -I precedes the compiler's C system headers. libc++'s own headers
        // mark themselves as system headers after their wrapper is reached.
        module.addIncludePath(compilerPath(b, &.{ directory, "include" }));
    }
    module.addCMacro("_LIBCPP_ABI_VERSION", "1");
    module.addCMacro("_LIBCPP_ABI_NAMESPACE", "__1");
    module.addCMacro("_LIBCPP_HAS_THREADS", "1");
    module.addCMacro("_LIBCPP_HAS_MUSL_LIBC", if (target.result.abi.isMusl()) "1" else "0");
    module.addCMacro("_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS", "0");
    // Match the shared runtime's .fast policy (src/libs/libcxx.zig:addCxxArgs).
    module.addCMacro("_LIBCPP_HARDENING_MODE", "_LIBCPP_HARDENING_MODE_NONE");
    module.addCMacro("_LIBCPP_ASSERTION_SEMANTIC_DEFAULT", "_LIBCPP_ASSERTION_SEMANTIC_IGNORE");
    for ([_][]const u8{
        "_LIBCPP_HAS_MONOTONIC_CLOCK",
        "_LIBCPP_HAS_TERMINAL",
        "_LIBCPP_HAS_FILESYSTEM",
        "_LIBCPP_HAS_RANDOM_DEVICE",
        "_LIBCPP_HAS_LOCALIZATION",
        "_LIBCPP_HAS_UNICODE",
        "_LIBCPP_HAS_WIDE_CHARACTERS",
        "_LIBCPP_HAS_NO_STD_MODULES",
        "_LIBCPP_PSTL_BACKEND_SERIAL",
    }) |macro| module.addCMacro(macro, "1");
    if (target.result.os.tag == .linux) module.addCMacro("_LIBCPP_HAS_TIME_ZONE_DATABASE", "1");
    if (target.result.isGnuLibC()) {
        const glibc_version = target.result.os.versionRange().gnuLibCVersion().?;
        if (glibc_version.order(.{ .major = 2, .minor = 16, .patch = 0 }) == .lt) {
            module.addCMacro("_LIBCPP_HAS_LIBRARY_ALIGNED_ALLOCATION", "0");
        }
    }
}

/// Compiles the pinned compiler's complete threaded ELF C++ runtime as one DSO.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    std.debug.assert(target.result.ofmt == .elf);
    const module = b.createModule(.{
        .target = target,
        .optimize = .fast,
        .link_libc = true,
        .link_libcpp = false,
        .pic = true,
        .single_threaded = false,
        .unwind_tables = .async,
        // Matches the compiler-provided runtime, not the S2/Abseil modules.
        .sanitize_c = .off,
    });
    configureHeaders(b, module, target);
    module.addIncludePath(compilerPath(b, &.{ "libcxx", "src" }));
    module.addIncludePath(compilerPath(b, &.{ "libcxx", "libc" }));
    module.addCMacro("NDEBUG", "1");
    module.addCMacro("_LIBCPP_BUILDING_LIBRARY", "1");
    module.addCMacro("LIBCXX_BUILDING_LIBCXXABI", "1");
    module.addCMacro("_LIBCXXABI_BUILDING_LIBRARY", "1");
    module.addCMacro("_LIBCPP_HAS_NO_PRAGMA_SYSTEM_HEADER", "1");
    module.addCMacro("LIBC_NAMESPACE", "__llvm_libc_common_utils");
    if (target.result.abi.isGnu()) {
        if (target.result.os.tag != .linux or
            target.result.os.versionRange().gnuLibCVersion().?.order(.{ .major = 2, .minor = 18, .patch = 0 }) != .lt)
        {
            module.addCMacro("HAVE___CXA_THREAD_ATEXIT_IMPL", "1");
        }
    }
    // The compiler's libunwind archive also hides its exports. Compile its
    // complete source list here, without _LIBUNWIND_HIDE_SYMBOLS.
    module.addIncludePath(compilerPath(b, &.{ "libunwind", "include" }));
    module.addCMacro("_LIBUNWIND_IS_NATIVE_ONLY", "1");
    if (target.result.cpu.arch.isArm() and target.result.abi.float() == .hard) {
        module.addCMacro("COMPILER_RT_ARMHF_TARGET", "1");
    }
    for (libcxx_files) |source| {
        if (std.mem.startsWith(u8, source, "src/support/win32/")) continue;
        module.addCSourceFile(.{
            .file = compilerPath(b, &.{ "libcxx", source }),
            .flags = &flags,
            .language = .cpp,
        });
    }
    for (libcxxabi_files) |source| {
        module.addCSourceFile(.{
            .file = compilerPath(b, &.{ "libcxxabi", source }),
            .flags = &flags,
            .language = .cpp,
        });
    }
    for ([_][]const u8{
        "libunwind.cpp",
        "Unwind-EHABI.cpp",
        "Unwind-seh.cpp",
        "UnwindLevel1.c",
        "UnwindLevel1-gcc-ext.c",
        "Unwind-sjlj.c",
        "Unwind-wasm.c",
        "UnwindRegistersRestore.S",
        "UnwindRegistersSave.S",
        "gcc_personality_v0.c",
    }) |source| {
        const common = [_][]const u8{
            "-Wa,--noexecstack",
            "-Wno-bitwise-conditional-parentheses",
            "-Wno-visibility",
            "-Wno-incompatible-pointer-types",
        };
        const cpp = common ++ [_][]const u8{ "-fno-exceptions", "-fno-rtti", "-nostdinc++", "-std=c++23" };
        const c = common ++ [_][]const u8{ "-std=c99", "-fexceptions" };
        module.addCSourceFile(.{
            .file = compilerPath(b, &.{ "libunwind", "src", source }),
            .flags = if (std.mem.endsWith(u8, source, ".cpp")) &cpp else if (std.mem.endsWith(u8, source, ".c")) &c else &common,
        });
    }
    module.addRPathSpecial("$ORIGIN");
    return b.addLibrary(.{
        .name = "s2cpp",
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 16, .patch = 0 },
        .root_module = module,
    });
}

/// Installs the runtime's upstream terms beside the SDK's existing notices.
pub fn installLicences(b: *std.Build) void {
    for ([_][]const u8{ "libcxx", "libcxxabi", "libunwind" }) |directory| {
        const install = b.addInstallFileWithDir(
            compilerPath(b, &.{ directory, "LICENSE.TXT" }),
            .prefix,
            b.fmt("share/licenses/s2geometry/LICENSE.{s}.txt", .{directory}),
        );
        b.getInstallStep().dependOn(&install.step);
    }
}

fn compilerPath(b: *std.Build, parts: []const []const u8) std.Build.LazyPath {
    return std.Build.LazyPath.zig_lib.path(b, b.pathJoin(parts));
}

const flags = [_][]const u8{
    "-nostdinc++",
    "-std=c++23",
    "-fvisibility=hidden",
    "-fvisibility-inlines-hidden",
    "-faligned-allocation",
    "-fstrict-aliasing",
    "-Wno-user-defined-literals",
    "-Wno-covered-switch-default",
    "-Wno-suggest-override",
};

// Base plus threaded sources. The compiler
// excludes filesystem/int128_builtins.cpp because compiler-rt provides it,
// and selects the serial PSTL backend rather than libdispatch.
const libcxx_files = [_][]const u8{
    "src/algorithm.cpp",
    "src/any.cpp",
    "src/bind.cpp",
    "src/call_once.cpp",
    "src/charconv.cpp",
    "src/chrono.cpp",
    "src/error_category.cpp",
    "src/exception.cpp",
    "src/expected.cpp",
    "src/filesystem/directory_entry.cpp",
    "src/filesystem/directory_iterator.cpp",
    "src/filesystem/filesystem_clock.cpp",
    "src/filesystem/filesystem_error.cpp",
    "src/filesystem/operations.cpp",
    "src/filesystem/path.cpp",
    "src/fstream.cpp",
    "src/functional.cpp",
    "src/hash.cpp",
    "src/ios.cpp",
    "src/ios.instantiations.cpp",
    "src/iostream.cpp",
    "src/locale.cpp",
    "src/memory.cpp",
    "src/memory_resource.cpp",
    "src/new.cpp",
    "src/new_handler.cpp",
    "src/new_helpers.cpp",
    "src/optional.cpp",
    "src/ostream.cpp",
    "src/print.cpp",
    "src/random.cpp",
    "src/random_shuffle.cpp",
    "src/regex.cpp",
    "src/ryu/d2fixed.cpp",
    "src/ryu/d2s.cpp",
    "src/ryu/f2s.cpp",
    "src/stdexcept.cpp",
    "src/string.cpp",
    "src/strstream.cpp",
    "src/support/win32/locale_win32.cpp",
    "src/support/win32/support.cpp",
    "src/system_error.cpp",
    "src/typeinfo.cpp",
    "src/valarray.cpp",
    "src/variant.cpp",
    "src/vector.cpp",
    "src/verbose_abort.cpp",
    "src/atomic.cpp",
    "src/barrier.cpp",
    "src/condition_variable.cpp",
    "src/condition_variable_destructor.cpp",
    "src/future.cpp",
    "src/mutex.cpp",
    "src/mutex_destructor.cpp",
    "src/shared_mutex.cpp",
    "src/support/win32/thread_win32.cpp",
    "src/thread.cpp",
};

// The exception-enabled non-WASI list, including thread-local destructors.
const libcxxabi_files = [_][]const u8{
    "src/cxa_aux_runtime.cpp",
    "src/cxa_default_handlers.cpp",
    "src/cxa_demangle.cpp",
    "src/cxa_exception_storage.cpp",
    "src/cxa_guard.cpp",
    "src/cxa_handlers.cpp",
    "src/cxa_vector.cpp",
    "src/cxa_virtual.cpp",
    "src/stdlib_exception.cpp",
    "src/stdlib_stdexcept.cpp",
    "src/stdlib_typeinfo.cpp",
    "src/stdlib_new_delete.cpp",
    "src/abort_message.cpp",
    "src/fallback_malloc.cpp",
    "src/private_typeinfo.cpp",
    "src/cxa_exception.cpp",
    "src/cxa_personality.cpp",
    "src/cxa_thread_atexit.cpp",
};
