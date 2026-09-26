# custom.screensaver — an Exsecutor screensaver behind hypridle.
#
# The engine is `somnium` from github:ALH477/exsecutor (the `exsecutor` flake
# input): a program written in Exsecutor, compiled by exsc and assembled by
# fasmg, freestanding, with no clock and no entropy source of its own. It
# reads a 17-byte request on stdin and writes raw 160x100 rgb24 frames on
# stdout; ./script.nix pipes those into a fullscreen, borderless mpv. What
# this module adds on top is the session wiring: a user unit that starts on
# demand, and (in home/hyprland/default.nix, which reads this option through
# osConfig) a hypridle listener that starts it at `timeout` and stops it on
# resume. See ./README.md.
#
# Opt-in, defaults OFF. With enable = false it adds no package, no unit and
# no listener — so, like android-mirror and oligarchy-vault, the ISO needs no
# mkForce for it — and it never forces the exsecutor input to be fetched.
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.custom.screensaver;
  system = pkgs.stdenv.hostPlatform.system;
in
{
  options.custom.screensaver = {
    enable = lib.mkEnableOption "the Exsecutor screensaver (somnium) under hypridle";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.exsecutor.packages.${system}.somnium;
      defaultText = lib.literalExpression "inputs.exsecutor.packages.\${system}.somnium";
      description = ''
        The somnium engine. The default is the exsecutor flake's own build:
        exsc compiled from fasmg, then examples/somnium/ compiled by exsc,
        under exsecutor's pinned nixpkgs.
      '';
    };

    somnia = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.enum [ "plasma" "ignis" "vita" ]);
      default = [ "plasma" "ignis" "vita" ];
      description = ''
        Effects to cycle through, in order: `plasma` (sine plasma), `ignis`
        (fire), `vita` (Conway's Life coloured by age). One entry runs that
        effect alone, with no cycling.
      '';
    };

    period = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds each effect runs when more than one is listed.";
    };

    fps = lib.mkOption {
      type = lib.types.ints.between 1 60;
      default = 20;
      description = ''
        Frame rate. The viewer plays at this rate and the pipe's
        backpressure paces the engine to it, so this is also the CPU knob:
        somnium writes each frame one byte per write(2) (an Exsecutor runtime
        property, 48,000 syscalls a frame), so the cost is roughly
        proportional. 20 is a starting point, not a measurement.
      '';
    };

    timeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 420;
      description = ''
        Seconds of idle before hypridle starts the screensaver. Must be below
        hypridle's lock timeout (600, home/hyprland/default.nix): the locker
        covers everything, so a screensaver started after it is invisible CPU.
        An assertion in home/hyprland/default.nix enforces this.
      '';
    };

    pixelated = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Upscale the 160x100 frame nearest-neighbour (chunky pixels, the
        intended look). false lets mpv's default scaler smooth it.
      '';
    };

    command = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The generated oligarchy-screensaver command (./script.nix). Read-only.";
    };
  };

  config = lib.mkMerge [
    {
      # Always defined, so home/ can read it without an enable check; it is a
      # derivation and costs nothing until something builds it.
      custom.screensaver.command = pkgs.callPackage ./script.nix {
        somnium = cfg.package;
        inherit (cfg) somnia fps period pixelated;
      };
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.command ];

      # On demand, never at login: no wantedBy. Started by hypridle's
      # listener, stopped by its on-resume and by the DPMS-off listener.
      # The same shape as hyprlock.service in home/hyprland/default.nix, for
      # the same reasons: its own cgroup (stopping it takes somnium and mpv
      # down together, KillMode=control-group), and `systemctl start` on an
      # active unit is a no-op, so a second idle event cannot stack a
      # second screensaver.
      systemd.user.services.oligarchy-screensaver = {
        description = "Exsecutor screensaver (somnium into a fullscreen viewer)";
        after = [ "hyprland-session.target" ];
        partOf = [ "hyprland-session.target" ];
        serviceConfig = {
          Type = "exec";
          ExecStart = "${cfg.command}/bin/oligarchy-screensaver";
          Restart = "no";
          TimeoutStopSec = "5s";
          # It is a screensaver; anything else the machine is doing wins.
          Nice = 10;
          # Render where the compositor renders -- the reasoning on
          # hyprlock.service's identical line in home/hyprland/default.nix.
          UnsetEnvironment = "DRI_PRIME";
        };
      };
    })
  ];
}
