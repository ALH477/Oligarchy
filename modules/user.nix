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
      # Default is EMPTY: shipping maintainer keys as the default meant a
      # fresh clone of this repo authorized the maintainer's keys on any
      # machine that evaluated it. The installer sets this from the keys the
      # user provides at install time. On THIS host the deployed layer
      # (~/.config/oligarchy/local.nix) is the source of truth and is updated
      # separately — see the security-overhaul commit that introduces that
      # override. The lockout-guard assertion in modules/security/hardening.nix
      # refuses to disable SSH password auth without at least one entry here,
      # so an empty default fails LOUDLY (build error) rather than silently
      # shipping an unreachable host.
      default = [];
      description = ''
        SSH public keys allowed to log in as custom.user.name. The installer
        populates this at install time. Leave empty only if the host is not
        reachable over SSH. modules/security/hardening.nix's lockout-guard
        assertion requires at least one entry here before it will disable SSH
        password auth — an empty list on a hardened host is a build error, not
        a silent lockout.
      '';
    };
  };
}
