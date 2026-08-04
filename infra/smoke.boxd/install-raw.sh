#!/usr/bin/env bash
# Bootstrap smoke.boxd on a raw Debian/Ubuntu x86_64 machine (no NixOS).
#
# Run as root on a fresh VM with nested KVM:
#   curl -fsSL https://raw.githubusercontent.com/.../install-raw.sh | bash
# Or from this repo:
#   sudo ./infra/smoke.boxd/install-raw.sh
#
# After install:
#   - SSH as smoke@smoke.boxd.sh
#   - View desktop: http://<host>:6080/vnc.html  (password: smokeboxd)
#   - Run smoke:    sudo -u smoke ~/baogui/scripts/apk-smoke.sh --build
set -euo pipefail

SMOKE_USER="${SMOKE_USER:-smoke}"
SMOKE_HOME="/home/$SMOKE_USER"
VNC_PASS="${SMOKE_VNC_PASSWORD:-smokeboxd}"
BAOGUI_REPO="${BAOGUI_REPO:-https://github.com/codegod100/baogui.git}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  curl git jq ca-certificates \
  xfce4 xfce4-goodies lightdm \
  tigervnc-standalone-server websockify novnc \
  android-tools-adb scrcpy \
  linux-modules-extra-"$(uname -r)" 2>/dev/null || true

# KVM
if ! grep -qE 'vmx|svm' /proc/cpuinfo; then
  echo "warning: CPU lacks hardware virtualization — emulator will be slow" >&2
fi
modprobe kvm 2>/dev/null || true
modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true

# Waydroid (Ubuntu 22.04+ / Debian bookworm backports may differ)
if ! command -v waydroid >/dev/null; then
  curl -fsSL https://repo.waydro.id | bash || {
    echo "warning: waydroid repo install failed — use KVM emulator path" >&2
  }
  apt-get install -y waydroid 2>/dev/null || true
fi

id "$SMOKE_USER" &>/dev/null || useradd -m -s /bin/bash -G sudo,kvm,video,render "$SMOKE_USER"
echo "$SMOKE_USER ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/"$SMOKE_USER"
chmod 440 /etc/sudoers.d/"$SMOKE_USER"

# Determinate Nix (for nix run .#waydroid)
if ! command -v nix >/dev/null; then
  curl -fsSL https://install.determinate.systems/nix | sh -s -- install --no-confirm
fi

# Rust (baogui needs ≥ 1.85)
sudo -u "$SMOKE_USER" bash -lc '
  if ! command -v rustup >/dev/null; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
  fi
  source "$HOME/.cargo/env"
  rustup target add x86_64-linux-android aarch64-linux-android
'

# Clone baogui + vidya sibling
sudo -u "$SMOKE_USER" mkdir -p "$SMOKE_HOME"
if [[ ! -d "$SMOKE_HOME/baogui/.git" ]]; then
  sudo -u "$SMOKE_USER" git clone --depth 1 "$BAOGUI_REPO" "$SMOKE_HOME/baogui"
fi
if [[ ! -d "$SMOKE_HOME/vidya/.git" ]]; then
  sudo -u "$SMOKE_USER" git clone --depth 1 https://tangled.org/nandi.uk/vidya "$SMOKE_HOME/vidya"
fi

# XFCE session for TigerVNC
sudo -u "$SMOKE_USER" mkdir -p "$SMOKE_HOME/.vnc"
cat >"$SMOKE_HOME/.vnc/xstartup" <<'XSTART'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XSTART
chmod +x "$SMOKE_HOME/.vnc/xstartup"
chown "$SMOKE_USER:$SMOKE_USER" "$SMOKE_HOME/.vnc/xstartup"
printf '%s\n' "$VNC_PASS" | sudo -u "$SMOKE_USER" vncpasswd -f >"$SMOKE_HOME/.vnc/passwd"
chmod 600 "$SMOKE_HOME/.vnc/passwd"
chown "$SMOKE_USER:$SMOKE_USER" "$SMOKE_HOME/.vnc/passwd"

# VNC + noVNC systemd units (Type=oneshot: vncserver forks then exits)
cat >/etc/systemd/system/smoke-vnc.service <<EOF
[Unit]
Description=TigerVNC for smoke.boxd
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$SMOKE_USER
Group=$SMOKE_USER
WorkingDirectory=$SMOKE_HOME
Environment=DISPLAY=:1
ExecStart=/usr/bin/vncserver :1 -geometry 1280x800 -depth 24 -localhost no -SecurityTypes VncAuth
ExecStop=/usr/bin/vncserver -kill :1

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/smoke-novnc.service <<'EOF'
[Unit]
Description=noVNC for smoke.boxd
After=smoke-vnc.service

[Service]
User=smoke
Group=smoke
ExecStart=/usr/bin/websockify --web=/usr/share/novnc 6080 localhost:5901

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now smoke-vnc.service smoke-novnc.service

# Waydroid init (needs binder — may require reboot on some kernels)
if command -v waydroid >/dev/null && [[ ! -f "$SMOKE_HOME/.local/share/waydroid/waydroid.cfg" ]]; then
  waydroid init -s GAPPS -f 2>/dev/null || {
    echo "note: waydroid init may need reboot + binder modules" >&2
  }
fi

cat <<EOF

smoke.boxd bootstrap complete.

  User:     $SMOKE_USER
  VNC:      http://$(hostname -I | awk '{print $1}'):6080/vnc.html
  Password: $VNC_PASS

  SSH in, then:
    cd ~/baogui && nix run .#run-apk
    ./scripts/apk-smoke.sh --build

  Point DNS smoke.boxd.sh → this host's public IP.
EOF
