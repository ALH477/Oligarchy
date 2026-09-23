# custom.windscribeApp — the official Windscribe desktop client, helper daemon
# and CLI (github.com/Windscribe/Desktop-App).
#
# Defaults OFF. Flip it in configuration.nix (or local.nix), do not edit this
# file to "turn it on".
#
# This is the vendor client, not the wg-quick path. It is the alternative to
# modules/vpn.nix (`custom.vpn`), not a companion: both take over the default
# route, and an assertion below refuses to have them enabled at once. Pick by
# what you want — custom.vpn is declarative, on demand and carries no vendor
# code; this one gives you the GUI, the server picker, R.O.B.E.R.T., split
# tunnelling and the account management the CLI cannot do.
#
# Read-write and network-facing, so like oligarchy-forge it must stay out of
# the MCP surface (`nix build .#mcp-self-audit` fails the build if it lands in
# .mcp.json).
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.windscribeApp;
  app = self.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # /etc/windscribe/platform drives the in-app updater's choice of artifact
  # extension. Nothing here is a .deb install, but an UNRECOGNISED value is
  # worse than a wrong one: downloadHelper.cpp leaves the download path empty
  # and asserts. The updater itself is neutered in the package (its
  # install-update script refuses), so the value only has to parse.
  platformId =
    if pkgs.stdenv.hostPlatform.system == "aarch64-linux"
    then "linux_deb_arm64"
    else "linux_deb_x64";
