# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025-2026, Asher LeRoy
# ═══════════════════════════════════════════════════════════════════════════════
# IP blocklists — multi-feed threat intel into ipset, inbound and outbound
# ═══════════════════════════════════════════════════════════════════════════════
# Complements services.demod-ip-blocker rather than replacing it: that module
# ships ONE list (a Spur-published Astrill VPN egress set) into demod-blk-v4/v6,
# which is VPN detection, not threat intel. This module owns olig-blk-v4/v6 and
# carries scanners, brute-force sources and C2.
#
# Feeds (all verified live, sizes as of 2026-08-16):
#   ipsum         levels/N.txt      15448 @ L3, bare IPv4, scored 30+ sources
#   spamhaus-drop drop.txt/dropv6    1687 + 96 nets, `CIDR ; SBLnnn`
#   blocklist-de  all.txt           22291 bare IPv4, 48h attack sensors
#   cins          ci-badguys.txt    15000 bare IPv4
#
# WHY THERE IS NO FIREHOL LEVEL1 HERE, AND WHY THE WHITELIST IS MANDATORY:
#
#   firehol_level1.netset bundles `fullbogons`, which contains 0.0.0.0/8,
#   10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12 and
#   192.168.0.0/16. That is correct for an edge router filtering transit and
#   catastrophic for a host on a private LAN: loaded into an INPUT DROP set it
#   blackholes the LAN, the default gateway, loopback and the ENTIRE Tailscale
#   mesh (tailnet addresses live inside 100.64/10).
#
#   The lesson is not "avoid that one feed" — any feed can drift or be served
#   as a truncated error page. So every feed is put through a preflight that
#   REJECTS IT WHOLESALE if it contains a protected address, and the protected
#   set is subtracted from the merged result regardless. Neither is optional.
#
# WHY ipset/iptables AND NOT nftables:
#
#   Setting networking.nftables.enable switches the global firewall backend and
#   fails eval against demod-ip-blocker's ipset/iptables extraCommands — see the
#   header of modules/security/dcf-spa-gate.nix. This module hooks in through
#   networking.firewall.extraCommands, exactly like demod-ip-blocker does.
#
# Recovery: `oligarchy-blocklist panic` runs `ipset flush`. That IS the correct
# escape here, and it is worth stating because it looks like the trap that took
# the machine down on 2026-08-16: flushing an *nft base chain* keeps its
# `policy drop` and fails closed, whereas an emptied *ipset* matches nothing, so
# `-m set --match-set` goes inert and traffic passes. Opposite behaviour, near
# identical spelling.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.networking.firewall.blocklists;

  setV4 = "olig-blk-v4";
  setV6 = "olig-blk-v6";
  stateDir = "/var/lib/oligarchy-blocklists";

  # ── Feed catalogue ──────────────────────────────────────────────────────────
  # `min`/`max` are sanity bands, not precision: they exist to reject a
  # truncated body or an HTML error page served with 200, so they are set an
  # order of magnitude either side of the observed size.
  sourcesFor = feed: {
    ipsum = [{
      id = "ipsum-L${toString cfg.ipsumLevel}";
      url = "https://raw.githubusercontent.com/stamparm/ipsum/master/levels/${toString cfg.ipsumLevel}.txt";
      min = 200;
      max = 400000;
    }];
    spamhaus-drop = [
      {
        id = "spamhaus-drop-v4";
        url = "https://www.spamhaus.org/drop/drop.txt";
        min = 100;
        max = 100000;
      }
      {
        id = "spamhaus-drop-v6";
        url = "https://www.spamhaus.org/drop/dropv6.txt";
        min = 5;
        max = 100000;
      }
    ];
    blocklist-de = [{
      id = "blocklist-de";
      url = "https://lists.blocklist.de/lists/all.txt";
      min = 500;
      max = 500000;
    }];
    cins = [{
      id = "cins";
      url = "https://cinsscore.com/list/ci-badguys.txt";
      min = 500;
      max = 300000;
    }];
  }.${feed};

  sources = concatMap sourcesFor cfg.feeds;

  sourceManifest = pkgs.writeText "oligarchy-blocklists-sources.json"
    (builtins.toJSON (map (s: { inherit (s) id url min max; }) sources));

  # ── Merge / validate / filter ───────────────────────────────────────────────
  # Python rather than awk because every meaningful check here is CIDR
  # containment, and getting that right in shell is how you end up with a
  # prefix-match bug that silently lets 192.168.0.0/16 through.
  filterScript = pkgs.writeText "oligarchy-blocklists-merge.py" ''
    import ipaddress, json, os, sys

    state = sys.argv[1]
    manifest = json.load(open(sys.argv[2]))
    protected_file = sys.argv[3]
    extra_allow = [a for a in sys.argv[4:] if a]

    # Never blockable, under any circumstances. Feeds that contain these are
    # not filtered, they are rejected outright — a feed carrying private space
    # is a feed built for a different job (see the header).
    MANDATORY = [
        "0.0.0.0/8", "10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10",
        "224.0.0.0/4", "240.0.0.0/4",
        "::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
    ]

    def parse_net(tok):
        try:
            return ipaddress.ip_network(tok, strict=False)
        except ValueError:
            return None

    protected = [n for n in (parse_net(t) for t in MANDATORY) if n]
    # Runtime additions: local addresses, the default gateway, and every IP the
    # strict-egress allowlist resolved. A host explicitly permitted for egress
    # must never be blocklisted by a feed.
    if os.path.exists(protected_file):
        for line in open(protected_file):
            n = parse_net(line.strip())
            if n:
                protected.append(n)
    for a in extra_allow:
        n = parse_net(a)
        if n:
            protected.append(n)

    prot4 = [n for n in protected if n.version == 4]
    prot6 = [n for n in protected if n.version == 6]

    def is_protected(net):
        pool = prot4 if net.version == 4 else prot6
        return any(net.subnet_of(p) or p.subnet_of(net) for p in pool)

    accepted, report = {4: set(), 6: set()}, []

    for src in manifest:
        path = os.path.join(state, "cache", src["id"] + ".txt")
        entry = {"id": src["id"], "status": "missing", "entries": 0, "reason": ""}
        if not os.path.exists(path) or os.path.getsize(path) == 0:
            entry["reason"] = "no cached data"
            report.append(entry)
            continue

        raw = [l.strip() for l in open(path, errors="ignore")]
        lines = [l for l in raw if l and l[0] not in "#;"]

        # (2) sanity band — catches truncation and error pages served with 200
        if not (src["min"] <= len(lines) <= src["max"]):
            entry.update(status="rejected",
                         reason="line count %d outside [%d, %d]" % (len(lines), src["min"], src["max"]))
            report.append(entry)
            continue

        nets, bad = [], 0
        for l in lines:
            tok = l.split(";")[0].split()[0].strip() if l.split() else ""
            n = parse_net(tok) if tok else None
            if n is None:
                bad += 1
            else:
                nets.append(n)

        # (3) format drift — a feed that stopped being a list of IPs
        if not nets or bad / max(len(lines), 1) > 0.10:
            entry.update(status="rejected",
                         reason="%d/%d lines unparseable" % (bad, len(lines)))
            report.append(entry)
            continue

        # (4) the FireHOL check: a feed containing protected space is rejected
        # wholesale, not quietly filtered. Filtering it would hide the fact that
        # the feed is the wrong shape for this host.
        hits = [str(n) for n in nets if is_protected(n)]
        if hits:
            entry.update(status="rejected",
                         reason="contains protected space: " + ", ".join(hits[:5]))
            report.append(entry)
            continue

        for n in nets:
            accepted[n.version].add(n)
        entry.update(status="ok", entries=len(nets))
        report.append(entry)

    # Belt and braces: subtract protected space from the merged result too, in
    # case a feed carried a supernet that slipped the per-feed check.
    merged = {v: sorted((n for n in accepted[v] if not is_protected(n)),
                        key=lambda n: (n.network_address, n.prefixlen))
              for v in (4, 6)}

    out = {}
    for ver in (4, 6):
        out[ver] = [str(n) for n in merged[ver]]

    json.dump({"sources": report,
               "v4": len(out[4]), "v6": len(out[6])},
              open(os.path.join(state, "manifest.json.new"), "w"), indent=2)
    open(os.path.join(state, "merged-v4.txt.new"), "w").write("\n".join(out[4]) + "\n")
    open(os.path.join(state, "merged-v6.txt.new"), "w").write("\n".join(out[6]) + "\n")

    ok = sum(1 for r in report if r["status"] == "ok")
    for r in report:
        if r["status"] != "ok":
            print("blocklists: %s %s: %s" % (r["id"], r["status"].upper(), r["reason"]),
                  file=sys.stderr)
    print("blocklists: %d/%d sources ok, %d IPv4 + %d IPv6 entries merged"
          % (ok, len(report), len(out[4]), len(out[6])))
    # Never apply an empty set over a populated one.
    sys.exit(0 if ok else 1)
  '';

  updateScript = pkgs.writeShellScriptBin "oligarchy-blocklists-update" ''
    set -u
    export PATH=${makeBinPath [ pkgs.coreutils pkgs.curl pkgs.ipset pkgs.iproute2 pkgs.gnugrep pkgs.gawk pkgs.python3Minimal ]}:$PATH

    STATE=${stateDir}
    mkdir -p "$STATE/cache"

    # ── Protected addresses, resolved at run time ────────────────────────────
    PROT="$STATE/protected.txt"
    : > "$PROT"
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' >> "$PROT"
    ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' >> "$PROT"
    ip -4 route show default 2>/dev/null | awk '{print $3}' >> "$PROT"
    ip -6 route show default 2>/dev/null | awk '{print $3}' >> "$PROT"
    # Anything strict-egress explicitly allowed for egress is never blockable.
    if [ -f /run/strict-egress/resolved.txt ]; then
      awk '{print $2}' /run/strict-egress/resolved.txt >> "$PROT"
    fi

    # ── Fetch ────────────────────────────────────────────────────────────────
    ${concatMapStringsSep "\n    " (s: ''
      tmp=$(mktemp)
      if curl -sS --fail --location --max-time 90 --retry 3 --retry-delay 5 \
          "${s.url}" -o "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$STATE/cache/${s.id}.txt"
        echo "blocklists: fetched ${s.id}"
      else
        rm -f "$tmp"
        echo "blocklists: fetch FAILED for ${s.id} — reusing cache" >&2
      fi
    '') sources}

    # ── Validate + merge ─────────────────────────────────────────────────────
    if ! python3 ${filterScript} "$STATE" ${sourceManifest} "$PROT" ${escapeShellArgs cfg.allow.ips}; then
      echo "blocklists: no source passed validation — keeping the live sets untouched" >&2
      exit 1
    fi
    mv "$STATE/manifest.json.new" "$STATE/manifest.json"
    mv "$STATE/merged-v4.txt.new" "$STATE/merged-v4.txt"
    mv "$STATE/merged-v6.txt.new" "$STATE/merged-v6.txt"

    # ── Apply atomically ─────────────────────────────────────────────────────
    # create/flush a temp set, fill it, then swap it over the live one, so there
    # is no window where the set is empty or half loaded.
    apply() {
      set_name="$1"; fam="$2"; src="$3"; max="$4"
      tmp_set="''${set_name}-tmp"
      restore=$(mktemp)
      {
        echo "create $tmp_set hash:net family $fam hashsize 8192 maxelem $max -exist"
        echo "flush $tmp_set"
        awk -v s="$tmp_set" 'NF {print "add " s " " $1 " -exist"}' "$src"
        echo "swap $tmp_set $set_name"
        echo "destroy $tmp_set"
      } > "$restore"
      ipset restore < "$restore" || { rm -f "$restore"; return 1; }
      rm -f "$restore"
    }

    ipset create -exist ${setV4} hash:net family inet  hashsize 8192 maxelem ${toString cfg.maxElem}
    ipset create -exist ${setV6} hash:net family inet6 hashsize 4096 maxelem ${toString cfg.maxElem}
    apply ${setV4} inet  "$STATE/merged-v4.txt" ${toString cfg.maxElem} || echo "blocklists: IPv4 apply failed" >&2
    apply ${setV6} inet6 "$STATE/merged-v6.txt" ${toString cfg.maxElem} || echo "blocklists: IPv6 apply failed" >&2

    date -Is > "$STATE/last-update"
    echo "blocklists: applied — v4=$(ipset list ${setV4} 2>/dev/null | grep -c '^[0-9]') v6=$(ipset list ${setV6} 2>/dev/null | grep -c '^[0-9a-f]*:')"
  '';

  cli = pkgs.writeShellScriptBin "oligarchy-blocklist" ''
    set -u
    export PATH=${makeBinPath [ pkgs.coreutils pkgs.ipset pkgs.jq pkgs.gnugrep pkgs.systemd ]}:$PATH
    STATE=${stateDir}

    case "''${1:-status}" in
      status)
        echo "Mode      : ${if cfg.dryRun then "DRY-RUN (log only)" else "ENFORCING"} (${cfg.direction})"
        echo "Last run  : $(cat "$STATE/last-update" 2>/dev/null || echo never)"
        echo "Set ${setV4}: $(ipset list ${setV4} 2>/dev/null | sed -n '/^Members/,$p' | tail -n +2 | grep -c . || echo 0) entries"
        echo "Set ${setV6}: $(ipset list ${setV6} 2>/dev/null | sed -n '/^Members/,$p' | tail -n +2 | grep -c . || echo 0) entries"
        if [ -f "$STATE/manifest.json" ]; then
          echo "Sources   :"
          jq -r '.sources[] | "  \(.id): \(.status) \(.entries) \(.reason)"' "$STATE/manifest.json"
        fi
        echo "Recent hits:"
        journalctl -k -g "BLOCKLIST-" -n 10 --no-pager 2>/dev/null || true
        ;;
      update)
        systemctl start oligarchy-blocklists-update.service
        journalctl -u oligarchy-blocklists-update.service -n 30 --no-pager
        ;;
      test)
        ip="''${2:?usage: oligarchy-blocklist test <ip>}"
        for s in ${setV4} ${setV6}; do
          if ipset test "$s" "$ip" 2>/dev/null; then echo "$ip: BLOCKED (in $s)"; exit 0; fi
        done
        echo "$ip: not blocked"
        ;;
      panic)
        # Emptying the sets makes `-m set --match-set` match nothing, so the
        # iptables rules go inert without touching the firewall. Contrast with
        # flushing an nft base chain, which keeps `policy drop` and fails closed.
        ipset flush ${setV4} 2>/dev/null || true
        ipset flush ${setV6} 2>/dev/null || true
        echo "blocklists: sets flushed — filtering is inert until the next update"
        ;;
      *)
        echo "usage: oligarchy-blocklist [status|update|test <ip>|panic]" >&2
        exit 1
        ;;
    esac
  '';

  inbound = cfg.direction == "inbound" || cfg.direction == "both";
  outbound = cfg.direction == "outbound" || cfg.direction == "both";

  ipt = "${pkgs.iptables}/bin/iptables";
  ip6t = "${pkgs.iptables}/bin/ip6tables";
  logArgs = ''-m limit --limit ${cfg.logging.rateLimit} -j LOG --log-prefix'';

  # Each -I inserts at position 1, so emitting DROP first and LOG second leaves
  # LOG above DROP — i.e. hits are logged and then dropped.
  mkChain = { chain, dir, bin, set, tag }: ''
    ${optionalString (!cfg.dryRun) "${bin} -I ${chain} -m set --match-set ${set} ${dir} -j DROP"}
    ${optionalString cfg.logging.enable
      ''${bin} -I ${chain} -m set --match-set ${set} ${dir} ${logArgs} "BLOCKLIST-${tag}: "''}
  '';
  mkStop = { chain, dir, bin, set, tag }: ''
    ${optionalString cfg.logging.enable
      ''${bin} -D ${chain} -m set --match-set ${set} ${dir} ${logArgs} "BLOCKLIST-${tag}: " 2>/dev/null || true''}
    ${optionalString (!cfg.dryRun) "${bin} -D ${chain} -m set --match-set ${set} ${dir} -j DROP 2>/dev/null || true"}
  '';

  chains =
    optionals inbound [
      { chain = "INPUT"; dir = "src"; bin = ipt; set = setV4; tag = "IN"; }
      { chain = "INPUT"; dir = "src"; bin = ip6t; set = setV6; tag = "IN6"; }
    ]
    ++ optionals outbound [
      { chain = "OUTPUT"; dir = "dst"; bin = ipt; set = setV4; tag = "OUT"; }
      { chain = "OUTPUT"; dir = "dst"; bin = ip6t; set = setV6; tag = "OUT6"; }
    ];

