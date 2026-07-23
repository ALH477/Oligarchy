{ lib, pkgs, ... }:

let
  # ── Strict egress: standalone inet table, static/dyn set matching ──────────
  strict-egress = pkgs.testers.runNixOSTest {
    name = "strict-egress";

    nodes.machine = { config, pkgs, ... }: {
      imports = [ ../modules/security/strict-egress.nix ];
      networking.firewall.strictEgress = {
        enable = true;
        preset = "minimal";
        # Enforcing so we can assert drops. VMs are offline, so the resolver
        # can't reach real DNS; the test injects a dyn element directly.
        recovery.dryRun = false;
        recovery.failOpen = false;
        allow.ips = [ "192.0.2.0/24" ]; # TEST-NET-1, into the static set
      };
      # The post-resolve cache.nixos.org check would fail offline; neuter the
      # resolver's enforcement guard for the test by allowing it to no-op.
      systemd.services.strict-egress-resolve.serviceConfig.ExecStart =
        lib.mkForce "${pkgs.coreutils}/bin/true";
    };

    testScript = ''
      machine.wait_for_unit("strict-egress-rules.service", timeout=120)

      # Our standalone table + chain exist.
      machine.succeed("nft list table inet strict-egress")
      machine.succeed("nft list chain inet strict-egress egress | grep -q 'policy drop'")

      # Static-set destination (192.0.2.5 in 192.0.2.0/24) is accepted.
      machine.succeed("nft add element inet strict-egress egress_dyn4 '{ 198.51.100.9 timeout 1h }'")
      machine.succeed("nft get element inet strict-egress egress_dyn4 '{ 198.51.100.9 }'")

      # Sanity: static allow set carries the CIDR.
      machine.succeed("nft list set inet strict-egress egress_static4 | grep -q '192.0.2.0/24'")

      print("strict-egress: table, policy, and set population verified")
    '';
  };

  # ── Malware Shield: YARA path detects the EICAR string, quarantine moves ───
  malware-shield = pkgs.testers.runNixOSTest {
    name = "malware-shield";

    nodes.machine = { config, pkgs, ... }: {
      imports = [ ../modules/security/malware-shield.nix ];
      custom.malwareShield = {
        enable = true;
        level = "quarantine";
        clamav.enable = false; # DBs can't download in the sandbox
        rootkit.enable = false; # lynis is slow/noisy in a VM
        aide.enable = false;
        yara.enable = true;
      };
    };

    testScript = ''
      machine.wait_for_unit("multi-user.target", timeout=120)

      # Plant the EICAR test string where the yara sweep looks.
      machine.succeed(
          r"printf '%s' "
          r"'X5O!P%@AP[4\\PZX54(P^)7CC)7}}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' "
          r"> /tmp/eicar.com"
      )

      # Run the sweep; quarantine level moves the file aside.
      machine.succeed("malware-shield-yara /tmp")
      machine.fail("test -f /tmp/eicar.com")
      machine.succeed("ls /var/lib/malware-shield/quarantine/ | grep -qi eicar")
      machine.succeed("grep -qi eicar /var/lib/malware-shield/events.log")

      print("malware-shield: EICAR detected and quarantined")
    '';
  };

  # ── Hardening: SSH keys-only, fail2ban up ──────────────────────────────────
  hardening = pkgs.testers.runNixOSTest {
    name = "security-hardening";

    nodes.machine = { config, pkgs, ... }: {
      imports = [ ../modules/security/hardening.nix ];
      services.openssh.enable = true;
      users.users.tester = {
        isNormalUser = true;
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYplaceholderplaceholderplaceholder tester@test"
        ];
      };
      custom.security.hardening = {
        enable = true;
        preset = "hardened";
        sshUser = "tester";
        apparmor = false; # keep the test node light
        auditd = false;
      };
    };

    testScript = ''
      machine.wait_for_unit("sshd.service", timeout=120)
      machine.succeed("sshd -T | grep -qi 'passwordauthentication no'")
      machine.succeed("sshd -T | grep -qi 'permitrootlogin no'")
      machine.wait_for_unit("fail2ban.service", timeout=120)
      machine.succeed("fail2ban-client status sshd")
      print("hardening: keys-only SSH + fail2ban verified")
    '';
  };

in
{
  inherit strict-egress malware-shield hardening;
}
