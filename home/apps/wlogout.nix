{ config, pkgs, lib, theme, ... }:

let
  p = theme;
in {
  # ══════════════════════════════════════════════════════════════════════════
  # Wlogout Power Menu Configuration
  # ══════════════════════════════════════════════════════════════════════════
  home.file.".config/wlogout/layout".text = ''
    {"label":"lock","action":"hyprlock","text":"Lock","keybind":"l"}
    {"label":"logout","action":"hyprctl dispatch exit","text":"Logout","keybind":"e"}
    {"label":"suspend","action":"systemctl suspend","text":"Sleep","keybind":"s"}
    {"label":"hibernate","action":"systemctl hibernate","text":"Hibernate","keybind":"h"}
    {"label":"reboot","action":"systemctl reboot","text":"Reboot","keybind":"r"}
    {"label":"shutdown","action":"systemctl poweroff","text":"Shutdown","keybind":"p"}
  '';

  home.file.".config/wlogout/style.css".text = ''
    * {
      background-image: none;
      font-family: "JetBrainsMono Nerd Font", "Inter", sans-serif;
      font-size: 14px;
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    }

    window {
      background: linear-gradient(180deg, 
        alpha(${p.bg}, 0.85) 0%, 
        alpha(${p.surface}, 0.80) 100%);
      animation: fadeIn 0.3s ease-out;
    }

    button {
      color: ${p.text};
      background: linear-gradient(180deg, 
        alpha(${p.surface}, 0.9) 0%, 
        alpha(${p.surfaceAlt}, 0.85) 100%);
      border: 2px solid alpha(${p.border}, 0.6);
      border-radius: 24px;
      margin: 16px;
      padding: 24px;
      min-width: 120px;
      min-height: 120px;
      background-repeat: no-repeat;
      background-position: center 35%;
      background-size: 28%;
    }

    button:focus,
    button:hover {
      border-color: ${p.accent};
      box-shadow: 
        0 8px 32px alpha(${p.accent}, 0.35),
        0 0 40px alpha(${p.accent}, 0.15);
      outline: none;
    }

    button:active {
      transform: scale(0.98);
    }

    #lock:focus, #lock:hover { 
      background: linear-gradient(135deg, ${p.info} 0%, ${p.accent} 100%);
      color: ${p.textOnAccent};
    }

    #logout:focus, #logout:hover { 
      background: linear-gradient(135deg, ${p.warning} 0%, ${p.orange} 100%);
      color: ${p.bg};
    }

    #suspend:focus, #suspend:hover { 
      background: linear-gradient(135deg, ${p.purple} 0%, ${p.pink} 100%);
      color: ${p.textOnAccent};
    }

    #hibernate:focus, #hibernate:hover { 
      background: linear-gradient(135deg, ${p.accentDim} 0%, ${p.purple} 100%);
      color: ${p.textOnAccent};
    }

    #reboot:focus, #reboot:hover { 
      background: linear-gradient(135deg, ${p.accentAlt} 0%, ${p.info} 100%);
      color: ${p.textOnAccent};
    }

    #shutdown:focus, #shutdown:hover { 
      background: linear-gradient(135deg, ${p.error} 0%, #FF6B7F 100%);
      color: ${p.text};
    }
  '';
}
