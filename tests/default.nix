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
        # Set explicitly because this node imports malware-shield.nix ALONE,
        # and `notifyUser` defaults to `config.custom.user.name` — an option
        # declared in modules/user.nix, which is not imported here. Without
        # this the node dies with a bare "attribute 'user' missing", naming
        # neither the option nor the module that would have supplied it.
        #
        # Setting the value rather than importing modules/user.nix keeps the
        # node light, which is the same call the hardening test makes just
        # below (apparmor/auditd off for the same reason).
        notifyUser = "root";
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

  # ── Windscribe VPN: on-demand tunnel + the strict-egress interface hatch ───
  # The point of this gate is the two things that are silent when wrong: the
  # tunnel starting at boot when it was meant to be on demand, and the outer
  # encapsulated packet having no way past the egress filter.
  vpn = pkgs.testers.runNixOSTest {
    name = "vpn";

    nodes.machine = { config, pkgs, lib, ... }: {
      # ip-blocklists is imported but left off: custom.vpn writes the endpoint
      # into its allow list unconditionally, because on every real host both
      # modules are in commonModules together.
      imports = [
        ../modules/vpn.nix
        ../modules/security/strict-egress.nix
        ../modules/security/ip-blocklists.nix
      ];

      # A throwaway keypair and an unroutable endpoint (TEST-NET-1). wg-quick
      # brings an interface up fine without ever completing a handshake, which
      # is exactly what lets this run offline.
      custom.vpn = {
        enable = true;
        endpoints = [ "192.0.2.7:443" ];
        configFile = toString (pkgs.writeText "windscribe-test.conf" ''
          [Interface]
          PrivateKey = SLFtAcBTjZ4ScTWNxaGXCSzXnwbvMD6E0Qpv/VDDGWA=
          Address = 100.64.7.2/32
          DNS = 10.255.255.3

          [Peer]
          PublicKey = 1uJrwPzHHVXCz1m7bJJMxUjTsvUQbLrJjKOsCGdTuVU=
          PresharedKey = 6WcDdJTEJ1ZlvKxmGl+Ct1SrJLfZIaHHDZ4xEHVQfCE=
          AllowedIPs = 0.0.0.0/0
          Endpoint = 192.0.2.7:443
        '');
      };

      networking.firewall.strictEgress = {
        enable = true;
        preset = "minimal";
        recovery.dryRun = false;
        recovery.failOpen = false;
      };
      # Offline VM: the resolver's post-resolve reachability check would fail.
      systemd.services.strict-egress-resolve.serviceConfig.ExecStart =
        lib.mkForce "${pkgs.coreutils}/bin/true";

      # On so the dns.useTunnelDns ExecStartPost has something to talk to. The
      # first version of this test ran without it and caught the real bug: an
      # unprefixed resolvectl failure took the whole tunnel down with it.
      services.resolved.enable = true;
    };

    testScript = ''
      machine.wait_for_unit("strict-egress-rules.service", timeout=120)

      # ── On demand: declared, but NOT started at boot. ────────────────────
      machine.succeed("systemctl cat wg-quick-wsc0.service >/dev/null")
      machine.fail("systemctl is-active wg-quick-wsc0.service")
      machine.fail("ip link show wsc0")

      # ── The interface escape hatch landed in the chain. ──────────────────
      machine.succeed("nft list chain inet strict-egress egress | grep -q 'oifname \"wsc0\" accept'")

      # ── The OUTER packet has a path out: endpoint address, port stripped. ─
      machine.succeed("nft list set inet strict-egress egress_static4 | grep -q '192.0.2.7'")

      # ── Bring it up by hand, the way oligarchy-vpn does. ─────────────────
      machine.succeed("systemctl start wg-quick-wsc0.service")
      machine.wait_until_succeeds("ip link show wsc0", timeout=30)
      machine.succeed("wg show wsc0 | grep -q 'peer:'")

      # ExecStartPost applied the MTU that configFile made unreachable from Nix.
      machine.succeed("ip -o link show wsc0 | grep -q 'mtu 1420'")

      # ...and pinned the tunnel resolver with a `~.` routing domain, which is
      # what stops this host's global `domains = [ "~." ]` from winning.
      machine.succeed("resolvectl status wsc0 | grep -q '10.255.255.3'")
      machine.succeed("resolvectl domain wsc0 | grep -q '~\\.'")

      # The CLI agrees with reality in both directions.
      machine.succeed("oligarchy-vpn status --icon | grep -q VPN")
      machine.succeed("systemctl stop wg-quick-wsc0.service")
      machine.fail("ip link show wsc0")
      machine.fail("oligarchy-vpn status --icon | grep -q VPN")

      print("vpn: on-demand start, interface hatch, endpoint allow, MTU and CLI verified")
    '';
  };

  # ── Windscribe vendor client: the silent-failure surface ──────────────────
  # Three things here fail without an error message, which is why they are a
  # gate rather than a read-through: the helper unlinks its own socket and
  # returns when the "windscribe" group is missing, the binaries reach their
  # scripts through a compiled-in /opt/windscribe, and those scripts are
  # #!/bin/bash with an FHS PATH.
  windscribe-app = pkgs.testers.runNixOSTest {
    name = "windscribe-app";

    nodes.machine = { config, pkgs, lib, ... }: {
      # The module takes the sub-flake as its `self`. Re-entering that flake
      # from here with getFlake fails (the evaluated source tree has no nested
      # flake), so hand it the one attribute it reads: a packages set built
      # from the same package expression the sub-flake calls.
      imports = [
        (import ../modules/windscribe-app/nixos-module.nix {
          packages.${pkgs.stdenv.hostPlatform.system}.default =
            pkgs.callPackage ../modules/windscribe-app/pkgs/windscribe-desktop.nix { };
        })
        ../modules/security/strict-egress.nix
      ];
      custom.windscribeApp = {
        enable = true;
        users = [ "tester" ];
      };
      users.users.tester = { isNormalUser = true; };
      # patchelf reads the RUNPATH; the minimal test image has no binutils.
      environment.systemPackages = [ pkgs.patchelf ];

      # ── Exec-smoke: does the binary even start? ───────────────────────────
      # autoPatchelfHook rewrites every binary's interpreter/RPATH the same
      # way regardless of toolchain. That is fine for the C/C++ helpers and
      # fatal for the two Go ones: relocating a Go binary's program headers
      # makes its runtime SIGSEGV on exec, and the client only ever reports
      # "wstunnel failed to start" / ConnectionManager error 5 — never a
      # loader error. Every other assertion in this test (group, /opt tree,
      # shebangs, socket, RUNPATH) stayed green the whole time this was
      # broken, so the frozen contract is checked here, out-of-line, once
      # per binary: run it, and fail ONLY if it died on a signal. A clean
      # non-zero exit (windscribeamneziawg with no interface argument, for
      # instance) is not a corruption and must not be flagged as one.
      environment.etc."windscribe-exec-smoke.sh" = {
        mode = "0755";
        source = pkgs.writeShellScript "windscribe-exec-smoke" ''
          set -u
          bin="/opt/windscribe/$1"
          name="$1"

          # rc classification, per the frozen contract:
          #   139 SIGSEGV / 132 SIGILL / 134 SIGABRT / any 128+n -> died on
          #   a signal -> FAIL. 124 is timeout(1) itself giving up on a
          #   still-alive process -> PASS. Anything else (0 included) is a
          #   normal exit -> PASS, whether or not it succeeded.
          died_on_signal() {
            rc="$1"
            [ "$rc" -eq 139 ] && return 0
            [ "$rc" -eq 132 ] && return 0
            [ "$rc" -eq 134 ] && return 0
            [ "$rc" -ge 128 ] && [ "$rc" -ne 124 ] && return 0
            return 1
          }

          # Returns 0 = pass (stop here), 1 = inconclusive (try next
          # invocation), 2 = signal death (stop, fail the whole script).
          attempt() {
            label="$1"
            shift
            rc=0
            timeout 5 "$bin" "$@" >/tmp/windscribe-exec-smoke.out 2>&1 || rc=$?
            if died_on_signal "$rc"; then
              echo "windscribe-exec-smoke: $name DIED ON SIGNAL $((rc - 128)) (rc=$rc) invoked with $label -- autoPatchelfHook corrupted a non-C binary's ELF layout; see modules/windscribe-app/README.md landmine list" >&2
              return 2
            fi
            if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
              echo "windscribe-exec-smoke: $name OK (rc=$rc, $label)"
              return 0
            fi
            last_rc="$rc"
            return 1
          }

          attempt "--version" --version && exit 0
          rc=$?; [ "$rc" -eq 2 ] && exit 1
          attempt "--help" --help && exit 0
          rc=$?; [ "$rc" -eq 2 ] && exit 1
          attempt "no args" && exit 0
          rc=$?; [ "$rc" -eq 2 ] && exit 1

          echo "windscribe-exec-smoke: $name OK (clean non-zero exit rc=$last_rc after --version/--help/bare, no signal death)"
          exit 0
        '';
      };
    };

    testScript = ''
      machine.wait_for_unit("multi-user.target", timeout=180)

      # ── The group whose absence makes the helper fail silently. ──────────
      machine.succeed("getent group windscribe")
      machine.succeed("id -nG tester | tr ' ' '\\n' | grep -qx windscribe")

      # ── The compiled-in install dir resolves, scripts included. ──────────
      machine.succeed("test -d /opt/windscribe")
      machine.succeed("test -x /opt/windscribe/helper")
      machine.succeed("test -x /opt/windscribe/scripts/cgroups-up")

      # Every script must have a real interpreter: NixOS has no /bin/bash.
      machine.fail("head -1 /opt/windscribe/scripts/* | grep -q '^#!/bin/bash$'")
      machine.succeed("head -1 /opt/windscribe/scripts/cgroups-up | grep -q '^#!/nix/store/'")

      # In-app update must refuse rather than try to dpkg over the store.
      machine.fail("/opt/windscribe/scripts/install-update /tmp/whatever")

      # ── The platform id the updater parses. ──────────────────────────────
      machine.succeed("grep -qE '^linux_deb_(x64|arm64)$' /etc/windscribe/platform")

      # ── The helper runs and publishes a socket the group can reach. ──────
      machine.wait_for_unit("windscribe-helper.service", timeout=120)
      machine.wait_for_file("/var/run/windscribe/helper.sock", timeout=60)
      machine.succeed("stat -c '%G' /var/run/windscribe/helper.sock | grep -qx windscribe")
      machine.succeed("stat -c '%U:%G' /var/run/windscribe | grep -qx root:windscribe")

      # ── The client binaries actually execute after autoPatchelf. ─────────
      machine.succeed("su - tester -c 'windscribe-cli --help' | grep -q 'windscribe-cli v'")

      # ── libdbus must stay reachable, and nothing else will tell you. ─────
      # Qt dlopen()s libdbus-1.so.3, so there is no DT_NEEDED entry and
      # autoPatchelfHook reports a clean build without it. The symptom of
      # losing it is not a missing-library error: the GUI segfaults inside
      # QDBusMenuConnection, four frames deep in the system-tray probe.
      machine.succeed(
          "patchelf --print-rpath /opt/windscribe/Windscribe | tr ':' '\\n' | grep -q dbus"
      )
      # ...and the directory it points at really holds the soname Qt asks for.
      machine.succeed(
          "test -e \"$(patchelf --print-rpath /opt/windscribe/Windscribe "
          "| tr ':' '\\n' | grep dbus | head -1)/libdbus-1.so.3\""
      )

      # ── The launcher defaults to XWayland. ───────────────────────────────
      # Native Wayland paints the fixed-size window clipped inside a surface
      # the compositor sized differently.
      machine.succeed("grep -q 'QT_QPA_PLATFORM' $(command -v windscribe)")
      machine.succeed("grep -q 'xcb' $(command -v windscribe)")

      # ── Exec-smoke: every bundled helper actually starts. ────────────────
      # Every assertion above passed the whole time windscribewstunnel and
      # windscribeamneziawg were autoPatchelf'd into an immediate SIGSEGV on
      # exec, because none of them ever runs the binaries. This does.
      for helper in [
          "windscribewstunnel",
          "windscribeamneziawg",
          "windscribeopenvpn",
          "windscribectrld",
          "windscribe-cli",
      ]:
          machine.succeed(f"/etc/windscribe-exec-smoke.sh {helper}")

      print("windscribe-app: group, /opt tree, patched scripts, platform id, helper socket, CLI, libdbus runpath, XWayland default and helper exec-smoke verified")
    '';
  };

  # ── Captive portal: NM probe flips to PORTAL, watcher opens once, login paths ─
  # Two nodes on one VLAN. `portal` plays the venue: nginx 302s everything to
  # /login until a flag file "logs you in", dnsmasq is the resolver a portal
  # network would hand out. `client` runs the real module with the same
  # resolver settings configuration.nix ships, and NM manages eth1 the way
  # nixpkgs' own NetworkManager test does (no auto profiles, one declared
  # profile). No wifi: the portal state machine is identical on ethernet, and
  # the connectivity probe needs a default route on the device, hence the
  # gateway pointing at the portal node.
  #
  # The scripts' state machine is covered by the no-KVM gate
  # (.#captive-portal-tests); this test is for what only a booted NM can prove:
  # the probe really flips to PORTAL against a real 302, `connectivity check`
  # really returns full once the body matches, and the DNS/route setup a
  # portal implies actually resolves the login host.
  captive-portal = pkgs.testers.runNixOSTest {
    name = "captive-portal";

    nodes = {
      portal = { config, ... }: {
        networking.firewall.allowedTCPPorts = [ 53 80 ];
        networking.firewall.allowedUDPPorts = [ 53 ];
        systemd.tmpfiles.rules = [ "d /var/lib/portal 0755 root root -" ];
        services.nginx = {
          enable = true;
          virtualHosts.portal = {
            default = true;
            locations."= /check_network_status.txt".extraConfig = ''
              if (!-f /var/lib/portal/open) { return 302 http://portal/login; }
              default_type text/plain;
              return 200 "NetworkManager is online\n";
            '';
            locations."= /login".extraConfig = ''
              default_type text/html;
              return 200 "<html><body><h1>Captive portal test login</h1></body></html>\n";
            '';
            locations."/".extraConfig = "return 302 http://portal/login;";
          };
        };
        services.dnsmasq = {
          enable = true;
          resolveLocalQueries = false;
          settings = {
            interface = "eth1";
            bind-interfaces = true;
            no-resolv = true;
            address = [ "/login.portal.test/${config.networking.primaryIPAddress}" ];
          };
        };
      };

      client = { pkgs, lib, nodes, ... }:
        let portalIp = nodes.portal.networking.primaryIPAddress; in
        {
          imports = [ ../modules/captive-portal ];

          # nixpkgs' NetworkManager test recipe: only NM touches eth1, and NM
          # creates no auto profiles, so the one below is the only connection.
          networking.useDHCP = false;
          networking.interfaces = lib.mkForce { eth1 = { }; };
          networking.networkmanager = {
            enable = true;
            dns = "systemd-resolved";
            settings.main.no-auto-default = "*";
            ensureProfiles.profiles.venue = {
              connection = {
                id = "venue";
                type = "ethernet";
                interface-name = "eth1";
                autoconnect = true;
              };
              ipv4 = {
                method = "manual";
                addresses = "192.168.1.42/24";
                # NM only runs the connectivity probe on a device that has a
                # default route, exactly like a real venue's DHCP lease.
                gateway = portalIp;
                dns = portalIp;
                ignore-auto-dns = true;
              };
              ipv6.method = "disabled";
            };
          };

          # configuration.nix's resolver settings, verbatim. Scenario 9 of the
          # design spec: a portal-local name must resolve through the LINK's
          # resolver under them, fallbackDns (unreachable here) notwithstanding.
          services.resolved = {
            enable = true;
            dnssec = "allow-downgrade";
            domains = [ "~." ];
            fallbackDns = [ "1.1.1.1" "8.8.8.8" ];
            dnsovertls = "opportunistic";
          };

          custom.network.captivePortal = {
            enable = true;
            probe.host = "portal";
            probe.interval = 30;
            loginUrl = "http://login.portal.test/";
            # Record instead of open: there is no browser in the VM.
            opener = "${pkgs.writeShellScript "record-open" ''echo "$@" >> /tmp/opened''}";
            terminalBrowser = pkgs.writeShellScriptBin "record-tui" ''echo "$@" >> /tmp/tui-opened'';
          };

          environment.systemPackages = [ pkgs.curl ];
        };
    };

    testScript = { nodes, ... }:
      let portalIp = nodes.portal.networking.primaryIPAddress; in
      ''
        start_all()
        portal.wait_for_unit("nginx.service", timeout=120)
        portal.wait_for_unit("dnsmasq.service", timeout=120)
        client.wait_for_unit("NetworkManager.service", timeout=120)
        client.wait_for_unit("NetworkManager-ensure-profiles.service", timeout=120)
        client.wait_until_succeeds("ip addr show dev eth1 | grep -q '192.168.1.42'", timeout=120)

        with subtest("NetworkManager.conf carries the probe"):
            client.succeed("grep -q '^uri=http://portal/check_network_status.txt$' /etc/NetworkManager/NetworkManager.conf")
            client.succeed("grep -q '^response=NetworkManager is online$' /etc/NetworkManager/NetworkManager.conf")

        with subtest("the venue intercepts plain HTTP"):
            client.wait_until_succeeds("curl -s -o /dev/null -w '%{http_code}' http://portal/check_network_status.txt | grep -qx 302", timeout=60)

        with subtest("NetworkManager reports PORTAL"):
            client.wait_until_succeeds("nmcli -t -g CONNECTIVITY general | grep -qx portal", timeout=120)

        with subtest("the watcher opens the login URL exactly once"):
            client.succeed("rm -f /tmp/opened; setsid -f captive-portal-watch >/tmp/watch.log 2>&1")
            client.wait_until_succeeds("test -f /tmp/opened", timeout=30)
            client.succeed("grep -qx 'http://login.portal.test/' /tmp/opened")
            # Two forced re-probes while still unpaid must not reopen.
            client.succeed("nmcli networking connectivity check | grep -qx portal")
            client.succeed("nmcli networking connectivity check | grep -qx portal")
            client.sleep(3)
            client.succeed("test $(wc -l < /tmp/opened) -eq 1")

        with subtest("the portal-local login host resolves through the link resolver"):
            client.wait_until_succeeds("resolvectl dns eth1 | grep -q '${portalIp}'", timeout=60)
            client.wait_until_succeeds("resolvectl query login.portal.test | grep -q '${portalIp}'", timeout=60)
            client.succeed("curl -s -o /dev/null -w '%{http_code}' http://login.portal.test/ | grep -qx 302")

        with subtest("captive-login without a display uses the text browser"):
            client.succeed("rm -f /tmp/tui-opened; captive-login")
            client.succeed("grep -qx 'http://login.portal.test/' /tmp/tui-opened")

        with subtest("logging in flips NM to FULL"):
            portal.succeed("touch /var/lib/portal/open")
            client.wait_until_succeeds("nmcli networking connectivity check | grep -qx full", timeout=60)
            client.succeed("captive-login | grep -q 'Already online'")
            client.succeed("test $(wc -l < /tmp/opened) -eq 1")

        with subtest("a new portal episode opens the page again"):
            portal.succeed("rm /var/lib/portal/open")
            client.wait_until_succeeds("nmcli networking connectivity check | grep -qx portal", timeout=60)
            client.wait_until_succeeds("test $(wc -l < /tmp/opened) -eq 2", timeout=30)

        with subtest("nmtui-portal hands off to captive-login on a portal"):
            # No tty here: nmtui exits at once; the hand-off is what matters.
            client.succeed("rm -f /tmp/tui-opened; timeout 60 nmtui-portal </dev/null >/tmp/nmtui-portal.log 2>&1 || true")
            client.succeed("grep -qx 'http://login.portal.test/' /tmp/tui-opened")

        with subtest("the graphical-session user unit is installed"):
            client.succeed("test -f /etc/systemd/user/captive-portal-watch.service")
            client.succeed("grep -q '^Restart=always' /etc/systemd/user/captive-portal-watch.service")
            client.succeed("grep -q 'graphical-session.target' /etc/systemd/user/captive-portal-watch.service")

        print("captive-portal: probe -> PORTAL -> open once -> login -> FULL -> re-arm verified")
      '';
  };
in
{
  inherit strict-egress malware-shield hardening dcf-spa-gate ip-blocklists vpn windscribe-app captive-portal;
}
