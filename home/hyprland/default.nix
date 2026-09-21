{ config, pkgs, lib, theme ? { }, features ? { }, osConfig ? { }, ... }:

let
  p = theme;

  # ── GPU targeting: deliberately NO session-wide DRI_PRIME ──────────────────
  # Two rules here, routinely conflated. Both are load-bearing.
  #
  # 1. Never steer Aquamarine's own backend/KMS device (AQ_DRM_DEVICES /
  #    WLR_DRM_DEVICES). The dGPU has no display path to the internal panel;
  #    telling Hyprland's backend to open it as primary is a fatal,
  #    unrecoverable abort with no fallback, not a graceful degrade (confirmed
  #    via coredump: CCompositor::initServer -> throwError -> SIGABRT).
  #    Asserted near the bottom of this file.
  #
  # 2. Never export DRI_PRIME from here either, which is why there is no
  #    gpuEnv binding any more. `env=` in hyprland.conf is session-global: it
  #    reaches every client AND the systemd user manager, so one line put the
  #    entire desktop on the dGPU. eDP-2 hangs off the iGPU, so every frame
  #    then became a cross-device dmabuf import -- visible artifacts and
  #    flicker in Brave, and a dGPU pinned resident at 0% busy that amdgpu
  #    runtime PM could never suspend. docs/dgpu-steam-forcing.md only ever
  #    argued for the PER-APP form, and explicitly calls an ambient session
  #    value a stray to hunt down; this was that stray, in Nix form.
  #
  # dGPU routing is opt-in, per app, via exactly three sanctioned routes:
  #   Steam          -> programs.steam `extraEnv` (configuration.nix)
  #   anything else  -> `dgpu-run <cmd>` (home/scripts/default.nix)
  #   a systemd unit -> `Environment=` on that unit

  # Monitor configuration - auto-detect based on hardware
  # To customize: override monitors.laptop or monitors.desktop in your config
  monitors = {
    laptop = {
      # desc: (EDID-based), not a connector name: eDP-N numbering can shift
      # across kernel/driver updates (this board is currently enumerated as
      # eDP-2, not eDP-1), and Hyprland silently no-ops a monitor rule
      # targeting a name that doesn't exist rather than erroring — so a stale
      # connector name here fails invisibly instead of failing loudly.
      name = "desc:BOE 0x0BC9";
      resolution = "2560x1600@165";
      position = "0x0";
      scale = "1";
    };
    desktop = {
      name = "DP-1";
      resolution = "2560x1440@165";
      position = "0x0";
      scale = "1";
    };
    # Fallback for unknown monitors - uses preferred mode
    fallback = {
      name = "";
      resolution = "preferred";
      position = "0x0";
      scale = "1";
    };
  };

  # First-boot welcome notification.
  # Kept as its own script rather than an inline exec-once: the body is
  # multi-line, and Hyprland's config parser is strictly line-based, so a
  # value containing real newlines emits continuation lines it rejects as
  # invalid config. printf builds the newlines at runtime instead.
  welcomeScript = pkgs.writeShellScript "oligarchy-welcome" ''
    stamp="$HOME/.config/oligarchy/welcome-shown"
    [ -e "$stamp" ] && exit 0
    sleep 5
    ${pkgs.libnotify}/bin/notify-send -t 15000 "Welcome to Oligarchy" \
      "$(printf 'Super+Return: Terminal\nSuper+D: Control Center\nSuper+Space: App Launcher\nSuper+F1: Command Center (incl. Keybinds)\nSuper+Escape: Logout')"
    mkdir -p "$(dirname "$stamp")"
    touch "$stamp"
  '';

  # Determine monitor based on hardware features
  # If hasBattery, assume laptop; otherwise desktop
  # Override in your flake if you have a different setup
  currentMonitor =
    if features.hasBattery or false
    then monitors.laptop
    else monitors.desktop;

  # ── Session resume (custom.session.*, declared in modules/session-resume.nix) ──
  # Read with `or` defaults at every hop, the same way `osConfig.custom.platform`
  # is read in home/scripts/default.nix: home/ has to evaluate on a host — or a
  # fresh clone — where the NixOS module declaring these options is absent, and
  # `osConfig` itself is `{ }` when home.nix is evaluated standalone.
  session = osConfig.custom.session or { };
  autoLogin = session.autoLogin or { };
  restore = session.restore or { };
  restoreOn = restore.enable or false;
  saveInterval = restore.saveInterval or "2min";
  # Whether a boot lock is CONFIGURED. This is the eval-time half of the
  # decision: it only controls whether hypr-boot-lock exists at all. Whether it
  # actually fires is a RUNTIME question, answered by the unit's
  # ConditionEnvironment (see hypr-boot-lock below) — `custom.session.autoLogin`
  # makes greetd log straight in on *boot*, but the very same Hyprland config is
  # what a tuigreet login later in the same boot starts, and there the password
  # has already been asked for.
  lockOnLoginConfigured = (autoLogin.enable or false) && (autoLogin.lockOnLogin or true);

