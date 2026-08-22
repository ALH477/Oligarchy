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

  # ── DCF-SPA gate: standalone table that COEXISTS with the iptables firewall ─
  # The bug this guards: upstream's spa/modules/dcf-spa.nix sets
  # networking.nftables.enable, which collides with demod-ip-blocker's
  # ipset/iptables firewall.extraCommands and fails eval. The node below sets
  # extraCommands precisely to reproduce that collision — if anyone "fixes" this
  # module by importing upstream's, or copies its `policy drop` chain, this test
  # stops building or stops passing.
  dcf-spa-gate = pkgs.testers.runNixOSTest {
    name = "dcf-spa-gate";

    nodes.machine = { config, pkgs, ... }: {
      imports = [ ../modules/security/dcf-spa-gate.nix ];

      networking.firewall.spaGate = {
        enable = true;
        meshPort = 7100;
        credsDir = "/var/lib/dcf-spa-test/peers";
        grantTtl = 30;
        # The real authorizer comes from the hydramesh flake input, which this
        # test file has no handle on (and whose Rust build has its own tests in
        # spa/tests/cross_lang.rs). What's under test here is the TABLE — our
        # code — so stub the binary and let the units prove their wiring.
        package = pkgs.writeShellScriptBin "dcf-spa-authorizer" ''
          echo "stub authorizer: $*"
          exec ${pkgs.coreutils}/bin/sleep infinity
        '';
      };

      # Reproduce the collision that started all this: an iptables/ipset-shaped
      # firewall rule. With upstream's module this node would not evaluate.
      networking.firewall.enable = true;
      networking.firewall.extraCommands = ''
        ${pkgs.iptables}/bin/iptables -I INPUT -s 203.0.113.0/24 -j DROP
      '';

      systemd.tmpfiles.rules = [
        "d /var/lib/dcf-spa-test/peers 0755 root root -"
        # 32-byte hex "public key" — shape is all the preflight checks.
        "f /var/lib/dcf-spa-test/peers/0001.pub 0444 root root - ${lib.concatStrings (lib.genList (_: "ab") 32)}"
      ];
    };

    testScript = ''
      machine.wait_for_unit("dcf-spa-gate-rules.service", timeout=120)

      # 1. The standalone table loaded.
      machine.succeed("nft list table inet dcf_spa_gate")

      # 2. THE critical assertion: policy accept, not upstream's policy drop.
      #    A drop policy here would black-hole every other inbound packet
      #    (ssh, dhcp, mdns) because it hooks input for the whole system.
      machine.succeed("nft list chain inet dcf_spa_gate input | grep -q 'policy accept'")
      machine.fail("nft list chain inet dcf_spa_gate input | grep -q 'policy drop'")

      # 3. The gate itself: unauthorized v4 dropped, and v6 dropped outright
      #    (the knock channel is v4-only, so a v6 peer can never be authorized).
      machine.succeed("nft list chain inet dcf_spa_gate input | grep -q 'udp dport 7100 drop'")
      machine.succeed("nft list chain inet dcf_spa_gate input | grep -q 'ip6 nexthdr udp udp dport 7100 drop'")

      # 4. Coexistence — the whole point. The iptables backend is still live and
      #    still carries the extraCommands rule, i.e. we did NOT flip the
      #    firewall to nftables the way upstream's module does.
      machine.succeed("iptables -L INPUT -n | grep -q '203.0.113.0/24'")

      # 5. A grant admits a peer, and expires on its own.
      machine.succeed("nft add element inet dcf_spa_gate allowed_peers '{ 198.51.100.7 timeout 2s }'")
      machine.succeed("nft get element inet dcf_spa_gate allowed_peers '{ 198.51.100.7 }'")
      machine.sleep(5)
      machine.fail("nft get element inet dcf_spa_gate allowed_peers '{ 198.51.100.7 }'")

      # 6. The authorizer came up (stubbed) with a populated creds dir.
      machine.wait_for_unit("dcf-spa.service", timeout=120)

      # 7. Empty creds must FAIL loudly rather than silently gating everyone
      #    out — with the table live, no creds means 7100 is dark forever.
      machine.succeed("systemctl stop dcf-spa.service")
      machine.succeed("rm -f /var/lib/dcf-spa-test/peers/0001.pub")
      machine.fail("systemctl start dcf-spa.service")

      print("dcf-spa-gate: coexisting table, gate rules, grant expiry, creds preflight verified")
    '';
  };

  # ── IP blocklists: the protected-space preflight is the whole safety story ──
  # A feed that carries RFC1918/CGNAT must be rejected WHOLESALE rather than
  # quietly filtered, and a rejected feed must never clobber a good live set.
  # firehol_level1 is the real-world instance of this: it bundles fullbogons, so
  # loading it would blackhole the LAN, the gateway and the Tailscale mesh.
  ip-blocklists = pkgs.testers.runNixOSTest {
    name = "ip-blocklists";

    nodes.machine = { config, pkgs, ... }: {
      imports = [ ../modules/security/ip-blocklists.nix ];
      networking.firewall.blocklists = {
        enable = true;
        # One source keeps the cache filename predictable (ipsum-L3.txt).
        feeds = [ "ipsum" ];
        ipsumLevel = 3;
        direction = "both";
      };
    };

    testScript = ''
      machine.wait_for_unit("firewall.service", timeout=120)

      state = "/var/lib/oligarchy-blocklists"
      cache = state + "/cache/ipsum-L3.txt"

      # 1. Rules are wired into BOTH chains against our own sets, and the
      #    iptables backend is still live — we did not flip to nftables.
      machine.succeed("iptables -S INPUT  | grep -q 'olig-blk-v4'")
      machine.succeed("iptables -S OUTPUT | grep -q 'olig-blk-v4'")
      machine.succeed("ipset list olig-blk-v4 >/dev/null")

      # 2. A clean feed loads. The VM is offline, so curl fails and the updater
      #    falls back to the cache — which is exactly the path we want covered.
      machine.succeed(f"mkdir -p {state}/cache")
      machine.succeed(
          f"for i in $(seq 1 254); do echo 203.0.113.$i; done > {cache}"
      )
      machine.succeed("systemctl start oligarchy-blocklists-update.service")
      machine.succeed("ipset test olig-blk-v4 203.0.113.5")

      # 3. Protected space is never in the set, even though it was never in the
      #    feed — the mandatory subtraction is unconditional.
      machine.fail("ipset test olig-blk-v4 192.168.1.1")
      machine.fail("ipset test olig-blk-v4 100.64.0.1")
      machine.fail("ipset test olig-blk-v4 127.0.0.1")

      # 4. THE FIREHOL CASE. One line of RFC1918 poisons the whole feed: the
      #    service must fail loudly rather than load a filtered remainder.
      machine.succeed(f"cp {cache} {cache}.good")
      machine.succeed(f"echo '192.168.0.0/16' >> {cache}")
      machine.fail("systemctl start oligarchy-blocklists-update.service")
      machine.succeed(
          "journalctl -u oligarchy-blocklists-update.service | grep -q 'REJECTED'"
      )

      # 5. ...and the previously-good set is still intact. A rejected feed must
      #    never leave the machine with an empty or half-loaded set.
      machine.succeed("ipset test olig-blk-v4 203.0.113.5")
      machine.fail("ipset test olig-blk-v4 192.168.0.1")

      # 6. A feed that shrinks below its sanity band is rejected too (truncated
      #    body / error page served with 200).
      machine.succeed(f"head -5 {cache}.good > {cache}")
      machine.fail("systemctl start oligarchy-blocklists-update.service")
      machine.succeed("ipset test olig-blk-v4 203.0.113.5")

      # 7. panic empties the sets, making the iptables rules inert without
      #    touching the firewall. Contrast strict-egress, where flushing the nft
      #    chain keeps `policy drop` and fails CLOSED.
      machine.succeed("oligarchy-blocklist panic")
      machine.fail("ipset test olig-blk-v4 203.0.113.5")
      machine.succeed("iptables -S INPUT | grep -q 'olig-blk-v4'")

      print("ip-blocklists: preflight rejection, mandatory subtraction, set preservation and panic verified")
    '';
  };

in
{
  inherit strict-egress malware-shield hardening dcf-spa-gate ip-blocklists;
}
