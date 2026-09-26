# custom.screensaver — an Exsecutor screensaver behind hypridle.
#
# The engine is `somnium` from github:ALH477/exsecutor (the `exsecutor` flake
# input): a program written in Exsecutor with no clock and no entropy source
# of its own, nine effects, one of them the language's own 3D engine turning
# its logo. It reads a request on stdin and writes raw 160x100 rgb24 frames
# on stdout; ./script.nix pipes those into a fullscreen, borderless mpv,
# which scales and presents them on the GPU (mpv's default gpu-next output;
# on the Framework 16, the 780M iGPU the compositor already renders on --
# DRI_PRIME is unset below, see docs/dgpu-steam-forcing.md). Two builds of
# the one source, picked by `backend`: exsc's C backend (default, fast) or
# the freestanding fasmg reference build. What
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

    backend = lib.mkOption {
      type = lib.types.enum [ "c" "reference" ];
      default = "c";
      description = ''
        Which build of the same Exsecutor source runs.

        `c` (default): exsc's C backend with the buffered host
        examples/somnium/hospes.c, compiled with `cflags` -- one write(2) a
        frame, the fast path. `reference`: the freestanding fasmg build, no
        libc, its syscall surface audited to read/write/exit_group, and one
        write(2) per BYTE (48,000 a frame), so markedly slower. Both write
        the same bytes; .#screensaver-tests holds both to exsecutor's goldens.
      '';
    };

    cflags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "-march=x86-64-v3" ]
        ++ lib.optional ((config.custom.platform.cpu or "amd") == "amd") "-mtune=znver4";
      defaultText = lib.literalExpression ''[ "-march=x86-64-v3" ] ++ optional (custom.platform.cpu == "amd") "-mtune=znver4"'';
      description = ''
        Machine flags for the `c` backend. The default targets AVX2-class
        x86-64 (Haswell and Zen 1 onward) and tunes for Zen 4 on AMD hosts --
        the Framework 16's Ryzen 7040. `[ ]` builds a binary for any x86-64.
        Contraction stays off regardless (exsecutor's lib.buildExsecutorCProgram
        pins -ffp-contract=off), so an FMA-capable -march cannot move a
        float effect's bits.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default =
        if cfg.backend == "c"
        then inputs.exsecutor.lib.buildExsecutorCProgram (inputs.exsecutor.lib.somniumCArgs // { inherit (cfg) cflags; })
        else inputs.exsecutor.packages.${system}.somnium;
      defaultText = lib.literalExpression "per `backend`: exsecutor's lib.buildExsecutorCProgram with `cflags`, or packages.somnium";
      description = ''
        The somnium engine. Built by the exsecutor flake: exsc from fasmg,
        then examples/somnium/ through exsc, under exsecutor's pinned nixpkgs.
      '';
    };

    somnia = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.enum [
        "plasma"
        "ignis"
        "vita"
        "pluvia"
        "stellae"
        "cuniculus"
        "abyssus"
        "titulus"
        "signum"
      ]);
      default = [ "pluvia" "titulus" "stellae" "signum" "cuniculus" "abyssus" "plasma" "ignis" "vita" ];
      description = ''
        Effects to cycle through, in order. `plasma` sine plasma; `ignis`
        fire; `vita` Conway's Life coloured by age; `pluvia` digital rain;
        `stellae` warp starfield; `cuniculus` the XOR tunnel in crimson and
        navy; `abyssus` a Mandelbrot deep zoom; `titulus` the title card --
        rain that flies together into OLIGARCHY, then EXSECVTOR PINXIT and
        PVNCTIM CECINIT typed beneath; `signum` the Exsecutor logo turning
        in the starfield, rendered by Exsecutor's own 3D engine. The default
        order lets the rain resolve into the title and the stars lead into
        the logo. One entry runs that effect alone, with no cycling.
      '';
    };

    period = lib.mkOption {
      type = lib.types.ints.positive;
      default = 45;
      description = "Seconds each effect runs when more than one is listed (titulus always plays its 20 s cycle, signum two full turns).";
    };

    fps = lib.mkOption {
      type = lib.types.ints.between 1 60;
      default = 20;
      description = ''
        Frame rate. The viewer plays at this rate and the pipe's
        backpressure paces the engine to it, so this is also the CPU knob.
        The effects' own cost differs by a lot -- the tunnel is two table
        reads a pixel, the Mandelbrot zoom up to 275 iterations, the logo a
        512x512 rasterisation by the 3D engine -- and a frame that takes
        longer than 1/fps simply arrives late (mpv waits for it).
        .#screensaver-tests prints measured frames per second per effect for
        both backends; 20 is a starting point, not a measurement.
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
