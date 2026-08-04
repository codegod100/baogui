#!/usr/bin/env bash
# KVM-accelerated Android Emulator (x86_64 APK). Prefer Waydroid when binder works.
#
# nix run .#emulator              # build + install + launch
# nix run .#emulator -- build     # APK only
#
# Requires /dev/kvm for acceptable performance. Without KVM, use:
#   nix run .#run-apk             # auto-picks fastest backend (desktop on cloud VMs)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/android"
PKG="org.openbao.baogui"
ACTIVITY="$PKG/android.app.NativeActivity"
AVD_NAME="${BAOGUI_AVD_NAME:-baogui}"
PLATFORM="${BAOGUI_EMU_PLATFORM:-34}"
ABI="x86_64"
IMAGE_TYPE="${BAOGUI_EMU_IMAGE:-google_apis}"
IMAGE_PKG="system-images;android-${PLATFORM};${IMAGE_TYPE};${ABI}"

export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$HOME/.android}"
mkdir -p "$ANDROID_AVD_HOME" "$ANDROID_USER_HOME"

need() { command -v "$1" >/dev/null || { echo "missing: $1 (nix run .#emulator)" >&2; exit 1; }; }

build_apk() {
  bash "$ROOT/scripts/waydroid.sh" build
}

accel_flags() {
  if [[ -r /dev/kvm ]] && "${BAOGUI_EMU_FORCE_SOFTWARE:-0}" != "1"; then
    echo "-accel on -gpu host"
  else
    echo "-accel off -gpu swiftshader_indirect"
  fi
}

emulator_flags() {
  local accel
  accel="$(accel_flags)"
  # -no-snapshot-save: faster shutdown; AVD still boots from disk image.
  echo "-no-boot-anim -no-audio -no-metrics $accel"
}

ensure_avd() {
  need avdmanager
  if avdmanager list avd 2>/dev/null | grep -q "Name: ${AVD_NAME}"; then
    return 0
  fi
  echo "creating AVD ${AVD_NAME} (${IMAGE_PKG})…" >&2
  if ! sdkmanager --install "$IMAGE_PKG" >&2; then
    echo "error: install system image: $IMAGE_PKG" >&2
    exit 1
  fi
  echo no | avdmanager create avd --force -n "$AVD_NAME" -k "$IMAGE_PKG" \
    -d "pixel_6" -p "$ANDROID_AVD_HOME/${AVD_NAME}.avd" >&2
  # Lean config for faster boot.
  local cfg="$ANDROID_AVD_HOME/${AVD_NAME}.avd/config.ini"
  if [[ -f "$cfg" ]]; then
    {
      echo "hw.ramSize=2048"
      echo "hw.cpu.ncore=4"
      echo "disk.dataPartition.size=2G"
      echo "fastboot.forceColdBoot=no"
    } >>"$cfg"
  fi
}

start_emulator() {
  need emulator
  ensure_avd
  local port serial emu_pid
  for port in $(seq 5554 2 5584); do
    serial="emulator-${port}"
    if ! adb devices 2>/dev/null | tr -d '\r' | grep -q "^${serial}[[:space:]]"; then
      break
    fi
    port=""
  done
  [[ -n "$port" ]] || { echo "no free emulator port" >&2; exit 1; }
  serial="emulator-${port}"
  export ANDROID_SERIAL="$serial"

  if adb -s "$serial" get-state 2>/dev/null | grep -q device; then
    echo "emulator already running: $serial" >&2
    return 0
  fi

  if [[ ! -r /dev/kvm ]]; then
    echo "warning: /dev/kvm missing — emulator will be very slow on this host" >&2
    echo "  use: nix run .#run-apk  (falls back to native desktop)" >&2
  fi

  echo "starting emulator $serial (AVD ${AVD_NAME})…" >&2
  # shellcheck disable=SC2046
  "$ANDROID_HOME/emulator/emulator" -avd "$AVD_NAME" -port "$port" $(emulator_flags) &
  emu_pid=$!

  adb -s "$serial" wait-for-device
  local i
  for i in $(seq 1 120); do
    if adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -q '^1$'; then
      echo "emulator booted ($serial)" >&2
      return 0
    fi
    if ! kill -0 "$emu_pid" 2>/dev/null; then
      echo "emulator exited during boot" >&2
      exit 1
    fi
    sleep 1
  done
  echo "emulator boot timed out" >&2
  exit 1
}

install_and_launch() {
  local apk="$1"
  need adb
  start_emulator
  echo "installing $apk…" >&2
  adb install -r "$apk" >&2
  adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
  adb shell am start -n "$ACTIVITY" >&2
}

cmd="${1:-run}"
shift || true
case "$cmd" in
  build) build_apk ;;
  run)
    apk="$(build_apk)"
    install_and_launch "$apk"
    echo "$apk"
    ;;
  *)
    echo "usage: $0 [build|run]" >&2
    exit 1
    ;;
esac
