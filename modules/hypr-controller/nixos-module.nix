# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025-2026, Asher LeRoy
{ config, lib, pkgs, hydramesh, ... }:

with lib;

###############################################################################
# ⚠ NOT PART OF THE READ-ONLY OLIGARCHY MCP SURFACE. ⚠
#
# demod-hypr-bridge relays two things over a single UDP socket:
#   * `hypr <dispatch>` — live Hyprland IPC control (workspace/focus/kill/...)
#   * `ctl <args>`       — a byte-for-byte passthrough to `oligarchy-ctl`, i.e.
#     the whole control-center action registry (personas, DSP rig, power, DCF
#     fabric, security), reachable from a phone for free
#
# That passthrough is arbitrary command execution by design (see the "Quick
# Exec" field in the Android app) — this is a read-write, UDP-bound remote
# control endpoint, not a read-only introspection aspect. It must never be
# added to .mcp.json; `nix build .#mcp-self-audit` fails the build if it finds
# "dcf-hypr-agent" or "demod-hypr-bridge" there (see
# modules/mcp-servers/crates/ports-sec/src/mcp_self_audit.rs).
#
# Default is OFF and should stay that way unless you're actually pairing a
# controller device. Full picture (wire protocol, Android client, transport
# notes) in modules/hypr-controller/README.md.
###############################################################################

let
  cfg = config.services.dcf-hypr-agent;

  bridgeWrapper = pkgs.writeScriptBin "demod-hypr-bridge" ''
    #!${pkgs.runtimeShell}
    export DCF_HYPR_NODE_ID="${cfg.nodeId}"
    export DCF_HYPR_PEER_ID="${cfg.peerId}"
    export DCF_HYPR_UDP_PORT="${toString cfg.udpPort}"
    export DCF_HYPR_CTRL_CHANNEL="${cfg.controlChannel}"
    export DCF_HYPR_TELE_CHANNEL="${cfg.telemetryChannel}"
    export DCF_HYPR_CTL_BIN="${cfg.ctlBin}"
    export DCF_HYPR_PYTHON_MCP="${hydramesh}/python/MCP"
    exec ${pkgs.python3.withPackages (ps: [ ps.pynacl ])}/bin/python3 ${./hypr_bridge.py} "$@"
  '';
