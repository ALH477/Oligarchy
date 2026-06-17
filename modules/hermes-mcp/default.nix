{ lib
, python3
, makeWrapper
, stdenvNoCC
}:

# Packages the read-only Hermes MCP server (server.py) as a `hermes-mcp`
# binary. Pure Python via python3.withPackages — no compilation. The server
# shells out to the system's own CLIs (hermes, nix, systemctl, …), which are
# resolved from the launching session's PATH.
let
  pyEnv = python3.withPackages (ps: [ ps.mcp ]);
in
stdenvNoCC.mkDerivation {
  pname = "hermes-mcp";
  version = "0.1.0";

  src = ./.; 

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm644 server.py "$out/share/hermes-mcp/server.py"
    makeWrapper ${pyEnv}/bin/python3 "$out/bin/hermes-mcp" \
      --add-flags "$out/share/hermes-mcp/server.py"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Local, read-only MCP server for Hermes Agent";
    license = licenses.bsd3;
    platforms = platforms.linux;
    mainProgram = "hermes-mcp";
  };
}
