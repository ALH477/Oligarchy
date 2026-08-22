# ═══════════════════════════════════════════════════════════════════════════════
# Strict Egress Filtering — default-deny outbound, allowlist by domain/IP/port
# ═══════════════════════════════════════════════════════════════════════════════
# Rewritten on networking.nftables.tables (validated at build by checkRuleset):
#   - one `inet` table, sets and chain inside it (the old generator emitted
#     them at top level and never loaded resolved IPs — non-functional)
#   - static sets carry private nets + allow.ips; dynamic sets are populated
#     by a resolver service via `nft add element` with 26h timeouts
#   - DNS is pinned: only systemd-resolved may talk to remote resolvers,
#     everything else goes through the 127.0.0.53 stub
#   - recovery.dryRun switches the policy to accept and logs WOULDBLOCK lines,
#     so the allowlist can be soaked before enforcement
#
# Two failure modes worth not reintroducing (both cost a full outage):
#   - resolve with pkgs.getent, NOT pkgs.glibc.bin — getent is a separate
#     derivation, and the wrong path made every lookup fail into /dev/null,
#     leaving the dynamic sets empty on every generation
#   - recover with `nft delete table`, NOT `nft flush chain` — a base chain
#     keeps `policy drop` across a flush, so flushing fails *closed*
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.networking.firewall.strictEgress;

  # ── Mandatory allowlist ─────────────────────────────────────────────────────
  # Hostnames only (the old list carried path-suffixed entries that can never
  # resolve). Always resolved and allowed — critical for nixos-rebuild.
  mandatoryDomains = [
    "cache.nixos.org"
    "channels.nixos.org"
    "api.flakehub.com"
    "install.determinate.systems"
    "github.com"
    "api.github.com"
    "codeload.github.com"
    "objects.githubusercontent.com"
    "raw.githubusercontent.com"
  ];

  privateNets4 = [
    "10.0.0.0/8" # RFC1918
    "172.16.0.0/12" # RFC1918
    "192.168.0.0/16" # RFC1918
    "100.64.0.0/10" # RFC6598 (CGNAT / tailscale)
    "169.254.0.0/16" # link-local
  ];
  privateNets6 = [
    "fc00::/7" # ULA
    "fe80::/10" # link-local
  ];

  # UDP ports that must always work (DHCP, NTP, mDNS)
  mandatoryUdpPorts = [ 67 68 123 5353 ];

  # ── Presets ─────────────────────────────────────────────────────────────────
  presets = {
    minimal.domains = [ ];
    developer.domains = [
      "gitlab.com"
      "pypi.org"
      "files.pythonhosted.org"
      "registry.npmjs.org"
      "crates.io"
      "static.crates.io"
      "index.crates.io"
      "registry-1.docker.io"
      "auth.docker.io"
      "production.cloudflare.docker.com"
      "acme-v02.api.letsencrypt.org"
    ];
    workstation.domains = presets.developer.domains ++ [
      "discord.com"
      "gateway.discord.gg"
      "slack.com"
      "zoom.us"
      "accounts.google.com"
      "mail.google.com"
      "login.microsoftonline.com"
      "outlook.office.com"
      "aws.amazon.com"
      "cloudflare.com"
    ];
    server.domains = [ "acme-v02.api.letsencrypt.org" ];
  };

  autoDetectDomains =
    optionals (cfg.autoDetect.acme && config.security.acme.certs or { } != { }) [
      "acme-v02.api.letsencrypt.org"
      "acme-staging-v02.api.letsencrypt.org"
    ]
    ++ optionals (cfg.autoDetect.docker && (config.virtualisation.docker.enable || config.virtualisation.docker.rootless.enable)) [
      "registry-1.docker.io"
      "auth.docker.io"
      "production.cloudflare.docker.com"
    ]
    ++ optionals (cfg.autoDetect.firmware && config.services.fwupd.enable) [
      "cdn.fwupd.org"
      "fwupd.org"
    ];

  allDomains = unique (mandatoryDomains ++ presets.${cfg.preset}.domains ++ cfg.allow.domains ++ autoDetectDomains);

  isV6 = ip: hasInfix ":" ip;
  static4 = privateNets4 ++ (filter (ip: !isV6 ip) cfg.allow.ips);
  static6 = privateNets6 ++ (filter isV6 cfg.allow.ips);

  portRules = concatMapStringsSep "\n      "
    (pp:
      let dport = if pp.to != null then "${toString pp.port}-${toString pp.to}" else toString pp.port;
      in "${pp.proto or "tcp"} dport ${dport} accept"
    )
    cfg.allow.ports;

  uidRules = concatMapStringsSep "\n      "
    (u:
      ''meta skuid "${u}" accept''
    )
    cfg.allow.uids;

  logLevelArg = optionalString (cfg.logging.level != "off") "level ${cfg.logging.level} ";

  finalVerdict =
    if cfg.recovery.dryRun then
      (optionalString cfg.logging.enable ''
        limit rate ${cfg.logging.rateLimit} log ${logLevelArg}prefix "STRICT-EGRESS-WOULDBLOCK: " counter
      '')
    else if cfg.logging.enable then ''
      limit rate ${cfg.logging.rateLimit} log ${logLevelArg}prefix "STRICT-EGRESS-BLOCKED: " counter drop
      counter drop
    '' else ''
      counter drop
    '';

  # ── Standalone nft ruleset ──────────────────────────────────────────────────
  # A self-contained `table inet strict-egress`, loaded by its own service so
  # it COEXISTS with the iptables-based NixOS firewall (and demod-ip-blocker's
  # ipset/iptables INPUT rules) instead of flipping the whole firewall backend
  # to nftables. Our table only hooks `output`; the firewall hooks `input`.
  rulesetFile = pkgs.writeText "strict-egress.nft" ''
    table inet strict-egress
    delete table inet strict-egress
    table inet strict-egress {
      set egress_static4 {
        type ipv4_addr
        flags interval
        ${optionalString (static4 != []) "elements = { ${concatStringsSep ", " static4} }"}
      }
      set egress_static6 {
        type ipv6_addr
        flags interval
        ${optionalString (static6 != []) "elements = { ${concatStringsSep ", " static6} }"}
      }
      set egress_dyn4 {
        type ipv4_addr
        flags timeout
      }
      set egress_dyn6 {
        type ipv6_addr
        flags timeout
      }

      chain egress {
        type filter hook output priority filter + 10; policy ${if cfg.recovery.dryRun then "accept" else "drop"};

        oif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # DNS pinning: only systemd-resolved may reach remote resolvers
        # (53/853); every other process is confined to the local stub.
        meta skuid "systemd-resolve" udp dport 53 accept
        meta skuid "systemd-resolve" tcp dport { 53, 853 } accept

        meta l4proto icmp accept
        meta l4proto ipv6-icmp accept

        udp dport { ${concatMapStringsSep ", " toString mandatoryUdpPorts} } accept

        ${optionalString cfg.recovery.preserveLocalSsh "tcp sport 22 accept"}
        ${optionalString (cfg.allow.uids != [ ]) uidRules}
        ${optionalString (cfg.allow.ports != [ ]) portRules}

        ip daddr @egress_static4 accept
        ip6 daddr @egress_static6 accept
        ip daddr @egress_dyn4 accept
        ip6 daddr @egress_dyn6 accept

        ${finalVerdict}
      }
    }
  '';

  # ── Resolver: populate the dynamic sets through the pinned stub ─────────────
  # getent ahosts resolves via NSS -> systemd-resolved, the one path the
  # ruleset guarantees. Elements carry a 26h timeout while the timer refreshes
  # every 15m, so each domain accumulates its provider's live address pool and
  # genuinely stale IPs still age out on their own.
  resolveScript = pkgs.writeShellScriptBin "strict-egress-resolve" ''
    set -u
    NFT=${pkgs.nftables}/bin/nft
    # getent lives in its own derivation — it is NOT in glibc.bin. Pointing at
    # glibc.bin here silently resolved nothing at all (every lookup died with
    # "No such file or directory" into /dev/null), so the dynamic sets stayed
    # empty on every generation and enforcement black-holed the whole machine.
    GETENT=${pkgs.getent}/bin/getent
    RUNDIR=/run/strict-egress
    mkdir -p "$RUNDIR"
    : > "$RUNDIR/resolved.txt.new"

    # ── Wait for real connectivity ────────────────────────────────────────────
    # network-online.target is reached immediately on this host (both
    # *-wait-online units are force-disabled), so without this the first pass
    # runs ~20s before DHCP completes and every single lookup fails.
    for attempt in $(seq 1 30); do
      if [ -n "$(${pkgs.iproute2}/bin/ip -4 route show default 2>/dev/null)" ] \
        && $GETENT ahosts ${head mandatoryDomains} >/dev/null 2>&1; then
        break
      fi
      if [ "$attempt" -eq 30 ]; then
        echo "strict-egress: WARNING no connectivity after 60s — resolving anyway" >&2
      fi
      sleep 2
    done

    failed=0
    for domain in ${toString allDomains}; do
      ips=""
      for attempt in 1 2 3; do
        # stderr is deliberately NOT discarded: swallowing it is what hid the
        # broken getent path for weeks.
        ips=$($GETENT ahosts "$domain" | ${pkgs.gawk}/bin/awk '{print $1}' | sort -u)
        [ -n "$ips" ] && break
        sleep 2
      done
      if [ -z "$ips" ]; then
        echo "strict-egress: FAILED to resolve $domain (keeping any live set entries)" >&2
        failed=$((failed+1))
        continue
      fi
      for ip in $ips; do
        case "$ip" in
          *:*) $NFT add element inet strict-egress egress_dyn6 "{ $ip timeout 26h }" 2>/dev/null || true ;;
          *)   $NFT add element inet strict-egress egress_dyn4 "{ $ip timeout 26h }" 2>/dev/null || true ;;
        esac
        echo "$domain $ip" >> "$RUNDIR/resolved.txt.new"
      done
    done

    ${optionalString cfg.autoDetect.tailscale ''
      # ── Tailscale DERP relays ─────────────────────────────────────────────
      # ~88 relay nodes spread over ~47 unrelated /24s (Linode, Hetzner, DO…)
      # that drift over time, so pull the authoritative map out of tailscaled
      # instead of hardcoding ranges. `debug derp-map` needs no root. Without
      # this, relay fallback is blocked whenever direct UDP:41641 can't be
      # established — controlplane/login alone are not enough.
      derp=0
      if derpmap=$(${config.services.tailscale.package}/bin/tailscale debug derp-map 2>/dev/null); then
        for ip in $(printf '%s' "$derpmap" \
          | ${pkgs.gnugrep}/bin/grep -oE '"IPv[46]": *"[0-9a-fA-F.:]+"' \
          | ${pkgs.gnused}/bin/sed -E 's/.*"([0-9a-fA-F.:]+)"$/\1/' | sort -u); do
          case "$ip" in
            *:*) $NFT add element inet strict-egress egress_dyn6 "{ $ip timeout 26h }" 2>/dev/null || continue ;;
            *)   $NFT add element inet strict-egress egress_dyn4 "{ $ip timeout 26h }" 2>/dev/null || continue ;;
          esac
          derp=$((derp+1))
          echo "derp-map $ip" >> "$RUNDIR/resolved.txt.new"
        done
        echo "strict-egress: added $derp DERP relay addresses from the tailscale derp-map"
      else
        echo "strict-egress: WARNING tailscale derp-map unavailable (tailscaled down?) — relay fallback may be blocked" >&2
      fi
    ''}

    mv "$RUNDIR/resolved.txt.new" "$RUNDIR/resolved.txt"
    echo "strict-egress: resolved $(wc -l < "$RUNDIR/resolved.txt") entries ($failed domains failed)"

    ${optionalString (!cfg.recovery.dryRun) ''
      # Post-flight: enforcing a broken allowlist must not brick nixos-rebuild
      # — or the interactive session. Probe several independently-hosted
      # endpoints, because cache.nixos.org alone cannot tell us that everything
      # the user actually reaches for is dead.
      reachable=0
      total=0
      for probe in ${concatStringsSep " " cfg.recovery.probeHosts}; do
        total=$((total+1))
        if ${pkgs.curl}/bin/curl -fsSL --connect-timeout ${toString cfg.recovery.activationTimeout} \
            --max-time 30 "https://$probe" >/dev/null 2>&1; then
          reachable=$((reachable+1))
        else
          echo "strict-egress: post-flight probe FAILED: $probe" >&2
        fi
      done

      if [ "$reachable" -eq 0 ]; then
        echo "strict-egress: ERROR no probe host reachable under enforcement ($total tried)!" >&2
        ${if cfg.recovery.failOpen then ''
          echo "strict-egress: failOpen=true -> deleting the egress table (FAIL OPEN)" >&2
          # NOT `flush chain`: a base chain keeps its `policy drop` across a
          # flush, so flushing strips every accept rule (loopback, established,
          # DNS pinning, RFC1918) and silently black-holes ALL egress — the
          # opposite of failing open. Dropping the table removes the hook.
          $NFT delete table inet strict-egress || true
          exit 1
        '' else ''
          echo "strict-egress: failOpen=false -> staying closed. Fix the allowlist or run: nft delete table inet strict-egress" >&2
          exit 1
        ''}
      elif [ "$reachable" -lt "$total" ]; then
        echo "strict-egress: WARNING only $reachable/$total probe hosts reachable — the allowlist has gaps" >&2
      fi
    ''}
  '';

  statusScript = pkgs.writeShellScriptBin "strict-egress-status" ''
    set -u
    NFT=${pkgs.nftables}/bin/nft
    echo "Mode      : ${if cfg.recovery.dryRun then "DRY-RUN (logging only)" else "ENFORCING"} (preset: ${cfg.preset})"
    echo "Dyn v4    : $(sudo $NFT list set inet strict-egress egress_dyn4 2>/dev/null | grep -c 'timeout' || echo 0) entries"
    echo "Dyn v6    : $(sudo $NFT list set inet strict-egress egress_dyn6 2>/dev/null | grep -c 'timeout' || echo 0) entries"
    if [ -f /run/strict-egress/resolved.txt ]; then
      echo "Resolved  : $(wc -l < /run/strict-egress/resolved.txt) domain->IP entries"
    else
      echo "Resolved  : resolver has not run yet"
    fi
    echo "Recent ${if cfg.recovery.dryRun then "would-blocks" else "blocks"}:"
    journalctl -k -g "STRICT-EGRESS" -n 10 --no-pager 2>/dev/null || true
  '';

  testScript = pkgs.writeShellScriptBin "strict-egress-test" ''
    set -u
    host="''${1:?usage: strict-egress-test <hostname>}"
    echo "Resolving $host through the stub..."
    ${pkgs.getent}/bin/getent ahosts "$host" | ${pkgs.gawk}/bin/awk '{print "  " $1}' | sort -u
    echo "Connectivity (https):"
    if ${pkgs.curl}/bin/curl -fsSL --max-time 5 "https://$host" >/dev/null 2>&1; then
      echo "  OK — egress permitted"
    else
      echo "  BLOCKED or unreachable (check strict-egress-status / allow.domains)"
    fi
  '';

