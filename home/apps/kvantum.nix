{ config, pkgs, lib, theme ? {}, ... }:

let
  p = theme;
  themeName = lib.toLower p.name;
in
{
  # ════════════════════════════════════════════════════════════════════════════
  # Kvantum Theme Configuration - Theme-aware Qt styling engine
  # ════════════════════════════════════════════════════════════════════════════
  
  # Main Kvantum config
  home.file.".config/Kvantum/kvantum.kvconfig".text = ''
    [General]
    theme=${p.name}
  '';

  # Kvantum theme configuration
  home.file.".config/Kvantum/${p.name}/${p.name}.kvconfig".text = ''
    [%General]
    author=DeMoD
    comment=${p.name} Dark Theme - Theme-aware Qt styling
    x11drag=menubar_and_primary_toolbar
    alt_mnemonic=true
    left_tabs=false
    attach_active_tab=true
    mirror_doc_tabs=false
    group_toolbar_buttons=false
    toolbar_item_spacing=2
    toolbar_interior_spacing=2
    spread_progressbar=true
    composite=true
    menu_shadow_depth=7
    spread_menuitems=true
    tooltip_shadow_depth=6
    splitter_width=1
    scroll_width=12
    scroll_arrows=false
    scroll_min_extent=36
    slider_width=4
    slider_handle_width=18
    slider_handle_length=18
    tickless_slider_handle_size=18
    center_toolbar_handle=true
    check_size=16
    textless_progressbar=false
    progressbar_thickness=4
    menubar_mouse_tracking=true
    toolbutton_style=0
    click_behavior=0
    translucent_windows=true
    blurring=true
    popup_blurring=true
    vertical_spin_indicators=false
    spin_button_width=16
    fill_rubberband=false
    merge_menubar_with_toolbar=false
    small_icon_size=16
    large_icon_size=32
    button_icon_size=16
    toolbar_icon_size=22
    combo_as_lineedit=true
    button_contents_shift=false
    iconless_pushbutton=false
    iconless_menu=false
    scrollbar_in_view=false
    transient_scrollbar=true
    transient_groove=true
    dark_titlebar=true
    respect_DE=true
    
    [GeneralColors]
    window.color=${p.bg}
    base.color=${p.bgAlt}
    alt.base.color=${p.surface}
    button.color=${p.surfaceAlt}
    light.color=${p.border}
    mid.light.color=${p.overlay}
    dark.color=${p.black}
    mid.color=${p.surface}
    highlight.color=${p.accent}
    inactive.highlight.color=${p.purple}
    text.color=${p.text}
    window.text.color=${p.text}
    button.text.color=${p.text}
    disabled.text.color=${p.textDim}
    tooltip.text.color=${p.text}
    highlight.text.color=${p.textOnAccent}
    link.color=${p.accent}
    link.visited.color=${p.pink}
    progress.indicator.text.color=${p.textOnAccent}
    
    [Hacks]
    transparent_dolphin_view=false
    transparent_pcmanfm_sidepane=true
    transparent_pcmanfm_view=false
    blur_translucent=true
    transparent_ktitle_label=true
    transparent_menutitle=true
    respect_darkness=true
    kcapacitybar_as_progressbar=true
    force_size_grip=true
    iconless_pushbutton=false
    iconless_menu=false
    disabled_icon_opacity=70
    lxqtmainmenu_iconsize=22
    normal_default_pushbutton=true
    single_top_toolbar=false
    tint_on_mouseover=0
    middle_click_scroll=false
    no_selection_tint=false
    transparent_arrow_button=true
    style_vertical_toolbars=false
  '';

  # Kvantum theme SVG
  home.file.".config/Kvantum/${p.name}/${p.name}.svg".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <defs>
        <linearGradient id="accentGrad" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" style="stop-color:${p.gradientStart}"/>
          <stop offset="100%" style="stop-color:${p.gradientEnd}"/>
        </linearGradient>
      </defs>
    </svg>
  '';
}
