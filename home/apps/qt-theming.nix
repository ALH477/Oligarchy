{ config, pkgs, lib, theme, ... }:

{
  # ════════════════════════════════════════════════════════════════════════════
  # Qt5/Qt6 Platform Theme Configuration
  # ════════════════════════════════════════════════════════════════════════════
  
  # Qt5 Configuration
  home.file.".config/qt5ct/qt5ct.conf".text = ''
    [Appearance]
    color_scheme_path=
    custom_palette=true
    icon_theme=Papirus-Dark
    standard_dialogs=default
    style=kvantum
    
    [Fonts]
    fixed="JetBrains Mono,10,-1,5,50,0,0,0,0,0"
    general="Inter,10,-1,5,50,0,0,0,0,0"
    
    [Interface]
    activate_item_on_single_click=1
    buttonbox_layout=0
    cursor_flash_time=1000
    dialog_buttons_have_icons=1
    double_click_interval=400
    gui_effects=@Invalid()
    keyboard_scheme=2
    menus_have_icons=true
    show_shortcuts_in_context_menus=true
    stylesheets=@Invalid()
    toolbutton_style=4
    underline_shortcut=1
    wheel_scroll_lines=3
    
    [PaletteEditor]
    geometry=@ByteArray()
    
    [SettingsWindow]
    geometry=@ByteArray()
  '';

  # Qt6 Configuration
  home.file.".config/qt6ct/qt6ct.conf".text = ''
    [Appearance]
    color_scheme_path=
    custom_palette=true
    icon_theme=Papirus-Dark
    standard_dialogs=default
    style=kvantum
    
    [Fonts]
    fixed="JetBrains Mono,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
    general="Inter,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
    
    [Interface]
    activate_item_on_single_click=1
    buttonbox_layout=0
    cursor_flash_time=1000
    dialog_buttons_have_icons=1
    double_click_interval=400
    gui_effects=@Invalid()
    keyboard_scheme=2
    menus_have_icons=true
    show_shortcuts_in_context_menus=true
    stylesheets=@Invalid()
    toolbutton_style=4
    underline_shortcut=1
    wheel_scroll_lines=3
  '';

  # Qt Platform Plugin Configuration
  home.file.".config/QtProject.conf".text = ''
    [Qt]
    Qtlanguage=en_US
    
    [Qt\PlatformPluginCache]
    .\.78\.+0\.+0\F83BD7C9-64AA-3F86-93A2-2E1D3BBD2310=wayland;xcb
  '';
}
