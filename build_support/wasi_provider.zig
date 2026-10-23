//! Complete external WASIp1-threads C/C++ provider configuration.
//! No provider is fetched by this build. WASI SDK 34's EH sysroot supplies
//! filesystem streams, real pthreads and standard Wasm exception unwinding.

const std = @import("std");

pub const cpp_flags = [_][]const u8{
    "-nostdinc++",
    "-fwasm-exceptions",
    "-mllvm",
    "-wasm-use-legacy-eh=false",
};

pub fn resolveTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (target.result.os.tag != .wasi) return target;
    var query = target.query;
    query.cpu_features_add.addFeatureSet(std.Target.wasm.featureSet(&.{
        .atomics,
        .bulk_memory,
        .exception_handling,
        .reference_types,
        .multivalue,
    }));
    // Explicitly disabled features remain disabled and receive the real
    // compiler/linker diagnostic; do not override the caller's CPU contract.
    return b.resolveTargetQuery(query);
}

pub const Provider = struct {
    include_dir: std.Build.LazyPath,
    cpp_include_dir: std.Build.LazyPath,
    common_cpp_include_dir: std.Build.LazyPath,
    lib_dir: std.Build.LazyPath,
    eh_lib_dir: std.Build.LazyPath,
    libc_file: std.Build.LazyPath,

    pub fn init(b: *std.Build, target: std.Build.ResolvedTarget, sysroot: ?[]const u8) ?Provider {
        if (target.result.os.tag != .wasi or target.result.cpu.arch != .wasm32) return null;
        const root = sysroot orelse return null;
        const include = b.pathResolve(&.{ root, "include/wasm32-wasip1-threads" });
        const lib = b.pathResolve(&.{ root, "lib/wasm32-wasip1-threads" });
        return .{
            .include_dir = .{ .cwd_relative = include },
            .cpp_include_dir = .{ .cwd_relative = b.pathResolve(&.{ include, "eh/c++/v1" }) },
            .common_cpp_include_dir = .{ .cwd_relative = b.pathResolve(&.{ root, "include/c++/v1" }) },
            .lib_dir = .{ .cwd_relative = lib },
            .eh_lib_dir = .{ .cwd_relative = b.pathResolve(&.{ lib, "eh" }) },
            .libc_file = b.addWriteFiles().add("wasi-libc.conf", b.fmt(
                "include_dir={s}\nsys_include_dir={s}\ncrt_dir={s}\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n",
                .{ include, include, lib },
            )),
        };
    }

    /// The single place this provider selects a WASI module's threading model.
    ///
    /// Every module links the SDK 34 WASIp1-threads sysroot. Keep Zig's
    /// `std.c._errno` in that libc's shared-memory TLS: Zig 0.17's `.wasi`
    /// implementation uses `private.errnoFromThreadLocal`, which returns
    /// `&private.errno` (`extern threadlocal var errno: c_int`). Leaving
    /// `single_threaded` unset compiles separate storage and gives one binary
    /// two `errno` variables.
    ///
    /// Set this on every module linked against the sysroot.
    pub fn configureModule(self: Provider, module: *std.Build.Module) void {
        module.single_threaded = false;
        module.link_libcpp = false;
        // Preserve fatal UB detection without Zig 0.17's incompatible Wasm UBSan
        // `nonnull_return_v1` handler.
        module.sanitize_c = .trap;
        // Ordinary -I paths put libc++'s C wrappers before builtin C headers;
        // -isystem paths do not have the required search precedence here.
        module.addIncludePath(self.cpp_include_dir);
        module.addIncludePath(self.common_cpp_include_dir);
        module.addIncludePath(self.include_dir);
        module.addLibraryPath(self.lib_dir);
    }

    pub fn linkRuntime(self: Provider, module: *std.Build.Module) void {
        // Link the matching ABI-2 headers/archive closure exactly once via
        // the facade module, never Zig's ABI-1 libc++.
        for ([_][]const u8{ "libc++.a", "libc++abi.a", "libunwind.a" }) |name| {
            module.addObjectFile(self.eh_lib_dir.path(module.owner, name));
        }
        module.addObjectFile(self.lib_dir.path(module.owner, "libwasi-emulated-signal.a"));
        // Zig 0.17's libc-linked nonsecure RNG fallback references getpid.
        // Use the SDK's documented identifier emulation, not a host import;
        // this does not provide host PIDs or independent process namespaces.
        module.addObjectFile(self.lib_dir.path(module.owner, "libwasi-emulated-getpid.a"));
    }
};

pub fn configureCompile(b: *std.Build, compile: *std.Build.Step.Compile, provider: ?Provider) void {
    if (compile.root_module.resolved_target.?.result.os.tag != .wasi) return;
    const actual = provider orelse {
        const missing = b.addFail("UnsupportedWasiProvider: wasm32-wasi requires -Dwasi-sysroot=<complete WASI SDK 34+ sysroot with WASIp1-threads EH C/C++ providers>; bundled libc++ lacks the filesystem/exception closure. No core sources are omitted.");
        compile.step.dependOn(&missing.step);
        return;
    };
    compile.setLibCFile(actual.libc_file);
    // WASI thread spawning instantiates the module again and must import the
    // same shared memory, not allocate a separate memory in each instance.
    compile.import_memory = true;
    compile.export_memory = true;
    compile.shared_memory = true;
    compile.max_memory = 256 * 1024 * 1024;
}
