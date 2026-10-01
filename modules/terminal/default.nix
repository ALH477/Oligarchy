# ─────────────────────────────────────────────────────────────────────────────
# custom.terminal — the USER terminal and the SYSTEM terminal.
#
# Before this module there was no terminal abstraction at all: "kitty" was
# declared independently in three places — home/home.nix's TERMINAL,
# home/hyprland/default.nix's $terminal, and roughly twenty hardcoded literals
# spread across Nix, bash, Python and an IceWM menu DSL — and there is still no
# XDG terminal registration anywhere in the tree.
#
# The split this introduces:
#
#   user   — the interactive terminal. kitty, unchanged. $mod+Return, the
#            scratchpads, TERMINAL and $terminal all still mean kitty, and
#            .#terminal-contract asserts they do.
#   system — the terminal an ADMIN action pops when it needs a visible window.
#            The canonical case is the GUI path that runs
#            `sudo nixos-rebuild switch`.
#
# Every call site reaches the system terminal through ONE wrapper,
# `oligarchy-system-term`, at a fixed path. That is what lets bash, Nix
# interpolation, Python and an IceWM menu all name the same thing — and it is
# the only form reachable from modules/hypr-controller/hypr_bridge.py, which
# runs as a daemon with no $TERMINAL and today falls through to a literal
# kitty.
#
# Read-write and it spawns processes, so like oligarchy-forge and dsp-ctl it
# stays OUT of the MCP surface.
#
# Opt-in, defaults OFF — but the WRAPPER is unconditional, deliberately.
# custom.terminal.system.package defaults to custom.terminal.user.package, so
# with velocitty disabled this module adds one ~1 KB script over a package
# already in every image (configuration.nix installs kitty), and no unit, no
# timer, no activation script. The ISO therefore needs no `mkForce`. That is a
# weaker claim than gc/mounts/screensaver's "emits nothing when disabled", and
# it is stated weakly on purpose. The alternative — installing the wrapper only
# when enabled — pushes every call site back to a `${VAR:-kitty}` fallback,
# which is exactly the three-way split this module exists to collapse.
#
# The `velocitty` and `nixpkgs-zig` inputs are reached ONLY from
# custom.terminal.velocitty.package's option default (the trick
# modules/screensaver uses for exsecutor), so a host with velocitty off never
# fetches either. See modules/terminal/README.md.
# ─────────────────────────────────────────────────────────────────────────────
{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.custom.terminal;

  # kitty and velocitty agree on every spelling below, which is what makes this
  # abstraction cheap rather than a compatibility layer.
  #
  # The flag NAMES are xdg-terminal-exec's (--app-id/--title/--dir/--hold), so
  # anyone who knows the freedesktop Default Terminal Execution spec already
  # knows this wrapper. `--class` stays an accepted alias: it is what the call
  # sites were first written against, and breaking them to rename a flag would
  # be churn for its own sake.
  # Built by concatenation rather than interpolated into a '' string: getting
  # `''${var}` past two levels of escaping is exactly the kind of thing that
  # silently emits `$${var}` and ships a wrapper that passes a literal.
  optArg = flag: var:
    lib.optionalString (flag != null)
      ("if [ -n \"$" + var + "\" ]; then term+=( "
        + lib.escapeShellArg flag + " \"$" + var + "\" ); fi");

  systemTerm = pkgs.writeShellApplication {
    name = "oligarchy-system-term";
    runtimeInputs = [ ];
    text = ''
      # usage: oligarchy-system-term [--app-id NAME] [--title TEXT] [--dir DIR]
      #                              [--hold] [--] CMD [ARG...]
      #        (--class is an accepted alias for --app-id)
      #
      # --hold keeps the window up after CMD exits, showing its status. It is
      # implemented HERE, in shell, and it has to be. Two terminals, two
      # different silent failures:
      #
      #   * velocitty's argument parser SILENTLY IGNORES flags it does not
      #     know, so `velocitty --hold -e cmd` drops it with no diagnostic and
      #     the window vanishes on the error you wanted to read.
      #   * xdg-terminal-exec would not help either: it honours --hold only
      #     via an X-TerminalArgHold= key in the desktop entry, and when that
      #     key is missing it logs through a `debug` function that is a no-op
      #     unless XTE__DEBUG is set. kitty.desktop declares the key;
      #     velocitty's entry does not.
      #
      # .#terminal-contract asserts that asymmetry so this comment cannot rot.
      app_id=${lib.escapeShellArg cfg.system.defaultClass}
      title=""
      dir=""
      hold=0

      while [ "$#" -gt 0 ]; do
        case "$1" in
          --app-id|--class) app_id="''${2:?$1 needs a value}"; shift 2 ;;
          --app-id=*)       app_id="''${1#--app-id=}"; shift ;;
          --class=*)        app_id="''${1#--class=}"; shift ;;
          --title)          title="''${2:?--title needs a value}"; shift 2 ;;
          --title=*)        title="''${1#--title=}"; shift ;;
          --dir)            dir="''${2:?--dir needs a value}"; shift 2 ;;
          --dir=*)          dir="''${1#--dir=}"; shift ;;
          --hold)           hold=1; shift ;;
          --)               shift; break ;;
          *)                break ;;
        esac
      done

      if [ "$#" -eq 0 ]; then
        echo "oligarchy-system-term: no command given" >&2
        echo "usage: oligarchy-system-term [--app-id NAME] [--title TEXT] [--dir DIR] [--hold] [--] CMD [ARG...]" >&2
        exit 2
      fi

      term=( ${lib.escapeShellArgs ([ (lib.getExe cfg.system.package) ] ++ cfg.system.extraArgs)} )
      ${optArg cfg.system.classFlag "app_id"}
      ${optArg cfg.system.titleFlag "title"}
      ${optArg cfg.system.dirFlag "dir"}
      # The exec flag goes LAST: velocitty's man page requires it ("must be
      # last among options") and kitty behaves the same way. Everything after
      # it is the command, not a terminal option.
      term+=( ${lib.escapeShellArg cfg.system.execFlag} )

      if [ "$hold" -eq 1 ]; then
        # The single quotes below are the point: that is the inner script
        # bash runs INSIDE the terminal, so "$@" and $? must survive this
        # shell unexpanded.
        # shellcheck disable=SC2016
        # Absolute bash: the hold shell runs inside the terminal's child
        # environment, whose PATH is whatever launched the terminal -- a tray
        # daemon or a desktop entry, not a login shell.
        exec "''${term[@]}" ${pkgs.bash}/bin/bash -c \
          '"$@"; rc=$?; echo; printf "-- exit %s, press any key --" "$rc"; read -r -n 1; echo' \
          _ "$@"
      else
        exec "''${term[@]}" "$@"
      fi
    '';
  };
