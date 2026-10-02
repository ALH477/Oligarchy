# ═══════════════════════════════════════════════════════════════════════════════
# modules/dsp-guest.nix — the ArchibaldOS DSP coprocessor guest, as CODE.
#
# WHY THIS EXISTS. The DSP VM used to be a hand-copied qcow2 (`~/vms/
# archibaldos-dsp.qcow2`, built out-of-tree in a separate repo) launched by a
# systemd unit that no `.nix` in this tree generated. Three config files in this
# repo *looked* like they defined it and none of them did:
#
#   modules/archibaldos-dsp-vm.nix        — commented out at flake.nix:284
#   vm-manager/config/archibaldos-dsp.nix — imported by nothing
#   modules/ArchibaldOS/                  — the ISO flake, a different image
#
# The consequence was not academic: the image stopped booting (OVMF found no
# EFI entry and fell through to PXE), and because nothing in the repo built it
# there was no way to fix it by rebuilding. The guest is defined here now, and
# the image is `nix build .#dsp-vm-qcow` — reproducible, and bootable by
# construction rather than by whoever last copied a file.
#
# THE RT STORY CHANGED, AND THIS SAYS SO. `linuxPackages-rt` and
# `linuxPackages-rt_latest` were REMOVED from nixpkgs ("removed due to lack of
# maintenance"), so a guest that claims PREEMPT_RT cannot simply ask for it any
# more. XanMod is used instead: it carries the RT patch set, it is already a
# supported variant in this flake's own kernel module, and it is maintained.
# Anything in the docs that says "RT kernel" means this, and the latency
# numbers should be re-measured rather than carried over.
#
# IT RUNS SOMETHING NOW. Until this change the guest installed jack2 and
# started nothing: no JACK server, no NetJack2, no engine. The host ran
# `jack_netsource` against it through a loopback forward, so no link could
# form. Now, on boot:
#
#   dsp-jackd           JACK on the passed-through interface if the host hands
#                       one over, else on the dummy driver
#   jack-netmanager     NetJack2 manager on `address`:`netjackPort` (ArchibaldOS
#                       modules/netjack.nix, role "manager")
#   demod-orchestrator  the DeMoD engine (orchestrator + demod-rt), DeMoD's
#                       packages from the archibaldos input (modules/demod-engine.nix)
#   jack-router         every NetJack2 follower's 1-2 into demod-rt, its output
#                       back to all of them (modules/jack-graph.nix)
#   dsp-control-bridge  TCP 7777 -> the engine's control socket, `hostAddress`
#                       only (dsp-ctl)
#   demod-remote-bridge DCF on UDP 47000, for a DeMoD app elsewhere: a
#                       companion's kiosk with engine = remote:<address>
#
# The ArchibaldOS modules come in through flake.nix (`dspGuestModules`), and the
# options below are set there from the HOST's custom.vm.dsp values, so the
# guest and the host that boots it cannot disagree about an address or a port.
# ═══════════════════════════════════════════════════════════════════════════════
{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types mkIf mkMerge;
  cfg = config.oligarchy.dspGuest;
  routed = cfg.network == "routed";

  # The passed-through interface when there is one. A USB interface can
  # enumerate after this starts, so a udev rule below restarts it when card 0
  # appears; when the interface goes away, jackd on alsa dies and Restart=
  # brings it back on the dummy driver. Which one it picked is the first line
  # of its journal.
  jackdStart = pkgs.writeShellScript "dsp-jackd" ''
    if [ -e /dev/snd/controlC0 ]; then
      echo "dsp-jackd: ALSA card 0 present: jackd on hw:0" >&2
      exec ${pkgs.jack2}/bin/jackd -R -d alsa -d hw:0 -r ${toString cfg.sampleRate} -p ${toString cfg.period} -n 2
    fi
    echo "dsp-jackd: no ALSA card in this guest: jackd on the dummy driver (NetJack2 followers and the engine only)" >&2
    exec ${pkgs.jack2}/bin/jackd -R -d dummy -r ${toString cfg.sampleRate} -p ${toString cfg.period}
  '';
in
{
  options.oligarchy.dspGuest = {
    network = mkOption {
      type = types.enum [ "routed" "user" ];
      default = "routed";
      description = "The host's custom.vm.dsp.network.mode. user: DHCP from QEMU user-mode networking, no NetJack2.";
    };
    address = mkOption { type = types.str; default = "10.78.0.2"; description = "This guest's address (routed)."; };
    hostAddress = mkOption { type = types.str; default = "10.78.0.1"; description = "The host's address on the tap: the gateway, and the only peer the control bridge and ssh admit."; };
    prefixLength = mkOption { type = types.ints.between 8 30; default = 24; description = "Prefix length of the tap subnet."; };
    mac = mkOption { type = types.str; default = "52:54:00:78:00:02"; description = "The MAC of the NIC to configure (the host sets it on the QEMU device)."; };
    netjack = mkOption { type = types.bool; default = routed; defaultText = lib.literalExpression ''network == "routed"''; description = "Run the NetJack2 manager."; };
    netjackPort = mkOption { type = types.port; default = 19000; description = "The NetJack2 manager's UDP port."; };
    sampleRate = mkOption { type = types.int; default = 96000; description = "JACK sample rate; every NetJack2 follower runs at it."; };
    period = mkOption { type = types.int; default = 32; description = "JACK period in frames."; };
    remotePort = mkOption { type = types.port; default = 47000; description = "UDP port of demod-remote-bridge (DCF)."; };
    authorizedKeys = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Keys for root over ssh: the host's custom.user.sshAuthorizedKeys (set in flake.nix). Empty: the serial console only.";
    };
  };

  config = mkMerge [
    {
      # ── Boot ─────────────────────────────────────────────────────────────────
      # UEFI, to match the OVMF firmware the host runner supplies. The old image
      # failed here: no EFI system partition, so OVMF fell through to PXE and sat
      # in the netboot loop forever. `nixos-generators -f qcow-efi` produces the
      # ESP; this half just has to agree with it.
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = false;
      boot.loader.timeout = 0;

      boot.kernelPackages = pkgs.linuxPackages_xanmod_latest;

      # `console=ttyS0` is what makes the host's console socket useful — without it
      # the guest talks to a VGA device nobody is watching.
      boot.kernelParams = [
        "console=ttyS0,115200n8"
        "preempt=full"
        "threadirqs"
        "mitigations=off" # a single-purpose guest on an isolated core
        "nohz_full=1"
        "rcu_nocbs=1"
      ];

      boot.initrd.availableKernelModules = [
        "virtio_pci"
        "virtio_blk"
        "virtio_net"
        "virtio_scsi"
        "xhci_pci"
        "usbhid"
        "usb_storage"
        "snd_usb_audio"
      ];
      boot.kernelModules = [ "snd_usb_audio" "snd_seq" ];

      # nrpacks=1 is the low-latency USB-audio setting; the whole point of passing
      # an xHCI controller through is to be able to set it.
      boot.extraModprobeConfig = ''
        options snd_usb_audio nrpacks=1
      '';

      # ── Reachability ─────────────────────────────────────────────────────────
      # TWO ways in, on purpose. The serial console is how you get a shell when
      # networking is broken; ssh is how anything gets SCRIPTED. The old guest had
      # neither — its console went to a write-only log file and the only forwarded
      # port was NETJACK — which is why a measurement could never be automated.
      services.getty.autologinUser = "root";
      systemd.services."serial-getty@ttyS0".enable = true;

      services.openssh = {
        enable = true;
        # Opened below, to the host's address only.
        openFirewall = false;
        settings = {
          PermitRootLogin = "prohibit-password";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
      };

      # The keys come from the HOST's config now. They used to be one hardcoded
      # maintainer key, because the image was built with no arguments from any
      # host and a host-side option would have silently done nothing. The image
      # is built from the host's values now (flake.nix, mkDspImage), so the keys
      # are custom.user.sshAuthorizedKeys there, and a machine installed from the
      # ISO (which empties that list) carries no maintainer key into its guest.
      users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;

      # On. The routed guest is a real host on the tap subnet, and NetJack2
      # followers on WireGuard reach it through the host.
      networking.firewall.enable = true;
      networking.hostName = "archibaldos-dsp";

      # ── Audio ────────────────────────────────────────────────────────────────
      # JACK, not PipeWire. This guest exists to be a deterministic audio device,
      # and a session-oriented sound server is the wrong shape for that.
      security.rtkit.enable = true;
      security.pam.loginLimits = [
        { domain = "@audio"; type = "-"; item = "rtprio"; value = "99"; }
        { domain = "@audio"; type = "-"; item = "memlock"; value = "unlimited"; }
        { domain = "@audio"; type = "-"; item = "nice"; value = "-19"; }
      ];
      users.groups.audio = { };
      users.users.root.extraGroups = [ "audio" ];

      # The JACK server, the router, the NetJack2 manager and the engine all run
      # as this account: JACK keeps one server per user.
      users.users.dsp = {
        isSystemUser = true;
        group = "audio";
        extraGroups = [ "audio" ];
      };

      environment.systemPackages = with pkgs; [
        alsa-utils
        jack2
        # `jack_iodelay` lives HERE and nowhere else — it is NOT in jack2 (checked:
        # jack2's bin/ has no iodelay at all). Without it this guest cannot measure
        # its own round trip, which is the one number the whole coprocessor claim
        # rests on. See scripts/dsp-latency-guest.sh.
        jack-example-tools
        usbutils
        htop
        vim
      ];

      # ── JACK ─────────────────────────────────────────────────────────────────
      systemd.services.dsp-jackd = {
        description = "JACK: the passed-through interface, or the dummy driver";
        wantedBy = [ "multi-user.target" ];
        after = [ "sound.target" ];
        serviceConfig = {
          User = "dsp";
          Group = "audio";
          Restart = "always";
          RestartSec = 2;
          LimitRTPRIO = 99;
          LimitMEMLOCK = "infinity";
          ExecStart = jackdStart;
        };
      };
      services.udev.extraRules = ''
        # An interface that enumerates after JACK started: restart JACK onto it.
        ACTION=="add", SUBSYSTEM=="sound", KERNEL=="controlC0", RUN+="${pkgs.systemd}/bin/systemctl --no-block try-restart dsp-jackd.service"
      '';

      archibald.jack = { user = "dsp"; unit = "dsp-jackd.service"; };

      # ── The engine ───────────────────────────────────────────────────────────
      # demod-rt's audio thread on vCPU 1, the one nohz_full/rcu_nocbs leave
      # alone. io = "system": the interface (when there is one) in and out of the
      # engine, alongside every NetJack2 follower.
      archibald.engine = {
        enable = true;
        io = "system";
        rtCore = 1;
        remote = mkIf routed {
          enable = true;
          bind = cfg.address;
          port = cfg.remotePort;
        };
      };

      archibald.dsp.control = {
        enable = true;
        user = "dsp";
        group = "audio";
        socket = config.archibald.engine.controlSocket;
        # QEMU user-mode networking presents the host as 10.0.2.2.
        allowFrom = if routed then "${cfg.hostAddress}/32" else "10.0.2.2/32";
      };

      # ── Nothing else ─────────────────────────────────────────────────────────
      services.xserver.enable = false;
      documentation.enable = false;
      documentation.nixos.enable = false;
      system.stateVersion = "25.11";
    }

    (mkIf routed {
      # The NIC with the host's MAC, a static address, the host as gateway. No
      # DHCP and no DNS: nothing on this guest looks anything up.
      networking.useDHCP = false;
      networking.useNetworkd = true;
      systemd.network.networks."10-dsp" = {
        matchConfig.MACAddress = cfg.mac;
        address = [ "${cfg.address}/${toString cfg.prefixLength}" ];
        gateway = [ cfg.hostAddress ];
        networkConfig.LinkLocalAddressing = "no";
        linkConfig.RequiredForOnline = "routable";
      };

      archibald.netjack = mkIf cfg.netjack {
        role = "manager";
        address = cfg.address;
        port = cfg.netjackPort;
      };

      # The control bridge and ssh: the host only (socat's range= and
      # IPAddressAllow repeat this for the bridge). NetJack2: the manager port,
      # then each follower's own UDP pair on ephemeral ports. The remote bridge
      # is in that range; it gates every datagram itself.
      networking.firewall.allowedUDPPorts = [ cfg.netjackPort cfg.remotePort ];
      networking.firewall.allowedUDPPortRanges = mkIf cfg.netjack [{ from = 1024; to = 65535; }];
      networking.firewall.extraCommands = ''
        iptables -A nixos-fw -p tcp -s ${cfg.hostAddress} --dport 22 -j nixos-fw-accept
        iptables -A nixos-fw -p tcp -s ${cfg.hostAddress} --dport ${toString config.archibald.dsp.control.port} -j nixos-fw-accept
      '';
    })

    (mkIf (!routed) {
      # QEMU user-mode networking: DHCP from QEMU, reached only through the
      # host's loopback forwards.
      networking.useDHCP = true;
      networking.firewall.allowedTCPPorts = [ 22 config.archibald.dsp.control.port ];
    })
  ];
}
