{
  description = "DeMoD Boot Intro — CRT audio-visualizer boot splash (FFmpeg generation + mpv playback)";

  # No inputs needed: the module pulls everything from the host's pkgs.
  inputs = { };

  outputs = { self }: {
    # NixOS module exporting services.boot-intro.
    nixosModules = {
      boot-intro = ./modules/core.nix;
      default = ./modules/core.nix;
    };
  };
}
