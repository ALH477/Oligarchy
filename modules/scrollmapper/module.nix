flake: { config, lib, pkgs, options, ... }:

let
  cfg = config.custom.scrollmapper;

  pkg =
    if cfg.package != null
    then cfg.package
    else pkgs.callPackage ./package.nix { translation = cfg.translation; };

  # Source-tree sample — no IFD, no package build at eval time.
  sampleLine =
    let
      raw = builtins.readFile ./sample.tsv;
      parts = lib.splitString "\t" (lib.removeSuffix "\n" raw);
    in
    {
      book = builtins.elemAt parts 0;
      chapter = builtins.elemAt parts 1;
      verse = builtins.elemAt parts 2;
      text = lib.concatStringsSep "\t" (lib.drop 3 parts);
    };

  sampleRef = "${sampleLine.book} ${sampleLine.chapter}:${sampleLine.verse}";

  escapeIssue = s: lib.replaceStrings [ "%" ] [ "%%" ] s;

  bootIntroLine =
    let
      clipped =
        if builtins.stringLength sampleLine.text > 90
        then builtins.substring 0 87 sampleLine.text + "..."
        else sampleLine.text;
    in
    "${sampleRef}  —  ${clipped}";

  hasBootIntro = options.services ? "boot-intro";
  hasGreeting = options.services ? "oligarchyGreeting";
  bootIntroEnabled =
    hasBootIntro && ((config.services.boot-intro.enable or false) == true);
  greetingEnabled =
    hasGreeting && ((config.services.oligarchyGreeting.enable or false) == true);

  binPath = lib.makeBinPath (
    [ pkgs.coreutils pkgs.gnused ]
    ++ lib.optional cfg.bootDialogue.plymouth pkgs.plymouth
  );
