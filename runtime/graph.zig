// SPDX-License-Identifier: Apache-2.0
//
//! Builds the runtime-loading module graph and generated dispatch.
//! The runtime branch resolves bridge symbols from an explicit provider, not a linked archive.
//! WASI keeps linked support; dynamic loading returns `UnsupportedTarget`.

const std = @import("std");

const absl_sources = @import("../build_support/absl_sources.zig");
const s2_sources = @import("../build_support/s2_sources.zig");

/// Prefix used by `runtime/sync.c`; it must match the symbols in `runtime/library.zig`.
const sync_prefix = "s2geometry_rt";

/// C-library declarations kept direct instead of resolved from the provider.
/// The pinned MinGW translation adds `__mingw_get_crt_info` and `__prefetch`.
const libc_noise =
    \\__mingw_get_crt_info,__prefetch
;

/// Optional provider symbols; empty because every bridge entry point is required.
const provider_optional = "";

/// Excluded provider symbols; empty because the provider must export the full bridge.
const provider_excluded = "";

/// Creates the loader module for linked builds.
/// Runtime builds re-export the same `LoadSource` and `LoadError` types from their dispatch.
pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("runtime/loader.zig"),
        .target = target,
        .optimize = optimize,
        // The Unix loader calls libc's `dlopen`.
        .link_libc = true,
    });
}

/// Creates the runtime-loaded C module for the selected target.
/// The caller supplies target-specific sysroot and threading settings.
pub fn createModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const core = createCoreModule(b, target, optimize);

    const library = b.createModule(.{
        .root_source_file = b.path("runtime/library.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("rt", core);

    return createDispatchModule(b, translate, target, optimize, core, library);
}

/// Paths to the generated dispatch and patched translation.
const GeneratedSources = struct {
    native: std.Build.LazyPath,
    dispatch: std.Build.LazyPath,
};

fn createDispatchModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    library: *std.Build.Module,
) *std.Build.Module {
    const sources = generateDispatch(b, translate, target);

    // Reuses patched translation types so nested aliases and dispatch share nominal types.
    const native = b.createModule(.{
        .root_source_file = sources.native,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addUpstreamIncludePaths(b, native);

    const dispatch = b.createModule(.{
        .root_source_file = sources.dispatch,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatch.addImport("rt", core);
    dispatch.addImport("library", library);
    dispatch.addImport("c_native", native);
    native.addImport("c_routed", dispatch);
    addUpstreamIncludePaths(b, dispatch);
    dispatch.addCSourceFiles(.{
        .files = &.{"runtime/sync.c"},
        .flags = &.{b.fmt("-DRT_SYNC_PREFIX={s}", .{sync_prefix})},
        .language = .c,
    });
    return dispatch;
}

/// Adds the upstream and Abseil include roots used by the linked module.
fn addUpstreamIncludePaths(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path(s2_sources.include_dir));
    module.addIncludePath(b.path(absl_sources.include_dir));
}

/// Generates dispatch from this target's translated header.
/// Each target and configuration uses its own translation output.
fn generateDispatch(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) GeneratedSources {
    const generator = b.addExecutable(.{
        .name = b.fmt("s2geometry-runtime-generate-{s}", .{
            target.result.zigTriple(b.allocator) catch @panic("unspellable target"),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/generate.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run = b.addRunArtifact(generator);
    run.addArg("--library");
    run.addArg("s2geometry");
    run.addArg("--translate");
    run.addFileArg(translate.getOutput());
    if (libc_noise.len != 0) {
        run.addArg("--noise");
        run.addArg(libc_noise);
    }
    if (provider_optional.len != 0) {
        run.addArg("--optional");
        run.addArg(provider_optional);
    }
    if (provider_excluded.len != 0) {
        run.addArg("--exclude");
        run.addArg(provider_excluded);
    }
    run.addArg("--native-output");
    const native_source = run.addOutputFileArg("native.zig");
    run.addArg("--output");
    const dispatch_source = run.addOutputFileArg("dispatch.zig");
    return .{ .native = native_source, .dispatch = dispatch_source };
}
