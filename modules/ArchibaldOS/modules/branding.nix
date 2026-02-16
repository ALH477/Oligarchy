# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025 DeMoD LLC. All rights reserved.
# ArchibaldOS branding module
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.branding;

  audioLogo = ''
     _             _     _ _           _  ___  ____  
    / \   _ __ ___| |__ (_) |__   __ _| |/ _ \/ ___| 
   / _ \ | '__/ __| '_ \| | '_ \ / _` | | | | \___ \ 
  / ___ \| | | (__| | | | | |_) | (_| | | |_| |___) |
 /_/   \_\_|  \___|_| |_|_|_.__/ \__,_|_|\___/|____/ 
                                                     
  Community Edition - Real-Time Audio Workstation
  https://github.com/ALH477/ArchibaldOS
  '';

  roboticsLogo = ''
     _             _     _ _           _  ___  ____  
    / \   _ __ ___| |__ (_) |__   __ _| |/ _ \/ ___| 
   / _ \ | '__/ __| '_ \| | '_ \ / _` | | | | \___ \ 
  / ___ \| | | (__| | | | | |_) | (_| | | |_| |___) |
 /_/   \_\_|  \___|_| |_|_|_.__/ \__,_|_|\___/|____/ 
                                                     
  Community Edition - Real-Time Robotics Workstation
  https://github.com/ALH477/ArchibaldOS
  '';

  logos = {
    audio = audioLogo;
    robotics = roboticsLogo;
  };

  prettyNames = {
    audio = "ArchibaldOS 24.11 Community Edition (Audio)";
    robotics = "ArchibaldOS 24.11 Community Edition (Robotics)";
  };

in {
  options.branding = {
    enable = mkEnableOption "ArchibaldOS branding";

    variant = mkOption {
      type = types.enum [ "audio" "robotics" ];
      default = "audio";
      description = "Branding variant";
    };
  };

  config = mkIf cfg.enable {
    # MOTD with ASCII art
    users.motd = logos.${cfg.variant};

    # Boot splash
    boot.plymouth = {
      enable = true;
      theme = "bgrt";
    };

    # Silent boot
    boot.consoleLogLevel = 0;
    boot.initrd.verbose = false;

    # System branding
    environment.etc."os-release".text = lib.mkForce ''
      NAME="ArchibaldOS"
      ID=archibaldos
      ID_LIKE=nixos
      VERSION="24.11-community"
      VERSION_ID="24.11"
      VARIANT="${cfg.variant}"
      PRETTY_NAME="${prettyNames.${cfg.variant}}"
      HOME_URL="https://github.com/ALH477/ArchibaldOS"
      SUPPORT_URL="https://github.com/ALH477/ArchibaldOS/issues"
      BUG_REPORT_URL="https://github.com/ALH477/ArchibaldOS/issues"
    '';
  };
}
