{ config, pkgs, lib, theme ? { }, features ? { }, themes ? { }, osConfig ? { }, ... }:

let
  p = theme; # Shorthand for palette

  # -- Locale (custom.locale.*, declared in modules/locale.nix) ---------------
  # Read with `or` defaults at every hop, exactly as home/hyprland/default.nix
  # reads the same option: home/ must still evaluate standalone, and on a fresh
  # clone where the NixOS module declaring these options is absent. The
  # 12-hour table below is kept LOCAL for that same reason -- do NOT import
  # modules/locale/lib.nix here.
  locale = osConfig.custom.locale or { };

  # custom.vpn (modules/vpn.nix). Same `or` discipline as `locale` above: home/
  # has to evaluate standalone, and on a fresh clone the NixOS module declaring
  # this option is not in scope. The tunnel is on demand, so an indicator is
  # not decoration -- without one there is nothing on screen that says whether
  # traffic is currently leaving through Windscribe.
  vpnEnabled = osConfig.custom.vpn.enable or false;
  glibcLocale = locale.glibcLocale or "en_US.UTF-8";
  lang = locale.language or "en-US";

  # docs/localization-roadmap.md section 7 stage 1's table is en-US / en-PH /
  # en-CA = 12-hour, everything else 24. en-US is left OUT of it here on
  # purpose: it is also the DEFAULT of custom.locale.language, so honouring it
  # would flip this machine's clock from 24h to 12h on a rebuild whose only
  # intended diff is the console keymap. The 12-hour form is therefore
  # reserved for a language EXPLICITLY set to one of the other two, until a
  # `custom.locale.clock24h` option exists to say "12-hour locale, 24-hour
  # clock" properly (recorded as a roadmap gap).
  use24h = !(lib.elem lang [ "en-PH" "en-CA" ]);

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
      (lib.optional (features.enableAudio or false) "custom/dsp")
      (lib.optional (features.enableAudio or false) "group/audio")
      (lib.optional (features.hasBacklight or false) "backlight")
      (lib.optional (features.hasBattery or false) "battery")
      "group/network"
      (lib.optional vpnEnabled "custom/vpn")
      (lib.optional (features.enableGaming or false) "custom/gamemode")
      "custom/caffeine"
      (lib.optional (features.enableDev or false) "custom/repo-updates")
      "tray"
      "custom/power"
    ];
  };

  # See home/apps/wofi.nix for why this is factored into a function of
  # `p` — theme-switch.sh symlinks a pre-rendered variant into place live.
  renderStyle = p: ''
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
    #custom-logo,
    #workspaces,
    #window,
    #clock,
    #custom-media,
    #pulseaudio,
    #backlight,
    #battery,
    #network,
    #tray,
    #custom-power {
      background: ${p.surface};
      color: ${p.text};
      padding: 0 16px;
      margin: 0 4px;
      border-radius: 14px;
      border: 2px solid ${p.border};
      box-shadow: 0 2px 8px rgba(0, 0, 0, 0.2);
    }

    /* Logo module special styling */
    #custom-logo {
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

    /* Windscribe tunnel (custom.vpn). Only present when the module is on. */
    #custom-vpn {
      color: ${p.success};
      padding: 0 8px;
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
    #custom-power {
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
    #custom-media:hover,
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

    /* NOTE: @media queries removed — GTK CSS has no media-query support;
       waybar logged parse errors and ignored those blocks anyway. */
  '';

