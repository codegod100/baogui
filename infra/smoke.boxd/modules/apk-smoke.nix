# APK smoke-test helpers on smoke.boxd (systemd timer + oneshot).

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.baogui-apk-smoke;
  smokeScript = pkgs.writeShellScriptBin "apk-smoke" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    REPO="${cfg.baoguiCheckout}"
    if [[ -x "$REPO/scripts/apk-smoke.sh" ]]; then
      exec "$REPO/scripts/apk-smoke.sh" "$@"
    fi
    echo "apk-smoke: missing $REPO/scripts/apk-smoke.sh" >&2
    exit 1
  '';
in
{
  options.services.baogui-apk-smoke = {
    enable = lib.mkEnableOption "BaoGUI APK smoke test oneshot";
    baoguiCheckout = lib.mkOption {
      type = lib.types.str;
      default = "/home/smoke/baogui";
      description = "Path to baogui git checkout on smoke.boxd.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ smokeScript ];

    systemd.services.baogui-apk-smoke = {
      description = "BaoGUI APK smoke test";
      serviceConfig = {
        Type = "oneshot";
        User = "smoke";
        Group = "smoke";
        WorkingDirectory = cfg.baoguiCheckout;
      };
      script = ''
        ${smokeScript}/bin/apk-smoke --ci
      '';
    };

    systemd.timers.baogui-apk-smoke = {
      description = "Nightly BaoGUI APK smoke (optional)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
