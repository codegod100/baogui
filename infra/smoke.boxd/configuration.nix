# NixOS profile for smoke.boxd — APK smoke testing with remote desktop view.
#
# Provision a raw x86_64 Linux VM with nested KVM (or bare metal), then:
#   nixos-install --flake .#smoke.boxd
#
# Point DNS smoke.boxd.sh → this host. View Android via https://smoke.boxd.sh/vnc.html

{
  config,
  pkgs,
  lib,
  ...
}:

{
  imports = [
    ./modules/apk-smoke.nix
    ./modules/novnc.nix
  ];

  services.smoke-vnc.enable = true;
  services.baogui-apk-smoke.enable = true;

  networking.hostName = "smoke";
  networking.domain = "boxd.sh";
  time.timeZone = "UTC";

  services.openssh.enable = true;

  # Open noVNC in browser (http://smoke.boxd.sh:6080/vnc.html). Enable TLS after DNS is live:
  # services.smoke-vnc.enableTls = true;
  # security.acme.acceptTerms = true;
  # security.acme.defaults.email = "you@boxd.sh";

  # Install-time placeholders (override in hardware-configuration.nix):
  boot.loader.grub.devices = lib.mkDefault [ "/dev/sda" ];
  fileSystems."/" = lib.mkDefault {
    device = "/dev/sda1";
    fsType = "ext4";
  };

  users.users.smoke = {
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "kvm"
      "adbusers"
      "video"
      "render"
    ];
    openssh.authorizedKeys.keys = [
      # Replace with your deploy key / admin key.
    ];
  };

  security.sudo.wheelNeedsPassword = false;

  # KVM for the Android emulator path.
  boot.kernelModules = [
    "kvm-intel"
    "kvm-amd"
  ];
  hardware.cpu.intel.updateMicrocode = lib.mkDefault true;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;

  # Waydroid (fastest APK runtime on Linux desktop).
  virtualisation.waydroid.enable = true;

  # Graphical sessions come from smoke-vnc (TigerVNC :1), not a local display manager.

  environment.systemPackages = with pkgs; [
    git
    curl
    jq
    android-tools
    scrcpy
  ];

  # Determinate-style nix for `nix run` from the baogui checkout.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.stateVersion = "24.11";
}
