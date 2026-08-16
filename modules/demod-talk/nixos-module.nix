# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (c) 2026 DeMoD LLC. A commercial license is available on request.
#
# services.demod-talk — DCF-Talk on Oligarchy.
#
# Per CLAUDE.md this defaults to OFF and is flipped on in configuration.nix.
# It is a feature, not a distro requirement (unlike custom.hydramesh, which
# installs the SDK CLIs this builds on and defaults to true).
#
# ─────────────────────────────────────────────────────────────────────────────
# THE SECURITY MODEL IS THE NETWORK. READ THIS BEFORE ENABLING.
#
# DCF carries no encryption — deliberately, to keep the framework clear of
# EAR/ITAR classification. Confidentiality here is a property of the tunnel you
# run it inside, not of the payload. So this module refuses to bind a wildcard
# address: `interface` is mandatory, and the firewall hole is opened on that
# interface only, never globally.
#
# What that buys, and what it does not:
#   defends   external attackers, transit observation, malformed traffic
#             (a 17-byte fixed-offset frame has no parser to exploit)
#   does NOT  a compromised peer inside the tunnel, a malicious insider, or
#             the operator — who can read everything, by design, like Slack
#
# Correct for a trusted-membership deployment. Wrong for a public network of
# strangers. See Documentation/DCF_TALK_SECURITY_MODEL.md.
# ─────────────────────────────────────────────────────────────────────────────
{ config, lib, pkgs, demod-talk ? null, ... }:

with lib;

let
  cfg = config.services.demod-talk;

  transportTiers = [ "lan" "wan" "rf" "acoustic" "debug" ];
  overTheAir = t: elem t [ "rf" "acoustic" ];

  wgIfaces = config.networking.wireguard.interfaces or { };
  wgQuickIfaces = config.networking.wg-quick.interfaces or { };
  isWg = wgIfaces ? ${cfg.interface};
  isWgQuick = wgQuickIfaces ? ${cfg.interface};

  # networking.wireguard.interfaces.wg0 -> wireguard-wg0.service
  # networking.wg-quick.interfaces.wg0  -> wg-quick-wg0.service
  tunnelUnit =
    if isWg then "wireguard-${cfg.interface}.service"
    else if isWgQuick then "wg-quick-${cfg.interface}.service"
    else null;
