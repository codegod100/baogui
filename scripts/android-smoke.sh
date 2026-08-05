#!/usr/bin/env bash
# APK smoke via budtmo/docker-android (x86_64 emulator in Docker + noVNC).
#
# nix run .#android-smoke              # build + install + launch + verify
# nix run .#android-smoke -- build     # APK only
# nix run .#android-smoke -- install PATH.apk
# ./scripts/android-smoke.sh --ci      # exit 1 on failure
#
# Requires: docker (daemon), adb, cargo-apk (+ ANDROID_* for build).
# Prefers /dev/kvm; without KVM, patches the image to allow -accel off
# (very slow — OK for smoke, not interactive use).
#
# Env:
#   BAOGUI_DOCKER_ANDROID_IMAGE=budtmo/docker-android:emulator_11.0
#   BAOGUI_DOCKER_ANDROID_NAME=baogui-android-smoke
#   BAOGUI_DOCKER_ANDROID_DEVICE=Nexus 5
#   BAOGUI_DOCKER_ANDROID_VNC_PORT=6080
#   BAOGUI_DOCKER_ANDROID_ADB_PORT=5555
#   BAOGUI_DOCKER_ANDROID_KEEP=0          # 1 = leave container running
#   BAOGUI_DOCKER_ANDROID_FORCE_SOFT=0    # 1 = software accel even with KVM
#   BAOGUI_SMOKE_TIMEOUT=90
#   BAOGUI_SMOKE_BOOT_TIMEOUT=600
#   BAOGUI_SMOKE_SCREENSHOT=/tmp/baogui-android-smoke.png
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="org.openbao.baogui"
ACTIVITY="$PKG/android.app.NativeActivity"

IMAGE="${BAOGUI_DOCKER_ANDROID_IMAGE:-budtmo/docker-android:emulator_11.0}"
NAME="${BAOGUI_DOCKER_ANDROID_NAME:-baogui-android-smoke}"
DEVICE="${BAOGUI_DOCKER_ANDROID_DEVICE:-Nexus 5}"
VNC_PORT="${BAOGUI_DOCKER_ANDROID_VNC_PORT:-6080}"
ADB_PORT="${BAOGUI_DOCKER_ANDROID_ADB_PORT:-5555}"
KEEP="${BAOGUI_DOCKER_ANDROID_KEEP:-0}"
FORCE_SOFT="${BAOGUI_DOCKER_ANDROID_FORCE_SOFT:-0}"
TIMEOUT="${BAOGUI_SMOKE_TIMEOUT:-90}"
BOOT_TIMEOUT="${BAOGUI_SMOKE_BOOT_TIMEOUT:-600}"
SCREENSHOT="${BAOGUI_SMOKE_SCREENSHOT:-/tmp/baogui-android-smoke.png}"

CI=0
CMD="run"
APK=""

usage() {
  sed -n '2,22p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --ci) CI=1; shift ;;
    build | run | install)
      CMD="$1"
      shift
      ;;
    -*)
      echo "android-smoke: unknown flag: $1" >&2
      usage
      exit 1
      ;;
    *)
      APK="$1"
      shift
      ;;
  esac
done

log() { echo "android-smoke: $*" >&2; }
fail() {
  log "FAIL: $*"
  exit 1
}
ok() { log "OK: $*"; }

need() { command -v "$1" >/dev/null || fail "missing: $1"; }

have_kvm() {
  [[ "${FORCE_SOFT}" != "1" && -r /dev/kvm ]]
}

SERIAL="127.0.0.1:${ADB_PORT}"

