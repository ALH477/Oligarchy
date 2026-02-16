{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.services.boot-intro-streamdb;

  # Build StreamDB from source (would normally use the demod/streamdb flake)
  streamdb = pkgs.rustPlatform.buildRustPackage rec {
    pname = "streamdb";
    version = "2.0.0";

    src = pkgs.fetchFromGitHub {
      owner = "demod";
      repo = "streamdb";
      rev = "v${version}";
      sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };

    cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

    buildFeatures = [ "persistence" "compression" "ffi" ];

    nativeBuildInputs = [ pkgs.pkg-config ];

    buildInputs = [ pkgs.openssl ];

    meta = {
      description = "High-performance embedded key-value database";
      license = lib.licenses.lgpl21Plus;
    };
  };
in {
  options.services.boot-intro-streamdb = {
    enable = mkEnableOption "DeMoD StreamDB for boot intro video storage";

    package = mkOption {
      type = types.package;
      default = streamdb;
      description = "The StreamDB package to use.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/boot-intro-streamdb";
      description = "Directory for StreamDB data files.";
    };

    autoImport = mkOption {
      type = types.bool;
      default = true;
      description = "Auto-import generated videos into StreamDB.";
    };

    maxSize = mkOption {
      type = types.int;
      default = 10240;  # MB
      description = "Maximum database size in MB.";
    };

    enableCompression = mkOption {
      type = types.bool;
      default = true;
      description = "Enable compression for stored videos.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 boot-intro boot-intro -"
    ];
  };
}
