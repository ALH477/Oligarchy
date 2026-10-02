{ config, pkgs, lib, ... }:

# ============================================================================
# DSP VM Module - ArchibaldOS DSP Coprocessor, NetJack2 hub
# ============================================================================
#
# An isolated KVM guest for real-time DSP: isolated cores, hugepages, VFIO
# passthrough of a USB controller for the audio interface, OVMF.
#
# The guest is a NetJack2 DSP host. It runs JACK (on the passed-through
# interface, or the dummy driver), jack2's netmanager, and the DeMoD engine.
# This host and any ArchibaldOS box join it as NetJack2 followers and their
# audio runs through the engine. That needs the guest on a real subnet:
# network.mode = "routed" puts it behind a tap (10.78.0.2 by default), and
# routed.forwardFrom lets the peers of a named interface (custom.companions'
# WireGuard hub) reach it through this host, UDP and ICMP only.
#
# Guest image: Oligarchy builds it from modules/dsp-guest.nix and THIS
# module's values (flake.nix, mkDspImage), so addresses, rate, period and
# ports here are the ones the guest uses.
#
# This host's audio: `systemctl --user start dsp-netjack` (or `dsp-arm on`)
# joins with PipeWire's netjack2 driver; the guest appears in PipeWire as
# `dsp-vm.sink` / `dsp-vm.source`.
#
# Terminus Dev audio routing: terminus-dsp-connect start|stop|status
#   (provided by modules/terminus-dev.nix)
#
# Prerequisite for passthrough: IOMMU on in firmware (AMD-Vi / Intel VT-d).
#
# Organization: https://github.com/ALH477
# ============================================================================

