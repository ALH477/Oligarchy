# Floodgate — lets Bedrock players join without a Java (Mojang) account.
#
# Pairs with geyser-spigot.nix; read that file's header for why these are
# fetched here rather than added as sub-flake inputs.
#
# Pin builds from the same fortnight as Geyser. A Geyser/Floodgate skew produces
# Floodgate's own disconnect message — "Expected {} arguments, got {}. Is Geyser
# up-to-date?" — which points at the wrong half of the pair.
#
# Note there is no Modrinth alternative for this artifact: Floodgate's Modrinth
# project publishes only Fabric and NeoForge jars, never Spigot.
{ lib
, stdenvNoCC
, fetchurl
, unzip
}:

let
  version = "2.2.5";
  build = 140; # 2026-08-09, contemporary with geyser 2.11.2-b1234

  # Floodgate ships its config template inside the jar, so unlike Geyser this
  # number is readable straight out of that file (and checked below).
  configVersion = 3;
in
stdenvNoCC.mkDerivation {
  pname = "floodgate-spigot";
  version = "${version}-b${toString build}";

  src = fetchurl {
    url = "https://download.geysermc.org/v2/projects/floodgate/versions/${version}/builds/${toString build}/downloads/spigot";
    name = "floodgate-spigot-${version}-b${toString build}.jar";
    hash = "sha256-n0NsQv/YsQkaQ316Thb4IYG51TFPixcy36nVpP/7Gf4=";
  };

  dontUnpack = true;
  preferLocalBuild = true;

  nativeBuildInputs = [ unzip ];

  # Version-less destination name, same reasoning as geyser-spigot.nix.
  installPhase = ''
    runHook preInstall
    install -Dm444 $src $out/share/floodgate/floodgate-spigot.jar
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    # No `grep -q`: stdenv sets `set -o pipefail` and -q closes the pipe on
    # first match, SIGPIPE-ing unzip and failing the pipeline on success.
    cv=$(unzip -p $out/share/floodgate/floodgate-spigot.jar config.yml \
         | grep -E "^config-version:[[:space:]]*${toString configVersion}[[:space:]]*$" || true)
    if [ -z "$cv" ]; then
      echo "floodgate-spigot: bundled config.yml is not config-version ${toString configVersion}." >&2
      echo "  Fix configVersion here, or Floodgate rewrites the rendered config." >&2
      exit 1
    fi
    runHook postInstallCheck
  '';

  passthru = { inherit configVersion; };

  meta = with lib; {
    description = "Bedrock authentication for Geyser — join without a Java account";
    homepage = "https://geysermc.org/wiki/floodgate/";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ binaryBytecode ];
    platforms = platforms.unix;
    maintainers = [ ];
  };
}
