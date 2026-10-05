# SPDX-License-Identifier: Apache-2.0
#
# flake.nix — entry point only. One derivation lives in ./package.nix; this
# file names its two variants and a tools-only development shell.
#
#   packages.<system>.static   -Dlinkage=static
#   packages.<system>.shared   -Dlinkage=dynamic
#   packages.<system>.default  static: the SDK's existing linkage policy, which
#                              build.zig hard-codes as .static for all three
#                              libraries
#
# `devenv shell` is the canonical development environment; `nix develop` is
# parity for the same tools. No lock is written here: flake.lock is the driver's
# to create and pin from an observed run.
{
  description = "S2 Geometry Library (google/s2geometry v0.14.0) with vendored Abseil C++ LTS 20250814.1, built by Zig 0.16.0";

  inputs = {
    # Pinned revision, not a channel: the toolchain and the licence metadata
    # must not move because a branch moved.
    nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      devEnv = pkgs: import ./devenv.nix { inherit pkgs; };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          mk = linkage: pkgs.callPackage ./package.nix {
            zig = pkgs.zig_0_16;
            inherit linkage;
          };
        in
        rec {
          static = mk "static";
          shared = mk "dynamic";
          default = static;
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "s2geometry";
          packages = (devEnv pkgs).packages;
        };
      });
    };
}