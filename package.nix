# SPDX-License-Identifier: Apache-2.0
#
# package.nix — the one derivation for this SDK. `flake.nix` and `devenv.nix`
# both reach it through `pkgs.callPackage ./package.nix { zig = pkgs.zig_0_16;
# … }`, so there is one build graph and one installed layout; `linkage` selects
# the variant and the variants themselves live in the entry points.
#
# Source-only: no sibling SDK, no download, no host path. The source allow-list
# keeps every compiled source, installed header, test, fixture and licence
# record, and keeps `.git`, `.zig-cache`, `zig-cache`, `zig-out`, `zig-pkg`,
# `consumer/zig-out`, `.devenv/`, `.direnv` and `result/` out of the store.
# `flake.lock` is a repository input, not build material: the flake frontend
# resolves it to fetch `nixpkgs` long before this derivation exists, so it is
# not in the unpacked source either. There is no `devenv.lock` in this tree.
#
# The build graph owns the compiler flags, the source lists, the header
# configuration and the native install — `lib/pkgconfig/s2geometry.pc` and
# `share/licenses/s2geometry/` included, so there is one writer per path. What
# this file adds is the variant and a check of what was installed.
#
# Not claimed here: a `wasm32-wasi` result (that target needs an installed WASI
# SDK 34 sysroot and a patched copy of the standard library, both named by the
# caller), an Apple result beyond the stdenv's own SDK, and a globally static
# closure — the C runtime and the platform libraries always come from the
# consumer's toolchain, and so does the C++ runtime except in the shared ELF
# variant, which installs its own beside the three compiled libraries.
{ lib
, stdenv
, zig
, linkage ? "static"
}:

assert linkage == "static" || linkage == "dynamic";

# build.zig.zon requires 0.16.0; a nixpkgs that moved the attribute fails here
# rather than compiling this package with another toolchain.
assert zig.version == "0.16.0";

# `zig build` is invoked without `-Dtarget`, so the build runner resolves
# `b.graph.host`: the builder. Under Nix cross-compilation that is not the
# target this output is labelled with, so it is refused. A native build on a
# remote builder is an ordinary native build and stays valid.
assert if stdenv.hostPlatform.system == stdenv.buildPlatform.system then
  true
else
  throw ''
    package.nix: `zig build` is given no -Dtarget, so it builds for the build
    machine. This stdenv builds for ${stdenv.hostPlatform.system} on
    ${stdenv.buildPlatform.system}; build this package with a native stdenv.
  '';

let
  # `build.zig`'s `sharedCppOwner(target, linkage)` owns the compiler-shipped
  # C++ runtime: it builds and installs `s2cpp` exactly when the delivery is
  # shared and the target's object format is ELF. This
  # derivation is given no `-Dtarget`, so the target is the machine the build
  # runs on, and `stdenv.hostPlatform.isElf` is this stdenv's own statement of
  # that object's format — nixpkgs reads that same attribute at
  # `pkgs/stdenv/generic/default.nix:147`, and it reaches a platform through
  # `kernels.<name>.execFormat` (lib/systems/parse.nix:562-642) by way of
  # `inspect.patterns.isElf` (lib/systems/inspect.nix:489-491). This is the
  # graph's rule stated in the language this file is written in, not a second
  # one.
  elf = stdenv.hostPlatform.isElf;
  cppRuntime = linkage == "dynamic" && elf;
in

