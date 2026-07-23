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
      "${pp.proto or "tcp"} dport ${toString pp.port} accept"
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
  # ruleset guarantees. Elements carry a 26h timeout (daily timer + slack),
  # so stale IPs age out on their own.
  resolveScript = pkgs.writeShellScriptBin "strict-egress-resolve" ''
    set -u
    NFT=${pkgs.nftables}/bin/nft
    RUNDIR=/run/strict-egress
    mkdir -p "$RUNDIR"
    : > "$RUNDIR/resolved.txt.new"

    failed=0
    for domain in ${toString allDomains}; do
      ips=""
      for attempt in 1 2 3; do
        ips=$(${pkgs.glibc.bin}/bin/getent ahosts "$domain" 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $1}' | sort -u)
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
    mv "$RUNDIR/resolved.txt.new" "$RUNDIR/resolved.txt"
    echo "strict-egress: resolved $(wc -l < "$RUNDIR/resolved.txt") entries ($failed domains failed)"

    ${optionalString (!cfg.recovery.dryRun) ''
      # Post-flight: enforcing a broken allowlist must not brick nixos-rebuild.
      if ! ${pkgs.curl}/bin/curl -fsSL --connect-timeout ${toString cfg.recovery.activationTimeout} \
          --max-time 30 https://cache.nixos.org >/dev/null 2>&1; then
        echo "strict-egress: ERROR cache.nixos.org unreachable under enforcement!" >&2
        ${if cfg.recovery.failOpen then ''
          echo "strict-egress: failOpen=true -> flushing egress chain (FAIL OPEN)" >&2
          $NFT flush chain inet strict-egress egress || true
          exit 1
        '' else ''
          echo "strict-egress: failOpen=false -> staying closed. Fix allowlist or run: nft flush chain inet strict-egress egress" >&2
          exit 1
        ''}
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
    ${pkgs.glibc.bin}/bin/getent ahosts "$host" | ${pkgs.gawk}/bin/awk '{print "  " $1}' | sort -u
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
            port = mkOption { type = types.port; };
            proto = mkOption { type = types.enum [ "tcp" "udp" ]; default = "tcp"; };
          };
        });
        default = [ ];
        description = "Destination ports always allowed regardless of address.";
        example = [{ port = 41641; proto = "udp"; }];
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
        description = "Seconds for the post-resolve cache.nixos.org reachability check (enforce mode).";
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
          If the post-resolve check cannot reach cache.nixos.org under
          enforcement, flush the egress chain (fail open) instead of leaving
          the machine unable to rebuild. Set false for strict environments.
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
        RemainAfterExit = true;
        ExecStart = "${resolveScript}/bin/strict-egress-resolve";
      };
    };

    systemd.timers.strict-egress-refresh = {
      description = "Strict Egress - periodic domain re-resolution";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m"; # catch-up: wait-online is masked on this host
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
        Unit = "strict-egress-resolve.service";
      };
    };

    environment.systemPackages = [ pkgs.nftables resolveScript statusScript testScript ];
  };
}
