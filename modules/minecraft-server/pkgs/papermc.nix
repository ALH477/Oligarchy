# Paper, pinned here rather than taken from nixpkgs.
#
# TWO reasons, either of which alone would justify it:
#
# 1. nixpkgs' `papermcServers` tops out at Minecraft 1.21.10, and Geyser only
#    bridges Bedrock clients to the Java version it natively speaks. Current
#    Geyser speaks 26.2, so a 1.21.10 server cannot serve a current Bedrock
#    client without inserting ViaVersion as a translation layer. Matching the
#    versions natively is simpler and has fewer ways to go subtly wrong.
#
# 2. nixpkgs' derivation fetches from `api.papermc.io/v2/...`, which PaperMC has
#    SUNSET — that URL now returns HTTP 410 Gone. `pkgs.papermcServers.*` still
#    appears to work only because the artifact sits in cache.nixos.org; on a
#    builder that cannot substitute it, the fetch fails outright. Verified:
#      curl -sI https://api.papermc.io/v2/projects/paper/versions/1.21.10/builds/91/downloads/paper-1.21.10-91.jar
#      HTTP/2 410
#
# The v3 (`fill.papermc.io`) download URL is content-addressed — the sha256 is
# literally in the path — so it is about as durable a pin as exists.
#
# Re-pinning:
#   curl -s https://fill.papermc.io/v3/projects/paper/versions/<mc>/builds/latest \
#     -H 'Accept: application/json' \
#   | jq -r '.id, .channel, .downloads."server:default".url,
#            .downloads."server:default".checksums.sha256'
#   nix hash convert --hash-algo sha256 --to sri <sha256>
# Take only `channel: STABLE` builds. Then update `nativePaperVersions` in
# ./geyser-spigot.nix, or the module's assertion will refuse the pair.
{ lib
, stdenvNoCC
, fetchurl
, makeBinaryWrapper
  # Paper 26.2 requires Java 25 or newer (fill.papermc.io v3 reports
  # java.version.minimum = 25). nixpkgs' default `jre` is still 21, so this must
  # be passed explicitly — on 21 the server refuses to boot.
, jdk25_headless
, udev
}:

let
  mcVersion = "26.2";
  build = 121; # STABLE, 2026-08-29
  sha256 = "0de30efb024bc8b83c9c7d507d11802897ad8056b6110ec09fe1a91d126ccb54";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "papermc";
  version = "${mcVersion}-${toString build}";

  src = fetchurl {
    url = "https://fill-data.papermc.io/v1/objects/${sha256}/paper-${mcVersion}-${toString build}.jar";
    hash = "sha256-DeMO+wJLyLg8nH1QfRGAKJetgFa2EQ7An+GpHRJsy1Q=";
  };

  dontUnpack = true;
  preferLocalBuild = true;

  nativeBuildInputs = [ makeBinaryWrapper ];

  # Binary name and layout deliberately match nixpkgs' papermc, so this stays a
  # drop-in for `services.minecraft-server.package`, whose ExecStart is
  # "${package}/bin/minecraft-server ${jvmOpts}".
  installPhase = ''
    runHook preInstall

    install -D $src $out/share/papermc/papermc.jar

    makeWrapper ${lib.getExe jdk25_headless} "$out/bin/minecraft-server" \
      --append-flags "-jar $out/share/papermc/papermc.jar nogui" \
      ${lib.optionalString stdenvNoCC.hostPlatform.isLinux
        "--prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ udev ]}"}

    runHook postInstall
  '';

  passthru = {
    inherit mcVersion;
    # The Java protocol this server speaks, for the crossplay assertion.
    # 776 == "26.2" per ViaVersion's ProtocolVersion registry.
    javaProtocolVersion = 776;
  };

  meta = {
    description = "High-performance Minecraft server (Paper), pinned for Geyser crossplay";
    homepage = "https://papermc.io/";
    sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.unix;
    mainProgram = "minecraft-server";
    maintainers = [ ];
  };
})
