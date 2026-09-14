# Geyser-Spigot — the Bedrock<->Java bridge, as a Paper/Spigot plugin.
#
# Packaged here rather than pinned as a sub-flake input: AGENTS.md landmine 13
# says extra inputs in a `path:` sub-flake are not carried by the parent lock,
# and prefers fetching inside. A build-numbered download.geysermc.org URL plus
# an SRI hash is as pinned as a flake input would be.
#
# ── THE VERSION RULE, WHICH IS NOT WHAT THE WIKI IMPLIES ─────────────────────
# Geyser's wiki says "You can use Geyser-Spigot on servers that run on 1.20.5 or
# above". That is the NMS/platform-adapter floor, NOT protocol compatibility.
# The real rule is in GeyserSpigotVersionChecker.checkForSupportedProtocol:
#
#     if (viaversion) { checkViaVersionSupportedVersions(logger); return; }
#     if (Bukkit.getUnsafe().getProtocolVersion() != GameProtocol.getJavaProtocolVersion())
#         sendOutdatedMessage(logger);
#
# Without ViaVersion the server's protocol must EQUAL the one Geyser speaks. So
# this file pins a Geyser whose native Java protocol matches the Paper we ship,
# and `javaProtocolVersion` below is checked against the jar at build time — the
# runtime symptom of getting it wrong is a Bedrock player disconnected with
# nothing useful in either log.
#
# Do NOT source the compatible-version list from Modrinth's `game_versions`:
# that is the ViaVersion-assisted range and would make the module's assertion
# pass on a configuration that cannot work.
#
# Re-pinning: see modules/minecraft-server/README.md.
{ lib
, stdenvNoCC
, fetchurl
, unzip
, jdk_headless
}:

let
  version = "2.11.2";
  build = 1234; # 2026-09-02, contemporary with floodgate 2.2.5-b140

  # Native Java protocol. 776 == "26.2" per ViaVersion's own ProtocolVersion
  # registry, which is why this pairs with ./papermc.nix at 26.2.
  javaMinecraftVersion = "26.2";
  javaProtocolVersion = 776;

  # Every Minecraft version sharing that protocol number. The module's
  # assertion is a membership test against this list.
  nativePaperVersions = [ "26.2" ];

  # Bedrock client versions this build accepts, for documentation and for the
  # module's warning. THIS is what decides whether a phone can connect, and it
  # is a moving target: Bedrock clients auto-update from the app stores and
  # cannot easily be held back, so an old Geyser silently stops serving real
  # devices. Geyser 2.9.1 covered 1.21.90-1.21.123 and shares NO versions at
  # all with this build. Read it out of the jar with:
  #   unzip -p <jar> org/geysermc/geyser/network/GameProtocol.class \
  #     | tr -c '[:print:]' '\n' | grep -xE '[0-9.]+' | sort -uV
  bedrockVersions = "26.0-26.45";

  # Geyser rewrites its config whenever the file's config-version differs from
  # this constant. The module renders a config pinning it, which is what keeps
  # the rendered file authoritative instead of being regenerated every boot.
  configVersion = 7;
in
stdenvNoCC.mkDerivation {
  pname = "geyser-spigot";
  version = "${version}-b${toString build}";

  src = fetchurl {
    # Build-numbered and immutable. Never `versions/latest` or `builds/latest`.
    url = "https://download.geysermc.org/v2/projects/geyser/versions/${version}/builds/${toString build}/downloads/spigot";
    name = "Geyser-Spigot-${version}-b${toString build}.jar";
    hash = "sha256-WMTGzYkMaC33SxvX8SeP0NUcmZtFuRs7D/HknEK3S4o=";
  };

  dontUnpack = true;
  preferLocalBuild = true;

  nativeBuildInputs = [ unzip jdk_headless ];

  # Fixed, version-LESS filename. The module symlinks this name into plugins/,
  # so a build bump replaces the link and leaves nothing behind. A build number
  # in the filename would leave the old jar next to the new one and Paper would
  # load the same plugin twice, then refuse to enable one — a failure that reads
  # like a plugin bug.
  installPhase = ''
    runHook preInstall
    install -Dm444 $src $out/share/geyser/Geyser-Spigot.jar
    runHook postInstall
  '';

  # The two passthru facts below are hand-written and both are load-bearing at
  # runtime, so both are checked against the jar here. A re-pin that forgets to
  # update them fails `nix build`, not a Bedrock player's login.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    # (1) The Java version Geyser natively speaks is a UTF8 constant in
    #     mcprotocollib's MinecraftCodec. The constant is length-prefixed, so
    #     splitting the class on non-printable bytes isolates it as its own
    #     line, and an exact whole-line match distinguishes 1.21.9 from 1.21.10
    #     without matching a substring. `tr` rather than `strings` so this needs
    #     nothing beyond coreutils. (Matching the raw length prefix instead is
    #     not possible from a shell: command substitution strips the NUL byte.)
    # NB: no `grep -q` in any of these pipelines. stdenv runs with
    # `set -o pipefail`, and -q closes the pipe on first match, killing unzip
    # with SIGPIPE and failing the whole pipeline on SUCCESS.
    codec=$(unzip -p $out/share/geyser/Geyser-Spigot.jar \
              org/geysermc/mcprotocollib/protocol/codec/MinecraftCodec.class \
            | tr -c '[:print:]' '\n' | grep -xF '${javaMinecraftVersion}' || true)
    if [ -z "$codec" ]; then
      echo "geyser-spigot: jar does not speak Java ${javaMinecraftVersion}." >&2
      echo "  Update javaMinecraftVersion/javaProtocolVersion/nativePaperVersions" >&2
      echo "  together, and re-check the Paper pin in modules/minecraft-server.nix." >&2
      exit 1
    fi

    # (2) Constants.CONFIG_VERSION decides whether Geyser rewrites the config
    #     the module renders. It moved 5 -> 7 between 2.9 and 2.11.
    cv=$(javap -p -constants -cp $out/share/geyser/Geyser-Spigot.jar \
           org.geysermc.geyser.Constants \
         | grep "CONFIG_VERSION = ${toString configVersion};" || true)
    if [ -z "$cv" ]; then
      echo "geyser-spigot: Constants.CONFIG_VERSION is not ${toString configVersion}." >&2
      echo "  Fix configVersion here or Geyser will regenerate its config on" >&2
      echo "  every start and the rendered file stops being the source of truth." >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  passthru = {
    inherit javaMinecraftVersion javaProtocolVersion nativePaperVersions configVersion
      bedrockVersions;
  };

  meta = with lib; {
    description = "Bedrock <-> Java Minecraft protocol bridge (Spigot/Paper plugin)";
    homepage = "https://geysermc.org/";
    license = licenses.mit;
    sourceProvenance = with sourceTypes; [ binaryBytecode ];
    platforms = platforms.unix;
    maintainers = [ ];
  };
}
