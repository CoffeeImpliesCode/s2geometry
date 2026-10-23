const std = @import("std");

/// Runtime dispatch and loader-core module constructors.
/// Each configuration must use one core instance so its public types stay identical.
const graph = @import("runtime/graph.zig");

const absl_sources = @import("build_support/absl_sources.zig");
const platform_flags = @import("build_support/platform_flags.zig");
const wasi_provider = @import("build_support/wasi_provider.zig");
const s2_sources = @import("build_support/s2_sources.zig");
const cpp_runtime = @import("build_support/cpp_runtime.zig");

/// Upstream S2 version from the source list.
const s2_version = s2_sources.version;

const s2_commit = s2_sources.commit;
const absl_version = absl_sources.version;
const absl_commit = absl_sources.commit;

/// Package version metadata, validated against the source list at comptime.
const manifest = @import("build.zig.zon");

const package_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

/// S2 uses upstream's `PROJECT_VERSION_MAJOR` as its ABI major (CMakeLists.txt:294-296).
/// The minor and patch follow this package's version.
const s2_abi_version: std.SemanticVersion = .{ .major = 0, .minor = 14, .patch = 0 };

/// Abseil's shared ABI major comes from `ABSL_SOVERSION` (vendor/abseil-cpp/CMakeLists.txt:27).
const absl_abi_version: std.SemanticVersion = .{ .major = 2508, .minor = 0, .patch = 0 };

/// The fork bridge uses S2's ABI major; upstream has no bridge artifact.
const bridge_abi_version: std.SemanticVersion = .{ .major = 0, .minor = 14, .patch = 0 };

/// ABI version of the compiler-sourced C++ runtime, not the package.
/// Keep it aligned with `build_support/cpp_runtime.zig`.
const cpp_runtime_version: std.SemanticVersion = .{ .major = 0, .minor = 16, .patch = 0 };

/// pkg-config package name consumed by system mode.
const system_pkg_config_module = "s2geometry";

/// Targets compiled by `check` when no target option is named.
/// `aarch64-macos-none` is the ordinary macOS ABI in Zig 0.17.0.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// Detects explicit target options; `-Dtarget=native` resolves like no option.
/// Keep these names aligned with `standardTargetOptionsQueryOnly`.
fn target_was_named(b: *const std.Build) bool {
    for ([_][]const u8{ "target", "cpu", "ofmt", "dynamic-linker" }) |name| {
        if (b.user_input_options.contains(name)) return true;
    }
    return false;
}

const Graph = struct {
    absl_lib: *std.Build.Step.Compile,
    s2_lib: *std.Build.Step.Compile,
    bridge_lib: *std.Build.Step.Compile,
    module: *std.Build.Module,
    provider: ?wasi_provider.Provider,
    cpp_lib: ?*std.Build.Step.Compile,
};

const NativeGraph = struct {
    absl_lib: *std.Build.Step.Compile,
    s2_lib: *std.Build.Step.Compile,
    bridge_lib: *std.Build.Step.Compile,
    cpp_lib: ?*std.Build.Step.Compile,
};

