{
  description = "BaoGUI — simple Vidya/egui OpenBao client";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vidya = {
      url = "git+https://tangled.org/nandi.uk/vidya";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      vidya,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
          config = {
            allowUnfree = true;
            android_sdk.accept_license = true;
          };
        };

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

      androidApiLevel = "28";
      androidTarget = "aarch64-linux-android";

      baoguiSrcTree =
        pkgs:
        let
          baoguiFiltered = pkgs.lib.cleanSourceWith {
            src = ./.;
            filter =
              path: type:
              let
                base = baseNameOf path;
              in
              pkgs.lib.cleanSourceFilter path type
              && !(builtins.elem base [
                ".tangled"
                ".github"
                ".cursor"
                ".jj"
                ".cargo"
                "AGENTS.md"
                "result"
                "result-android"
                "result-baogui"
              ]);
          };
        in
        pkgs.runCommand "baogui-src-tree" { } ''
          mkdir -p $out/baogui $out/vidya
          cp -a ${baoguiFiltered}/. $out/baogui/
          cp -a ${vidya}/. $out/vidya/
          chmod -R u+w $out
          rm -rf $out/baogui/{target,result,result-*,.git} 2>/dev/null || true
          rm -rf $out/baogui/android/target 2>/dev/null || true
          rm -rf $out/vidya/{target,android-demo,host,examples,docs,.git} 2>/dev/null || true
        '';

      # Host glibc is often older than nixpkgs libs; prefer system egui deps when present.
      preferSystemEguiLibs = ''
        system_egui_libs_ok() {
          ldconfig -p 2>/dev/null | grep -qE 'libxkbcommon-x11\.so' &&
            ldconfig -p 2>/dev/null | grep -qE 'libGL\.so\.1' &&
            ldconfig -p 2>/dev/null | grep -qE 'libwayland-client\.so'
        }
      '';

      linkEguiLibs = libPath: ''
        ${preferSystemEguiLibs}
        if ! system_egui_libs_ok; then
          export LD_LIBRARY_PATH="${libPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
      '';

      # Shared by apps.build / apps.baogui: enter checkout + set link path.
      cargoPreamble = libPath: ''
        set -euo pipefail
        ${linkEguiLibs libPath}

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
          pkgs = pkgsFor system;
          inherit (pkgs) lib;
          libs = eguiLibs pkgs;
          srcTree = baoguiSrcTree pkgs;

          rustAndroid = pkgs.rust-bin.stable.latest.default.override {
            extensions = [ "rust-src" ];
            targets = [
              androidTarget
              "x86_64-linux-android"
            ];
          };
          rustPlatformAndroid = pkgs.makeRustPlatform {
            cargo = rustAndroid;
            rustc = rustAndroid;
          };

          androidComposition = pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "34" ];
            buildToolsVersions = [ "34.0.0" ];
            includeNDK = true;
            includeEmulator = false;
            includeSystemImages = false;
          };
          androidSdk = androidComposition.androidsdk;
          androidSdkRoot = "${androidSdk}/libexec/android-sdk";

          # Emulator + x86_64 system image (KVM-accelerated APK runs).
          androidCompositionEmu = pkgs.androidenv.composeAndroidPackages {
            platformVersions = [ "34" ];
            buildToolsVersions = [ "34.0.0" ];
            includeNDK = true;
            includeEmulator = true;
            includeSystemImages = true;
            systemImageTypes = [ "google_apis" ];
            abiVersions = [ "x86_64" ];
          };
          androidSdkEmu = androidCompositionEmu.androidsdk;
          androidSdkEmuRoot = "${androidSdkEmu}/libexec/android-sdk";

          baogui = pkgs.rustPlatform.buildRustPackage {
            pname = "baogui";
            version = "0.1.0";
            src = srcTree;
            sourceRoot = "baogui-src-tree/baogui";
            cargoLock.lockFile = ./Cargo.lock;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = libs;

            postInstall = ''
              wrapProgram $out/bin/baogui \
                --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath libs}

              install -Dm644 data/share/applications/org.openbao.baogui.desktop \
                $out/share/applications/org.openbao.baogui.desktop
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

          baogui-android = pkgs.stdenv.mkDerivation {
            pname = "baogui-android";
            version = "0.1.0";
            src = srcTree;

            cargoRoot = "baogui/android";
            cargoDeps = rustPlatformAndroid.importCargoLock {
              lockFile = ./android/Cargo.lock;
              allowBuiltinFetchGit = true;
            };

            nativeBuildInputs = [
              rustAndroid
              pkgs.cargo-apk
              pkgs.jdk17_headless
              pkgs.python3
              rustPlatformAndroid.cargoSetupHook
            ];

            strictDeps = true;
            dontUseCmakeConfigure = true;
            disallowedReferences = [ rustAndroid ];

            ANDROID_HOME = androidSdkRoot;
            ANDROID_SDK_ROOT = androidSdkRoot;
            ANDROID_NDK_HOME = "${androidSdkRoot}/ndk-bundle";
            ANDROID_NDK_ROOT = "${androidSdkRoot}/ndk-bundle";

            buildPhase = ''
              runHook preBuild

              export HOME="$TMPDIR/home"
              mkdir -p "$HOME/.android"

              keystore="$(pwd)/baogui/android/ci.keystore"
              [[ -f "$keystore" ]] || {
                echo "missing CI keystore at $keystore" >&2
                exit 1
              }

              ndk="$ANDROID_NDK_HOME"
              if [[ ! -d "$ndk" ]]; then
                ndk="$(echo "$ANDROID_HOME"/ndk/* | awk '{print $1}')"
                export ANDROID_NDK_HOME="$ndk"
                export ANDROID_NDK_ROOT="$ndk"
              fi
              [[ -d "$ndk" ]] || {
                echo "Android NDK not found under $ANDROID_HOME" >&2
                ls -la "$ANDROID_HOME" >&2 || true
                exit 1
              }

              prebuilt=""
              for host in linux-x86_64 linux-aarch64; do
                if [[ -d "$ndk/toolchains/llvm/prebuilt/$host/bin" ]]; then
                  prebuilt="$ndk/toolchains/llvm/prebuilt/$host/bin"
                  break
                fi
              done
              [[ -n "$prebuilt" ]] || {
                echo "NDK llvm prebuilt toolchain not found under $ndk" >&2
                exit 1
              }
              export PATH="$prebuilt:$PATH"

              export CC_aarch64_linux_android="aarch64-linux-android${androidApiLevel}-clang"
              export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC_aarch64_linux_android"
              export AR_aarch64_linux_android=llvm-ar
              export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR=llvm-ar

              pushd baogui/android >/dev/null
              if ! grep -q 'signing.release' Cargo.toml; then
                python3 - "$keystore" <<'PY'
import pathlib, sys
keystore = sys.argv[1]
path = pathlib.Path("Cargo.toml")
text = path.read_text()
block = f"""
[package.metadata.android.signing.release]
path = "{keystore}"
keystore_password = "android"
key_alias = "androiddebugkey"
key_password = "android"
"""
path.write_text(text + block)
PY
              fi
              cargo apk build --release --target ${androidTarget} -p baogui-android --lib
              popd >/dev/null

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              apk=""
              for cand in \
                baogui/android/target/release/apk/baogui.apk \
                baogui/android/target/baogui.apk \
                baogui/android/target/release/apk/baogui-release.apk; do
                if [[ -f "$cand" ]]; then
                  apk="$cand"
                  break
                fi
              done
              if [[ -z "''${apk:-}" ]]; then
                apk="$(find baogui/android/target -type f -path '*/release/apk/*.apk' ! -name '*-unaligned.apk' 2>/dev/null | head -1 || true)"
              fi
              [[ -n "''${apk:-}" && -f "$apk" ]] || {
                echo "APK not found under baogui/android/target" >&2
                find baogui/android/target -name '*.apk' 2>/dev/null | head -20 >&2 || true
                exit 1
              }
              cp "$apk" $out/baogui.apk
              apksigner="$(echo "$ANDROID_HOME"/build-tools/*/apksigner | awk '{print $NF}')"
              "$apksigner" verify --verbose "$out/baogui.apk"
              "$apksigner" verify --print-certs "$out/baogui.apk" | grep -q 'CN=BaoGUI CI'
              ln -s baogui.apk $out/app.apk
              runHook postInstall
            '';

            meta = {
              description = "BaoGUI Android APK (aarch64)";
              homepage = "https://openbao.org/";
              license = lib.licenses.mit;
            };
          };

          waydroidDisplay = {
            width = "1080";
            height = "2400";
            lcdDensity = "420";
          };
          mkWaydroidApp =
            {
              name,
              release ? false,
            }:
            pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = [
                rustAndroid
                pkgs.cargo-apk
                pkgs.android-tools
                pkgs.jdk17_headless
                pkgs.python3
                pkgs.findutils
                pkgs.gawk
                pkgs.gnugrep
                pkgs.coreutils
                pkgs.bash
                pkgs.procps
              ];
              text = ''
                set -euo pipefail
                export ANDROID_HOME="''${ANDROID_HOME:-${androidSdkRoot}}"
                export ANDROID_SDK_ROOT="''${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
                export ANDROID_NDK_HOME="''${ANDROID_NDK_HOME:-${androidSdkRoot}/ndk-bundle}"
                export ANDROID_NDK_ROOT="''${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
                if [[ ! -d "$ANDROID_NDK_HOME" ]]; then
                  ndk="$(echo "$ANDROID_HOME"/ndk/* | awk '{print $1}')"
                  if [[ -n "''${ndk:-}" && -d "$ndk" ]]; then
                    export ANDROID_NDK_HOME="$ndk"
                    export ANDROID_NDK_ROOT="$ndk"
                  fi
                fi
                export BAOGUI_WAYDROID_WIDTH="''${BAOGUI_WAYDROID_WIDTH:-${waydroidDisplay.width}}"
                export BAOGUI_WAYDROID_HEIGHT="''${BAOGUI_WAYDROID_HEIGHT:-${waydroidDisplay.height}}"
                export BAOGUI_WAYDROID_LCD_DENSITY="''${BAOGUI_WAYDROID_LCD_DENSITY:-${waydroidDisplay.lcdDensity}}"
                export BAOGUI_WAYDROID_SHOW_UI="''${BAOGUI_WAYDROID_SHOW_UI:-1}"
                export BAOGUI_WAYDROID_START_SESSION="''${BAOGUI_WAYDROID_START_SESSION:-1}"
                export BAOGUI_WAYDROID_RELEASE="''${BAOGUI_WAYDROID_RELEASE:-${if release then "1" else "0"}}"
                script=""
                if [[ -f ./scripts/waydroid.sh ]]; then
                  script=./scripts/waydroid.sh
                else
                  script="${./scripts/waydroid.sh}"
                fi
                exec bash "$script" "$@"
              '';
            };
          run-waydroid = mkWaydroidApp { name = "waydroid"; };
          run-waydroid-release = mkWaydroidApp {
            name = "waydroid-release";
            release = true;
          };

          mkEmulatorApp = pkgs.writeShellApplication {
            name = "emulator";
            runtimeInputs = [
              rustAndroid
              pkgs.cargo-apk
              androidSdkEmu
              pkgs.jdk17_headless
              pkgs.python3
              pkgs.coreutils
              pkgs.bash
            ];
            text = ''
              set -euo pipefail
              export ANDROID_HOME="''${ANDROID_HOME:-${androidSdkEmuRoot}}"
              export ANDROID_SDK_ROOT="''${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
              export ANDROID_NDK_HOME="''${ANDROID_NDK_HOME:-${androidSdkRoot}/ndk-bundle}"
              export ANDROID_NDK_ROOT="''${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
              export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
              script=""
              if [[ -f ./scripts/emulator.sh ]]; then
                script=./scripts/emulator.sh
              else
                script="${./scripts/emulator.sh}"
              fi
              exec bash "$script" "$@"
            '';
          };

          run-emulator = mkEmulatorApp;

          mkRunApkApp = pkgs.writeShellApplication {
            name = "run-apk";
            runtimeInputs = [
              rustAndroid
              pkgs.cargo-apk
              androidSdkEmu
              pkgs.jdk17_headless
              pkgs.python3
              pkgs.coreutils
              pkgs.bash
              pkgs.android-tools
            ];
            text = ''
              set -euo pipefail
              export ANDROID_HOME="''${ANDROID_HOME:-${androidSdkEmuRoot}}"
              export ANDROID_SDK_ROOT="''${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
              export ANDROID_NDK_HOME="''${ANDROID_NDK_HOME:-${androidSdkRoot}/ndk-bundle}"
              export ANDROID_NDK_ROOT="''${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
              export PATH="$ANDROID_HOME/emulator:$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
              script=""
              if [[ -f ./scripts/run-apk.sh ]]; then
                script=./scripts/run-apk.sh
              else
                script="${./scripts/run-apk.sh}"
              fi
              exec bash "$script" "$@"
            '';
          };

          run-apk = mkRunApkApp;
        in
        {
          default = baogui;
          inherit baogui;
          android = baogui-android;
          inherit baogui-android;
          waydroid = run-waydroid;
          inherit run-waydroid;
          waydroid-release = run-waydroid-release;
          inherit run-waydroid-release;
          emulator = run-emulator;
          inherit run-emulator;
          inherit run-apk;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;
          libs = eguiLibs pkgs;
          libPath = lib.makeLibraryPath libs;
          appTools = with pkgs; [ pkg-config ];
          requireCargo = ''
            if ! command -v cargo >/dev/null; then
              echo "baogui: cargo not on PATH (install rustup, or: nix develop)" >&2
              exit 1
            fi
            cargo_ver=$(cargo --version | awk '{print $2}')
            if ! printf '%s\n%s\n' "1.85.0" "$cargo_ver" | sort -CV 2>/dev/null; then
              if command -v rustup >/dev/null; then
                echo "→ cargo $cargo_ver too old (need >= 1.85); installing stable via rustup..." >&2
                rustup toolchain install stable
                rustup default stable
              else
                echo "baogui: cargo $cargo_ver is too old (need >= 1.85 for edition2024)" >&2
                echo "  install rustup: https://rustup.rs/" >&2
                exit 1
              fi
            fi
          '';

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
            install -m 644 "$desktop" "$PWD/target/org.openbao.baogui.desktop"
            export XDG_DATA_DIRS="$xdg''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
          '';

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

          baoguiApp = pkgs.writeShellApplication {
            name = "baogui";
            runtimeInputs = appTools;
            text = ''
              ${cargoPreamble libPath}
              ${requireCargo}
              ${stageXdg}

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
          waydroid = {
            type = "app";
            program = "${self.packages.${system}.waydroid}/bin/waydroid";
          };
          waydroid-release = {
            type = "app";
            program = "${self.packages.${system}.waydroid-release}/bin/waydroid-release";
          };
          emulator = {
            type = "app";
            program = "${self.packages.${system}.emulator}/bin/emulator";
          };
          run-apk = {
            type = "app";
            program = "${self.packages.${system}.run-apk}/bin/run-apk";
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
              pkg-config
              glib
              rust-analyzer
            ];
            buildInputs = libs;
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libs;
            RUST_BACKTRACE = "1";
            shellHook = ''
              ${preferSystemEguiLibs}
              if system_egui_libs_ok; then
                unset LD_LIBRARY_PATH
              fi
              echo "BaoGUI dev shell (uses PATH rustc/cargo — not nixpkgs rustc)"
              echo "  nix run / nix run .#baogui   # cargo run (+ staged .desktop/icons)"
              echo "  nix run .#build              # cargo build"
              echo "  cargo run                    # from this shell"
              echo "  nix build .#baogui           # pure package (+ installed .desktop)"
              echo "  nix build .#android          # pure APK (aarch64, CI)"
              echo "  nix run .#waydroid           # cargo-apk x86_64 → Waydroid"
              echo "  nix run .#run-apk            # auto: waydroid | KVM emulator | desktop"
              echo "  nix run .#emulator           # KVM emulator (needs /dev/kvm)"
            '';
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);
    };
}
