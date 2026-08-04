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

      # Shared by apps.build / apps.baogui: enter checkout + set link path.
      cargoPreamble = libPath: ''
        set -euo pipefail
        export LD_LIBRARY_PATH="${libPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

        if [ ! -f Cargo.toml ] && [ -f "''${FLAKE_ROOT:-}/Cargo.toml" ]; then
          cd "$FLAKE_ROOT"
        fi
        if [ ! -f Cargo.toml ]; then
          echo "baogui: no Cargo.toml here (cwd=$PWD)" >&2
          echo "  cd into the baogui checkout, then: nix run .#baogui" >&2
          exit 1
        fi
        if [ ! -d ../vidya ]; then
          echo "baogui: expected sibling ../vidya (Cargo path dep)" >&2
          echo "  clone vidya next to baogui, or: nix build .#baogui" >&2
          exit 1
        fi
      '';

      desktopTemplate = ./data/share/applications/org.openbao.baogui.desktop;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;
          libs = eguiLibs pkgs;

          # Packaged binary for `nix build` / install — pure, remote-builder capable.
          # Day-to-day: prefer `nix run .#baogui` (devshell + .desktop launch below).
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
              # Absolute Exec so the desktop file works without PATH tricks.
              substituteInPlace $out/share/applications/org.openbao.baogui.desktop \
                --replace-fail 'Exec=baogui' "Exec=$out/bin/baogui"

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
          # Prefer host rustup/cargo; only pull small nix deps (not nixpkgs rustc ~1GiB).
          appTools = with pkgs; [ pkg-config ];
          requireCargo = ''
            if ! command -v cargo >/dev/null; then
              echo "baogui: cargo not on PATH (install rustup, or: nix develop)" >&2
              exit 1
            fi
          '';

          # Stage FreeDesktop tree so Wayland can resolve icons via app_id.
          stageXdg = ''
            xdg="$PWD/target/xdg-data"
            mkdir -p "$xdg/applications"
            for size in 16 24 32 48 64 128 256 512; do
              mkdir -p "$xdg/icons/hicolor/''${size}x''${size}/apps"
              src="data/share/icons/hicolor/''${size}x''${size}/apps/org.openbao.baogui.png"
              if [ -f "$src" ]; then
                install -m 644 "$src" \
                  "$xdg/icons/hicolor/''${size}x''${size}/apps/org.openbao.baogui.png"
              fi
            done
            desktop="$xdg/applications/org.openbao.baogui.desktop"
            install -m 644 "${desktopTemplate}" "$desktop"
            # Exec is filled after cargo produces a binary (debug for run, release for build).
            install -m 644 "$desktop" "$PWD/target/org.openbao.baogui.desktop"
            export XDG_DATA_DIRS="$xdg''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
          '';

          # Local cargo build (host rustc/cargo).
          build = pkgs.writeShellApplication {
            name = "baogui-build";
            runtimeInputs = appTools;
            text = ''
              ${cargoPreamble libPath}
              ${requireCargo}
              ${stageXdg}
              echo "→ cargo build $*"
              cargo build "$@"
              bin="$PWD/target/debug/baogui"
              # Prefer release binary if the user passed --release.
              if [ -x "$PWD/target/release/baogui" ] && printf '%s\n' "$*" | grep -q -- '--release'; then
                bin="$PWD/target/release/baogui"
              fi
              if [ -x "$bin" ]; then
                bin_esc=''${bin//\\/\\\\}
                bin_esc=''${bin_esc//&/\\&}
                sed -i -e "s|^Exec=.*|Exec=$bin_esc|" \
                  "$PWD/target/xdg-data/applications/org.openbao.baogui.desktop" \
                  "$PWD/target/org.openbao.baogui.desktop"
              fi
              echo "✓ $bin"
            '';
          };

          # Stage .desktop/icons, then cargo run with host rustc/cargo.
          baoguiApp = pkgs.writeShellApplication {
            name = "baogui";
            runtimeInputs = appTools;
            text = ''
              ${cargoPreamble libPath}
              ${requireCargo}
              ${stageXdg}

              # Point desktop Exec at the debug binary cargo run will use.
              bin="$PWD/target/debug/baogui"
              bin_esc=''${bin//\\/\\\\}
              bin_esc=''${bin_esc//&/\\&}
              sed -i -e "s|^Exec=.*|Exec=$bin_esc|" \
                "$PWD/target/xdg-data/applications/org.openbao.baogui.desktop" \
                "$PWD/target/org.openbao.baogui.desktop"

              echo "→ cargo run $*  ($(command -v cargo))"
              echo "    app_id=org.openbao.baogui  XDG_DATA_DIRS=$PWD/target/xdg-data:…"
              exec cargo run -- "$@"
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${baoguiApp}/bin/baogui";
          };
          baogui = {
            type = "app";
            program = "${baoguiApp}/bin/baogui";
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
            # Host rustup for rustc/cargo; this shell only adds egui link libs + helpers.
            packages = with pkgs; [
              pkg-config
              glib # gio launch
              rust-analyzer
            ];
            buildInputs = libs;
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libs;
            RUST_BACKTRACE = "1";
            shellHook = ''
              echo "BaoGUI dev shell (uses PATH rustc/cargo — not nixpkgs rustc)"
              echo "  nix run / nix run .#baogui   # cargo run (+ staged .desktop/icons)"
              echo "  nix run .#build              # cargo build"
              echo "  cargo run                    # from this shell"
              echo "  nix build .#baogui           # pure package (+ installed .desktop)"
            '';
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