pub fn build(b: *std.Build) void {
    const target = wasi_provider.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const wasi_sysroot = b.option([]const u8, "wasi-sysroot", "Complete WASI SDK 34+ sysroot with WASIp1-threads EH C/C++ providers");
    const linkage_option = b.option(
        std.lang.LinkMode,
        "linkage",
        "Deliver this package's own native libraries as static archives (the " ++
            "default, and this SDK's linkage policy) or as real shared " ++
            "objects with upstream's sonames. This selects the delivery and " ++
            "never the compilation: the same Abseil and S2 sources, the " ++
            "same bridge, the same flags and the same header closure are " ++
            "built either way. In -fsys=s2 the only artifact this graph still " ++
            "compiles is the bridge, and the option additionally names the " ++
            "kind of installed libs2 and Abseil to bind to.",
    );

    // Bundled delivery defaults to static; system mode retains its dynamic link default.
    const system_mode = b.systemIntegrationOption("s2", .{ .default = false });
    const delivery: std.lang.LinkMode = linkage_option orelse .static;

    // Linkage selects installed artifacts; runtime selects how the facade resolves symbols.
    const runtime_option = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. " ++
            "The facade keeps the same translated header and the same public " ++
            "types; each selected native function becomes a dispatch through " ++
            "one process-lifetime table that an explicit load(source) fills, " ++
            "and the module links no archive. Independent of -Dlinkage, which " ++
            "still decides which artifact this build delivers and installs. " ++
            "Default off, and a linked build is unchanged in every respect.",
    );
    const runtime_loaded = runtime_option orelse false;

    if (system_mode) {
        addSystemMode(
            b,
            target,
            optimize,
            wasi_sysroot,
            delivery,
            linkage_option orelse .dynamic,
            linkage_option,
            runtime_option,
        );
        return;
    }

    rejectUnsupportedDynamicLinkage(target, delivery, "the published build");
    const linkage = delivery;

    const published = addGraph(b, target, optimize, linkage, runtime_loaded, true, wasi_sysroot);

    // Installed DSOs link against installed dependencies, not build-cache paths.
    const installed = if (linkage == .dynamic)
        addNativeGraph(b, target, optimize, linkage, published.provider, false)
    else
        NativeGraph{
            .absl_lib = published.absl_lib,
            .s2_lib = published.s2_lib,
            .bridge_lib = published.bridge_lib,
            .cpp_lib = published.cpp_lib,
        };
    b.installArtifact(installed.absl_lib);
    b.installArtifact(installed.s2_lib);
    b.installArtifact(installed.bridge_lib);
    if (installed.cpp_lib) |cpp_lib| {
        b.installArtifact(cpp_lib);
        cpp_runtime.installLicences(b);
    }

    // Bundled mode installs pkg-config metadata and licence records with the libraries.
    addPkgConfig(b, target, linkage);
    installLicenceRecords(b);

    const smoke_exe = addSmoke(b, target, optimize, published.module, published.provider);
    // Compile the smoke executable as part of install without running it.
    b.getInstallStep().dependOn(&smoke_exe.step);

    const run_smoke = b.addRunArtifact(smoke_exe);
    run_smoke.has_side_effects = true;
    run_smoke.addPassthruArgs();
    b.step("smoke", "Run the deterministic S2 smoke program").dependOn(&run_smoke.step);

    // Expose test runs for every target; the build runner selects or rejects an executor.
    const test_step = b.step("test", "Run the behavioural tests");
    const unit_tests = addTests(b, target, optimize, published.module, published.provider, "s2-tests");
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    test_step.dependOn(&run_tests.step);

    // A named target checks one target; otherwise `check` compiles the matrix.
    const check_step = b.step(
        "check",
        "Compile the C++ library, bridge, facade, tests and example for every required target without running them",
    );
    if (target_was_named(b)) {
        addCheck(b, check_step, target, optimize, delivery, runtime_loaded, wasi_sysroot);
    } else {
        for (check_targets) |query| {
            addCheck(b, check_step, b.resolveTargetQuery(query), optimize, delivery, runtime_loaded, wasi_sysroot);
        }
    }

    // Forward bundled mode to the nested consumer build.
    addConsumerStep(b, target, optimize, false, linkage_option, runtime_option, wasi_sysroot);

    if (linkage == .dynamic) {
        const shared_cpp = if (sharedCppOwner(target, linkage))
            b.fmt(", {s}", .{deliveryName(b, target, "s2cpp", cpp_runtime_version)})
        else
            "";
        std.debug.print("s2geometry: shared objects (-Dlinkage=dynamic): {s}, {s}, {s}{s}\n", .{
            deliveryName(b, target, "absl", absl_abi_version),
            deliveryName(b, target, "s2", s2_abi_version),
            deliveryName(b, target, "s2bridge", bridge_abi_version),
            shared_cpp,
        });
    } else {
        std.debug.print("s2geometry: static archives (-Dlinkage=static, the default)\n", .{});
    }
    if (runtime_loaded) {
        std.debug.print(
            "s2geometry: runtime-loaded dispatch (-Druntime=true); no library " ++
                "is linked into the module, and a provider is named by an " ++
                "explicit load(source)\n",
            .{},
        );
    }
}

