{ stdenv, lib }:

stdenv.mkDerivation {
  pname = "oligarchy-plymouth-theme";
  version = "2.0.0";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/plymouth/themes/oligarchy
    
    cp oligarchy.plymouth $out/share/plymouth/themes/oligarchy/
    cp oligarchy.script $out/share/plymouth/themes/oligarchy/
    
    # Copy wallpaper.jpg if it exists
    if [ -f wallpaper.jpg ]; then
      cp wallpaper.jpg $out/share/plymouth/themes/oligarchy/
    fi
    
    # Ensure correct theme path in .plymouth file
    sed -i "s|ImageDir=.*|ImageDir=$out/share/plymouth/themes/oligarchy|g" \
      $out/share/plymouth/themes/oligarchy/oligarchy.plymouth
    sed -i "s|ScriptFile=.*|ScriptFile=$out/share/plymouth/themes/oligarchy/oligarchy.script|g" \
      $out/share/plymouth/themes/oligarchy/oligarchy.plymouth

    runHook postInstall
  '';

  meta = with lib; {
    description = "Modern Plymouth boot theme for Oligarchy NixOS with DeMoD palette";
    license = licenses.free;
    platforms = platforms.linux;
    maintainers = [ ];
  };
}
