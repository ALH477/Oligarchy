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
# ═══════════════════════════════════════════════════════════════════════════════
{ config, lib, pkgs, ... }:

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
    "mitigations=off"     # a single-purpose guest on an isolated core
    "nohz_full=1"
    "rcu_nocbs=1"
  ];

  boot.initrd.availableKernelModules = [
    "virtio_pci" "virtio_blk" "virtio_net" "virtio_scsi"
    "xhci_pci" "usbhid" "usb_storage" "snd_usb_audio"
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
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # The key lives HERE, in the guest, and not as an option on the host module.
  # The image is built by `nix build .#dsp-vm-qcow` with no arguments from the
  # host config, so a host-side `authorizedKey` option would have been a
  # setting that silently did nothing — which is the exact failure mode this
  # whole rewrite exists to clear out. A public key is safe to commit; it is
  # only useful against a guest reachable on 127.0.0.1 through the host's
  # forward.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL+eqhrKR37FkxmiCuyZav4XVF7JK/1/yFA0rKaBBlbE hermes@framework16"
  ];
  # Reached only through the host's loopback forward; the guest has no route in
  # from anywhere else.
  networking.firewall.enable = false;
  networking.useDHCP = true;
  networking.hostName = "archibaldos-dsp";

  # ── Audio ────────────────────────────────────────────────────────────────
  # JACK, not PipeWire. This guest exists to be a deterministic audio device,
  # and a session-oriented sound server is the wrong shape for that.
  security.rtkit.enable = true;
  security.pam.loginLimits = [
    { domain = "@audio"; type = "-"; item = "rtprio";  value = "99"; }
    { domain = "@audio"; type = "-"; item = "memlock"; value = "unlimited"; }
    { domain = "@audio"; type = "-"; item = "nice";    value = "-19"; }
  ];
  users.groups.audio = { };
  users.users.root.extraGroups = [ "audio" ];

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

  # ── Nothing else ─────────────────────────────────────────────────────────
  services.xserver.enable = false;
  documentation.enable = false;
  documentation.nixos.enable = false;
  system.stateVersion = "25.11";
}
