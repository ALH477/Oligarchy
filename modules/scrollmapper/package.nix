{ lib
, stdenvNoCC
, python3
, fetchurl
, makeWrapper
, translation ? "KJVA"
}:

let
  # Trust boundary is the SRI hash, not the branch name. A moved tip fails
  # the build instead of shipping substituted scripture.
  sources = {
    KJVA = {
      url = "https://raw.githubusercontent.com/scrollmapper/bible_databases/master/formats/json/KJVA.json";
      hash = "sha256-QEzIYUXyIaVZmGSh4gAzWI7FkpM8kLsg/mxPpGHblFo=";
    };
    KJV = {
      url = "https://raw.githubusercontent.com/scrollmapper/bible_databases/master/formats/json/KJV.json";
      hash = "sha256-8LCdxJ37l7uE8DquH78CZIUEjDyrMaekEBfi2GrB0Rw=";
    };
    CPDV = {
      url = "https://raw.githubusercontent.com/scrollmapper/bible_databases/master/formats/json/CPDV.json";
      hash = "sha256-+RpdyVVtd6RBoYrf9aJy+PSx/qF0XgHQw8KpOqeSmjg=";
    };
    ASV = {
      url = "https://raw.githubusercontent.com/scrollmapper/bible_databases/master/formats/json/ASV.json";
      hash = "sha256-YCRF4iwoCmgqxMSJEX6tF5Jx9e5Qp47kUxsknHHnzpk=";
    };
    BSB = {
      url = "https://raw.githubusercontent.com/scrollmapper/bible_databases/master/formats/json/BSB.json";
      hash = "sha256-zsPGRAiKjvSlDPHi3gNfediCXzlGJdEWu37n4dV3Ock=";
    };
  };

  srcSpec = sources.${translation} or (throw "unsupported scrollmapper translation ${translation}");
  textJson = fetchurl {
    inherit (srcSpec) url hash;
    name = "${translation}.json";
  };

  srcFiles = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./scrollmapper.py
      ./canons.json
      ./boot-pool.tsv
      ./boot-dialogue.sh
      ./sample.tsv
    ];
  };
in
stdenvNoCC.mkDerivation {
  pname = "oligarchy-scrollmapper";
  version = "1.0.1";

  src = srcFiles;

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;
  dontFixup = false;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/scrollmapper/texts

    cp scrollmapper.py canons.json boot-pool.tsv boot-dialogue.sh sample.tsv \
      $out/share/scrollmapper/
    cp ${textJson} $out/share/scrollmapper/texts/${translation}.json

    # --set-default so the NixOS module / user env can override canon and wrap.
    makeWrapper ${python3}/bin/python3 $out/bin/scrollmapper \
      --add-flags "$out/share/scrollmapper/scrollmapper.py" \
      --set-default SCROLLMAPPER_DATA "$out/share/scrollmapper" \
      --set-default SCROLLMAPPER_TRANSLATION ${lib.escapeShellArg translation} \
      --set-default SCROLLMAPPER_CANON orthodox \
      --set-default SCROLLMAPPER_WRAP 72

    makeWrapper ${stdenvNoCC.shell} $out/bin/scrollmapper-boot-dialogue \
      --add-flags "$out/share/scrollmapper/boot-dialogue.sh" \
      --set-default SCROLLMAPPER_BOOT_POOL "$out/share/scrollmapper/boot-pool.tsv"

    makeWrapper $out/bin/scrollmapper $out/bin/scrollmapper-daily \
      --add-flags "daily"

    chmod 0644 $out/share/scrollmapper/scrollmapper.py
    chmod 0755 $out/share/scrollmapper/boot-dialogue.sh
    runHook postInstall
  '';

  meta = with lib; {
    description = "Low-footprint Scrollmapper reader for Oligarchy (Orthodox canon default)";
    homepage = "https://github.com/scrollmapper/bible_databases";
    license = licenses.bsd3;
    platforms = platforms.linux;
  };
}
