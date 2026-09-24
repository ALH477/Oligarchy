# ═══════════════════════════════════════════════════════════════════════════════
# Captive portal support — hotel / airport / café Wi-Fi logins
# ═══════════════════════════════════════════════════════════════════════════════
# NetworkManager was already enabled, but nixpkgs ships it with NO
# connectivity-check URI, so NM never leaves "full"/"unknown" and never reports
# the "portal" state. Nothing downstream (nm-applet, this watcher) can react to
# a portal it was never told about. Two pieces fix that:
#
#   1. networking.networkmanager.settings.connectivity — gives NM a plain-HTTP
#      probe. A portal intercepts it, the body mismatches, NM flips to PORTAL.
#   2. captive-portal-watch (user service) — follows `nmcli monitor` and, on a
#      transition into PORTAL, notifies and opens a plain-HTTP page so the
#      portal's redirect lands in the default browser. Hyprland has no
#      GNOME-Shell-style portal helper, so without this the state is silent.
#
# Plus `captive-login` on PATH for the manual path (re-check, show DNS state,
# open the page) — for when the watcher is off or a portal slips past the
# probe. With no graphical session it logs in through a text browser (w3m)
# instead. `nmtui-portal` runs nmtui and does the same check when you exit it.
#
# The scripts live in bin/ as plain bash, configured through CAPTIVE_* env
# vars that the wrappers below export, so modules/captive-portal/tests/run.sh
# (the no-KVM gate, `nix build .#captive-portal-tests`) can drive the SAME
# files against a fake nmcli. Keep logic in the scripts, not in the wrappers.
#
# The probe and login URLs MUST be plain http://. HTTPS can't be intercepted
# without a cert error (that's the point of HTTPS), so the redirect never fires.
{ config, lib, pkgs, options, ... }:

let
  cfg = config.custom.network.captivePortal;
  probeUri = "http://${cfg.probe.host}${cfg.probe.path}";
  loginHost = lib.head (lib.splitString "/" (lib.removePrefix "http://" cfg.loginUrl));

  runtimeInputs = with pkgs; [ networkmanager libnotify xdg-utils util-linux coreutils ];

  # One wrapper per script: export the configuration, exec the file.
  wrap = name: extraInputs: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = runtimeInputs ++ extraInputs;
    text = ''
      export CAPTIVE_LOGIN_URL=${lib.escapeShellArg cfg.loginUrl}
      export CAPTIVE_PROBE_URI=${lib.escapeShellArg probeUri}
      export CAPTIVE_OPENER=${lib.escapeShellArg (if cfg.opener == null then "xdg-open" else cfg.opener)}
      export CAPTIVE_TERMINAL_BROWSER=${lib.escapeShellArg (lib.getExe cfg.terminalBrowser)}
      exec ${pkgs.bash}/bin/bash ${./bin + "/${name}.sh"} "$@"
    '';
  };

  watcher = wrap "captive-portal-watch" [ ];
  login = wrap "captive-login" [ pkgs.systemd ];
  nmtuiPortal = wrap "nmtui-portal" [ login ];
in
{
  options.custom.network.captivePortal = {
    enable = lib.mkEnableOption "captive portal detection and auto-open login page" // {
      default = true;
    };

    probe = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "nmcheck.gnome.org";
        description = ''
          Host NetworkManager probes over plain HTTP. Each probe is a request
          to this host from every Oligarchy machine, every `interval` seconds —
          point it at a DeMoD-controlled host (with matching `response`) to
          keep that off a third party.
        '';
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "/check_network_status.txt";
        description = "Path on `probe.host`.";
      };
      response = lib.mkOption {
        type = lib.types.str;
        default = "NetworkManager is online";
        description = "Body the probe URL must START with when not behind a portal.";
      };
      interval = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 300;
        description = "Seconds between idle re-probes. NM also probes on every link change.";
      };
    };

    loginUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://neverssl.com/";
      description = ''
        Plain-HTTP page opened when a portal is detected; the portal hijacks it
        and redirects to its login form. Must be http://, never https://.
      '';
    };

    opener = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = lib.literalExpression ''"''${pkgs.firefox}/bin/firefox"'';
      description = ''
        Command handed the login URL in a graphical session. `null` means
        `xdg-open`, i.e. the user's default browser. The VM gate points this at
        a script that records the URL instead of opening it.
      '';
    };

    terminalBrowser = lib.mkOption {
      type = lib.types.package;
      default = pkgs.w3m;
      defaultText = lib.literalExpression "pkgs.w3m";
      description = ''
        Text-mode browser `captive-login` falls back to when there is no
        graphical session (TTY, SSH, nmtui from a console). Its main program
        is invoked with the login URL.
      '';
    };

    autoOpen = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run the per-user watcher that opens `loginUrl` on detection. Off leaves
        detection on (nm-applet still shows it) and the CLIs on PATH.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.hasPrefix "http://" cfg.loginUrl;
          message = "custom.network.captivePortal.loginUrl must be plain http:// — portals cannot redirect HTTPS.";
        }
        {
          assertion = config.networking.networkmanager.enable;
          message = "custom.network.captivePortal needs networking.networkmanager.enable (the probe is NM's own).";
        }
      ];

      networking.networkmanager.settings.connectivity = {
        enabled = true;
        uri = probeUri;
        response = cfg.probe.response;
        interval = cfg.probe.interval;
      };

      # The watcher is on PATH for debugging (`captive-portal-watch` in a
      # terminal shows the transitions it sees) and for the VM gate.
      environment.systemPackages = [ login nmtuiPortal watcher ];

      systemd.user.services.captive-portal-watch = lib.mkIf cfg.autoOpen {
        description = "Open the captive portal login page when NetworkManager detects one";
        after = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = lib.getExe watcher;
          # nmcli monitor exits when NetworkManager restarts; follow it back up.
          Restart = "always";
          RestartSec = 5;
        };
      };
    }

    # Only matters once strict egress is enforced (it is dry-run today), but a
    # blocked probe reads as "limited" and would hide every portal. Portals on
    # RFC1918 are already admitted by the module's static set; this covers the
    # probe host and the login page's redirect bootstrap. Guarded on the option
    # existing so this module still imports standalone (the VM gate does).
    (lib.optionalAttrs (options.networking.firewall ? strictEgress) {
      networking.firewall.strictEgress.allow.domains = [ cfg.probe.host loginHost ];
    })
  ]);
}
