{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.demod-voice;
in {
  options.services.demod-voice = {
    enable = mkEnableOption "DeMoD Voice - Local TTS and Voice Cloning";
    
    package = mkOption {
      type = types.package;
      default = (import ../demod-voice/flake.nix).packages.${pkgs.system}.demod-voice;
      description = "The demod-voice package to use";
    };
    
    configFile = mkOption {
      type = types.path;
      default = ../demod-voice/config.yaml;
      description = "Path to demod-voice configuration file";
    };
    
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open firewall ports for demod-voice API server";
    };
    
    port = mkOption {
      type = types.port;
      default = 5002;
      description = "Port for demod-voice API server";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    
    environment.etc."demod-voice/config.yaml".source = cfg.configFile;
    
    users.groups.demod-voice = {};
    
    users.users.demod-voice = {
      isSystemUser = true;
      group = "demod-voice";
      description = "DeMoD Voice service user";
    };
    
    systemd.services.demod-voice = {
      description = "DeMoD Voice - Local TTS and Voice Cloning";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 10;
        User = "demod-voice";
        Group = "demod-voice";
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/demod-voice" "/tmp" ];
        
        ExecStart = "${cfg.package}/bin/demod-voice serve --port ${toString cfg.port}";
        
        Environment = [
          "PYTHONPATH=${cfg.package}/lib/python3.11/site-packages"
        ];
      };
    };
    
    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ cfg.port ];
    };
  };
}
