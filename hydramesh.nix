{ config, pkgs, lib, ... }:

let
  cfg = config.services.hydramesh;
  sbclWithPkgs = pkgs.sbcl.withPackages (ps: with ps; [
    cffi cl-ppcre cl-json cl-csv usocket bordeaux-threads log4cl trivial-backtrace cl-store hunchensocket fiveam cl-dot cserial-port
  ]);
  streamdb = pkgs.rustPlatform.buildRustPackage rec {
    pname = "streamdb";
    version = "0.1.0";  # Adjust version as needed
    src = ./HydraMesh/streamdb;
    cargoSha256 = "sha256-placeholder-compute-with-nix-prefetch";  # Replace with nix-prefetch-url --unpack src
    meta = with lib; {
      description = "StreamDB for HydraMesh";
      license = licenses.lgpl3;
    };
    # Assuming it builds libstreamdb.so
    buildPhase = "cargo build --release --lib";
    installPhase = ''
      mkdir -p $out/lib
      cp target/release/libstreamdb.so $out/lib/
    '';
  };
  toggleScript = pkgs.writeShellScriptBin "hydramesh-toggle" ''
    #!/usr/bin/env bash
    if systemctl is-active --quiet hydramesh; then
      systemctl stop hydramesh
      hyprctl notify -1 4000 "rgb(ff3333)" "HydraMesh" "Service stopped"
      echo "OFF" > /var/lib/hydramesh/hydramesh-status
    else
      systemctl start hydramesh
      hyprctl notify -1 4000 "rgb(33ff33)" "HydraMesh" "Service started"
      echo "ON" > /var/lib/hydramesh/hydramesh-status
    fi
  '';
  statusScript = pkgs.writeShellScriptBin "hydramesh-status" ''
    #!/usr/bin/env bash
    STATUS=$(systemctl is-active hydramesh)
    if [ "$STATUS" = "active" ]; then
      echo "{\"text\": \"🕸️ ON\", \"class\": \"hydramesh-active\", \"tooltip\": \"HydraMesh running\", \"icon\": \"/etc/hydramesh/hydramesh.svg\"}"
    else
      echo "{\"text\": \"🕸️ OFF\", \"class\": \"hydramesh-inactive\", \"tooltip\": \"HydraMesh stopped\", \"icon\": \"/etc/hydramesh/hydramesh.svg\"}"
    fi
  '';
in {
  # Note: HydraMesh codebase is sourced from ./HydraMesh and licensed under LGPL-3.0 (see ./HydraMesh/LICENSE if available).
  options.services.hydramesh = {
    enable = lib.mkEnableOption "HydraMesh Lisp service";
    configFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/hydramesh/config.json";
      description = "Path to HydraMesh config.json";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ sbclWithPkgs toggleScript statusScript streamdb ];

    # Copy entire HydraMesh directory to /etc/hydramesh
    environment.etc."hydramesh".source = ./HydraMesh;
    environment.etc."hydramesh/config.json".text = ''
      {
        "transport": "gRPC",
        "host": "localhost",
        "port": 50051,
        "mode": "AUTO",
        "node-id": "hydramesh-node-1",
        "peers": [],
        "group-rtt-threshold": 50,
        "plugins": {},
        "storage": "streamdb",
        "streamdb-path": "/var/lib/hydramesh/streamdb",
        "optimization-level": 2,
        "retry-max": 3
      }
    '';

    # HydraMesh systemd service
    systemd.services.hydramesh = {
      description = "HydraMesh Lisp Node";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.writeShellScriptBin "hydramesh-start" ''
          # Setup Quicklisp if not present
          if [ ! -d "/root/quicklisp" ]; then
            curl -O https://beta.quicklisp.org/quicklisp.lisp
            ${sbclWithPkgs}/bin/sbcl --load quicklisp.lisp --eval '(quicklisp-quickstart:install)' --quit
          fi
          # Load main HydraMesh file
          ${sbclWithPkgs}/bin/sbcl --load /root/quicklisp/setup.lisp \
            --load /etc/hydramesh/src/hydramesh.lisp \
            --eval '(dolist (plugin (directory "/etc/hydramesh/plugins/*.lisp")) (load plugin))' \
            --eval '(in-package :hydramesh)' \
            --eval '(hydramesh-init "${cfg.configFile}" :restore-state t)' \
            --eval '(hydramesh-start)' \
            --non-interactive
        ''}/bin/hydramesh-start";
        Restart = "always";
        User = "hydramesh";
        WorkingDirectory = "/etc/hydramesh";
        Environment = "LD_LIBRARY_PATH=${streamdb}/lib";
        DynamicUser = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        RestrictNamespaces = true;
        SystemCallFilter = "@system-service ~@privileged";
      };
    };

    # Dedicated user for security
    users.users.hydramesh = {
      isSystemUser = true;
      group = "hydramesh";
      home = "/var/lib/hydramesh";
      createHome = true;
    };
    users.groups.hydramesh = {};
  };
}
