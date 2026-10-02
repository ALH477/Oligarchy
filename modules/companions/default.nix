# custom.companions — this host commands ArchibaldOS companion machines.
#
# A companion is an older machine running ArchibaldOS's `companion` profile:
# a headless music computer with JACK on its audio interface (ArchibaldOS
# docs/companion.md). This host is its commander:
#
#   - a WireGuard hub (`wg-companions`, 10.77.0.1/24, UDP 51877). Companions
#     dial in; this side only listens, and each peer's allowedIPs is its own
#     /32, so a companion can reach this host and nothing behind it;
#   - `oligarchy-companion`: enrol a freshly installed companion, deploy to it
#     (built HERE, so a 4 GB machine never compiles), and drive its DSP stack
#     through dsp-ctl's SSH transport.
#
# Why WireGuard and not just the LAN: the DSP control protocol and DCF are
# plaintext by design (export posture), so the link beneath them is what
# provides confidentiality. Same rule as custom.vpn and demod-talk.
#
# Read-write and it reaches other machines, so like dsp-ctl and
# oligarchy-forge it stays OUT of the MCP surface.
#
# Opt-in, defaults off; disabled it emits nothing (no interface, no unit, no
# package, no /etc file), so the ISO needs no mkForce.
{ config, lib, pkgs, dsp-ctl, ... }:

let
  inherit (lib) mkOption mkEnableOption mkIf types mapAttrsToList mapAttrs optional;
  cfg = config.custom.companions;
  system = pkgs.stdenv.hostPlatform.system;

  hubPub = "/run/oligarchy-companions/hub.pub";

  cli = pkgs.writeShellApplication {
    name = "oligarchy-companion";
    runtimeInputs = with pkgs; [ openssh gnutar jq coreutils findutils gnugrep gawk iproute2 getent nixos-rebuild nix ]
      ++ [ dsp-ctl.packages.${system}.default ];
    text = builtins.readFile ./oligarchy-companion.sh;
  };

  member = types.submodule ({ name, ... }: {
    options = {
      address = mkOption {
        type = types.str;
        example = "10.77.0.2";
        description = "The companion's address on the hub's subnet (no prefix).";
      };
      publicKey = mkOption {
        type = types.str;
        description = ''
          The companion's WireGuard public key. `oligarchy-companion enroll`
          prints it; it was generated on the companion and its private half
          never leaves that machine.
        '';
      };
      user = mkOption {
        type = types.str;
        description = "The companion's user: JACK runs as it and dsp-ctl logs in as it.";
      };
    };
  });
in
{
  options.custom.companions = {
    enable = mkEnableOption "the WireGuard hub and CLI for commanding ArchibaldOS companions";

    interface = mkOption { type = types.str; default = "wg-companions"; description = "WireGuard interface name."; };
    address = mkOption {
      type = types.str;
      default = "10.77.0.1";
      description = "This host's address on the companion subnet. Companions' control bridges admit this address only.";
    };
    prefixLength = mkOption { type = types.ints.between 8 30; default = 24; description = "Subnet prefix length."; };
    listenPort = mkOption { type = types.port; default = 51877; description = "UDP port companions dial."; };
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Open `listenPort` (UDP). WireGuard answers nothing to a packet that is
        not from a configured peer, so this exposes no service.
      '';
    };
    privateKeyFile = mkOption {
      type = types.str;
      default = "/var/lib/wireguard/companions.key";
      description = "The hub's private key, generated on first start.";
    };
    members = mkOption {
      type = types.attrsOf member;
      default = { };
      example = lib.literalExpression ''
        { surface = { address = "10.77.0.2"; publicKey = "…"; user = "asher"; }; }
      '';
      description = ''
        Enrolled companions. `oligarchy-companion enroll` prints the entry to
        add here.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [{
      assertion = lib.allUnique (map (m: m.address) (lib.attrValues cfg.members) ++ [ cfg.address ]);
      message = "custom.companions: every member needs its own address, distinct from the hub's (${cfg.address}).";
    }];

    networking.wireguard.interfaces.${cfg.interface} = {
      ips = [ "${cfg.address}/${toString cfg.prefixLength}" ];
      inherit (cfg) listenPort privateKeyFile;
      generatePrivateKeyFile = true;
      peers = mapAttrsToList
        (name: m: {
          inherit name;
          inherit (m) publicKey;
          allowedIPs = [ "${m.address}/32" ];
        })
        cfg.members;
      # The public half, readable by the unprivileged CLI (enroll writes it
      # into the companion's commander.nix). The private key stays 0600 root.
      postSetup = ''
        mkdir -p ${dirOf hubPub}
        ${pkgs.wireguard-tools}/bin/wg show ${cfg.interface} public-key > ${hubPub}
        chmod 0644 ${hubPub}
      '';
    };
    networking.firewall.allowedUDPPorts = optional cfg.openFirewall cfg.listenPort;

    # What the CLI reads: where the hub is and who the members are. No keys.
    environment.etc."oligarchy/companions.json".text = builtins.toJSON {
      inherit (cfg) interface address prefixLength listenPort;
      publicKeyFile = hubPub;
      members = mapAttrs (_: m: { inherit (m) address user; }) cfg.members;
    };

    environment.systemPackages = [ cli pkgs.wireguard-tools ];
  };
}