in
{
  options.custom.windscribeApp = {
    enable = lib.mkEnableOption ''
      the Windscribe desktop client (custom.windscribeApp). Installs the GUI,
      windscribe-cli and the root helper daemon, and materialises the
      /opt/windscribe tree the binaries have compiled in.

      Mutually exclusive with custom.vpn: both take the default route
    '';

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        let n = config.custom.user.name or null;
        in lib.optional (n != null && n != "") n;
      defaultText = lib.literalExpression "[ config.custom.user.name ]";
      description = ''
        Accounts added to the "windscribe" group, which is what grants access
        to the helper's control socket.

        Upstream instead ships the GUI setgid windscribe (its postinst runs
        `chmod 2755`). That does not survive packaging into the Nix store, and
        reproducing it would mean a security.wrappers setgid wrapper. Group
        membership is the same access with none of the setgid surface, at the
        cost of a re-login the first time.
      '';
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Start the client automatically on login. Off by default, matching the
        rest of this repo: the helper daemon is always running and ready, so
        launching the GUI stays a deliberate act.
      '';
    };

    tunnelInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "wgwindscribe0" "tun0" ];
      description = ''
        Interfaces the client creates, added to
        networking.firewall.strictEgress.allow.interfaces when trustTunnel is
        on. "wgwindscribe0" is the WireGuard adapter and "tun0" the OpenVPN
        one; the stealth/wstunnel protocols ride the same tun device.

        Check `ip link` after connecting if egress enforcement bites. Unlike
        custom.vpn, the interface here is chosen by the vendor client at
        runtime rather than declared, so this list is a best guess rather than
        a derived fact.
      '';
    };

    trustTunnel = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Add tunnelInterfaces to networking.firewall.strictEgress
        .allow.interfaces, so traffic leaving through the client's tunnel is
        not filtered by destination.

        Same trade as custom.vpn.trustTunnel, and see that option for the
        reasoning: it is what keeps IP-diverse UDP (Discord voice, arbitrary
        game servers) working while connected, and it costs you the local
        egress boundary for as long as the tunnel is up.
      '';
    };

    allowServerEgress = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open the egress ports the client dials Windscribe's servers on: UDP
        443/1194/53/80/123/65142 (WireGuard and OpenVPN) and TCP 443/1194/80
        (stealth and wstunnel).

        This is a port-shaped hole rather than an address list on purpose, and
        it is the honest cost of running the vendor client under an enforcing
        egress policy. The client picks from a server pool of hundreds of
        addresses that it fetches at runtime, so there is nothing to
        allowlist — unlike custom.vpn, where the endpoint is a single address
        you can name. Turn this off and the client cannot connect at all under
        an enforcing policy.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(config.custom.vpn.enable or false);
        message = ''
          custom.windscribeApp and custom.vpn are both enabled. They are two
          ways to reach the same subscription and both take the default route,
          so having both is a race, not a redundancy.

          Pick one. custom.vpn is the declarative wg-quick path: on demand, no
          vendor code, one sops-held config. custom.windscribeApp is the vendor
          client: a GUI, the server picker, R.O.B.E.R.T. and split tunnelling,
          at the cost of a root helper daemon and a binary blob.
        '';
      }
    ];

    # HARD REQUIREMENT, and the failure is silent. helper/linux/server.cpp
    # getgrnam()s "windscribe" and, if it is missing, unlinks its own control
    # socket and returns — the unit stays "active", logs one line, and the
    # client just never connects. The run and state directories are chowned to
    # this group too.
    users.groups.windscribe = { };

    # Upstream's postinst also creates a system user of the same name. The
    # helper runs as root and nothing observed reads this account, but it is
    # created for parity with every other distro's install so that anything
    # that does getpwnam("windscribe") behaves the same here.
    users.users = lib.mkMerge [
      {
        windscribe = {
          isSystemUser = true;
          group = "windscribe";
          description = "Windscribe helper service account";
        };
      }
      (lib.genAttrs cfg.users (_: { extraGroups = [ "windscribe" ]; }))
    ];

    # The binaries have /opt/windscribe compiled in (WS_LINUX_INSTALL_DIR, a
    # -D define, not a runtime lookup) and reach their own scripts/ through it.
    # autoPatchelf rewrote the library RPATHs to store paths, so this symlink
    # exists for the scripts and for the helper, not for the loader.
    systemd.tmpfiles.rules = [
      "L+ /opt/windscribe - - - - ${app}/opt/windscribe"
      "d /var/log/windscribe 0750 root windscribe -"
    ];

    # /etc/windscribe/platform is read by the client; the autostart entry is
    # read by the client's own "launch on startup" toggle.
    environment.etc = lib.mkMerge [
      {
        "windscribe/platform".text = "${platformId}\n";
        "windscribe/autostart/windscribe.desktop".source =
          "${app}/share/windscribe/autostart/windscribe.desktop";
      }
      # The client's own "launch on startup" toggle writes a per-user autostart
      # entry; this is the system-level equivalent for a host that wants it
      # from the first boot.
      (lib.mkIf cfg.autoStart {
        "xdg/autostart/windscribe.desktop".source =
          "${app}/share/windscribe/autostart/windscribe.desktop";
      })
    ];

    # Our own unit rather than the shipped one. The difference that matters is
    # PATH: upstream pins it to /usr/sbin:/usr/bin:/sbin:/bin, which on NixOS
    # contains none of ip, nft, mount or resolvectl. The package also prepends
    # a store PATH inside each script, so this is belt and braces — the helper
    # runs some tools directly, not only through the scripts.
    systemd.services.windscribe-helper = {
      description = "Windscribe helper service";
      before = [ "network-pre.target" ];
      wants = [ "network-pre.target" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [
        bash
        coreutils
        gnugrep
        gnused
        gawk
        util-linux
        iproute2
        iptables
        nftables
        procps
        psmisc
        iputils
        wirelesstools
        iw
        systemd
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${app}/opt/windscribe/helper";
        Restart = "on-failure";
        RestartSec = 2;
      };
      # No sandboxing directives here on purpose. This daemon's whole job is to
      # rewrite the host's routing table, nftables ruleset, cgroups and
      # /etc/resolv.conf as root. Every ProtectSystem/RestrictAddressFamilies
      # line that looks like an improvement here would break one of those, and
      # break it at connect time rather than at start time.
    };

    # Windscribe's own control plane. The server pool itself is fetched at
    # runtime and is not allowlistable — see allowServerEgress.
    networking.firewall.strictEgress.allow = {
      domains = [
        "api.windscribe.com"
        "assets.windscribe.com"
        "windscribe.com"
        "www.windscribe.com"
      ];
      interfaces = lib.optionals cfg.trustTunnel cfg.tunnelInterfaces;
      ports = lib.optionals cfg.allowServerEgress [
        # WireGuard and OpenVPN UDP. These are the ports the config generator
        # offers, and the client uses the same set.
        { port = 53; proto = "udp"; }
        { port = 80; proto = "udp"; }
        { port = 123; proto = "udp"; }
        { port = 443; proto = "udp"; }
        { port = 1194; proto = "udp"; }
        { port = 65142; proto = "udp"; }
        # Stealth (OpenVPN over TLS) and wstunnel.
        { port = 1194; proto = "tcp"; }
      ];
    };

    environment.systemPackages = [ app ];
  };
}
