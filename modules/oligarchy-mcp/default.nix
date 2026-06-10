{ lib
, python3
, makeWrapper
, stdenvNoCC
}:

# Packages the read-only Oligarchy MCP server (server.py) as an `oligarchy-mcp`
# binary. Pure Python via python3.withPackages — no compilation. The server
# shells out to the system's own CLIs (oligarchy-ctl, hydramesh-*, nix,
# systemctl, …), which are resolved from the launching session's PATH.
let
  pyEnv = python3.withPackages (ps: [ ps.mcp ]);
in
stdenvNoCC.mkDerivation {
  pname = "oligarchy-mcp";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    install -Dm644 server.py "$out/share/oligarchy-mcp/server.py"
    makeWrapper ${pyEnv}/bin/python3 "$out/bin/oligarchy-mcp" \
      --add-flags "$out/share/oligarchy-mcp/server.py"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Local, read-only MCP server for working on the Oligarchy NixOS system";
    license = licenses.bsd3;
    platforms = platforms.linux;
    mainProgram = "oligarchy-mcp";
  };
}
