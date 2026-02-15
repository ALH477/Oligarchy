{ config, pkgs, lib, theme ? {}, ... }:

{
  # ════════════════════════════════════════════════════════════════════════════
  # Dolphin File Manager Configuration
  # ════════════════════════════════════════════════════════════════════════════
  
  home.file.".config/dolphinrc".text = ''
    [General]
    EditableUrl=true
    GlobalViewProps=true
    RememberOpenedTabs=false
    ShowFullPath=true
    ShowFullPathInTitlebar=true
    ShowZoomSlider=false
    SortingChoice=CaseInsensitiveSorting
    Version=202
    ViewPropsTimestamp=2024,1,1,0,0,0
    
    [IconsMode]
    IconSize=48
    PreviewSize=48
    
    [KFileDialog Settings]
    Places Icons Auto-resize=false
    Places Icons Static Size=22
    
    [MainWindow]
    MenuBar=Disabled
    ToolBarsMovable=Disabled
    
    [PreviewSettings]
    Plugins=appimagethumbnail,audiothumbnail,blenderthumbnail,comicbookthumbnail,cursorthumbnail,djvuthumbnail,ebookthumbnail,exrthumbnail,directorythumbnail,fontthumbnail,imagethumbnail,jaborathumbnail,kraborathumbnail,opaborathumbnail,moaborathumbnail,windowsimagethumbnail,windowsexethumbnail
    
    [VersionControl]
    enabledPlugins=Git
  '';

  home.file.".config/dolphinstylerc".text = ''
    [DetailsView]
    FontSize=10
    
    [Settings]
    Icons=true
    ModifiedShown=true
    SizeDisplay=2
    ViewMode=2
  '';
}
