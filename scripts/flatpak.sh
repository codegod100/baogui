#!/usr/bin/env bash
# Build / install / run the org.openbao.baogui Flatpak.
# Requires: flatpak, flatpak-builder, Flathub remote, sibling ../vidya.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MANIFEST="$ROOT/flatpak/org.openbao.baogui.yml"
BUILD_DIR="$ROOT/flatpak-build"
REPO_DIR="$ROOT/flatpak-repo"
BUNDLE="$ROOT/org.openbao.baogui.flatpak"
APP_ID=org.openbao.baogui

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

ensure_vidya() {
  local vidya
  vidya="$(dirname "$ROOT")/vidya"
  if [[ ! -f "$vidya/Cargo.toml" ]]; then
    echo "→ cloning vidya next to baogui (Cargo path dep)"
    git clone --depth 1 https://tangled.org/nandi.uk/vidya "$vidya"
  fi
}

ensure_builder() {
  need_cmd flatpak
  if ! command -v flatpak-builder >/dev/null 2>&1; then
    echo "flatpak-builder not on PATH; try: nix-shell -p flatpak-builder appstream" >&2
    exit 1
  fi
  if ! command -v appstreamcli >/dev/null 2>&1; then
    echo "appstreamcli not on PATH (needed for metainfo compose); try: nix-shell -p flatpak-builder appstream" >&2
    exit 1
  fi
}

# Smoke-test bubblewrap (flatpak-builder needs this). Hosted CI often blocks
# pivot_root; callers can wrap this script in `docker run --privileged` instead.
bwrap_ok() {
  command -v bwrap >/dev/null 2>&1 || return 1
  bwrap --ro-bind / / --proc /proc --dev /dev --unshare-user --uid 0 --gid 0 \
    /bin/true >/dev/null 2>&1
}

cmd_build() {
  ensure_builder
  ensure_vidya
  if ! bwrap_ok; then
    echo "warning: bubblewrap cannot create a user namespace (pivot_root/userns)." >&2
    echo "  On Buildkite hosted agents, use the privileged Docker path in" >&2
    echo "  .buildkite/pipeline.yml (ghcr.io/flathub-infra/flatpak-github-actions)." >&2
  fi
  mkdir -p "$BUILD_DIR" "$REPO_DIR"
  echo "→ flatpak-builder (install deps from flathub, export repo)"
  flatpak-builder \
    --user \
    --force-clean \
    --disable-rofiles-fuse \
    --install-deps-from=flathub \
    --repo="$REPO_DIR" \
    "$BUILD_DIR" \
    "$MANIFEST"
  echo "→ bundle $BUNDLE"
  flatpak build-bundle "$REPO_DIR" "$BUNDLE" "$APP_ID"
  ls -lh "$BUNDLE"
}

cmd_install() {
  ensure_builder
  if [[ -f "$BUNDLE" ]]; then
    flatpak --user install -y --reinstall "$BUNDLE"
  else
    ensure_vidya
    flatpak-builder \
      --user \
      --force-clean \
      --disable-rofiles-fuse \
      --install-deps-from=flathub \
      --install \
      "$BUILD_DIR" \
      "$MANIFEST"
  fi
}

cmd_run() {
  need_cmd flatpak
  exec flatpak run "$APP_ID" "$@"
}

usage() {
  cat <<EOF
Usage: $0 <build|install|run> [args...]

  build    flatpak-builder → org.openbao.baogui.flatpak (repo export + bundle)
  install  install the bundle (or build+install if no bundle yet)
  run      flatpak run org.openbao.baogui

Needs sibling ../vidya and Flathub (flatpak remote-add --if-not-exists flathub …).
EOF
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  install) shift; cmd_install "$@" ;;
  run) shift; cmd_run "$@" ;;
  -h|--help|help|"") usage; exit 0 ;;
  *)
    echo "unknown command: $1" >&2
    usage >&2
    exit 1
    ;;
esac
