#!/usr/bin/env bash
# Provision smoke.boxd on boxd infrastructure.
#
# Requires: OPENBAO_TOKEN, boxd CLI (~/.local/bin/boxd)
#
#   eval "$(./scripts/boxd-env.sh)"
#   ./scripts/provision-smoke-boxd.sh
#
# Creates machine "smoke" → smoke.boxd.sh, bootstraps APK smoke stack, exposes noVNC.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${BOXD_SMOKE_NAME:-smoke}"
BRANCH="${BOXD_SMOKE_BRANCH:-cursor/nixbuild-apk-ci-8dfd}"
REPO="${BOXD_SMOKE_REPO:-https://github.com/codegod100/baogui.git}"

export PATH="${HOME}/.local/bin:${PATH}"
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need boxd
need jq
need curl

eval "$(BOXD_EXCHANGE_URL="${BOXD_EXCHANGE_URL:-}" "$ROOT/scripts/boxd-env.sh")"
./scripts/boxd-env.sh --check

machine_exists() {
  boxd machine list --json 2>/dev/null | jq -e --arg n "$NAME" '.[] | select(.name == $n)' >/dev/null
}

if machine_exists; then
  echo "boxd machine '$NAME' already exists — ensuring running" >&2
  boxd machine resume "$NAME" 2>/dev/null || true
else
  echo "creating boxd machine: $NAME" >&2
  boxd machine new "$NAME" --json | jq .
fi

echo "bootstrapping smoke stack on $NAME.boxd.sh …" >&2
boxd machine exec "$NAME" -- bash -s <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! id smoke &>/dev/null; then
  sudo useradd -m -s /bin/bash smoke || true
  sudo usermod -aG sudo,kvm,video,render smoke 2>/dev/null || true
  echo 'smoke ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/smoke >/dev/null
fi
sudo mkdir -p /opt/baogui
if [[ ! -d /opt/baogui/.git ]]; then
  sudo git clone --depth 1 -b '$BRANCH' '$REPO' /opt/baogui
else
  cd /opt/baogui && sudo git fetch origin '$BRANCH' && sudo git checkout '$BRANCH' && sudo git pull --ff-only
fi
sudo chown -R boxd:boxd /opt/baogui
if [[ ! -f /etc/systemd/system/smoke-novnc.service ]]; then
  sudo bash /opt/baogui/infra/smoke.boxd/install-raw.sh
fi
REMOTE

echo "pointing https://$NAME.boxd.sh → noVNC (port 6080)…" >&2
boxd machine proxy set-port --vm "$NAME" --port 6080 2>/dev/null || \
  boxd machine exec "$NAME" -- sudo systemctl restart smoke-novnc smoke-vnc 2>/dev/null || true

URL="https://${NAME}.boxd.sh/vnc.html"
echo ""
echo "smoke.boxd ready."
echo "  view:  $URL  (password: smokeboxd)"
echo "  shell: boxd connect $NAME"
echo "  smoke: boxd machine exec $NAME -- bash -lc 'cd /opt/baogui && ./scripts/apk-smoke.sh --build'"
