# services.oligarchyHaven — Haven, a self-hosted private-chat Discord alternative.
#
# AGPL-3.0 upstream, packaged UNMODIFIED from an immutable release tag (see
# packages/haven.nix and README.md for the licence posture). This module
# defaults OFF; flip services.oligarchyHaven.enable in configuration.nix, never edit
# this file to "turn it on".
#
# ─────────────────────────────────────────────────────────────────────────────
# THE SECURITY MODEL IS THE NETWORK. READ THIS BEFORE ENABLING.
#
# Haven is a chat server: anyone who can reach it can register an account and
# post. So `interface` is mandatory and the port is admitted on THAT INTERFACE
# ONLY, never globally — the same shape services.oligarchyMinecraft and
# services.demod-talk use, for the same reason. The tailnet (or whatever
# tunnel you name) is the membership boundary.
#
# The process is additionally sandboxed to a dynamic user with a near-total
# systemd hardening stanza (see the serviceConfig block), because a chat server
# parses arbitrary, hostile input (messages, uploads, audio files) and is the
# likeliest thing here to be exploited. One deliberate exemption is documented
# inline: MemoryDenyWriteExecute is FALSE, because Node's V8 JIT must map
# writable+executable memory. That is the plugin-policy W^X mirror in
# AGENTS.md rule 3 — a per-instance *policy*, not a global law — and this
# service opts out per instance, the same way the plugin registry permits a
# signed plugin to clear allowSelfJit.
#
# Secrets: JWT_SECRET comes from sops (custom.secrets.haven.enable) and is
# rendered to a 0400 runtime file consumed via EnvironmentFile, so it never
# appears as a unit-file Environment= line and never lands world-readable in
# the store. If sops is disabled, the module falls back to an auto-generated
# secret held in the StateDirectory (Haven's own behaviour) with a loud
# warning — acceptable for a single-host tailnet, wrong for anything public.
#
# strict-egress is REPORT-ONLY here (house rule): this module emits a warning
# naming the hosts an operator must add to configuration.nix's allowlist if
# they enable optional outbound features (in-app updater/tunnel, push,
# link-preview/GIF, STUN), but it never writes the allowlist — strict-egress
# PULLS, and one auditable allowlist in configuration.nix is the point.
#
# ─────────────────────────────────────────────────────────────────────────────
self:
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.oligarchyHaven;

  # The package from this sub-flake, not pkgs. So the enable bit and the
  # derivation travel together and a host with enable=false never realizes it.
  haven = self.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Tunnel detection — lifted from modules/minecraft-server.nix and
  # modules/demod-talk. Tailscale IS WireGuard but is not declared under
  # networking.wireguard.interfaces, so an option-tree-only check would reject
  # a good tailnet.
  wgIfaces = config.networking.wireguard.interfaces or { };
  wgQuickIfaces = config.networking.wg-quick.interfaces or { };
  isWg = wgIfaces ? ${cfg.interface};
  isWgQuick = wgQuickIfaces ? ${cfg.interface};
  tsIface = config.services.tailscale.interfaceName or "tailscale0";
  isTailscale = (config.services.tailscale.enable or false) && cfg.interface == tsIface;

  tunnelUnit =
    if isWg then "wireguard-${cfg.interface}.service"
    else if isWgQuick then "wg-quick-${cfg.interface}.service"
    else if isTailscale then "tailscaled.service"
    else null;

  # Hosts Haven only needs when an operator turns on an OPTIONAL outbound
  # feature. Never written to the allowlist — reported, like minecraft-server's
  # requiredEgressHosts, so the single auditable list in configuration.nix
  # stays the source of truth.
  optionalEgressHosts = [
    # STUN defaults (stun.stunprotocol.org / stun.nextcloud.com) for WebRTC
    # voice. In practice tailnet voice is P2P; these matter only when NAT
    # punching needs a public reflector.
    "stun.stunprotocol.org"
    "stun.nextcloud.com"
  ];

  allowedEgressDomains = config.networking.firewall.strictEgress.allow.domains or [ ];
  missingEgressHosts = subtractLists allowedEgressDomains optionalEgressHosts;

  # JWT secret source. When sops is on, the secret is the decrypted dotenv file
  # (sops-nix writes `JWT_SECRET=…`) consumed via EnvironmentFile — systemd
  # reads it as root, so it never lands in the store or the unit text. When
  # sops is off, we leave JWT_SECRET unset so Haven auto-generates one into its
  # data dir on first boot (its documented behaviour) — with a warning.
  useSops = config.custom.secrets.enable or false && cfg.sops.enable;
