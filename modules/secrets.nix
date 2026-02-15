{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.custom.secrets;
in {
  options.custom.secrets = {
    enable = mkEnableOption "Secrets management with sops-nix";
    
    ageKeyFile = mkOption {
      type = types.path;
      default = ./secrets/keys.txt;
      description = "Path to the age private key file";
    };
  };

  config = mkIf cfg.enable {
    # Deploy the age key to /etc/sops/age/
    # This is required for sops-nix to decrypt secrets at runtime
    environment.etc."sops/age/keys.txt".source = cfg.ageKeyFile;
    
    # Ensure proper permissions on the keys directory
    systemd.tmpfiles.rules = [
      "d /etc/sops 0700 root root -"
      "d /etc/sops/age 0700 root root -"
      "f /etc/sops/age/keys.txt 0600 root root - ${cfg.ageKeyFile}"
    ];
  };
}
