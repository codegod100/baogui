# smoke.boxd

Raw Linux machine for **BaoGUI APK smoke testing** with a browser-viewable desktop.

## What it gives you

- **Waydroid** (fast) or **KVM emulator** fallback — same backends as `nix run .#run-apk`
- **noVNC** — open `https://smoke.boxd.sh/vnc.html` and watch the Android UI
- **`scripts/apk-smoke.sh`** — install APK, launch, verify process (CI-friendly)
- **SSH** — connect, debug with `adb logcat`, `scrcpy`

## Provision

### Option A: NixOS (recommended for boxd)

1. Create an x86_64 VM with **nested KVM** enabled (or bare metal).
2. Add your SSH public key to `configuration.nix` → `users.users.smoke.openssh.authorizedKeys`.
3. Install:

   ```bash
   nixos-install --flake github:codegod100/baogui#smoke-boxd
   ```

   Or from a checkout:

   ```bash
   cd infra/smoke.boxd && nixos-install --flake .#smoke-boxd
   ```

4. Point **DNS** `smoke.boxd.sh` → the host's public IP.

### Option B: Raw Debian/Ubuntu

On a fresh root shell:

```bash
git clone https://github.com/codegod100/baogui.git /opt/baogui
sudo /opt/baogui/infra/smoke.boxd/install-raw.sh
```

## Connect and view

| What | How |
|------|-----|
| Desktop (browser) | `https://smoke.boxd.sh/vnc.html` (default password `smokeboxd` — change it) |
| SSH | `ssh smoke@smoke.boxd.sh` |
| Manual APK run | `cd ~/baogui && nix run .#run-apk` |
| Automated smoke | `./scripts/apk-smoke.sh /path/to/baogui.apk` |

## Smoke test script

```bash
# Build x86_64 APK locally and smoke-test (Waydroid/emulator)
./scripts/apk-smoke.sh --build

# Test a CI artifact (aarch64 — needs emulator or physical device path)
./scripts/apk-smoke.sh result-android/baogui.apk

# Headless CI mode (exit 1 on failure)
./scripts/apk-smoke.sh --ci result-android/baogui.apk
```

### Provision on boxd

```bash
eval "$(./scripts/boxd-env.sh)"   # BOXD_API_KEY from OpenBao → JWT
./scripts/provision-smoke-boxd.sh
```

CI uses the same OpenBao `BOXD_API_KEY` and `boxd machine exec smoke` for APK smoke tests.

## Requirements

| Requirement | Why |
|-------------|-----|
| x86_64 + `/dev/kvm` | Emulator path; Waydroid still benefits from a real GPU |
| ~4 GB RAM minimum | Waydroid + desktop |
| `binder` kernel module | Waydroid (may need `linux-modules-extra` + reboot) |
| DNS `smoke.boxd.sh` | TLS + noVNC via nginx (NixOS profile) |

## Architecture

```
┌─────────────────────────────────────────┐
│  smoke.boxd.sh                          │
│  ┌─────────┐   ┌──────────┐   ┌───────┐ │
│  │ noVNC   │──▶│ XFCE/VNC │──▶│Waydroid│ │
│  │ :443    │   │ :5901    │   │  APK  │ │
│  └─────────┘   └──────────┘   └───────┘ │
│       ▲              ▲              ▲    │
│       │              │              │    │
│   browser         SSH          apk-smoke │
└─────────────────────────────────────────┘
```
