# noVNC + TigerVNC so you can view smoke.boxd in a browser.
#
# After boot: open https://smoke.boxd.sh/vnc.html

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.smoke-vnc;
in
{
  options.services.smoke-vnc = {
    enable = lib.mkEnableOption "TigerVNC + noVNC for smoke.boxd remote view";
    password = lib.mkOption {
      type = lib.types.str;
      default = "smokeboxd";
      description = "VNC password (change in production).";
    };
    display = lib.mkOption {
      type = lib.types.str;
      default = ":1";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      tigervnc
      websockify
      novnc
    ];

    systemd.services.smoke-vnc = {
      description = "TigerVNC for smoke.boxd";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        User = "smoke";
        Group = "smoke";
        WorkingDirectory = "/home/smoke";
        Environment = [
          "DISPLAY=${cfg.display}"
        ];
      };
      script = ''
        mkdir -p "$HOME/.vnc"
        if [[ ! -f "$HOME/.vnc/passwd" ]]; then
          printf '%s\n' "${cfg.password}" | vncpasswd -f > "$HOME/.vnc/passwd"
          chmod 600 "$HOME/.vnc/passwd"
        fi
        exec vncserver ${cfg.display} \
          -geometry 1280x800 -depth 24 -localhost no -SecurityTypes VncAuth
      '';
    };

    systemd.services.smoke-novnc = {
      description = "noVNC websocket proxy for smoke.boxd";
      wantedBy = [ "multi-user.target" ];
      after = [ "smoke-vnc.service" ];
      serviceConfig = {
        User = "smoke";
        Group = "smoke";
      };
      script = ''
        exec websockify --web=${pkgs.novnc}/share/novnc 6080 localhost:5901
      '';
    };

    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;
      recommendedProxySettings = true;
      virtualHosts."smoke.boxd.sh" = {
        forceSSL = true;
        enableACME = true;
        locations."/vnc.html" = {
          proxyPass = "http://127.0.0.1:6080/vnc.html";
          proxyWebsockets = true;
        };
        locations."/websockify" = {
          proxyPass = "http://127.0.0.1:6080/websockify";
          proxyWebsockets = true;
        };
      };
    };
  };
}
