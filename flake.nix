{
  description = "BaoGUI — simple Vidya/egui OpenBao client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    vidya = {
      url = "git+https://tangled.org/nandi.uk/vidya";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      vidya,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      eguiLibs =
        pkgs:
        with pkgs;
        [
          libxkbcommon
          libGL
          vulkan-loader
        ]
        ++ lib.optionals stdenv.hostPlatform.isLinux [
          wayland
          libx11
          libxcursor
          libxi
          libxrandr
        ];
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;
          libs = eguiLibs pkgs;

          # Cargo.toml expects path = "../vidya" (sibling of the package root).
          srcTree = pkgs.runCommand "baogui-src" { } ''
            mkdir -p $out/baogui $out/vidya
            cp -a ${lib.cleanSource ./.}/. $out/baogui/
            cp -a ${vidya}/. $out/vidya/
            chmod -R u+w $out
            rm -rf $out/baogui/{target,result,result-*,.git} 2>/dev/null || true
            rm -rf $out/vidya/{target,android-demo,host,examples,docs,.git} 2>/dev/null || true
          '';

          baogui = pkgs.rustPlatform.buildRustPackage {
            pname = "baogui";
            version = "0.1.0";
            src = srcTree;
            sourceRoot = "baogui-src/baogui";
            cargoLock.lockFile = ./Cargo.lock;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = libs;

            postInstall = ''
              wrapProgram $out/bin/baogui \
                --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath libs}

              install -Dm644 data/share/applications/org.openbao.baogui.desktop \
                $out/share/applications/org.openbao.baogui.desktop
              for size in 16 24 32 48 64 128 256 512; do
                install -Dm644 data/share/icons/hicolor/''${size}x''${size}/apps/org.openbao.baogui.png \
                  $out/share/icons/hicolor/''${size}x''${size}/apps/org.openbao.baogui.png
              done
            '';

            meta = {
              description = "Simple Vidya client for OpenBao";
              homepage = "https://openbao.org/";
              license = lib.licenses.mit;
              mainProgram = "baogui";
              platforms = lib.platforms.linux;
            };
          };
        in
        {
          default = baogui;
          baogui = baogui;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;
          libs = eguiLibs pkgs;
          libPath = lib.makeLibraryPath libs;
          pkg = self.packages.${system}.baogui;

          build = pkgs.writeShellApplication {
            name = "baogui-build";
            runtimeInputs = with pkgs; [
              rustc
              cargo
              pkg-config
            ];
            text = ''
              set -euo pipefail
              export LD_LIBRARY_PATH="${libPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              if [ ! -f Cargo.toml ] && [ -f "''${FLAKE_ROOT:-}/Cargo.toml" ]; then
                cd "$FLAKE_ROOT"
              fi
              if [ ! -f Cargo.toml ]; then
                echo "baogui-build: no Cargo.toml here (cwd=$PWD)" >&2
                echo "  cd into the baogui checkout, then: nix run .#build" >&2
                exit 1
              fi
              if [ ! -d ../vidya ]; then
                echo "baogui-build: expected sibling ../vidya (Cargo path dep)" >&2
                echo "  clone vidya next to baogui, or use: nix build .#baogui" >&2
                exit 1
              fi

              echo "→ cargo build --release $*"
              cargo build --release "$@"
              echo "✓ target/release/baogui"
              echo "  run:  LD_LIBRARY_PATH=${libPath}:\''${LD_LIBRARY_PATH:-} ./target/release/baogui"
              echo "  or:   nix develop -c cargo run --release"
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${pkg}/bin/baogui";
          };
          baogui = {
            type = "app";
            program = "${pkg}/bin/baogui";
          };
          build = {
            type = "app";
            program = "${build}/bin/baogui-build";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          libs = eguiLibs pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              rustc
              cargo
              rustfmt
              clippy
              rust-analyzer
              pkg-config
            ];
            buildInputs = libs;
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libs;
            RUST_BACKTRACE = "1";
            shellHook = ''
              echo "BaoGUI dev shell"
              echo "  cargo run          # build & launch"
              echo "  cargo build --release"
              echo "  nix run            # build package & run"
            '';
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
