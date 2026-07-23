{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.custom.secrets;
in
{
  options.custom.secrets = {
    enable = mkEnableOption "Secrets management with sops-nix";

    ageKeyFile = mkOption {
      # types.str, NOT types.path: a path literal would copy the age PRIVATE
      # key into the world-readable /nix/store. The key lives outside the repo
      # and outside the store, readable only by root.
      type = types.str;
      default = "/var/lib/sops-nix/key.txt";
      description = ''
        Absolute path to the age private key sops-nix decrypts with at
        activation. Generate it once, outside the repo:
          sudo mkdir -p /var/lib/sops-nix
          sudo age-keygen -o /var/lib/sops-nix/key.txt
          sudo chmod 600 /var/lib/sops-nix/key.txt
        Then put the printed public key in .sops.yaml and re-encrypt secrets.
      '';
    };

    dcfIdentity.enable = mkEnableOption ''
      the encrypted DCF identity env file (modules/secrets/dcf-id.enc.env,
      sops dotenv format). Decrypted to a root-only runtime path consumed by
      custom.dcfIdentity.secretsFile.
    '';
  };

  config = mkIf cfg.enable {
    sops.age.keyFile = cfg.ageKeyFile;

    # Encrypted secrets are declared per consumer. sops-nix no-ops gracefully
    # when no secrets are declared, so custom.secrets.enable is safe to keep
    # on even while every consumer below is disabled.
    sops.secrets = mkIf cfg.dcfIdentity.enable {
      "dcf-id-env" = {
        format = "dotenv";
        sopsFile = ./secrets/dcf-id.enc.env;
        # Root-only; the dcf-identity container reads it as an env file.
        mode = "0400";
      };
    };
  };
}
