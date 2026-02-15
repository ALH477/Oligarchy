{ config, pkgs, lib, theme, ... }:

let
  p = theme;
in {
  # ══════════════════════════════════════════════════════════════════════════
  # Wofi Launcher Configuration
  # ══════════════════════════════════════════════════════════════════════════
  home.file.".config/wofi/config".text = ''
    width=700
    height=500
    location=center
    show=drun
    prompt=  Search applications...
    filter_rate=100
    allow_markup=true
    no_actions=true
    insensitive=true
    allow_images=true
    image_size=42
    gtk_dark=true
    layer=overlay
    columns=1
    orientation=vertical
    halign=fill
    line_wrap=off
    dynamic_lines=false
    content_halign=fill
    matching=contains
    sort_order=alphabetical
    hide_scroll=false
    key_expand=Tab
    key_exit=Escape
  '';

  home.file.".config/wofi/style.css".text = ''
    @define-color bg ${p.bg};
    @define-color surface ${p.surface};
    @define-color accent ${p.accent};
    @define-color accent-alt ${p.accentAlt};
    @define-color text ${p.text};
    @define-color text-dim ${p.textDim};
    @define-color border ${p.border};
    
    * {
      font-family: "JetBrainsMono Nerd Font", "Inter", system-ui, sans-serif;
      font-size: 14px;
      outline: none;
    }

    window {
      background: linear-gradient(160deg, 
        alpha(@bg, 0.92) 0%, 
        alpha(@surface, 0.88) 50%,
        alpha(@bg, 0.92) 100%);
      border: 2px solid alpha(@accent, 0.6);
      border-radius: 24px;
      box-shadow: 
        0 0 0 1px alpha(@border, 0.3),
        0 12px 48px rgba(0, 0, 0, 0.6),
        0 0 60px alpha(@accent, 0.08),
        inset 0 1px 0 alpha(white, 0.05);
      animation: fadeIn 0.2s ease-out;
    }

    #input {
      margin: 18px 18px 12px 18px;
      padding: 16px 20px;
      border: 2px solid alpha(@border, 0.5);
      border-radius: 16px;
      background: linear-gradient(135deg, 
        alpha(@surface, 0.8) 0%, 
        alpha(@bg, 0.9) 100%);
      color: @text;
      font-size: 16px;
      font-weight: 500;
      caret-color: @accent;
      transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1);
    }

    #input:focus {
      border-color: @accent;
      box-shadow: 
        0 0 0 4px alpha(@accent, 0.12),
        0 0 20px alpha(@accent, 0.1);
    }

    #entry {
      padding: 14px 18px;
      margin: 4px 0;
      border-radius: 14px;
      background: transparent;
      border: 2px solid transparent;
      transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
    }

    #entry:hover {
      background: alpha(@accent, 0.08);
      border-color: alpha(@accent, 0.15);
    }

    #entry:selected {
      background: linear-gradient(135deg, 
        alpha(${p.gradientStart}, 0.95) 0%, 
        alpha(${p.gradientEnd}, 0.9) 100%);
      border-color: transparent;
      box-shadow: 
        0 4px 16px alpha(@accent, 0.35),
        0 0 0 1px alpha(white, 0.1),
        inset 0 1px 0 alpha(white, 0.15);
    }

    #text {
      color: @text;
      font-weight: 500;
      margin-left: 4px;
    }

    #text:selected {
      color: ${p.textOnAccent};
      font-weight: 600;
    }

    #img {
      margin-right: 14px;
      border-radius: 10px;
      background: alpha(@surface, 0.5);
      padding: 4px;
    }
  '';
}
