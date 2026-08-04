#!/usr/bin/env bash
# Prove whether Waydroid can run on this host (boxd microVM or otherwise).
# Exit 0 only if binder exists and waydroid reports RUNNING or initialized.
set -euo pipefail

fail() { echo "waydroid-proof: FAIL: $*" >&2; exit 1; }
ok() { echo "waydroid-proof: OK: $*" >&2; }

echo "=== waydroid proof ==="
echo "host: $(hostname -f 2>/dev/null || hostname)"
echo "kernel: $(uname -r)"
echo ""

echo "=== /dev nodes ==="
for dev in /dev/binder /dev/kvm /dev/ashmem; do
  if [[ -e "$dev" ]]; then echo "  $dev: present"; else echo "  $dev: MISSING"; fi
done
echo ""

command -v waydroid >/dev/null || fail "waydroid not installed"
echo "waydroid: $(waydroid --version)"
waydroid status 2>&1 || true
echo ""

if [[ ! -e /dev/binder ]]; then
  fail "no /dev/binder — boxd microVM kernel 6.1.0+ lacks binder_linux (waydroid cannot run)"
fi

if ! waydroid status 2>/dev/null | grep -q 'Session.*RUNNING'; then
  echo "attempting waydroid init…" >&2
  sudo waydroid init -s GAPPS -f >&2 || fail "waydroid init failed"
fi

ok "binder present; waydroid initialized"