{
  imports = [
    (lib.mkRemovedOptionModule [ "custom" "vm" "dsp" "archibaldOS" "netjack" "sourcePort" ] ''
      It was the port of `jack_netsource`, a NetJack1 tool run on both ends,
      which could not form a link. The guest now runs a NetJack2 manager on
      custom.vm.dsp.archibaldOS.netjack.port (19000).
    '')
  ];

  options.custom.vm.dsp = {
    enable = lib.mkEnableOption "ArchibaldOS DSP coprocessor VM";

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Start the DSP VM (and its NETJACK/JACK bridges) automatically at boot.
        When false, the systemd units are still defined and can be launched
        manually (systemctl start archibaldos-dsp), but nothing pulls them in
        at boot — so a broken guest can't soft-lock the host on startup.
        Hugepages are allocated dynamically on service start and released on
        stop, so no RAM is reserved when the VM is idle.
      '';
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "archibaldos-dsp";
      description = "Name of the DSP VM.";
    };

    isolatedCores = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ 0 1 ];
      description = "CPU cores to isolate for the DSP VM (e.g., [0,1] for cores 0-1).";
    };

    memoryMB = lib.mkOption {
      type = lib.types.int;
      default = 2048;
      description = "Memory allocation for the VM in MB.";
    };

    hugepages = lib.mkOption {
      type = lib.types.int;
      default = 1024;
      description = ''
        Number of 2MB hugepages to allocate when the VM starts.
        Allocated dynamically via sysctl on service preStart and released on
        postStop — not reserved at boot. Set to 0 to disable hugepage backing.
      '';
    };

    cpuModel = lib.mkOption {
      type = lib.types.enum [ "host" "max" "EPYC" "Skylake-Server" ];
      default = "host";
      description = "CPU model for QEMU.";
    };

    archibaldOS = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use ArchibaldOS as guest OS (recommended).";
      };

      diskImage = lib.mkOption {
        # `path`, not `str`, so a derivation can be assigned directly and the
        # image becomes part of the system closure — built, GC-rooted and
        # rebuildable. The old `str` default below was a hand-copied artifact
        # that nothing in this repo produced; when it stopped booting (no EFI
        # system partition, so OVMF fell through to PXE) there was nothing to
        # rebuild it from. `nix build .#dsp-vm-qcow` is that something.
        type = lib.types.either lib.types.path lib.types.str;
        default = "/home/asher/vms/archibaldos-dsp.qcow2";
        description = ''
          ArchibaldOS disk image. Assign the `dsp-vm-qcow` derivation to get a
          reproducible guest; a bare path is still accepted for a hand-managed
          image. A read-only store path is booted through a writable qcow2
          overlay (see `overlay`), so the guest can write.
        '';
      };

      overlay = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Boot `diskImage` through a writable qcow2 overlay under
          /var/lib/qemu rather than writing to it in place.

          Required whenever `diskImage` is a store path: the store is
          read-only, and QEMU fails to open the drive for writing. Kept on by
          default for a plain path too — the guest's writes then stay
          discardable, which is what you want for a coprocessor whose state is
          not meant to be precious. Delete the overlay to reset the guest.
        '';
      };

      # NetJack2. The guest's JACK runs jack2's netmanager (ArchibaldOS
      # modules/netjack.nix, role "manager"); this host and any box join it
      # as followers and appear there as clients named after themselves.
      # The guest image is built from these values (flake.nix, mkDspImage),
      # so they reach the guest rather than describing it.
      netjack = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            NetJack2 between the guest and this host. The guest runs the
            manager on `port`; this host joins with PipeWire's netjack2
            driver (`systemctl --user start dsp-netjack`), which shows up
            here as the sink/source `dsp-vm.sink` and `dsp-vm.source`.
            Requires network.mode = "routed".
          '';
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 19000;
          description = "The guest's NetJack2 manager port (UDP).";
        };

        clientName = lib.mkOption {
          type = lib.types.str;
          default = config.networking.hostName;
          defaultText = lib.literalExpression "config.networking.hostName";
          description = "The client name this host appears under in the guest's JACK graph.";
        };

        bufferSize = lib.mkOption {
          type = lib.types.int;
          default = 32;
          description = "The guest JACK period in frames (32 @ 96kHz = 0.33ms). Every NetJack2 follower runs at this period.";
        };

        sampleRate = lib.mkOption {
          type = lib.types.int;
          default = 96000;
          description = "The guest JACK sample rate. Boxes resample to it (netadapter); this host's PipeWire follows it.";
        };

        channels = lib.mkOption {
          type = lib.types.int;
          default = 2;
          description = "Channels each way between this host and the guest.";
        };
      };
    };

    audioDevice = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable VFIO passthrough of an entire USB host controller to the VM.
          The VM gets direct hardware access to whatever audio interface is
          plugged into that controller — zero-copy, zero-latency, no hypervisor
          translation in the audio path.
          NETJACK is still used to route the processed audio back to the host.
        '';
      };

      # Single PCI address (legacy — one device)
      pciId = lib.mkOption {
        type = lib.types.str;
        default = "0000:00:1b.0";
        description = "PCI address of audio device (from lspci -nn).";
      };

      vendorDevice = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Vendor:Device ID for VFIO binding (e.g., '1022:15e3').";
      };

      # Full USB controller passthrough — the real deal
      usbController = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Pass through an entire USB XHCI host controller to the VM.";
        };

        # XHCI USB2 controller (e.g., 0000:c7:00.3)
        xhciUsb2PciId = lib.mkOption {
          type = lib.types.str;
          default = "0000:c7:00.3";
          description = "PCI address of the XHCI USB2 controller to pass through.";
        };

        # XHCI USB3 companion (e.g., 0000:c7:00.4)
        xhciUsb3PciId = lib.mkOption {
          type = lib.types.str;
          default = "0000:c7:00.4";
          description = "PCI address of the XHCI USB3 companion controller to pass through.";
        };

        # Vendor:Device IDs for both controllers (for VFIO binding)
        usb2VendorDevice = lib.mkOption {
          type = lib.types.str;
          default = "1022:15C0";
          description = "Vendor:Device ID for USB2 controller (from lspci -nn).";
        };

        usb3VendorDevice = lib.mkOption {
          type = lib.types.str;
          default = "1022:15C1";
          description = "Vendor:Device ID for USB3 companion (from lspci -nn).";
        };
      };
    };

    network = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable network for the VM.";
      };

      mode = lib.mkOption {
        type = lib.types.enum [ "routed" "user" ];
        default = "routed";
        description = ''
          routed: a tap device (`routed.interface`) with an address on each
          side, so the guest is a real host on a small subnet. NetJack2 needs
          this: each joined box gets its own UDP pair on ephemeral ports, which
          no fixed port forward can carry.

          user: QEMU user-mode networking with loopback `hostfwd`s. The guest
          is reachable only through the forwards, so NetJack2 cannot run.
        '';
      };

      hostfwd = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = { };
        description = "mode = user only: port forwards { hostPort = guestPort; }, bound to 127.0.0.1 on the host.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "mode = user only: open the forwarded ports in the host firewall for LAN access.";
      };

      routed = {
        interface = lib.mkOption {
          type = lib.types.str;
          default = "dsp0";
          description = "The tap device on the host.";
        };
        hostAddress = lib.mkOption {
          type = lib.types.str;
          default = "10.78.0.1";
          description = "The host's address on the tap. The guest's gateway, and the only address its control bridge and ssh admit.";
        };
        guestAddress = lib.mkOption {
          type = lib.types.str;
          default = "10.78.0.2";
          description = "The guest's address: where NetJack2 boxes, the host's PipeWire and dsp-ctl reach it.";
        };
        prefixLength = lib.mkOption {
          type = lib.types.ints.between 8 30;
          default = 24;
          description = "Prefix length of the tap subnet.";
        };
        guestMac = lib.mkOption {
          type = lib.types.str;
          default = "52:54:00:78:00:02";
          description = "The guest NIC's MAC; the guest configures the NIC that has it.";
        };
        forwardFrom = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "wg-companions" ];
          description = ''
            Interfaces whose peers may reach the guest through this host:
            UDP and ICMP to `guestAddress`, nothing else, and nothing from
            them to anywhere else. Forwarding is turned on for these
            interfaces and the tap only (`net.ipv4.conf.<if>.forwarding`),
            never globally. custom.companions adds its tunnel here.
          '';
        };
      };
    };

    qemuExtraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra QEMU arguments.";
    };

    realtime = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable real-time scheduling and locking.";
      };

      mlock = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Lock memory (mlockall).";
      };

      nice = lib.mkOption {
        type = lib.types.int;
        default = -20;
        description = "Nice value (lower = higher priority).";
      };
    };

    spice = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SPICE display for the VM.";
    };

    vnc = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable VNC display for the VM.";
    };

    tpm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable TPM 2.0 emulation.";
    };

    ovmf = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable UEFI (OVMF).";
    };
  };

  config =
    let
      cfg = config.custom.vm.dsp;

      # Stock QEMU, deliberately: do NOT `override`/`overrideAttrs` this, and
      # do NOT narrow it to a host-only build.
      #
      # This used to be `pkgs.qemu.override { gtkSupport = false; sdlSupport =
      # false; spiceSupport = false; }`. Any non-stock flag set yields a
      # derivation cache.nixos.org has never built, so every `nixos-rebuild
      # switch` following a flake.lock bump compiled QEMU from source — about
      # an hour, on a machine that had asked for nothing but a config change.
      # Stock `pkgs.qemu` substitutes, and is already in this system's closure
      # via `environment.systemPackages`, so this binding drags in no second,
      # distinct QEMU either.
      #
      # `pkgs.qemu_kvm` is the same trap one step quieter: it is
      # `qemu.override { hostCpuOnly = true; }` (`--target-list=i386,x86_64`),
      # and this binding is ALSO `virtualisation.libvirtd.qemu.package` below,
      # so it silently empties /run/libvirt/nix-emulators/ of every non-x86
      # emulator (~30 of them, `qemu-system-aarch64` and `-riscv64` included)
      # on a host that sets `boot.binfmt.emulatedSystems` for aarch64+riscv64
      # and drives riscv64 guests from virt-manager.
      #
      # Headless is a RUNTIME property here, not a build one: `displayOpts`
      # below emits `-display none` whenever neither `spice` nor `vnc` is set,
      # so GTK never initialises regardless of whether it was linked in —
      # verified, a GTK-linked QEMU with `-display none` runs fine under
      # `env -i` with DISPLAY unset or `:99`, attempting no X11 connection at
      # all. `-display none` was already in the file when the override was
      # added, but a trailing newline terminating the exec line meant it never
      # reached QEMU; once that was fixed the override was dead weight.
      #
      # Dropping the override does NOT make `cfg.spice` work. The override
      # made spice impossible at BUILD time (it emits `-display gtk,gl=on`,
      # which a gtk-less binary cannot honour); it remains non-functional at
      # RUNTIME for want of a display server — this is a root systemd service
      # whose `DISPLAY = ":99"` below is a dead Xvfb leftover, so `-display
      # gtk` fails "gtk initialization failed" and `gl=on` fails "OpenGL is
      # not supported by display backend gtk". Separate issue, not fixed here.
      qemu = pkgs.qemu;

      # The guest's serial console, as an INTERACTIVE socket plus a log.
      #
      # It used to be `-chardev file`, which is write-only: `dsp-console` ran
      # socat against a path QEMU never created, printed "VM not running or
      # console unavailable", and looked exactly like a VM that had failed to
      # start. There was no way to type at the guest at all — on a headless,
      # display-less VM that is the only way in before sshd is up.
      #
      # `logfile=` keeps the transcript the file chardev used to give, so
      # boot output is still readable after the fact without attaching.
      consoleSocket = "/run/${cfg.name}-console.sock";
      consoleLog = "/var/log/qemu-${cfg.name}-serial.log";

      # Where the guest actually writes. See `overlay`.
      overlayDisk = "/var/lib/qemu/${cfg.name}-overlay.qcow2";

      # `dsp-vm-qcow` builds via nixos-generators' `qcow-efi` format, whose
      # output is a DIRECTORY (nixos.qcow2 + nix-support/), not a bare qcow2
      # file. `-drive file=` and `qemu-img -b` both require a regular file,
      # so resolve to the qcow2 inside before either sees the path. A plain
      # hand-managed path (the option's `str` branch) is untouched, since
      # pathExists on a non-directory file path is simply false.
      #
      # A derivation is resolved by its known layout, NOT by pathExists:
      # pathExists on a derivation's output is import-from-derivation, which
      # built the whole disk image (a KVM job, minutes) just to EVALUATE any
      # host with the VM enabled. Now the image is an ordinary build input.
      resolveDisk = img:
        let s = toString img;
        in
        if lib.isDerivation img then "${img}/nixos.qcow2"
        else if builtins.pathExists (s + "/nixos.qcow2") then s + "/nixos.qcow2"
        else s;

      runtimeDisk = if cfg.archibaldOS.overlay then overlayDisk else resolveDisk cfg.archibaldOS.diskImage;

      # ── Routed network ────────────────────────────────────────────────────
      net = cfg.network;
      r = net.routed;
      routed = net.enable && net.mode == "routed";
      nj = cfg.archibaldOS.netjack;

      # Forwarding through this host, scoped to the guest. Its own inet table,
      # loaded by its own oneshot (the pattern strict-egress.nix and
      # dcf-spa-gate.nix use), so it coexists with the iptables firewall and
      # touches nothing that does not cross the tap. `policy accept` because
      # a forward hook sees every forwarded packet on the machine; the drops
      # below match only traffic to or from the tap and the `forwardFrom`
      # interfaces. Peers on those interfaces get UDP and ICMP to the guest
      # (NetJack2, the DeMoD remote bridge, path-MTU messages) and nothing
      # else; the guest gets the same back to them and nothing else. The
      # control bridge (TCP) and ssh stay host-only: the guest admits only
      # `hostAddress` on those.
      routeTable = "oligarchy-dsp-route";
      ifset = l: "{ " + lib.concatMapStringsSep ", " (i: ''"${i}"'') l + " }";
      routeRules = pkgs.writeText "${routeTable}.nft" (lib.concatStringsSep "\n" ([
        "table inet ${routeTable}"
        "delete table inet ${routeTable}"
        "table inet ${routeTable} {"
        "  chain forward {"
        "    type filter hook forward priority filter; policy accept;"
      ] ++ map (rule: "    " + rule) (lib.optionals (r.forwardFrom != [ ]) [
        ''iifname ${ifset r.forwardFrom} oifname "${r.interface}" ip daddr ${r.guestAddress} meta l4proto { udp, icmp } accept''
        ''iifname "${r.interface}" oifname ${ifset r.forwardFrom} ip saddr ${r.guestAddress} meta l4proto { udp, icmp } accept''
        ''iifname ${ifset r.forwardFrom} counter drop''
      ] ++ [
        ''iifname "${r.interface}" counter drop''
        ''oifname "${r.interface}" counter drop''
      ]) ++ [ "  }" "}" "" ]));

      # This host joins the guest's NetJack2 manager with PipeWire's own
      # netjack2 driver, as a separate PipeWire process (the way filter-chain
      # runs standalone) that connects to the user's PipeWire daemon. Its
      # sink and source carry this host's audio into the guest's engine and
      # the engine's output back. The driver creates its ports when the
      # session manager configures the nodes (WirePlumber's PortConfig).
      # Measured in the build sandbox against jack2's netmanager:
      # `.#dsp-netjack-tests`.
      netjackConf = pkgs.writeText "dsp-netjack.conf" ''
        context.properties = {
          support.dbus = false
        }
        context.spa-libs = {
          audio.convert.* = audioconvert/libspa-audioconvert
          support.*       = support/libspa-support
        }
        context.modules = [
          { name = libpipewire-module-rt flags = [ ifexists nofail ] }
          { name = libpipewire-module-protocol-native }
          { name = libpipewire-module-client-node }
          { name = libpipewire-module-adapter }
          { name = libpipewire-module-netjack2-driver
            args = {
              net.ip               = "${r.guestAddress}"
              net.port             = ${toString nj.port}
              netjack2.client-name = "${nj.clientName}"
              audio.channels       = ${toString nj.channels}
              sink.props = {
                node.name        = "dsp-vm.sink"
                node.description = "DSP VM (to the engine)"
              }
              source.props = {
                node.name        = "dsp-vm.source"
                node.description = "DSP VM (from the engine)"
              }
            }
          }
        ]
      '';
    in
    lib.mkIf cfg.enable (lib.mkMerge [{
      assertions = [
        {
          assertion = nj.enable -> routed;
          message = ''
            custom.vm.dsp.archibaldOS.netjack needs custom.vm.dsp.network.mode = "routed".
            NetJack2 gives each follower its own UDP pair on ephemeral ports,
            which QEMU user-mode forwards cannot carry.
          '';
        }
        {
          assertion = routed -> (net.hostfwd == { } && !net.openFirewall);
          message = "custom.vm.dsp.network.hostfwd/openFirewall apply to mode = \"user\" only; in routed mode reach the guest at ${r.guestAddress}.";
        }
      ];

      boot.kernelParams = lib.mkAfter (
        let
          isolatedCoresStr = lib.concatStringsSep "," (map toString cfg.isolatedCores);
        in
        [
          "isolcpus=${isolatedCoresStr}"
          "nohz_full=${isolatedCoresStr}"
          "rcu_nocbs=${isolatedCoresStr}"
          "irqaffinity=1-7"
          "threadirqs"
          "hugepagesz=2M"
          "hugepages=0"
          "amd_iommu=on"
          "iommu=pt"
        ]
      );

      boot.kernelModules = [
        "vfio-pci"
        "vfio_iommu_type1"
        "vfio"
      ];

      boot.extraModprobeConfig =
        # Full USB controller passthrough: bind both XHCI controllers to vfio-pci
        lib.optionalString (cfg.audioDevice.enable && cfg.audioDevice.usbController.enable) ''
          options vfio-pci ids=${cfg.audioDevice.usbController.usb2VendorDevice},${cfg.audioDevice.usbController.usb3VendorDevice}
          softdep xhci_hcd pre: vfio-pci
        ''
        # Single device passthrough (legacy)
        + lib.optionalString (cfg.audioDevice.enable && !cfg.audioDevice.usbController.enable && cfg.audioDevice.vendorDevice != "") ''
          options vfio-pci ids=${cfg.audioDevice.vendorDevice}
          softdep snd_hda_intel pre: vfio-pci
        '';

      # Display init failures on a headless host are avoided by `-display none`
      # at runtime (see `displayOpts`), not by a stripped-down QEMU build.
      virtualisation.libvirtd = {
        enable = true;
        qemu = {
          package = qemu;
          # Kept true: this VM is launched by the direct systemd QEMU service
          # below (not a libvirt-managed domain), which needs root for VFIO PCI
          # passthrough + sysfs bind. runAsRoot here only governs libvirt domains
          # (none defined), so flipping it buys no security but risks the guest.
          runAsRoot = true;
          swtpm.enable = cfg.tpm;
        };
      };

      systemd.services.${cfg.name} = {
        description = "ArchibaldOS DSP Coprocessor VM";
        wantedBy = lib.optionals cfg.autoStart [ "multi-user.target" ];
        after = [ "network.target" "libvirtd.service" ];
        requires = [ "libvirtd.service" ];

        environment = {
          DISPLAY = ":99";
        };

        preStart = ''
          mkdir -p /var/log
          touch ${consoleLog}
          chmod 666 ${consoleLog}
        '' + lib.optionalString cfg.archibaldOS.overlay ''
          # Writable overlay backed by the (possibly read-only) base image.
          #
          # `-F qcow2` is not optional: without an explicit backing format
          # qemu-img refuses to create the overlay on any recent QEMU rather
          # than probing, and the unit dies in preStart with a message that
          # says nothing about backing files.
          #
          # Recreated whenever the base image changes — a `nixos-rebuild` that
          # updates the guest would otherwise leave the overlay pointing at a
          # garbage-collected backing file, and QEMU's error for that names
          # only the missing store path.
          #
          # `dsp-vm-qcow` builds via nixos-generators' `qcow-efi` format,
          # whose output is a DIRECTORY (nixos.qcow2 + nix-support/), not a
          # bare qcow2 file — `qemu-img -b` requires a regular file, so
          # resolve to the file inside it here too (mirrors `resolveDisk`
          # above; done again at runtime, not just at eval time, so a
          # hand-copied directory-shaped image still gets caught here).
          mkdir -p /var/lib/qemu
          # resolveDisk at eval time covers the flake-wired dsp-vm-qcow
          # directory. The shell check is for a hand-assigned directory that
          # was not a store path at eval (option's `str` branch).
          base=${lib.escapeShellArg (resolveDisk cfg.archibaldOS.diskImage)}
          if [ -d "$base" ]; then
            if [ -f "$base/nixos.qcow2" ]; then
              base="$base/nixos.qcow2"
            else
              found=$(${pkgs.findutils}/bin/find "$base" -maxdepth 1 -name '*.qcow2' -print -quit)
              if [ -z "$found" ]; then
                echo "${cfg.name}: $base is a directory with no nixos.qcow2 or *.qcow2 inside it" >&2
                exit 1
              fi
              base="$found"
            fi
          fi
          stamp=/var/lib/qemu/${cfg.name}-overlay.base
          if [ ! -f ${overlayDisk} ] || [ "$(cat "$stamp" 2>/dev/null)" != "$base" ]; then
            rm -f ${overlayDisk}
            ${qemu}/bin/qemu-img create -q -f qcow2 -F qcow2 -b "$base" ${overlayDisk}
            printf '%s' "$base" > "$stamp"
          fi
        '' + lib.optionalString (cfg.hugepages > 0) ''
          # Allocate hugepages dynamically (released in postStop)
          echo ${toString cfg.hugepages} > /proc/sys/vm/nr_hugepages
        '' + lib.optionalString cfg.ovmf ''
          # Seed a per-VM writable OVMF variable store from the read-only
          # template on first boot (holds UEFI boot entries / NVRAM).
          mkdir -p /var/lib/qemu
          if [ ! -f /var/lib/qemu/${cfg.name}_VARS.fd ]; then
            ${pkgs.coreutils}/bin/install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd /var/lib/qemu/${cfg.name}_VARS.fd
          fi
        '' + lib.optionalString (cfg.audioDevice.enable && cfg.audioDevice.usbController.enable) ''
          # Ensure vfio-pci module is loaded
          ${pkgs.kmod}/bin/modprobe vfio-pci
        
          # Unbind VFIO devices from xhci_hcd and bind to vfio-pci
          for dev in ${cfg.audioDevice.usbController.xhciUsb2PciId} ${cfg.audioDevice.usbController.xhciUsb3PciId}; do
            if [ -e "/sys/bus/pci/devices/$dev/driver" ]; then
              echo "$dev" > /sys/bus/pci/devices/$dev/driver/unbind || true
            fi
            echo "$dev" > /sys/bus/pci/drivers/vfio-pci/bind || true
          done
        '';

        serviceConfig = {
          Type = "simple";
          Restart = "always";
          RestartSec = 5;

          Nice = cfg.realtime.nice;
          IOSchedulingClass = "realtime";
          IOSchedulingPriority = 0;
          CPUSchedulingPolicy = "fifo";
          CPUSchedulingPriority = 99;

          CPUAffinity = map toString cfg.isolatedCores;

          ExecStart =
            let
              coresCount = lib.length cfg.isolatedCores;
              coresStr = lib.concatStringsSep "," (map toString cfg.isolatedCores);

              # UEFI firmware (OVMF). Without this the guest boots under SeaBIOS;
              # a UEFI-only ArchibaldOS image then never boots and spins the
              # isolated cores at 100%. unit=0 is the read-only firmware code,
              # unit=1 the per-VM writable variable store (seeded in preStart).
              ovmfOpts = lib.optionalString cfg.ovmf (lib.replaceStrings [ "\n" ] [ " " ] ''
                -drive if=pflash,format=raw,unit=0,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd
                -drive if=pflash,format=raw,unit=1,file=/var/lib/qemu/${cfg.name}_VARS.fd
              '');

              memoryOpts = lib.optionalString cfg.realtime.enable (lib.replaceStrings [ "\n" ] [ " " ] ''
                -mem-prealloc -mem-path /dev/hugepages -overcommit mem-lock=on
              '');

              # Disk: cache=unsafe + native AIO for lowest I/O latency
              diskOpts = lib.replaceStrings [ "\n" ] [ " " ] ''
                -drive file=${runtimeDisk},format=qcow2,if=virtio,cache=unsafe,aio=native,cache.direct=on
              '';

              # Disable all unnecessary emulated devices — no USB, no floppy,
              # no parallel. The single serial port is defined in displayOpts
              # (a bare `-device isa-serial` here collided with it on ISA port
              # 0x3f8 and broke serial output entirely).
              minimalDeviceOpts = lib.replaceStrings [ "\n" ] [ " " ] ''
                -nodefaults -no-fd-bootchk -boot c
              '';

              # VFIO passthrough: either a single PCI device or a full USB
              # host controller pair (USB2 + USB3 companion). The VM gets
              # direct hardware access — zero-copy, zero-latency audio.
              vfioOpts = lib.replaceStrings [ "\n" ] [ " " ] (
                # Full USB controller passthrough (primary mode)
                lib.optionalString (cfg.audioDevice.enable && cfg.audioDevice.usbController.enable) ''
                  -device vfio-pci,host=${cfg.audioDevice.usbController.xhciUsb2PciId},multifunction=on,romfile=
                  -device vfio-pci,host=${cfg.audioDevice.usbController.xhciUsb3PciId},multifunction=on,romfile=
                ''
                # Single PCI device passthrough (legacy mode)
                + lib.optionalString (cfg.audioDevice.enable && !cfg.audioDevice.usbController.enable) ''
                  -device vfio-pci,host=${cfg.audioDevice.pciId}
                ''
              );

              # Network. routed: the persistent tap (networking.interfaces
              # below) with vhost-net, and a fixed MAC the guest matches on.
              # No mq=on: multi-queue needs a multi-queue tap (`queues=` on
              # the netdev), and this one is created single-queue.
              # user: QEMU user-mode networking; forwards bind 127.0.0.1, so
              # the guest's ports are never exposed on LAN interfaces.
              netOpts =
                let
                  userFwds = lib.mapAttrsToList (k: v: "hostfwd=tcp:127.0.0.1:${toString k}-:${toString v}") net.hostfwd;
                in
                lib.optionalString net.enable (lib.replaceStrings [ "\n" ] [ " " ] (
                  if net.mode == "routed" then ''
                    -netdev tap,id=net0,ifname=${r.interface},script=no,downscript=no,vhost=on
                    -device virtio-net-pci,netdev=net0,mac=${r.guestMac}
                  '' else ''
                    -netdev user,id=net0${lib.concatMapStrings (f: "," + f) userFwds}
                    -device virtio-net-pci,netdev=net0,mq=on,vectors=4
                  ''
                ));

              displayOpts =
                lib.optionalString cfg.spice " -vga virtio -display gtk,gl=on"
                + lib.optionalString cfg.vnc " -vnc :0"
                + lib.optionalString (!cfg.spice && !cfg.vnc) (lib.replaceStrings [ "\n" ] [ " " ] ''
                  -display none
                  -chardev socket,id=serial0,path=${consoleSocket},server=on,wait=off,logfile=${consoleLog}
                  -device isa-serial,chardev=serial0
                '');

              # QEMU monitor socket for debugging
              monitorOpts = " -monitor unix:/run/qemu-${cfg.name}.sock,server,nowait";

              tpmOpts = lib.optionalString cfg.tpm (lib.replaceStrings [ "\n" ] [ " " ] ''
                -tpmdev emulator,id=tpm0,tpm-type=tpm2-emulator
                -device tpm-tis,tpmdev=tpm0
              '');

            in
            pkgs.writeShellScript "start-${cfg.name}" (lib.concatStringsSep " \\\n  " (lib.filter (s: s != "") [
              "${qemu}/bin/qemu-system-x86_64"
              "-enable-kvm"
              "-name ${cfg.name},process=${cfg.name}"
              "-m ${toString cfg.memoryMB}"
              "-smp ${toString coresCount},sockets=1,cores=${toString coresCount},threads=1"
              "-cpu ${cfg.cpuModel},+topoext"
              "-machine q35,accel=kvm,kernel_irqchip=split"
              "-no-reboot"
              ovmfOpts
              memoryOpts
              minimalDeviceOpts
              diskOpts
              vfioOpts
              netOpts
              displayOpts
              monitorOpts
              tpmOpts
              (lib.concatStringsSep " " cfg.qemuExtraArgs)
            ]));

          ExecStop = "${pkgs.coreutils}/bin/kill -TERM $MAINPID";
          ExecStopPost = lib.optionalString (cfg.hugepages > 0) "+${pkgs.coreutils}/bin/echo 0 > /proc/sys/vm/nr_hugepages";
        };

        startLimitIntervalSec = 300;
        startLimitBurst = 5;
      };

      # This host's side of NetJack2 (see netjackConf). A user unit, started
      # on demand like the VM itself (`dsp-arm on`, terminus-dsp-connect),
      # because it joins the user's PipeWire. It replaces dsp-netjack-bridge
      # and dsp-jack-bridge, which ran jack_netsource (NetJack1, and a master)
      # against a guest that ran no JACK at all, through a loopback forward
      # that could not carry NetJack2's ephemeral ports. Neither could have
      # formed a link.
      systemd.user.services.dsp-netjack = lib.mkIf (nj.enable && routed) {
        description = "This host's audio to the DSP VM's NetJack2 manager at ${r.guestAddress}:${toString nj.port}";
        after = [ "pipewire.service" ];
        bindsTo = [ "pipewire.service" ];
        serviceConfig = {
          ExecStart = "${config.services.pipewire.package}/bin/pipewire -c ${netjackConf}";
          Restart = "on-failure";
          RestartSec = 5;
        };
      };

      # user mode only: hostfwd binds 127.0.0.1, so nothing needs opening for
      # local use; openFirewall is the explicit opt-in for LAN exposure.
      networking.firewall.allowedTCPPorts = lib.mkIf (net.enable && net.mode == "user" && net.openFirewall)
        (lib.attrValues net.hostfwd);

      environment.systemPackages = [
        (pkgs.writeShellScriptBin "dsp-status" ''
          echo "=== DSP VM Status ==="
          systemctl status ${cfg.name}.service --no-pager || true
          echo ""
          echo "=== CPU Isolation ==="
          cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "None"
          echo ""
          echo "=== Hugepages ==="
          cat /proc/meminfo | grep -i huge
          echo ""
          echo "=== NetJack2 (this host -> ${r.guestAddress}:${toString nj.port}) ==="
          systemctl --user status dsp-netjack.service --no-pager || true
        '')

        # Interactive guest console.
        #
        # The path here has to match the `-chardev socket` above. It used to be
        # /run/${cfg.name}.sock, which QEMU never creates — the monitor is at
        # /run/qemu-${cfg.name}.sock and the console was a write-only file — so
        # this reported "VM not running or console unavailable" on a perfectly
        # healthy VM and there was no way to tell the two apart. Say which.
        (pkgs.writeShellScriptBin "dsp-console" ''
          sock=${consoleSocket}
          if [ ! -S "$sock" ]; then
            echo "No console socket at $sock." >&2
            if ${pkgs.systemd}/bin/systemctl is-active --quiet ${cfg.name}.service; then
              echo "${cfg.name}.service IS running — the console chardev did not come up." >&2
              echo "Check: journalctl -u ${cfg.name} -n 50" >&2
            else
              echo "${cfg.name}.service is not running. Start it with:" >&2
              echo "  sudo systemctl start ${cfg.name}" >&2
            fi
            exit 1
          fi
          echo "Connecting to DSP VM console (Ctrl-] to exit)..." >&2
          exec ${pkgs.socat}/bin/socat -,raw,echo=0,escape=0x1d UNIX-CONNECT:"$sock"
        '')

        # The boot transcript, for when the guest died before you could attach.
        (pkgs.writeShellScriptBin "dsp-console-log" ''
          exec ${pkgs.coreutils}/bin/tail "''${@:--n +1}" ${consoleLog}
        '')

        (pkgs.writeShellScriptBin "dsp-netjack-restart" ''
          echo "Restarting NetJack2 to the DSP VM..."
          exec systemctl --user restart dsp-netjack.service
        '')
      ];

      users.users.asher.extraGroups = [ "libvirtd" "kvm" "audio" ];
    }

      (lib.mkIf routed {
        # The tap, persistent, with the host's address. QEMU (root) attaches to
        # it by name; while the VM is down it simply has no carrier.
        networking.interfaces.${r.interface} = {
          virtual = true;
          virtualType = "tap";
          ipv4.addresses = [{ address = r.hostAddress; prefixLength = r.prefixLength; }];
        };
        networking.networkmanager.unmanaged = [ "interface-name:${r.interface}" ];
        boot.kernelModules = [ "vhost_net" ];

        systemd.services.${cfg.name} = {
          requires = [ "${r.interface}-netdev.service" "dsp-vm-route.service" ];
          after = [ "${r.interface}-netdev.service" "network-addresses-${r.interface}.service" "dsp-vm-route.service" ];
        };

        # Per interface, never `net.ipv4.ip_forward`: packets arriving on any
        # other interface (Wi-Fi, the LAN) are still never forwarded. These are
        # applied when each interface appears, by systemd's own udev rule
        # (99-systemd.rules runs systemd-sysctl --prefix=/net/ipv4/conf/$name),
        # so a tunnel that is recreated gets them again.
        boot.kernel.sysctl = lib.listToAttrs (map
          (i: lib.nameValuePair "net.ipv4.conf.${i}.forwarding" 1)
          ([ r.interface ] ++ r.forwardFrom));

        # Ordered before network-pre.target, so the filter is in place before
        # any of these interfaces exists. The VM requires it.
        systemd.services.dsp-vm-route = {
          description = "DSP VM - scope forwarding to the guest (nft table ${routeTable})";
          wantedBy = [ "multi-user.target" ];
          wants = [ "network-pre.target" ];
          before = [ "network-pre.target" ];
          after = [ "firewall.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStartPre = "${pkgs.nftables}/bin/nft -c -f ${routeRules}";
            ExecStart = "${pkgs.nftables}/bin/nft -f ${routeRules}";
            ExecStop = "${pkgs.nftables}/bin/nft delete table inet ${routeTable}";
          };
        };

        # NetJack2: the manager answers this host's PipeWire from ephemeral
        # ports, so the tap admits UDP. The guest is the only thing on it.
        networking.firewall.interfaces.${r.interface}.allowedUDPPortRanges =
          lib.mkIf nj.enable [{ from = 1024; to = 65535; }];
      })]);
}