/// Builds the native libraries and facade for one target.
/// Private modules avoid reusing the public module name across cross-target builds.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    public: bool,
    wasi_sysroot: ?[]const u8,
) Graph {
    const provider = wasi_provider.Provider.init(b, target, wasi_sysroot);
    // All three libraries use the caller's selected linkage.
    const native = addNativeGraph(b, target, optimize, linkage, provider, true);

    // Runtime dispatch replaces the translated module and bridge link.
    // Reuse the same translation and loader-core types as the linked branch.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("zig/bridge.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // TranslateC and compiled C++ use the same upstream include roots.
    translate_c.addIncludePath(b.path(s2_sources.include_dir));
    translate_c.addIncludePath(b.path(absl_sources.include_dir));
    if (provider) |actual| translate_c.addIncludePath(actual.include_dir);
    // The dispatch owns the loader core; do not create a second instance.
    // Duplicate core modules would give the public types different identities.
    const c_module: *std.Build.Module = if (runtime_loaded)
        graph.createModule(b, translate_c, target, optimize)
    else if (public)
        translate_c.addModule("c")
    else
        translate_c.createModule();

    if (runtime_loaded) {
        // Apply the WASI sysroot and threading model to the selected module.
        if (provider) |actual| actual.configureModule(c_module);
    } else {
        // Restore upstream include roots; this provider also sets WASI configuration.
        c_module.addIncludePath(b.path(s2_sources.include_dir));
        c_module.addIncludePath(b.path(absl_sources.include_dir));
        if (provider) |actual| actual.configureModule(c_module);
    }

    const module = if (public)
        b.addModule("s2geometry", .{
            .root_source_file = b.path("zig/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = target.result.os.tag != .wasi and linkage == .static and !runtime_loaded,
        })
    else
        b.createModule(.{
            .root_source_file = b.path("zig/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = target.result.os.tag != .wasi and linkage == .static and !runtime_loaded,
        });
    module.addImport("c", c_module);
    if (runtime_loaded) {
        // Runtime dispatch already exports loader types; do not create another core module.
    } else {
        // Linked mode imports loader types without adding dispatch code.
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        module.linkLibrary(native.bridge_lib);
    }
    if (provider) |actual| {
        actual.configureModule(module);
        actual.linkRuntime(module);
    }

    return .{
        .absl_lib = native.absl_lib,
        .s2_lib = native.s2_lib,
        .bridge_lib = native.bridge_lib,
        .module = module,
        .provider = provider,
        .cpp_lib = native.cpp_lib,
    };
}

/// Builds the same native closure with cache or installed-tree search paths.
fn addNativeGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    provider: ?wasi_provider.Provider,
    cache_paths: bool,
) NativeGraph {
    const cpp_lib = if (sharedCppOwner(target, linkage)) cpp_runtime.add(b, target) else null;
    const absl_lib = addAbseil(b, target, optimize, platform_flags.isWindows(target), provider, cpp_lib, linkage, cache_paths);
    const s2_lib = addS2(b, target, optimize, provider, absl_lib, cpp_lib, linkage, cache_paths);
    const bridge_lib = addBridge(b, target, optimize, provider, s2_lib, cpp_lib, linkage, cache_paths);
    return .{ .absl_lib = absl_lib, .s2_lib = s2_lib, .bridge_lib = bridge_lib, .cpp_lib = cpp_lib };
}

// OpenBSD/NetBSD PowerPC lacks Abseil's timebase query; use its steady-clock backend.
// Apply this define only to bundled sources; system mode inherits its installed configuration.
fn configureClock(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .openbsd and target.result.os.tag != .netbsd) return;
    switch (target.result.cpu.arch) {
        .powerpc, .powerpc64 => module.addCMacro("ABSL_USE_UNSCALED_CYCLECLOCK", "0"),
        else => {},
    }
}

/// Shared ELF libraries use one source-built C++ runtime.
/// Duplicate C++ runtimes cannot share locale facet identities.
fn sharedCppOwner(target: std.Build.ResolvedTarget, linkage: std.lang.LinkMode) bool {
    return linkage == .dynamic and target.result.ofmt == .elf;
}

fn configureSharedCpp(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    cpp_lib: ?*std.Build.Step.Compile,
    cache_paths: bool,
) void {
    if (cpp_lib) |library| {
        cpp_runtime.configureHeaders(b, module, target);
        linkNativeDependency(module, library, target, cache_paths);
    }
}