cleanup() {
  if [[ "${KEEP}" == "1" ]]; then
    log "keeping container ${NAME} (BAOGUI_DOCKER_ANDROID_KEEP=1); noVNC http://127.0.0.1:${VNC_PORT}"
    return 0
  fi
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_apk() {
  bash "$ROOT/scripts/waydroid.sh" build
}

patch_dir() {
  echo "${TMPDIR:-/tmp}/baogui-docker-android-patch.$$"
}

# Upstream hard-fails without /dev/kvm. Soften to -accel off for smoke hosts.
prepare_soft_accel_patch() {
  local dir emu
  dir="$(patch_dir)"
  mkdir -p "$dir"
  need docker
  docker pull "$IMAGE" >/dev/null
  docker create --name "${NAME}-extract" "$IMAGE" >/dev/null
  docker cp "${NAME}-extract:/home/androidusr/docker-android/cli/src/device/emulator.py" "$dir/emulator.py"
  docker rm -f "${NAME}-extract" >/dev/null

  emu="$dir/emulator.py"
  python3 - "$emu" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old_perm = '''    def change_permission(self) -> None:
        kvm_path = "/dev/kvm"
        if os.path.exists(kvm_path):
            cmds = (f"sudo chown 1300:1301 {kvm_path}",
                    "sudo sed -i '1d' /etc/passwd")
            for c in cmds:
                subprocess.check_call(c, shell=True)
            self.logger.info("KVM permission is granted!")
        else:
            raise RuntimeError("/dev/kvm cannot be found!")'''
new_perm = '''    def change_permission(self) -> None:
        kvm_path = "/dev/kvm"
        if os.path.exists(kvm_path):
            cmds = (f"sudo chown 1300:1301 {kvm_path}",
                    "sudo sed -i '1d' /etc/passwd")
            for c in cmds:
                subprocess.check_call(c, shell=True)
            self.logger.info("KVM permission is granted!")
            self._accel = "on"
        else:
            self.logger.warning("/dev/kvm not found — falling back to software accel (-accel off)")
            self._accel = "off"'''
if old_perm not in text:
    raise SystemExit("android-smoke: unexpected emulator.py (change_permission)")
text = text.replace(old_perm, new_perm)
old_deploy = 'basic_args = "-gpu swiftshader_indirect -accel on -writable-system -verbose"'
new_deploy = 'basic_args = f"-gpu swiftshader_indirect -accel {getattr(self, \'_accel\', \'on\')} -no-audio -no-boot-anim -writable-system -verbose"'
if old_deploy not in text:
    raise SystemExit("android-smoke: unexpected emulator.py (deploy args)")
text = text.replace(old_deploy, new_deploy)
p.write_text(text)
print(p)
PY
}

start_container() {
  need docker
  docker rm -f "${NAME}" >/dev/null 2>&1 || true

  local -a run_args=(
    run -d --name "${NAME}"
    -p "${VNC_PORT}:6080"
    -p "${ADB_PORT}:5555"
    -p "$((ADB_PORT - 1)):5554"
    -e "EMULATOR_DEVICE=${DEVICE}"
    -e WEB_VNC=true
    -e APPIUM=false
    -e EMULATOR_NO_SKIN=true
  )

  if have_kvm; then
    log "starting ${IMAGE} with /dev/kvm (device=${DEVICE})"
    run_args+=(--device /dev/kvm --privileged)
  else
    log "no /dev/kvm — starting ${IMAGE} with software accel patch (slow)"
    local patch
    patch="$(prepare_soft_accel_patch)"
    run_args+=(
      --privileged
      -v "${patch}:/home/androidusr/docker-android/cli/src/device/emulator.py:ro"
    )
  fi

  run_args+=("$IMAGE")
  docker "${run_args[@]}" >/dev/null
  ok "container ${NAME} started; noVNC http://127.0.0.1:${VNC_PORT}"
}

ctr_exec() {
  # device_status / logs live under the androidusr home directory.
  docker exec -u androidusr -w /home/androidusr "${NAME}" "$@"
}

emulator_alive() {
  # AVD creation runs before qemu; allow a grace window.
  if ctr_exec bash -lc 'pgrep -f qemu-system >/dev/null || pgrep -f "/emulator/emulator" >/dev/null'; then
    return 0
  fi
  # Still starting (device supervisor / avdmanager) counts as alive early on.
  ctr_exec bash -lc 'pgrep -f "docker-android start device" >/dev/null'
}

wait_for_boot() {
  need adb
  local status boot svc pm elapsed=0
  local grace="${BAOGUI_DOCKER_ANDROID_BOOT_GRACE:-90}"
  log "waiting for emulator boot (timeout ${BOOT_TIMEOUT}s)…"
  while [[ "$elapsed" -lt "$BOOT_TIMEOUT" ]]; do
    status="$(ctr_exec cat device_status 2>/dev/null || echo UNKNOWN)"
    adb connect "${SERIAL}" >/dev/null 2>&1 || true
    boot="$(adb -s "${SERIAL}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    svc="$(adb -s "${SERIAL}" shell service check package 2>/dev/null | tr -d '\r' || true)"
    pm="$(adb -s "${SERIAL}" shell pm path android 2>/dev/null | tr -d '\r' || true)"
    if [[ "$boot" == "1" ]] && echo "$svc" | grep -q 'found' && [[ "$pm" == package:* ]]; then
      # Soften first-boot ANRs / setup wizards that block installs.
      adb -s "${SERIAL}" shell settings put global device_provisioned 1 >/dev/null 2>&1 || true
      adb -s "${SERIAL}" shell settings put secure user_setup_complete 1 >/dev/null 2>&1 || true
      # Software-accel images often flap package manager right after boot_completed.
      sleep 10
      pm="$(adb -s "${SERIAL}" shell pm path android 2>/dev/null | tr -d '\r' || true)"
      if [[ "$pm" != package:* ]]; then
        log "package manager flapped after boot_completed — continuing to wait…"
        sleep 5
        elapsed=$((elapsed + 15))
        continue
      fi
      ok "emulator ready (status=${status} serial=${SERIAL})"
      export ANDROID_SERIAL="${SERIAL}"
      return 0
    fi
    if [[ "$elapsed" -ge "$grace" ]] && ! emulator_alive; then
      ctr_exec bash -lc 'tail -80 logs/device.stdout.log 2>/dev/null; tail -40 logs/device.stderr.log 2>/dev/null' >&2 || true
      fail "emulator process died during boot (device_status=${status})"
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  fail "emulator boot timed out after ${BOOT_TIMEOUT}s (status=$(ctr_exec cat device_status 2>/dev/null || echo UNKNOWN))"
}

wait_for_package_manager() {
  local i pm svc
  for i in $(seq 1 60); do
    adb connect "${SERIAL}" >/dev/null 2>&1 || true
    svc="$(adb -s "${SERIAL}" shell service check package 2>/dev/null | tr -d '\r' || true)"
    pm="$(adb -s "${SERIAL}" shell pm path android 2>/dev/null | tr -d '\r' || true)"
    if echo "$svc" | grep -q 'found' && [[ "$pm" == package:* ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

install_and_launch() {
  local apk="$1" attempt
  [[ -f "$apk" ]] || fail "APK not found: $apk"
  need adb
  export ANDROID_SERIAL="${SERIAL}"
  adb connect "${SERIAL}" >/dev/null 2>&1 || true
  adb -s "${SERIAL}" wait-for-device
  wait_for_package_manager || fail "package manager not stable after boot"
  log "installing $apk…"
  for attempt in 1 2 3 4 5; do
    if adb -s "${SERIAL}" install -r -t "$apk" >&2; then
      break
    fi
    [[ "$attempt" -eq 5 ]] && fail "adb install failed after ${attempt} attempts"
    log "adb install attempt $attempt failed — retrying…"
    wait_for_package_manager || true
    sleep 5
  done
  adb -s "${SERIAL}" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  adb -s "${SERIAL}" logcat -c >/dev/null 2>&1 || true
  log "launching $ACTIVITY…"
  for attempt in 1 2 3 4 5; do
    if adb -s "${SERIAL}" shell am start -n "$ACTIVITY" >&2; then
      break
    fi
    [[ "$attempt" -eq 5 ]] && fail "am start failed after ${attempt} attempts"
    sleep 3
  done
}

wait_for_pid() {
  local i pid
  for i in $(seq 1 "$TIMEOUT"); do
    pid="$(adb -s "${SERIAL}" shell pidof "$PKG" 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "$pid" ]]; then
      echo "$pid"
      return 0
    fi
    sleep 1
  done
  return 1
}

capture_screenshot() {
  adb -s "${SERIAL}" exec-out screencap -p >"$SCREENSHOT" 2>/dev/null || return 0
  log "screenshot: $SCREENSHOT"
}

verify_running() {
  local pid
  pid="$(wait_for_pid)" || {
    adb -s "${SERIAL}" logcat -d 2>/dev/null | grep -iE 'baogui|AndroidRuntime|FATAL' | tail -60 >&2 || true
    fail "process $PKG not running after ${TIMEOUT}s"
  }
  ok "running pid=$pid"
  # Give egui a moment to paint, then dismiss common ANR overlays if present.
  sleep 5
  adb -s "${SERIAL}" shell am force-stop com.google.android.apps.nexuslauncher >/dev/null 2>&1 || true
  sleep 1
  capture_screenshot
}

smoke() {
  local apk="$1"
  start_container
  wait_for_boot
  install_and_launch "$apk"
  verify_running
  ok "docker-android smoke passed ($apk)"
  echo "$apk"
}

case "$CMD" in
  build)
    apk="$(build_apk)"
    echo "$apk"
    # Avoid tearing down a container we never started.
    trap - EXIT
    ;;
  install)
    [[ -n "$APK" && -f "$APK" ]] || fail "usage: $0 install PATH.apk"
    smoke "$APK"
    ;;
  run)
    if [[ -n "$APK" ]]; then
      [[ -f "$APK" ]] || fail "APK not found: $APK"
      smoke "$APK"
    else
      apk="$(build_apk)"
      smoke "$apk"
    fi
    ;;
  *)
    fail "usage: $0 [build|run|install PATH] [--ci]"
    ;;
esac
