{ config, pkgs, lib, inputs, ... }:

let
  kernelVersion = "6.18.3";
  kernelDir = let parts = builtins.splitVersion kernelVersion; in "${builtins.elemAt parts 0}.${builtins.elemAt parts 1}";
  linux_src = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernelVersion}.tar.xz";
    sha256 = "eoh5FnuJxLrgd9bznE8hMHafBdva0qrZFK2rmvt9f5o=";
  };
  boreConfig = "${inputs.linux-cachyos}/linux-cachyos-bore/config";
  kernelPatches = [
    {
      name = "cachyos-base-all";
      patch = pkgs.fetchpatch {
        url = "https://raw.githubusercontent.com/cachyos/kernel-patches/master/${kernelDir}/all/0001-cachyos-base-all.patch";
        sha256 = "043kcszx2hnfinq6j92zzas4ghzqk42ah8hr73cnrzksp8kjqjl9";
      };
    }
    {
      name = "bore-cachy";
      patch = pkgs.fetchpatch {
        url = "https://raw.githubusercontent.com/cachyos/kernel-patches/master/${kernelDir}/sched/0001-bore-cachy.patch";
        sha256 = "10xl6vakjs3njmx1kgacs4zypyz4smcm8180h8zf0kiprk9753gq";
      };
    }
  ];
  customKernel = (pkgs.linuxManualConfig {
    inherit (pkgs) stdenv;
    version = "${kernelVersion}-cachyos-bore";
    modDirVersion = kernelVersion;  # Critical: matches upstream for external modules.
    src = linux_src;
    configfile = boreConfig;
    allowImportFromDerivation = true;
    kernelPatches = kernelPatches;
  }).overrideAttrs (oldAttrs: {
    passthru = oldAttrs.passthru // {
      features = { ia32Emulation = true; efiBootStub = true; };
      modDirVersion = kernelVersion;  # Propagate for safety.
    };
  });
in {
  boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor customKernel);

  boot.kernelModules = lib.mkBefore [ "kvm-amd" ];

  services.thermald.enable = true;
  powerManagement.powertop.enable = true;
}