/// Compiles the vendored Abseil source list as one library.
fn addAbseil(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    windows: bool,
    provider: ?wasi_provider.Provider,
    cpp_lib: ?*std.Build.Step.Compile,
    linkage: std.lang.LinkMode,
    cache_paths: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi and cpp_lib == null,
        .pic = if (linkage == .dynamic) true else null,
    });
    configureClock(module, target);
    configureSharedCpp(b, module, target, cpp_lib, cache_paths);
    if (provider) |actual| actual.configureModule(module);
    // Matches Abseil's MINGW -ldbghelp and MSVC dbghelp.lib dependency.
    if (windows) module.linkSystemLibrary("dbghelp", .{});
    // CCTZ's Apple default-timezone implementation uses real CoreFoundation.
    if (target.result.os.tag.isDarwin()) module.linkFramework("CoreFoundation", .{});
    // WASI uses the synchronous signal emulation provider; asynchronous facilities are unsupported.
    if (target.result.os.tag == .wasi) {
        module.addCMacro("_WASI_EMULATED_SIGNAL", "1");
    }
    module.addIncludePath(b.path(absl_sources.include_dir));
    module.addCSourceFiles(.{
        .root = b.path(absl_sources.include_dir),
        .files = &absl_sources.sources,
        .flags = platform_flags.abslFlags(target),
        .language = .cpp,
    });

    const lib = b.addLibrary(.{
        .name = "absl",
        .linkage = linkage,
        // Abseil's SOVERSION is 2508.0.0; static archives have no versioned name (CMakeLists.txt:27).
        .version = if (linkage == .dynamic) absl_abi_version else null,
        .root_module = module,
    });
    if (linkage == .dynamic) addInstalledTreeRPath(module, target);
    wasi_provider.configureCompile(b, lib, provider);
    return lib;
}

/// Compiles the upstream S2 library and links Abseil into it.
fn addS2(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    provider: ?wasi_provider.Provider,
    absl_lib: *std.Build.Step.Compile,
    cpp_lib: ?*std.Build.Step.Compile,
    linkage: std.lang.LinkMode,
    cache_paths: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi and cpp_lib == null,
        .pic = if (linkage == .dynamic) true else null,
    });
    configureClock(module, target);
    configureSharedCpp(b, module, target, cpp_lib, cache_paths);
    if (provider) |actual| actual.configureModule(module);
    // S2 headers include Abseil by name, so both include roots are required.
    module.addIncludePath(b.path(s2_sources.include_dir));
    module.addIncludePath(b.path(absl_sources.include_dir));
    module.addCSourceFiles(.{
        .files = &s2_sources.sources,
        .flags = platform_flags.s2Flags(target),
        .language = .cpp,
    });
    linkNativeDependency(module, absl_lib, target, cache_paths);

    const lib = b.addLibrary(.{
        .name = "s2",
        .linkage = linkage,
        // Upstream sets SOVERSION to PROJECT_VERSION_MAJOR (CMakeLists.txt:294-296).
        // The file version follows build.zig.zon.
        .version = if (linkage == .dynamic) s2_abi_version else null,
        .root_module = module,
    });
    if (linkage == .dynamic) addInstalledTreeRPath(module, target);
    wasi_provider.configureCompile(b, lib, provider);
    return lib;
}

/// Compiles the fork bridge and installs upstream headers with it.
/// System include paths match upstream CMake's warning policy (CMakeLists.txt:46-49).
fn addBridge(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    provider: ?wasi_provider.Provider,
    s2_lib: *std.Build.Step.Compile,
    cpp_lib: ?*std.Build.Step.Compile,
    linkage: std.lang.LinkMode,
    cache_paths: bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi and cpp_lib == null,
        .pic = if (linkage == .dynamic) true else null,
    });
    configureClock(module, target);
    configureSharedCpp(b, module, target, cpp_lib, cache_paths);
    if (provider) |actual| actual.configureModule(module);
    // Use upstream system-include policy only for the bridge translation unit.
    module.addSystemIncludePath(b.path(s2_sources.include_dir));
    module.addSystemIncludePath(b.path(absl_sources.include_dir));
    module.addCSourceFile(.{
        .file = b.path("zig/bridge.cc"),
        .flags = platform_flags.s2Flags(target),
        .language = .cpp,
    });
    linkNativeDependency(module, s2_lib, target, cache_paths);

    const lib = b.addLibrary(.{
        .name = "s2bridge",
        .linkage = linkage,
        // The fork bridge uses S2's ABI major; upstream has no bridge SOVERSION.
        .version = if (linkage == .dynamic) bridge_abi_version else null,
        .root_module = module,
    });
    if (linkage == .dynamic) addInstalledTreeRPath(module, target);
    wasi_provider.configureCompile(b, lib, provider);
    // Install src/s2 under include/s2; installing src would add another s2/ level.
    lib.installHeadersDirectory(
        b.path(s2_sources.header_dir),
        "s2",
        .{ .include_extensions = &.{".h"} },
    );
    // Abseil headers include `.inc` implementation fragments as well as `.h` files.
    lib.installHeadersDirectory(
        b.path(absl_sources.header_dir),
        "absl",
        .{ .include_extensions = &absl_sources.header_extensions },
    );
    lib.installHeader(b.path("zig/bridge.h"), "s2geometry_bridge.h");
    return lib;
}

fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    module: *std.Build.Module,
    provider: ?wasi_provider.Provider,
    comptime name: []const u8,
) *std.Build.Step.Compile {
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = module.link_libcpp,
    });
    test_module.addImport("s2geometry", module);
    if (provider) |actual| actual.configureModule(test_module);
    const tests = b.addTest(.{ .name = name, .root_module = test_module });
    wasi_provider.configureCompile(b, tests, provider);
    return tests;
}

fn addSmoke(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    module: *std.Build.Module,
    provider: ?wasi_provider.Provider,
) *std.Build.Step.Compile {
    const exe_module = b.createModule(.{
        .root_source_file = b.path("smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = module.link_libcpp,
    });
    exe_module.addImport("s2geometry", module);
    if (provider) |actual| actual.configureModule(exe_module);
    const exe = b.addExecutable(.{ .name = "s2-smoke", .root_module = exe_module });
    wasi_provider.configureCompile(b, exe, provider);
    return exe;
}

/// Adds compile-only checks for one target.
fn addCheck(
    b: *std.Build,
    step: *std.Build.Step,
    raw_target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    wasi_sysroot: ?[]const u8,
) void {
    const target = wasi_provider.resolveTarget(b, raw_target);
    // Fail only this matrix cell when the target has no dynamic linker.
    if (linkage == .dynamic and !targetHasDynamicLinker(target)) {
        step.dependOn(&b.addFail(b.fmt(
            "s2geometry: check cannot deliver shared objects for {s}; no static substitution. Use -Dlinkage=static.",
            .{@tagName(target.result.os.tag)},
        )).step);
        return;
    }
    const built = addGraph(b, target, optimize, linkage, runtime_loaded, false, wasi_sysroot);
    step.dependOn(&addTests(b, target, optimize, built.module, built.provider, "s2-analyze").step);
    step.dependOn(&addSmoke(b, target, optimize, built.module, built.provider).step);
}

/// Links installed S2 and Abseil through pkg-config; only this fork's bridge is compiled.
/// The bridge uses installed headers to match the selected libraries.
/// `check` covers one target because installed libraries are host-specific.
fn addSystemMode(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    wasi_sysroot: ?[]const u8,
    linkage: std.lang.LinkMode,
    installed_linkage: std.lang.LinkMode,
    linkage_option: ?std.lang.LinkMode,
    runtime_option: ?bool,
) void {
    const runtime_loaded = runtime_option orelse false;
    rejectUnsupportedDynamicLinkage(target, linkage, "-fsys=s2");
    const provider = wasi_provider.Provider.init(b, target, wasi_sysroot);
    // The installed shared ELF closure supplies s2cpp through pkg-config.
    const installed_shared_cpp = sharedCppOwner(target, installed_linkage);
    const bridge_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = target.result.os.tag != .wasi and !installed_shared_cpp,
        .pic = if (linkage == .dynamic) true else null,
    });
    if (installed_shared_cpp) cpp_runtime.configureHeaders(b, bridge_module, target);
    if (provider) |actual| actual.configureModule(bridge_module);
    bridge_module.addCSourceFile(.{
        .file = b.path("zig/bridge.cc"),
        .flags = platform_flags.s2Flags(target),
        .language = .cpp,
    });
    // pkg-config supplies the installed headers and complete library closure.
    bridge_module.linkSystemLibrary(system_pkg_config_module, .{
        .use_pkg_config = .force,
        .preferred_link_mode = installed_linkage,
    });

    const bridge_lib = b.addLibrary(.{
        .name = "s2bridge",
        .linkage = linkage,
        .version = if (linkage == .dynamic) bridge_abi_version else null,
        .root_module = bridge_module,
    });
    if (linkage == .dynamic) addInstalledTreeRPath(bridge_module, target);
    wasi_provider.configureCompile(b, bridge_lib, provider);
    b.installArtifact(bridge_lib);
    bridge_lib.installHeader(b.path("zig/bridge.h"), "s2geometry_bridge.h");

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("zig/bridge.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (provider) |actual| translate_c.addIncludePath(actual.include_dir);
    // Translate against the same installed pkg-config closure as the bridge.
    translate_c.linkSystemLibrary(system_pkg_config_module, .{
        .use_pkg_config = .force,
        .preferred_link_mode = installed_linkage,
    });
    const facade_module = b.addModule("s2geometry", .{
        .root_source_file = b.path("zig/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Avoid a second C++ runtime when the installed ELF closure provides s2cpp.
        // Tests, smoke, and consumer modules inherit this setting.
        .link_libcpp = target.result.os.tag != .wasi and !installed_shared_cpp,
    });
    // Use the installed s2cpp headers with its shared runtime.
    if (installed_shared_cpp) cpp_runtime.configureHeaders(b, facade_module, target);
    // Runtime mode dispatches into the installed library; linked mode uses TranslateC.
    // The shared WASI provider configures either module shape.
    const c_module: *std.Build.Module = if (runtime_loaded)
        graph.createModule(b, translate_c, target, optimize)
    else
        translate_c.addModule("c");
    if (provider) |actual| actual.configureModule(c_module);
    facade_module.addImport("c", c_module);
    if (!runtime_loaded) {
        // Linked mode creates the loader core; runtime dispatch already exports its types.
        // A second core module would make those public types distinct.
        facade_module.addImport("rt", graph.createCoreModule(b, target, optimize));
        facade_module.linkLibrary(bridge_lib);
    }
    if (provider) |actual| {
        actual.configureModule(facade_module);
        actual.linkRuntime(facade_module);
    }

    const smoke_exe = addSmoke(b, target, optimize, facade_module, provider);
    b.getInstallStep().dependOn(&smoke_exe.step);

    const run_smoke = b.addRunArtifact(smoke_exe);
    run_smoke.has_side_effects = true;
    run_smoke.addPassthruArgs();
    const smoke_step = b.step("smoke", "Run the deterministic S2 smoke program against the installed library");
    smoke_step.dependOn(&run_smoke.step);

    // Expose runtime tests against the installed library for every target.
    const test_step = b.step("test", "Run the behavioural tests against the installed library");
    const unit_tests = addTests(b, target, optimize, facade_module, provider, "s2-tests");
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    test_step.dependOn(&run_tests.step);

    // Attach both test and smoke roots to the compile-only check.
    const check_step = b.step(
        "check",
        "Compile the bridge, facade, tests and example against the installed libraries",
    );
    check_step.dependOn(&unit_tests.step);
    check_step.dependOn(&smoke_exe.step);

    // Forward system mode so the nested consumer uses the same installed libraries.
    addConsumerStep(b, target, optimize, true, linkage_option, runtime_option, wasi_sysroot);

    if (linkage == .dynamic) {
        std.debug.print("s2geometry: -fsys=s2, bridge as {s}, bound to {s} installed libraries\n", .{
            deliveryName(b, target, "s2bridge", bridge_abi_version),
            @tagName(installed_linkage),
        });
    } else {
        std.debug.print(
            "s2geometry: -fsys=s2, bridge as a static archive, bound to {s} " ++
                "installed libraries\n",
            .{@tagName(installed_linkage)},
        );
    }
}

/// Builds the consumer package with this graph's target, toolchain, and modes.
/// Uses a nested cache and the outer install prefix.
/// Runs native or Rosetta targets; other cross-targets install without execution.
fn addConsumerStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    use_system: bool,
    linkage: ?std.lang.LinkMode,
    runtime_loaded: ?bool,
    wasi_sysroot: ?[]const u8,
) void {
    const query = target.query;
    const triple = query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    const cpu = query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    const launcher = b.addExecutable(.{
        .name = "s2geometry-consumer-build",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build_support/consumer.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const run = b.addRunArtifact(launcher);
    run.addDirectoryArg2(std.Build.LazyPath.zig_lib, .{ .make_absolute = true });
    run.addDirectoryArg2(.{ .relative = .{ .base = .global_cache } }, .{ .make_absolute = true });
    run.addArgs(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanRunOnHost(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // Forward requested linkage so the nested dependency matches this graph.
    // Omit unset options to preserve the same defaults in both builds.
    if (linkage) |requested| run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(requested)}));
    // Forward runtime mode independently of linkage.
    if (runtime_loaded) |loaded| {
        run.addArg(b.fmt("-Druntime={s}", .{if (loaded) "true" else "false"}));
    }
    // Forward the target triple and CPU; the path dependency cannot represent other query fields.
    // Preserve system mode and the optional WASI sysroot in the nested build.
    run.addArg(if (use_system) "-fsys=s2" else "-fno-sys=s2");
    if (wasi_sysroot) |root| run.addArg(b.fmt("-Dwasi-sysroot={s}", .{root}));
    // Forward third-party executor settings without reading make-phase flags.
    run.addThirdPartyEnabledArgDarling(.{ .enabled = "-fdarling" });
    run.addThirdPartyEnabledArgQemu(.{ .enabled = "-fqemu" });
    run.addThirdPartyEnabledArgRosetta(.{ .enabled = "-frosetta" });
    run.addThirdPartyEnabledArgWasmtime(.{ .enabled = "-fwasmtime" });
    run.addThirdPartyEnabledArgWine(.{ .enabled = "-fwine" });
    // Forward this package's job width and summary; child builds do not inherit them.
    run.addArg("-j8");
    // Keep the summary option in its two-token form.
    run.addArgs(&.{ "--summary", "all" });
    // Keep the nested local cache separate.
    run.addArg("--cache-dir");
    run.addDirectoryArg2(std.Build.LazyPath.cache_root.path(b, "consumer"), .{ .make_absolute = true });
    // Resolve the outer install prefix at make time.
    run.addArg("--prefix");
    run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });
    // Forward consumer-program arguments after `--`.
    run.addArg("--");
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step(
        "consumer",
        "Build the consumer package and run it for native or Rosetta targets",
    ).dependOn(&run.step);
}

