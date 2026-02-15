{ config, pkgs, lib, theme ? {}, features ? {}, ... }:

let
  p = theme;
  
  # Monitor configuration - auto-detect based on hardware
  # To customize: override monitors.laptop or monitors.desktop in your config
  monitors = {
    laptop = {
      name = "eDP-1";
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
  
  # Determine monitor based on hardware features
  # If hasBattery, assume laptop; otherwise desktop
  # Override in your flake if you have a different setup
  currentMonitor = if features.hasBattery or false 
    then monitors.laptop 
    else monitors.desktop;
  
in {
  wayland.windowManager.hyprland = {
    enable = true;
    
    settings = {
      # Monitor setup
      monitor = "${currentMonitor.name}, ${currentMonitor.resolution}, ${currentMonitor.position}, ${currentMonitor.scale}";

      # Startup applications - optimized, no gnome-keyring
      exec-once = lib.flatten [
        # Environment setup - critical for proper session integration
        [ "dbus-update-activation-environment --systemd --all" ]
        [ "systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP" ]
        
        # Core services
        [ "waybar" "hyprpaper" "hypridle" "mako" ]
        [ "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1" ]
        
        # System tray apps
        [ "nm-applet --indicator" "udiskie --automount --notify" ]
        (lib.optional features.hasBluetooth "blueman-applet")
        
        # Clipboard
        [ "wl-paste --type text --watch cliphist store" ]
        [ "wl-paste --type image --watch cliphist store" ]
        
        # Directory setup
        [ "mkdir -p ~/.cache/hypr" "mkdir -p ~/Pictures/Screenshots" "mkdir -p ~/Videos/Recordings" "mkdir -p ~/Videos/Replays" ]
        
        # Initialize theme
        [ "echo '${p.name}' > ~/.cache/hypr/current-palette" ]
        
        # Ensure XWayland has proper cursor
        [ "sleep 1 && hyprctl setcursor idTech4 24" ]
      ];

      # Environment variables - comprehensive for all use cases
      env = [
        # Qt Theming
        "QT_QPA_PLATFORM,wayland;xcb"
        "QT_QPA_PLATFORMTHEME,qt5ct"
        "QT_STYLE_OVERRIDE,kvantum"
        "QT_WAYLAND_DISABLE_WINDOWDECORATION,1"
        "QT_AUTO_SCREEN_SCALE_FACTOR,1"
        "QT_SCALE_FACTOR_ROUNDING_POLICY,RoundPreferFloor"
        
        # GTK Theming
        "GTK_THEME,Adwaita:dark"
        "GDK_BACKEND,wayland,x11,xkb"
        
        # XDG & Desktop
        "XDG_CURRENT_DESKTOP,Hyprland"
        "XDG_SESSION_TYPE,wayland"
        "XDG_SESSION_DESKTOP,Hyprland"
        
        # Wayland Native
        "CLUTTER_BACKEND,wayland"
        "SDL_VIDEODRIVER,wayland"
        "MOZ_ENABLE_WAYLAND,1"
        "MOZ_DBUS_REMOTE,1"
        "ELECTRON_OZONE_PLATFORM_HINT,auto"
        "_JAVA_AWT_WM_NONREPARENTING,1"
        
        # Cursor
        "XCURSOR_SIZE,24"
        "XCURSOR_THEME,idTech4"
        "HYPRCURSOR_SIZE,24"
        "HYPRCURSOR_THEME,idTech4"
        
        # XWayland Compatibility
        "WLR_NO_HARDWARE_CURSORS,1"
        
        # Gaming - VRR & Performance (only when gaming enabled)
        (lib.optionals (features.enableGaming or false) "STEAM_FORCE_DESKTOPUI_SCALING,1")
        (lib.optionals (features.enableGaming or false) "__GL_GSYNC_ALLOWED,1")
        (lib.optionals (features.enableGaming or false) "__GL_VRR_ALLOWED,1")
        (lib.optionals (features.enableGaming or false) "WLR_DRM_NO_ATOMIC,1")
        
        # AMD Gaming
        (lib.optionals (features.enableGaming or false) "AMD_VULKAN_ICD,RADV")
        (lib.optionals (features.enableGaming or false) "RADV_PERFTEST,gpl")
        
        # Wine/Proton Gaming
        (lib.optionals (features.enableGaming or false) "WINE_FULLSCREEN_FSR,1")
        (lib.optionals (features.enableGaming or false) "DXVK_ASYNC,1")
        (lib.optionals (features.enableGaming or false) "GAMEMODERUNEXEC,env")
        
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
        vrr = 1;
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
        no_hardware_cursors = true;
        no_break_fs_vrr = true;
        min_refresh_rate = 60;
        hotspot_padding = 0;
        inactive_timeout = 5;
        hide_on_key_press = true;
        hide_on_touch = true;
        enable_hyprcursor = true;
        sync_gsettings_theme = true;
      };

      # Gestures - touchpad configuration
      gestures = lib.mkIf (features.hasTouchpad or false) {
        workspace_swipe_direction_lock = true;
        workspace_swipe_direction_lock_threshold = 10;
        workspace_swipe_invert = false;
        workspace_swipe_distance = 250;
        workspace_swipe_cancel_ratio = 0.5;
        workspace_swipe_min_speed_to_force = 30;
        workspace_swipe_create_new = true;
        workspace_swipe_forever = false;
      };

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

      # Keybindings - complete set
      bind = [
        # Help & Core
        "$mod, F1, exec, ~/.config/hypr/scripts/keybind-help.sh"
        "$mod, Return, exec, $terminal"
        "$mod SHIFT, Return, exec, $terminal --class floating-term"
        
        # App launchers
        "$mod, Space, exec, $menu"
        "$mod, D, exec, wofi --show drun"
        "$mod, B, exec, $browser"
        "$mod, E, exec, thunar"
        (lib.optional (features.enableDev or false) "$mod, C, exec, code")
        (lib.optional (features.enableDev or false) "$mod, O, exec, obsidian")

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
        
        # Special workspace / scratchpad
        "$mod, grave, workspace, previous"
        "$mod, bracketleft, workspace, e-1"
        "$mod, bracketright, workspace, e+1"
        "$mod, S, togglespecialworkspace, scratchpad"
        "$mod SHIFT, S, movetoworkspace, special:scratchpad"

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
        "$mod, V, exec, cliphist list | wofi --dmenu -p 'Clipboard' | cliphist decode | wl-copy"
        
        # Session
        "$mod, Escape, exec, wlogout -p layer-shell"
        "$mod CTRL, L, exec, hyprlock"
        "$mod SHIFT, Escape, exit"

        # Theme switching
        "$mod, F8, exec, ~/.config/hypr/scripts/theme-switcher.sh"
        "$mod SHIFT, F8, exec, ~/.config/hypr/scripts/theme-switcher.sh menu"

        # System
        "$mod, M, exec, gnome-system-monitor"
        "$mod, equal, exec, gnome-calculator"
        
        # Battery/sleep (laptop only)
        (lib.optional (features.hasBattery or false) "$mod, F12, exec, ~/.config/hypr/scripts/lid.sh toggle")
        
        # DCF (DeMoD Communication Framework)
        (lib.optional (features.enableDCF or false) "$mod, D, exec, $terminal --title 'DCF Control' -e dcf-control")
        
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
      ];

      # Volume/Brightness (with waybar reload)
      binde = [
        ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+ && pkill -HUP waybar"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%- && pkill -HUP waybar"
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle && pkill -HUP waybar"
      ] ++ lib.optionals (features.hasBacklight or false) [
        ", XF86MonBrightnessUp, exec, brightnessctl set 5%+ && pkill -HUP waybar"
        ", XF86MonBrightnessDown, exec, brightnessctl set 5%- && pkill -HUP waybar"
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
        "workspace 9 silent, class:^(steam)$"
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
        "immediate, class:^(steam_app_.*)$"
        "fullscreen, class:^(steam_app_.*)$, title:^(?!.*Settings).*$"
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
    '' + lib.optionalString (features.hasBattery or false) ''
      bindl = , switch:Lid Switch, exec, ~/.config/hypr/scripts/lid.sh close
      bindl = , switch:off:Lid Switch, exec, ~/.config/hypr/scripts/lid.sh open
    '';
  };

  # Screenshot directory
  home.file.".config/hypr/wallpapers".recursive = true;

  # Hypridle configuration
  home.file.".config/hypr/hypridle.conf".text = ''
    general {
      lock_cmd = pidof hyprlock || hyprlock
      before_sleep_cmd = loginctl lock-session
      after_sleep_cmd = hyprctl dispatch dpms on
    }
    listener { timeout = 300; on-timeout = loginctl lock-session; }
    listener { timeout = 360; on-timeout = hyprctl dispatch dpms off; on-resume = hyprctl dispatch dpms on; }
    listener { timeout = 60; on-timeout = hyprctl dispatch dpms off; on-resume = hyprctl dispatch dpms on; }
  '';

  # Hyprpaper configuration
  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = ~/.config/hypr/wallpapers/default.png
    wallpaper = ,~/.config/hypr/wallpapers/default.png
    splash = false
    ipc = on
  '';
}
