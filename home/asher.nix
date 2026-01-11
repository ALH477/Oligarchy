{ config, pkgs, lib, inputs, ... }:

{
  # ============================================================================
  # Home Manager Configuration for asher
  # DeMoD Compute Fabric Workstation
  # ============================================================================
  
  home.username = "asher";
  home.homeDirectory = "/home/asher";
  
  programs.home-manager.enable = true;

  # ────────────────────────────────────────────────────────────────────────────
  # DeMoD Color Palette
  # ────────────────────────────────────────────────────────────────────────────
  # Primary:   #00D4AA (Cyan/Teal - DCF Online)
  # Secondary: #FF6B6B (Coral/Red - DCF Offline/Alert)
  # Accent:    #4ECDC4 (Light Teal)
  # Dark:      #1A1A2E (Deep Navy)
  # Surface:   #16213E (Dark Blue)
  # Text:      #EAEAEA (Off-White)

  # ────────────────────────────────────────────────────────────────────────────
  # Hyprland Window Manager - DeMoD Edition
  # ────────────────────────────────────────────────────────────────────────────
  wayland.windowManager.hyprland = {
    enable = true;
    
    settings = {
      # Monitor configuration - Framework 16
      monitor = [
        "eDP-2, 2560x1600@165, 0x0, 1"       # Built-in display
        ", preferred, auto, 1"                # External displays
      ];
      
      # Startup applications - DeMoD Stack
      exec-once = [
        # Core desktop
        "waybar"
        "hyprpaper"
        "mako &"
        
        # Idle management
        "hypridle"
        
        # System services
        "udiskie --automount --notify &"
        "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1"
        
        # DeMoD/DCF Stack
        "dcf-tray"
        
        # Network & Bluetooth applets
        "nm-applet --indicator"
        "blueman-applet"
        
        # Clipboard manager
        "wl-paste --type text --watch cliphist store"
        "wl-paste --type image --watch cliphist store"
        
        # GNOME Keyring
        "${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --start --components=secrets"
        
        # Initialize DeMoD palette
        "mkdir -p ~/.cache/hypr && echo 'demod' > ~/.cache/hypr/palette"
        
        # Set cursor
        "hyprctl setcursor Adwaita 24"
      ];
      
      # Environment variables for DeMoD theme
      env = [
        "XCURSOR_SIZE,24"
        "QT_QPA_PLATFORMTHEME,qt5ct"
        "GTK_THEME,Adwaita:dark"
      ];
      
      # Input configuration
      input = {
        kb_layout = "us";
        follow_mouse = 1;
        touchpad = {
          natural_scroll = true;
          tap-to-click = true;
          drag_lock = true;
          disable_while_typing = true;
        };
        sensitivity = 0;
        accel_profile = "flat";
      };
      
      # General settings - DeMoD Theme
      general = {
        gaps_in = 4;
        gaps_out = 8;
        border_size = 2;
        # DeMoD colors: Cyan gradient for active, dark for inactive
        "col.active_border" = "rgba(00D4AAee) rgba(4ECDC4ee) 45deg";
        "col.inactive_border" = "rgba(1A1A2Eaa)";
        layout = "dwindle";
        resize_on_border = true;
        extend_border_grab_area = 15;
      };
      
      # Visual decoration - DeMoD Style
      decoration = {
        rounding = 8;
        
        blur = {
          enabled = true;
          size = 6;
          passes = 3;
          new_optimizations = true;
          xray = false;
          noise = 0.02;
          contrast = 1.0;
          brightness = 1.0;
        };
        
        shadow = {
          enabled = true;
          range = 12;
          render_power = 3;
          color = "rgba(00000066)";
          color_inactive = "rgba(00000033)";
        };
        
        # Dimming inactive windows slightly
        dim_inactive = true;
        dim_strength = 0.1;
      };
      
      # Animations - Smooth and professional
      animations = {
        enabled = true;
        
        bezier = [
          "demod, 0.05, 0.9, 0.1, 1.0"
          "smoothOut, 0.36, 0, 0.66, -0.56"
          "smoothIn, 0.25, 1, 0.5, 1"
          "overshot, 0.13, 0.99, 0.29, 1.1"
        ];
        
        animation = [
          "windows, 1, 4, demod, slide"
          "windowsOut, 1, 4, smoothOut, slide"
          "windowsMove, 1, 4, demod"
          "border, 1, 10, default"
          "borderangle, 1, 100, default, loop"
          "fade, 1, 4, smoothIn"
          "fadeDim, 1, 4, smoothIn"
          "workspaces, 1, 4, overshot, slidevert"
        ];
      };
      
      # Layout settings
      dwindle = {
        pseudotile = true;
        preserve_split = true;
        force_split = 2;
        smart_split = false;
        smart_resizing = true;
      };
      
      master = {
        new_status = "master";
        mfact = 0.55;
      };
      
      # Misc settings
      misc = {
        force_default_wallpaper = 0;
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        mouse_move_enables_dpms = true;
        key_press_enables_dpms = true;
        vfr = true;
        vrr = 1;  # Variable refresh rate
        animate_manual_resizes = true;
        animate_mouse_windowdragging = true;
        enable_swallow = true;
        swallow_regex = "^(kitty|Alacritty)$";
      };
      
      # Gesture support
      gestures = {
        workspace_swipe = true;
        workspace_swipe_fingers = 3;
        workspace_swipe_distance = 250;
        workspace_swipe_min_speed_to_force = 15;
      };
      
      # Keybindings
      "$mod" = "SUPER";
      "$terminal" = "kitty";
      "$fileManager" = "thunar";
      "$menu" = "wofi --show drun -I";
      "$browser" = "brave";
      
      bind = [
        # Application launchers
        "$mod, Return, exec, $terminal"
        "$mod, Q, killactive"
        "$mod, M, exit"
        "$mod, E, exec, $fileManager"
        "$mod, Space, exec, $menu"
        "$mod, B, exec, $browser"
        "$mod, C, exec, code"
        "$mod, O, exec, obsidian"
        
        # DCF Controls
        "$mod, D, exec, dcf-control"
        "$mod SHIFT, D, exec, dcf-logs"
        
        # Layout controls
        "$mod, V, togglefloating"
        "$mod, P, pseudo"
        "$mod, J, togglesplit"
        "$mod, F, fullscreen, 0"
        "$mod SHIFT, F, fullscreen, 1"
        "$mod, T, togglegroup"
        "$mod, Tab, changegroupactive, f"
        
        # ═══════════════════════════════════════════════════════════════════
        # DeMoD Toggle Controls (F-keys)
        # ═══════════════════════════════════════════════════════════════════
        "$mod, F1, exec, ~/.config/hypr/scripts/toggle-anim.sh"
        "$mod, F2, exec, ~/.config/hypr/scripts/toggle-blur.sh"
        "$mod, F3, exec, ~/.config/hypr/scripts/toggle-gaps.sh"
        "$mod, F4, exec, ~/.config/hypr/scripts/toggle-opacity.sh"
        "$mod, F5, exec, ~/.config/hypr/scripts/toggle-borders.sh"
        "$mod, F6, exec, ~/.config/hypr/scripts/toggle-rounding.sh"
        
        # Palette cycling
        "$mod, F7, exec, ~/.config/hypr/scripts/cycle-palette.sh forward"
        "$mod SHIFT, F7, exec, ~/.config/hypr/scripts/cycle-palette.sh reverse"
        
        # Power menu
        "$mod, Escape, exec, wlogout -p layer-shell"
        
        # Screenshot bindings - DeMoD style
        ", Print, exec, hyprshot -m output -o ~/Pictures/Screenshots"
        "$mod, Print, exec, hyprshot -m window -o ~/Pictures/Screenshots"
        "$mod SHIFT, Print, exec, hyprshot -m region -o ~/Pictures/Screenshots"
        "$mod ALT, Print, exec, hyprshot -m region --clipboard-only"
        "$mod CTRL, S, exec, grim -g \"$(slurp)\" - | swappy -f -"
        
        # Screen recording
        "$mod SHIFT, R, exec, gpu-screen-recorder-gtk"
        
        # Color picker
        "$mod SHIFT, C, exec, hyprpicker -a"
        
        # Clipboard history
        "$mod CTRL, V, exec, cliphist list | wofi --dmenu | cliphist decode | wl-copy"
        
        # Lock screen
        "$mod, L, exec, hyprlock"
        
        # Focus movement (vim-style + arrows)
        "$mod, left, movefocus, l"
        "$mod, right, movefocus, r"
        "$mod, up, movefocus, u"
        "$mod, down, movefocus, d"
        "$mod, h, movefocus, l"
        "$mod, l, movefocus, r"
        "$mod, k, movefocus, u"
        "$mod, j, movefocus, d"
        
        # Window movement
        "$mod SHIFT, left, movewindow, l"
        "$mod SHIFT, right, movewindow, r"
        "$mod SHIFT, up, movewindow, u"
        "$mod SHIFT, down, movewindow, d"
        "$mod SHIFT, h, movewindow, l"
        "$mod SHIFT, l, movewindow, r"
        "$mod SHIFT, k, movewindow, u"
        "$mod SHIFT, j, movewindow, d"
        
        # Workspace switching
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
        
        # Move to workspace
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
        
        # Special workspace (scratchpad)
        "$mod, S, togglespecialworkspace, magic"
        "$mod SHIFT, S, movetoworkspace, special:magic"
        
        # Workspace scroll
        "$mod, mouse_down, workspace, e+1"
        "$mod, mouse_up, workspace, e-1"
        
        # Clamshell mode toggle (Framework)
        "$mod, F12, exec, ~/.config/hypr/scripts/toggle_clamshell.sh"
        
        # AI Assistant
        "$mod, A, exec, $terminal -e bash -c 'ai-stack status && read -p \"Press enter...\"'"
      ];
      
      # Repeat bindings (brightness, volume)
      binde = [
        ", XF86AudioRaiseVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"
        ", XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"
        ", XF86MonBrightnessUp, exec, brightnessctl set 5%+"
        ", XF86MonBrightnessDown, exec, brightnessctl set 5%-"
        
        # Window resize
        "$mod CTRL, left, resizeactive, -20 0"
        "$mod CTRL, right, resizeactive, 20 0"
        "$mod CTRL, up, resizeactive, 0 -20"
        "$mod CTRL, down, resizeactive, 0 20"
        "$mod CTRL, h, resizeactive, -20 0"
        "$mod CTRL, l, resizeactive, 20 0"
        "$mod CTRL, k, resizeactive, 0 -20"
        "$mod CTRL, j, resizeactive, 0 20"
      ];
      
      # Locked bindings (work even when locked)
      bindl = [
        ", XF86AudioMute, exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"
        ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPrev, exec, playerctl previous"
        ", XF86AudioStop, exec, playerctl stop"
      ];
      
      # Mouse bindings
      bindm = [
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];
      
      # Window rules - DeMoD Stack
      windowrulev2 = [
        # Float system dialogs
        "float, class:^(pwvucontrol)$"
        "float, class:^(com.saivert.pwvucontrol)$"  # Flatpak version
        "float, class:^(helvum)$"
        "float, class:^(qpwgraph)$"
        "float, class:^(easyeffects)$"
        "float, class:^(com.github.wwmm.easyeffects)$"
        "float, class:^(blueman-manager)$"
        "float, class:^(nm-connection-editor)$"
        "float, title:^(Picture-in-Picture)$"
        "float, class:^(.blueman-manager-wrapped)$"
        "float, class:^(gnome-calculator)$"
        "float, class:^(file-roller)$"
        
        # DCF Tray
        "float, class:^(dcf-tray)$"
        "float, title:^(DCF Controller)$"
        "size 400 350, title:^(DCF Controller)$"
        "center, title:^(DCF Controller)$"
        
        # Firefox PiP
        "pin, title:^(Picture-in-Picture)$"
        "keepaspectratio, title:^(Picture-in-Picture)$"
        "size 480 270, title:^(Picture-in-Picture)$"
        "move 100%-490 100%-280, title:^(Picture-in-Picture)$"
        
        # Steam
        "workspace 9 silent, class:^(steam)$"
        "float, class:^(steam)$, title:^(Friends List)$"
        "float, class:^(steam)$, title:^(Steam Settings)$"
        
        # IDE/Dev workspaces
        "workspace 2, class:^(Code)$"
        "workspace 2, class:^(code-url-handler)$"
        "workspace 3, class:^(obsidian)$"
        
        # AI/Ollama
        "workspace 4, title:^(Open WebUI)$"
        "workspace 4, class:^(Alpaca)$"
        
        # Communication
        "workspace 5, class:^(thunderbird)$"
        "workspace 5, class:^(discord)$"
        "workspace 5, class:^(legcord)$"
        
        # Media
        "workspace 6, class:^(obs)$"
        "workspace 6, class:^(kdenlive)$"
        
        # Opacity rules
        "opacity 0.95, class:^(kitty)$"
        "opacity 0.95, class:^(Code)$"
        "opacity 1.0, class:^(brave-browser)$"
        "opacity 1.0, class:^(firefox)$"
        
        # No border for maximized
        "noborder, fullscreen:1"
      ];
      
      # Layer rules
      layerrule = [
        "blur, waybar"
        "blur, wofi"
        "blur, notifications"
        "ignorezero, waybar"
        "ignorezero, notifications"
      ];
    };
    
    # Extra config
    extraConfig = ''
      # Lid switch handling for Framework 16
      bindl = , switch:Lid Switch, exec, ~/.config/hypr/scripts/lid.sh close
      bindl = , switch:off:Lid Switch, exec, ~/.config/hypr/scripts/lid.sh open
      
      # Workspace rules
      workspace = 1, monitor:eDP-2, default:true
      workspace = 9, monitor:eDP-2  # Steam
      workspace = 10, monitor:eDP-2 # Background tasks
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Hyprland Helper Scripts
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".config/hypr/scripts/lid.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      INTERNAL="eDP-2"
      
      if [[ "$1" == "close" ]]; then
        if hyprctl monitors -j | jq -e '.[] | select(.name != "'"$INTERNAL"'")' > /dev/null 2>&1; then
          hyprctl keyword monitor "$INTERNAL,disable"
        fi
      elif [[ "$1" == "open" ]]; then
        hyprctl keyword monitor "$INTERNAL,2560x1600@165,auto,1"
      fi
    '';
  };
  
  home.file.".config/hypr/scripts/toggle_clamshell.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      INTERNAL="eDP-2"
      
      if hyprctl monitors -j | jq -e '.[] | select(.name | startswith("DP-") or startswith("HDMI-"))' > /dev/null 2>&1; then
        if hyprctl monitors -j | jq -e '.[] | select(.name == "'"$INTERNAL"'")' > /dev/null 2>&1; then
          hyprctl keyword monitor "$INTERNAL,disable"
          notify-send -i display "Clamshell Mode" "Laptop screen disabled" -u low
        else
          hyprctl keyword monitor "$INTERNAL,2560x1600@165,auto,1"
          notify-send -i display "Clamshell Mode" "Laptop screen enabled" -u low
        fi
      else
        notify-send -i dialog-warning "Clamshell Mode" "No external monitor detected" -u normal
      fi
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Waybar - DeMoD Theme
  # ────────────────────────────────────────────────────────────────────────────
  programs.waybar = {
    enable = true;
    systemd.enable = false;
    
    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 36;
      spacing = 0;
      margin-top = 4;
      margin-left = 8;
      margin-right = 8;
      
      modules-left = [ 
        "custom/logo" 
        "hyprland/workspaces" 
        "hyprland/window" 
      ];
      modules-center = [ "clock" ];
      modules-right = [ 
        "custom/dcf"
        "custom/ollama"
        "tray"
        "wireplumber"   # Wayland-native audio (replaces pulseaudio)
        "network" 
        "bluetooth"
        "cpu" 
        "memory" 
        "temperature"
        "battery" 
        "custom/power"
      ];
      
      "custom/logo" = {
        format = "  ";
        tooltip = false;
      };
      
      "hyprland/workspaces" = {
        format = "{icon}";
        format-icons = {
          "1" = "󰎤";
          "2" = "󰎧";
          "3" = "󰎪";
          "4" = "󰎭";
          "5" = "󰎱";
          "6" = "󰎳";
          "7" = "󰎶";
          "8" = "󰎹";
          "9" = "󰎼";
          "10" = "󰽽";
          urgent = "󰀨";
          default = "󰧞";
        };
        on-click = "activate";
        sort-by-number = true;
      };
      
      "hyprland/window" = {
        max-length = 40;
        separate-outputs = true;
      };
      
      clock = {
        format = "󰥔 {:%H:%M}";
        format-alt = "󰃭 {:%Y-%m-%d %H:%M:%S}";
        tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
        interval = 1;
      };
      
      "custom/dcf" = {
        exec = "~/.config/waybar/scripts/dcf-status.sh";
        interval = 5;
        return-type = "json";
        format = "{}";
        on-click = "dcf-control";
        tooltip = true;
      };
      
      "custom/ollama" = {
        exec = "~/.config/waybar/scripts/ollama-status.sh";
        interval = 10;
        return-type = "json";
        format = "{}";
        on-click = "kitty -e ai-stack status";
        tooltip = true;
      };
      
      battery = {
        states = { 
          good = 80;
          warning = 30; 
          critical = 15; 
        };
        format = "{icon} {capacity}%";
        format-charging = "󰂄 {capacity}%";
        format-plugged = "󰂄 {capacity}%";
        format-full = "󰁹 Full";
        format-icons = [ "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
        tooltip-format = "{timeTo}\n{power}W";
      };
      
      network = {
        format-wifi = "󰖩 {signalStrength}%";
        format-ethernet = "󰈀 {ipaddr}";
        format-disconnected = "󰖪 ";
        tooltip-format-wifi = "{essid} ({signalStrength}%)\n{ifname}: {ipaddr}/{cidr}";
        tooltip-format-ethernet = "{ifname}: {ipaddr}/{cidr}\n{bandwidthUpBytes} up / {bandwidthDownBytes} down";
        tooltip-format-disconnected = "Disconnected";
        on-click = "nm-connection-editor";
      };
      
      bluetooth = {
        format = "󰂯";
        format-connected = "󰂱 {num_connections}";
        format-disabled = "󰂲";
        tooltip-format = "{controller_alias}\t{controller_address}";
        tooltip-format-connected = "{controller_alias}\t{controller_address}\n\n{device_enumerate}";
        tooltip-format-enumerate-connected = "{device_alias}\t{device_address}";
        on-click = "blueman-manager";
      };
      
      # Wayland-native audio control via WirePlumber
      wireplumber = {
        format = "{icon} {volume}%";
        format-muted = "󰝟 ";
        format-icons = [ "󰕿" "󰖀" "󰕾" ];
        on-click = "pwvucontrol";
        on-click-right = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        on-scroll-up = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 2%+";
        on-scroll-down = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 2%-";
        max-volume = 150;
        scroll-step = 2;
      };
      
      cpu = {
        format = "󰻠 {usage}%";
        tooltip-format = "CPU: {usage}%\n{avg_frequency}GHz";
        interval = 2;
        on-click = "kitty -e htop";
      };
      
      memory = {
        format = "󰍛 {}%";
        tooltip-format = "RAM: {used:0.1f}GB / {total:0.1f}GB";
        interval = 2;
      };
      
      temperature = {
        hwmon-path-abs = "/sys/devices/pci0000:00/0000:00:18.3/hwmon";
        input-filename = "temp1_input";
        format = "󰔏 {temperatureC}°C";
        format-critical = "󱃂 {temperatureC}°C";
        critical-threshold = 85;
        interval = 5;
      };
      
      tray = {
        icon-size = 18;
        spacing = 8;
      };
      
      "custom/power" = {
        format = "󰐥";
        tooltip = false;
        on-click = "wlogout -p layer-shell";
      };
    };
    
    style = ''
      /* DeMoD Waybar Theme */
      @define-color bg #1A1A2E;
      @define-color bg-alt #16213E;
      @define-color fg #EAEAEA;
      @define-color cyan #00D4AA;
      @define-color cyan-dim #00A888;
      @define-color red #FF6B6B;
      @define-color yellow #FFE66D;
      @define-color blue #4ECDC4;
      
      * {
        font-family: "JetBrains Mono Nerd Font", "Font Awesome 6 Free";
        font-size: 13px;
        min-height: 0;
        border: none;
        border-radius: 0;
      }
      
      window#waybar {
        background: transparent;
      }
      
      window#waybar > box {
        background: alpha(@bg, 0.85);
        border-radius: 12px;
        border: 1px solid alpha(@cyan, 0.3);
      }
      
      #custom-logo {
        color: @cyan;
        font-size: 18px;
        padding: 0 12px;
      }
      
      #workspaces {
        background: transparent;
        margin: 4px 0;
      }
      
      #workspaces button {
        color: alpha(@fg, 0.5);
        padding: 0 8px;
        margin: 0 2px;
        border-radius: 6px;
        transition: all 0.2s ease;
      }
      
      #workspaces button:hover {
        color: @fg;
        background: alpha(@cyan, 0.2);
      }
      
      #workspaces button.active {
        color: @bg;
        background: @cyan;
      }
      
      #workspaces button.urgent {
        color: @bg;
        background: @red;
      }
      
      #window {
        color: alpha(@fg, 0.8);
        padding: 0 12px;
      }
      
      #clock {
        color: @fg;
        font-weight: bold;
        padding: 0 16px;
      }
      
      #custom-dcf {
        padding: 0 12px;
      }
      
      #custom-dcf.online {
        color: @cyan;
      }
      
      #custom-dcf.offline {
        color: alpha(@fg, 0.4);
      }
      
      #custom-dcf.partial {
        color: @yellow;
      }
      
      #custom-ollama {
        padding: 0 12px;
      }
      
      #custom-ollama.running {
        color: @cyan;
      }
      
      #custom-ollama.stopped {
        color: alpha(@fg, 0.4);
      }
      
      #tray {
        padding: 0 8px;
      }
      
      #tray > .passive {
        -gtk-icon-effect: dim;
      }
      
      #tray > .needs-attention {
        -gtk-icon-effect: highlight;
        background-color: @red;
      }
      
      #wireplumber, #network, #bluetooth, #cpu, #memory, #temperature, #battery {
        padding: 0 10px;
        margin: 4px 2px;
        border-radius: 6px;
        background: alpha(@bg-alt, 0.5);
        color: @fg;
        transition: all 0.2s ease;
      }
      
      #wireplumber:hover, #network:hover, #bluetooth:hover,
      #cpu:hover, #memory:hover, #temperature:hover, #battery:hover {
        background: alpha(@cyan, 0.2);
      }
      
      #wireplumber.muted {
        color: @red;
      }
      
      #network.disconnected {
        color: @red;
      }
      
      #bluetooth.disabled {
        color: alpha(@fg, 0.3);
      }
      
      #cpu.warning, #memory.warning {
        color: @yellow;
      }
      
      #cpu.critical, #memory.critical {
        color: @red;
      }
      
      #temperature.critical {
        color: @red;
        animation: blink 0.5s ease infinite alternate;
      }
      
      #battery.charging, #battery.plugged {
        color: @cyan;
      }
      
      #battery.warning:not(.charging) {
        color: @yellow;
      }
      
      #battery.critical:not(.charging) {
        color: @red;
        animation: blink 0.5s ease infinite alternate;
      }
      
      #custom-power {
        color: @red;
        padding: 0 14px 0 10px;
        font-size: 16px;
      }
      
      #custom-power:hover {
        color: @fg;
        background: @red;
        border-radius: 0 12px 12px 0;
      }
      
      @keyframes blink {
        to { color: @fg; }
      }
    '';
  };
  
  # Waybar DCF status script
  home.file.".config/waybar/scripts/dcf-status.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      
      ID_RUNNING=false
      NODE_RUNNING=false
      
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^dcf-id$'; then
        ID_RUNNING=true
      fi
      
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^dcf-sdk$'; then
        NODE_RUNNING=true
      fi
      
      if $ID_RUNNING && $NODE_RUNNING; then
        echo '{"text": "󰒋 DCF", "class": "online", "tooltip": "DCF Stack: All Online\nIdentity: Running\nNode: Running"}'
      elif $ID_RUNNING || $NODE_RUNNING; then
        echo '{"text": "󰒋 DCF", "class": "partial", "tooltip": "DCF Stack: Partial\nIdentity: '$ID_RUNNING'\nNode: '$NODE_RUNNING'"}'
      else
        echo '{"text": "󰒎 DCF", "class": "offline", "tooltip": "DCF Stack: Offline\nClick to open controls"}'
      fi
    '';
  };
  
  # Waybar Ollama status script
  home.file.".config/waybar/scripts/ollama-status.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ollama$'; then
        MODELS=$(docker exec ollama ollama list 2>/dev/null | tail -n +2 | wc -l)
        echo '{"text": "󰧑 AI", "class": "running", "tooltip": "Ollama: Running\nModels loaded: '$MODELS'"}'
      else
        echo '{"text": "󰧑 AI", "class": "stopped", "tooltip": "Ollama: Stopped\nRun: ai-stack start"}'
      fi
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Mako Notifications - DeMoD Theme
  # ────────────────────────────────────────────────────────────────────────────
  services.mako = {
    enable = true;
    
    settings = {
      # DeMoD colors
      background-color = "#1A1A2EF0";
      text-color = "#EAEAEA";
      border-color = "#00D4AA";
      progress-color = "over #00D4AA";
      
      border-radius = 8;
      border-size = 2;
      padding = "12";
      margin = "12";
      
      default-timeout = 5000;
      
      font = "JetBrains Mono 11";
      
      icons = true;
      max-icon-size = 48;
      
      layer = "overlay";
      anchor = "top-right";
      
      # Urgency-specific settings
      "urgency=critical" = {
        border-color = "#FF6B6B";
        default-timeout = 0;
      };
      
      "app-name=Spotify" = {
        default-timeout = 3000;
      };
      
      "app-name=DCF Controller" = {
        border-color = "#00D4AA";
      };
    };
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Wofi Launcher - DeMoD Theme
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".config/wofi/style.css".text = ''
    /* DeMoD Wofi Theme */
    window {
      margin: 0px;
      border: 2px solid #00D4AA;
      border-radius: 12px;
      background-color: #1A1A2EF0;
      font-family: "JetBrains Mono";
      font-size: 14px;
    }
    
    #input {
      margin: 8px;
      border: none;
      border-radius: 8px;
      padding: 12px;
      background-color: #16213E;
      color: #EAEAEA;
    }
    
    #input:focus {
      border: 1px solid #00D4AA;
    }
    
    #inner-box {
      margin: 8px;
      border: none;
      background-color: transparent;
    }
    
    #outer-box {
      margin: 0px;
      border: none;
      background-color: transparent;
    }
    
    #scroll {
      margin: 0px;
      border: none;
    }
    
    #text {
      margin: 0px;
      border: none;
      color: #EAEAEA;
    }
    
    #entry {
      margin: 4px 8px;
      padding: 12px;
      border-radius: 8px;
      background-color: transparent;
    }
    
    #entry:selected {
      background-color: #00D4AA;
      color: #1A1A2E;
    }
    
    #entry:hover {
      background-color: #16213E;
    }
  '';
  
  home.file.".config/wofi/config".text = ''
    width=600
    height=400
    location=center
    show=drun
    prompt=Search...
    filter_rate=100
    allow_markup=true
    no_actions=true
    halign=fill
    orientation=vertical
    content_halign=fill
    insensitive=true
    allow_images=true
    image_size=32
    gtk_dark=true
  '';
  
  # ────────────────────────────────────────────────────────────────────────────
  # Kitty Terminal - DeMoD Theme
  # ────────────────────────────────────────────────────────────────────────────
  programs.kitty = {
    enable = true;
    settings = {
      # Font
      font_family = "JetBrains Mono";
      bold_font = "JetBrains Mono Bold";
      italic_font = "JetBrains Mono Italic";
      font_size = 11;
      
      # Cursor
      cursor_shape = "beam";
      cursor_blink_interval = 0;
      
      # Scrollback
      scrollback_lines = 10000;
      
      # Window
      window_padding_width = 10;
      hide_window_decorations = "yes";
      confirm_os_window_close = 0;
      
      # Performance
      sync_to_monitor = "yes";
      
      # Bell
      enable_audio_bell = false;
      visual_bell_duration = 0;
      
      # URLs
      url_style = "curly";
      
      # DeMoD Color Scheme
      background = "#1A1A2E";
      foreground = "#EAEAEA";
      selection_background = "#00D4AA";
      selection_foreground = "#1A1A2E";
      cursor = "#00D4AA";
      cursor_text_color = "#1A1A2E";
      
      # Black
      color0 = "#16213E";
      color8 = "#4A4A6A";
      
      # Red
      color1 = "#FF6B6B";
      color9 = "#FF8E8E";
      
      # Green
      color2 = "#00D4AA";
      color10 = "#4ECDC4";
      
      # Yellow
      color3 = "#FFE66D";
      color11 = "#FFF59D";
      
      # Blue
      color4 = "#4ECDC4";
      color12 = "#80DEEA";
      
      # Magenta
      color5 = "#C792EA";
      color13 = "#E1BEE7";
      
      # Cyan
      color6 = "#00D4AA";
      color14 = "#4ECDC4";
      
      # White
      color7 = "#EAEAEA";
      color15 = "#FFFFFF";
      
      # Tab bar
      tab_bar_style = "powerline";
      tab_powerline_style = "slanted";
      active_tab_background = "#00D4AA";
      active_tab_foreground = "#1A1A2E";
      inactive_tab_background = "#16213E";
      inactive_tab_foreground = "#EAEAEA";
      
      # Background opacity
      background_opacity = "0.95";
    };
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Hyprpaper Wallpaper
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = ~/.config/hypr/wallpapers/demod-dark.png
    wallpaper = ,~/.config/hypr/wallpapers/demod-dark.png
    splash = false
  '';
  
  # Create a simple DeMoD wallpaper placeholder script
  home.file.".config/hypr/wallpapers/.create-wallpaper.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # Generate a simple DeMoD branded wallpaper
      # Requires imagemagick
      
      convert -size 2560x1600 \
        -define gradient:angle=135 \
        gradient:'#1A1A2E-#16213E' \
        -font "JetBrains-Mono-Bold" \
        -pointsize 120 \
        -fill '#00D4AA20' \
        -gravity center \
        -annotate +0-200 "DeMoD" \
        -pointsize 40 \
        -fill '#00D4AA15' \
        -annotate +0+0 "COMPUTE FABRIC" \
        ~/.config/hypr/wallpapers/demod-dark.png
      
      echo "Wallpaper created at ~/.config/hypr/wallpapers/demod-dark.png"
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Git Configuration
  # ────────────────────────────────────────────────────────────────────────────
  programs.git = {
    enable = true;
    
    settings = {
      user.name = "Asher";
      # user.email = "your@email.com";
      
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.editor = "vim";
      merge.conflictstyle = "diff3";
      diff.colorMoved = "default";
      
      alias = {
        st = "status -sb";
        co = "checkout";
        br = "branch";
        ci = "commit";
        lg = "log --oneline --graph --decorate";
        unstage = "reset HEAD --";
        last = "log -1 HEAD";
      };
    };
  };
  
  # Delta - Git diff viewer
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
      side-by-side = true;
      line-numbers = true;
      syntax-theme = "base16";
    };
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Bash Configuration
  # ────────────────────────────────────────────────────────────────────────────
  programs.bash = {
    enable = true;
    
    shellAliases = {
      # Navigation
      ll = "ls -la --color=auto";
      ls = "ls --color=auto";
      la = "ls -A --color=auto";
      l = "ls -CF --color=auto";
      grep = "grep --color=auto";
      ".." = "cd ..";
      "..." = "cd ../..";
      
      # NixOS
      rebuild = "sudo nixos-rebuild switch --flake .";
      rebuild-test = "sudo nixos-rebuild test --flake .";
      rebuild-boot = "sudo nixos-rebuild boot --flake .";
      nix-clean = "sudo nix-collect-garbage -d";
      
      # Docker
      dps = "docker ps";
      dpa = "docker ps -a";
      dlog = "docker logs -f";
      dex = "docker exec -it";
      
      # DCF Stack
      dcf-logs = "docker logs -f dcf-sdk";
      dcf-id-logs = "docker logs -f dcf-id";
      dcf-restart = "sudo systemctl restart docker-dcf-sdk.service docker-dcf-id.service";
      
      # AI
      ai = "ai-stack";
      ollama-logs = "ai-stack logs";
      
      # System
      ports = "ss -tulanp";
      myip = "curl -s ifconfig.me";
      weather = "curl wttr.in";
    };
    
    initExtra = ''
      # DeMoD Bash Prompt
      PS1='\[\033[38;5;43m\]╭─[\[\033[38;5;252m\]\u\[\033[38;5;43m\]@\[\033[38;5;252m\]\h\[\033[38;5;43m\]] \[\033[38;5;252m\]\w\[\033[38;5;43m\]\n╰─▶\[\033[0m\] '
      
      # History
      HISTSIZE=50000
      HISTFILESIZE=100000
      HISTCONTROL=ignoreboth:erasedups
      shopt -s histappend
      
      # Navigation
      shopt -s cdspell
      shopt -s autocd
      shopt -s dirspell
      shopt -s globstar
      
      # DCF Quick Status
      dcf-status() {
        echo -e "\033[38;5;43m═══════════════════════════════════════\033[0m"
        echo -e "\033[38;5;43m        DeMoD Compute Fabric          \033[0m"
        echo -e "\033[38;5;43m═══════════════════════════════════════\033[0m"
        echo ""
        
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^dcf-id$'; then
          echo -e "  Identity Service: \033[38;5;43m● Online\033[0m"
        else
          echo -e "  Identity Service: \033[38;5;203m○ Offline\033[0m"
        fi
        
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^dcf-sdk$'; then
          echo -e "  Community Node:   \033[38;5;43m● Online\033[0m"
        else
          echo -e "  Community Node:   \033[38;5;203m○ Offline\033[0m"
        fi
        
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ollama$'; then
          echo -e "  Ollama AI:        \033[38;5;43m● Running\033[0m"
        else
          echo -e "  Ollama AI:        \033[38;5;203m○ Stopped\033[0m"
        fi
        
        echo ""
      }
      
      # Show status on login
      if [[ $- == *i* ]]; then
        dcf-status
      fi
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Environment
  # ────────────────────────────────────────────────────────────────────────────
  home.sessionVariables = {
    EDITOR = "vim";
    BROWSER = "brave";
    TERMINAL = "kitty";
  };
  
  home.sessionPath = [ "$HOME/.local/bin" ];
  
  # ────────────────────────────────────────────────────────────────────────────
  # DCF Control Script
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".local/bin/dcf-control" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # DeMoD Compute Fabric Control Panel
      
      show_menu() {
        echo -e "\033[38;5;43m"
        echo "╔══════════════════════════════════════╗"
        echo "║     DeMoD Compute Fabric Control     ║"
        echo "╠══════════════════════════════════════╣"
        echo "║  1) Start All Services               ║"
        echo "║  2) Stop All Services                ║"
        echo "║  3) Restart All Services             ║"
        echo "║  4) View Status                      ║"
        echo "║  5) View Identity Logs               ║"
        echo "║  6) View Node Logs                   ║"
        echo "║  7) Start Ollama                     ║"
        echo "║  8) Stop Ollama                      ║"
        echo "║  0) Exit                             ║"
        echo "╚══════════════════════════════════════╝"
        echo -e "\033[0m"
      }
      
      while true; do
        clear
        show_menu
        read -p "Select option: " choice
        
        case $choice in
          1) sudo systemctl start docker-dcf-sdk.service docker-dcf-id.service ;;
          2) sudo systemctl stop docker-dcf-sdk.service docker-dcf-id.service ;;
          3) sudo systemctl restart docker-dcf-sdk.service docker-dcf-id.service ;;
          4) dcf-status; read -p "Press enter..." ;;
          5) docker logs -f dcf-id ;;
          6) docker logs -f dcf-sdk ;;
          7) ai-stack start ;;
          8) ai-stack stop ;;
          0) exit 0 ;;
          *) echo "Invalid option" ;;
        esac
      done
    '';
  };
  
  home.file.".local/bin/dcf-logs" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # View combined DCF logs
      docker logs -f dcf-sdk &
      docker logs -f dcf-id &
      wait
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Network Helper Scripts
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".local/bin/net-status" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      echo -e "\033[38;5;43m═══════════════════════════════════════\033[0m"
      echo -e "\033[38;5;43m           Network Status              \033[0m"
      echo -e "\033[38;5;43m═══════════════════════════════════════\033[0m"
      echo ""
      
      echo -e "\033[38;5;43m▸ NetworkManager:\033[0m"
      systemctl is-active NetworkManager.service && echo "  RUNNING ✓" || echo "  STOPPED ✗"
      
      echo ""
      echo -e "\033[38;5;43m▸ Active Connections:\033[0m"
      nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | while IFS=: read -r name type device; do
        echo "  • $name ($type) on $device"
      done
      
      echo ""
      echo -e "\033[38;5;43m▸ WiFi:\033[0m"
      if nmcli radio wifi 2>/dev/null | grep -q "enabled"; then
        SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
        SIGNAL=$(nmcli -t -f active,signal dev wifi | grep '^yes' | cut -d: -f2)
        echo "  Status: ENABLED"
        [ -n "$SSID" ] && echo "  Connected: $SSID ($SIGNAL%)"
      else
        echo "  Status: DISABLED"
      fi
      
      echo ""
      echo -e "\033[38;5;43m▸ IP Addresses:\033[0m"
      ip -4 addr show | grep inet | grep -v '127.0.0.1' | awk '{print "  " $NF ": " $2}'
      
      echo ""
      echo -e "\033[38;5;43m▸ Internet:\033[0m"
      ping -c 1 -W 2 1.1.1.1 &>/dev/null && echo "  IPv4: ✓" || echo "  IPv4: ✗"
      ping -c 1 -W 2 google.com &>/dev/null && echo "  DNS:  ✓" || echo "  DNS:  ✗"
      echo ""
    '';
  };
  
  home.file.".local/bin/net-fix" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      echo "Restarting network services..."
      sudo systemctl restart NetworkManager.service systemd-resolved.service
      sleep 2
      resolvectl flush-caches 2>/dev/null || true
      nmcli device wifi rescan 2>/dev/null || true
      sleep 1
      net-status
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Docker Helper Scripts
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".local/bin/docker-start" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -e
      if systemctl is-active --quiet docker.service; then
        echo "Docker is already running"
      else
        echo "Starting Docker..."
        sudo systemctl start docker.service docker.socket
        echo "Docker started ✓"
      fi
    '';
  };
  
  home.file.".local/bin/docker-stop" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -e
      if ! systemctl is-active --quiet docker.service; then
        echo "Docker is not running"
        exit 0
      fi
      
      RUNNING=$(docker ps -q 2>/dev/null | wc -l)
      if [ "$RUNNING" -gt 0 ]; then
        echo "Warning: $RUNNING container(s) still running"
        read -p "Stop all containers and Docker? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
          docker stop $(docker ps -q) 2>/dev/null || true
        else
          exit 1
        fi
      fi
      
      sudo systemctl stop docker.service docker.socket
      echo "Docker stopped ✓"
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # XDG Configuration
  # ────────────────────────────────────────────────────────────────────────────
  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      
      desktop = "${config.home.homeDirectory}/Desktop";
      documents = "${config.home.homeDirectory}/Documents";
      download = "${config.home.homeDirectory}/Downloads";
      music = "${config.home.homeDirectory}/Music";
      pictures = "${config.home.homeDirectory}/Pictures";
      videos = "${config.home.homeDirectory}/Videos";
      
      extraConfig = {
        XDG_SCREENSHOTS_DIR = "${config.home.homeDirectory}/Pictures/Screenshots";
        XDG_PROJECTS_DIR = "${config.home.homeDirectory}/Projects";
      };
    };
    
    mimeApps = {
      enable = true;
      defaultApplications = {
        "text/html" = "brave-browser.desktop";
        "x-scheme-handler/http" = "brave-browser.desktop";
        "x-scheme-handler/https" = "brave-browser.desktop";
        "application/pdf" = "org.kde.okular.desktop";
        "image/png" = "org.kde.gwenview.desktop";
        "image/jpeg" = "org.kde.gwenview.desktop";
        "video/mp4" = "vlc.desktop";
        "audio/mpeg" = "vlc.desktop";
      };
    };
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # DeMoD Hyprland Toggle Scripts
  # Runtime toggles for animations, blur, gaps, opacity, borders, rounding
  # ────────────────────────────────────────────────────────────────────────────
  
  home.file.".config/hypr/scripts/toggle-anim.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      STATE=$(hyprctl getoption animations:enabled -j | jq -r '.int')
      if [[ "$STATE" == "1" ]]; then
        hyprctl keyword animations:enabled false
        notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Animations OFF"
      else
        hyprctl keyword animations:enabled true
        notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Animations ON"
      fi
    '';
  };
  
  home.file.".config/hypr/scripts/toggle-blur.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      STATE=$(hyprctl getoption decoration:blur:enabled -j | jq -r '.int')
      if [[ "$STATE" == "1" ]]; then
        hyprctl keyword decoration:blur:enabled false
        notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Blur OFF"
      else
        hyprctl keyword decoration:blur:enabled true
        notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Blur ON"
      fi
    '';
  };
  
  home.file.".config/hypr/scripts/toggle-gaps.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      CACHE="''${XDG_CACHE_HOME:-$HOME/.cache}/hypr/gaps"
      mkdir -p "$(dirname "$CACHE")"
      [[ -f "$CACHE" ]] || echo "default" > "$CACHE"
      CURRENT=$(cat "$CACHE")
      
      case "$CURRENT" in
        default)
          hyprctl keyword general:gaps_in 0
          hyprctl keyword general:gaps_out 0
          echo "zero" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Gaps ZERO"
          ;;
        zero)
          hyprctl keyword general:gaps_in 2
          hyprctl keyword general:gaps_out 4
          echo "minimal" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Gaps MINIMAL"
          ;;
        *)
          hyprctl keyword general:gaps_in 4
          hyprctl keyword general:gaps_out 8
          echo "default" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Gaps DEFAULT"
          ;;
      esac
    '';
  };
  
  home.file.".config/hypr/scripts/toggle-opacity.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      CACHE="''${XDG_CACHE_HOME:-$HOME/.cache}/hypr/opacity"
      mkdir -p "$(dirname "$CACHE")"
      [[ -f "$CACHE" ]] || echo "default" > "$CACHE"
      CURRENT=$(cat "$CACHE")
      
      case "$CURRENT" in
        default)
          hyprctl keyword decoration:active_opacity 1.0
          hyprctl keyword decoration:inactive_opacity 1.0
          echo "solid" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Opacity SOLID"
          ;;
        solid)
          hyprctl keyword decoration:active_opacity 0.95
          hyprctl keyword decoration:inactive_opacity 0.85
          echo "transparent" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Opacity TRANSPARENT"
          ;;
        *)
          hyprctl keyword decoration:active_opacity 1.0
          hyprctl keyword decoration:inactive_opacity 0.92
          echo "default" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Opacity DEFAULT"
          ;;
      esac
    '';
  };
  
  home.file.".config/hypr/scripts/toggle-borders.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      CACHE="''${XDG_CACHE_HOME:-$HOME/.cache}/hypr/borders"
      mkdir -p "$(dirname "$CACHE")"
      [[ -f "$CACHE" ]] || echo "default" > "$CACHE"
      CURRENT=$(cat "$CACHE")
      
      case "$CURRENT" in
        default)
          hyprctl keyword general:border_size 0
          echo "none" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Borders NONE"
          ;;
        none)
          hyprctl keyword general:border_size 1
          echo "thin" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Borders THIN"
          ;;
        *)
          hyprctl keyword general:border_size 2
          echo "default" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Borders DEFAULT"
          ;;
      esac
    '';
  };
  
  home.file.".config/hypr/scripts/toggle-rounding.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      CACHE="''${XDG_CACHE_HOME:-$HOME/.cache}/hypr/rounding"
      mkdir -p "$(dirname "$CACHE")"
      [[ -f "$CACHE" ]] || echo "default" > "$CACHE"
      CURRENT=$(cat "$CACHE")
      
      case "$CURRENT" in
        default)
          hyprctl keyword decoration:rounding 0
          echo "square" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Rounding SQUARE"
          ;;
        square)
          hyprctl keyword decoration:rounding 4
          echo "subtle" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Rounding SUBTLE"
          ;;
        *)
          hyprctl keyword decoration:rounding 8
          echo "default" > "$CACHE"
          notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Rounding DEFAULT"
          ;;
      esac
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # DeMoD Palette Cycling
  # Six color themes: demod (cyan), vim (green), amber, purple, rose, gold
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".config/hypr/scripts/cycle-palette.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      
      CACHE="''${XDG_CACHE_HOME:-$HOME/.cache}/hypr/palette"
      mkdir -p "$(dirname "$CACHE")"
      [[ -f "$CACHE" ]] || echo "demod" > "$CACHE"
      
      PALETTES=(demod vim amber purple rose gold)
      CURRENT=$(cat "$CACHE")
      DIR="''${1:-forward}"
      
      IDX=0
      for i in "''${!PALETTES[@]}"; do
        if [[ "''${PALETTES[$i]}" == "$CURRENT" ]]; then
          IDX=$i
          break
        fi
      done
      
      if [[ "$DIR" == "reverse" ]]; then
        NEXT=$(( (IDX - 1 + ''${#PALETTES[@]}) % ''${#PALETTES[@]} ))
      else
        NEXT=$(( (IDX + 1) % ''${#PALETTES[@]} ))
      fi
      
      PALETTE="''${PALETTES[$NEXT]}"
      echo "$PALETTE" > "$CACHE"
      
      case "$PALETTE" in
        demod)
          ACTIVE="rgba(00D4AAee) rgba(4ECDC4ee) 45deg"
          INACTIVE="rgba(1A1A2Eaa)"
          ;;
        vim)
          ACTIVE="rgba(33ff33ee) rgba(00ff00ee) 45deg"
          INACTIVE="rgba(595959aa)"
          ;;
        amber)
          ACTIVE="rgba(ffaa00ee) rgba(ff6600ee) 45deg"
          INACTIVE="rgba(4a4a4aaa)"
          ;;
        purple)
          ACTIVE="rgba(aa00ffee) rgba(ff00aaee) 45deg"
          INACTIVE="rgba(4a3a4aaa)"
          ;;
        rose)
          ACTIVE="rgba(ff6b9dee) rgba(c44569ee) 45deg"
          INACTIVE="rgba(4a3a3aaa)"
          ;;
        gold)
          ACTIVE="rgba(ffd700ee) rgba(b8860bee) 45deg"
          INACTIVE="rgba(4a4a3aaa)"
          ;;
      esac
      
      hyprctl keyword general:col.active_border "$ACTIVE"
      hyprctl keyword general:col.inactive_border "$INACTIVE"
      notify-send -t 1500 -h string:x-canonical-private-synchronous:hypr "Hyprland" "Palette: ''${PALETTE^^}"
    '';
  };
  
  # ────────────────────────────────────────────────────────────────────────────
  # Hyprlock - DeMoD Theme Lock Screen
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".config/hypr/hyprlock.conf".text = ''
    general {
      disable_loading_bar = true
      hide_cursor = true
      grace = 3
      no_fade_in = false
    }
    
    background {
      monitor =
      path = screenshot
      blur_passes = 3
      blur_size = 8
      noise = 0.02
      contrast = 0.9
      brightness = 0.7
      vibrancy = 0.17
    }
    
    input-field {
      monitor =
      size = 300, 50
      outline_thickness = 2
      dots_size = 0.25
      dots_spacing = 0.15
      dots_center = true
      outer_color = rgba(00D4AAee)
      inner_color = rgba(1A1A2Eee)
      font_color = rgba(EAEAEAff)
      fade_on_empty = false
      placeholder_text = <i>Password...</i>
      hide_input = false
      position = 0, -100
      halign = center
      valign = center
    }
    
    label {
      monitor =
      text = $TIME
      font_size = 72
      font_family = JetBrains Mono Bold
      color = rgba(00D4AAff)
      position = 0, 100
      halign = center
      valign = center
    }
    
    label {
      monitor =
      text = DeMoD Compute Fabric
      font_size = 16
      font_family = JetBrains Mono
      color = rgba(EAEAEAaa)
      position = 0, 30
      halign = center
      valign = center
    }
  '';
  
  # ────────────────────────────────────────────────────────────────────────────
  # Hypridle - Idle Management
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".config/hypr/hypridle.conf".text = ''
    general {
      lock_cmd = pidof hyprlock || hyprlock
      before_sleep_cmd = loginctl lock-session
      after_sleep_cmd = hyprctl dispatch dpms on
    }
    
    # Dim screen after 5 minutes
    listener {
      timeout = 300
      on-timeout = brightnessctl -s set 10%
      on-resume = brightnessctl -r
    }
    
    # Lock after 10 minutes
    listener {
      timeout = 600
      on-timeout = loginctl lock-session
    }
    
    # Turn off display after 11 minutes
    listener {
      timeout = 660
      on-timeout = hyprctl dispatch dpms off
      on-resume = hyprctl dispatch dpms on
    }
    
    # Suspend after 30 minutes
    listener {
      timeout = 1800
      on-timeout = systemctl suspend
    }
  '';
  
  # ────────────────────────────────────────────────────────────────────────────
  # Wlogout - Power Menu
  # ────────────────────────────────────────────────────────────────────────────
  home.file.".config/wlogout/layout".text = ''
    {
      "label" : "lock",
      "action" : "hyprlock",
      "text" : "Lock",
      "keybind" : "l"
    }
    {
      "label" : "hibernate",
      "action" : "systemctl hibernate",
      "text" : "Hibernate",
      "keybind" : "h"
    }
    {
      "label" : "logout",
      "action" : "hyprctl dispatch exit",
      "text" : "Logout",
      "keybind" : "e"
    }
    {
      "label" : "shutdown",
      "action" : "systemctl poweroff",
      "text" : "Shutdown",
      "keybind" : "s"
    }
    {
      "label" : "suspend",
      "action" : "systemctl suspend",
      "text" : "Suspend",
      "keybind" : "u"
    }
    {
      "label" : "reboot",
      "action" : "systemctl reboot",
      "text" : "Reboot",
      "keybind" : "r"
    }
  '';
  
  home.file.".config/wlogout/style.css".text = ''
    * {
      background-image: none;
    }
    
    window {
      background-color: rgba(26, 26, 46, 0.9);
    }
    
    button {
      color: #EAEAEA;
      background-color: #16213E;
      border: 2px solid #4A4A6A;
      border-radius: 12px;
      margin: 10px;
      background-repeat: no-repeat;
      background-position: center;
      background-size: 25%;
      box-shadow: none;
      text-shadow: none;
    }
    
    button:focus, button:active, button:hover {
      background-color: #00D4AA;
      color: #1A1A2E;
      border-color: #00D4AA;
      outline: none;
    }
    
    #lock {
      background-image: image(url("/usr/share/wlogout/icons/lock.png"));
    }
    
    #logout {
      background-image: image(url("/usr/share/wlogout/icons/logout.png"));
    }
    
    #suspend {
      background-image: image(url("/usr/share/wlogout/icons/suspend.png"));
    }
    
    #hibernate {
      background-image: image(url("/usr/share/wlogout/icons/hibernate.png"));
    }
    
    #shutdown {
      background-image: image(url("/usr/share/wlogout/icons/shutdown.png"));
    }
    
    #reboot {
      background-image: image(url("/usr/share/wlogout/icons/reboot.png"));
    }
  '';

  # ────────────────────────────────────────────────────────────────────────────
  # Create Screenshots directory
  # ────────────────────────────────────────────────────────────────────────────
  home.file."Pictures/Screenshots/.keep".text = "";
  home.file.".config/hypr/wallpapers/.keep".text = "";
  
  # ────────────────────────────────────────────────────────────────────────────
  # State Version
  # ────────────────────────────────────────────────────────────────────────────
  home.stateVersion = "24.11";
}