/// Selects executor cases visible during configuration; third-party flags arrive at make time.
fn hostCanRunOnHost(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .host_cpu_arch = host.cpu.arch,
        .host_os_tag = host.os.tag,
        .link_mode = .dynamic,
        .link_libc = true,
    };
    if (candidate.os.tag == host.os.tag) {
        if (candidate.dynamic_linker.get()) |dynamic_linker| {
            b.dependOnFileMetadata(b.graph.cwdRelativePath(dynamic_linker));
        }
    }
    return switch (std.zig.system.getExternalExecutor(b.graph.io, candidate, options)) {
        .native, .rosetta => true,
        else => false,
    };
}

/// Windows uses its own loader; WASI has no dynamic linker.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// Refuses shared delivery on targets with no dynamic linker.
/// Static delivery remains available; never substitute it for a requested shared object.
fn rejectUnsupportedDynamicLinkage(
    target: std.Build.ResolvedTarget,
    linkage: std.lang.LinkMode,
    where: []const u8,
) void {
    if (linkage != .dynamic or targetHasDynamicLinker(target)) return;
    // Panic at configure time because entry points can skip the install step.
    std.debug.panic("s2geometry: {s} cannot deliver shared objects for {s}; no static substitution. Use -Dlinkage=static.", .{
        where, @tagName(target.result.os.tag),
    });
}

