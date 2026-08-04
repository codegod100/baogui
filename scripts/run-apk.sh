#!/usr/bin/env bash
# Pick the fastest way to run BaoGUI on this host.
#
# nix run .#run-apk
#
# Backends (auto):
#   waydroid  — binder container (fastest on Linux desktop; needs waydroid session)
#   emulator  — KVM x86_64 AVD (fast with /dev/kvm)
#   desktop   — native egui binary (fastest when Android runtimes unavailable)
#
# Force: BAOGUI_APK_BACKEND=waydroid|emulator|desktop
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

have_kvm() { [[ -r /dev/kvm ]]; }

waydroid_usable() {
  command -v waydroid >/dev/null 2>&1 || return 1
  [[ -f "$HOME/.local/share/waydroid/waydroid.cfg" ]] || \
    waydroid status 2>/dev/null | grep -q 'Version:'
}

pick_backend() {
  local forced="${BAOGUI_APK_BACKEND:-auto}"
  case "$forced" in
    waydroid | emulator | desktop) echo "$forced"; return ;;
    auto) ;;
    *)
      echo "unknown BAOGUI_APK_BACKEND=$forced" >&2
      exit 1
      ;;
  esac

  if waydroid_usable; then
    echo waydroid
  elif have_kvm; then
    echo emulator
  else
    echo desktop
  fi
}

backend="$(pick_backend)"
echo "baogui run-apk: backend=$backend" >&2

case "$backend" in
  waydroid)
    exec bash "$ROOT/scripts/waydroid.sh" run "$@"
    ;;
  emulator)
    exec bash "$ROOT/scripts/emulator.sh" run "$@"
    ;;
  desktop)
    echo "No Waydroid/KVM on this host — running native desktop (same UI, much faster)." >&2
    if [[ -f "$ROOT/flake.nix" ]] && command -v nix >/dev/null 2>&1; then
      exec nix run "$ROOT#baogui" -- "$@"
    fi
    exec cargo run --manifest-path "$ROOT/Cargo.toml" -- "$@"
    ;;
esac
