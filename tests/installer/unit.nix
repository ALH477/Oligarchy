# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 DeMoD LLC.
#
# installer-unit — the Calamares job and its packaging (vendored from ArchibaldOS tests/installer-unit.nix).
#   1. installer/calamares/tests/test_distroinstall.py against the REAL
#      upstream nixos job of this nixpkgs (the helpers it borrows are
#      exercised as shipped);
#   2. the extended calamares-nixos-extensions builds, and its settings.conf
#      runs distroinstall where upstream runs nixos;
#   3. the drift guard refuses an upstream whose sequence changed (built
#      against a doctored upstream and required to FAIL);
#   4. the CLI's --dry-run prints the install.json the job would write.
{ pkgs, extensions, cli }:

let
  upstream = pkgs.calamares-nixos-extensions;
  doctored = pkgs.runCommand "calamares-nixos-extensions-doctored" { inherit (upstream) version; } ''
    cp -r ${upstream} $out; chmod -R u+w $out
    sed -i 's/^  - nixos$/  - nixos\n  - somethingnew/' $out/etc/calamares/settings.conf
  '';
  drift = pkgs.testers.testBuildFailure (extensions.override { calamares-nixos-extensions = doctored; });
in
pkgs.runCommand "installer-unit"
{ nativeBuildInputs = [ pkgs.python3 pkgs.gnugrep ]; }
  ''
    set -euo pipefail
    cp -r ${../../installer} installer; chmod -R u+w installer
    UPSTREAM_JOB=${upstream}/lib/calamares/modules/nixos/main.py \
      python3 -W error::ResourceWarning -m unittest -v installer/calamares/tests/test_distroinstall.py 2>&1 | tee log
    grep -q '^OK' log

    s=${extensions}/etc/calamares/settings.conf
    grep -qx '  - distroinstall' $s || { echo "FAIL: distroinstall not in the exec sequence"; exit 1; }
    ! grep -qx '  - nixos' <(sed -n '/^- exec:/,/^- show:/p' $s) || { echo "FAIL: nixos still runs in exec"; exit 1; }
    grep -qx '  - packagechooser@profile' $s || { echo "FAIL: no profile page"; exit 1; }
    test -f ${extensions}/lib/calamares/modules/nixos/main.py || { echo "FAIL: plain has nothing to delegate to"; exit 1; }
    echo "PASS: settings.conf runs distroinstall, shows the profile page, keeps nixos for plain"

    grep -q 'changed its sequence' ${drift}/testBuildFailure.log \
      || { echo "FAIL: the drift guard did not name the change"; cat ${drift}/testBuildFailure.log; exit 1; }
    echo "PASS: a doctored upstream sequence fails the build, and says why"

    ${cli}/bin/oligarchy-install --dry-run --profile nixos-fw13 --user maria --hostname werkbank \
      --timezone Europe/Berlin --locale de_DE.UTF-8 --keyboard de:nodeadkeys --boot-device /dev/sda \
      > dry.json 2>dry.err
    python3 -c 'import json,sys; d=json.load(open("dry.json")); assert d["profile"]=="nixos-fw13" and d["user"]["name"]=="maria" and d["timeZone"]=="Europe/Berlin" and d["keyboard"]["variant"]=="nodeadkeys", d'
    grep -q 'nixos-install --no-root-passwd --root /mnt --flake /mnt/etc/nixos#installed' dry.err
    echo "PASS: oligarchy-install --dry-run prints the install.json and the install command"
    touch $out
  ''
