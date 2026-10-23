# SPDX-License-Identifier: Apache-2.0
{
  description = "S2 Geometry Library (google/s2geometry v0.14.0) with vendored Abseil C++ LTS 20250814.1, built by Zig 0.16.0";

  inputs = {
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