in
{
  options.services.demod-talk = {
    enable = mkEnableOption "DCF-Talk — decentralized voice and text over DeModFrame";

    package = mkOption {
      type = types.package;
      default =
        if demod-talk != null
        then demod-talk.packages.${pkgs.stdenv.hostPlatform.system}.demod-talk
        else throw ''
          services.demod-talk.package is unset and the `demod-talk` sub-flake was
          not passed to this module. Add it to flake.nix inputs as
          `demod-talk.url = "path:./modules/demod-talk";` and thread it through
          specialArgs, or set services.demod-talk.package explicitly.
        '';
      defaultText = literalExpression "demod-talk.packages.\${system}.demod-talk";
      description = "The demod-talk package (the certified Lua DCF chat stack).";
    };

    channel = mkOption {
      type = types.str;
      default = "demod-talk";
      example = "basement-jam";
      description = ''
        Rendezvous passphrase. Hashed with the repo-wide CRC-16 into the 16-bit
        frame `dst`, so peers that agree on a word land on the same channel with
        no handshake. This is a RENDEZVOUS, not a secret — a 16-bit space is
        trivially enumerable and the frames are plaintext. Secrecy comes from
        `interface`, never from this string.
      '';
    };

    interface = mkOption {
      type = types.str;
      example = "wg0";
      description = ''
        The interface to bind and to open the firewall on. MANDATORY and
        deliberately not defaulted: DCF is plaintext, so binding it to a
        wildcard address would put unencrypted voice on every network the
        machine can reach. Point this at your WireGuard interface.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 7317;                # 7317 — "731.7", the 17-byte frame
      description = "UDP port for DCF-Talk on `interface`.";
    };

    transport = mkOption {
      type = types.enum transportTiers;
      default = "wan";
      description = ''
        Datagram grouping and error control, per transport tier:

          lan       SuperPack-batched, no FEC          switched LAN
          wan       SuperPack-batched, no FEC          internet / VPN (default)
          rf        batched + Reed-Solomon(16)         SDR links
          acoustic  batched + Reed-Solomon(32)         HydraModem
          debug     one datagram per frame             198 kbps; diagnostics only

        Batching is the largest link-cost win available: 11 frames as 11
        datagrams costs 198 kbps for a 16 kbps stream; as one datagram, 86.
      '';
    };

    hub = {
      enable = mkEnableOption "run as a forwarding hub for this channel";

      maxSources = mkOption {
        type = types.ints.between 1 32;
        default = 8;
        description = ''
          Sources the hub will forward for. Capped at 32 by DCF-Snake's 5-bit
          stream_id field. The hub never decodes audio — it reads src/dst at
          fixed offsets, checks an ACL and forwards the bytes untouched — so
          frames stay byte-identical end to end and it needs no codec at all.
        '';
      };
    };

    history = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Persist chat history (DeMoD StreamDB, memory fallback).";
      };

      maxPerChannel = mkOption {
        type = types.int;
        default = 50000;
        description = "Retention cap per channel. 0 disables pruning.";
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open `port` on `interface` only. Never opens it globally — see the
        header comment. Set false if you manage nftables yourself.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--blocks" "0" ];
      description = "Extra arguments appended to the dcf-talk invocation.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.interface != "";
        message = "services.demod-talk.interface must name a real interface — "
          + "DCF is plaintext and must not be bound to a wildcard address.";
      }
      {
        # The tunnel is the security boundary, so make its absence loud rather
        # than letting plaintext voice quietly ride an untrusted link.
        assertion = isWg || isWgQuick
          || cfg.transport == "debug"
          || overTheAir cfg.transport;
        message = ''
          services.demod-talk.interface = "${cfg.interface}" is not a WireGuard
          interface declared on this host. DCF carries no encryption, so the
          tunnel IS the confidentiality boundary. Either declare the interface
          under networking.wireguard.interfaces / networking.wg-quick.interfaces,
          or choose an over-the-air transport where plaintext is expected and
          lawful.
        '';
      }
    ];

    warnings =
      optional (overTheAir cfg.transport) ''
        services.demod-talk.transport = "${cfg.transport}" transmits in the
        clear, and that is not merely a default — on US amateur bands, FCC Part
        97.113(a)(4) prohibits messages encoded to obscure their meaning, so
        plaintext is the lawful mode there. Treat everything on this channel as
        public and do not carry anything sensitive over it.
      ''
      ++ optional (cfg.transport == "debug") ''
        services.demod-talk.transport = "debug" sends one datagram per 17-byte
        frame — roughly 198 kbps for a 16 kbps voice stream, versus 86 kbps
        batched. Fine for packet captures, wasteful for anything else.
      '';

    environment.systemPackages = [ cfg.package ];

    networking.firewall = mkIf cfg.openFirewall {
      interfaces.${cfg.interface}.allowedUDPPorts = [ cfg.port ];
    };

    systemd.services.demod-talk = {
      description = "DCF-Talk — decentralized voice and text over DeModFrame";
      documentation = [ "https://github.com/ALH477/HydraMesh" ];
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ]
        ++ optional cfg.history.enable "local-fs.target"
        ++ optional (tunnelUnit != null) tunnelUnit;
      wants = [ "network-online.target" ];

      # Do not start before the tunnel exists: a race here means plaintext on
      # the wrong interface, which is exactly the failure this module prevents.
      bindsTo = optional (tunnelUnit != null) tunnelUnit;

      serviceConfig = {
        Type = "simple";
        # systemd parses ExecStart itself — it is not run through a shell — so
        # arguments are escaped with systemd's rules, not the shell's.
        ExecStart = escapeShellArgs ([
          "${cfg.package}/bin/dcf-talk"
          "--channel" cfg.channel
          "--transport" cfg.transport
        ]
        ++ optionals cfg.hub.enable [ "--hub" (toString cfg.hub.maxSources) ]
        ++ cfg.extraArgs);

        Restart = "on-failure";
        RestartSec = 5;

        DynamicUser = true;
        StateDirectory = mkIf cfg.history.enable "demod-talk";
        StateDirectoryMode = "0700";
        WorkingDirectory = mkIf cfg.history.enable "/var/lib/demod-talk";

        # A pure-Lua process that speaks UDP and writes one state directory has
        # no business doing anything else. Everything below is what that
        # sentence looks like as a unit file.
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];
        UMask = "0077";
      };
    };
  };

  meta.maintainers = [ ];
}