in
{
  programs.waybar = {
    enable = true;
    # Supervised by Home Manager's own waybar-module unit — gets
    # ConditionEnvironment=WAYLAND_DISPLAY and config/style hot-reload for
    # free, and restarts on crash instead of leaving the bar silently absent.
    systemd = {
      enable = true;
      target = "hyprland-session.target";
    };

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
        tooltip-format = "Oligarchy · The War Machine\n\n<b>Keybindings</b>\n󰌨 Super+D: App Launcher\n󰍜 Super+Return: Terminal\n󰀻 Super+F: Fullscreen\n\n<b>Quick Actions</b>\n󱓞 Click: App Launcher\n󰍜 Right: System Info";
        on-click = "wofi --show drun -I";
        on-click-right = "kitty --class floating-term -e btop";
      };

      "hyprland/workspaces" = {
        format = "{icon}";
        format-icons = {
          "1" = "󰎤";
          "2" = "󰎧";
          "3" = "󰎪";
          "4" = "󰎭";
          "5" = "󰎯";
          "6" = "󰎰";
          "7" = "󰎱";
          "8" = "󰎳";
          "9" = "󰎶";
          "10" = "󰎸";
          urgent = "󰀫";
          active = "󰀺";
          default = "󰎤";
          special = "󰠱";
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
        format = if use24h then "󰥔  {:%H:%M}" else "󰥔  {:%I:%M %p}";
        # waybar's own clock `locale` key (waybar-clock(5)); it is also what
        # makes {calendar}'s start-of-week follow the locale rather than the
        # system one.
        locale = glibcLocale;
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
          default = "";
          playing = "";
          paused = "";
        };
        exec = "playerctl -a metadata --format='{{title}} - {{artist}}' --follow 2>/dev/null | head -n-1";
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
      };

      # Top-level definition — waybar resolves group members by name from the
      # root config; a definition nested inside the group block is ignored.
      "custom/wireplumber-microphone" = {
        format = "{format_source}";
        format-source = "󰍬 {volume}%";
        format-source-muted = "󰍭 Muted";
        tooltip-format = "Microphone: {volume}%";
        on-click = "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle";
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
          default = [ "󰕿" "󰖀" "󰕾" ];
        };
        on-click = "pavucontrol";
        on-scroll-up = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+";
        on-scroll-down = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";
        tooltip-format = "{desc}";
      };

      "backlight" = {
        # device omitted — auto-detects amdgpu_bl* on the Framework 16.
        # The old hardcoded "intel_backlight" matched nothing on AMD.
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
        tooltip-format-wifi = "󰖩 {essid} ({signalStrength}%)\n {bandwidthDownBits} 󰕒 {bandwidthUpBits}";
        tooltip-format-ethernet = "󰈀 {ifname}\n {bandwidthDownBits} 󰕒 {bandwidthUpBits}";
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

      "custom/power" = {
        format = "󰐥";
        tooltip = true;
        tooltip-format = "Power Menu\n󰍃 Click: Logout\n󰜉 Right: Reboot\n󰐥 Middle: Shutdown";
        on-click = "hyprctl dispatch exit";
        on-click-right = "reboot";
        on-click-middle = "shutdown now";
      };

      # Always defined; only *referenced* in modules-right when enableGaming.
      # (lib.mkIf inside JSON-serialized settings leaks _type/condition attrs
      # into the generated config file — never use it here.)
      "custom/gamemode" = {
        format = "{}";
        exec = "~/.config/hypr/scripts/gamemode.sh status";
        return-type = "json";
        interval = 2;
        tooltip = true;
        on-click = "~/.config/hypr/scripts/gamemode.sh toggle";
      };

      # Always defined, referenced only when custom.vpn.enable -- same reason
      # as custom/gamemode above: lib.mkIf inside these serialized settings
      # leaks _type/condition attrs into the generated JSON.
      "custom/vpn" = {
        format = "{}";
        exec = "oligarchy-vpn status --icon";
        interval = 5;
        tooltip = true;
        tooltip-format = "Windscribe WireGuard (on demand)\\nClick to toggle · Right: full status";
        on-click = "oligarchy-vpn toggle";
        on-click-right = "kitty --class floating-term -e bash -c 'oligarchy-vpn status; echo; read -n1 -p \"press any key\"'";
      };

      "custom/caffeine" = {
        format = "{}";
        exec = "test \"$(caffeine status)\" = on && echo '󰅶' || echo '󰾪'";
        interval = 2;
        tooltip = true;
        tooltip-format = "Caffeine — idle inhibitor\\nClick to toggle (Super+F10)";
        on-click = "caffeine toggle";
      };

      # Silent when clean (empty text -> effectively invisible; no polling
      # network calls — reads state a systemd user timer refreshes every
      # 30m, see home/scripts/default.nix). Only appears as a small "⇡ N"
      # badge once there's actually something to know about.
      "custom/repo-updates" = {
        format = "{}";
        exec = "repo-update-check --quiet";
        return-type = "json";
        interval = 300;
        tooltip = true;
        on-click = "kitty --class floating-term -e bash -c 'repo-update-check --log; echo; read -n1 -p \"press any key\"'";
      };

      "custom/dsp" = {
        format = "🎛 {}";
        exec = "dsp-latency";
        interval = 3;
        tooltip = true;
        tooltip-format = "DSP latency · active rig\\nScroll: volume · Click: Control Center · Right: next output · Middle: mute";
        on-click = "oligarchy-menu";
        on-click-right = "audio-dev next sink";
        on-click-middle = "audio-dev mute sink";
        on-scroll-up = "swayosd-client --output-volume raise --max-volume 100";
        on-scroll-down = "swayosd-client --output-volume lower";
      };
    };

    # ════════════════════════════════════════════════════════════════════════════
    # Enhanced Waybar Stylesheet with Animations
    # ════════════════════════════════════════════════════════════════════════════
    style = renderStyle p;
  };

  # force = true on the generated style.css: home/scripts/theme-switch.sh
  # live-repoints ~/.config/waybar/style.css with `ln -sfn` as a theme preview.
  # Without force, that foreign symlink blocks Home Manager's link step and
  # EVERY activation fails (clobbered-file error), silently freezing the
  # deployed generation. Force wins: HM owns the path on switch; theme-switch
  # remains a next-boot-reset preview.
  xdg.configFile."waybar/style.css".force = true;

  home.file = lib.mapAttrs'
    (id: pal: lib.nameValuePair ".config/oligarchy/themes/${id}/waybar.css" {
      text = renderStyle pal;
    })
    themes;
}
