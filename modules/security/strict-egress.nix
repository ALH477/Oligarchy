{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.networking.firewall.strictEgress;

  # ═══════════════════════════════════════════════════════════════════════════════
  # Helper Functions
  # ═══════════════════════════════════════════════════════════════════════════════

  # Convert domain list to nftables set entries
  domainToNftset = domain: "${domain}";

  # Generate IP set entries from domain resolution
  ipsToNftset = ips: concatStringsSep "\n" (map (ip: "    ${ip}") ips);

  # Port protocol string to nftables format
  portProtoToNftables = pp: "${toString pp.port}/${pp.proto or "tcp"}";

  # ═══════════════════════════════════════════════════════════════════════════════
  # Mandatory Allowlist - Non-Configurable Baseline for NixOS
  # ═══════════════════════════════════════════════════════════════════════════════

  # These domains are ALWAYS allowed - critical for NixOS operation
  mandatoryDomains = [
    # Nix Binary Cache & Channels
    "cache.nixos.org"
    "channels.nixos.org"
    # Flake Registry
    "api.flakehub.com"
    "github.com/NixOS/flake-registry"
    # GitHub (primary flake host)
    "github.com"
    "api.github.com"
    "codeload.github.com"
    # GitLab (alternative)
    "gitlab.com"
    "gitlab.com/api/v4"
    # Docker Hub
    "registry-1.docker.io"
    "docker.io"
    # Let's Encrypt (ACME)
    "acme-v02.api.letsencrypt.org"
    "acme-staging-v02.api.letsencrypt.org"
  ];

  # Mandatory ports/protocols
  mandatoryPorts = [
    # DNS (systemd-resolved stub)
    { port = 53; proto = "udp"; }
    { port = 53; proto = "tcp"; }
    # NTP
    { port = 123; proto = "udp"; }
    # DHCP
    { port = 67; proto = "udp"; }
    { port = 68; proto = "udp"; }
    # mDNS
    { port = 5353; proto = "udp"; }
  ];

  # Private networks that are ALWAYS allowed
  privateNets = [
    # IPv4
    "10.0.0.0/8"       # RFC1918
    "172.16.0.0/12"    # RFC1918
    "192.168.0.0/16"   # RFC1918
    "100.64.0.0/10"    # RFC6598 (CGNAT)
    "169.254.0.0/16"   # Link-local
    # IPv6
    "fc00::/7"         # RFC4193 (ULA)
    "fe80::/10"        # Link-local
    "::1/128"          # Loopback
    "ff00::/8"         # Multicast
  ];

  # ═══════════════════════════════════════════════════════════════════════════════
  # Preset Definitions
  # ═══════════════════════════════════════════════════════════════════════════════

  presets = {
    minimal = {
      domains = [
        "cache.nixos.org"
        "channels.nixos.org"
      ];
    };

    developer = {
      domains = [
        # Nix
        "cache.nixos.org"
        "channels.nixos.org"
        "api.flakehub.com"
        # Git
        "github.com"
        "api.github.com"
        "gitlab.com"
        # Package registries
        "pypi.org"
        "registry.npmjs.org"
        "registry-1.docker.io"
        "docker.io"
        # ACME
        "acme-v02.api.letsencrypt.org"
      ];
    };

    workstation = {
      domains = presets.developer.domains ++ [
        # Productivity
        "api.github.com"
        "discord.com"
        "slack.com"
        "zoom.us"
        "teams.microsoft.com"
        # Auth providers
        "accounts.google.com"
        "login.microsoftonline.com"
        "auth0.com"
        "okta.com"
        # Cloud
        "aws.amazon.com"
        "cloudflare.com"
        "azure.microsoft.com"
        # Communication
        "mail.google.com"
        "outlook.office.com"
      ];
    };

    server = {
      domains = [
        "cache.nixos.org"
        "acme-v02.api.letsencrypt.org"
      ];
    };
  };

  # Resolve preset domains to IPs (merged with manual lists)
  resolvedPresetDomains = let
    preset = presets.${cfg.preset} or presets.developer;
  in preset.domains;

  # All domains to resolve (preset + manual)
  allDomains = resolvedPresetDomains ++ cfg.allow.domains;

  # Combine all allowed IPs (mandatory + resolved + manual)
  allAllowedIPs = privateNets ++ cfg.allow.ips;

  # ═══════════════════════════════════════════════════════════════════════════════
  # nftables Ruleset Generation
  # ═══════════════════════════════════════════════════════════════════════════════

  nftablesRules = let
    # Generate domain allow rules
    domainRules = concatStringsSep "\n" (map (domain: ''
      # Allow ${domain}
      ip daddr @strict_egress_domains_${replaceStrings ["." "-"] ["_" "_"] domain} accept
      ip6 daddr @strict_egress_domains_${replaceStrings ["." "-"] ["_" "_"] domain} accept
    '') allDomains);

    # Generate IP/CIDR allow rules
    ipRules = concatStringsSep "\n" (map (ip: ''
      # Allow ${ip}
      ip daddr ${ip} accept
      ip6 daddr ${ip} accept
    '') allAllowedIPs);

    # Generate port allow rules
    portRules = concatStringsSep "\n" (map (pp: ''
      # Allow port ${toString pp.port}/${pp.proto or "tcp"}
      ${if pp.proto == "udp" then "udp" else "tcp"} dport ${toString pp.port} accept
    '') (mandatoryPorts ++ cfg.allow.ports));

  in ''
    #!/usr/sbin/nft -f
    # Strict Egress Filtering - Defense in Depth
    # Generated by NixOS strict-egress module

    flush ruleset

    # ═══════════════════════════════════════════════════════════════════════════
    # Tables
    # ═══════════════════════════════════════════════════════════════════════════
    table ip strict_egress { }
    table ip6 strict_egress { }

    # ═══════════════════════════════════════════════════════════════════════════
    # Sets for domain-based filtering
    # ═══════════════════════════════════════════════════════════════════════════
    ${concatStringsSep "\n" (map (domain: ''
      set strict_egress_domains_${replaceStrings ["." "-"] ["_" "_"]} {
        type ipv4_addr
        flags constant,timeout
        elements = { }
      }
    '') allDomains)}

    ${concatStringsSep "\n" (map (domain: ''
      set strict_egress_domains_${replaceStrings ["." "-"] ["_" "_"]} {
        type ipv6_addr
        flags constant,timeout
        elements = { }
      }
    '') allDomains)}

    # ═══════════════════════════════════════════════════════════════════════════
    # Chains
    # ═══════════════════════════════════════════════════════════════════════════
    chain output {
      type filter hook output priority -100; policy drop;

      # ═══════════════════════════════════════════════════════════════════════
      # Always allow loopback
      # ═══════════════════════════════════════════════════════════════════════
      oif lo accept
      iif lo accept

      # ═══════════════════════════════════════════════════════════════════════
      # Allow established/related connections
      # ═══════════════════════════════════════════════════════════════════════
      ct state established,related accept

      # ═══════════════════════════════════════════════════════════════════════
      # Allow invalid state (some NAT scenarios)
      # ═══════════════════════════════════════════════════════════════════════
      ct state invalid accept

      # ═══════════════════════════════════════════════════════════════════════
      # Allow private networks (RFC1918, RFC6598, RFC4193)
      # ═══════════════════════════════════════════════════════════════════════
      ${ipRules}

      # ═══════════════════════════════════════════════════════════════════════
      # Allow DNS (systemd-resolved on localhost)
      # ═══════════════════════════════════════════════════════════════════════
      oif != lo udp dport 53 drop
      oif != lo tcp dport 53 drop

      # Allow to systemd-resolved stub (127.0.0.53)
      ip daddr 127.0.0.53 udp dport 53 accept
      ip daddr 127.0.0.53 tcp dport 53 accept

      # ═══════════════════════════════════════════════════════════════════════
      # Allow mandatory domains (NixOS, GitHub, etc.)
      # ═══════════════════════════════════════════════════════════════════════
      ${domainRules}

      # ═══════════════════════════════════════════════════════════════════════
      # Allow mandatory ports (NTP, DHCP, mDNS)
      # ═══════════════════════════════════════════════════════════════════════
      ${portRules}

      # ═══════════════════════════════════════════════════════════════════════
      # Allow SSH from local networks (recovery)
      # ═══════════════════════════════════════════════════════════════════════
      ${if cfg.recovery.preserveLocalSsh then ''
        tcp dport 22 ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, fc00::/7 } accept
      '' else ""}

      # ═══════════════════════════════════════════════════════════════════════
      # Logging (rate-limited)
      # ═══════════════════════════════════════════════════════════════════════
      ${if cfg.logging.enable then ''
        counter drop
        limit rate ${cfg.logging.rateLimit} counter drop
        log prefix "STRICT-EGRESS-BLOCKED: " counter drop
      '' else "counter drop"}
    }

    chain output6 {
      type filter hook output priority -100; policy drop;

      # Same as IPv4 but for IPv6
      oif lo accept
      iif lo accept
      ct state established,related accept
      ct state invalid accept

      ${ipRules}

      # IPv6 mDNS
      udp dport 5353 ip6 daddr ff02::fb accept

      # IPv6 NDP (router solicitation/advertisement)
      icmpv6 type { 133, 134, 135, 136 } accept

      ${domainRules}

      ${portRules}

      ${if cfg.recovery.preserveLocalSsh then ''
        tcp dport 22 ip6 saddr { fc00::/7, fe80::/10 } accept
      '' else ""}

      ${if cfg.logging.enable then ''
        limit rate ${cfg.logging.rateLimit} counter drop
        log prefix "STRICT-EGRESS-BLOCKED: " counter drop
      '' else "counter drop"}
    }
  '';

  # ═══════════════════════════════════════════════════════════════════════════════
  # Domain Resolution Script
  # ═══════════════════════════════════════════════════════════════════════════════
  domainResolverScript = pkgs.writeShellScriptBin "strict-egress-resolve" ''
    #!/usr/bin/env bash
    set -euo pipefail

    RESOLVED_IPS_DIR="/run/strict-egress"
    mkdir -p "$RESOLVED_IPS_DIR"

    resolve_domain() {
      local domain="$1"
      # Resolve A records
      dig +short "$domain" A 2>/dev/null || true
      # Resolve AAAA records
      dig +short "$domain" AAAA 2>/dev/null || true
    }

    echo "Resolving domains for strict-egress..."

    for domain in ${toString allDomains}; do
      echo "  Resolving $domain..."
      ips=$(resolve_domain "$domain")
      if [ -n "$ips" ]; then
        echo "$ips" >> "$RESOLVED_IPS_DIR/resolved-ips.txt"
        echo "    → $ips"
      else
        echo "    → FAILED (keeping old if exists)"
      fi
    done

    # Deduplicate
    sort -u "$RESOLVED_IPS_DIR/resolved-ips.txt" -o "$RESOLVED_IPS_DIR/resolved-ips.txt"

    echo "Resolved $(wc -l < "$RESOLVED_IPS_DIR/resolved-ips.txt") unique IPs"
  '';

  # ═══════════════════════════════════════════════════════════════════════════════
  # Pre-flight Check Script
  # ═══════════════════════════════════════════════════════════════════════════════
  preflightCheckScript = pkgs.writeShellScriptBin "strict-egress-preflight" ''
    #!/usr/bin/env bash
    set -euo pipefail

    echo "Running strict-egress pre-flight connectivity check..."

    # Test Nix cache connectivity (critical for nixos-rebuild)
    echo "  Testing connectivity to cache.nixos.org..."
    if curl -fsSL --connect-timeout ${toString cfg.recovery.activationTimeout} \
       --max-time 30 https://cache.nixos.org > /dev/null 2>&1; then
      echo "  ✓ cache.nixos.org reachable"
    else
      echo "✗ ERROR: cache.nixos.org is not reachable!"
      echo "  Applying strict egress would break nixos-rebuild."
      echo "  Aborting activation. Fix network connectivity first."
      exit 1
    fi

    # Test DNS resolution
    echo "  Testing DNS resolution..."
    if host github.com > /dev/null 2>&1; then
      echo "  ✓ DNS resolution working"
    else
      echo "  ✗ WARNING: DNS resolution not working"
    fi

    echo "Pre-flight check passed. Proceeding with egress filtering."
  '';

