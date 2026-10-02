# Primary-account identity, factored out so forking this repo for another
# machine/user is a one-file edit instead of a grep-and-replace across
# configuration.nix, home/home.nix and half a dozen modules.
{ config, lib, ... }:

with lib;

{
  options.custom.user = {
    name = mkOption {
      type = types.str;
      default = "asher";
      description = ''
        Primary account name: the Home Manager user (flake.nix), the sudoer
        and SSH login (configuration.nix), and the account several optional
        modules (agentic-local-ai, terminus-dev, dcf-tray, llama-cpp,
        hardening, malware-shield) run as or notify by default. Forking this
        repo for your own machine? Change this one value instead of hunting
        down every "asher" literal.
      '';
    };

    fullName = mkOption {
      type = types.str;
      default = "Asher";
      description = ''
        The account holder's name: git's user.name (home/apps/default.nix).
        The installer sets it from the name given at install.
      '';
    };

    email = mkOption {
      type = types.nullOr types.str;
      default = "demodllc@gmail.com";
      description = ''
        git's user.email (home/apps/default.nix). null leaves it unset, so
        git asks before the first commit instead of using someone else's
        address; the installer sets null, since it never asks for one.
      '';
    };

    sshAuthorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKUnqq4zcVhHe5NyupFpnlU8+b1/Gvw3O2VRbgZm/eNi root@deepcomputing"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM6HhsWIY7VCGLpu/ucXvzkuuf4GOtUMraf7sVflf775 ubuntu@deepcomputing"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL+eqhrKR37FkxmiCuyZav4XVF7JK/1/yFA0rKaBBlbE hermes@framework16"
      ];
      description = ''
        SSH public keys allowed to log in as custom.user.name. Replace the
        default list with your own keys before deploying to a new machine —
        modules/security/hardening.nix's lockout-guard assertion requires at
        least one entry here before it will disable SSH password auth.
      '';
    };
  };
}