stdenv.mkDerivation {
  pname = "s2geometry";
  # Upstream's tag. `CMakeLists.txt:7-8` still says 0.12.0 inside the v0.14.0
  # tag and is left as upstream shipped it; see UPSTREAM.md.
  version = "0.14.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./build.zig
      ./build.zig.zon
      ./build_support
      # `build.zig` imports `runtime/graph.zig` while it configures, and that
      # graph names `runtime/loader.zig`, `runtime/library.zig`,
      # `runtime/generate.zig` and the compiled `runtime/sync.c`.
      ./runtime
      ./cross-test.profile.sh
      ./smoke.zig
      ./testdata
      ./tests.zig
      ./zig # the C bridge and the typed facade
      ./src # the compiled S2 sources and the installed s2/ header tree
      ./vendor # the vendored Abseil release, whole

      # Upstream records and build definitions: none is compiled here, and the
      # integrity record names all of them.
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

      # This fork's records, including the licence grant.
      ./CHANGELOG.md
      ./FORK-LICENSE.md
      ./FORK-NOTES.md
      ./NOTICE.md
      ./README.md
      # Upstream's README, byte-preserved at this name since 2026-10-04 and
      # recorded under that name by `UPSTREAM.sha256`. Nothing compiles it,
      # but the integrity record names it, so a fetched source that omits it
      # cannot answer the record it ships.
      ./README.upstream.md
      ./README.zig.md
      ./UPSTREAM.md
      ./UPSTREAM.sha256

      # `consumer/` and `doc/` are excluded on purpose: the former is a separate
      # package that carries a `zig-out/` of its own, the latter is upstream's
      # documentation. Neither is an input to this derivation.
    ];
  };

  strictDeps = true;

  nativeBuildInputs = [ zig ];

  # One build, in the install phase, with the flags spelled there.
  dontConfigure = true;
  dontBuild = true;
  dontCheck = true; # the behavioural gate is `zig build test`, run by the driver
  dontUseZigConfigure = true;
  dontUseZigBuild = true;
  dontUseZigCheck = true;
  dontUseZigInstall = true;

  installPhase = ''
    runHook preInstall

    # Both caches under the Nix-provided TMPDIR, outside the unpacked source.
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"

    # One optimize selection, one CPU baseline, one linkage, bundled source
    # mode. C flags and the source lists are the build graph's.
    zig build install \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=ReleaseSafe \
      -Dcpu=baseline \
      -Dlinkage=${linkage} \
      -fno-sys=s2 \
      --prefix "$out"

    # What this variant must have produced. `zig build install` installs what
    # the graph produced; a variant whose artifacts are missing fails here
    # rather than being described. `s2cpp` joins this list exactly when the
    # graph builds it — shared delivery on an ELF platform — and is then held
    # to the same rule as the other three: a shared object, and no static
    # archive beside it.
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

    # The other direction of that same rule: a variant the graph gives no
    # `s2cpp` must not ship one. Static delivery links the consumer's own C++
    # runtime, and a shared delivery on a non-ELF platform keeps the platform
    # provider, so an installed `libs2cpp` there would be an artifact nothing
    # links and no installed licence record covers.
    cpp_runtime="${lib.boolToYesNo cppRuntime}"
    if [ "$cpp_runtime" = "no" ]; then
      for candidate in "$out/lib/libs2cpp".*; do
        if [ -e "$candidate" ]; then
          echo "package.nix: this variant installed $candidate, but only shared ELF delivery builds libs2cpp" >&2
          exit 1
        fi
      done
    fi

    # The C++ runtime ships its own terms. `cpp_runtime.installLicences`
    # (build_support/cpp_runtime.zig:132-141) installs the pinned compiler's
    # three LICENSE.TXT files verbatim beside this SDK's other records, so their
    # absence is as much a partial install as a missing public header.
    if [ "$cpp_runtime" = "yes" ]; then
      for runtime in libcxx libcxxabi libunwind; do
        licence="$out/share/licenses/s2geometry/LICENSE.$runtime.txt"
        if [ ! -s "$licence" ]; then
          echo "package.nix: shared ELF variant is missing or has an empty $licence" >&2
          exit 1
        fi
      done
    fi

    # Public header closure: the bridge header, one S2 header, one Abseil
    # header, and that some Abseil `.inc` implementation fragment was
    # installed — an `.h`-only Abseil header tree looks complete and does not
    # compile.
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

    # Not one label for a mixed tree: Apache-2.0 is both upstreams' project
    # licence, BSD-3-Clause is the additional text three compiled S2 util/gtl
    # headers carry, and MIT is the pinned Zig compiler's, whose terms travel
    # because build_support/wasi_stdlib.patch edits two of its files. The
    # compiled CCTZ header, the retained timezone data and the golang/geo
    # fixture rows carry their own notices and are itemised per file in
    # NOTICE.md, which no label here overrides.
    #
    # The second entry below is not a new term for any of those files. Shared
    # ELF delivery compiles `libs2cpp` from the pinned compiler's libc++,
    # libc++abi and libunwind sources, which carry Apache-2.0 WITH
    # LLVM-exception, and their three LICENSE.TXT files install beside this
    # SDK's own records. `WITH asl20 llvm-exception` is nixpkgs' spelling of
    # that grant (`lib/licenses/operators.nix:78`, `llvm-exception` at
    # `lib/licenses/licenses.nix:1068-1071`), and `lib/licenses/helpers.nix:156`
    # uses that exact expression in its own worked example.
    #
    # One compound, not a bare four-element list, and that is load-bearing
    # rather than stylistic. nixpkgs' unfree check answers a single licence
    # attrset with `isFree`
    # (`pkgs/stdenv/generic/check-meta.nix:118-122`), which understands an
    # exception; it answers a *list* instead with `any (l: !l.free or false)`
    # over the elements (`pkgs/stdenv/generic/check-meta.nix:131-133`), and a
    # `WITH` result carries no `free` attribute at all, so as a list element
    # the LLVM exception reads as unfree and the build stops in check-meta. The
    # same function is why that entry prints as `unknown` in a licence message:
    # `showLicense` falls back to the literal `"unknown"` for an expression
    # with neither `shortName` nor `fullName`
    # (`pkgs/stdenv/generic/check-meta.nix:237-238`). Under the top-level
    # compound the `WITH` is resolved as `license && exception`
    # (`lib/licenses/helpers.nix:14-15`), which is free.
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