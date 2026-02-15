{ config, pkgs, lib, theme ? {}, ... }:

{
  # ════════════════════════════════════════════════════════════════════════════
  # KDE Baloo File Indexing Configuration
  # Disabled for gaming performance
  # ════════════════════════════════════════════════════════════════════════════
  
  home.file.".config/baloofilerc".text = ''
    [Basic Settings]
    Indexing-Enabled=false
    
    [General]
    dbVersion=2
    exclude filters=*~,*.part,*.o,*.la,*.lo,*.loT,*.moc,moc_*.cpp,qrc_*.cpp,ui_*.h,cmake_install.cmake,CMakeCache.txt,CTestTestfile.cmake,*.nvram,*.rcore,lzo,*.elc,*.qmlc,*.jsc,node_modules,.git,.hg,.svn
    exclude filters version=9
  '';
}