in
{
  # ═══════════════════════════════════════════════════════════════════════════
  # Options (API unchanged from the original module, plus allow.uids/failOpen)
  # ═══════════════════════════════════════════════════════════════════════════
  options.networking.firewall.strictEgress = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Strict egress filtering: default-deny outbound with an allowlist of
        domains, IPs, ports and users. Start with recovery.dryRun = true and
        watch `journalctl -k -g STRICT-EGRESS-WOULDBLOCK` before enforcing.
      '';
    };

    preset = mkOption {
      type = types.enum [ "minimal" "developer" "workstation" "server" ];
      default = "workstation";
      description = "Domain allowlist preset (mandatory NixOS/GitHub domains are always included).";
    };

    allow = {
      ips = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "IPs/CIDRs (v4 or v6) always allowed, merged into the static sets.";
        example = [ "192.168.1.0/24" "2001:db8::/32" ];
      };
      domains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra hostnames resolved into the dynamic allow sets (refreshed daily).";
      };
      ports = mkOption {
        type = types.listOf (types.submodule {
          options = {
            port = mkOption { type = types.port; description = "Start port (or the only port, if `to` is unset)."; };
            to = mkOption {
              type = types.nullOr types.port;
              default = null;
              description = ''
                End port, making this an inclusive range (port-to). Leave
                null for a single port. For destination-IP-diverse traffic
                that can't be domain-allowlisted (e.g. game servers), this is
                the escape hatch: it accepts by port regardless of address.
              '';
            };
            proto = mkOption { type = types.enum [ "tcp" "udp" ]; default = "tcp"; };
          };
        });
        default = [ ];
        description = "Destination ports (or port ranges via `to`) always allowed regardless of address.";
        example = [{ port = 41641; proto = "udp"; } { port = 27000; to = 27100; proto = "udp"; }];
      };
      uids = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          User names whose traffic bypasses egress filtering entirely
          (meta skuid). Escape hatch for daemons with IP-diverse endpoints.
        '';
      };
    };

    autoDetect = {
      acme = mkOption { type = types.bool; default = true; description = "Auto-allow Let's Encrypt when ACME certs are configured."; };
      docker = mkOption { type = types.bool; default = true; description = "Auto-allow Docker Hub when docker (rootful or rootless) is enabled."; };
      firmware = mkOption { type = types.bool; default = true; description = "Auto-allow fwupd metadata/firmware downloads when fwupd is enabled."; };
      tailscale = mkOption {
        type = types.bool;
        default = config.services.tailscale.enable;
        defaultText = literalExpression "config.services.tailscale.enable";
        description = ''
          Auto-allow Tailscale DERP relays by pulling the live derp-map from
          tailscaled at each refresh. The relay set spans dozens of unrelated
          /24s and drifts, so it cannot be usefully hardcoded; without this,
          relay fallback breaks whenever a direct connection can't be made.
        '';
      };
    };

    recovery = {
      preserveLocalSsh = mkOption {
        type = types.bool;
        default = true;
        description = "Keep inbound-SSH reply traffic working even across conntrack flushes (tcp sport 22 accept).";
      };
      activationTimeout = mkOption {
        type = types.int;
        default = 30;
        description = "Connect timeout, in seconds, for each post-resolve reachability probe (enforce mode).";
      };
      probeHosts = mkOption {
        type = types.listOf types.str;
        default = [ "cache.nixos.org" "api.anthropic.com" ];
        description = ''
          Hosts probed after resolution under enforcement. Recovery triggers
          only when every probe fails; a partial failure logs a warning. Use
          independently-hosted endpoints — a single CDN-fronted host cannot
          distinguish "one domain is missing" from "all egress is dead".
        '';
      };
      dryRun = mkOption {
        type = types.bool;
        default = false;
        description = "Log what would be blocked (WOULDBLOCK) without dropping anything.";
      };
      failOpen = mkOption {
        type = types.bool;
        default = true;
        description = ''
          If no host in recovery.probeHosts is reachable under enforcement,
          delete the egress table (fail open) instead of leaving the machine
          unable to rebuild. Set false for strict environments.
        '';
      };
    };

    logging = {
      enable = mkOption { type = types.bool; default = true; description = "Log dropped (or would-be-dropped) packets."; };
      level = mkOption { type = types.enum [ "debug" "info" "warn" "off" ]; default = "info"; description = "nftables log level."; };
      rateLimit = mkOption { type = types.str; default = "10/minute"; description = "Rate limit for log rules."; };
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════
  # Implementation
  # ═══════════════════════════════════════════════════════════════════════════
  config = mkIf cfg.enable {
    # Load our standalone table (coexists with the iptables firewall). Its own
    # service, not networking.nftables.enable, so demod-ip-blocker's iptables
    # rules keep working.
    systemd.services.strict-egress-rules = {
      description = "Strict Egress - load the nft egress table";
      wantedBy = [ "multi-user.target" ];
      after = [ "firewall.service" "network-pre.target" ];
      before = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Validate before applying; tear down only our own table on stop.
        ExecStartPre = "${pkgs.nftables}/bin/nft -c -f ${rulesetFile}";
        ExecStart = "${pkgs.nftables}/bin/nft -f ${rulesetFile}";
        ExecStop = "${pkgs.nftables}/bin/nft delete table inet strict-egress";
      };
    };

    # ── Resolver service + refresh timer ────────────────────────────────────
    systemd.services.strict-egress-resolve = {
      description = "Strict Egress - resolve allowlisted domains into nft sets";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "strict-egress-rules.service" "network-online.target" "systemd-resolved.service" ];
      requires = [ "strict-egress-rules.service" ];
      serviceConfig = {
        Type = "oneshot";
        # Deliberately NOT RemainAfterExit: a oneshot that stays "active" makes
        # every timer-driven `systemctl start` a no-op, so the refresh below
        # would never actually re-run.
        RemainAfterExit = false;
        ExecStart = "${resolveScript}/bin/strict-egress-resolve";
      };
    };

    systemd.timers.strict-egress-refresh = {
      description = "Strict Egress - periodic domain re-resolution";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m"; # catch-up: wait-online is masked on this host
        # CDN-fronted domains (GitHub/Fastly, CloudFront, Cloudflare) hand out a
        # rotating handful of addresses per lookup. Elements carry a 26h timeout
        # and `nft add element` accumulates, so refreshing every 15m builds up
        # the provider's actual pool instead of pinning a two-IP snapshot.
        OnUnitActiveSec = "15m";
        RandomizedDelaySec = "2m";
        Unit = "strict-egress-resolve.service";
      };
    };

    environment.systemPackages = [ pkgs.nftables resolveScript statusScript testScript ];
  };
}
