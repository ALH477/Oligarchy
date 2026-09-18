{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.reliquary;
in
{
  options.services.reliquary = {
    enable = lib.mkEnableOption "Reliquary preservation store and USB automount hooks";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.reliquary;
      description = "Reliquary package.";
    };

    storeDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/reliquary";
      description = "On-disk staging store (blocks, catalog, ISO images).";
    };

    mountRoot = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/reliquary";
      description = "Where labelled USB partitions are mounted.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    environment.sessionVariables.RELIQUARY_STORE = cfg.storeDir;

    systemd.tmpfiles.rules = [
      "d ${cfg.storeDir} 0750 root root -"
      "d ${cfg.storeDir}/blocks 0750 root root -"
      "d ${cfg.storeDir}/iso 0750 root root -"
      "d ${cfg.mountRoot} 0755 root root -"
      "d ${cfg.mountRoot}/meta-a 0755 root root -"
      "d ${cfg.mountRoot}/data-a 0755 root root -"
      "d ${cfg.mountRoot}/meta-b 0755 root root -"
      "d ${cfg.mountRoot}/data-b 0755 root root -"
    ];

    # Mount the dedicated Reliquary partitions by filesystem label whenever
    # either 256 GB stick is plugged in.
    fileSystems."${cfg.mountRoot}/meta-a" = {
      device = "/dev/disk/by-label/RLQ-META-A";
      fsType = "vfat";
      options = [ "nofail" "x-systemd.automount" "x-systemd.idle-timeout=300" "uid=0" "gid=0" "umask=022" ];
    };
    fileSystems."${cfg.mountRoot}/data-a" = {
      device = "/dev/disk/by-label/RLQ-DATA-A";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.automount" "x-systemd.idle-timeout=300" "noatime" ];
    };
    fileSystems."${cfg.mountRoot}/meta-b" = {
      device = "/dev/disk/by-label/RLQ-META-B";
      fsType = "vfat";
      options = [ "nofail" "x-systemd.automount" "x-systemd.idle-timeout=300" "uid=0" "gid=0" "umask=022" ];
    };
    fileSystems."${cfg.mountRoot}/data-b" = {
      device = "/dev/disk/by-label/RLQ-DATA-B";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.automount" "x-systemd.idle-timeout=300" "noatime" ];
    };
  };
}
