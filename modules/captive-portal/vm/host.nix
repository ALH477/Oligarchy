# ═══════════════════════════════════════════════════════════════════════════════
# Portal login in a disposable, verified microVM — host side (Design F).
# ═══════════════════════════════════════════════════════════════════════════════
# Active when custom.network.captivePortal.browser.kind = "microvm". Builds the
# guest (vm/guest.nix) with microvm.nix's guest module, the manifest over it
# (vm/manifest.nix), and a launcher with the manifest's sha256 baked in at
# build time. Installs:
#
#   captive-vm.service          root orchestrator for one run (bin/captive-vm-run.sh)
#   captive-vm-viewer.service   cage + wlvncc on tty${vt}, as captive-view,
#                               showing the VM's CPU framebuffer — its own VT,
#                               its own logind session, nothing to do with the
#                               desktop compositor (no Wayland bridge of any kind)
#   captive-vm-sign.service     signs the manifest when a host key is configured
#   a polkit rule               the listed users may start/stop captive-vm only
#
# Display: a GPU given to VMs (bound to vfio-pci, whole IOMMU group) drives its
# own monitor from inside the guest; otherwise a CPU framebuffer (virtio-gpu
# 2D, pixman in the guest) is shown on the VT. Crummy, deliberately: nothing of
# a host GPU is exposed to the guest on that path.
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.network.captivePortal;
  vm = cfg.microvm;
  enabled = cfg.enable && cfg.browser.kind == "microvm";
  gpuOn = vm.gpu.functions != [ ];
  vt = toString vm.vt;
  runDir = "/run/captive-vm";

  locale = config.custom.locale.keyboard or { };
  keyboardLayout = locale.layout or "us";
  keyboardVariant = locale.variant or "";

  guest = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = null;
    modules = [
      vm.guestModule
      (import ./guest.nix {
        inherit (cfg) loginUrl;
        inherit keyboardLayout keyboardVariant;
        inherit (vm) memMiB guestMac;
        gpuFirmware = if gpuOn then vm.gpu.firmware else null;
        gpuKernelModules = vm.gpu.kernelModules;
      })
      { nixpkgs.pkgs = pkgs; }
    ] ++ vm.extraGuestModules;
  };

  manifest = import ./manifest.nix {
    inherit pkgs lib guest;
    policyFile = ./policy.nft;
    limits = { inherit (vm) memMiB timeoutSec probeIntervalSec gpuGraceSec; };
    inputsInfo = vm.provenance;
  };

  # The reference is read from the built manifest while THIS derivation
  # builds — an ordinary build-time dependency, not import-from-derivation.
  launcher = pkgs.runCommand "captive-vm-run"
    {
      nativeBuildInputs = [ pkgs.makeWrapper ];
      passthru = { inherit manifest guest; };
    } ''
    reference=$(cat ${manifest}/reference)
    makeWrapper ${pkgs.bash}/bin/bash $out/bin/captive-vm-run \
      --add-flags ${../bin/captive-vm-run.sh} \
      --set CVM_MANIFEST ${manifest}/manifest.json \
      --set CVM_REFERENCE "$reference" \
      --set CVM_PUBKEY ${lib.escapeShellArg (if vm.publicKey == null then "" else vm.publicKey)} \
      --set CVM_SIG /var/lib/captive-portal/manifest.sig \
      --set CVM_QEMU ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
      --set CVM_CORESCHED ${pkgs.util-linux}/bin/coresched \
      --set CVM_DNSMASQ ${pkgs.dnsmasq}/bin/dnsmasq \
      --set-default CVM_RUNDIR ${runDir} \
      --set CVM_FB_WIDTH ${toString vm.framebuffer.width} \
      --set CVM_FB_HEIGHT ${toString vm.framebuffer.height} \
      --set CVM_GUEST_MAC ${vm.guestMac} \
      --set CVM_GPU_FUNCTIONS ${lib.escapeShellArg (lib.concatStringsSep " " vm.gpu.functions)} \
      --set CVM_GPU_ROM ${lib.escapeShellArg (if vm.gpu.romFile == null then "" else toString vm.gpu.romFile)} \
      --set CVM_GPU_INPUTS ${lib.escapeShellArg (if vm.gpu.inputs == [ ] then "auto" else lib.concatStringsSep " " vm.gpu.inputs)} \
      --set CVM_GPU_GRAB_TOGGLE ${vm.gpu.grabToggle} \
      --set CVM_CPU ${lib.escapeShellArg (if vm.cpu == null then "" else toString vm.cpu)} \
      --set CVM_VT ${vt} \
      --set CVM_DEBUG ${if vm.debug then "1" else "0"} \
      --set PATH ${lib.makeBinPath (with pkgs; [
        coreutils findutils gnused gnugrep jq iproute2 nftables openssh
        networkmanager systemd kbd util-linux
      ])}
  '';

  # isolcpus=0,1 / isolcpus=2-3 / isolcpus=managed_irq,domain,4 -> [ 0 1 ... ]
  isolated =
    let
      params = lib.filter (lib.hasPrefix "isolcpus=") config.boot.kernelParams;
      items = lib.concatMap (p: lib.splitString "," (lib.removePrefix "isolcpus=" p)) params;
      expand = i:
        let r = lib.splitString "-" i; in
        if lib.length r == 2 && lib.all (x: builtins.match "[0-9]+" x != null) r
        then lib.range (lib.toInt (lib.head r)) (lib.toInt (lib.last r))
        else if builtins.match "[0-9]+" i != null then [ (lib.toInt i) ] else [ ];
    in
    lib.concatMap expand items;

  usersJs = lib.concatMapStringsSep " || " (u: "subject.user == ${builtins.toJSON u}") vm.users;