in
{
  options.custom.scrollmapper = {
    enable = lib.mkEnableOption "Scrollmapper scripture reader (Orthodox canon default)";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Override the package. When null, built from this module's package.nix for the selected translation.";
    };

    translation = lib.mkOption {
      type = lib.types.enum [ "KJVA" "KJV" "CPDV" "ASV" "BSB" ];
      default = "KJVA";
      description = ''
        Scrollmapper bible_databases translation.
        KJVA is default: public-domain KJV plus the deuterocanon / anagignoskomena.
      '';
    };

    canon = lib.mkOption {
      type = lib.types.enum [ "orthodox" "catholic" "protestant" "full" ];
      default = "orthodox";
      description = "Book filter. Orthodox is the default.";
    };

    wrap = lib.mkOption {
      type = lib.types.ints.positive;
      default = 72;
      description = "Preferred wrap width for the CLI box.";
    };

    aliases = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install short aliases `sm` and `verse`. Off by default to avoid collisions.";
    };

    bootDialogue = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Place a verse in the boot dialogue: Plymouth message, /dev/console,
          /run/scrollmapper, getty issue.d, and boot-intro bottomText when that
          service is enabled.
        '';
      };

      plymouth = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Push the verse through plymouth display-message.";
      };

      console = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Print the verse to /dev/console during sysinit.";
      };

      bootIntro = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "When services.boot-intro.enable, set bottomText (rebuild-stable sample).";
      };
    };

    dailyVerse = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Deterministic calendar-day verse from the curated pool (no 10 MiB JSON on login).";
      };

      onLogin = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Print the daily verse on local interactive bash.";
      };

      notify = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "User-session timer + notify-send.";
      };

      hour = lib.mkOption {
        type = lib.types.ints.between 0 23;
        default = 7;
        description = "Local hour for the user timer.";
      };

      fullCanon = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Hash over the whole installed translation instead of the curated pool.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.package != null || builtins.elem cfg.translation [ "KJVA" "KJV" "CPDV" "ASV" "BSB" ];
          message = "custom.scrollmapper.translation is not packaged.";
        }
      ];

      environment.systemPackages = [ pkg ];

      # Session env only — not dumped into every systemd unit.
      environment.sessionVariables = {
        SCROLLMAPPER_DATA = "${pkg}/share/scrollmapper";
        SCROLLMAPPER_TRANSLATION = cfg.translation;
        SCROLLMAPPER_CANON = cfg.canon;
        SCROLLMAPPER_WRAP = toString cfg.wrap;
      };
    }

    (lib.mkIf cfg.aliases {
      environment.shellAliases = {
        verse = "scrollmapper daily";
        sm = "scrollmapper";
      };
    })

    (lib.mkIf cfg.bootDialogue.enable {
      systemd.services.scrollmapper-boot-dialogue = {
        description = "Scrollmapper verse on the boot dialogue";
        wantedBy = [ "sysinit.target" ];
        after = [ "local-fs.target" ]
          ++ lib.optional cfg.bootDialogue.plymouth "plymouth-start.service";
        before = [
          "plymouth-quit.service"
          "getty.target"
          "display-manager.service"
        ];
        conflicts = [ "shutdown.target" ];
        unitConfig = {
          DefaultDependencies = false;
          SuccessExitStatus = "0 1";
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = 5;
          StandardOutput = "null";
          StandardError = "journal";
          ProtectHome = true;
          ProtectClock = true;
          RestrictSUIDSGID = true;
          # /run and /dev/console must remain writable.
        };
        script = ''
          export PATH="${binPath}"
          export SCROLLMAPPER_BOOT_PLYMOUTH=${if cfg.bootDialogue.plymouth then "1" else "0"}
          export SCROLLMAPPER_BOOT_CONSOLE=${if cfg.bootDialogue.console then "1" else "0"}
          exec ${pkg}/bin/scrollmapper-boot-dialogue
        '';
      };

      environment.etc."issue.d/50-scrollmapper.issue".text = ''

        ${escapeIssue sampleRef}
        ${escapeIssue sampleLine.text}

      '';
    })

    (lib.mkIf (cfg.bootDialogue.enable && cfg.bootDialogue.bootIntro && bootIntroEnabled) {
      services.boot-intro.bottomText = lib.mkDefault bootIntroLine;
    })

    (lib.mkIf (cfg.bootDialogue.enable && greetingEnabled) {
      services.oligarchyGreeting.tips = lib.mkAfter [
        "scrollmapper daily — today's verse (Orthodox canon)"
        "scrollmapper read John 1"
      ];
    })

    (lib.mkIf cfg.dailyVerse.enable {
      programs.bash.interactiveShellInit = lib.mkIf cfg.dailyVerse.onLogin ''
        if [ -z "''${SCROLLMAPPER_DAILY_SHOWN-}" ] && [ -z "''${SSH_CONNECTION-}" ] && [ -t 1 ]; then
          ${pkg}/bin/scrollmapper --canon ${lib.escapeShellArg cfg.canon} --translation ${lib.escapeShellArg cfg.translation} daily ${lib.optionalString (!cfg.dailyVerse.fullCanon) "--pool"}
          export SCROLLMAPPER_DAILY_SHOWN=1
        fi
      '';
    })

    (lib.mkIf (cfg.dailyVerse.enable && cfg.dailyVerse.notify) {
      systemd.user.timers.scrollmapper-daily = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* ${toString cfg.dailyVerse.hour}:00:00";
          Persistent = true;
        };
      };

      systemd.user.services.scrollmapper-daily = {
        description = "Scrollmapper daily verse notification";
        after = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          set -euo pipefail
          text="$(${pkg}/bin/scrollmapper --canon ${lib.escapeShellArg cfg.canon} --translation ${lib.escapeShellArg cfg.translation} daily --plain ${lib.optionalString (!cfg.dailyVerse.fullCanon) "--pool"})"
          mkdir -p "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/scrollmapper"
          printf '%s\n' "$text" > "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/scrollmapper/daily"
          if command -v ${pkgs.libnotify}/bin/notify-send >/dev/null 2>&1; then
            ref=$(printf '%s\n' "$text" | head -n1)
            body=$(printf '%s\n' "$text" | tail -n +2)
            ${pkgs.libnotify}/bin/notify-send --app-name=scrollmapper "Daily verse" "$ref — $body" || true
          fi
        '';
      };
    })
  ]);
}
