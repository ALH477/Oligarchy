# custom.vpn — Windscribe over WireGuard, on demand.
#
# There is no Windscribe package in nixpkgs, and the vendor client is a .deb
# that wants a root helper daemon. None of that is needed: Windscribe's config
# generator (windscribe.com/getconfig/wireguard) hands out a complete wg-quick
# .conf, so the whole subscription reduces to one encrypted blob plus kernel
# WireGuard. This module holds that blob's runtime path, brings the interface
# up through networking.wg-quick, and teaches the two egress filters on this
# box about it.
#
# Deliberately declared under networking.wg-quick.interfaces rather than a
# hand-rolled unit: modules/demod-talk/nixos-module.nix and
# modules/minecraft-server.nix both assert that their `interface` is a
# WireGuard interface by looking for the attribute NAME in
# networking.{wireguard,wg-quick}.interfaces. A bespoke unit would fail those
# assertions with a message that points nowhere near this file.
#
# ON DEMAND BY DEFAULT. autoStart = false, so nothing routes through Windscribe
# until `oligarchy-vpn up`. There is no kill switch: if the tunnel drops,
# traffic falls back to the plain route rather than going dark.
#
# Defaults OFF. Flip it in configuration.nix (or local.nix), do not edit this
# file to "turn it on". Not an always-on service, but the ISO forces it off
# anyway alongside the other opt-in modules. See docs/vpn-windscribe.md.
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.vpn;
  iface = cfg.interface;
  unit = "wg-quick-${iface}.service";

  # An endpoint entry is "IP" or "IP:port". The firewalls key on address only,
  # so strip anything from the last colon on — but only for v4 and bracketed
  # v6, since a bare v6 literal is all colons.
  stripPort = e:
    if lib.hasPrefix "[" e then
      lib.removeSuffix "]" (lib.head (lib.splitString "]" (lib.removePrefix "[" e)))
    else if lib.length (lib.splitString ":" e) == 2 then
      lib.head (lib.splitString ":" e)
    else e;

  endpointIps = map stripPort cfg.endpoints;

  vpnCli = pkgs.writeShellApplication {
    name = "oligarchy-vpn";
    runtimeInputs = with pkgs; [ systemd wireguard-tools iproute2 coreutils gnugrep gnused sops libnotify ];
    text = ''
      IFACE="${iface}"
      UNIT="${unit}"

      is_up() { ip link show "$IFACE" >/dev/null 2>&1; }

      # Report the resulting state wherever there is a session to report into.
      # Every trigger — the keybind, the waybar click, the control-center entry
      # — goes through here, so they all give the same feedback and none of
      # them has to re-implement it. Silent under ssh, in a VM test, and in any
      # other context with no display.
      announce() {
        if [ -n "''${WAYLAND_DISPLAY:-}''${DISPLAY:-}" ] && command -v notify-send >/dev/null 2>&1; then
          notify-send -a Windscribe "Windscribe" "$1"
        fi
        echo "$1"
      }

      usage() {
        cat <<'EOF'
      oligarchy-vpn — Windscribe WireGuard tunnel (on demand)

        up                 bring the tunnel up
        down               take it down
        toggle             flip it
        status             interface, peer, DNS and default route
        status --icon      one glyph, for the waybar module
        import <file.conf> encrypt a Windscribe config into the repo as the
                           sops secret, and print the custom.vpn.endpoints
                           line that goes with it

      The tunnel never starts on its own. See docs/vpn-windscribe.md.
      EOF
      }

      cmd_status() {
        if [ "''${1:-}" = "--icon" ]; then
          if is_up; then echo "󰦝 VPN"; else echo "󰦞"; fi
          return 0
        fi
        if ! is_up; then
          echo "windscribe: DOWN ($IFACE not present)"
          echo "bring it up with: oligarchy-vpn up"
          return 0
        fi
        echo "windscribe: UP"
        echo
        wg show "$IFACE" 2>/dev/null || echo "(wg show needs root for key material)"
        echo
        echo "-- default route --"
        ip route get 1.1.1.1 2>/dev/null || true
        if command -v resolvectl >/dev/null 2>&1; then
          echo
          echo "-- dns --"
          resolvectl status "$IFACE" 2>/dev/null || true
        fi
      }

      # Encrypt a downloaded Windscribe config into the repo's secret slot.
      # Mirrors oligarchy-adopt: it writes one file and then tells you the one
      # line you still have to paste, rather than editing local.nix behind you.
      cmd_import() {
        local src="''${1:-}"
        if [ -z "$src" ]; then
          echo "usage: oligarchy-vpn import <windscribe.conf>" >&2
          return 2
        fi
        if [ ! -r "$src" ]; then
          echo "no such readable file: $src" >&2
          return 1
        fi
        if ! grep -q '^\[Interface\]' "$src" || ! grep -q '^\[Peer\]' "$src"; then
          echo "$src does not look like a wg-quick config ([Interface]/[Peer] missing)" >&2
          return 1
        fi

        local flake="''${OLIGARCHY_FLAKE_DIR:-$PWD}"
        if [ ! -f "$flake/.sops.yaml" ]; then
          echo "no .sops.yaml in $flake — run this from the repo root, or set OLIGARCHY_FLAKE_DIR" >&2
          return 1
        fi
        # The placeholder recipient is the single most common way this fails,
        # and sops' own error for it is opaque.
        if grep -q 'age1PLACEHOLDER' "$flake/.sops.yaml"; then
          echo "$flake/.sops.yaml still holds the placeholder age recipient." >&2
          echo "Generate a key and paste its PUBLIC half in first:" >&2
          echo "  sudo mkdir -p /var/lib/sops-nix" >&2
          echo "  sudo age-keygen -o /var/lib/sops-nix/key.txt" >&2
          echo "  sudo chmod 600 /var/lib/sops-nix/key.txt" >&2
          return 1
        fi

        local dest="$flake/modules/secrets/windscribe-wg.enc.conf"
        mkdir -p "$flake/modules/secrets"
        ( cd "$flake" && sops --encrypt --input-type binary --output-type binary "$src" ) > "$dest.tmp"
        mv "$dest.tmp" "$dest"
        chmod 0644 "$dest"
        echo "wrote $dest"

        local ep
        ep=$(grep -i '^[[:space:]]*Endpoint' "$src" | head -n1 | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]')
        echo
        echo "Add to ~/.config/oligarchy/local.nix:"
        echo
        echo "  custom.secrets.vpn.enable = true;"
        echo "  custom.vpn.enable = true;"
        if [ -n "$ep" ]; then
          echo "  custom.vpn.endpoints = [ \"$ep\" ];"
        else
          echo "  # no Endpoint line found; set custom.vpn.endpoints by hand"
        fi
        echo
        echo "Then: sudo nixos-rebuild switch --flake .#nixos --impure"
        echo "The endpoints line is not cosmetic — it is what lets the outer"
        echo "encapsulated packet past strict-egress and the IP blocklists."
      }

      case "''${1:-status}" in
        up)     systemctl start "$UNIT" && announce "tunnel UP" && cmd_status ;;
        down)   systemctl stop "$UNIT" && announce "tunnel DOWN" ;;
        toggle) if is_up; then systemctl stop "$UNIT" && announce "tunnel DOWN"
                else systemctl start "$UNIT" && announce "tunnel UP"; fi ;;
        status) shift || true; cmd_status "''${1:-}" ;;
        import) shift; cmd_import "''${1:-}" ;;
        -h|--help|help) usage ;;
        *) usage; exit 2 ;;
      esac
    '';
    meta = {
      description = "Bring the Windscribe WireGuard tunnel up or down, and import its config into sops";
      mainProgram = "oligarchy-vpn";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
    };
  };
