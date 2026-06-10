{ config, lib, pkgs, inputs, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Secure Boot via lanzaboote (opt-in)
# OFF by default so it can never brick boot unattended. Enabling REQUIRES key
# enrollment first — see the runbook below. The lanzaboote module is imported
# unconditionally (it only acts when boot.lanzaboote.enable is true).
#
# Enrollment runbook (run on the machine, once):
#   1) sudo sbctl create-keys
#   2) set custom.secureBoot.enable = true; sudo nixos-rebuild switch --flake .#nixos
#   3) Put firmware in "Setup Mode" (clear existing keys in BIOS).
#   4) sudo sbctl enroll-keys --microsoft        # --microsoft keeps OEM/Windows trust
#   5) reboot; verify with: bootctl status   (Secure Boot: enabled)
# Optional follow-on: TPM2-backed LUKS auto-unlock via
#   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/<luks-part>
# ─────────────────────────────────────────────────────────────────────────────

let
  cfg = config.custom.secureBoot;
in
{
  imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];

  options.custom.secureBoot = {
    enable = lib.mkEnableOption "Secure Boot via lanzaboote (enroll keys FIRST — see runbook)";

    pkiBundle = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sbctl";
      description = "Path to the sbctl PKI bundle (keys live here).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.sbctl ];

    # lanzaboote replaces the systemd-boot stub with a signed one.
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.lanzaboote = {
      enable = true;
      pkiBundle = cfg.pkiBundle;
    };
  };
}