in
{
  options.custom.network.captivePortal.microvm = {
    guestModule = lib.mkOption {
      type = lib.types.nullOr lib.types.deferredModule;
      default = null;
      description = ''
        microvm.nix's `nixosModules.microvm` (erofs store disk, virtio boot).
        configuration.nix sets it from the flake inputs; the VM gate passes it
        explicitly.
      '';
    };
    extraGuestModules = lib.mkOption {
      type = lib.types.listOf lib.types.deferredModule;
      default = [ ];
      description = "Extra modules for the guest. Anything here changes the manifest, and so the reference.";
    };
    provenance = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Flake input narHashes recorded in the manifest (informational; configuration.nix fills it).";
    };
    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.optional (config.custom ? user) config.custom.user.name;
      defaultText = lib.literalExpression "[ config.custom.user.name ]";
      description = "Users allowed to start and stop captive-vm.service (polkit), which the watcher and captive-login do.";
    };
    memMiB = lib.mkOption { type = lib.types.ints.between 768 8192; default = 1536; };
    timeoutSec = lib.mkOption { type = lib.types.ints.positive; default = 600; description = "Longest a run may last."; };
    probeIntervalSec = lib.mkOption { type = lib.types.ints.positive; default = 20; };
    gpuGraceSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 45;
      description = "A GPU-mode guest that exits within this many seconds found no display; the run falls back to the framebuffer.";
    };
    guestMac = lib.mkOption {
      type = lib.types.strMatching "02(:[0-9a-f]{2}){5}";
      default = "02:ca:97:00:00:02";
      description = "Locally administered; never leaves the host (the guest is NATed).";
    };
    vt = lib.mkOption { type = lib.types.ints.between 2 63; default = 7; description = "VT the framebuffer viewer runs on."; };
    framebuffer = {
      width = lib.mkOption { type = lib.types.ints.positive; default = 1600; };
      height = lib.mkOption { type = lib.types.ints.positive; default = 1000; };
    };
    viewerEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { WLR_RENDERER = "pixman"; };
      description = "Extra environment for cage on the viewer VT (the VM gate forces pixman; real hardware uses the iGPU).";
    };
    cpu = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        Pin the VMM to this CPU. Unset, the scheduler places it; core
        scheduling (automatic when SMT is on) already keeps host threads off
        the vCPU's physical core while it runs. Refused if isolcpus gave it
        to the DSP guest.
      '';
    };
    publicKey = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "ssh-ed25519 [A-Za-z0-9+/]+=*");
      default = null;
      description = "When set, every launch requires a manifest signature from this key.";
    };
    signingKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/captive-vm-signing-key";
      description = "Runtime path of the ed25519 private key (a sops secret) that signs the manifest at activation.";
    };
    build = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      internal = true;
      readOnly = true;
      description = "The guest evaluation, manifest and launcher, for the gates (like system.build).";
    };
    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Guest serial console to /run/captive-vm/ctl/serial.log, kept after the run and copied to /var/lib/captive-portal/debug/serial.log at discard. Guest-controlled bytes on the host; test use only.";
    };
    gpu = {
      functions = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-7]");
        default = [ ];
        example = [ "0000:03:00.0" "0000:03:00.1" ];
        description = ''
          PCI functions of a GPU given to the portal VM (the GPU and its audio
          function). Empty: framebuffer only. Used only while the whole IOMMU
          group is bound to vfio-pci; otherwise every run uses the framebuffer.
          The guest drives this GPU's own outputs, so a monitor must be
          connected to it (on the Framework 16: the Graphics Module's rear port).
        '';
      };
      pciIds = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[0-9a-f]{4}:[0-9a-f]{4}");
        default = [ ];
        example = [ "1002:7480" "1002:ab30" ];
        description = "vendor:device ids for vfio-pci.ids= when bindAtBoot is on.";
      };
      bindAtBoot = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Claim the GPU for vfio-pci at boot and never give it to the host
          driver. The host never touches a GPU a guest has used. On a machine
          whose discrete GPU also runs games, this takes it away from them.
        '';
      };
      firmware = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "amdgpu" ];
        description = "linux-firmware subdirectories copied into the guest for the passed-through GPU.";
      };
      kernelModules = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "amdgpu" ];
      };
      romFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "VBIOS image for GPUs whose ROM the guest cannot read on its own.";
      };
      inputs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "evdev paths grabbed for the GPU guest; empty = every by-path keyboard and mouse. Paths ending in -kbd are keyboards.";
      };
      grabToggle = lib.mkOption {
        type = lib.types.enum [ "ctrl-ctrl" "alt-alt" "shift-shift" "meta-meta" "scrolllock" "ctrl-scrolllock" ];
        default = "ctrl-ctrl";
        description = "Keys that hand the keyboard back to the host while the GPU guest runs.";
      };
    };
  };

  config = lib.mkMerge [
    { custom.network.captivePortal.microvm.build = { inherit guest manifest launcher; }; }

    (lib.mkIf enabled {
      assertions = [
        {
          assertion = vm.guestModule != null;
          message = "custom.network.captivePortal.browser.kind = \"microvm\" needs custom.network.captivePortal.microvm.guestModule (microvm.nix's nixosModules.microvm).";
        }
        {
          assertion = vm.cpu == null || !(lib.elem vm.cpu isolated);
          message = "custom.network.captivePortal.microvm.cpu = ${toString vm.cpu} is isolated (isolcpus) for the DSP guest; pick another core or leave it unset.";
        }
        {
          assertion = vm.signingKeyFile == null || !(lib.hasPrefix builtins.storeDir vm.signingKeyFile);
          message = "custom.network.captivePortal.microvm.signingKeyFile must not be a Nix store path — the store is world-readable.";
        }
        {
          assertion = vm.signingKeyFile == null || vm.publicKey != null;
          message = "custom.network.captivePortal.microvm.signingKeyFile is set but publicKey is not; nothing would check the signature.";
        }
        {
          assertion = !vm.gpu.bindAtBoot || (gpuOn && vm.gpu.pciIds != [ ]);
          message = "custom.network.captivePortal.microvm.gpu.bindAtBoot needs gpu.functions and gpu.pciIds.";
        }
      ];

      users.users.captive-vm = {
        isSystemUser = true;
        group = "captive-vm";
        extraGroups = [ "kvm" ];
        description = "Portal microVM (QEMU)";
      };
      users.groups.captive-vm = { };
      users.users.captive-view = {
        isSystemUser = true;
        group = "captive-view";
        description = "Portal microVM display (cage on a VT)";
      };
      users.groups.captive-view = { };

      # The tap exists only during a run; NetworkManager must never adopt it,
      # and the NixOS firewall must let the guest's DNS reach the forwarder
      # (the run's own table drops everything else from cp0).
      networking.networkmanager.unmanaged = [ "interface-name:cp0" ];
      networking.firewall.interfaces.cp0 = {
        allowedUDPPorts = [ 53 ];
        allowedTCPPorts = [ 53 ];
      };

      systemd.tmpfiles.rules = [ "d /run/captive-portal 0755 root root -" ];

      systemd.services.captive-vm = {
        description = "Portal login microVM (one disposable run)";
        after = [ "network.target" "NetworkManager.service" "systemd-resolved.service" ];
        restartIfChanged = false;
        serviceConfig = {
          Type = "notify";
          NotifyAccess = "all";
          ExecStart = "${launcher}/bin/captive-vm-run run";
          TimeoutStartSec = 90;
          RuntimeMaxSec = vm.timeoutSec + 120;
          # SIGTERM reaches the orchestrator first so it can discard; its
          # children follow.
          KillMode = "mixed";
          TimeoutStopSec = 30;
          RuntimeDirectory = "captive-vm";
          RuntimeDirectoryMode = "0755";
          # Under debug the orchestrator keeps ctl/serial.log, but systemd
          # removes the whole RuntimeDirectory on stop regardless — so a
          # debugging run that died young left nothing to read. Preserve it
          # only then; a normal run has no serial log and keeps the default.
          RuntimeDirectoryPreserve = if vm.debug then "yes" else "no";
          StateDirectory = "captive-portal";
          StateDirectoryMode = "0700";
          NoNewPrivileges = true;
          ProtectHome = true;
          PrivateTmp = true;
          ProtectSystem = "full";
          RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" "AF_INET" "AF_INET6" ];
          CapabilityBoundingSet = [
            "CAP_NET_ADMIN" # tap, nft, forwarding
            "CAP_NET_BIND_SERVICE" # the forwarder on :53
            "CAP_SETUID"
            "CAP_SETGID" # the forwarder drops to nobody
            "CAP_CHOWN"
            "CAP_FOWNER"
            "CAP_DAC_OVERRIDE" # run-dir ownership, the VFIO group node
            "CAP_KILL" # stopping the dropped-privilege forwarder
            "CAP_SYS_TTY_CONFIG" # chvt
          ];
        };
      };

      systemd.services.captive-vm-viewer = {
        description = "Portal microVM display: cage + wlvncc on tty${vt}";
        after = [ "systemd-user-sessions.service" "systemd-logind.service" ];
        wants = [ "systemd-logind.service" ];
        conflicts = [ "getty@tty${vt}.service" "autovt@tty${vt}.service" ];
        restartIfChanged = false;
        unitConfig.ConditionPathExists = "/dev/tty${vt}";
        environment = {
          XKB_DEFAULT_LAYOUT = keyboardLayout;
          XKB_DEFAULT_VARIANT = keyboardVariant;
        } // vm.viewerEnvironment;
        serviceConfig = {
          # XDG_RUNTIME_DIR is forced to a directory this unit owns. PAM hands
          # cage /run/user/<uid>, and ProtectHome=true below makes /run/user
          # inaccessible along with /home and /root (systemd.exec(5)), so
          # cage tried wayland-0.lock … wayland-32.lock under a path that did
          # not exist in its namespace, gave up with "Unable to open Wayland
          # socket" and dumped core — on the first sweep run of
          # .#test-captive-vm. env(1) rather than Environment=: the PAM
          # environment is merged last and would win. wlvncc inherits the
          # variable from cage and finds the socket the same way.
          ExecStart = "${pkgs.coreutils}/bin/env XDG_RUNTIME_DIR=/run/captive-vm-viewer ${pkgs.cage}/bin/cage -d -- ${pkgs.wlvncc}/bin/wlvncc -d ${runDir}/vnc/vnc.sock";
          RuntimeDirectory = "captive-vm-viewer";
          RuntimeDirectoryMode = "0700";
          User = "captive-view";
          Group = "captive-view";
          PAMName = "captive-view";
          TTYPath = "/dev/tty${vt}";
          TTYReset = "yes";
          TTYVHangup = "yes";
          TTYVTDisallocate = "yes";
          StandardInput = "tty-fail";
          StandardOutput = "journal";
          StandardError = "journal";
          UtmpIdentifier = "tty${vt}";
          UtmpMode = "user";
          IgnoreSIGPIPE = "no";
          # It needs a unix socket and the seat, nothing else.
          PrivateNetwork = true;
          NoNewPrivileges = true;
          ProtectHome = true;
          RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" ];
        };
      };

      security.pam.services.captive-view.text = ''
        auth    required pam_unix.so nullok
        account required pam_unix.so
        session required pam_unix.so
        session required pam_env.so conffile=/etc/pam/environment readenv=0
        session required ${config.systemd.package}/lib/security/pam_systemd.so
      '';

      security.polkit.extraConfig = lib.optionalString (vm.users != [ ]) ''
        // custom.network.captivePortal.microvm.users may start and stop the
        // portal VM, and nothing else, without a password prompt.
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "captive-vm.service" &&
              (action.lookup("verb") == "start" || action.lookup("verb") == "stop") &&
              (${usersJs})) {
            return polkit.Result.YES;
          }
        });
      '';

      systemd.services.captive-vm-sign = lib.mkIf (vm.signingKeyFile != null) {
        description = "Sign the portal microVM manifest with this host's key";
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ manifest ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StateDirectory = "captive-portal";
          StateDirectoryMode = "0700";
          UMask = "0077";
        };
        script = ''
          ${pkgs.openssh}/bin/ssh-keygen -Y sign -q -f ${lib.escapeShellArg vm.signingKeyFile} \
            -n oligarchy-captive-vm < ${manifest}/manifest.json > /var/lib/captive-portal/manifest.sig.tmp
          mv -f /var/lib/captive-portal/manifest.sig.tmp /var/lib/captive-portal/manifest.sig
        '';
      };

      environment.systemPackages = [ launcher ];
    })

    (lib.mkIf (enabled && vm.gpu.bindAtBoot) {
      boot.initrd.kernelModules = [ "vfio_pci" "vfio" "vfio_iommu_type1" ];
      boot.kernelParams = [ "vfio-pci.ids=${lib.concatStringsSep "," vm.gpu.pciIds}" ];
      warnings = [
        ''
          custom.network.captivePortal.microvm.gpu.bindAtBoot gives ${lib.concatStringsSep " " vm.gpu.functions}
          to vfio-pci for good: the host driver never binds it, so nothing on the host
          (Steam's dGPU offload included, see docs/dgpu-steam-forcing.md) can use it.
        ''
      ];
    })
  ];
}
