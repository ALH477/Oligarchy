{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.custom.secrets;

  # One assertion per encrypted file, so a consumer switched on before its
  # file exists gets the fix, not sops-nix's "path … does not exist" over a
  # /nix/store/…-source path. NixOS forces `assertions` before any derivation
  # under system.build.toplevel, which is why this fires first. pathExists
  # sees what flake evaluation sees: a file on disk but untracked is filtered
  # out of the source tree — the message says so, because that is the
  # confusing case (the file is right there in `ls`).
  # modules/network-profiles.nix carries the same shape for wifi.enc.env.
  missingEncrypted = flag: file: hint: {
    assertion = !flag || builtins.pathExists file;
    message = ''
      ${hint.option} is on but modules/secrets/${hint.name} is not in the flake source.
      Create it (${hint.mint}) and `git add` it: an untracked file is invisible
      to flake evaluation even though it is on disk.
    '';
  };
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

    vpn.enable = mkEnableOption ''
      the encrypted Windscribe WireGuard config
      (modules/secrets/windscribe-wg.enc.conf, sops binary format). Decrypted
      to a root-only runtime path that custom.vpn.configFile defaults to, and
      handed straight to networking.wg-quick.interfaces.<n>.configFile.

      Mint it with `oligarchy-vpn import <windscribe.conf>`; the plaintext
      .conf is gitignored and the .enc.conf is safe to commit.
    '';
  };

  config = mkIf cfg.enable {
    sops.age.keyFile = cfg.ageKeyFile;

    assertions = [
      (missingEncrypted cfg.dcfIdentity.enable ./secrets/dcf-id.enc.env {
        option = "custom.secrets.dcfIdentity.enable";
        name = "dcf-id.enc.env";
        mint = "sops --encrypt modules/secrets/dcf-id.env > modules/secrets/dcf-id.enc.env, see .sops.yaml";
      })
      (missingEncrypted cfg.vpn.enable ./secrets/windscribe-wg.enc.conf {
        option = "custom.secrets.vpn.enable";
        name = "windscribe-wg.enc.conf";
        mint = "oligarchy-vpn import <windscribe.conf>";
      })
    ];

    # Encrypted secrets are declared per consumer. sops-nix no-ops gracefully
    # when no secrets are declared, so custom.secrets.enable is safe to keep
    # on even while every consumer below is disabled.
    sops.secrets = mkMerge [
      (mkIf cfg.dcfIdentity.enable {
        "dcf-id-env" = {
          format = "dotenv";
          sopsFile = ./secrets/dcf-id.enc.env;
          # Root-only; the dcf-identity container reads it as an env file.
          mode = "0400";
        };
      })

      (mkIf cfg.vpn.enable {
        "windscribe-wg" = {
          # binary: the payload is a wg-quick .conf, not a structured bag.
          format = "binary";
          sopsFile = ./secrets/windscribe-wg.enc.conf;
          # Root-only. wg-quick-<if>.service runs as root and copies this into
          # its own PrivateTmp before handing it to `wg-quick up`.
          mode = "0400";
          # Deliberately no restartUnits: the tunnel is on-demand
          # (custom.vpn.autoStart = false), so a rebuild must never yank a
          # live session down to re-provision a file it already copied.
        };
      })
    ];
  };
}
