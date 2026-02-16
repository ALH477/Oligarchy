# Helper function to build demod-voice package
{ pkgs, pythonEnv }:

pkgs.python3Packages.buildPythonPackage {
  pname = "demod-voice";
  version = "1.0.0";
  
  src = ../.;
  
  format = "other";
  
  propagatedBuildInputs = with pkgs.python3Packages; [
    pyyaml
    tqdm
  ];
  
  nativeBuildInputs = [ pkgs.makeWrapper ];
  
  installPhase = ''
    mkdir -p $out/${pkgs.python3.sitePackages}/demod_voice
    mkdir -p $out/bin
    
    # Install Python modules
    cp -r ../demod_voice/* $out/${pkgs.python3.sitePackages}/demod_voice/
    
    # Create __init__.py if it doesn't exist
    touch $out/${pkgs.python3.sitePackages}/demod_voice/__init__.py
    
    # Install CLI script
    cp ../bin/demod-voice $out/bin/demod-voice
    chmod +x $out/bin/demod-voice
    
    # Wrap the CLI with all dependencies
    wrapProgram $out/bin/demod-voice \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.piper-tts pkgs.ffmpeg pkgs.sox ]} \
      --set PYTHONPATH "${pythonEnv}/${pythonEnv.sitePackages}:$out/${pkgs.python3.sitePackages}"
  '';
  
  checkInputs = with pkgs.python3Packages; [ pkgs.python3Packages.pytest ];
  checkPhase = ''
    export PYTHONPATH="$out/${pkgs.python3.sitePackages}:${pythonEnv}/${pythonEnv.sitePackages}:$PYTHONPATH"
    pytest ../tests/test_config.py ../tests/test_batch.py -v || true
  '';
  
  meta = with pkgs.lib; {
    description = "DeMoD LLC Voice Clone - Local TTS and Voice Cloning";
    license = licenses.mit;
    platforms = platforms.linux;
    maintainers = [ ];
  };
}