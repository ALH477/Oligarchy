{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.boot-intro-tui;
in {
  options.services.boot-intro-tui = {
    enable = mkEnableOption "DeMoD Boot Intro TUI Manager";

    package = mkOption {
      type = types.package;
      default = pkgs.mpv;  # Placeholder - would be actual TUI package
      description = "The boot-intro-tui package to use.";
    };

    apiUrl = mkOption {
      type = types.str;
      default = "http://localhost:8080";
      description = "URL of the video database API server.";
    };

    cacheDir = mkOption {
      type = types.path;
      default = "/var/cache/boot-intro-tui";
      description = "Directory for cached videos and thumbnails.";
    };

    tempDir = mkOption {
      type = types.path;
      default = "/tmp/boot-intro-renders";
      description = "Temporary directory for video rendering.";
    };

    nixosConfigPath = mkOption {
      type = types.path;
      default = "/etc/nixos/boot-intro.nix";
      description = "Path where TUI will write boot intro configuration.";
    };

    autoRebuild = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Automatically run nixos-rebuild when applying configuration.
        Requires passwordless sudo for nixos-rebuild.
      '';
    };

    defaultVolume = mkOption {
      type = types.int;
      default = 100;
      description = "Default playback volume in TUI previews.";
    };

    allowedUsers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Users allowed to use the TUI.";
    };

    allowedGroups = mkOption {
      type = types.listOf types.str;
      default = [ "wheel" ];
      description = "Groups allowed to use the TUI.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0755 root root -"
      "d ${cfg.tempDir} 0755 root root -"
    ];

    environment.etc."boot-intro-tui/config.toml".text = ''
      [database]
      api_url = "${cfg.apiUrl}"
      cache_dir = "${cfg.cacheDir}"

      [rendering]
      temp_dir = "${cfg.tempDir}"

      [nixos]
      config_path = "${cfg.nixosConfigPath}"
      rebuild_command = "sudo nixos-rebuild switch"

      [playback]
      default_volume = ${toString cfg.defaultVolume}
    '';

    environment.shellAliases = {
      "boot-intro-tui" = "${cfg.package}/bin/boot-intro-tui";
    };
  };
}
