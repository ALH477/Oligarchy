{
  description = "Oligarchy MCP Servers — dedicated, read-only aspect servers + ports-sec auditor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rust-analyzer" "clippy" ];
        };

        # Each aspect is built as its own `rustPlatform.buildRustPackage` so
        # the flake outputs are individually addressable. They share one
        # Cargo.lock at the workspace root, pinned and committed.
        mkAspect = name:
          pkgs.rustPlatform.buildRustPackage {
            pname = "oligarchy-${name}-mcp";
            version = "0.1.0";
            src = ./.;
            cargoLock.lockFile = ./Cargo.lock;
            nativeBuildInputs = [ pkgs.pkg-config rustToolchain ];
            # ports-sec pulls reqwest/rustls which need openssl or use
            # rustls-tls (no openssl dependency). We use rustls-tls in the
            # workspace so the buildInputs stay minimal.
            buildInputs = [ ];

            # Build only this crate's bin, not the whole workspace. Avoids
            # pulling optional deps of unrelated aspects.
            buildAndTestSubset = [
              "--package"
              "oligarchy-${name}-mcp"
            ];

            # ports-sec's local_api_scan tool needs the loopback-socket
            # feature to actually probe APIs. Default off so the binary
            # reports the no-op path until the host opts in.
            cargoBuildFlags = pkgs.lib.optionals (name == "ports-sec") [
              "--features"
              "allow-loopback-socket"
            ];

            meta = with pkgs.lib; {
              description = "Oligarchy MCP server: ${name} aspect (read-only)";
              license = licenses.mit;
              platforms = platforms.linux;
            };
          };

        aspectNames = [
          "system" "net" "dcf" "dsp" "ai" "secrets" "vm" "ports-sec"
        ];

        aspectPackages = builtins.listToAttrs (
          map (n: { name = "oligarchy-${n}-mcp"; value = mkAspect n; }) aspectNames
        );

        umbrella = pkgs.rustPlatform.buildRustPackage {
          pname = "oligarchy-mcp";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
          nativeBuildInputs = [ pkgs.pkg-config rustToolchain ];
          buildAndTestSubset = [ "--package" "oligarchy-mcp-umbrella" ];
          meta = with pkgs.lib; {
            description = "Oligarchy MCP umbrella router (replaces the legacy Python server)";
            license = licenses.mit;
            platforms = platforms.linux;
            mainProgram = "oligarchy-mcp";
          };
        };

        # Self-audit package: runs the ports-sec `mcp_self_audit` tool against
        # the workspace source. Mirrors the `malwareScan` precedent in the
        # top-level flake. Fails the build on any violation.
        mcpSelfAudit = pkgs.runCommand "oligarchy-mcp-self-audit"
          {
            nativeBuildInputs = [ (mkAspect "ports-sec") ];
            meta = with pkgs.lib; {
              description = "MCP self-audit build gate — fails on forbidden socket/allowlist patterns";
              license = licenses.mit;
              platforms = platforms.linux;
            };
          }
          ''
            mkdir -p $out
            oligarchy-ports-sec-mcp --self-audit > $out/report.txt 2>&1 || {
              echo "mcp-self-audit FAILED — see $out/report.txt" >&2
              cat $out/report.txt
              exit 1
            }
            echo "mcp-self-audit clean — see $out/report.txt"
          '';

      in {
        packages = {
          default = umbrella;
          inherit umbrella mcpSelfAudit;
        } // aspectPackages;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            rustToolchain
            pkg-config
            cargo-watch
            cargo-edit
          ];
        };
      }
    ) // {
      # NixOS module surface — consumed by the top-level flake.
      nixosModules.default = import ./nixos-module.nix;
      nixosModules.mcp-servers = self.nixosModules.default;
    };
}