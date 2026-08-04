#!/usr/bin/env bash
# In-tree cargo-apk (x86_64) + Waydroid adb install/launch.
#
# nix run .#waydroid              # debug build + install + launch
# nix run .#waydroid-release      # release build
# nix run .#waydroid -- build     # APK only
# nix run .#waydroid -- launch    # no rebuild
#
# Env (flake app sets SDK/NDK paths):
#   BAOGUI_WAYDROID_WIDTH=1080
#   BAOGUI_WAYDROID_HEIGHT=2400
#   BAOGUI_WAYDROID_LCD_DENSITY=420
#   BAOGUI_WAYDROID_SHOW_UI=1
#   BAOGUI_WAYDROID_START_SESSION=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/android"
PKG="org.openbao.baogui"
ACTIVITY="$PKG/android.app.NativeActivity"
TARGET="${BAOGUI_ANDROID_TARGET:-x86_64-linux-android}"
API_LEVEL="${BAOGUI_ANDROID_API:-28}"

BAOGUI_WAYDROID_WIDTH="${BAOGUI_WAYDROID_WIDTH:-1080}"
BAOGUI_WAYDROID_HEIGHT="${BAOGUI_WAYDROID_HEIGHT:-2400}"
BAOGUI_WAYDROID_LCD_DENSITY="${BAOGUI_WAYDROID_LCD_DENSITY:-420}"
BAOGUI_WAYDROID_SHOW_UI="${BAOGUI_WAYDROID_SHOW_UI:-1}"
BAOGUI_WAYDROID_START_SESSION="${BAOGUI_WAYDROID_START_SESSION:-1}"
RELEASE=0
case "${BAOGUI_WAYDROID_RELEASE:-0}" in
  1 | true | yes | TRUE | YES) RELEASE=1 ;;
esac

export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-$HOME/.local/share/android-ndk-r29}}"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/.local/share/android-sdk}}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

need() { command -v "$1" >/dev/null || { echo "missing: $1 (use: nix run .#waydroid)" >&2; exit 1; }; }

need cargo
need cargo-apk
need rustc

if [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]]; then
  prebuilt=""
  for host in linux-x86_64 linux-aarch64; do
    if [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin" ]]; then
      prebuilt="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host/bin"
      break
    fi
  done
  if [[ -n "$prebuilt" ]]; then
    export PATH="$prebuilt:$PATH"
  fi
fi
if [[ -d "$ANDROID_HOME/platform-tools" ]]; then
  export PATH="$ANDROID_HOME/platform-tools:$PATH"
fi
export PATH="${HOME}/.cargo/bin:$PATH"

triple_upper="$(echo "$TARGET" | tr '[:lower:]-' '[:upper:]_')"
clang_bin="${TARGET}${API_LEVEL}-clang"
export "CC_${TARGET//-/_}=$clang_bin"
export "CARGO_TARGET_${triple_upper}_LINKER=$clang_bin"
export "AR_${TARGET//-/_}=llvm-ar"
export "CARGO_TARGET_${triple_upper}_AR=llvm-ar"

if ! rustc --print sysroot --target "$TARGET" >/dev/null 2>&1; then
  echo "error: rustc missing target $TARGET" >&2
  echo "  rustup target add $TARGET  # or: nix run .#waydroid" >&2
  exit 1
fi

[[ -f "$APP/Cargo.toml" ]] || {
  echo "error: android crate not found at $APP" >&2
  exit 1
}

waydroid_ip() {
  waydroid status 2>/dev/null | awk -F': *' '/IP address/{gsub(/[[:space:]]/,"",$2); print $2; exit}'
}

session_running() {
  waydroid status 2>/dev/null | grep -q 'Session:.*RUNNING'
}

apply_waydroid_config() {
  local w h d cur
  w="$BAOGUI_WAYDROID_WIDTH"
  h="$BAOGUI_WAYDROID_HEIGHT"
  d="$BAOGUI_WAYDROID_LCD_DENSITY"
  echo "waydroid display: ${w}x${h} density=${d}" >&2
  if ! session_running && [[ "${BAOGUI_WAYDROID_START_SESSION}" != "1" ]]; then
    return 0
  fi
  set_prop_if_needed() {
    local key="$1" want="$2"
    cur="$(waydroid prop get "$key" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$cur" == "$want" ]] && return 0
    waydroid prop set "$key" "$want" >/dev/null 2>&1 || true
  }
  set_prop_if_needed persist.waydroid.width "$w"
  set_prop_if_needed persist.waydroid.height "$h"
  set_prop_if_needed persist.waydroid.lcd_density "$d"
  set_prop_if_needed ro.sf.lcd_density "$d"
}

