# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025-2026, Asher LeRoy
# ═══════════════════════════════════════════════════════════════════════════════
# DCF-SPA port gate — single-packet authorization for one UDP service
# ═══════════════════════════════════════════════════════════════════════════════
# Runs HydraMesh's `dcf-spa-authorizer` against a self-contained nft table, so a
# gated port reads DROP to a LAN scan until a valid signed knock arrives.
#
# WHY THIS EXISTS INSTEAD OF upstream's spa/modules/dcf-spa.nix:
#
#   Upstream's module sets `networking.nftables.enable = true`, which switches
#   the global firewall backend. This host drives ipset/iptables through
#   `firewall.extraCommands` (services.demod-ip-blocker), and nixpkgs asserts
#   those are mutually exclusive — importing it fails eval outright.
#
#   modules/security/strict-egress.nix already established the right shape (see
#   its comment at ~L130): ship a self-contained table loaded by its own oneshot
#   service so it COEXISTS with the iptables firewall instead of replacing it.
#   This module does the same for the SPA ingress gate.
#
#   Only upstream's *package* is reused. `dcf-spa-authorizer` never creates the
#   table — it just runs `nft add element inet <table> <set> { ip timeout Ns }`
#   and accepts --nft-table/--nft-set — and the package already wraps `nft` onto
#   its PATH, so it has no dependency on networking.nftables.enable.
#
# WHAT IT IS NOT: authentication of the *port*, not of the protocol above it. A
# grant is per source IP for grantTtl seconds; anything sharing that IP (NAT, a
# second device on the LAN) rides in with it. See DCF_SPA_SPEC.md §3 — this is
# authentication only, no confidentiality, no key exchange.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.networking.firewall.spaGate;

  tableName = "dcf_spa_gate";
  setName = "allowed_peers";

  # ── The standalone gate table ───────────────────────────────────────────────
  # Deliberately NOT upstream's `policy drop` input chain. That shape is a
  # whole-system default-deny firewall and is only correct when dcf-spa IS the
  # firewall; dropped in next to the iptables firewall it would black-hole
  # everything else inbound (SSH, DHCP, mDNS).
  #
  # netfilter runs the iptables and nftables hooks independently: a `drop` in
  # either is final, an `accept` in one does NOT bypass the other. So
  # `policy accept` here leaves all non-mesh traffic entirely to the existing
  # firewall + demod-ip-blocker, while our drop on the mesh port stays
  # authoritative. Defense in depth is preserved rather than bypassed.
  #
  # Family MUST be inet: the authorizer hardcodes `inet` in its add-element args.
  rulesetFile = pkgs.writeText "dcf-spa-gate.nft" ''
    table inet ${tableName}
    delete table inet ${tableName}
    table inet ${tableName} {
      set ${setName} {
        type ipv4_addr
        flags timeout
      }
      chain input {
        type filter hook input priority filter - 10; policy accept;

        # Authorized (knocked) peers reach the gated port.
        ip saddr @${setName} udp dport ${toString cfg.meshPort} accept

        # Everyone else does not. This is the gate.
        udp dport ${toString cfg.meshPort} drop

        # IPv6 is dropped unconditionally, and that is load-bearing: the knock
        # channel is IPv4-only (the authorizer discards non-SocketAddr::V4) and
        # the allow-set is ipv4_addr, so a v6 peer can never be authorized.
        # Without this the gate is trivially bypassed over v6 — and Tailscale
        # hands out v6 addresses. Consequence: a gated controller must connect
        # to this box's IPv4 address.
        ip6 nexthdr udp udp dport ${toString cfg.meshPort} drop
      }
    }
  '';

  # Refuse to start with an empty credential store. The authorizer only warns
  # ("no credentials loaded") and then runs, which with this table in place
  # means every packet to meshPort is dropped forever — a silent self-DoS that
  # looks exactly like a broken network. Fail loudly instead.
  credsPreflight = pkgs.writeShellScript "dcf-spa-gate-preflight" ''
    set -eu
    dir=${escapeShellArg cfg.credsDir}
    if [ ! -d "$dir" ]; then
      echo "dcf-spa-gate: credsDir $dir does not exist" >&2
      exit 1
    fi
    # shellcheck disable=SC2012
    if [ -z "$(find "$dir" -maxdepth 1 -type f \( -name '*.pub' -o -name '*.key' \) -print -quit)" ]; then
      cat >&2 <<EOF
    dcf-spa-gate: no credentials in $dir

    The gate is active, so UDP ${toString cfg.meshPort} is currently DROPped for
    everyone and nothing can knock its way in. Provision at least one device:

      # Ed25519 (preferred — nothing secret is stored on this box)
      openssl genpkey -algorithm ed25519 -outform DER | tail -c 32 | xxd -p -c 32
      # keep that as the device's DCF_SPA_KEY, put its 32-byte raw PUBLIC key
      # (hex) in $dir/0001.pub

    See DCF_SPA_SPEC.md §11 in the HydraMesh repo.
    EOF
      exit 1
    fi
  '';
