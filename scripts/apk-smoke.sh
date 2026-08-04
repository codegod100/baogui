#!/usr/bin/env bash
# APK smoke test — install, launch, verify process is alive.
#
# Usage:
#   ./scripts/apk-smoke.sh --build              # build x86_64 + smoke
#   ./scripts/apk-smoke.sh path/to/baogui.apk   # install existing APK
#   ./scripts/apk-smoke.sh --ci path/to.apk     # exit 1 on failure (for CI/SSH)
#
# Env:
#   BAOGUI_APK_BACKEND=waydroid|emulator|auto
#   BAOGUI_SMOKE_TIMEOUT=30   seconds to wait for process
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="org.openbao.baogui"
CI=0
BUILD=0
APK=""
TIMEOUT="${BAOGUI_SMOKE_TIMEOUT:-30}"

usage() {
  sed -n '2,10p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --ci) CI=1; shift ;;
    --build) BUILD=1; shift ;;
    -*) echo "unknown flag: $1" >&2; usage; exit 1 ;;
    *)
      APK="$1"
      shift
      ;;
  esac
done

fail() {
  echo "apk-smoke: FAIL: $*" >&2
  [[ "$CI" == 1 ]] && exit 1
  exit 1
}

ok() {
  echo "apk-smoke: OK: $*" >&2
}

apk_native_abi() {
  local apk="$1"
  if unzip -l "$apk" 2>/dev/null | grep -q 'lib/arm64-v8a/'; then
    echo arm64
  elif unzip -l "$apk" 2>/dev/null | grep -q 'lib/x86_64/'; then
    echo x86_64
  else
    echo unknown
  fi
}

pick_install_backend() {
  local apk="$1"
  local abi forced="${BAOGUI_APK_BACKEND:-auto}"
  abi="$(apk_native_abi "$apk")"
  case "$forced" in
    waydroid | emulator) echo "$forced"; return ;;
    auto) ;;
    *) fail "unknown BAOGUI_APK_BACKEND=$forced" ;;
  esac
  if [[ "$abi" == arm64 ]]; then
    echo waydroid
  elif [[ -r /dev/kvm ]]; then
    echo emulator
  elif [[ -r /dev/binder ]] || [[ -f "$HOME/.local/share/waydroid/waydroid.cfg" ]]; then
    echo waydroid
  else
    fail "no waydroid/kvm on this host — provision smoke.boxd"
  fi
}

wait_for_pid() {
  local i pid
  for i in $(seq 1 "$TIMEOUT"); do
    pid="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "$pid" ]]; then
      echo "$pid"
      return 0
    fi
    sleep 1
  done
  return 1
}

capture_screenshot() {
  local out="${BAOGUI_SMOKE_SCREENSHOT:-/tmp/baogui-smoke.png}"
  adb shell screencap -p 2>/dev/null | tr -d '\r' >"$out" 2>/dev/null || return 0
  echo "screenshot: $out" >&2
}

verify_running() {
  local pid
  pid="$(wait_for_pid)" || {
    adb logcat -d 2>/dev/null | tail -40 >&2 || true
    fail "process $PKG not running after ${TIMEOUT}s"
  }
  ok "running pid=$pid"
  capture_screenshot
}

smoke_apk() {
  local apk="$1"
  [[ -f "$apk" ]] || fail "APK not found: $apk"

  local backend abi
  abi="$(apk_native_abi "$apk")"
  backend="$(pick_install_backend "$apk")"
  echo "apk-smoke: backend=$backend abi=$abi apk=$apk" >&2

  case "$backend" in
    waydroid)
      export BAOGUI_WAYDROID_START_SESSION=1
      export BAOGUI_WAYDROID_SHOW_UI=1
      bash "$ROOT/scripts/waydroid.sh" install-apk "$apk" >&2
      bash "$ROOT/scripts/waydroid.sh" launch >&2
      verify_running
      ;;
    emulator)
      if [[ "$abi" == arm64 ]]; then
        fail "aarch64 CI APK needs waydroid on smoke.boxd (emulator is x86_64)"
      fi
      bash "$ROOT/scripts/emulator.sh" install "$apk" >&2
      verify_running
      ;;
  esac
}

if [[ "$BUILD" == 1 ]]; then
  apk="$(bash "$ROOT/scripts/waydroid.sh" build)"
  smoke_apk "$apk"
  echo "$apk"
  exit 0
fi

if [[ -z "$APK" ]]; then
  usage
  exit 1
fi

smoke_apk "$APK"
ok "$APK"
