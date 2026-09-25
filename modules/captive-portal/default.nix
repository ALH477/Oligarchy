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
#      portal's redirect lands in a browser. Hyprland has no GNOME-Shell-style
#      portal helper, so without this the state is silent. The page is
#      attacker-controlled, so captive-portal-open puts it in a throwaway
#      browser profile (browser.kind), rate-limited (minInterval), never as
#      root.
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
  # Shared with strict-egress: strips user:pass@ and :port, so a loginUrl with
  # a port does not put "host:port" into the egress domain allowlist.
  hostOf = import ../security/url-host.nix { inherit lib; };
  loginHost = hostOf cfg.loginUrl;

  runtimeInputs = with pkgs; [ networkmanager libnotify xdg-utils util-linux coreutils findutils jq systemd ];

  browserBin =
    if cfg.browser.kind == "firefox" then lib.getExe cfg.browser.package
    else if cfg.browser.kind == "chromium" then lib.getExe cfg.browser.package
    else "";

  # One wrapper per script: export the configuration, exec the file.
  wrap = name: extraInputs: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = runtimeInputs ++ extraInputs;
    text = ''
      export CAPTIVE_LOGIN_URL=${lib.escapeShellArg cfg.loginUrl}
      export CAPTIVE_PROBE_URI=${lib.escapeShellArg probeUri}
      export CAPTIVE_TERMINAL_BROWSER=${lib.escapeShellArg (lib.getExe cfg.terminalBrowser)}
      export CAPTIVE_MIN_INTERVAL=${toString cfg.minInterval}
      export CAPTIVE_BROWSER_KIND=${lib.escapeShellArg cfg.browser.kind}
      export CAPTIVE_BROWSER_BIN=${lib.escapeShellArg browserBin}
      export CAPTIVE_BROWSER_CMD=${lib.escapeShellArg (if cfg.browser.command == null then "" else cfg.browser.command)}
      export CAPTIVE_VM_FALLBACK=firefox
      export CAPTIVE_VM_STATUS=/run/captive-portal/vm-status
      exec ${pkgs.bash}/bin/bash ${./bin + "/${name}.sh"} "$@"
    '';
  };

  opener = wrap "captive-portal-open" [ ];
  # The watcher and captive-login reach the launcher by name; its wrapper is
  # a runtime input of theirs, so CAPTIVE_OPENER's default resolves on PATH.
  watcher = wrap "captive-portal-watch" [ opener ];
  login = wrap "captive-login" [ pkgs.systemd opener ];
  nmtuiPortal = wrap "nmtui-portal" [ login ];
in
{
  # Design F: the portal login in a disposable, verified microVM
  # (browser.kind = "microvm"). Everything for it lives in vm/.
  imports = [ ./vm/host.nix ];

  options.custom.network.captivePortal = {
    # Off here like every other feature; configuration.nix turns it on. The
    # module owning a `default = true` was the one exception to the repo's
    # off-by-default convention, and .#captive-portal-contract now asserts it.
    enable = lib.mkEnableOption "captive portal detection and auto-open login page";

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

    browser = {
      kind = lib.mkOption {
        type = lib.types.enum [ "microvm" "firefox" "chromium" "command" "xdg-open" ];
        default = "firefox";
        description = ''
          How the login page is opened in a graphical session. The page is
          attacker-controlled plaintext HTTP, so `firefox` and `chromium`
          open it in a THROWAWAY profile under $XDG_RUNTIME_DIR (no cookies,
          sessions, extensions or history of the everyday browser), the way
          GNOME's portal helper uses a disposable WebKit view. `microvm`
          boots a disposable, verified VM with the login page on its own VT
          (or a passed-through GPU's monitor) and falls back to `firefox` if
          it cannot start; see custom.network.captivePortal.microvm and
          vm/host.nix. `command` runs `browser.command` with the URL and adds
          no isolation; `xdg-open` is the everyday default browser, everyday
          profile — opt in knowingly.
        '';
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = if cfg.browser.kind == "chromium" then pkgs.chromium else pkgs.firefox;
        defaultText = lib.literalExpression "pkgs.firefox, or pkgs.chromium for kind = \"chromium\"";
        description = "Browser used for kind `firefox` or `chromium` (Brave and Ungoogled Chromium are `chromium`).";
      };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Command handed the URL for kind `command`. The VM gate uses a script that records the URL.";
      };
    };

    minInterval = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 60;
      description = ''
        Seconds the watcher waits before opening a second window. A hostile
        gateway can bounce NetworkManager between full and portal at will;
        this bounds it to one window per interval (captive-login still works).
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
          assertion = cfg.browser.kind != "command" || cfg.browser.command != null;
          message = "custom.network.captivePortal.browser.kind = \"command\" needs browser.command.";
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
      environment.systemPackages = [ login nmtuiPortal watcher opener ];

      systemd.user.services.captive-portal-watch = lib.mkIf cfg.autoOpen {
        description = "Open the captive portal login page when NetworkManager detects one";
        after = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
        # No start-rate limit: a NetworkManager that is down for a while
        # would otherwise trip the default 5-in-10s burst and leave this unit
        # failed until the next login, i.e. silently off on the next portal.
        unitConfig.StartLimitIntervalSec = 0;
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
