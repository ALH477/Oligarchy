{ config, pkgs, lib, theme ? {}, ... }:

let
  p = theme;
in
{
  # ════════════════════════════════════════════════════════════════════════════
  # GTK 3/4 Theming Configuration - Theme-aware styling
  # ════════════════════════════════════════════════════════════════════════════
  
  # GTK 3 Settings
  home.file.".config/gtk-3.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=true
    gtk-button-images=true
    gtk-cursor-theme-name=idTech4
    gtk-cursor-theme-size=24
    gtk-decoration-layout=close,minimize,maximize:menu
    gtk-enable-animations=true
    gtk-enable-event-sounds=false
    gtk-enable-input-feedback-sounds=false
    gtk-error-bell=false
    gtk-font-name=Inter 10
    gtk-icon-theme-name=Papirus-Dark
    gtk-menu-images=true
    gtk-primary-button-warps-slider=false
    gtk-theme-name=Breeze-Dark
    gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
    gtk-toolbar-style=GTK_TOOLBAR_BOTH_HORIZ
    gtk-xft-antialias=1
    gtk-xft-dpi=98304
    gtk-xft-hinting=1
    gtk-xft-hintstyle=hintslight
    gtk-xft-rgba=rgb
  '';

  # GTK 3 Custom CSS
  home.file.".config/gtk-3.0/gtk.css".text = ''
    /* DeMoD GTK3 Overrides - Theme-aware styling */
    @define-color theme_bg_color ${p.bg};
    @define-color theme_fg_color ${p.text};
    @define-color theme_base_color ${p.bgAlt};
    @define-color theme_text_color ${p.text};
    @define-color theme_selected_bg_color ${p.accent};
    @define-color theme_selected_fg_color ${p.textOnAccent};
    @define-color theme_tooltip_bg_color ${p.surface};
    @define-color theme_tooltip_fg_color ${p.text};
    @define-color accent_color ${p.accent};
    @define-color accent_bg_color ${p.accent};
    @define-color accent_fg_color ${p.textOnAccent};
    
    /* Scrollbars */
    scrollbar slider {
      min-width: 8px;
      min-height: 8px;
      border-radius: 4px;
      background-color: alpha(${p.accent}, 0.4);
      transition: all 0.15s ease;
    }
    
    scrollbar slider:hover {
      background-color: alpha(${p.accent}, 0.6);
    }
    
    scrollbar slider:active {
      background-color: ${p.accent};
    }
    
    /* Selection */
    selection, *:selected {
      background-color: ${p.accent};
      color: ${p.textOnAccent};
    }
    
    /* Links */
    *:link {
      color: ${p.accent};
      transition: color 0.15s ease;
    }
    
    *:visited {
      color: ${p.pink};
    }
    
    *:link:hover {
      color: ${p.purple};
    }
    
    /* Buttons */
    button {
      transition: all 0.2s ease;
    }
    
    button:checked {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
      color: ${p.textOnAccent};
    }
    
    button:hover {
      box-shadow: 0 4px 12px alpha(${p.accent}, 0.2);
    }
    
    button:focus {
      outline: none;
      box-shadow: 0 0 0 3px alpha(${p.accent}, 0.3);
    }
    
    /* Entries/Inputs */
    entry {
      transition: all 0.2s ease;
      border-radius: 8px;
    }
    
    entry:focus {
      box-shadow: 0 0 0 3px alpha(${p.accent}, 0.15);
    }
    
    /* Progress bars */
    progressbar progress {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
      border-radius: 4px;
    }
    
    /* Switches */
    switch {
      transition: all 0.25s ease;
    }
    
    switch:checked {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
    }
    
    switch:checked slider {
      background-color: ${p.text};
    }
    
    /* Scale/Sliders */
    scale highlight {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
    }
    
    scale slider {
      background-color: ${p.text};
    }
    
    /* Checkboxes & Radio */
    checkbutton check:checked,
    radiobutton radio:checked {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
      color: ${p.textOnAccent};
    }
    
    /* Reduced Motion Support */
    @media (prefers-reduced-motion: reduce) {
      * {
        transition-duration: 0.01ms !important;
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
      }
    }
  '';

  # GTK 4 Settings
  home.file.".config/gtk-4.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=true
    gtk-cursor-theme-name=idTech4
    gtk-cursor-theme-size=24
    gtk-decoration-layout=close,minimize,maximize:menu
    gtk-enable-animations=true
    gtk-font-name=Inter 10
    gtk-icon-theme-name=Papirus-Dark
    gtk-theme-name=Adwaita-dark
    gtk-xft-antialias=1
    gtk-xft-hinting=1
    gtk-xft-hintstyle=hintslight
    gtk-xft-rgba=rgb
  '';

  # GTK 4 Custom CSS
  home.file.".config/gtk-4.0/gtk.css".text = ''
    /* DeMoD GTK4 Overrides - Theme-aware styling */
    @define-color window_bg_color ${p.bg};
    @define-color window_fg_color ${p.text};
    @define-color view_bg_color ${p.bgAlt};
    @define-color view_fg_color ${p.text};
    @define-color card_bg_color ${p.surface};
    @define-color card_fg_color ${p.text};
    @define-color headerbar_bg_color ${p.bg};
    @define-color headerbar_fg_color ${p.text};
    @define-color popover_bg_color ${p.surface};
    @define-color popover_fg_color ${p.text};
    @define-color dialog_bg_color ${p.surface};
    @define-color dialog_fg_color ${p.text};
    @define-color sidebar_bg_color ${p.bgAlt};
    @define-color sidebar_fg_color ${p.text};
    @define-color accent_color ${p.accent};
    @define-color accent_bg_color ${p.accent};
    @define-color accent_fg_color ${p.textOnAccent};
    @define-color destructive_color ${p.error};
    @define-color success_color ${p.success};
    @define-color warning_color ${p.warning};
    @define-color error_color ${p.error};
    
    /* Global Selection */
    selection {
      background-color: ${p.accent};
      color: ${p.textOnAccent};
    }
    
    /* Accent Elements */
    .accent {
      color: ${p.accent};
    }
    
    /* Buttons */
    button {
      transition: all 0.2s ease;
    }
    
    button:hover {
      box-shadow: 0 4px 12px alpha(${p.accent}, 0.15);
    }
    
    button:focus {
      outline: none;
      box-shadow: 0 0 0 3px alpha(${p.accent}, 0.3);
    }
    
    button.suggested-action {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
      color: ${p.textOnAccent};
      box-shadow: 0 4px 12px alpha(${p.accent}, 0.3);
    }
    
    button.suggested-action:hover {
      background-image: linear-gradient(135deg, ${p.accentAlt}, ${p.purple});
      box-shadow: 0 6px 20px alpha(${p.accent}, 0.4);
    }
    
    button.destructive-action {
      background-color: ${p.error};
      color: ${p.text};
    }
    
    button.destructive-action:hover {
      background-color: ${p.brightRed};
      box-shadow: 0 4px 12px alpha(${p.error}, 0.3);
    }
    
    /* Entries/Inputs */
    entry {
      transition: all 0.2s ease;
      border-radius: 12px;
    }
    
    entry:focus {
      box-shadow: 0 0 0 3px alpha(${p.accent}, 0.15);
    }
    
    /* Progress bars */
    progressbar > trough > progress {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
    }
    
    /* Switches */
    switch {
      transition: all 0.25s ease;
    }
    
    switch:checked {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
    }
    
    /* Scale/Slider */
    scale highlight {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
    }
    
    scale slider {
      background-color: ${p.text};
    }
    
    /* Links */
    link, .link {
      color: ${p.accent};
      transition: color 0.15s ease;
    }
    
    link:visited, .link:visited {
      color: ${p.pink};
    }
    
    link:hover, .link:hover {
      color: ${p.purple};
    }
    
    /* Scrollbars */
    scrollbar slider {
      background-color: alpha(${p.accent}, 0.4);
      border-radius: 9999px;
      min-width: 8px;
      min-height: 8px;
      transition: all 0.15s ease;
    }
    
    scrollbar slider:hover {
      background-color: alpha(${p.accent}, 0.6);
    }
    
    scrollbar slider:active {
      background-color: ${p.accent};
    }
    
    /* Check and Radio Buttons */
    checkbutton check:checked,
    radiobutton radio:checked {
      background-image: linear-gradient(135deg, ${p.gradientStart}, ${p.gradientEnd});
      color: ${p.textOnAccent};
    }
    
    checkbutton check:focus,
    radiobutton radio:focus {
      box-shadow: 0 0 0 3px alpha(${p.accent}, 0.3);
    }
    
    /* Headerbar */
    headerbar {
      background-color: ${p.bg};
      border-bottom: 1px solid ${p.border};
    }
    
    /* Window Controls */
    windowcontrols button.close:hover {
      background-color: ${p.error};
    }
    
    windowcontrols button.minimize:hover,
    windowcontrols button.maximize:hover {
      background-color: alpha(${p.text}, 0.1);
    }
    
    /* Cards */
    .card {
      background-color: ${p.surface};
      border: 1px solid ${p.border};
      border-radius: 16px;
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.4);
      transition: all 0.2s ease;
    }
    
    .card:hover {
      border-color: ${p.purple};
    }
    
    /* Reduced Motion Support */
    @media (prefers-reduced-motion: reduce) {
      * {
        transition-duration: 0.01ms !important;
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
      }
    }
  '';
}