in
{
  options.custom.terminal = {
    user.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.kitty;
      defaultText = lib.literalExpression "pkgs.kitty";
      description = ''
        The interactive terminal. Everything a human opens on purpose —
        $mod+Return, the scratchpads, TERMINAL, Hyprland's $terminal — means
        this. Changing it does NOT change the system terminal.
      '';
    };

    user.desktopId = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.user.package.meta.mainProgram or "kitty"}.desktop";
      defaultText = lib.literalExpression ''"''${config.custom.terminal.user.package.meta.mainProgram}.desktop"'';
      description = ''
        The desktop-file ID that identifies the user terminal to the
        freedesktop Default Terminal Execution spec. Derived rather than typed
        so it cannot become a fourth independent copy of "kitty".

        A wrong value fails SILENTLY -- xdg-terminal-exec falls through to
        scanning every entry with a TerminalEmulator category -- so
        .#terminal-contract checks that the file really exists in the package
        rather than trusting this string. That check lives in the gate, not in
        an assertion: `builtins.pathExists` on a store path would force the
        package to be realised during evaluation, which is import-from-
        derivation and would poison `nix flake show`.
      '';
    };

    system = {
      package = lib.mkOption {
        type = lib.types.package;
        default = cfg.user.package;
        defaultText = lib.literalExpression "config.custom.terminal.user.package";
        description = ''
          The terminal an admin action pops when it needs a visible window.
          Defaults to the user terminal, so with no opt-in the two cannot
          drift and the disabled state is identical to having no module at
          all. custom.terminal.velocitty.enable is what moves it.
        '';
      };

      execFlag = lib.mkOption {
        type = lib.types.str;
        default = "-e";
        description = ''
          The flag after which the command begins. Must be the LAST option the
          terminal is given. kitty and velocitty both document `-e`, and
          velocitty's own desktop entry advertises `X-TerminalArgExec=-e`.
        '';
      };

      classFlag = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "--class";
        description = ''
          The flag that sets the window's WM_CLASS / app-id, or null for a
          terminal that has none. Exists so a terminal spelling it
          `--app-id` is one option change rather than a wrapper rewrite.
        '';
      };

      titleFlag = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "--title";
        description = ''
          The flag that sets the window title, or null for a terminal that has
          none. kitty and velocitty share this spelling, and it is what
          velocitty's own desktop entry advertises as `X-TerminalArgTitle=`.
        '';
      };

      dirFlag = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "--working-directory";
        description = ''
          The flag that sets the child's working directory, or null for a
          terminal that has none. kitty and velocitty share this spelling, and
          it is what velocitty's own desktop entry advertises as
          `X-TerminalArgDir=`.
        '';
      };

      defaultClass = lib.mkOption {
        type = lib.types.str;
        default = "oligarchy-system";
        description = "Window class used when the caller passes no --class.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra options passed to the terminal before the exec flag.";
      };

      command = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = ''
          The `oligarchy-system-term` wrapper. Read-only: it is derived from
          the options above, and it is the single interposition point every
          call site goes through.
        '';
      };
    };

    xdg = {
      enable = lib.mkEnableOption ''
        registering the USER terminal with xdg-terminal-exec, the freedesktop
        Default Terminal Execution spec, so that applications asking the
        desktop for "a terminal" get a declared answer instead of whatever
        scanning the entries happens to turn up first.

        This is orthogonal to custom.terminal.system, not an implementation of
        it: the spec has no notion of a purpose-scoped terminal, so it can name
        the interactive default and nothing else. See modules/terminal/README.md
      '';
    };

    velocitty = {
      enable = lib.mkEnableOption ''
        velocitty as the system terminal — the window a GUI-launched
        `sudo nixos-rebuild switch` draws in. kitty remains the interactive
        default. Velocitty is an X11 client with no Wayland backend, so under
        Hyprland it runs through XWayland
      '';

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./velocitty.nix {
          src = inputs.velocitty;
          # zig 0.16 is in neither of this tree's other nixpkgs pins; see the
          # nixpkgs-zig input comment in flake.nix. Reached from inside this
          # `default` on purpose, so a host with velocitty.enable = false never
          # forces the second nixpkgs to be fetched.
          inherit (inputs.nixpkgs-zig.legacyPackages.${pkgs.stdenv.hostPlatform.system}) zig_0_16;
        };
        defaultText = lib.literalExpression
          "pkgs.callPackage ./velocitty.nix { src = inputs.velocitty; zig_0_16 = from the nixpkgs-zig input; }";
        description = "The velocitty package built from the pinned source input.";
      };
    };
  };

  config = lib.mkMerge [
    {
      custom.terminal.system.command = systemTerm;

      # Unconditional: see the banner. With velocitty off this is a ~1 KB
      # script over the kitty that is already installed.
      environment.systemPackages = [ systemTerm ];
    }

    # The standard path. nixpkgs already ships the module that renders
    # /etc/xdg/[<desktop>-]xdg-terminals.list (nixos/modules/config/xdg/
    # terminal-exec.nix); reimplementing it with environment.etc would be a
    # second copy of a mechanism that is already upstream.
    #
    # `default` is the fallback list; the Hyprland-scoped one is written too
    # because a ${desktop}-prefixed list OUTRANKS the default, so leaving it
    # unset would let a stray one elsewhere in XDG_CONFIG_DIRS win.
    (lib.mkIf cfg.xdg.enable {
      xdg.terminal-exec = {
        enable = true;
        settings = {
          default = [ cfg.user.desktopId ];
          Hyprland = [ cfg.user.desktopId ];
        };
      };
    })

    (lib.mkIf cfg.velocitty.enable {
      custom.terminal.system.package = cfg.velocitty.package;
      environment.systemPackages = [ cfg.velocitty.package ];
    })

    {
      assertions = [
        {
          # The stated contract, in the option set rather than only in prose.
          assertion = cfg.user.package != cfg.velocitty.package;
          message = ''
            custom.terminal.user.package must not be the velocitty package.
            Velocitty is the system/admin terminal (custom.terminal.system.package);
            kitty stays the interactive default.
          '';
        }
        {
          assertion = cfg.system.execFlag != "";
          message = ''
            custom.terminal.system.execFlag must name the flag after which the
            command begins ("-e" for both kitty and velocitty). Empty means the
            command would be parsed as terminal options.
          '';
        }
        {
          assertion = cfg.velocitty.enable -> pkgs.stdenv.hostPlatform.isLinux;
          message = ''
            custom.terminal.velocitty.enable requires Linux: velocitty links
            X11, Xi and xkbcommon and has no other platform backend.
          '';
        }
        {
          # Velocitty has no Wayland backend, and without XWayland the window
          # never appears -- with no error anywhere that names a terminal.
          assertion = (cfg.velocitty.enable && config.programs.hyprland.enable)
            -> config.programs.hyprland.xwayland.enable;
          message = ''
            custom.terminal.velocitty.enable is set on a Hyprland host with
            programs.hyprland.xwayland.enable = false. Velocitty is an X11
            client with no Wayland backend, so every system-terminal window
            would silently fail to appear. Enable XWayland, or leave the system
            terminal as custom.terminal.user.package.
          '';
        }
      ];

      warnings = lib.optional
        (!cfg.velocitty.enable && cfg.system.package != cfg.user.package)
        ''
          custom.terminal.system.package differs from custom.terminal.user.package
          while custom.terminal.velocitty.enable is false — the system terminal is
          something other than the interactive one, and velocitty is not what put
          it there.
        '';
    }
  ];
}
