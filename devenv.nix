# SPDX-License-Identifier: Apache-2.0
{ pkgs, ... }:

let
  lib = pkgs.lib;
  zig = pkgs.zig_0_16;

  sdk = linkage: pkgs.callPackage ./package.nix {
    zig = pkgs.zig_0_16;
    inherit linkage;
  };

  # Resolve this package path at evaluation time; `${./.}` would copy it to the store.
  # `$DEVENV_ROOT` names the caller's state directory, not this package.
  sdkRoot = lib.escapeShellArg (builtins.toString ./.);

  # Task bodies set caches because single-mode tasks skip enterShell.
  # Preserve caller values; otherwise use XDG_CACHE_HOME or TMPDIR, or fail.
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

  # Isolate the local cache by package; share the global content-addressed cache.
  cacheFlags = "--cache-dir \"$ZIG_LOCAL_CACHE_DIR/s2geometry\" --global-cache-dir \"$ZIG_GLOBAL_CACHE_DIR\"";

  # Only install tasks need a prefix; place it under this package's local cache.
  prefixLines = ''
    prefix="$ZIG_LOCAL_CACHE_DIR/s2geometry/prefix"
    mkdir -p "$prefix"
  '';
  prefixFlag = "--prefix \"$prefix\"";

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

  # Outputs are lazy; entering the shell does not realize them.
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