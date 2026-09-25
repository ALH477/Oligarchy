# ═══════════════════════════════════════════════════════════════════════════════
# The portal microVM guest — one job: show a browser on one URL, then die.
# ═══════════════════════════════════════════════════════════════════════════════
# A function of the host's settings, returning a NixOS module. Built with
# microvm.nix's guest module for the erofs store disk and the virtio boot glue;
# booted by modules/captive-portal/bin/captive-vm-run.sh with its own QEMU
# command line, NOT microvm.nix's runner, because the display, the disks and
# the kernel command line are decided per run from the signed manifest.
#
# What the host can rely on, and why:
#   - /nix/store is the erofs store disk behind dm-verity. The root hash comes
#     from the kernel command line (captive.verity=), where the host puts it
#     from the verified manifest. It cannot live in the initrd: the initrd is
#     inside the store disk, so it would have to contain its own hash.
#   - / is tmpfs (microvm.nix default); there is no writable disk at all.
#   - No vsock, no shared folders, no agent, no clipboard, no SSH, no Nix
#     daemon. The guest's channels to the host are the filtered NAT, the
#     framebuffer (or a passed-through GPU it owns outright), and its own exit.
#   - Closing the browser powers the guest off; so does finding no display.
#
# Kernel lockdown is deliberately NOT claimed: the stock NixOS kernel has
# CONFIG_SECURITY_LOCKDOWN_LSM=n (see modules/cpu-security.nix), so
# `lockdown=` would be a silent no-op. Root in this guest owns a disposable
# guest and nothing else; the boundary that matters is the VM.
captive:

{ config, lib, pkgs, ... }:

let
  hasGpu = captive.gpuFirmware != null;

  # Every policy here either keeps the portal page working (DoH off, captive
  # portal service off, HTTPS-only off) or removes code paths a kiosk never
  # needs. Downloads are not blocked by policy — Firefox has none that holds —
  # but they land in tmpfs and die with the VM; nothing is ever exported.
  firefox = pkgs.wrapFirefox pkgs.firefox-unwrapped {
    extraPolicies = {
      DisableTelemetry = true;
      DisableFirefoxStudies = true;
      DisablePocket = true;
      DisableFirefoxAccounts = true;
      DisableAppUpdate = true;
      DisableDeveloperTools = true;
      DisableFeedbackCommands = true;
      DisableSetDesktopBackground = true;
      DontCheckDefaultBrowser = true;
      NoDefaultBookmarks = true;
      OfferToSaveLogins = false;
      PasswordManagerEnabled = false;
      CaptivePortal = false;
      NetworkPrediction = false;
      SearchSuggestEnabled = false;
      OverrideFirstRunPage = "";
      OverridePostUpdatePage = "";
      # The portal answers through the venue's resolver only; DoH would ask
      # someone else and the login page would never load.
      DNSOverHTTPS = { Enabled = false; Locked = true; };
      HttpsOnlyMode = "allowed";
      ExtensionSettings = { "*" = { installation_mode = "blocked"; }; };
      Homepage = { URL = captive.loginUrl; Locked = true; StartPage = "homepage"; };
      UserMessaging = {
        WhatsNew = false;
        ExtensionRecommendations = false;
        FeatureRecommendations = false;
        UrlbarInterventions = false;
        SkipOnboarding = true;
        MoreFromMozilla = false;
        Locked = true;
      };
    };
    extraPrefs = ''
      lockPref("network.trr.mode", 5);
      lockPref("network.captive-portal-service.enabled", false);
      lockPref("network.connectivity-service.enabled", false);
      lockPref("browser.sessionstore.resume_from_crash", false);
      lockPref("browser.shell.checkDefaultBrowser", false);
      lockPref("datareporting.healthreport.uploadEnabled", false);
      lockPref("datareporting.policy.dataSubmissionEnabled", false);
    '';
  };

  # Runs as the kiosk user under a logind session on tty1 (same shape as
  # nixpkgs' services.cage, which is a boot-time tty1 kiosk and so not quite
  # this). The renderer choice is the only thing decided at run time.
  kiosk = pkgs.writeShellScript "portal-kiosk" ''
    set -eu
    for v in /sys/class/drm/card[0-9]*/device/vendor; do
      [ -e "$v" ] || continue
      # By PCI VENDOR, not device/driver: that symlink resolves to the PCI bus
      # driver (virtio-pci), never the DRM driver (virtio_gpu), so the old
      # `basename … = virtio_gpu` test never matched, WLR_RENDERER stayed
      # unset, and cage tried EGL/Vulkan on a 2D device — "Unable to create
      # the wlroots renderer", exit, and the guest powered off ~1 s in. That
      # is what .#test-captive-vm caught the first time it ran (2026-09-25).
      # 0x1af4 virtio, 0x1234 QEMU stdvga/bochs, 0x1b36 Red Hat qxl: software
      # framebuffers with no usable GL here — render on the CPU. A passed-
      # through real GPU (0x1002 AMD, 0x10de NVIDIA, 0x8086 Intel) keeps GL.
      case "$(${pkgs.coreutils}/bin/cat "$v")" in
        0x1af4 | 0x1234 | 0x1b36) export WLR_RENDERER=pixman ;;
      esac
    done
    export XKB_DEFAULT_LAYOUT=${lib.escapeShellArg captive.keyboardLayout}
    export XKB_DEFAULT_VARIANT=${lib.escapeShellArg captive.keyboardVariant}
    export MOZ_ENABLE_WAYLAND=1
    profile=$(${pkgs.coreutils}/bin/mktemp -d)
    exec ${pkgs.cage}/bin/cage -d -- ${firefox}/bin/firefox \
      --no-remote --new-instance --profile "$profile" ${lib.escapeShellArg captive.loginUrl}
  '';
