//! A package that consumes `s2geometry` from outside the package that defines
//! it.
//!
//! On native targets a dependent needs only a path dependency and
//! `dep.module("s2geometry")` to get a correctly linked library.
//! The consumer writes no include path, links no library and knows nothing about
//! the bridge, the C++ archive or Absl; if the facade module stopped carrying
//! its artifacts, or the translated header stopped matching the compiled
//! library, this program would stop building or stop producing the answers
//! below, and nothing inside the library would notice.
//! WASI additionally inherits two things it cannot derive for itself: the
//! library module's threading model, which is a `std.Build.Module` field and so
//! has to be copied rather than imported, and the provider's final-link
//! configuration from `s2bridge`, because std.Build keeps libc_file and the
//! memory flags on `std.Build.Step.Compile` rather than propagating them
//! through a module import. Headers and C/C++ runtime archives remain
//! SDK-owned.
//!
//! Run it with `zig build run`; anything after that command's `--` is passed
//! to the program.  It exits non-zero if any answer disagrees with the value
//! google/s2geometry or golang/geo publishes for that input, so it is a check
//! and not a demo.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wasi_sysroot = b.option([]const u8, "wasi-sysroot", "Complete WASI SDK 34+ WASIp1-threads EH sysroot");

    const dep = if (wasi_sysroot) |root|
        b.dependency("s2geometry", .{
            .target = target,
            .optimize = optimize,
            .@"wasi-sysroot" = root,
        })
    else
        b.dependency("s2geometry", .{
            .target = target,
            .optimize = optimize,
        });

    // No `link_libc` and no `link_libcpp` here on purpose. Those requirements
    // belong to the library module, which carries them; a dependent states its
    // own, and this program needs nothing beyond what the library already
    // brings. Adding either here would hide a library that forgot to declare it.

    // The library module, not a copy of its settings: this root shares the
    // provider's libc, and std.Build propagates neither `single_threaded` nor
    // `libc_file` through a module import.  The WASI threading model is one
    // property of that module (`wasi_provider.Provider.configureModule` sets it
    // on every module it configures), and `Module.single_threaded` is a plain
    // field, so the dependent root reads it from the module it actually links
    // instead of restating it.  On every other target the library module leaves
    // it null, and so does this one.
    const s2_module = dep.module("s2geometry");
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = s2_module.resolved_target,
        .optimize = optimize,
    });
    exe_mod.single_threaded = s2_module.single_threaded;
    exe_mod.addImport("s2geometry", s2_module);

    const exe = b.addExecutable(.{
        .name = "s2geometry_consumer",
        .root_module = exe_mod,
    });
    // The provider's link-time settings, copied from the artifact that already
    // carries them: std.Build holds these on `Step.Compile`, not on `Module`,
    // so a module import never propagates them.
    if (target.result.os.tag == .wasi) {
        const bridge = dep.artifact("s2bridge");
        exe.setLibCFile(bridge.libc_file);
        exe.import_memory = bridge.import_memory;
        exe.export_memory = bridge.export_memory;
        exe.shared_memory = bridge.shared_memory;
        exe.max_memory = bridge.max_memory;
    }
    b.installArtifact(exe);

    // This package's arguments are the program's, and this is the only place
    // that hands them over.  Driven directly, `zig build run -- …`.  Driven by
    // the `consumer` step of the package that depends on this one, that build
    // forwards its own `b.args` after a `--`, which is why the step below
    // forwards them rather than inventing arguments of its own.
    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    b.step("run", "Build and run the consumer program").dependOn(&run_exe.step);
}