ensure_session() {
  if session_running; then
    return 0
  fi
  if [[ "${BAOGUI_WAYDROID_START_SESSION}" != "1" ]]; then
    echo "Waydroid session not RUNNING — start with: waydroid session start" >&2
    exit 1
  fi
  echo "starting Waydroid session…" >&2
  if [[ -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
    if [[ -n "${XDG_RUNTIME_DIR:-}" && -S "${XDG_RUNTIME_DIR}/wayland-0" ]]; then
      export WAYLAND_DISPLAY=wayland-0
    elif [[ -S /tmp/.X11-unix/X0 ]]; then
      export DISPLAY=:0
    fi
  fi
  waydroid session start >/dev/null 2>&1 &
  local i
  for i in $(seq 1 60); do
    if session_running; then
      echo "Waydroid session RUNNING" >&2
      return 0
    fi
    sleep 0.5
  done
  echo "error: Waydroid session failed to start" >&2
  waydroid status >&2 || true
  exit 1
}

ensure_adb() {
  need waydroid
  need adb
  ensure_session
  mkdir -p "$HOME/.android" "$HOME/.local/share/waydroid/data/misc/adb"
  [[ -f "$HOME/.android/adbkey" ]] || adb keygen "$HOME/.android/adbkey"
  cp "$HOME/.android/adbkey.pub" "$HOME/.local/share/waydroid/data/misc/adb/adb_keys" 2>/dev/null || true
  local ip
  ip="$(waydroid_ip)"
  ip="${ip:-192.168.240.112}"
  waydroid adb connect >/dev/null 2>&1 || adb connect "${ip}:5555" >/dev/null 2>&1 || true
  local _
  for _ in $(seq 1 40); do
    if adb devices 2>/dev/null | tr -d '\r' | grep -qE "${ip}:5555[[:space:]]+device"; then
      export ANDROID_SERIAL="${ip}:5555"
      export WAYDROID_IP="$ip"
      echo "ADB ready: $ANDROID_SERIAL" >&2
      return 0
    fi
    sleep 0.5
  done
  echo "ADB not ready for ${ip}:5555" >&2
  adb devices -l >&2 || true
  exit 1
}

ensure_full_ui() {
  [[ "${BAOGUI_WAYDROID_SHOW_UI}" == "1" ]] || return 0
  if pgrep -a waydroid 2>/dev/null | grep -qE 'show-full-ui|first-launch'; then
    return 0
  fi
  echo "Opening Waydroid full UI (${BAOGUI_WAYDROID_WIDTH}x${BAOGUI_WAYDROID_HEIGHT})…" >&2
  nohup waydroid show-full-ui >/dev/null 2>&1 &
  local _
  for _ in $(seq 1 30); do
    if pgrep -a waydroid 2>/dev/null | grep -qE 'show-full-ui|first-launch'; then
      sleep 0.5
      return 0
    fi
    if adb shell dumpsys window 2>/dev/null | grep -q 'mCurrentFocus'; then
      sleep 0.5
      return 0
    fi
    sleep 0.3
  done
}

writable_apk_stage() {
  local profile="$1"
  local stage
  for stage in "$APP/target/${profile}/apk" "$APP/target/apk" "$APP/target"; do
    [[ -d "$stage" ]] && chmod -R u+w "$stage" 2>/dev/null || true
  done
  rm -f "$APP/target/${profile}/apk/"*-unaligned.apk 2>/dev/null || true
}

find_apk() {
  local profile="$1"
  local apk="" dir="$APP/target/${profile}/apk"
  for cand in "$dir/baogui.apk" "$APP/target/baogui.apk" "$dir/baogui-${profile}.apk"; do
    [[ -f "$cand" ]] && { echo "$cand"; return 0; }
  done
  apk="$(find "$APP/target" -type f -path "*/${profile}/apk/*.apk" ! -name '*-unaligned.apk' 2>/dev/null | head -1 || true)"
  [[ -n "${apk:-}" && -f "$apk" ]] || return 1
  echo "$apk"
}

ensure_release_signing() {
  local keystore="$APP/ci.keystore"
  [[ -f "$keystore" ]] || {
    need keytool
    keystore="$HOME/.android/baogui-release.keystore"
    [[ -f "$keystore" ]] || keytool -genkeypair -v -keystore "$keystore" -storepass android \
      -alias androiddebugkey -keypass android -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=BaoGUI Local,O=OpenBao,C=US" >&2
  }
  if ! grep -q 'signing.release' "$APP/Cargo.toml"; then
    python3 - "$APP/Cargo.toml" "$keystore" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
keystore = sys.argv[2]
block = f"""
[package.metadata.android.signing.release]
path = "{keystore}"
keystore_password = "android"
key_alias = "androiddebugkey"
key_password = "android"
"""
path.write_text(path.read_text() + block)
PY
  fi
}

build_apk() {
  [[ -d "$ANDROID_NDK_HOME" ]] || { echo "Set ANDROID_NDK_HOME=$ANDROID_NDK_HOME" >&2; exit 1; }
  [[ -d "$ANDROID_HOME" ]] || { echo "Set ANDROID_HOME=$ANDROID_HOME" >&2; exit 1; }

  local profile=debug
  local -a apk_args=(build --target "$TARGET" -p baogui-android --lib)
  if [[ "$RELEASE" -eq 1 ]]; then
    profile=release
    apk_args+=(--release)
    ensure_release_signing
  fi

  echo "cargo apk ${apk_args[*]} → $APP" >&2
  writable_apk_stage "$profile"
  (
    cd "$APP"
    [[ "${BAOGUI_WAYDROID_CLEAN:-0}" == "1" ]] && cargo clean -p baogui-android --target "$TARGET" >&2 2>/dev/null || true
    cargo apk "${apk_args[@]}" >&2
  )
  find_apk "$profile"
}

install_apk() {
  local apk="$1"
  ensure_adb
  apply_waydroid_config
  echo "install $apk" >&2
  if waydroid app install "$apk" >&2; then
    return 0
  fi
  adb install -r "$apk" >&2
}

launch_app() {
  ensure_adb
  apply_waydroid_config
  ensure_full_ui
  adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  adb shell am start -n "$ACTIVITY" >&2
  sleep 0.8
  local pid
  pid="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "$pid" ]]; then
    echo "warning: process not running — try: adb logcat | grep -i baogui" >&2
  else
    echo "Launched $PKG (pid $pid) on ${WAYDROID_IP:-waydroid}" >&2
  fi
}

usage() {
  cat <<EOF
usage: $0 [--release] [build|install|install-apk|launch|run]
  run (default)  build + install + launch
  install-apk PATH  install an existing APK (no rebuild)
EOF
}

cmd=run
extra=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --release) RELEASE=1; shift ;;
    build | install | install-apk | launch | run) cmd="$1"; shift ;;
    *)
      if [[ "$cmd" == "install-apk" && -z "$extra" ]]; then
        extra="$1"
        shift
      else
        echo "unknown: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

case "$cmd" in
  build) build_apk ;;
  install) install_apk "$(build_apk)" ;;
  install-apk)
    [[ -n "$extra" && -f "$extra" ]] || {
      echo "usage: $0 install-apk PATH.apk" >&2
      exit 1
    }
    install_apk "$extra"
    ;;
  launch) launch_app ;;
  run)
    apk="$(build_apk)"
    install_apk "$apk"
    launch_app
    echo "$apk"
    ;;
esac