in
{
  microvm = {
    # Guest-side defaults only (systemd initrd, virtio modules). The host never
    # uses microvm.nix's runner for this VM.
    hypervisor = "qemu";
    vcpu = 1;
    mem = captive.memMiB;
    storeOnDisk = true;
    storeDiskType = "erofs";
    writableStoreOverlay = null;
    interfaces = [ ];
    shares = [ ];
    volumes = [ ];
    registerClosure = false;
  };

  # ── dm-verity over the store disk ────────────────────────────────────────
  # systemd-veritysetup comes from nixpkgs' dmVerity module; the mapping is
  # attached by hand because the generator's root=/usr= slots would also
  # imply mounts this tmpfs-rooted guest must not get.
  boot.initrd.systemd.dmVerity.enable = true;
  boot.initrd.systemd.services.captive-verity = {
    description = "Map the verity-protected Nix store (root hash from the kernel command line)";
    unitConfig.DefaultDependencies = false;
    requires = [
      "dev-disk-by\\x2did-virtio\\x2dnixstore.device"
      "dev-disk-by\\x2did-virtio\\x2dnixverity.device"
    ];
    after = [
      "dev-disk-by\\x2did-virtio\\x2dnixstore.device"
      "dev-disk-by\\x2did-virtio\\x2dnixverity.device"
    ];
    before = [ "sysroot-nix-store.mount" ];
    requiredBy = [ "sysroot-nix-store.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      hash=""
      for w in $(cat /proc/cmdline); do
        case "$w" in captive.verity=*) hash="''${w#captive.verity=}" ;; esac
      done
      case "$hash" in
        "" | *[!0-9a-f]*)
          echo "captive-verity: no valid captive.verity= on the command line; refusing to boot" >&2
          exit 1 ;;
      esac
      if [ "''${#hash}" -ne 64 ]; then
        echo "captive-verity: root hash must be 64 hex characters" >&2
        exit 1
      fi
      exec ${config.boot.initrd.systemd.package}/lib/systemd/systemd-veritysetup attach nixstore \
        /dev/disk/by-id/virtio-nixstore /dev/disk/by-id/virtio-nixverity "$hash"
    '';
  };
  # The raw store disk and the verity device carry the same erofs label, so
  # microvm.nix's by-label device would be ambiguous. Mount the mapping only.
  fileSystems."/nix/store" = lib.mkForce {
    device = "/dev/mapper/nixstore";
    fsType = "erofs";
    options = [ "ro" ];
    neededForBoot = true;
    noCheck = true;
  };

  # ── kernel ───────────────────────────────────────────────────────────────
  boot.kernelModules = [ "virtio_gpu" "virtio_input" "evdev" ]
    ++ lib.optionals hasGpu captive.gpuKernelModules;
  # microvm.nix blacklists drm when its own graphics are off; this guest
  # draws, just not through microvm.nix's graphics.
  boot.blacklistedKernelModules = lib.mkForce [ "rfkill" "intel_pstate" ];
  security.lockKernelModules = true;
  boot.kernel.sysctl = {
    "kernel.kexec_load_disabled" = 1;
    "kernel.unprivileged_bpf_disabled" = 1;
    "kernel.yama.ptrace_scope" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 2;
    "net.ipv4.conf.all.forwarding" = 0;
  };
  hardware.firmware = lib.optional hasGpu (pkgs.runCommand "portal-gpu-firmware" { } ''
    mkdir -p $out/lib/firmware
    ${lib.concatMapStringsSep "\n" (d: "cp -r ${pkgs.linux-firmware}/lib/firmware/${d} $out/lib/firmware/") captive.gpuFirmware}
  '');
  hardware.graphics.enable = hasGpu;

  # ── network: one static link to the host's NAT ───────────────────────────
  networking.hostName = "portal";
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.enableIPv6 = false;
  networking.firewall.enable = true;
  systemd.network.networks."10-portal" = {
    matchConfig.MACAddress = captive.guestMac;
    address = [ "10.207.0.2/30" ];
    gateway = [ "10.207.0.1" ];
    dns = [ "10.207.0.1" ];
    networkConfig = {
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
  };
  # The host already chose DNSSEC/DoT policy for this link; the guest asks
  # the forwarder plainly. A portal that forges answers would otherwise
  # break the very page the guest exists to show.
  services.resolved = {
    enable = true;
    dnssec = "false";
    dnsovertls = "false";
    llmnr = "false";
    extraConfig = "MulticastDNS=no";
  };

  # ── the kiosk ────────────────────────────────────────────────────────────
  users.mutableUsers = false;
  # Both accounts are locked ("!" is an invalid hash, not an empty password),
  # which is the point: this guest is discarded after one portal login and
  # nothing should ever be able to log into it. NixOS's users-groups assertion
  # reads that state as "you are about to lock yourself out" and fails the
  # build, so the intent has to be stated explicitly — without this line the
  # whole portal-VM config refuses to evaluate.
  users.allowNoPasswordLogin = true;
  users.users.root.hashedPassword = "!";
  users.users.portal = {
    isNormalUser = true;
    hashedPassword = "!";
  };
  security.sudo.enable = false;
  security.polkit.enable = true;
  security.pam.services.portal-kiosk.text = ''
    auth    required pam_unix.so nullok
    account required pam_unix.so
    session required pam_unix.so
    session required pam_env.so conffile=/etc/pam/environment readenv=0
    session required ${config.systemd.package}/lib/security/pam_systemd.so
  '';

  # No display within 15 s (a passed-through GPU with no monitor attached)
  # powers the guest off; the host sees the VMM exit early and falls back to
  # the framebuffer. That exit is the only "signal" the guest can send.
  systemd.services.portal-display-check = {
    description = "Power off unless a display is connected";
    wantedBy = [ "graphical.target" ];
    before = [ "portal-kiosk.service" ];
    after = [ "systemd-udev-settle.service" "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Same reason as portal-kiosk below: a debug run's serial console is
      # the only place this unit's verdict can be read after the discard.
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      for _ in $(seq 1 30); do
        for s in /sys/class/drm/card[0-9]*-*/status; do
          [ -e "$s" ] && [ "$(cat "$s")" = connected ] && exit 0
        done
        sleep 0.5
      done
      echo "portal-display-check: no connected display; powering off" >&2
      systemctl poweroff --no-block
      exit 1
    '';
  };

  systemd.services.portal-kiosk = {
    description = "Portal login browser (cage + Firefox) on tty1";
    after = [ "systemd-user-sessions.service" "systemd-logind.service" "portal-display-check.service" "network-online.target" ];
    requires = [ "portal-display-check.service" ];
    wants = [ "dbus.socket" "systemd-logind.service" ];
    wantedBy = [ "graphical.target" ];
    conflicts = [ "getty@tty1.service" ];
    restartIfChanged = false;
    serviceConfig = {
      ExecStart = kiosk;
      # Closing the browser ends the run: power off, the host discards.
      ExecStopPost = "+${config.systemd.package}/bin/systemctl poweroff --no-block";
      User = "portal";
      PAMName = "portal-kiosk";
      TTYPath = "/dev/tty1";
      TTYReset = "yes";
      TTYVHangup = "yes";
      TTYVTDisallocate = "yes";
      StandardInput = "tty-fail";
      # journal+console, not journal: this guest's journal is volatile and
      # gone at poweroff, and the run discards the VM, so a kiosk that dies
      # in its first second leaves no trace at all — which is how the first
      # .#test-captive-vm run went (cage opened its session and exited, reason
      # unrecorded). The console is `-serial none` outside a debug run, so
      # nothing reaches the host unless captive-vm-run was asked to keep it.
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      UtmpIdentifier = "%n";
      UtmpMode = "user";
      IgnoreSIGPIPE = "no";
    };
  };
  systemd.defaultUnit = "graphical.target";

  # ── everything this guest does not need ──────────────────────────────────
  nix.enable = false;
  documentation.enable = false;
  services.openssh.enable = false;
  services.udisks2.enable = false;
  services.journald.extraConfig = "Storage=volatile";
  programs.command-not-found.enable = false;
  xdg.portal.enable = false;
  environment.defaultPackages = [ ];
  system.stateVersion = "25.11";
}
