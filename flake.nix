{
  description = "isonim-render-serve - WebSocket bridge for the IsoNim render-stream protocol (F/M/I packets)";

  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules";
    nixpkgs.follows = "nixos-modules/nixpkgs-unstable";
    flake-parts.follows = "nixos-modules/flake-parts";
    git-hooks.follows = "nixos-modules/git-hooks-nix";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      git-hooks,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        let
          preCommit = git-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              check-added-large-files = {
                enable = true;
                args = [ "--maxkb=1200" ];
              };
              check-merge-conflicts.enable = true;
              lint = {
                enable = true;
                name = "just lint";
                entry = "just lint";
                language = "system";
                pass_filenames = false;
              };
            };
          };
        in
        {
          checks.pre-commit = preCommit;
          devShells.default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                nim
                nimble
                just
                nixfmt-rfc-style
                markdownlint-cli2
                shellcheck
                shfmt
                nodejs_20
              ]
              ++ pkgs.lib.optionals (pkgs.lib.hasSuffix "linux" system) [
                # RS-M2: the GPUI streaming adapter (and the integration
                # tests that exercise it) load `libgpui_nim_shim.so` at
                # run time via `{.dynlib.}`. The shim itself is built
                # in the `isonim-gpui` repo (`just rust-build`). Even in
                # the headless stub mode the shim has no extra link-time
                # deps, so the only thing this dev shell needs to
                # provide is the loader search path. We extend
                # `LD_LIBRARY_PATH` in `shellHook` below.
                tree-sitter
                pkg-config
              ];
            shellHook = ''
              ${preCommit.shellHook}
              # RS-M2: extend LD_LIBRARY_PATH so `nim c -r` driven tests
              # that import `isonim_gpui/renderer` find the shim cdylib.
              # The shim is built once via `cd ../isonim-gpui && just
              # rust-build`; this hook just makes the loader find it.
              if [ -d "$PWD/../isonim-gpui/rust/target/debug" ]; then
                export LD_LIBRARY_PATH="$PWD/../isonim-gpui/rust/target/debug''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              fi
              # RS-M4: same trick for the Freya adapter. The shim is
              # built via `cd ../isonim-freya && just rust-build`;
              # this hook makes `libfreya_nim_shim.so` resolvable at
              # run time so `nim c -r` tests that import
              # `isonim_freya/renderer` (transitively through the
              # adapter / the EX-M4 task_app demo) link cleanly.
              if [ -d "$PWD/../isonim-freya/rust/target/debug" ]; then
                export LD_LIBRARY_PATH="$PWD/../isonim-freya/rust/target/debug''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              fi
              # RS-M5 (partial-linux): the Cocoa adapter
              # (`src/isonim_render_serve/adapters/cocoa_adapter.nim`)
              # is scaffolded here on Linux; its AppKit-touching body
              # is gated `when defined(macosx)`. On a macOS dev shell
              # the build needs the AppKit SDK (provided automatically
              # by Xcode-on-macOS via `xcrun`) — no Nix package needed
              # because Apple bundles AppKit / Foundation /
              # CoreGraphics with the OS. `isonim_cocoa/renderer`
              # declares the link-time `{.passL: "-lobjc -framework
              # Foundation -framework CoreGraphics".}` pragmas; the
              # macOS engineer extends `nim c` invocations with
              # `--passL:"-framework AppKit"` as the
              # `bitmapImageRepForCachingDisplayInRect` capture path
              # lands. No `LD_LIBRARY_PATH` extension is needed on
              # Linux — the scaffold returns placeholder pixels and
              # never touches AppKit.
              echo "isonim-render-serve dev shell - nim $(nim --version 2>&1 | head -1)"
            '';
          };
          packages.default = pkgs.stdenvNoCC.mkDerivation {
            pname = "isonim-render-serve";
            version = "0.1.0";
            src = ./.;
            installPhase = ''
              mkdir -p $out
              cp -R src isonim_render_serve.nimble README.md LICENSE static $out/
            '';
          };
        };
    };
}