in
{
  options.custom.vpn = {
    enable = lib.mkEnableOption ''
      the Windscribe WireGuard tunnel (custom.vpn). Declares a wg-quick
      interface fed from a sops-held config, but starts nothing: the tunnel is
      on demand via `oligarchy-vpn up`. Requires custom.secrets.vpn.enable, or
      configFile set by hand
    '';

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wsc0";
      description = ''
        wg-quick interface name. Must be <= 15 characters. Changing it changes
        the unit name (wg-quick-<n>.service) and the strict-egress rule, both
        of which are derived from it.
      '';
    };

    configFile = lib.mkOption {
      # types.str, NOT types.path: a path literal would copy the private key
      # into the world-readable /nix/store. This is a RUNTIME path.
      type = lib.types.nullOr lib.types.str;
      # `or` at every hop so this module still evaluates where
      # modules/secrets.nix is absent (a VM test node importing only this
      # file), the same discipline strict-egress.nix uses to avoid referencing
      # options a given host may not declare.
      default =
        if (config.custom.secrets.enable or false)
          && (config.custom.secrets.vpn.enable or false)
        then config.sops.secrets."windscribe-wg".path
        else null;
      defaultText = lib.literalExpression ''config.sops.secrets."windscribe-wg".path, when custom.secrets.vpn.enable'';
      description = ''
        Runtime path to the Windscribe wg-quick .conf. Handed to
        networking.wg-quick.interfaces.<n>.configFile, which OVERRIDES every
        other interface option — so address, DNS, peer and MTU all come from
        inside this file, not from Nix.
      '';
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bring the tunnel up at boot. Off by default and meant to stay off: a
        full-tunnel VPN on every boot costs latency on every game and every
        voice call, and there is no kill switch here to make that trade worth
        paying continuously.
      '';
    };

    endpoints = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "184.75.223.226:443" ];
      description = ''
        The Peer Endpoint(s) from your Windscribe config, as "IP" or
        "IP:port". NOT a secret — an endpoint address is public infrastructure,
        and it has to be visible at eval time because the config file itself is
        an opaque encrypted blob.

        This is load-bearing, not documentation. The OUTER encapsulated packet
        is an ordinary UDP datagram to this address, and both
        networking.firewall.strictEgress and networking.firewall.blocklists
        filter it. Leave this empty under an enforcing egress policy and the
        tunnel simply never completes a handshake.

        Use endpointDomains instead if your config names a hostname.
      '';
    };

    endpointDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "us-central-001.whiskergalaxy.com" ];
      description = ''
        Hostname form of endpoints, for configs whose Peer Endpoint is a name
        rather than a literal address. Merged into strictEgress.allow.domains,
        so it is resolved and refreshed on the usual 15-minute timer.
      '';
    };

    trustTunnel = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Add the tunnel interface to networking.firewall.strictEgress
        .allow.interfaces, so traffic leaving through it is not filtered by
        destination.

        On is the right default for a full tunnel you turn on deliberately, and
        it is what keeps Discord voice and arbitrary game servers working while
        connected — both are IP-diverse UDP that no address allowlist can
        cover. The cost is real and worth naming: while the tunnel is up,
        strict-egress constrains nothing that routes through it, and Windscribe
        is the egress boundary instead.

        Turn it off to keep the boundary local. The address allowlist still
        works through a tunnel — an inner packet carries the real destination —
        so ordinary web traffic is unaffected; it is specifically the
        IP-diverse UDP that will start hitting the drop.
      '';
    };

    mtu = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 1420;
      description = ''
        MTU to set on the interface after it comes up. Applied by an
        ExecStartPost rather than by Nix, because configFile overrides the
        wg-quick module's own mtu option. Set null to leave whatever the .conf
        asked for (or wg-quick's own discovery) alone.
      '';
    };

    dns = {
      servers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "10.255.255.3" ];
        description = ''
          Resolvers to pin on the tunnel interface while it is up. Windscribe's
          in-tunnel resolver (which is also what serves R.O.B.E.R.T. filtering)
          is 10.255.255.3 and is reachable only through the tunnel.
        '';
      };

      useTunnelDns = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Make systemd-resolved actually prefer the tunnel's resolver.

          This is not redundant with the DNS= line in the Windscribe config.
          This host sets services.resolved.domains = [ "~." ] globally, which
          makes the global resolvers a candidate for every name; wg-quick's
          resolvconf call sets link DNS but no routing domain, so the global
          servers keep winning and the tunnel resolver is never consulted. The
          ExecStartPost below sets `~.` on the link itself to break that tie.

          Traffic still goes through the tunnel either way (AllowedIPs is
          0.0.0.0/0), so this is about WHICH resolver sees your queries, not
          about a plaintext leak to your ISP.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.configFile != null;
        message = ''
          custom.vpn.enable is on but custom.vpn.configFile is null, so there
          is no Windscribe config to bring up.

          Either set custom.secrets.vpn.enable = true (and mint the secret with
          `oligarchy-vpn import <windscribe.conf>`), or point
          custom.vpn.configFile at a root-readable runtime path yourself.
          See docs/vpn-windscribe.md.
        '';
      }
      {
        assertion = lib.stringLength cfg.interface <= 15;
        message = "custom.vpn.interface \"${cfg.interface}\" exceeds the 15-character kernel limit on interface names.";
      }
      {
        assertion = !(config.networking.firewall.strictEgress.enable
          && !config.networking.firewall.strictEgress.recovery.dryRun
          && cfg.endpoints == [ ] && cfg.endpointDomains == [ ]);
        message = ''
          strict-egress is enforcing (not dry-run) but custom.vpn declares
          neither endpoints nor endpointDomains, so the outer WireGuard packet
          has no path out and the tunnel will never handshake — silently, with
          no error from wg-quick.

          Set custom.vpn.endpoints to the Peer Endpoint in your Windscribe
          config; `oligarchy-vpn import` prints the exact line.
        '';
      }
    ];

    # Autoload is fine on this host (cpu-security's `hardened` preset leaves
    # lockKernelModules off), but an on-demand tunnel should not depend on it:
    # under the `vault` or `paranoid` preset the module could not load at the
    # moment you asked for the tunnel.
    boot.kernelModules = [ "wireguard" ];

    # Guarded on configFile rather than on cfg.enable alone. wg-quick's own
    # `assert` inside generateUnit fires during option evaluation, which is
    # EARLIER than the assertions list above — so declaring the interface with
    # a null configFile replaces the actionable message with wg-quick's
    # "Only one of privateKey, configFile or privateKeyFile may be set",
    # which points at nixpkgs and mentions neither sops nor custom.vpn.
    networking.wg-quick.interfaces = lib.mkIf (cfg.configFile != null) {
      ${iface} = {
        configFile = cfg.configFile;
        autostart = cfg.autoStart;
      };
    };

    # configFile overrides every Nix-side interface option, so MTU and the DNS
    # routing domain have to be applied after the interface exists.
    #
    # The two resolvectl lines carry systemd's "-" ignore-failure prefix, and
    # that prefix is the whole point: without it a resolvectl that cannot reach
    # resolved (not running, socket not up yet, D-Bus activation lost) fails
    # ExecStartPost, which fails the unit, which tears the tunnel back down. A
    # DNS preference is not worth the tunnel. Degrading here lands the host on
    # its global resolvers, which is exactly dns.useTunnelDns = false — a
    # supported configuration — and traffic still leaves through the tunnel
    # either way, because AllowedIPs is 0.0.0.0/0.
    #
    # `ip link set mtu` is deliberately NOT prefixed: it does not fail on a
    # live interface, and a silently wrong MTU is the kind of fault that shows
    # up later as large packets vanishing rather than as an error.
    systemd.services = lib.mkIf (cfg.configFile != null) {
      "wg-quick-${iface}".serviceConfig.ExecStartPost =
        lib.optional (cfg.mtu != null)
          "${pkgs.iproute2}/bin/ip link set dev ${iface} mtu ${toString cfg.mtu}"
        ++ lib.optionals (cfg.dns.useTunnelDns && cfg.dns.servers != [ ]) [
          "-${pkgs.systemd}/bin/resolvectl dns ${iface} ${lib.concatStringsSep " " cfg.dns.servers}"
          "-${pkgs.systemd}/bin/resolvectl domain ${iface} ~."
        ];
    };

    # The OUTER packet: an ordinary UDP datagram to the Windscribe endpoint.
    # Both filters on this box would otherwise eat it.
    networking.firewall.strictEgress.allow = {
      ips = endpointIps;
      domains = cfg.endpointDomains;
      # The INNER traffic. See the option's own description for the trade.
      interfaces = lib.optional cfg.trustTunnel iface;
    };

    # ip-blocklists inserts an unqualified `OUTPUT ... dst -j DROP` and its
    # protected set does NOT read strictEgress.allow.ips (only the resolved
    # domains file), so the endpoint has to be named here separately. A
    # commercial VPN endpoint on a threat feed is not hypothetical.
    networking.firewall.blocklists.allow.ips = endpointIps;

    # Let the desktop user flip the tunnel without a password prompt. Same
    # shape as modules/dsp-rigs.nix's manage-units rule, scoped to this one
    # unit rather than to systemd as a whole.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" && subject.isInGroup("wheel")) {
          if (action.lookup("unit") == "${unit}") {
            return polkit.Result.YES;
          }
        }
      });
    '';

    environment.systemPackages = [ vpnCli pkgs.wireguard-tools ];
  };
}
