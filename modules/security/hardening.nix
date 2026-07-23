# ═══════════════════════════════════════════════════════════════════════════════
# Security Hardening Ladder — SSH/auth, brute-force defense, MAC, audit
# ═══════════════════════════════════════════════════════════════════════════════
# Preset-driven like modules/cpu-security.nix: pick a preset, override any
# single knob with the tri-state options (null = inherit preset).
#
#   baseline  = SSH passwords still allowed, fail2ban on. Transitional only.
#   hardened  = SSH keys-only (lockout-guard assertion), fail2ban, AppArmor,
#               auditd. USBGuard stays off (Framework expansion cards).
#   paranoid  = hardened + USBGuard default-block for new USB devices.
#
# The SSH server *settings* are owned here — configuration.nix only sets
# services.openssh.enable and declares the authorized keys.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.custom.security.hardening;

  presets = {
    baseline = { sshPasswordAuth = true; fail2ban = true; apparmor = false; auditd = false; usbguard = false; };
    hardened = { sshPasswordAuth = false; fail2ban = true; apparmor = true; auditd = true; usbguard = false; };
    paranoid = { sshPasswordAuth = false; fail2ban = true; apparmor = true; auditd = true; usbguard = true; };
  };

  # null => inherit from preset (cpu-security.nix idiom)
  pick = name: if cfg.${name} != null then cfg.${name} else presets.${cfg.preset}.${name};

  tri = mkOption { type = types.nullOr types.bool; default = null; };

  passwordAuth = pick "sshPasswordAuth";

  authorizedKeys = config.users.users.${cfg.sshUser}.openssh.authorizedKeys;
in
{
  options.custom.security.hardening = {
    enable = mkEnableOption "security hardening ladder (SSH keys-only, fail2ban, AppArmor, auditd, USBGuard)";

    preset = mkOption {
      type = types.enum [ "baseline" "hardened" "paranoid" ];
      default = "hardened";
      description = "Hardening preset; individual tri-state options override single knobs.";
    };

    sshUser = mkOption {
      type = types.str;
      default = "asher";
      description = "The (only) user allowed to SSH in; also the user whose declared keys satisfy the lockout guard.";
    };

    sshPasswordAuth = tri // { description = "Allow SSH password authentication. false requires a declared authorized key (asserted)."; };
    fail2ban = tri // { description = "Ban IPs that brute-force sshd (private ranges are exempt)."; };
    apparmor = tri // { description = "AppArmor LSM with distro profiles (complain-first posture, no custom profiles)."; };
    auditd = tri // { description = "Kernel audit daemon with a minimal privileged-exec rule set."; };
    usbguard = tri // { description = "USBGuard: allow present devices, block newly plugged ones until authorized. Disruptive with Framework expansion cards - paranoid preset only by default."; };
  };

  config = mkIf cfg.enable (mkMerge [

    ##########################################################################
    # 1. SSH server — keys-only with lockout guard
    ##########################################################################
    {
      assertions = [{
        assertion = passwordAuth || authorizedKeys.keys != [ ] || authorizedKeys.keyFiles != [ ];
        message = ''
          custom.security.hardening disables SSH password authentication but no
          authorized key is declared for user "${cfg.sshUser}".
            1. Add your public key: users.users.${cfg.sshUser}.openssh.authorizedKeys.keys = [ "ssh-ed25519 ..." ];
            2. Verify key login BEFORE switching: ssh -o PreferredAuthentications=publickey ${cfg.sshUser}@<host> true
            3. Rebuild. (Or set custom.security.hardening.sshPasswordAuth = true transitionally.)
        '';
      }];

      services.openssh.settings = {
        PasswordAuthentication = passwordAuth;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        MaxAuthTries = 3;
        AllowUsers = [ cfg.sshUser ];
      };
    }

    ##########################################################################
    # 2. fail2ban — sshd brute-force banning
    ##########################################################################
    (mkIf (pick "fail2ban") {
      services.fail2ban = {
        enable = true;
        maxretry = 5;
        # Local + private + CGNAT (tailscale) ranges never get banned; a bad
        # key rollout on a trusted machine must not lock the front door.
        ignoreIP = [ "127.0.0.1/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" "fc00::/7" ];
      };
    })

    ##########################################################################
    # 3. AppArmor — mandatory access control (complain-first posture)
    ##########################################################################
    (mkIf (pick "apparmor") {
      security.apparmor = {
        enable = true;
        # Do not kill running processes that merely *could* be confined;
        # profiles apply on next exec. Keeps the first switch non-disruptive.
        killUnconfinedConfinables = false;
      };
      services.dbus.apparmor = "enabled";
    })

    ##########################################################################
    # 4. auditd — kernel audit trail (kept minimal: privileged execs + module
    #    loads; full syscall auditing is noise on a desktop)
    ##########################################################################
    (mkIf (pick "auditd") {
      security.auditd.enable = true;
      security.audit = {
        enable = true;
        rules = [
          "-a exit,always -F arch=b64 -F euid=0 -S execve -k root-exec"
          "-w /etc/sudoers -p wa -k sudoers"
          "-w /etc/ssh/sshd_config -p wa -k sshd-config"
        ];
      };
    })

    ##########################################################################
    # 5. USBGuard — paranoid only by default (expansion cards hot-plug)
    ##########################################################################
    (mkIf (pick "usbguard") {
      services.usbguard = {
        enable = true;
        # Devices present at daemon start are allowed; new plugs are blocked
        # until authorized (usbguard allow-device / generate-policy).
        presentDevicePolicy = "allow";
        implicitPolicyTarget = "block";
        IPCAllowedUsers = [ "root" cfg.sshUser ];
      };
    })
  ]);
}