in
{
  options.networking.firewall.spaGate = {
    enable = mkEnableOption "DCF-SPA single-packet authorization gate for one UDP port";

    package = mkOption {
      type = types.package;
      description = ''
        The dcf-spa-authorizer package, e.g.
        `hydramesh.packages.''${system}.dcf-spa-authorizer`. Required — this
        module intentionally has no default so the pinned flake input stays the
        single source of the binary.
      '';
    };

    meshPort = mkOption {
      type = types.port;
      example = 7100;
      description = "The UDP port to gate. Dropped for everyone except peers holding a live grant.";
    };

    knockPort = mkOption {
      type = types.port;
      default = 62201;
      description = ''
        UDP port the authorizer listens on for knock packets. Stays reachable —
        it is the way in, and it is silent by design (never replies), so it
        leaks nothing to a scan.
      '';
    };

    credsDir = mkOption {
      type = types.path;
      default = "/etc/dcf-spa/peers";
      description = ''
        Directory of per-device credentials: `NNNN.pub` (32-byte raw Ed25519
        public key, hex) or `NNNN.key` (32-byte PSK, hex), NNNN = zero-padded
        device id.

        Prefer `.pub`: public keys are not secret, so this directory can be
        world-readable and needs no sops-nix handling. A `.key` PSK IS secret —
        route it through custom.secrets rather than committing it.
      '';
    };

    grantTtl = mkOption {
      type = types.int;
      default = 30;
      description = "Seconds an accepted knock keeps the port open for that source IP.";
    };

    windowMs = mkOption {
      type = types.int;
      default = 30000;
      description = "Replay window in milliseconds — how far a knock's timestamp may skew.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open knockPort and meshPort in the iptables firewall. Opening the gated
        port here is intended, not a contradiction: both netfilter backends must
        accept a packet, so the firewall admitting it leaves the nft gate above
        as the actual control. Without this the firewall drops the traffic first
        and the gate never sees a thing.
      '';
    };

    interfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "wlp1s0" ];
      description = ''
        Scope openFirewall to these interfaces instead of opening globally.
        Empty means global.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Load the gate table. Own oneshot service, NOT networking.nftables.enable
      # — see the header. Modeled directly on strict-egress-rules.
      systemd.services.dcf-spa-gate-rules = {
        description = "DCF-SPA gate - load the nft allow-set table";
        wantedBy = [ "multi-user.target" ];
        after = [ "firewall.service" "network-pre.target" ];
        before = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Validate before applying; tear down only our own table on stop.
          ExecStartPre = "${pkgs.nftables}/bin/nft -c -f ${rulesetFile}";
          ExecStart = "${pkgs.nftables}/bin/nft -f ${rulesetFile}";
          ExecStop = "${pkgs.nftables}/bin/nft delete table inet ${tableName}";
        };
      };

      # The authorizer. Hardening posture is upstream's (spa/modules/dcf-spa.nix)
      # kept verbatim — it only ever needs to edit one nftables set.
      systemd.services.dcf-spa = {
        description = "DCF-SPA single-packet port authorizer";
        wantedBy = [ "multi-user.target" ];
        # requires, not just after: `nft add element` against a table that does
        # not exist fails, and the authorizer would run on happily granting
        # nothing.
        requires = [ "dcf-spa-gate-rules.service" ];
        after = [ "dcf-spa-gate-rules.service" "network.target" ];

        serviceConfig = {
          ExecStartPre = credsPreflight;
          ExecStart = ''
            ${cfg.package}/bin/dcf-spa-authorizer \
              --knock-port ${toString cfg.knockPort} \
              --mesh-port ${toString cfg.meshPort} \
              --window-ms ${toString cfg.windowMs} \
              --grant-ttl ${toString cfg.grantTtl} \
              --creds-dir ${cfg.credsDir} \
              --nft-table ${tableName} --nft-set ${setName}
          '';
          Restart = "on-failure";
          RestartSec = 5;

          DynamicUser = true;
          # Narrowly scoped: the authorizer only needs to edit the nftables set.
          AmbientCapabilities = [ "CAP_NET_ADMIN" ];
          CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_NETLINK" ];
          SystemCallFilter = [ "@system-service" ];
          MemoryDenyWriteExecute = true;
          LockPersonality = true;
        };
      };

      # Public keys — readable is fine and intended (see credsDir description).
      systemd.tmpfiles.rules = [ "d ${cfg.credsDir} 0755 root root -" ];

      environment.systemPackages = [ pkgs.nftables ];
    }

    (mkIf (cfg.openFirewall && cfg.interfaces == [ ]) {
      networking.firewall.allowedUDPPorts = [ cfg.knockPort cfg.meshPort ];
    })

    (mkIf (cfg.openFirewall && cfg.interfaces != [ ]) {
      networking.firewall.interfaces = genAttrs cfg.interfaces (_: {
        allowedUDPPorts = [ cfg.knockPort cfg.meshPort ];
      });
    })
  ]);
}
