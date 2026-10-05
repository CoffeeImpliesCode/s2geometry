# SPDX-License-Identifier: Apache-2.0
#
# devenv.nix — the canonical development environment for this SDK.
#
# `packages` holds tools only: entering the shell never builds this SDK. The
# package itself is reached through the lazy `outputs` below, which call the
# same ./package.nix the flake calls and are built on request:
#
#   devenv build outputs.static     # the SDK's own linkage policy: static
#   devenv build outputs.shared     # -Dlinkage=dynamic
#
# The two variants install different closures. Static installs libabsl, libs2
# and libs2bridge and leaves the C++ runtime to the consumer; shared on an ELF
# platform also installs libs2cpp.so.0, compiled from the pinned compiler's own
# libc++/libc++abi/libunwind sources. That is the build graph's own rule, not a
# difference introduced here. `outputs` stays an attrset of attribute values,
# so entering the shell still builds nothing and only the named output is ever
# realised.
#
# Every task names this SDK's own directory first, because that is not where a
# task runs. `devenv tasks run` and `devenv shell -- <name>` both inherit the
# caller's working directory, which is wherever the caller typed the command and
# which holds devenv's own state (`.devenv`, `devenv.lock`) rather than this
# package's `build.zig`, `consumer/` or `UPSTREAM.sha256`. `sdkRoot` below is
# `./.` in this file, so each task reads the SDK that owns it.
#
# `zig build` resolves three locations the caller owns. The local cache defaults
# to `.zig-cache/` beside the package and the global cache to a path the
# compiler picks for itself, so every build names both caches explicitly and an
# unset `ZIG_LOCAL_CACHE_DIR` or `ZIG_GLOBAL_CACHE_DIR` is filled rather than
# left to fall through to a default inside this checkout. The installed prefix
# defaults to `zig-out/` inside the package, so the one task that runs the
# install step names a prefix under the caller's own local cache too. No fixed
# path is written here for build output, so a canonical task delivers its
# artifacts outside this repository and outside the volume it lives on. The
# steps that only compile or run install nothing and name no prefix.
#
# A value the caller exported is used exactly as it stands and is never
# overwritten or unset: TMPDIR, XDG_CACHE_HOME, both Zig cache variables,
# DEVENV_HOME, XDG_RUNTIME_DIR and XDG_DATA_HOME are all read, and the only one
# this file ever writes is a Zig cache variable it had to fill. A shell that
# names no location for either cache is told so and stops before the compiler
# runs, in the task body and not only in `enterShell`, because `devenv tasks
# run --mode single <name>` executes a body without running the shell hook.
# Caller flags travel last, in `"$@"`, so a named `--prefix`, `--cache-dir`,
# `-Doption` or `-j` is the one that takes effect.
#
# `wasm32-wasi` needs an installed WASI SDK 34 sysroot and a patched copy of
# the pinned standard library. Both are per-machine providers the caller names
# on the command line; this file supplies neither and hard-codes no path.
{ pkgs, ... }:

let
  lib = pkgs.lib;
  zig = pkgs.zig_0_16;

  sdk = linkage: pkgs.callPackage ./package.nix {
    zig = pkgs.zig_0_16;
    inherit linkage;
  };

  # This file's own directory, as a string resolved while this file is
  # evaluated: the generated shell program names the directory. `${./.}` would
  # instead give every exec a store context and add a read-only copy of the
  # whole SDK to the store, and `$DEVENV_ROOT` names the caller's devenv state
  # directory rather than this package. `escapeShellArg` quotes it for the shell.
  sdkRoot = lib.escapeShellArg (builtins.toString ./.);

  # What every task runs before `zig build`, and the flags it names to
  # `zig build`. Both caches are in both parts: a `zig build` given no
  # `--cache-dir` resolves `.zig-cache` inside the package, and one given no
  # `--global-cache-dir` resolves a package store of its own.
  #
  # A value the caller exported is used exactly as it stands. Only a missing
  # one is filled, from `XDG_CACHE_HOME` first, where a cache belongs by the
  # Base Directory Specification, and `TMPDIR` second. `/tmp` is not a fallback
  # for anything: a small system temporary filesystem is not scratch storage,
  # and a task that has nowhere approved to write says so and stops before the
  # compiler. The fill is in the body rather than in `enterShell`, because
  # `devenv tasks run --mode single <name>` executes a body without running
  # the shell hook.
  cacheLines = ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        ZIG_LOCAL_CACHE_DIR="''${XDG_CACHE_HOME}/zig-local-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        ZIG_LOCAL_CACHE_DIR="''${TMPDIR}/zig-local-cache"
      else
        echo "s2geometry devenv: ZIG_LOCAL_CACHE_DIR is unset, and neither XDG_CACHE_HOME nor TMPDIR names a cache location, so no cache and no install prefix is chosen here. Export one and run the task again." >&2
        exit 1
      fi
      export ZIG_LOCAL_CACHE_DIR
    fi
    if [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME}/zig-global-cache"
      elif [ -n "''${TMPDIR:-}" ]; then
        ZIG_GLOBAL_CACHE_DIR="''${TMPDIR}/zig-global-cache"
      else
        echo "s2geometry devenv: ZIG_GLOBAL_CACHE_DIR is unset, and neither XDG_CACHE_HOME nor TMPDIR names a cache location, so no global cache is chosen here. Export one and run the task again." >&2
        exit 1
      fi
      export ZIG_GLOBAL_CACHE_DIR
    fi
  '';

  # The local cache carries this SDK's own subdirectory, because two build
  # graphs must not share one manifest directory. The global cache is passed
  # through unchanged: it is the shared, content-addressed package store, and
  # a subdirectory of it would make this graph materialise its own copy of
  # every dependency.
  cacheFlags = "--cache-dir \"$ZIG_LOCAL_CACHE_DIR/s2geometry\" --global-cache-dir \"$ZIG_GLOBAL_CACHE_DIR\"";

  # The install prefix, and the flag that names it. Only the step that runs
  # this package's install step needs one, because the other steps install
  # nothing in this graph. It is under the local cache location the two lines
  # above have already resolved, so a bare `zig build` never lands in
  # `zig-out/` inside this repository.
  prefixLines = ''
    prefix="$ZIG_LOCAL_CACHE_DIR/s2geometry/prefix"
    mkdir -p "$prefix"
  '';
  prefixFlag = "--prefix \"$prefix\"";

  # The SDK's own commands, spelled as the READMEs spell them, under namespaced
  # task names: `devenv tasks run sdk:test`. `installs` marks the single command
  # that runs this package's install step, `build.zig`'s default step.
  zigTask =
    { description, args, installs ? false }:
    {
      inherit description;
      exec = ''
        cd ${sdkRoot}
        ${cacheLines}${lib.optionalString installs prefixLines}zig build ${args} -j8 ${cacheFlags} ${lib.optionalString installs prefixFlag} --summary all "$@"
      '';
    };
in

{
  packages = [
    zig
    pkgs.gdb # native debugging of the bridge and the facade
    pkgs.pkg-config # reading the installed s2geometry.pc of a built output
    pkgs.shellcheck # cross-test.profile.sh is sourced as trusted Bash
  ];

  # Lazy: nothing here is realised by entering the shell.
  outputs = {
    static = sdk "static";
    shared = sdk "dynamic";
    default = sdk "static";
  };

  tasks = {
    "sdk:build" = zigTask {
      description = "Install the static closure — libabsl, libs2, libs2bridge, the S2 and Abseil header trees and the bridge header — and compile the smoke program; shared ELF delivery instead adds libs2cpp.so.0. The installed tree goes under the caller's own $ZIG_LOCAL_CACHE_DIR, never into this repository and never into a temporary filesystem this file names";
      args = "";
      installs = true;
    };
    "sdk:test" = zigTask {
      description = "Run the behavioural tests for the selected target";
      args = "test";
    };
    "sdk:test-release-safe" = zigTask {
      description = "Run the behavioural tests at ReleaseSafe, where Zig's runtime safety checks stay on: it optimises where Debug does not, and switches nothing off where ReleaseFast would";
      args = "test -Doptimize=ReleaseSafe";
    };
    "sdk:smoke" = zigTask {
      description = "Run the deterministic smoke program";
      args = "smoke";
    };
    "sdk:check" = zigTask {
      description = "Compile the library, bridge, facade, tests and example for the six required targets, running nothing";
      args = "check";
    };
    "sdk:consumer" = zigTask {
      description = "Build the standalone consumer/ package and run it where this host can execute the target";
      args = "consumer";
    };
    "sdk:fmt" = {
      description = "Check the formatting of this fork's own Zig sources";
      exec = ''
        cd ${sdkRoot}
        zig fmt --check build.zig tests.zig smoke.zig zig consumer "$@"
      '';
    };
    "sdk:integrity" = {
      description = "Verify the immutable source, licence and fixture digests in UPSTREAM.sha256";
      exec = ''
        cd ${sdkRoot}
        sha256sum -c UPSTREAM.sha256 "$@"
      '';
    };
  };

  assertions = [
    {
      assertion = zig.version == "0.16.0";
      message = "devenv.nix: this SDK requires Zig 0.16.0; pkgs.zig_0_16 is ${zig.version}.";
    }
  ];
}