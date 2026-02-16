# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025 DeMoD LLC. All rights reserved.
# Profile selector module
{ config, lib, pkgs, ... }:

with lib;

{
  options.profiles = {
    # ========================================================================
    # AUDIO PROFILE
    # ========================================================================
    audio = {
      enable = mkEnableOption "Audio production profile";

      latency = mkOption {
        type = types.enum [ "low" "ultra-low" ];
        default = "ultra-low";
        description = "Audio latency setting";
      };
    };

    # ========================================================================
    # ROBOTICS PROFILE
    # ========================================================================
    robotics = {
      enable = mkEnableOption "Robotics and control systems profile";

      ros = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Enable ROS 2 support (when available)";
        };
      };

      simulation = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Enable simulation tools (Gazebo, etc.)";
        };
      };

      hardware = {
        arduino = mkOption {
          type = types.bool;
          default = true;
          description = "Enable Arduino support";
        };

        canbus = mkOption {
          type = types.bool;
          default = true;
          description = "Enable CAN bus support";
        };

        gpio = mkOption {
          type = types.bool;
          default = true;
          description = "Enable GPIO/I2C/SPI support";
        };
      };
    };

    # ========================================================================
    # NETWORKING PROFILE
    # ========================================================================
    networking = {
      enable = mkEnableOption "HydraMesh networking profile";

      mode = mkOption {
        type = types.enum [ "p2p" "client" "server" ];
        default = "p2p";
        description = "HydraMesh network mode";
      };
    };
  };

  config = mkMerge [
    # Audio profile configuration
    (mkIf config.profiles.audio.enable {
      # Audio groups
      users.groups.audio = {};
      users.groups.jackaudio = {};
      users.groups.realtime = {};

      # RT limits
      security.pam.loginLimits = [
        { domain = "@audio"; type = "-"; item = "rtprio"; value = "99"; }
        { domain = "@audio"; type = "-"; item = "memlock"; value = "unlimited"; }
        { domain = "@audio"; type = "-"; item = "nice"; value = "-19"; }
      ];
    })

    # Robotics profile configuration
    (mkIf config.profiles.robotics.enable {
      # Robotics groups
      users.groups.dialout = {};
      users.groups.plugdev = {};
      users.groups.gpio = {};
      users.groups.i2c = {};
      users.groups.spi = {};

      # RT limits for control loops
      security.pam.loginLimits = [
        { domain = "@realtime"; type = "-"; item = "rtprio"; value = "95"; }
        { domain = "@realtime"; type = "-"; item = "memlock"; value = "unlimited"; }
        { domain = "@realtime"; type = "-"; item = "nice"; value = "-15"; }
      ];

      users.groups.realtime = {};

      # Enable I2C
      hardware.i2c.enable = mkIf config.profiles.robotics.hardware.gpio true;
    })

    # Networking profile configuration
    (mkIf config.profiles.networking.enable {
      services.hydramesh = {
        enable = true;
        mode = config.profiles.networking.mode;
        hardened = true;
      };
    })
  ];
}