/// Keep installed dependencies ahead of the separate build-cache directories.
fn linkNativeDependency(
    module: *std.Build.Module,
    dependency: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    cache_paths: bool,
) void {
    if (dependency.linkage == .dynamic and target.result.os.tag != .windows) {
        // addObjectFile avoids linkLibrary's cache-first RPATH for shared dependencies.
        module.addObjectFile(dependency.getEmittedBin());
        addInstalledTreeRPath(module, target);
        if (cache_paths) module.addRPath(dependency.getEmittedBin().dirname());
    } else {
        module.linkLibrary(dependency);
    }
}

/// Adds `$ORIGIN` or `@loader_path` so installed shared libraries find sibling libraries.
/// Matches Abseil's INSTALL_RPATH (vendor/abseil-cpp/CMake/AbseilHelpers.cmake:259-267).
/// Windows uses same-directory DLL lookup, so no RPATH is added.
fn addInstalledTreeRPath(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .windows => {},
        else => module.addRPathSpecial(if (target.result.os.tag.isDarwin())
            "@loader_path"
        else
            "$ORIGIN"),
    }
}

/// Formats the shared library name for this target.
fn deliveryName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    version: std.SemanticVersion,
) []const u8 {
    if (target.result.os.tag == .windows) {
        // Windows uses an unversioned DLL and a separate import library.
        return b.fmt("{s}.dll (+ {s}.lib)", .{ name, name });
    }
    if (target.result.os.tag.isDarwin()) {
        return b.fmt("{s}{s}.{d}.dylib", .{ target.result.libPrefix(), name, version.major });
    }
    return b.fmt("{s}{s}.so.{d}", .{ target.result.libPrefix(), name, version.major });
}

