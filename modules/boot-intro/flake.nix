{
  description = "DeMoD Boot Intro Suite - Video management with FFmpeg generation, StreamDB, TUI, and REST API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    let
      # Generate outputs for each system
      forAllSystems = flake-utils.lib.eachDefaultSystem (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
        in {
          # Core packages (always available)
          packages = {
            corePackages = with pkgs; [
              ffmpeg-full
              mpv
              alsa-utils
              socat
              bc
              soundfont-fluid
              dejavu_fonts
            ];
          };
        }
      );
    in
    {
      # NixOS modules (shared across systems)
      nixosModules = {
        boot-intro = ./modules/core.nix;
        boot-intro-tui = ./modules/tui.nix;
        boot-intro-api = ./modules/api.nix;
        boot-intro-streamdb = ./modules/streamdb.nix;
      };

      # Pass through packages from forAllSystems
      packages = forAllSystems.packages;
    };
}