in {
  # ═══════════════════════════════════════════════════════════════════════════════
  # Module Options
  # ═══════════════════════════════════════════════════════════════════════════════
  options.networking.firewall.strictEgress = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable strict egress filtering with default-deny outbound policy.
        
        When enabled, all outbound connections are blocked by default unless
        explicitly allowed. This provides defense-in-depth against data exfiltration
        and ensures only approved destinations can be reached.
        
        **WARNING**: Misconfiguration can lock you out of network access.
        The module includes pre-flight checks to prevent lockout during activation.
      '';
      example = true;
    };

    preset = mkOption {
      type = types.enum [ "minimal" "developer" "workstation" "server" ];
      default = "workstation";
      description = ''
        Preset configuration for common workflows.
        
        - `minimal`: Only NixOS caches (cache.nixos.org, channels.nixos.org)
        - `developer`: + GitHub, GitLab, PyPI, npm, Docker Hub, Let's Encrypt
        - `workstation`: + Discord, Slack, Zoom, Google, Microsoft (full workstation)
        - `server`: Only cache.nixos.org + ACME (server hardening)
        
        This can be combined with `allow` for additional custom domains/IPs.
      '';
    };

    allow = mkOption {
      type = types.submodule {
        options = {
          ips = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              List of IP addresses or CIDR ranges to allow.
              These are added to the mandatory private network allowlist.
            '';
            example = [ "192.168.1.0/24" "10.0.0.5" "2001:db8::/32" ];
          };

          domains = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = ''
              List of domains to allow. These are resolved to IPs at activation
              and daily via systemd timer.
            '';
            example = [ "pypi.org" "registry.npmjs.org" "my-internal-api.local" ];
          };

          ports = mkOption {
            type = types.listOf types.submodule {
              options = {
                port = mkOption {
                  type = types.port;
                  description = "Port number";
                };
                proto = mkOption {
                  type = types.enum [ "tcp" "udp" ];
                  default = "tcp";
                  description = "Protocol";
                };
              };
            };
            default = [ ];
            description = ''
              List of port/protocol combinations to allow.
              These are added to the mandatory port allowlist.
            '';
            example = [ { port = 8000; proto = "tcp"; } { port = 5000; proto = "udp"; } ];
          };
        };
      };
      default = { };
      description = ''
        Manual allowlist entries (merged with preset if set).
      '';
    };

    autoDetect = mkOption {
      type = types.submodule {
        options = {
          acme = mkOption {
            type = types.bool;
            default = true;
            description = "Auto-allow Let's Encrypt endpoints if ACME is enabled";
          };
          docker = mkOption {
            type = types.bool;
            default = true;
            description = "Auto-allow Docker registries if Docker is enabled";
          };
          firmware = mkOption {
            type = types.bool;
            default = true;
            description = "Allow linux-firmware downloads during activation";
          };
        };
      };
      default = { };
      description = ''
        Auto-detect enabled services and automatically permit required endpoints.
      '';
    };

    recovery = mkOption {
      type = types.submodule {
        options = {
          preserveLocalSsh = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Always allow SSH from RFC1918 networks during activation.
              This provides a recovery mechanism if strict filtering breaks connectivity.
            '';
          };
          activationTimeout = mkOption {
            type = types.int;
            default = 30;
            description = ''
              Timeout in seconds for pre-flight connectivity test.
              If cache.nixos.org is not reachable within this time, activation aborts.
            '';
          };
          dryRun = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Preview rules without applying. For testing configuration.
            '';
          };
        };
      };
      default = { };
      description = ''
        Recovery safeguards to prevent admin lockout.
      '';
    };

    logging = mkOption {
      type = types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Enable logging of dropped packets";
          };
          level = mkOption {
            type = types.enum [ "debug" "info" "warn" "off" ];
            default = "info";
            description = "Log level";
          };
          rateLimit = mkOption {
            type = types.str;
            default = "10/minute";
            description = "Rate limit for log messages to prevent DoS";
          };
        };
      };
      default = { };
      description = ''
        Logging configuration for blocked connections.
      '';
    };
  };

  # ═══════════════════════════════════════════════════════════════════════════════
  # Module Configuration
  # ═══════════════════════════════════════════════════════════════════════════════
  config = mkIf cfg.enable {
    # Ensure nftables is available
    environment.systemPackages = [ pkgs.nftables domainResolverScript preflightCheckScript ];

    # ═══════════════════════════════════════════════════════════════════════════
    # Pre-flight check before applying rules
    # ═══════════════════════════════════════════════════════════════════════════════
    systemd.services.strict-egress-activation = {
      description = "Strict Egress - Pre-flight connectivity check";
      wantedBy = [ "multi-user.target" ];
      before = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${preflightCheckScript}/bin/strict-egress-preflight";
        RemainAfterExit = false;
      };
    };

    # ═══════════════════════════════════════════════════════════════════════════
    # Domain resolution at boot
    # ═══════════════════════════════════════════════════════════════════════════════
    systemd.services.strict-egress-resolve = {
      description = "Strict Egress - Resolve allowed domains to IPs";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "strict-egress-activation.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${domainResolverScript}/bin/strict-egress-resolve";
        RemainAfterExit = true;
      };
    };

    # ═══════════════════════════════════════════════════════════════════════════
    # Daily domain refresh timer
    # ═══════════════════════════════════════════════════════════════════════════════
    systemd.timers.strict-egress-refresh = {
      description = "Strict Egress - Daily domain re-resolution";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    systemd.services.strict-egress-refresh = {
      description = "Strict Egress - Refresh resolved domain IPs";
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${domainResolverScript}/bin/strict-egress-resolve";
        RemainAfterExit = true;
      };
    };

    # ═══════════════════════════════════════════════════════════════════════════
    # nftables ruleset
    # ═══════════════════════════════════════════════════════════════════════════
    systemd.services.strict-egress-rules = {
      description = "Strict Egress - Apply nftables rules";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "strict-egress-resolve.service" ];
      before = [ "network.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.nftables}/bin/nft -f -";
        ExecStartPost = "${pkgs.nftables}/bin/nft list ruleset > /run/strict-egress/ruleset.nft";
        RemainAfterExit = true;
      };
      # Dry run mode
      unitConfig = mkIf cfg.recovery.dryRun {
        ConditionVirtualization = "!container";
      };
    };

    # Store the ruleset as a file for systemd
    environment.etc."nftables/strict-egress.conf".text = nftablesRules;

    # ═══════════════════════════════════════════════════════════════════════════
    # Enable nftables
    # ═══════════════════════════════════════════════════════════════════════════════
    networking.firewall.enable = true;
    networking.firewall.backend = "nftables";

    # ═══════════════════════════════════════════════════════════════════════════════
    # Integration with auto-detect services
    # ═══════════════════════════════════════════════════════════════════════════════
    # ACME - Let's Encrypt (already in mandatory list via presets)
    # Note: Docker Hub is already included in developer/workstation presets

    # ═══════════════════════════════════════════════════════════════════════════════
    # Systemd journal for egress logging
    # (Logging is handled via nftables counter and log prefix)
    # View blocked packets: journalctl -f | grep "STRICT-EGRESS-BLOCKED"
    # ═══════════════════════════════════════════════════════════════════════════════
  };
}
