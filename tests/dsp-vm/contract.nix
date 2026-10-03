# dsp-route-contract — eval-only. The DSP VM on .#nixos, enabled with
# custom.companions, and the guest image flake.nix builds from that host:
# the routed tap, forwarding scoped to the guest, the host's NetJack2 unit,
# and a guest that runs JACK, the NetJack2 manager, the DeMoD engine and its
# bridges on the addresses the host gave it.
#
# One complete host evaluation (Home Manager included) plus the guest, so it
# lives in legacyPackages, like installer-contract: `nix flake check` never
# pays for it. The forward table is also checked by nft itself: parsed and
# evaluated (`nft -c` in a network namespace of its own) where the build
# sandbox allows one, parsed only where it does not, as on GitHub's Ubuntu
# runners. The evaluation is then reported as SKIP, never as a pass.
#
#   nix build .#dsp-route-contract
#
# What happens on the wire is .#dsp-netjack-tests' job; this is the wiring
# that has to be right for that to happen on a real machine.
{ pkgs, host, guest }:

let
  lib = pkgs.lib;
  h = host.config;
  g = guest.config;
  d = h.custom.vm.dsp;
  r = d.network.routed;
  nj = d.archibaldOS.netjack;
  hs = h.systemd.services;
  gs = g.systemd.services;
  # The VM's start script, as text: reading the built script would build
  # the disk image it names (a KVM job), so read what it is built from.
  vmExec = hs.${d.name}.serviceConfig.ExecStart.text;
  failedAssertions = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);

  # Files the units point at; their contents are checked in the build below
  # (grep -x), not read at evaluation time.
  lastWord = s: lib.last (lib.splitString " " s);
  routeRules = lastWord hs.dsp-vm-route.serviceConfig.ExecStart;
  netjackConf = lastWord h.systemd.user.services.dsp-netjack.serviceConfig.ExecStart;
  jackdScript = gs.dsp-jackd.serviceConfig.ExecStart;
  guestNet = g.systemd.network.networks."10-dsp";
  routes = g.archibald.jack.routes;

  # name, file, fixed lines it must contain (whitespace-trimmed, whole line)
  fileChecks = [
    {
      name = "the forward table admits UDP/ICMP between the tunnel and the guest, and drops the rest of both";
      file = routeRules;
      lines = [
        ''iifname { "wg-companions" } oifname "${r.interface}" ip daddr ${r.guestAddress} meta l4proto { udp, icmp } accept''
        ''iifname "${r.interface}" oifname { "wg-companions" } ip saddr ${r.guestAddress} meta l4proto { udp, icmp } accept''
        ''iifname { "wg-companions" } counter drop''
        ''iifname "${r.interface}" counter drop''
        ''oifname "${r.interface}" counter drop''
      ];
    }
    {
      name = "dsp-netjack joins ${r.guestAddress}:${toString nj.port} as ${nj.clientName}";
      file = netjackConf;
      lines = [
        ''net.ip               = "${r.guestAddress}"''
        "net.port             = ${toString nj.port}"
        ''netjack2.client-name = "${nj.clientName}"''
      ];
    }
    {
      name = "the guest's JACK runs at the host's netjack.sampleRate and bufferSize";
      file = jackdScript;
      lines = [ ];
      infix = "-r ${toString nj.sampleRate} -p ${toString nj.bufferSize}";
    }
  ];
  fileCheckScript = lib.concatMapStrings
    (c: ''
      ok=1
      ${lib.concatMapStrings (l: ''
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' ${c.file} | grep -qxF ${lib.escapeShellArg l} || { ok=0; echo "  missing: "${lib.escapeShellArg l}; }
      '') c.lines}
      ${lib.optionalString (c ? infix) ''grep -qF -- ${lib.escapeShellArg c.infix} ${c.file} || { ok=0; echo "  missing: "${lib.escapeShellArg c.infix}; }''}
      if [ $ok = 1 ]; then echo "PASS: "${lib.escapeShellArg c.name}; else echo "FAIL: "${lib.escapeShellArg c.name}; fail=1; fi
    '')
    fileChecks;

  checks = [
    # ── anti-vacuity: this is the host it claims to be ────────────────────
    {
      name = "the host is .#nixos with the DSP VM and the companions hub on";
      ok = d.enable && h.custom.companions.enable && h.networking.wireguard.interfaces ? wg-companions;
    }

    # ── the host: a tap, not a loopback forward ───────────────────────────
    {
      name = "QEMU attaches the tap ${r.interface} (vhost) with the guest's MAC";
      ok = lib.hasInfix "-netdev tap,id=net0,ifname=${r.interface},script=no,downscript=no,vhost=on" vmExec
        && lib.hasInfix "mac=${r.guestMac}" vmExec;
    }
    {
      name = "no user-mode networking and no hostfwd";
      ok = !(lib.hasInfix "-netdev user" vmExec) && !(lib.hasInfix "hostfwd" vmExec);
    }
    {
      name = "the tap is declared with the host's address, and NetworkManager leaves it alone";
      ok = h.networking.interfaces.${r.interface}.virtual
        && h.networking.interfaces.${r.interface}.virtualType == "tap"
        && h.networking.interfaces.${r.interface}.ipv4.addresses == [{ address = r.hostAddress; prefixLength = r.prefixLength; }]
        && lib.elem "interface-name:${r.interface}" h.networking.networkmanager.unmanaged;
    }
    {
      name = "the VM requires its tap and its forward filter";
      ok = lib.all (u: lib.elem u hs.${d.name}.requires) [ "${r.interface}-netdev.service" "dsp-vm-route.service" ];
    }

    # ── forwarding: two interfaces, scoped ────────────────────────────────
    {
      name = "custom.companions puts its tunnel in forwardFrom";
      ok = r.forwardFrom == [ "wg-companions" ];
    }
    {
      name = "forwarding on for the tap and the tunnel only, never globally";
      ok = h.boot.kernel.sysctl."net.ipv4.conf.${r.interface}.forwarding" or null == 1
        && h.boot.kernel.sysctl."net.ipv4.conf.wg-companions.forwarding" or null == 1
        && !lib.elem (h.boot.kernel.sysctl."net.ipv4.ip_forward" or 0) [ 1 true "1" ]
        && !lib.elem (h.boot.kernel.sysctl."net.ipv4.conf.all.forwarding" or 0) [ 1 true "1" ];
    }
    {
      name = "the forward filter loads before network-pre.target";
      ok = lib.elem "network-pre.target" hs.dsp-vm-route.before;
    }
    {
      name = "the tap admits NetJack2's UDP; no other interface gets anything for it";
      ok = h.networking.firewall.interfaces.${r.interface}.allowedUDPPortRanges == [{ from = 1024; to = 65535; }]
        && !lib.elem nj.port h.networking.firewall.allowedUDPPorts;
    }

    # ── this host's NetJack2 ──────────────────────────────────────────────
    {
      name = "dsp-netjack is on demand (wanted by nothing), and the jack_netsource units are gone";
      ok = (h.systemd.user.services.dsp-netjack.wantedBy or [ ]) == [ ]
        && !(hs ? dsp-netjack-bridge) && !(hs ? dsp-jack-bridge);
    }

    # ── the guest, built from the host ────────────────────────────────────
    {
      name = "the guest configures the NIC with the host's MAC: its address, the host as gateway";
      ok = guestNet.matchConfig.MACAddress == r.guestMac
        && guestNet.address == [ "${r.guestAddress}/${toString r.prefixLength}" ]
        && guestNet.gateway == [ r.hostAddress ];
    }
    {
      name = "the guest runs JACK as dsp, and the manager, the router and the engine live and die with it";
      ok = gs.dsp-jackd.serviceConfig.User == "dsp"
        && lib.all (u: lib.elem "dsp-jackd.service" gs.${u}.bindsTo) [ "jack-netmanager" "jack-router" "demod-orchestrator" ];
    }
    {
      name = "the NetJack2 manager listens on ${r.guestAddress}:${toString nj.port}, after the network";
      ok = lib.hasInfix "-a ${r.guestAddress} -p ${toString nj.port}" gs.jack-netmanager.serviceConfig.ExecStart
        && lib.elem "network-online.target" gs.jack-netmanager.after;
    }
    {
      name = "every follower's 1-2 into demod-rt, its output back to all of them";
      ok = lib.all (x: lib.elem x routes) [
        "*:from_slave_1 -> demod-rt:in_L"
        "*:from_slave_2 -> demod-rt:in_R"
        "demod-rt:out_L -> *:to_slave_1"
        "demod-rt:out_R -> *:to_slave_2"
      ];
    }
    {
      name = "the engine is DeMoD's orchestrator with demod-rt as its child, as dsp";
      ok = lib.hasInfix "/bin/demod-orchestrator --control-socket /run/demod/control.sock --rt-binary " gs.demod-orchestrator.serviceConfig.ExecStart
        && lib.hasInfix "-demod-rt-" gs.demod-orchestrator.serviceConfig.ExecStart
        && gs.demod-orchestrator.serviceConfig.User == "dsp";
    }
    {
      name = "the control bridge relays to the engine's socket and admits the host only";
      ok = lib.hasInfix "range=${r.hostAddress}/32" gs.dsp-control-bridge.serviceConfig.ExecStart
        && lib.hasInfix "UNIX-CONNECT:/run/demod/control.sock" gs.dsp-control-bridge.serviceConfig.ExecStart
        && gs.dsp-control-bridge.serviceConfig.IPAddressAllow == [ "${r.hostAddress}/32" ];
    }
    {
      name = "the DeMoD remote bridge binds the guest's address (a companion's kiosk: remote:${r.guestAddress})";
      ok = gs.demod-remote-bridge.environment.DEMOD_DCF_BIND == r.guestAddress;
    }
    {
      name = "the guest's firewall is on; ssh and the bridge from the host only; NetJack2 open";
      ok = g.networking.firewall.enable && !g.services.openssh.openFirewall
        && lib.hasInfix "-s ${r.hostAddress} --dport 22 -j nixos-fw-accept" g.networking.firewall.extraCommands
        && lib.hasInfix "-s ${r.hostAddress} --dport 7777 -j nixos-fw-accept" g.networking.firewall.extraCommands
        && lib.elem nj.port g.networking.firewall.allowedUDPPorts
        && !lib.elem 22 g.networking.firewall.allowedTCPPorts;
    }
    {
      name = "root's keys in the guest are the host's custom.user keys, not a hardcoded one";
      ok = g.users.users.root.openssh.authorizedKeys.keys == h.custom.user.sshAuthorizedKeys;
    }
    {
      name = "host and guest evaluate with no failed assertion"
        + lib.concatMapStrings (m: "\n    " + m) (map (m: "host: " + m) (failedAssertions h) ++ map (m: "guest: " + m) (failedAssertions g));
      ok = failedAssertions h == [ ] && failedAssertions g == [ ];
    }
  ];

  failed = lib.filter (x: !x.ok) checks;
  report = lib.concatMapStringsSep "\n" (x: (if x.ok then "PASS: " else "FAIL: ") + x.name) checks;
