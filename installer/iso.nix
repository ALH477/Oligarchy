# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 DeMoD LLC.
#
# Makes a Calamares ISO install this distribution (installer/calamares/).
# Import it into an ISO configuration with:
#   (import ./installer/iso.nix { distro = "ArchibaldOS"; source = self;
#      profiles = [ … ]; defaultProfile = "audio"; })
{ distro, source, profiles, defaultProfile }:
{ lib, ... }:

{
  nixpkgs.overlays = [
    (final: prev: {
      calamares-nixos-extensions = final.callPackage ./calamares/extensions.nix {
        calamares-nixos-extensions = prev.calamares-nixos-extensions;
        inherit distro source profiles defaultProfile;
      };
    })
  ];
}