/// Source and destination names for installed licence and provenance files.
const licence_records = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "LICENSE", .to = "LICENSE" },
    .{ .from = "NOTICE", .to = "NOTICE" },
    .{ .from = "AUTHORS", .to = "AUTHORS" },
    .{ .from = "CONTRIBUTORS", .to = "CONTRIBUTORS" },
    .{ .from = "vendor/abseil-cpp/LICENSE", .to = "LICENSE.abseil" },
    .{ .from = "vendor/abseil-cpp/AUTHORS", .to = "AUTHORS.abseil" },
    .{ .from = "build_support/zig-0.16-LICENSE.txt", .to = "LICENSE.zig-0.16.0.txt" },
    .{ .from = "NOTICE.md", .to = "NOTICE.md" },
    .{ .from = "FORK-LICENSE.md", .to = "FORK-LICENSE.md" },
    .{ .from = "UPSTREAM.md", .to = "UPSTREAM.md" },
    .{ .from = "UPSTREAM.sha256", .to = "UPSTREAM.sha256" },
    .{ .from = "CHANGELOG.md", .to = "CHANGELOG.md" },
    .{ .from = "FORK-NOTES.md", .to = "FORK-NOTES.md" },
};

/// Writes fork-authored pkg-config metadata; upstream has no `.pc` template.
/// The prefix is relative to the installed file, and private link flags are target-specific.
/// Shared ELF output includes s2cpp in the library closure.
fn addPkgConfig(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    linkage: std.lang.LinkMode,
) void {
    // Select private link flags for the target platform.
    const platform_private =
        if (platform_flags.isWindows(target))
            "-ldbghelp"
        else if (target.result.os.tag.isDarwin())
            "-framework CoreFoundation"
        else
            "";
    const shared_cpp = if (sharedCppOwner(target, linkage)) " -ls2cpp" else "";
    const install = b.addInstallFileWithDir(
        b.addWriteFiles().add("s2geometry.pc", b.fmt(
            \\# Written by build.zig.  Upstream ships no pkg-config template:
            \\# `Config.cmake.in` is a CMake package config, not link
            \\# metadata, so this file is fork-authored.  `prefix` is
            \\# relative to this file's own directory on purpose, so the
            \\# installed file is correct wherever `--prefix` pointed.
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: s2geometry
            \\Description: S2 Geometry Library (google/s2geometry v{d}.{d}.{d}) with vendored Abseil C++ LTS {s} and this fork's C bridge -- {s} libraries
            \\URL: https://github.com/google/s2geometry
            \\Version: {f}
            \\
            \\Requires:
            \\Libs: -L"${{libdir}}" -ls2bridge -ls2 -labsl{s}
            \\Cflags: -I"${{includedir}}"
            \\Libs.private: {s}
            \\
        , .{
            package_version.major,
            package_version.minor,
            package_version.patch,
            absl_version,
            @tagName(linkage),
            package_version,
            shared_cpp,
            platform_private,
        })),
        .lib,
        "pkgconfig/s2geometry.pc",
    );
    b.getInstallStep().dependOn(&install.step);
}

/// Installs the unconditional licence and provenance records.
/// The C++ runtime's licences are installed beside its shared ELF artifact.
fn installLicenceRecords(b: *std.Build) void {
    for (licence_records) |record| {
        const install = b.addInstallFileWithDir(
            b.path(record.from),
            .prefix,
            b.fmt("share/licenses/s2geometry/{s}", .{record.to}),
        );
        b.getInstallStep().dependOn(&install.step);
    }
}

comptime {
    // Keep manifest, source-list, pkg-config, and S2 ABI versions aligned.
    std.debug.assert(std.mem.eql(u8, manifest.version, s2_version));
    std.debug.assert(package_version.order(s2_abi_version) == .eq);
    std.debug.assert(package_version.order(bridge_abi_version) == .eq);
    // Abseil uses its own 2508 ABI major (vendor/abseil-cpp/CMakeLists.txt:27).
    std.debug.assert(absl_abi_version.major == 2508);
}