in
pkgs.runCommand "dsp-route-contract"
{
  inherit report;
  passAsFile = [ "report" ];
  nativeBuildInputs = [ pkgs.nftables pkgs.util-linux ];
}
  ''
    cat "$reportPath"; echo
    fail=${if failed == [ ] then "0" else "1"}
    ${fileCheckScript}
    # nft -c evaluates the table against the kernel, so it needs CAP_NET_ADMIN
    # in some network namespace: a private one where the sandbox lets the
    # builder make one. GitHub's Ubuntu runners refuse nested user namespaces
    # ("write failed /proc/self/uid_map"). There nft can still parse: it reads
    # the whole file before it touches netlink, so a syntax error is reported
    # and a clean parse stops at exactly the permission line below. Anything
    # else fails. What a parse cannot see (a bad address, a type mismatch) is
    # the evaluation, reported as SKIP rather than passed.
    if unshare -rn true 2>/dev/null; then
      if unshare -rn nft -c -f ${routeRules}; then echo "PASS: nft -c accepts the forward table (parsed and evaluated, private netns)"
      else echo "FAIL: nft -c rejects the forward table"; fail=1; fi
    else
      nftout=$(nft -c -f ${routeRules} 2>&1) || true
      if [ "$nftout" = "netlink: Error: cache initialization failed: Operation not permitted" ]; then
        echo "PASS: nft parses the forward table (grammar only)"
        echo "SKIP: nft evaluation of the forward table: this sandbox grants no network namespace (unshare -rn refused)"
      else echo "FAIL: nft rejects the forward table:"; echo "$nftout"; fail=1; fi
    fi
    echo "${toString (lib.length checks - lib.length failed)}/${toString (lib.length checks)} eval checks passed"
    [ $fail = 0 ] || exit 1
    cp "$reportPath" $out
  ''
