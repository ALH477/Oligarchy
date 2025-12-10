# modules/archibaldos-dsp-vm.nix
{ config, pkgs, lib, ... }:

let
  cfg = config.custom.archibaldos-dsp-vm;

  # This is the canonical way — the image comes straight from the ArchibaldOS flake
  # No URLs, no manual sha256, no web server, no GitHub LFS, no 2 GB limit
  dspImage = archibaldos.packages.${pkgs.system}.dsp;   # ← the .xz image you already build

  # Decompress once, at evaluation time → raw .img ready for QEMU
  diskImage = pkgs.runCommandNoCC "archibaldos-dsp-disk.img" {} ''
    mkdir -p $out
    ${pkgs.xz}/bin/xz -d --stdout ${dspImage} > $out/disk.img
  '';
in
{
  options.custom.archibaldos-dsp-vm.enable = lib.mkEnableOption "ArchibaldOS kexec DSP coprocessor VM";

  config = lib.mkIf cfg.enable {
    # Core 0 becomes the eternal DSP slave
    boot.kernelParams = [
      "isolcpus=0" "nohz_full=0" "rcu_nocbs=0"
      "irqaffinity=1-$(nproc --all)"
      "threadirqs"
    ];

    # Reserve hugepages so QEMU doesn’t fight the host
    boot.kernelParams = [ "hugepagesz=2M" "hugepages=1024" ];

    # VFIO passthrough of your USB audio interface (replace with your actual PCI ID)
    # Run `lspci -nn | grep -i audio` to get it
    boot.kernelModules = [ "vfio-pci" "vfio_iommu_type1" ];
    boot.extraModprobeConfig = ''
      options vfio-pci ids=XXXX:XXXX  # ← your Behringer/Focusrite/etc
    '';

    systemd.services.archibaldos-dsp-vm = {
      description = "ArchibaldOS kexec DSP Coprocessor";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      requires = [ "libvirtd.service" ];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "3";
        ExecStart = "${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
          -enable-kvm \
          -name archibald-dsp \
          -m 1536 \
          -smp 1 \
          -cpu host \
          -machine q35 \
          -drive file=${diskImage}/diskImage}/disk.img,format=raw,if=virtio,cache=unsafe \
          -device vfio-pci,host=00:1b.0 \\  # ← change to your audio device
          -netdev user,id=net0,hostfwd=tcp::4713-:4713 \
          -device virtio-net-pci,netdev=net0 \
          -nographic \
          -daemonize";
        ExecStop = "${pkgs.libvirt}/bin/virsh shutdown archibald-dsp || true";
      };

      # Auto-start on boot and survive crashes
      startLimitIntervalSec = 0;
    };

    # Optional: expose JACK ports to host
    networking.firewall.allowedTCPPorts = [ 4713 ];
  };
}