in
{
  options.services.dcf-hypr-agent = {
    enable = mkEnableOption "DCF-Hypr remote-controller bridge for the Hyprland session";

    nodeId = mkOption {
      type = types.str;
      default = "0x0001";
      description = "DCF node id for this bridge (hex). Mirrors DCF-Control's engine=1 convention.";
    };

    peerId = mkOption {
      type = types.str;
      default = "0x0002";
      description = "Expected controller node id (hex). Mirrors DCF-Control's GUI=2 convention.";
    };

    udpPort = mkOption {
      type = types.port;
      default = 7100;
      description = ''
        UDP port the bridge listens on. Transport-agnostic by design: whatever
        IP path currently reaches this box — Tailscale, LAN, or a USB-gadget
        link — just needs a route to this port; see
        modules/hypr-controller/docs/DCF_HYPR_SPEC.md.
      '';
    };

    controlChannel = mkOption {
      type = types.str;
      default = "demod-hypr-ctrl";
      description = "Passphrase hashed (crc16) into the control-channel dst_id.";
    };

    telemetryChannel = mkOption {
      type = types.str;
      default = "demod-hypr-tele";
      description = "Passphrase hashed (crc16) into the telemetry-channel dst_id.";
    };

    ctlBin = mkOption {
      type = types.str;
      default = "oligarchy-ctl";
      description = "Binary name/path for the existing control-center action dispatcher.";
    };

    openFirewallInterfaces = mkOption {
      type = types.listOf types.str;
      default = [ "tailscale0" ];
      example = [ "tailscale0" "usb0" ];
      description = ''
        Interfaces on which to admit udpPort. Without this the bridge is
        unreachable on every path: the global firewall opens only 5353/udp, and
        tailscale0 is deliberately NOT a trusted interface here (it admits ssh
        only), so even the "just use Tailscale" path was silently dropped.

        Defaults to the Tailscale interface because that is the documented
        trusted path. Add `usb0`/`rndis0` for a USB-gadget link. Naming an
        interface here opens the port on it unconditionally — for an untrusted
        LAN use spaGated instead, which gates the port rather than opening it.

        Set to [ ] to manage the firewall yourself.
      '';
    };

    spaGated = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Gate udpPort behind DCF-SPA (networking.firewall.spaGate,
        modules/security/dcf-spa-gate.nix) so it reads DROP to a LAN scan until
        a valid signed knock arrives. Turn on before exposing this to a shared
        or untrusted LAN; leave off when the only path in is Tailscale or a
        direct USB-gadget link.

        Two things it does NOT do. It authenticates the *port*, not the
        protocol above it — the bridge still has no signed hello, so a grant
        lets its holder drive `ctl` and Quick Exec. And a grant is per source
        IP for grantTtl seconds, so anything behind the same NAT rides in with
        it. Raises the bar against a LAN attacker; does not make Quick Exec
        safe on a hostile network.

        Gating forces IPv4: the knock channel is v4-only, so a gated controller
        must use this box's v4 address. See spaCredsDir — nothing gets in until
        that directory has a key, and the gate refuses to start without one
        rather than silently dropping everything.
      '';
    };

    spaCredsDir = mkOption {
      type = types.path;
      default = "/etc/dcf-spa/peers";
      description = ''
        Forwarded to networking.firewall.spaGate.credsDir when spaGated is on.
        One file per authorized controller device: `NNNN.pub` (32-byte raw
        Ed25519 public key, hex) or `NNNN.key` (32-byte PSK, hex), NNNN =
        zero-padded device id.

        The directory is created for you, but NOT populated — generate a key
        and copy the public half in (DCF_SPA_SPEC.md §11 has the openssl
        one-liner). Prefer `.pub`: public keys aren't secret, so nothing here
        needs sops-nix. A `.key` PSK is secret and does.
      '';
    };

    advertiseMdns = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Publish a `_dcfhypr._udp` avahi service so the app's NSD discovery
        path finds this box on plain LAN without a saved IP. Purely a
        convenience — broadcast-ping discovery works without it, and it's a
        no-op unless services.avahi is enabled.
      '';
    };

    sshAuth = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Generate a build-unique Ed25519 key pair for HyprController
        pairing-auth and SSH access. Each build-all.sh run creates a fresh
        key; the previous one is implicitly revoked when nixos-rebuild
        overwrites authorized_keys and the SPA peer file. The private key is
        baked into the APK via BuildConfig; the public key is installed in
        the configured user's authorized_keys and as a DCF-SPA peer
        credential for bridge pairing-auth.
      '';
    };

    sshAuthUser = mkOption {
      type = types.str;
      default = "asher";
      description = "User whose authorized_keys receives the controller's public key.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Surfaced by oligarchy-ports-sec-mcp's `listening_ports` as a
      # LAN-exposed UDP bind, same posture as dcf-mesh-agent. Expected — it's
      # the whole point of the module — hence the entry in known_endpoints.rs.
      warnings = [
        ''
          services.dcf-hypr-agent is enabled: this opens a read-write,
          UDP-bound Hyprland/oligarchy-ctl remote-control endpoint on port
          ${toString cfg.udpPort}. It is NOT part of the read-only Oligarchy
          MCP surface and must not be added to .mcp.json.
        ''
      ];

      environment.systemPackages = [ bridgeWrapper ];

      # Reachability. Without this the bridge starts, binds, and receives
      # nothing — the firewall drops udpPort before it ever gets there.
      networking.firewall.interfaces = genAttrs cfg.openFirewallInterfaces (_: {
        allowedUDPPorts = [ cfg.udpPort ];
      });

      systemd.user.services.dcf-hypr-agent = {
        description = "DCF-Hypr remote-controller bridge (Hyprland dispatch + oligarchy-ctl passthrough)";
        after = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];

        serviceConfig = {
          ExecStart = "${bridgeWrapper}/bin/demod-hypr-bridge";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };
    }
    (mkIf cfg.spaGated {
      # modules/security/dcf-spa-gate.nix, NOT upstream's spa/modules/dcf-spa.nix
      # — the latter flips networking.nftables.enable and collides head-on with
      # demod-ip-blocker's iptables backend. The gate module ships its own
      # standalone table (the strict-egress pattern) and reuses only upstream's
      # authorizer binary. Its header explains the whole thing.
      #
      # openFirewall there admits knockPort + udpPort; the nft gate is what
      # actually keeps udpPort dark until a signed knock lands.
      networking.firewall.spaGate = {
        enable = true;
        package = hydramesh.packages.${pkgs.stdenv.hostPlatform.system}.dcf-spa-authorizer;
        meshPort = cfg.udpPort;
        credsDir = cfg.spaCredsDir;
      };
    })
    (mkIf cfg.advertiseMdns {
      environment.etc."avahi/services/dcf-hypr.service".text = ''
        <?xml version="1.0" standalone='no'?>
        <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
        <service-group>
          <name replace-wildcards="yes">Oligarchy DCF-Hypr on %h</name>
          <service>
            <type>_dcfhypr._udp</type>
            <port>${toString cfg.udpPort}</port>
          </service>
        </service-group>
      '';
    })
    (mkIf cfg.sshAuth {
      # SSH authorized key from the build-generated public key.
      # current-key.pub is overwritten by build-all.sh before each rebuild;
      # it's a per-build artifact (gitignored), not a sops secret — the
      # public key isn't secret, and rotation is by rebuild.
      users.users.${cfg.sshAuthUser}.openssh.authorizedKeys.keys =
        [ (builtins.readFile ./current-key.pub) ];

      # DCF-SPA peer credential (raw Ed25519 public key, 64 hex chars) for
      # bridge pairing-auth verification. Same posture as the SPA creds dir —
      # public key, no sops needed.
      environment.etc."dcf-spa/peers/0001.pub".source =
        ./current-key-raw.pub;
    })
  ]);
}
