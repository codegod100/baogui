{
  description = "smoke.boxd — raw NixOS host for BaoGUI APK smoke testing";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs =
    { nixpkgs, ... }:
    {
      nixosConfigurations.smoke-boxd = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./configuration.nix
          {
            services.smoke-vnc.enable = true;
            services.baogui-apk-smoke.enable = true;
          }
        ];
      };
    };
}
