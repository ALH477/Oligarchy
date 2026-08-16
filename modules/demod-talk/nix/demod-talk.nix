# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (c) 2026 DeMoD LLC. A commercial license is available on request.
#
# The DCF-Talk Lua stack, packaged straight out of the HydraMesh checkout.
#
# There is nothing to compile. Every module is pure Lua 5.3+ with no C
# dependencies, so this derivation copies the certified sources into
# $out/share/lua/dcf and wraps two CLI entry points with LUA_PATH pointing at
# them. That means the thing NixOS runs is byte-identical to the thing CI
# certified — no build step sits between the golden vectors and the artifact.
{ lib, stdenvNoCC, lua5_4, makeWrapper, hydramesh-src, version ? "0.1.0" }:

stdenvNoCC.mkDerivation {
  pname = "demod-talk";
  inherit version;

  src = hydramesh-src;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ lua5_4 ];

  dontConfigure = true;
  dontBuild = true;

  # The certificate is the contract: refuse to produce a package whose modules
  # do not reproduce the committed golden vectors. A failing cert is a failed
  # build, not a runtime surprise.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    cd lua
    for t in selftest.lua selftest_text.lua selftest_voice.lua selftest_snake.lua \
             dcf_superpack.lua dcf_fec.lua; do
      echo "certifying $t"
      ${lua5_4}/bin/lua "$t"
    done
    ${lua5_4}/bin/lua dcf_talk.lua --blocks 40 --quiet
    ${lua5_4}/bin/lua dcf_talk.lua --blocks 40 --loss 0.15 --quiet
    ${lua5_4}/bin/lua dcf_talk.lua --blocks 40 --transport rf --corrupt 0.3 --quiet
    ${lua5_4}/bin/lua dcf_talk.lua --blocks 40 --hub 8 --quiet
    cd ..
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/lua/dcf $out/bin $out/share/doc/demod-talk
    install -m0644 lua/*.lua $out/share/lua/dcf/
    install -m0644 lua/README.md $out/share/doc/demod-talk/ 2>/dev/null || true
    for d in Documentation/DCF_TEXT_SPEC.md Documentation/DCF_AUDIO_SPEC.md \
             Documentation/DCF_SNAKE_SPEC.md; do
      [ -f "$d" ] && install -m0644 "$d" $out/share/doc/demod-talk/ || true
    done

    # dcf-talk — the end-to-end demo / smoke tool.
    makeWrapper ${lua5_4}/bin/lua $out/bin/dcf-talk \
      --add-flags "$out/share/lua/dcf/dcf_talk.lua" \
      --set LUA_PATH "$out/share/lua/dcf/?.lua;;"

    # dcf-jam — the rendezvous demo that already shipped in lua/.
    makeWrapper ${lua5_4}/bin/lua $out/bin/dcf-jam \
      --add-flags "$out/share/lua/dcf/dcf_jam.lua" \
      --set LUA_PATH "$out/share/lua/dcf/?.lua;;"

    # dcf-certify — re-run every certification against the installed copy.
    # Useful after a channel bump: proves the store path you are actually
    # running still reproduces the vectors.
    cat > $out/bin/dcf-certify <<EOF
#!${stdenvNoCC.shell}
set -e
cd $out/share/lua/dcf
for t in selftest.lua selftest_text.lua selftest_voice.lua selftest_snake.lua \
         dcf_superpack.lua dcf_fec.lua; do
  ${lua5_4}/bin/lua "\$t"
done
EOF
    chmod +x $out/bin/dcf-certify

    runHook postInstall
  '';

  meta = with lib; {
    description = "DCF-Talk — decentralized voice and text over the 17-byte DeModFrame";
    longDescription = ''
      The pure-Lua DCF chat stack from HydraMesh: certified text and Snake
      adapters, voice L3 (jitter buffer, packet-loss concealment, DTX),
      SuperPack + Reed-Solomon datagram transport, and StreamDB-backed history.

      Security is network-determined by design — the framework carries no
      encryption, so this is meant to run inside a WireGuard tunnel. See
      services.demod-talk.interface.
    '';
    homepage = "https://github.com/ALH477/HydraMesh";
    license = licenses.lgpl3Only;   # dual-licensed; commercial terms on request
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "dcf-talk";
  };
}