in
{
  wayland.windowManager.hyprland = {
    enable = true;

    # Explicit pin of the HM default: this is what generates
    # hyprland-session.target (BindsTo=graphical-session.target) and a
    # synchronized `dbus-update-activation-environment && systemctl --user
    # stop/start hyprland-session.target` exec-once line, run before anything
    # ordered After=hyprland-session.target. That target is the anchor the
    # supervised services below (waybar, hyprpaper, hypridle, mako, polkit
    # agent) are bound to, replacing the old unordered manual env-import lines.
    systemd = {
      enable = true;
      variables = [ "--all" ];
    };

    # Workspace overview plugin — bound to Super+grave; configured in extraConfig.
    plugins = [ pkgs.hyprlandPlugins.hyprexpo ];

    settings = {
      # Monitor setup
      monitor = "${currentMonitor.name}, ${currentMonitor.resolution}, ${currentMonitor.position}, ${currentMonitor.scale}";

      # Startup applications - optimized, no gnome-keyring
      exec-once = lib.flatten [
        # NOTE: the autologin boot lock is NOT here. exec-once forks and does
        # not wait, so a `systemctl --user start` issued from this list races
        # the target bounce on line 1 of the generated config and could be
        # killed by it. It is the hypr-boot-lock unit below instead.

        # System tray apps
        [ "nm-applet --indicator" "udiskie --automount --notify" ]
        (lib.optional features.hasBluetooth "blueman-applet")

        # Clipboard — text goes through clip-filter (home/scripts/clip-filter.sh)
        # first, which refuses to persist anything secret-shaped (private
        # keys, cloud credential prefixes, JWTs) into cliphist's history.
        # Images aren't text-pattern-filterable, so they go straight through.
        [ "wl-paste --type text --watch clip-filter" ]
        [ "wl-paste --type image --watch cliphist store" ]

        # Directory setup
        [ "mkdir -p ~/.cache/hypr" "mkdir -p ~/Pictures/Screenshots" "mkdir -p ~/Videos/Recordings" "mkdir -p ~/Videos/Replays" ]

        # Initialize theme
        [ "echo '${p.name}' > ~/.cache/hypr/current-palette" ]

        # Ensure XWayland has proper cursor
        [ "sleep 1 && hyprctl setcursor idTech4 24" ]

        # Dropdown scratchpads — pre-spawned hidden on their special workspaces.
        # Off by default (custom.desktopFeatures.enableScratchpads): the
        # scratch-mon one runs htop continuously, a non-obvious idle-resource
        # cost that shouldn't ship on a fresh install.
        (lib.optionals (features.enableScratchpads or false) [
          "[workspace special:term silent] kitty --class scratch-term"
          "[workspace special:notes silent] kitty --class scratch-notes -e nvim ~/Documents/notes.md"
          "[workspace special:mon silent] kitty --class scratch-mon -e htop"
        ])

        # First-boot welcome — essential keybinds shown once on fresh login
        [ "${welcomeScript}" ]
      ];

      # Environment variables - comprehensive for all use cases
      # lib.flatten + lib.optional: the old bare lib.optionals entries nested
      # lists inside the list, which the HM hyprland serializer rejects.
      env = lib.flatten [
        # Qt Theming
        "QT_QPA_PLATFORM,wayland;xcb"
        "QT_QPA_PLATFORMTHEME,qt5ct"
        "QT_STYLE_OVERRIDE,kvantum"
        "QT_WAYLAND_DISABLE_WINDOWDECORATION,1"
        "QT_AUTO_SCREEN_SCALE_FACTOR,1"
        "QT_SCALE_FACTOR_ROUNDING_POLICY,RoundPreferFloor"

        # GTK Theming
        "GTK_THEME,Adwaita:dark"
        "GDK_BACKEND,wayland,x11,*"

        # XDG & Desktop
        "XDG_CURRENT_DESKTOP,Hyprland"
        "XDG_SESSION_TYPE,wayland"
        "XDG_SESSION_DESKTOP,Hyprland"

        # Wayland Native
        "CLUTTER_BACKEND,wayland"
        "SDL_VIDEODRIVER,wayland,x11"
        "MOZ_ENABLE_WAYLAND,1"
        "MOZ_DBUS_REMOTE,1"
        # auto (not x11): NIXOS_OZONE_WL=1 is set system-wide in
        # configuration.nix, and forcing x11 here overrode it back onto
        # XWayland -- a second copy path on top of everything else.
        "ELECTRON_OZONE_PLATFORM_HINT,auto"
        "_JAVA_AWT_WM_NONREPARENTING,1"

        # Cursor
        "XCURSOR_SIZE,24"
        "XCURSOR_THEME,idTech4"
        "HYPRCURSOR_SIZE,24"
        "HYPRCURSOR_THEME,idTech4"

        # Gaming - VRR & Performance (only when gaming enabled)
        (lib.optional (features.enableGaming or false) "STEAM_FORCE_DESKTOPUI_SCALING,1.25")
        (lib.optional (features.enableGaming or false) "__GL_GSYNC_ALLOWED,1")
        (lib.optional (features.enableGaming or false) "__GL_VRR_ALLOWED,1")

        # AMD Gaming
        (lib.optional (features.enableGaming or false) "AMD_VULKAN_ICD,RADV")
        (lib.optional (features.enableGaming or false) "RADV_PERFTEST,gpl")

        # Wine/Proton Gaming
        (lib.optional (features.enableGaming or false) "WINE_FULLSCREEN_FSR,1")
        (lib.optional (features.enableGaming or false) "DXVK_ASYNC,1")
        (lib.optional (features.enableGaming or false) "GAMEMODERUNEXEC,env")

        # SSH
        "SSH_AUTH_SOCK,$XDG_RUNTIME_DIR/gcr/ssh"
      ];

      # Input configuration
      input = {
        kb_layout = "us";
        kb_options = "caps:escape";
        follow_mouse = 1;
        repeat_delay = 300;
        repeat_rate = 50;
        sensitivity = 0;
        accel_profile = "flat";

        touchpad = lib.mkIf (features.hasTouchpad or false) {
          natural_scroll = true;
          "tap-to-click" = true;
          drag_lock = true;
          disable_while_typing = true;
          clickfinger_behavior = true;
        };
      };

      # General settings
      general = {
        gaps_in = 5;
        gaps_out = 10;
        border_size = 2;
        "col.active_border" = "rgba(${lib.removePrefix "#" p.gradientStart}ee) rgba(${lib.removePrefix "#" p.gradientEnd}ee) ${p.gradientAngle}";
        "col.inactive_border" = "rgba(${lib.removePrefix "#" p.border}aa)";
        layout = "dwindle";
        resize_on_border = true;
        extend_border_grab_area = 15;
        hover_icon_on_border = true;
      };

      # Decoration - optimized for performance
      decoration = {
        rounding = 12;
        dim_inactive = true;
        dim_strength = 0.08;
        dim_special = 0.3;

        blur = {
          enabled = true;
          size = 8;
          passes = 3;
          noise = 0.02;
          vibrancy = 0.2;
          popups = true;
          special = true;
        };

        shadow = {
          enabled = true;
          range = 12;
          render_power = 3;
          color = "rgba(00000055)";
          color_inactive = "rgba(00000033)";
          offset = "0 4";
        };
      };

      # Animations - smooth and responsive
      animations = {
        enabled = true;
        bezier = [
          "fluent, 0.05, 0.9, 0.1, 1.05"
          "bounce, 0.68, -0.55, 0.265, 1.55"
          "smooth, 0.25, 0.1, 0.25, 1"
          "snappy, 0.4, 0, 0.2, 1"
        ];
        animation = [
          "windows, 1, 4, fluent, slide"
          "windowsIn, 1, 4, bounce, slide"
          "windowsOut, 1, 3, snappy, slide"
          "windowsMove, 1, 3, smooth"
          "border, 1, 10, default"
          "borderangle, 1, 100, smooth, loop"
          "fade, 1, 4, smooth"
          "fadeDim, 1, 4, smooth"
          "workspaces, 1, 4, fluent, slidevert"
          "specialWorkspace, 1, 4, bounce, slidevert"
          "layers, 1, 3, snappy, fade"
        ];
      };

      # Dwindle layout
      dwindle = {
        pseudotile = true;
        preserve_split = true;
        force_split = 2;
        smart_resizing = true;
        special_scale_factor = 0.92;
      };

      # Master layout
      master = {
        new_status = "master";
        mfact = 0.55;
      };

      # Misc optimizations
      misc = {
        force_default_wallpaper = 0;
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        mouse_move_enables_dpms = true;
        key_press_enables_dpms = true;
        vfr = true;
        # VRR is OFF on purpose. With vrr = 1 (always on) the Framework 16's
        # BOE panel flickers stale buffers / the wallpaper through windows the
        # moment vfr lets the frame rate fall under the panel's LFC floor —
        # visible on the desktop and fatal in games. Confirmed live via
        # `hyprctl keyword misc:vrr 0`, which stopped it immediately. Do not
        # set 2 (fullscreen-only) either: games are exactly where it bites.
        vrr = 0;
        enable_swallow = true;
        swallow_regex = "^(kitty|foot)$";
        focus_on_activate = true;
      };

      # XWayland Configuration
      xwayland = {
        force_zero_scaling = true;
        use_nearest_neighbor = false;
      };

      # Cursor Configuration
      cursor = {
        # Hardware cursors are smooth on aquamarine/AMD; forcing software
        # cursors caused stutter under load.
        no_hardware_cursors = false;
        no_break_fs_vrr = true;
        min_refresh_rate = 60;
        hotspot_padding = 0;
        inactive_timeout = 5;
        hide_on_key_press = true;
        hide_on_touch = true;
        enable_hyprcursor = true;
        sync_gsettings_theme = true;
      };

      # Touchpad workspace swipe — Hyprland ≥ 0.51 syntax. The old
      # gestures:workspace_swipe_* options were removed upstream and now
      # hard-fail config parsing; the unified `gesture` keyword replaces them.
      gesture = lib.optionals (features.hasTouchpad or false) [
        "3, horizontal, workspace"
      ];

      # Workspace bindings
      binds = {
        workspace_back_and_forth = true;
        allow_workspace_cycles = true;
      };

      # Variable definitions
      "$mod" = "SUPER";
      "$terminal" = "kitty";
      "$menu" = "wofi --show drun -I";
      "$browser" = "brave";

      # Keybindings - complete set (flattened: lib.optional entries nest lists)
      bind = lib.flatten [
        # Help & Core
        "$mod, F1, exec, $terminal -e oligarchy"
        "$mod, Return, exec, $terminal"
        "$mod SHIFT, Return, exec, $terminal --class floating-term"

        # App launchers
        "$mod, Space, exec, $menu"
        "$mod, D, exec, oligarchy-menu" # unified control center (was a duplicate drun)
        "$mod, B, exec, $browser"
        "$mod, E, exec, thunar"
        (lib.optional (features.enableDev or false) "$mod, C, exec, code")
        (lib.optional (features.enableDev or false) "$mod, O, exec, obsidian")
        (lib.optional (features.enableDev or false) "$mod SHIFT, T, exec, terminus")

        # Window management
        "$mod, Q, killactive"
        "$mod SHIFT, Q, exec, hyprctl kill"
        "$mod, W, togglefloating"
        "$mod, F, fullscreen, 0"
        "$mod SHIFT, F, fullscreen, 1"
        "$mod, P, pseudo"
        "$mod, X, togglesplit"
        "$mod, G, togglegroup"
        "$mod, Tab, changegroupactive, f"
        "$mod SHIFT, Tab, changegroupactive, b"
        "$mod SHIFT, C, centerwindow"
        "$mod SHIFT, P, pin"

        # Window navigation
        "$mod, H, movefocus, l"
        "$mod, L, movefocus, r"
        "$mod, K, movefocus, u"
        "$mod, J, movefocus, d"
        "$mod, left, movefocus, l"
        "$mod, right, movefocus, r"
        "$mod, up, movefocus, u"
        "$mod, down, movefocus, d"

        # Move windows
        "$mod SHIFT, H, movewindow, l"
        "$mod SHIFT, L, movewindow, r"
        "$mod SHIFT, K, movewindow, u"
        "$mod SHIFT, J, movewindow, d"

        "$mod, U, focusurgentorlast"

        # Workspaces
        "$mod, 1, workspace, 1"
        "$mod, 2, workspace, 2"
        "$mod, 3, workspace, 3"
        "$mod, 4, workspace, 4"
        "$mod, 5, workspace, 5"
        "$mod, 6, workspace, 6"
        "$mod, 7, workspace, 7"
        "$mod, 8, workspace, 8"
        "$mod, 9, workspace, 9"
        "$mod, 0, workspace, 10"

        # Move to workspaces
        "$mod SHIFT, 1, movetoworkspace, 1"
        "$mod SHIFT, 2, movetoworkspace, 2"
        "$mod SHIFT, 3, movetoworkspace, 3"
        "$mod SHIFT, 4, movetoworkspace, 4"
        "$mod SHIFT, 5, movetoworkspace, 5"
        "$mod SHIFT, 6, movetoworkspace, 6"
        "$mod SHIFT, 7, movetoworkspace, 7"
        "$mod SHIFT, 8, movetoworkspace, 8"
        "$mod SHIFT, 9, movetoworkspace, 9"
        "$mod SHIFT, 0, movetoworkspace, 10"

        # Workspace overview (hyprexpo). grave was a redundant "workspace previous"
        # — back_and_forth + the e-1/e+1 binds already cover that.
        "$mod, grave, hyprexpo:expo, toggle"
        "$mod, bracketleft, workspace, e-1"
        "$mod, bracketright, workspace, e+1"

        # Scratchpads — generic + three dropdowns
        "$mod, S, togglespecialworkspace, scratchpad"
        "$mod SHIFT, S, movetoworkspace, special:scratchpad"
        "$mod, T, togglespecialworkspace, term"
        "$mod, Y, togglespecialworkspace, notes"
        "$mod, I, togglespecialworkspace, mon"

        # Keyboard resize — quick nudge + sustained submap (Super+Z)
        "$mod CTRL, left, resizeactive, -40 0"
        "$mod CTRL, right, resizeactive, 40 0"
        "$mod CTRL, up, resizeactive, 0 -40"
        "$mod CTRL, down, resizeactive, 0 40"
        "$mod, Z, submap, resize"

        # Caffeine — toggle idle inhibition
        "$mod, F10, exec, caffeine toggle"

        # Screenshots
        ", Print, exec, ~/.config/hypr/scripts/screenshot.sh screen"
        "$mod, Print, exec, ~/.config/hypr/scripts/screenshot.sh window"
        "SHIFT, Print, exec, ~/.config/hypr/scripts/screenshot.sh region"
        "$mod SHIFT, Print, exec, ~/.config/hypr/scripts/screenshot.sh region-edit"
        "$mod SHIFT, X, exec, hyprpicker -a -n"

        # Screen Recording
        "$mod, R, exec, ~/.config/hypr/scripts/record.sh toggle"
        "$mod SHIFT, R, exec, ~/.config/hypr/scripts/record.sh save-replay"
        "$mod ALT, R, exec, ~/.config/hypr/scripts/record.sh region"
        "$mod CTRL, R, exec, ~/.config/hypr/scripts/record.sh replay-toggle"

        # Clipboard
        "$mod, V, exec, clipboard-picker"

        # Session
        "$mod, Escape, exec, wlogout -p layer-shell"
        "$mod CTRL, L, exec, systemctl --user start --no-block hyprlock.service"
        "$mod SHIFT, Escape, exit"

        # Theme switching
        "$mod, F8, exec, ~/.config/hypr/scripts/theme-switch.sh toggle"
        "$mod SHIFT, F8, exec, ~/.config/hypr/scripts/theme-switch.sh gui"

        # Resolution cycling
        "$mod, F5, exec, ~/.config/hypr/scripts/resolution-cycle.sh"

        # Display scale cycling (1x / 1.25x / 1.5x) — live via hyprctl, no
        # rebuild; reverts to the static per-monitor scale above on reload.
        "$mod, F6, exec, scale-cycle"

        # Window layout save/restore (persona-layout) — previously only
        # reachable two menu hops deep in oligarchy-ctl's persona category;
        # it's functionally distinct from persona switching, so it gets its
        # own direct keybind.
        "$mod, F3, exec, persona-layout restore"
        "$mod SHIFT, F3, exec, persona-layout save"

        # Session save/restore (hypr-session) — the launching counterpart of
        # F3. F3 only MOVES windows that are already open; F4 records each
        # window's argv/cwd and starts the programs again, so it is what brings
        # a session back after a reboot. Bound unconditionally: the script is
        # always installed, and custom.session.restore.enable only controls
        # whether systemd drives it on its own.
        "$mod, F4, exec, hypr-session restore"
        "$mod SHIFT, F4, exec, hypr-session save"

        # System
        "$mod, M, exec, gnome-system-monitor"
        "$mod, equal, exec, gnome-calculator"
        "$mod, F2, exec, $terminal --class warroom -e oligarchy-warroom"
        "$mod SHIFT, Delete, exec, panic"

        # Battery/sleep (laptop only)
        (lib.optional (features.hasBattery or false) "$mod, F12, exec, ~/.config/hypr/scripts/lid.sh toggle")

        # DCF (DeMoD Communication Framework) — moved off Super+D (now the control center)
        (lib.optional (features.enableDCF or false) "$mod SHIFT, D, exec, $terminal --title 'DCF Control' -e dcf-control")

        # Gaming - Full support
        (lib.optional (features.enableGaming or false) "$mod, F9, exec, ~/.config/hypr/scripts/gamemode.sh toggle")
        (lib.optional (features.enableGaming or false) "$mod SHIFT, F9, exec, mangohud --dlsym")

        # Media keybindings
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioPause, exec, playerctl play-pause"
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPrev, exec, playerctl previous"
        ", XF86AudioStop, exec, playerctl stop"
        "$mod, N, exec, playerctl previous"
        "$mod, COMMA, exec, playerctl next"

        # Audio / DSP cockpit — Super+A enters the submap; quick I/O cycling direct
        "$mod, A, submap, audio"
        "$mod, period, exec, audio-dev next sink"
        "$mod SHIFT, period, exec, audio-dev next source"
        # Quick-access system commands
        "$mod SHIFT, U, exec, oligarchy-update"
        "$mod CTRL, S, exec, oligarchy-security status"
      ];

      # Volume/Brightness (with waybar reload)
      # Volume/brightness via swayosd (on-screen display). Waybar's wireplumber
      # module updates itself, so the old `pkill -HUP waybar` is gone.
      binde = [
        ", XF86AudioRaiseVolume, exec, swayosd-client --output-volume raise --max-volume 100"
        ", XF86AudioLowerVolume, exec, swayosd-client --output-volume lower"
        ", XF86AudioMute, exec, swayosd-client --output-volume mute-toggle"
      ] ++ lib.optionals (features.hasBacklight or false) [
        ", XF86MonBrightnessUp, exec, swayosd-client --brightness raise"
        ", XF86MonBrightnessDown, exec, swayosd-client --brightness lower"
      ];

      # Mouse bindings
      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];

      # Window rules - comprehensive
      windowrulev2 = [
        # Floating windows
        "float, class:^(pavucontrol|blueman-manager|nm-connection-editor|gnome-calculator|gnome-system-monitor)$"
        "float, class:^(thunar)$, title:^(File Operation|Confirm).*$"
        "float, title:^(Open|Save|Export|Import|Choose|Select|Preferences|Settings|Properties|About).*$"
        "float, class:^(floating-term)$"
        "size 1000 700, class:^(floating-term)$"
        "center, class:^(floating-term)$"
        "animation slide, class:^(floating-term)$"

        # Tool windows
        "float, title:^(Thermal Status|DCF Control|DCF Logs|AI Stack)$"
        "size 650 500, title:^(Thermal Status|DCF Control|DCF Logs|AI Stack)$"
        "center, title:^(Thermal Status|DCF Control|DCF Logs|AI Stack)$"

        # Dropdown scratchpads (term / notes / monitor)
        "float, class:^(scratch-term|scratch-notes|scratch-mon)$"
        "size 65% 60%, class:^(scratch-term|scratch-notes|scratch-mon)$"
        "center, class:^(scratch-term|scratch-notes|scratch-mon)$"

        # PiP support
        "float, title:^(Picture.in.[Pp]icture)$"
        "pin, title:^(Picture.in.[Pp]icture)$"
        "keepaspectratio, title:^(Picture.in.[Pp]icture)$"
        "size 480 270, title:^(Picture.in.[Pp]icture)$"
        "move 100%-490 100%-280, title:^(Picture.in.[Pp]icture)$"
        "nodim, title:^(Picture.in.[Pp]icture)$"

        # Workspace assignments
        "workspace 2, class:^(Code|code-url-handler)$"
        "workspace 3, class:^(obsidian)$"
        "workspace 5, class:^(thunderbird|discord)$"
        # No `silent`: launching Steam used to dump it on ws 9 without
        # switching, so the click looked like a no-op. Follow the client.
        "workspace 9, class:^(steam)$"
        "float, class:^(steam)$, title:^(Friends|Settings|Screenshot).*$"

        # Gaming - Steam
        "float, class:^(steam)$, title:^(Steam Settings)$"
        "float, class:^(steam)$, title:^(Steam - News).*$"
        "float, class:^(steam)$, title:^(.*Steam Guard.*)$"
        "stayfocused, class:^(steam)$, title:^()$"
        "minsize 1 1, class:^(steam)$, title:^()$"

        # Gaming - Lutris
        "workspace 9 silent, class:^(lutris)$"
        "float, class:^(lutris)$, title:^(Lutris)$"

        # Gaming - GameScope (fullscreen compositor)
        "fullscreen, class:^(gamescope)$"
        "immediate, class:^(gamescope)$"
        "noblur, class:^(gamescope)$"
        "noshadow, class:^(gamescope)$"

        # Gaming - Wine/Proton (immediate rendering, no effects)
        # Do not force fullscreen: that double-fullscreens games that already
        # set their own mode and also catches Proton config/overlay windows.
        "immediate, class:^(steam_app_.*)$"
        "noblur, class:^(steam_app_.*)$"
        "noshadow, class:^(steam_app_.*)$"
        "idleinhibit always, class:^(steam_app_.*)$"

        # Generic game windows
        "immediate, class:^(.*[Gg]ame.*)$"
        "idleinhibit always, class:^(.*[Gg]ame.*)$"
        "idleinhibit always, fullscreen:1"

        # Wine
        "float, class:^(wine)$"
        "float, class:^(.*.exe)$"
        "float, class:^(explorer.exe)$"
        "noinitialfocus, class:^(steam)$, title:^(notificationtoasts)$"

        # XWayland - proper rendering and focus
        "rounding 8, xwayland:1"
        "forcergbx, xwayland:1"

        # XWayland apps
        "float, class:^(Gimp.*)$, title:^((?!GNU Image).*)$"
        "float, class:^(feh)$"
        "float, class:^(mpv)$"
        "idleinhibit always, class:^(mpv)$"

        # Visual - opacity
        "opacity 0.95 0.88, class:^(kitty)$"
        "opacity 0.95 0.90, class:^(Code)$"
        "opacity 1.0 override, fullscreen:1"
        "noborder, fullscreen:1"
        "idleinhibit fullscreen, class:^(brave-browser|firefox|mpv|vlc)$"
      ];
    };

    # Extra configuration
    extraConfig = ''
      workspace = 1, default:true
      workspace = special:scratchpad, gapsout:60, gapsin:20
      workspace = special:term,  gapsout:60, gapsin:20
      workspace = special:notes, gapsout:60, gapsin:20
      workspace = special:mon,   gapsout:60, gapsin:20

      # Keyboard resize submap — enter with Super+Z, exit with Esc/Enter.
      submap = resize
      binde = , right, resizeactive, 40 0
      binde = , left,  resizeactive, -40 0
      binde = , up,    resizeactive, 0 -40
      binde = , down,  resizeactive, 0 40
      binde = , l, resizeactive, 40 0
      binde = , h, resizeactive, -40 0
      binde = , k, resizeactive, 0 -40
      binde = , j, resizeactive, 0 40
      bind = , escape, submap, reset
      bind = , return, submap, reset
      submap = reset

      # Audio / DSP cockpit submap — enter with Super+A, exit with Esc/Enter.
      # waybar shows "audio" while it's active.
      submap = audio
      bind = , o, exec, audio-dev next sink
      bind = SHIFT, o, exec, audio-dev menu sink
      bind = , i, exec, audio-dev next source
      bind = SHIFT, i, exec, audio-dev menu source
      bind = , m, exec, audio-dev mute sink
      bind = SHIFT, m, exec, audio-dev mute source
      bind = , bracketright, exec, dsp-quantum up
      bind = , bracketleft,  exec, dsp-quantum down
      bind = , r, exec, dsp-rig next
      bind = SHIFT, r, exec, oligarchy-menu
      bind = , d, exec, dsp-arm toggle
      bind = , e, exec, easyeffects
      bind = , g, exec, qpwgraph
      bind = , h, exec, helvum
      bind = , escape, submap, reset
      bind = , return, submap, reset
      submap = reset

      # Workspace overview (hyprexpo plugin) — bound to Super+grave.
      plugin {
        hyprexpo {
          columns = 3
          gap_size = 6
          bg_col = rgb(1a1b26)
          workspace_method = center current
          enable_gesture = true
          gesture_fingers = 4
          gesture_distance = 300
          gesture_positive = true
        }
      }
    '' + lib.optionalString (features.hasBattery or false) ''
      bindl = , switch:Lid Switch, exec, ~/.config/hypr/scripts/lid.sh close
      bindl = , switch:off:Lid Switch, exec, ~/.config/hypr/scripts/lid.sh open
    '';
  };

  # Guards against regressing the documented dGPU-backend-SIGABRT hazard
  # (see the GPU targeting comment at the top of this file, and
  # docs/dgpu-steam-forcing.md): turns the
  # comment-only warning into a build-time check.
  assertions = [{
    # Also reject session-wide DRI_PRIME: `env=` in hyprland.conf lands in the
    # systemd user manager's environment, so every user unit (hyprlock
    # included) silently inherited it and rendered on the dGPU -- the
    # flicker/pinned-awake/TTM-shutdown-wedge class documented in
    # docs/dgpu-steam-forcing.md. dGPU offload is opt-in per app only
    # (steam extraEnv / dgpu-run / per-unit Environment=).
    assertion = !(lib.any
      (v: lib.hasPrefix "AQ_DRM_DEVICES," v || lib.hasPrefix "WLR_DRM_DEVICES," v
        || lib.hasPrefix "DRI_PRIME," v)
      (lib.flatten (config.wayland.windowManager.hyprland.settings.env or [])));
    message = "Do not set AQ_DRM_DEVICES/WLR_DRM_DEVICES toward the dGPU (no display path, fatal SIGABRT) nor a session-wide DRI_PRIME (whole desktop on dGPU; hyprlock TTM wedge; dGPU pinned awake). Offload is opt-in per-app. See docs/dgpu-steam-forcing.md.";
  }];

  # Session daemon supervision — bound to hyprland-session.target (see the
  # `systemd` block above). Previously these were unsupervised exec-once
  # commands: if any one failed a transient startup race, Hyprland reported
  # "running" but the session was visibly broken (no bar/wallpaper/idle-lock/
  # notifications/polkit prompts) with nothing to retry it. Restart=on-failure
  # + PartOf/After=hyprland-session.target fixes both the recovery and the
  # lifecycle (they die cleanly when Hyprland exits instead of lingering).
  systemd.user.services =
    let
      mkSessionService = { description, execStart }: {
        Unit = {
          inherit description;
          After = [ "hyprland-session.target" ];
          PartOf = [ "hyprland-session.target" ];
          StartLimitIntervalSec = 60;
          StartLimitBurst = 5;
        };
        Service = {
          ExecStart = execStart;
          Restart = "on-failure";
          RestartSec = 2;
          # Nothing here is worth 90s of a shutdown. The default let one stuck
          # child (hyprlock, in hypridle's cgroup) burn 90s here and then a
          # further 2min+2min in user@1000 -- a 3m44s poweroff.
          TimeoutStopSec = "10s";
        };
        Install.WantedBy = [ "hyprland-session.target" ];
      };
    in
    {
      hyprpaper = mkSessionService {
        description = "Hyprland wallpaper daemon";
        execStart = "${pkgs.hyprpaper}/bin/hyprpaper";
      };
      hypridle = mkSessionService {
        description = "Hyprland idle daemon (dim/lock/suspend ladder)";
        execStart = "${pkgs.hypridle}/bin/hypridle";
      };
      # The locker is deliberately NOT a mkSessionService: it has no
      # Install.WantedBy because it is started on demand, and it must not be
      # `Restart`ed. Two reasons it is a unit at all rather than a bare command:
      #
      #  - It gets its own cgroup. Spawned as hypridle's child it inherited
      #    hypridle's (KillMode=control-group), so a hyprlock stuck in an
      #    uninterruptible amdgpu ioctl held hypridle's stop, then user@1000's.
      #  - `systemctl start` on an active unit is a no-op, which is what
      #    `pidof hyprlock || hyprlock` was reaching for and got wrong: pidof
      #    also matches a hyprlock that is present but dead, and then the lock
      #    is silently SKIPPED. That happened three times in one day.
      #
      # `grace` is an ExecStart flag because hyprlock 0.9.x removed the config
      # key; see the comment in home/apps/hyprlock.nix.
      hyprlock = {
        Unit = {
          Description = "Hyprland screen locker";
          After = [ "hyprland-session.target" ];
          PartOf = [ "hyprland-session.target" ];
        };
        Service = {
          Type = "exec";
          ExecStart = "${pkgs.hyprlock}/bin/hyprlock --grace 3";
          Restart = "no";
          TimeoutStopSec = "5s";
          KillMode = "mixed";
          # REGRESSION GUARD, not the active fix. The session-wide
          # `env=DRI_PRIME` this defended against is gone (see the GPU
          # targeting comment at the top of this file), so on a correct
          # config there is nothing here to unset. It stays because the
          # failure it caught was expensive and silent: `env=` in
          # hyprland.conf also lands in the systemd user manager's
          # environment, so every user unit silently inherited DRI_PRIME and
          # every hyprlock in the journal was on the dGPU (amdgpu
          # 0000:03:00.0). A full-screen blur on the dGPU over a dmabuf the
          # compositor produced on the iGPU is a cross-device import, which
          # dragged it into TTM buffer migration (ttm_bo_move_memcpy ->
          # amdgpu_bo_move) and wedged it there uninterruptibly. The locker
          # renders where the COMPOSITOR renders, not where games do. Unset
          # rather than pin: Mesa's default is already the compositor's
          # device, and this stays correct on iGPU-only hosts.
          UnsetEnvironment = "DRI_PRIME";
        };
      };
      mako = mkSessionService {
        description = "Mako notification daemon";
        execStart = "${config.services.mako.package}/bin/mako";
      };
      polkit-gnome-authentication-agent-1 = mkSessionService {
        description = "polkit-gnome authentication agent";
        execStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
      };
      # The last remaining unsupervised exec-once daemon — moved here for the
      # same reason as the four above (see comment block at the top).
      swayosd-server = mkSessionService {
        description = "swayosd on-screen display daemon";
        execStart = "${pkgs.swayosd}/bin/swayosd-server";
      };
    }
    # ── Autologin boot lock (custom.session.autoLogin.lockOnLogin) ──────────
    # Under autologin there is no greeter asking for a password, so an unlocked
    # desktop must never be on screen even for a frame. LUKS is the real gate on
    # this machine (whole-disk); this is what keeps the post-boot desktop from
    # being handed to whoever pressed the power button.
    #
    # Three things here are deliberate and each was a real defect:
    #
    #  - A UNIT, not an exec-once. Line 1 of the config Home Manager generates
    #    is `dbus-update-activation-environment --systemd --all && systemctl
    #    --user stop hyprland-session.target && systemctl --user start
    #    hyprland-session.target`. exec-once entries fork and are NOT
    #    sequenced against each other, so a `systemctl --user start
    #    hyprlock.service` from this list could land BEFORE that `stop`, and
    #    the stop then tore the locker down again through
    #    PartOf=hyprland-session.target -- with no Install and Restart=no,
    #    nothing brought it back, and the session restore ordered
    #    After=hyprlock.service against a job that no longer existed. Bound to
    #    the target instead, it is part of the same transaction as everything
    #    else in the session and can be ordered Before= them.
    #
    #  - `--grace 0`, NOT the shared hyprlock.service. That unit carries
    #    `--grace 3`: for three seconds any keypress or >5px pointer move
    #    dismisses the lock with no password. That is correct for an IDLE lock
    #    (you walked away, you came back, you moved the mouse) and completely
    #    wrong for a boot lock, where the whole point is that the person at the
    #    keyboard has not authenticated yet. Hence a second unit rather than a
    #    reuse; hypridle's lock_cmd still points at hyprlock.service.
    #
    #  - ConditionEnvironment, not the eval-time flag alone. `custom.session.
    #    autoLogin` only describes greetd's INITIAL session; the identical
    #    Hyprland config is also what a tuigreet login later in the same boot
    #    starts, and locking there would demand the password the user just
    #    typed. The two are indistinguishable from inside the session (loginctl
    #    reports Service=greetd for both), so session-resume.nix sets
    #    OLIGARCHY_AUTOLOGIN=1 on greetd's initial_session command only.
    #    Hyprland inherits it, and HM's line-1 `dbus-update-activation-
    #    environment --systemd --all` imports it into the user manager before
    #    the target starts -- which is exactly when this condition is
    #    evaluated. ExecStartPost then unsets it from the manager, so a logout
    #    and greeter re-login in the same boot does not lock again.
    //
    lib.optionalAttrs lockOnLoginConfigured {
      hypr-boot-lock = {
        Unit = {
          Description = "Lock the screen on autologin boot (no grace period)";
          After = [ "hyprland-session.target" ];
          PartOf = [ "hyprland-session.target" ];
          # Nothing that paints may start before the locker is up. Type=exec
          # below is what makes this ordering mean anything: without it the
          # unit is "started" as soon as fork() returns, before hyprlock has a
          # surface.
          Before = [ "waybar.service" "hyprpaper.service" "mako.service" ]
          ++ lib.optional restoreOn "hypr-session-restore.service";
          ConditionEnvironment = "OLIGARCHY_AUTOLOGIN=1";
        };
        Service = {
          Type = "exec";
          ExecStart = "${pkgs.hyprlock}/bin/hyprlock --grace 0";
          # `-` because failing to unset must never fail the lock.
          ExecStartPost = "-${pkgs.systemd}/bin/systemctl --user unset-environment OLIGARCHY_AUTOLOGIN";
          Restart = "no";
          TimeoutStopSec = "5s";
          KillMode = "mixed";
          # Same regression guard as hyprlock.service above -- see the long
          # comment there. The locker renders where the COMPOSITOR renders.
          UnsetEnvironment = "DRI_PRIME";
        };
        Install.WantedBy = [ "hyprland-session.target" ];
      };
    }
    # ── Session resume (custom.session.restore.enable) ───────────────────────
    # lib.optionalAttrs, not lib.mkIf: this whole binding is a plain attrset
    # built in a `let`, so mkIf would land inside an attribute value rather
    # than on the option.
    //
    lib.optionalAttrs restoreOn {
      # Neither of these is a mkSessionService: they are oneshots, and
      # Restart=on-failure on a oneshot that legitimately finds nothing to do
      # is a restart loop.
      #
      # PATH is set explicitly rather than inherited: the user manager's
      # environment comes from whatever `systemctl --user import-environment`
      # happened to pick up, and a restore that silently found no hyprctl
      # looks exactly like a restore with nothing to restore. Per-user profile
      # first so hyprctl is the one Home Manager installed, i.e. the same
      # build as the running compositor. JQ is pinned to the store outright —
      # the script honours $JQ/$HYPRCTL with PATH as the fallback.
      hypr-session-restore = {
        Unit = {
          Description = "Relaunch the previous Hyprland window set";
          # No snapshot yet (first ever login, or the file was cleared) is not
          # a failure. Without this the unit exits non-zero on that first boot
          # and sits `failed` for the whole session, which is indistinguishable
          # at a glance from a restore that genuinely broke.
          ConditionPathExists = "%h/.config/oligarchy/session/last.json";
          After = [ "hyprland-session.target" ]
          ++ lib.optional lockOnLoginConfigured "hypr-boot-lock.service";
          # Requires, not just After: if hyprlock fails to start in the
          # autologin session, the bar and wallpaper may as well come up, but
          # the previous window set must NOT be relaunched onto an unlocked
          # desktop. A boot-lock whose ConditionEnvironment declined (a greeter
          # login) counts as satisfied, so this only bites on a real failure.
          Requires = lib.optional lockOnLoginConfigured "hypr-boot-lock.service";
          PartOf = [ "hyprland-session.target" ];
        };
        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          Environment = [
            "PATH=%h/.local/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
            "JQ=${pkgs.jq}/bin/jq"
          ];
          ExecStart = "%h/.local/bin/hypr-session restore";
          # Deliberately NO ExecStop. A save-on-stop looks like free insurance
          # and is actively harmful: the unit is RemainAfterExit, so the one
          # case where the stop CAN reach a live compositor -- `systemctl
          # --user restart hypr-session-restore`, the obvious way to re-run a
          # restore by hand -- saves the desktop that is currently on screen
          # and then immediately relaunches all of it, doubling every window
          # (RemainAfterExit means `restart` really does run the stop half).
          # ($mod+F4 dodges this only because it calls `hypr-session restore`
          # directly rather than going through the unit.) On a
          # real logout the stop cannot succeed anyway (the target is stopped
          # because the compositor already exited, so `hyprctl clients -j` has
          # no socket). The timer below is the protection, and it is the only
          # thing that survives a crash, a power cut or an OOM kill.
        };
        Install.WantedBy = [ "hyprland-session.target" ];
      };

      hypr-session-save = {
        Unit = {
          Description = "Snapshot the current Hyprland window set";
          After = [ "hyprland-session.target" ];
          PartOf = [ "hyprland-session.target" ];
        };
        Service = {
          Type = "oneshot";
          Environment = [
            "PATH=%h/.local/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
            "JQ=${pkgs.jq}/bin/jq"
          ];
          ExecStart = "%h/.local/bin/hypr-session save";
        };
        # No Install: the timer below is what starts it.
      };
    };

  # The timer is the ONLY thing that snapshots the session (see the comment on
  # hypr-session-restore for why there is no save-on-stop): a crash, a power cut
  # or an OOM kill never runs an ExecStop, and the whole point is to survive
  # exactly those. Worst case the snapshot is one saveInterval old.
  systemd.user.timers = lib.mkIf restoreOn {
    hypr-session-save = {
      Unit = {
        Description = "Periodic Hyprland window-set snapshot";
        PartOf = [ "hyprland-session.target" ];
        # Never let the first tick race the restore: a save that ran while the
        # desktop was still empty would overwrite the snapshot it is meant to
        # protect.
        After = [ "hypr-session-restore.service" ];
      };
      Timer = {
        # OnActiveSec (relative to this timer's activation, i.e. session start)
        # rather than OnStartupSec (relative to the *user manager's* start).
        # The user manager outlives the compositor, so on a re-login within the
        # same boot OnStartupSec is already elapsed and the timer fires
        # instantly — see the After= above for why that is the one moment a
        # save must not happen.
        OnActiveSec = saveInterval;
        OnUnitActiveSec = saveInterval;
      };
      Install.WantedBy = [ "hyprland-session.target" ];
    };
  };

  # Wallpaper directory is created by the .keep file in home.nix; a bare
  # home.file with only `recursive` and no source is invalid.

  # Hypridle — idle ladder: dim (5m) → lock (10m) → display off (11m) → suspend
  # (30m). Honors idle inhibitors, so the Super+F10 caffeine toggle and
  # fullscreen video pause all of it. (The old config blanked the screen after
  # 60s and had no dim/suspend step.)
  #
  # The suspend rung goes through idle-suspend.sh rather than calling
  # `systemctl suspend` directly. systemd-sleep only freezes `user.slice`, so a
  # nix build (nix-daemon.service, a system unit, holding no inhibitor lock)
  # would happily keep running while the EC applied its suspend fan policy —
  # i.e. a fully loaded CPU with the fans pinned low. The guard polls and only
  # suspends once the machine is actually idle and cool; on-resume cancels it.
  home.file.".config/hypr/hypridle.conf".text = ''
    general {
      lock_cmd = systemctl --user start --no-block hyprlock.service
      before_sleep_cmd = loginctl lock-session
      after_sleep_cmd = hyprctl dispatch dpms on
      ignore_dbus_inhibit = false
      ignore_systemd_inhibit = false
    }
  '' + lib.optionalString (features.hasBacklight or false) ''
    listener {
      timeout = 300
      on-timeout = brightnessctl -s set 10%
      on-resume = brightnessctl -r
    }
  '' + ''
    # Start the hyprlock unit directly instead of `loginctl lock-session`:
    # lock-session is a no-op when no ext-session-lock client is running yet
    # (hyprlock registers the handler only once started), which left a gap
    # where the session looked "about to lock" but nothing was listening.
    listener {
      timeout = 600
      on-timeout = systemctl --user start --no-block hyprlock.service
    }
    listener {
      timeout = 660
      on-timeout = hyprctl dispatch dpms off
      on-resume = hyprctl dispatch dpms on
    }
    listener {
      timeout = 1800
      on-timeout = ~/.config/hypr/scripts/idle-suspend.sh start
      on-resume = ~/.config/hypr/scripts/idle-suspend.sh cancel
    }
  '';

  # Hyprpaper configuration
  home.file.".config/hypr/wallpapers/default.jpg".source = ../../assets/wallpaper.jpg;
  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = ~/.config/hypr/wallpapers/default.jpg
    wallpaper = ,~/.config/hypr/wallpapers/default.jpg
    splash = false
    ipc = on
  '';
}
