# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 DeMoD LLC.
#
# `<distro>-install`: installer/cli.py with the same job module and the same
# job configuration the graphical installer gets (installer/calamares/).
{ lib
, runCommand
, makeWrapper
, python3
, calamares-nixos-extensions
, distro
, source
, profiles
, defaultProfile
, flakeAttr ? "installed"
, hostDir ? "hosts/installed"
}:

let
  name = "${lib.toLower distro}-install";
  conf = builtins.toJSON {
    inherit distro flakeAttr hostDir defaultProfile;
    source = "${source}";
    profileKey = "packagechooser_profile";
    plainProfile = "plain";
    profiles = map (p: p.id) profiles;
    # "plain" is not offered here: the CLI exists to install the distribution.
    upstreamJob = "${calamares-nixos-extensions}/lib/calamares/modules/nixos/main.py";
  };
in
runCommand name { nativeBuildInputs = [ makeWrapper ]; inherit conf; passAsFile = [ "conf" ]; meta.mainProgram = name; } ''
  mkdir -p $out/libexec/${name}/calamares/distroinstall $out/bin
  cp ${./cli.py} $out/libexec/${name}/cli.py
  cp ${./calamares/distroinstall/main.py} $out/libexec/${name}/calamares/distroinstall/main.py
  cp "$confPath" $out/libexec/${name}/distroinstall.json
  makeWrapper ${python3}/bin/python3 $out/bin/${name} --add-flags $out/libexec/${name}/cli.py
''