in
{
  options.services.oligarchyHaven = {
    enable = mkEnableOption ''
      Haven — self-hosted private chat (AGPL-3.0). Binds loopback and is
      admitted on `interface` only; voice is peer-to-peer, so no UDP ports and
      no relay are opened by this module.
    '';

    package = mkOption {
      type = types.package;
      default = haven;
      defaultText = literalExpression "haven.packages.\${system}.default";
      description = "The Haven server package (AGPL-3.0 upstream, unmodified).";
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "TCP port Haven serves HTTPS on, admitted on `interface` only.";
    };

    interface = mkOption {
      type = types.str;
      default = tsIface;
      description = ''
        The tunnel interface Haven is reachable on. Must name a WireGuard,
        wg-quick or Tailscale interface (asserted). The firewall hole is opened
        on this interface only, never globally.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open `port` on `interface` only (never globally).";
    };

    serverName = mkOption {
      type = types.str;
      default = "Haven";
      description = "Display name for this server in multi-server clients.";
    };

    adminUsername = mkOption {
      type = types.str;
      default = "admin";
      description = "Username to register first; the first registration becomes admin.";
    };

    publicUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Public-facing URL (with scheme) for OAuth/OpenID callbacks and invite
        links when the server cannot determine its own external address. Leave
        null for a tailnet-only server.
      '';
    };

    environment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = ''
        Extra environment passed to the server. For the rare optional knobs
        (GIF API keys, OIDC client secret, TURN) that do not warrant a
        first-class option. Secrets here land in the unit and the store — use
        custom.secrets.haven for JWT_SECRET instead.
      '';
    };

    sops = {
      enable = mkEnableOption ''
        the encrypted JWT secret (modules/secrets/haven.enc.env, sops dotenv
        format, key JWT_SECRET). Without this the server auto-generates a secret
        into its data dir — fine for a single-host tailnet, not for anything
        public.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = isWg || isWgQuick || isTailscale;
        message = ''
          services.oligarchyHaven.interface = "${cfg.interface}" is not a tunnel interface
          on this host. A chat server grants account registration to anyone who
          can reach it, so the tunnel is the membership boundary and this module
          will not open the port anywhere else. Declare the interface under
          networking.wireguard.interfaces or networking.wg-quick.interfaces, or
          enable services.tailscale and point this at "${tsIface}".
        '';
      }
      {
        assertion = !useSops || config.custom.secrets.enable;
        message = ''
          services.oligarchyHaven.sops.enable = true but custom.secrets.enable is off.
          Enable custom.secrets.enable (and create modules/secrets/haven.enc.env)
          or set services.oligarchyHaven.sops.enable = false to fall back to a generated
          secret.
        '';
      }
    ];

    warnings =
      optional (cfg.enable && !useSops)
        "services.oligarchyHaven: JWT_SECRET is not provisioned via sops — Haven will generate one into its data dir. Fine for a single-host tailnet; enable custom.secrets.haven for anything shared."
      ++ optional
        (config.networking.firewall.strictEgress.enable or false && missingEgressHosts != [ ])
        ''
          services.oligarchyHaven: networking.firewall.strictEgress is enabled and these
          hosts are not in its allowlist: ${concatStringsSep " " missingEgressHosts}.
          Haven only needs them if you enable voice NAT-punching (STUN) or other
          optional outbound features. This module reports rather than writes —
          add them to networking.firewall.strictEgress.allow.domains in
          configuration.nix if you enable those features.
        '';

    # ── sops JWT secret ─────────────────────────────────────────────────────
    # EnvironmentFile points at the sops-decrypted dotenv; systemd's manager
    # reads it as root (so 0400 is fine) and injects JWT_SECRET into the
    # process environment without it ever appearing in the unit file.
    systemd.services.oligarchyHaven.serviceConfig.EnvironmentFile = mkIf useSops [
      config.sops.secrets."haven-jwt".path
    ];

    # Per-interface, never global, never trustedInterfaces.
    networking.firewall = mkIf cfg.openFirewall {
      interfaces.${cfg.interface}.allowedTCPPorts = [ cfg.port ];
    };

    systemd.services.oligarchyHaven = {
      description = "Haven — self-hosted private chat";
      after = optional (tunnelUnit != null) tunnelUnit;
      bindsTo = optional (tunnelUnit != null) tunnelUnit;
      wantedBy = [ "multi-user.target" ];

      # Static knobs. JWT_SECRET (when sops is on) arrives via EnvironmentFile
      # above; otherwise Haven generates it into the data dir on first boot.
      environment = {
        PORT = toString cfg.port;
        HOST = "127.0.0.1";
        SERVER_NAME = cfg.serverName;
        ADMIN_USERNAME = cfg.adminUsername;
        HAVEN_DATA_DIR = "/var/lib/haven";
      } // optionalAttrs (cfg.publicUrl != null) { PUBLIC_URL = cfg.publicUrl; } // cfg.environment;

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/haven";

        DynamicUser = true;
        User = "haven";
        Group = "haven";
        StateDirectory = "haven";
        WorkingDirectory = "/var/lib/haven";
        UMask = "0077";

        # ── The sandbox ─────────────────────────────────────────────────────
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
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
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
        CapabilityBoundingSet = [ ];

        # The data dir (DynamicUser's StateDirectory) stays writable;
        # /nix/store stays read-only via ProtectSystem=strict. No extra
        # ReadWritePaths needed: the env file is read by systemd, not the proc.
        ReadWritePaths = [ "/var/lib/haven" ];

        # AF_INET/AF_INET6 only: loopback listener + outbound WebRTC/STUN and
        # any optional callbacks. No AF_UNIX, AF_NETLINK, AF_PACKET.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];

        # DELIBERATE EXEMPTION — see the module header. Node's V8 JIT must map
        # writable+executable memory. This is the plugin-policy W^X mirror of
        # AGENTS.md rule 3 being opted out of, per instance, the same way the
        # plugin registry clears allowSelfJit for a signed plugin.
        MemoryDenyWriteExecute = false;
      };
    };
  };
}
