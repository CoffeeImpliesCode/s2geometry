# SPDX-License-Identifier: Apache-2.0
{ lib
, stdenv
, zig
, linkage ? "static"
}:

assert linkage == "static" || linkage == "dynamic";

  # Keep the pinned compiler version aligned with build.zig.zon.
assert zig.version == "0.16.0";

  # Nix cross-builds are refused because Zig defaults to the builder target.
assert if stdenv.hostPlatform.system == stdenv.buildPlatform.system then
  true
else
  throw ''
    package.nix: `zig build` is given no -Dtarget, so it builds for the build
    machine. This stdenv builds for ${stdenv.hostPlatform.system} on
    ${stdenv.buildPlatform.system}; build this package with a native stdenv.
  '';

let
  # Shared ELF delivery uses the same C++ runtime predicate as build.zig.
  elf = stdenv.hostPlatform.isElf;
  cppRuntime = linkage == "dynamic" && elf;
in

stdenv.mkDerivation {
  pname = "s2geometry";
  # Upstream's tag is v0.14.0; CMakeLists.txt retains its stale 0.12.0 project version.
  version = "0.14.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./build_support
      # build.zig imports the runtime sources during configuration and compilation.
      ./runtime
      ./cross-test.profile.sh
      ./smoke.zig
      ./testdata
      ./tests.zig
      ./zig # the C bridge and the typed facade
      ./src # the compiled S2 sources and the installed s2/ header tree
      ./vendor # the vendored Abseil release, whole

      # Keep upstream metadata used by the integrity record.
      ./.clang-format
      ./AUTHORS
      ./CONTRIBUTORS
      ./CONTRIBUTING.md
      ./CMakeLists.txt
      ./Config.cmake.in
      ./LICENSE
      ./NOTICE
      ./pyproject.toml
      ./setup.py

      ./CHANGELOG.md
      ./FORK-LICENSE.md
      ./FORK-NOTES.md
      ./NOTICE.md
      ./README.md
      # Retain the upstream README because UPSTREAM.sha256 records it.
      ./README.upstream.md
      ./README.zig.md
      ./UPSTREAM.md
      ./UPSTREAM.sha256

    ];
  };

  strictDeps = true;

  nativeBuildInputs = [ zig ];

  dontConfigure = true;
  dontBuild = true;
  dontCheck = true; # the behavioural gate is `zig build test`, run by the driver
  dontUseZigConfigure = true;
  dontUseZigBuild = true;
  dontUseZigCheck = true;
  dontUseZigInstall = true;

  installPhase = ''
    runHook preInstall

    # Keep both compiler caches outside the unpacked source tree.
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"

    # Build the declared linkage variant with the package's release settings.
    zig build install \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=ReleaseSafe \
      -Dcpu=baseline \
      -Dlinkage=${linkage} \
      -fno-sys=s2 \
      --prefix "$out"

    # Require the installed closure to match linkage and the ELF runtime rule.
    for name in absl s2 s2bridge${lib.optionalString cppRuntime " s2cpp"}; do
      if [ "${linkage}" = "static" ]; then
        if [ ! -f "$out/lib/lib$name.a" ]; then
          echo "package.nix: static variant is missing $out/lib/lib$name.a" >&2
          exit 1
        fi
      else
        found=
        for candidate in \
          "$out/lib/lib$name.so" \
          "$out/lib/lib$name.so."* \
          "$out/lib/lib$name.dylib" \
          "$out/lib/lib$name.dll" \
          "$out/lib/lib$name.dll.a" \
          "$out/lib/$name.dll" \
          "$out/lib/$name.dll.lib" \
          "$out/lib/$name.lib"
        do
          if [ -e "$candidate" ]; then
            found=1
          fi
        done
        if [ -z "$found" ]; then
          echo "package.nix: shared variant produced no shared object for $name" >&2
          exit 1
        fi
        if [ -f "$out/lib/lib$name.a" ]; then
          echo "package.nix: shared variant also installed a static archive for $name" >&2
          exit 1
        fi
      fi
    done

    # Reject libs2cpp where the build graph does not provide it.
    cpp_runtime="${lib.boolToYesNo cppRuntime}"
    if [ "$cpp_runtime" = "no" ]; then
      for candidate in "$out/lib/libs2cpp".*; do
        if [ -e "$candidate" ]; then
          echo "package.nix: this variant installed $candidate, but only shared ELF delivery builds libs2cpp" >&2
          exit 1
        fi
      done
    fi

    # The shared ELF runtime carries its own three licence texts.
    if [ "$cpp_runtime" = "yes" ]; then
      for runtime in libcxx libcxxabi libunwind; do
        licence="$out/share/licenses/s2geometry/LICENSE.$runtime.txt"
        if [ ! -s "$licence" ]; then
          echo "package.nix: shared ELF variant is missing or has an empty $licence" >&2
          exit 1
        fi
      done
    fi

    # Check representative public headers and an Abseil implementation fragment.
    for header in \
      "$out/include/s2geometry_bridge.h" \
      "$out/include/s2/s2cell_id.h" \
      "$out/include/absl/base/config.h" \
      "$out/include/absl/base/options.h"
    do
      if [ ! -f "$header" ]; then
        echo "package.nix: installed header closure is missing $header" >&2
        exit 1
      fi
    done
    if ! find "$out/include/absl" -name '*.inc' -print -quit | grep -q .; then
      echo "package.nix: no Abseil .inc implementation fragment was installed" >&2
      exit 1
    fi

    runHook postInstall
  '';

  meta = {
    description =
      "S2 Geometry Library (spherical geometry) with vendored Abseil C++ and a C bridge";
    longDescription = ''
      The google/s2geometry C++ sources at tag v0.14.0, compiled with the
      Abseil C++ LTS 20250814.1 release that s2geometry's own CMakeLists.txt
      fetches and which is vendored whole at vendor/abseil-cpp, plus this
      fork's C bridge (libs2bridge) over them. Installs ${if cppRuntime then "four" else "three"} libraries, the
      complete S2 and Abseil public header trees, the bridge header,
      relocatable pkg-config metadata and every licence text the output
      carries.${if cppRuntime then ''
        On an ELF platform the shared delivery's fourth library is
        libs2cpp.so.0, compiled from the pinned Zig 0.16.0 compiler's own
        libc++, libc++abi and libunwind sources: Zig's ordinary static C++
        runtime hides its exports, so two images that each carry it cannot
        share one locale facet registry. It is built at the compiler's own
        runtime policy — ReleaseFast, C sanitization off, hardening NONE —
        rather than at the ReleaseSafe the S2, Abseil and bridge objects use,
        and the compiler's three LICENSE.TXT files are installed verbatim
        beside this SDK's other licence records.
      '' else ''
        This delivery has no fourth library: static linking uses the
        consumer's own C++ runtime, and a non-ELF platform keeps the platform
        provider, which is the build graph's own C++ provider rule.
      ''}
      Neither variant is a globally static closure: the C runtime and the
      platform libraries come from the consumer's toolchain, and where this
      delivery carries no libs2cpp the C++ runtime comes from there too.
    '';
    homepage = "https://github.com/google/s2geometry";

    # Keep the LLVM exception in a compound licence expression; nixpkgs handles
    # it differently from a list of licences.
    # NOTICE.md records per-file licence scope.
    license = with lib.licenses; AND [
      asl20
      (WITH asl20 llvm-exception)
      bsd3
      mit
    ];
    licenseFile = "LICENSE";

    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  };
}