{
  description = "StreamDb: A reverse Trie index key-value database in Rust";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    crane.url = "github:ipetkov/crane";
    rust-overlay.url = "github:oxalica/rust-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, crane, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        rustToolchain = pkgs.rust-bin.stable."1.75".default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        src = craneLib.cleanCargoSource (pkgs.lib.cleanSource ./.);

        commonArgs = {
          inherit src;
          pname = "streamdb";
          version = "0.1.0";
          cargoLock = { lockFile = ./Cargo.lock; };
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        streamdb = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "-p streamdb";
          doCheck = true;
        });

        streamdb-wasm = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "-p streamdb --features wasm --target wasm32-unknown-unknown";
          doCheck = false;
        });

        streamdb-encryption = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "-p streamdb --features encryption";
        });
      in
      {
        packages = {
          default = streamdb;
          inherit streamdb streamdb-wasm streamdb-encryption;
        };

        devShells.default = craneLib.devShell {
          checks = self.checks.${system};
          packages = with pkgs; [
            rust-analyzer
            cargo-watch
            cargo-nextest
            criterion
            valgrind
          ];
        };

        checks = {
          streamdb-tests = craneLib.cargoNextest (commonArgs // { inherit cargoArtifacts; });
          streamdb-clippy = craneLib.cargoClippy (commonArgs // { inherit cargoArtifacts; cargoClippyExtraArgs = "--all-targets -- -D warnings"; });
          streamdb-fmt = craneLib.cargoFmt commonArgs;
        };
      }
    );
}
