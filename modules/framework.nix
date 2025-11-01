{ config, lib, nixpkgs-unstable, ... }: {
  options = {
    hardware.framework.enable = lib.mkEnableOption "Framework 16-inch 7040 AMD support";
    hardware.fw-fanctrl.enable = lib.mkEnableOption "Framework fan control";
  };
  config = {
    nixpkgs.overlays = [
      (final: prev: {
        unstable = import nixpkgs-unstable {
          system = prev.system;
          config.allowUnfree = true;
        };
      })
    ];
    hardware.framework.enable = true;
    hardware.fw-fanctrl.enable = true;
  };
}