in
{
  options.networking.firewall.blocklists = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Multi-feed threat-intel IP blocklists loaded into ipset and matched from
        iptables. Independent of services.demod-ip-blocker, which carries a
        VPN-egress list in its own sets.
      '';
    };

    feeds = mkOption {
      type = types.listOf (types.enum [ "ipsum" "spamhaus-drop" "blocklist-de" "cins" ]);
      default = [ "ipsum" "spamhaus-drop" "blocklist-de" "cins" ];
      description = ''
        Threat feeds to merge. All four were CIDR-tested against this host's
        LAN, gateway, tailnet, DERP relays and API endpoints with no collisions.

        FireHOL level1 is deliberately not offered: it bundles fullbogons and so
        contains RFC1918 plus 100.64/10, which would blackhole the LAN and the
        Tailscale mesh. The per-feed preflight would reject it anyway.
      '';
    };

    ipsumLevel = mkOption {
      type = types.ints.between 1 8;
      default = 3;
      description = ''
        IPsum confidence level: the minimum number of source lists an address
        must appear on. Lower is broader and noisier (L3 ~15k entries, L4 ~6k).
      '';
    };

    direction = mkOption {
      type = types.enum [ "inbound" "outbound" "both" ];
      default = "both";
      description = ''
        Which chains to filter. Outbound coverage overlaps
        networking.firewall.strictEgress once that enforces — a default-deny
        egress allowlist already denies everything a blocklist would — but it is
        the only outbound coverage while strict-egress is in dry-run.
      '';
    };

    dryRun = mkOption {
      type = types.bool;
      default = false;
      description = "Log matches (BLOCKLIST-*) without dropping, to soak the feeds first.";
    };

    updateInterval = mkOption {
      type = types.str;
      default = "6h";
      description = "Refresh interval (systemd time span). Feeds update hourly to daily upstream.";
    };

    maxElem = mkOption {
      type = types.int;
      default = 300000;
      description = "ipset maxelem. Must exceed the merged entry count with headroom.";
    };

    allow.ips = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra IPs/CIDRs that must never be blocked, merged into the protected
        set. Private space, loopback, CGNAT, local addresses, the default
        gateway and every strict-egress-resolved IP are already protected
        unconditionally and cannot be un-protected.
      '';
      example = [ "203.0.113.0/24" ];
    };

    logging = {
      enable = mkOption { type = types.bool; default = true; description = "Log matched packets."; };
      rateLimit = mkOption { type = types.str; default = "10/minute"; description = "iptables limit rate for log rules."; };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.networking.nftables.enable;
        message = ''
          networking.firewall.blocklists needs the iptables backend (it matches
          ipsets from INPUT/OUTPUT). networking.nftables.enable also collides
          with services.demod-ip-blocker — see modules/security/dcf-spa-gate.nix.
        '';
      }
      {
        assertion = cfg.feeds != [ ];
        message = "networking.firewall.blocklists.feeds is empty — either add a feed or set enable = false.";
      }
    ];

    # Sets must exist before the rules that reference them, and must survive a
    # firewall restart even if the updater has not run yet (an empty set simply
    # matches nothing).
    networking.firewall.extraCommands = ''
      ${pkgs.ipset}/bin/ipset create -exist ${setV4} hash:net family inet  hashsize 8192 maxelem ${toString cfg.maxElem}
      ${pkgs.ipset}/bin/ipset create -exist ${setV6} hash:net family inet6 hashsize 4096 maxelem ${toString cfg.maxElem}
      ${concatMapStringsSep "\n" mkChain chains}
    '';

    networking.firewall.extraStopCommands = concatMapStringsSep "\n" mkStop chains;

    systemd.services.oligarchy-blocklists-update = {
      description = "Oligarchy IP blocklists - fetch, validate and load threat feeds";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      # After strict-egress-resolve so /run/strict-egress/resolved.txt exists
      # before we read it as a never-block list. Ordering only — if strict-egress
      # is disabled the unit is absent and this is a no-op.
      after = [ "network-online.target" "firewall.service" "strict-egress-resolve.service" ];
      serviceConfig = {
        Type = "oneshot";
        # Not RemainAfterExit: an active oneshot makes every timer-driven start
        # a no-op, which is exactly how strict-egress's refresh silently never
        # ran. See modules/security/strict-egress.nix.
        RemainAfterExit = false;
        ExecStart = "${updateScript}/bin/oligarchy-blocklists-update";
        StateDirectory = "oligarchy-blocklists";
        User = "root";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        LockPersonality = true;
      };
    };

    systemd.timers.oligarchy-blocklists-refresh = {
      description = "Oligarchy IP blocklists - periodic feed refresh";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3m";
        OnUnitActiveSec = cfg.updateInterval;
        RandomizedDelaySec = "5m";
        Unit = "oligarchy-blocklists-update.service";
      };
    };

    environment.systemPackages = [ pkgs.ipset cli updateScript ];
  };
}
