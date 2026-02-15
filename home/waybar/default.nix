{ config, pkgs, lib, theme ? {}, features ? {}, ... }:

let
  p = theme;  # Shorthand for palette
  
  # Define module layouts based on features
  mkWaybarModules = {
    left = [
      "custom/logo"
      "hyprland/workspaces"
      "hyprland/submap"
      "hyprland/window"
    ];
    
    center = [ "clock" ];
    
    right = lib.flatten [
      "custom/media"
      (lib.optional (features.enableAudio or false) "group/audio")
      (lib.optional (features.hasBacklight or false) "backlight")
      (lib.optional (features.hasBattery or false) "battery")
      "group/network"
      (lib.optional (features.enableGaming or false) "custom/gamemode")
      "tray"
      "custom/power"
    ];
  };
  
in {
  programs.waybar = {
    enable = true;
    systemd.enable = false;
    
    settings.mainBar = {
      # Layout
      layer = "top";
      position = "top";
      height = 50;
      margin-top = 6;
      margin-left = 10;
      margin-right = 10;
      spacing = 0;

      modules-left = mkWaybarModules.left;
      modules-center = mkWaybarModules.center;
      modules-right = mkWaybarModules.right;

      # ══════════════════════════════════════════════════════════════════════════
      # Module Configurations
      # ══════════════════════════════════════════════════════════════════════════
      
      "custom/logo" = {
        format = "󱄅";
        tooltip = true;
        tooltip-format = "DeMoD Workstation\n\n<b>Keybindings</b>\n󰌨 Super+D: App Launcher\n󰍜 Super+Return: Terminal\n󰀻 Super+F: Fullscreen\n\n<b>Quick Actions</b>\n󱓞 Click: App Launcher\n󰍜 Right: System Info";
        on-click = "wofi --show drun -I";
        on-click-right = "kitty --class floating-term -e btop";
      };

      "hyprland/workspaces" = {
        format = "{icon}";
        format-icons = {
          "1" = "󰎤"; "2" = "󰎧"; "3" = "󰎪"; "4" = "󰎭"; "5" = "󰎯";
          "6" = "󰎰"; "7" = "󰎱"; "8" = "󰎳"; "9" = "󰎶"; "10" = "󰎸";
          urgent = "󰀫"; active = "󰀺"; default = "󰎤"; special = "󰠱";
        };
        on-click = "activate";
        on-scroll-up = "hyprctl dispatch workspace e+1";
        on-scroll-down = "hyprctl dispatch workspace e-1";
        persistent-workspaces = { "*" = 10; };
        all-outputs = false;
        show-special = true;
        special-visible-only = false;
      };

      "hyprland/submap" = {
        format = "{}";
        tooltip = false;
      };

      "hyprland/window" = {
        format = "{title}";
        max-length = 40;
        separate-outputs = true;
        rewrite = {
          "(.*) — Mozilla Firefox" = " $1";
          "(.*) - Brave" = "󰖟 $1";
          "(.*) - Visual Studio Code" = "󰨞 $1";
          "(.*)kitty" = " Terminal";
          "" = " Desktop";
        };
      };

      "clock" = {
        interval = 1;
        format = "󰥔  {:%H:%M}";
        format-alt = "󰃭  {:%A, %B %d   󰥔  %H:%M:%S}";
        tooltip = true;
        tooltip-format = "<big><b>{:%B %Y}</b></big>\n\n<tt>{calendar}</tt>";
        actions = {
          "on-scroll-up" = "tz_up";
          "on-scroll-down" = "tz_down";
        };
      };

      "custom/media" = {
        format = "{icon} {}";
        format-icons = {
          default = "";
          playing = "";
          paused = "";
        };
        exec = "playerctl -a metadata --format='{{title}} - {{artist}}' --follow 5>/dev/null | head -n-1";
        exec-if = "pgrep playerctl";
        on-click = "playerctl play-pause";
        on-click-right = "playerctl next";
        interval = 2;
        tooltip-format-players = "{}";
        tooltip-format = "{{player}}: {{title}} - {{artist}} ({{duration(position)}}/{{duration(mpris:length)}})";
      };

      "group/audio" = {
        orientation = "inherit";
        modules = [ "wireplumber" "custom/wireplumber-microphone" ];
        "custom/wireplumber-microphone" = {
          format = "{format_source}";
          format-source = "󰍬 {volume}%";
          format-source-muted = "󰍭 Muted";
          tooltip-format = "Microphone: {volume}%";
          on-click = "wpctl set-source-mute @DEFAULT_SOURCE@ toggle";
        };
      };

      "wireplumber" = {
        format = "{icon} {volume}%";
        format-muted = "󰖁 Muted";
        format-icons = {
          headphone = "󰋋";
          hands-free = "󰋐";
          headset = "󰋎";
          phone = "󰍲";
          portable = "󱘯";
          car = "󰄋";
          default = ["󰕿" "󰖀" "󰕾"];
        };
        on-click = "pavucontrol";
        on-scroll-up = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+";
        on-scroll-down = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
        tooltip-format = "{desc}";
      };

      "backlight" = {
        device = "intel_backlight";
        format = "{icon} {percent}%";
        format-icons = [ "󰃞" "󰃟" "󰃠" ];
        on-scroll-up = "brightnessctl set 5%+";
        on-scroll-down = "brightnessctl set 5%-";
        tooltip-format = "Brightness: {percent}%";
      };

      "battery" = {
        states = {
          warning = 30;
          critical = 15;
        };
        format = "{icon} {capacity}%";
        format-charging = "󰂄 {capacity}%";
        format-plugged = "󱘖 {capacity}%";
        format-alt = "{icon} {capacity}%";
        format-icons = [ "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰂁" "󰂀" ];
        tooltip-format = "{timeTo} {power}W";
        on-click = "powerprofilesctl set performance";
        on-click-right = "powerprofilesctl set power-saver";
      };

      "group/network" = {
        orientation = "inherit";
        modules = [ "network" ];
      };

      "network" = {
        format-wifi = "󰖩 {signalStrength}%";
        format-ethernet = "󰈀 {ifname}";
        tooltip-format-wifi = "󰖩 {essid} ({signalStrength}%)\n {bandwidthDownBits} 󰕒 {bandwidthUpBits}";
        tooltip-format-ethernet = "󰈀 {ifname}\n {bandwidthDownBits} 󰕒 {bandwidthUpBits}";
        format-linked = "󰖪 {ifname} (No IP)";
        format-disconnected = "󰖪 Disconnected";
        format-alt = "󰀂 {ifname}: {ipaddr}/{cidr}";
        on-click = "nm-connection-editor";
        on-click-right = "kitty --class floating-term -e nmtui";
        interval = 5;
      };

      "tray" = {
        icon-size = 18;
        spacing = 8;
        show-passive-items = false;
        tooltip-format = "{}";
      };

      # Theme signal handler (receives signals from Hyprland keybindings)
      "custom/theme" = {
        format = "";
        exec = "echo";
        interval = 0;
        signal = true;
        on-signal = "pkill -HUP waybar";
        tooltip = false;
      };

      "custom/power" = {
        format = "󰐥";
        tooltip = true;
        tooltip-format = "Power Menu\n󰍃 Click: Logout\n󰜉 Right: Reboot\n󰐥 Middle: Shutdown";
        on-click = "hyprctl dispatch exit";
        on-click-right = "reboot";
        on-click-middle = "shutdown now";
      };

      "custom/gamemode" = lib.mkIf (features.enableGaming or false) {
        format = "{}";
        exec = "~/.config/hypr/scripts/gamemode.sh status";
        return-type = "json";
        interval = 2;
        tooltip = true;
        on-click = "~/.config/hypr/scripts/gamemode.sh toggle";
      };
    };

    # ════════════════════════════════════════════════════════════════════════════
    # Enhanced Waybar Stylesheet with Animations
    # ════════════════════════════════════════════════════════════════════════════
    style = ''
      * {
        font-family: "JetBrainsMono Nerd Font", monospace;
        font-size: 14px;
        font-weight: 600;
        border: none;
        border-radius: 0;
        min-height: 0;
        transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
      }

      window#waybar {
        background: transparent;
        color: ${p.text};
      }

      /* Base module styling */
      #custom/logo,
      #workspaces,
      #window,
      #clock,
      #custom/media,
      #pulseaudio,
      #backlight,
      #battery,
      #network,
      #tray,
      #custom/power {
        background: ${p.surface};
        color: ${p.text};
        padding: 0 16px;
        margin: 0 4px;
        border-radius: 14px;
        border: 2px solid ${p.border};
        box-shadow: 0 2px 8px rgba(0, 0, 0, 0.2);
      }

      /* Logo module special styling */
      #custom/logo {
        color: ${p.accent};
        font-size: 20px;
        padding: 0 14px;
        border-color: ${p.accent};
        animation: logoGlow 3s ease-in-out infinite alternate;
      }

      @keyframes logoGlow {
        from { 
          box-shadow: 0 0 5px ${p.accent}44;
          border-color: ${p.accent};
        }
        to { 
          box-shadow: 0 0 20px ${p.accent}88, 0 0 30px ${p.accent}44;
          border-color: ${p.accentAlt};
        }
      }

      #custom-logo:hover {
        background: ${p.surfaceAlt};
        border-color: ${p.borderHover};
        transform: scale(1.05);
        animation: logoPulse 0.3s ease-out;
      }

      @keyframes logoPulse {
        0% { transform: scale(1); }
        50% { transform: scale(1.1); }
        100% { transform: scale(1.05); }
      }

      /* Workspaces styling */
      #workspaces button {
        padding: 0 8px;
        color: ${p.textDim};
        background: transparent;
        transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
        border-radius: 10px;
        margin: 2px;
      }

      #workspaces button.active {
        color: ${p.bg};
        background: ${p.accent};
        border-radius: 10px;
        margin: 2px;
        box-shadow: 0 4px 12px ${p.accent}66;
        animation: workspaceActive 0.3s ease-out;
      }

      @keyframes workspaceActive {
        0% { 
          transform: scale(1);
          background: ${p.accentDim};
        }
        50% { 
          transform: scale(1.1);
          background: ${p.accentAlt};
        }
        100% { 
          transform: scale(1);
          background: ${p.accent};
        }
      }

      #workspaces button:hover {
        color: ${p.accent};
        background: ${p.surfaceAlt};
        transform: translateY(-2px);
        box-shadow: 0 4px 8px rgba(0, 0, 0, 0.3);
      }

      #workspaces button.urgent {
        color: ${p.error};
          background: ${p.error}22;
        border: 2px solid ${p.error};
        animation: workspaceUrgent 1s ease-in-out infinite alternate;
      }

      @keyframes workspaceUrgent {
        from { opacity: 0.6; }
        to { opacity: 1; }
      }

      /* Window title styling */
      #window {
        color: ${p.text};
        font-weight: 500;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      /* Clock styling */
      #clock {
        color: ${p.accent};
        font-weight: 700;
        border-color: ${p.accent};
        animation: clockTicking 60s linear infinite;
      }

      @keyframes clockTicking {
        0% { opacity: 0.95; }
        50% { opacity: 1; }
        100% { opacity: 0.95; }
      }

      #clock:hover {
        background: ${p.surfaceAlt};
        transform: scale(1.02);
      }

      /* Media module styling */
      #custom-media {
        color: ${p.info};
        border-color: ${p.info};
      }

      #custom-media.playing {
        animation: mediaPlaying 2s ease-in-out infinite;
      }

      @keyframes mediaPlaying {
        0%, 100% { opacity: 0.8; }
        50% { opacity: 1; }
      }

      /* Audio modules */
      #wireplumber {
        color: ${p.info};
      }

      #pulseaudio.muted {
        color: ${p.error};
        animation: audioMuted 1s ease-in-out infinite alternate;
      }

      @keyframes audioMuted {
        from { opacity: 0.5; }
        to { opacity: 1; }
      }

      /* Battery module */
      #battery {
        color: ${p.success};
      }

      #battery.warning {
        color: ${p.warning};
        animation: batteryWarning 1s ease-in-out infinite alternate;
      }

      @keyframes batteryWarning {
        from { opacity: 0.7; }
        to { opacity: 1; }
      }

      #battery.critical {
        color: ${p.error};
        animation: batteryCritical 0.5s ease-in-out infinite alternate;
      }

      @keyframes batteryCritical {
        from { 
          opacity: 0.5;
        background: ${p.error}22;
        }
        to { 
          opacity: 1;
          background: ${p.error}44;
        }
      }

      #battery.charging {
        color: ${p.accent};
        animation: batteryCharging 3s ease-in-out infinite;
      }

      @keyframes batteryCharging {
        0%, 100% { opacity: 1; }
        50% { opacity: 0.6; }
      }

      /* Network module */
      #network {
        color: ${p.info};
      }

      #network.disconnected {
        color: ${p.error};
        animation: networkDisconnected 2s ease-in-out infinite alternate;
      }

      @keyframes networkDisconnected {
        from { opacity: 0.6; }
        to { opacity: 1; }
      }

      /* Tray styling */
      #tray {
        padding: 0 8px;
      }

      #tray > .passive {
        opacity: 0.6;
      }

      #tray > .needs-attention {
        animation: trayAttention 1s ease-in-out infinite alternate;
      }

      @keyframes trayAttention {
        from { background: ${p.warning}44; }
        to { background: ${p.warning}88; }
      }

      /* Power button styling */
      #custom/power {
        color: ${p.warning};
        border-color: ${p.warning};
        font-weight: 700;
      }

      #custom-power:hover {
        color: ${p.bg};
        background: ${p.error};
        border-color: ${p.error};
        transform: scale(1.1);
      }

      /* Group styling */
      .modules-group {
        border: 2px solid ${p.border};
        border-radius: 14px;
        background: ${p.surface};
        margin: 0 4px;
        box-shadow: 0 2px 8px rgba(0, 0, 0, 0.2);
      }

      .modules-group > * {
        border-radius: 0;
        border: none;
        box-shadow: none;
        margin: 0;
      }

      .modules-group > *:first-child {
        border-radius: 12px 0 0 12px;
        margin-left: 2px;
      }

      .modules-group > *:last-child {
        border-radius: 0 12px 12px 0;
        margin-right: 2px;
      }

      /* Tooltip styling */
      tooltip {
        background: ${p.surfaceAlt};
        border: 2px solid ${p.borderFocus};
        border-radius: 12px;
        padding: 8px 12px;
        color: ${p.text};
        font-size: 12px;
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
        animation: tooltipFadeIn 0.2s ease-out;
      }

      @keyframes tooltipFadeIn {
        from { 
          opacity: 0;
          transform: translateY(-4px);
        }
        to { 
          opacity: 1;
          transform: translateY(0);
        }
      }

      /* Hover effects for all modules */
      #custom/media:hover,
      #pulseaudio:hover,
      #backlight:hover,
      #battery:hover,
      #network:hover,
      #tray:hover {
        background: ${p.surfaceAlt};
        border-color: ${p.borderHover};
        transform: translateY(-2px);
        box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
      }

      /* Responsive adjustments */
      @media (max-width: 1200px) {
        #window {
          max-length: 30px;
        }
      }

      @media (max-width: 800px) {
        #window {
          display: none;
        }
        
        #custom-logo {
          font-size: 16px;
          padding: 0 10px;
        }
      }
    '';
  };
}