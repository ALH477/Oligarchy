{
  description = "Nix flake for HydraMesh (D-LISP) SDK";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        lib = pkgs.lib;

        sbcl = pkgs.sbcl;

        quicklisp-dist = "2023-10-21";
        quicklisp-setup = pkgs.writeShellScriptBin "setup-quicklisp.sh" ''
          mkdir -p $HOME/quicklisp
          curl -O https://beta.quicklisp.org/quicklisp.lisp
          ${sbcl}/bin/sbcl --no-userinit --no-sysinit --load quicklisp.lisp \
            --eval '(quicklisp-quickstart:install :path "~/quicklisp/")' \
            --eval '(ql-util:without-prompting (ql:update-client) (ql:update-dist "quicklisp" :dist-version "${quicklisp-dist}"))' \
            --eval '(ql:quickload :ql-dist)' \
            --quit
        '';

        ql-packages = [
          "cl-protobufs" "cl-grpc" "cffi" "uuid" "cl-json" "jsonschema"
          "cl-ppcre" "cl-csv" "usocket" "bordeaux-threads" "curses"
          "log4cl" "trivial-backtrace" "cl-store" "mgl" "hunchensocket"
          "fiveam" "cl-dot" "cl-lsquic" "cl-serial" "cl-can" "cl-sctp"
          "cl-zigbee"
        ];

        load-deps = pkgs.writeShellScriptBin "load-deps.lisp" ''
          (load "~/quicklisp/setup.lisp")
          (ql:quickload '(${pkgs.lib.concatStringsSep " " (map (p: ":${p}") ql-packages)}))
          (quit)
        '';

        hydramesh = pkgs.stdenv.mkDerivation {
          name = "hydramesh";
          src = self;

          nativeBuildInputs = [ sbcl quicklisp-setup ];

          buildPhase = ''
            export HOME=$PWD
            setup-quicklisp.sh
            ${sbcl}/bin/sbcl --script ${load-deps}/bin/load-deps.lisp
            ${sbcl}/bin/sbcl --no-userinit --load hydramesh.lisp \
              --eval '(dcf-deploy "dcf-lisp")' \
              --quit
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp dcf-lisp $out/bin/dcf-lisp
          '';
        };

        toggleScript = pkgs.writeShellScriptBin "hydramesh-toggle" ''
          #!/usr/bin/env bash
          set -euo pipefail

          STATUS_FILE="/var/lib/hydramesh/hydramesh-status"
          SERVICE="hydramesh"

          notify() {
            hyprctl notify -1 4000 "$1" "HydraMesh" "$2" || true
          }

          if systemctl is-active --quiet "$SERVICE"; then
            systemctl stop "$SERVICE"
            notify "rgb(ff3333)" "Service stopped"
            echo "OFF" > "$STATUS_FILE"
          else
            systemctl start "$SERVICE"
            notify "rgb(33ff33)" "Service started"
            echo "ON" > "$STATUS_FILE"
          fi
        '';

        statusScript = pkgs.writeShellScriptBin "hydramesh-status" ''
          #!/usr/bin/env bash
          set -euo pipefail

          SERVICE="hydramesh"
          ICON_ON="/etc/waybar/hydramesh-on.svg"
          ICON_OFF="/etc/waybar/hydramesh-off.svg"

          if systemctl is-active --quiet "$SERVICE"; then
            cat <<EOF
{"text":"ON","class":"hydramesh-active","tooltip":"HydraMesh running","icon":"$ICON_ON"}
EOF
          else
            cat <<EOF
{"text":"OFF","class":"hydramesh-inactive","tooltip":"HydraMesh stopped","icon":"$ICON_OFF"}
EOF
          fi
        '';

        streamdb = pkgs.rustPlatform.buildRustPackage rec {
          pname = "streamdb";
          version = "0.1.0";
          src = self + "/streamdb";
          cargoSha256 = "sha256-placeholder-compute-with-nix-prefetch";
          meta = with lib; {
            description = "StreamDB for HydraMesh";
            license = licenses.lgpl3;
          };
          buildPhase = "cargo build --release --lib";
          installPhase = ''
            mkdir -p $out/lib
            cp target/release/libstreamdb.so $out/lib/
          '';
        };

      in {
        packages = {
          default = hydramesh;
          inherit hydramesh toggleScript statusScript streamdb;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            sbcl
            quicklisp-setup
            pkgs.grpc
            pkgs.protobuf
            pkgs.openssl
            pkgs.zlib
          ];

          shellHook = ''
            export HOME=$PWD
            if [ ! -d "$HOME/quicklisp" ]; then
              setup-quicklisp.sh
            fi
            echo "Quicklisp set up with dist ${quicklisp-dist}. Load deps with: sbcl --script ${load-deps}/bin/load-deps.lisp"
            echo "Load the project: sbcl --load hydramesh.lisp"
          '';
        };
      }
    );
}
