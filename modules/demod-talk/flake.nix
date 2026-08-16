{
  description = "DCF-Talk — decentralized voice and text chat over the DeModFrame wire quantum";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    hydramesh-src = {
      url = "github:ALH477/HydraMesh";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, hydramesh-src }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in
    flake-utils.lib.eachSystem systems (system:
      let
        pkgs = import nixpkgs { inherit system; };
        demod-talk = pkgs.callPackage ./nix/demod-talk.nix {
          inherit hydramesh-src;
        };
      in
      {
        packages = {
          inherit demod-talk;
          default = demod-talk;
        };

        apps = {
          dcf-talk = { type = "app"; program = "${demod-talk}/bin/dcf-talk"; };
          dcf-jam = { type = "app"; program = "${demod-talk}/bin/dcf-jam"; };
          default = { type = "app"; program = "${demod-talk}/bin/dcf-talk"; };
        };

        # `nix flake check` re-runs the golden-vector certifications. The package
        # already gates on them in checkPhase; these make the failure legible as
        # a named check rather than a build log.
        checks = {
          certify = pkgs.runCommand "demod-talk-certify" { } ''
            ${demod-talk}/bin/dcf-certify > $out
          '';
          smoke-clean = pkgs.runCommand "demod-talk-smoke-clean" { } ''
            ${demod-talk}/bin/dcf-talk --blocks 40 --quiet && touch $out
          '';
          smoke-lossy = pkgs.runCommand "demod-talk-smoke-lossy" { } ''
            ${demod-talk}/bin/dcf-talk --blocks 40 --loss 0.15 --quiet && touch $out
          '';
          smoke-corrupt = pkgs.runCommand "demod-talk-smoke-corrupt" { } ''
            ${demod-talk}/bin/dcf-talk --blocks 40 --transport rf --corrupt 0.3 --quiet \
              && touch $out
          '';
          smoke-hub = pkgs.runCommand "demod-talk-smoke-hub" { } ''
            ${demod-talk}/bin/dcf-talk --blocks 40 --hub 8 --quiet && touch $out
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.lua5_4 demod-talk ];
          shellHook = ''
            echo "DCF-Talk dev shell — pure Lua 5.3+, no C dependencies."
            echo "  lua lua/selftest_voice.lua      certify L3 + history"
            echo "  lua lua/dcf_talk.lua --hub 8    end-to-end demo"
          '';
        };
      })
    // {
      nixosModules.default = import ./nixos-module.nix;
      nixosModules.demod-talk = import ./nixos-module.nix;
    };
}
