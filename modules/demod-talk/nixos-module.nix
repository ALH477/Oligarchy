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

  # Tailscale IS WireGuard, but it is not declared under
  # networking.wireguard.interfaces -- it brings up its own tailscale0 via
  # tailscaled. A tunnel check that only looked at those two option trees would
  # reject a perfectly good tailnet, so recognise it explicitly.
  tsIface = config.services.tailscale.interfaceName or "tailscale0";
  isTailscale = (config.services.tailscale.enable or false) && cfg.interface == tsIface;

  # networking.wireguard.interfaces.wg0 -> wireguard-wg0.service
  # networking.wg-quick.interfaces.wg0  -> wg-quick-wg0.service
  # services.tailscale                  -> tailscaled.service
  tunnelUnit =
    if isWg then "wireguard-${cfg.interface}.service"
    else if isWgQuick then "wg-quick-${cfg.interface}.service"
    else if isTailscale then "tailscaled.service"
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

    tailscale = {
      tag = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tag:demod-talk";
        description = ''
          Informational: the Tailscale ACL tag that gates this room. Tailscale
          ACLs are tailnet-wide policy and are not managed from NixOS, so this
          option documents the intended tag and is surfaced in the unit
          description -- it does not enforce anything by itself. The matching
          ACL grants only this tag `udp:${toString cfg.port}` on tagged hosts.

          Tailscale also happens to supply three things this stack otherwise
          lacks: NAT traversal, peer discovery, and cryptographic peer identity.
          It is the shortest path from the in-process demo to peers talking
          across the internet.
        '';
      };

      acknowledgeTailnetReach = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Silence the warning about every tailnet peer being able to reach the
          room port. Set this only once an ACL actually restricts it.
        '';
      };
    };

    agent = {
      enable = mkEnableOption "an LLM agent participating in this room";

      name = mkOption {
        type = types.str;
        default = "claude";
        description = "What the room calls the agent. Mentions gate inference.";
      };

      llmCommand = mkOption {
        type = types.listOf types.str;
        example = [ "ollama" "run" "llama3.2" ];
        default = [ ];
        description = ''
          Command producing a completion on stdout from a prompt on stdin. Local
          by default and by preference: a room reply is a first-token-latency
          problem, and a network round trip to a hosted model dominates it.
        '';
      };

      sttCommand = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "whisper-cpp" "--no-timestamps" "-f" "-" ];
        description = ''
          Speech-to-text, invoked ONLY on a completed talkspurt. DCF marks the
          trailing edge with FLAG_END_TALKSPURT via DTX, so segmentation is free
          and an idle room transcribes nothing at all.
        '';
      };

      ttsCommand = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "piper" "--model" "en_US-amy-medium" ];
        description = ''
          Optional. The agent replies in TEXT and each listener speaks it with
          its own local TTS -- a spoken reply as Opus costs ~86 kbps, the same
          reply as DCF-Text costs a few hundred bytes total. Set this only for
          clients that cannot synthesise locally.

          services.demod-voice already packages piper and Coqui on this distro.
        '';
      };

      maxTokens = mkOption {
        type = types.int;
        default = 1400;
        description = "Prompt budget. Older turns compact into a rolling summary.";
      };
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
        assertion = !cfg.agent.enable || cfg.agent.llmCommand != [ ];
        message = "services.demod-talk.agent.enable requires agent.llmCommand.";
      }
      {
        # The MCP surface on this distro is read-only and dry-run by
        # construction, and mcp_self_audit fails the build if a read-write
        # server reaches .mcp.json. An agent that SPEAKS into a room is
        # read-write by definition, so it lives here as an ordinary service --
        # the same category as dcf-mesh-agent and dcf-hypr-agent -- and must
        # never be registered as an MCP aspect. This assertion is a tripwire for
        # anyone who later wires the two together.
        assertion = !(cfg.agent.enable && (config.custom.mcpServers.extraServers or { }) ? demod-talk);
        message = ''
          services.demod-talk.agent is read-write (it speaks into rooms) and must
          stay out of the MCP surface, which is read-only by construction. Remove
          the demod-talk entry from custom.mcpServers.extraServers; expose a
          separate read-only aspect if agents need to READ room history.
        '';
      }
      {
        assertion = cfg.interface != "";
        message = "services.demod-talk.interface must name a real interface — "
          + "DCF is plaintext and must not be bound to a wildcard address.";
      }
      {
        # The tunnel is the security boundary, so make its absence loud rather
        # than letting plaintext voice quietly ride an untrusted link.
        assertion = isWg || isWgQuick || isTailscale
          || cfg.transport == "debug"
          || overTheAir cfg.transport;
        message = ''
          services.demod-talk.interface = "${cfg.interface}" is not a tunnel
          interface on this host. DCF carries no encryption, so the tunnel IS
          the confidentiality boundary. Declare it under
          networking.wireguard.interfaces or networking.wg-quick.interfaces,
          enable services.tailscale and point this at "${tsIface}", or choose an
          over-the-air transport where plaintext is expected and lawful.
        '';
      }
    ];

    warnings =
      # configuration.nix states plainly that tailscale0 is NOT a trusted
      # interface, because every tailnet peer would otherwise reach whatever
      # listens on it. That stance applies here: opening a UDP port on the
      # tailnet exposes the room to the whole tailnet unless ACLs say otherwise.
      optional (isTailscale && cfg.openFirewall && !cfg.tailscale.acknowledgeTailnetReach) ''
        services.demod-talk is opening UDP ${toString cfg.port} on ${tsIface},
        which every peer in your tailnet can reach. This host's own policy treats
        tailscale0 as untrusted for exactly that reason. Restrict the room with a
        Tailscale ACL keyed on a tag (see services.demod-talk.tailscale.tag), then
        set tailscale.acknowledgeTailnetReach = true to silence this.
      ''
      ++ optional (overTheAir cfg.transport) ''
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
      description = "DCF-Talk — decentralized voice and text over DeModFrame"
        + optionalString (cfg.tailscale.tag != null) " (ACL ${cfg.tailscale.tag})";
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
        ++ optionals cfg.agent.enable [
          "--agent" cfg.agent.name
          "--agent-max-tokens" (toString cfg.agent.maxTokens)
        ]
        ++ optionals (cfg.agent.enable && cfg.agent.llmCommand != [ ])
          [ "--llm" (concatStringsSep " " cfg.agent.llmCommand) ]
        ++ optionals (cfg.agent.enable && cfg.agent.sttCommand != [ ])
          [ "--stt" (concatStringsSep " " cfg.agent.sttCommand) ]
        ++ optionals (cfg.agent.enable && cfg.agent.ttsCommand != [ ])
          [ "--tts" (concatStringsSep " " cfg.agent.ttsCommand) ]
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
        # AF_UNIX is needed only when an agent shells out to a local model
        # server (ollama, llama.cpp) over a socket.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ]
          ++ optional cfg.agent.enable "AF_UNIX";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        # An agent forks STT/LLM/TTS helpers; without one, nothing is spawned.
        NoExecPaths = mkIf (!cfg.agent.enable) [ "/" ];
        CapabilityBoundingSet = [ "" ];
        AmbientCapabilities = [ "" ];
        UMask = "0077";
      };
    };
  };

  meta.maintainers = [ ];
}
