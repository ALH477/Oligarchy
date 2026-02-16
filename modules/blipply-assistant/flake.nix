{
  description = "Blipply Assistant - AI-powered desktop assistant with voice interaction";

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
          extensions = [ "rust-src" "rust-analyzer" ];
        };

        blipply-assistant = pkgs.rustPlatform.buildRustPackage {
          pname = "blipply-assistant";
          version = "0.1.0";
          
          src = ./.;
          
          cargoLock = {
            lockFile = ./Cargo.lock;
          };

          nativeBuildInputs = with pkgs; [
            pkg-config
            rustToolchain
          ];

          buildInputs = with pkgs; [
            gtk4
            gtk4-layer-shell
            glib
            cairo
            pango
            gdk-pixbuf
            
            # Audio
            alsa-lib
            
            # For ONNX Runtime
            stdenv.cc.cc.lib
          ];

          # ONNX Runtime needs these at runtime
          runtimeDependencies = with pkgs; [
            stdenv.cc.cc.lib
          ];

          postInstall = ''
            # Wrap binary to set library paths
            wrapProgram $out/bin/blipply-assistant \
              --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}"
          '';

          meta = with pkgs.lib; {
            description = "AI-powered desktop assistant with voice interaction for NixOS";
            homepage = "https://github.com/demod-llc/blipply-assistant";
            license = licenses.mit;
            platforms = platforms.linux;
            maintainers = [ "DeMoD LLC" ];
          };
        };

      in {
        packages.default = blipply-assistant;
        packages.blipply-assistant = blipply-assistant;

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            rustToolchain
            pkg-config
            
            # GTK/UI
            gtk4
            gtk4-layer-shell
            glib
            cairo
            pango
            gdk-pixbuf
            
            # Audio
            alsa-lib
            pipewire
            
            # Development tools
            rust-analyzer
            cargo-watch
            cargo-edit
            
            # For downloading models
            wget
            curl
            
            # Ollama (optional, can be installed separately)
            # ollama
          ];

          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ]}:$LD_LIBRARY_PATH"
            
            echo "Blipply Assistant Development Environment"
            echo "========================================"
            echo ""
            echo "Available commands:"
            echo "  cargo build          - Build the project"
            echo "  cargo run -- --help  - Run with help"
            echo "  cargo test           - Run tests"
            echo ""
            echo "First time setup:"
            echo "  1. Ensure Ollama is running: systemctl --user start ollama"
            echo "  2. Download models: ./scripts/download-models.sh"
            echo "  3. Run setup: cargo run -- setup"
            echo ""
          '';
        };
      }
    ) // {
      # NixOS module
      nixosModules.default = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.services.blipply-assistant;
        in {
          options.services.blipply-assistant = {
            enable = mkEnableOption "Blipply Assistant";

            user = mkOption {
              type = types.str;
              default = "blipply";
              description = "User to run Blipply Assistant as";
            };

            group = mkOption {
              type = types.str;
              default = "blipply";
              description = "Group to run Blipply Assistant as";
            };

            homeDirectory = mkOption {
              type = types.path;
              default = "/var/empty";
              description = "Home directory for the blipply user";
            };

            package = mkOption {
              type = types.package;
              default = self.packages.${pkgs.system}.default;
              description = "The blipply-assistant package to use";
            };

            ollamaUrl = mkOption {
              type = types.str;
              default = "http://127.0.0.1:11434";
              description = "URL of the Ollama API server";
            };

            downloadModels = mkOption {
              type = types.bool;
              default = true;
              description = "Automatically download required models";
            };
          };

          config = mkIf cfg.enable {
            # Create blipply user if it doesn't exist
            users.users.${cfg.user} = {
              isSystemUser = true;
              group = cfg.group;
              description = "Blipply AI Assistant";
              home = cfg.homeDirectory;
            };
            
            users.groups.${cfg.group} = {};

            # Install package
            environment.systemPackages = [ cfg.package ];

            # Ensure PipeWire is running
            services.pipewire = {
              enable = mkDefault true;
              alsa.enable = mkDefault true;
              pulse.enable = mkDefault true;
            };

            # Add user to input group for hotkey support
            users.groups.input = {};

            # udev rules for input devices
            services.udev.extraRules = ''
              KERNEL=="event*", SUBSYSTEM=="input", GROUP="input", MODE="0640"
            '';

            # Enable xdg-desktop-portal for global shortcuts
            xdg.portal = {
              enable = true;
              extraPortals = mkIf (
                config.services.xserver.desktopManager.plasma6.enable or false
              ) [
                pkgs.xdg-desktop-portal-kde
              ];
            };

            # Systemd user service
            systemd.user.services.blipply-assistant = {
              description = "Blipply AI Assistant";
              after = [ "graphical-session.target" ];
              partOf = [ "graphical-session.target" ];
              
              serviceConfig = {
                Type = "simple";
                ExecStart = "${cfg.package}/bin/blipply-assistant daemon";
                Restart = "on-failure";
                RestartSec = "5s";
              };
              
              wantedBy = [ "graphical-session.target" ];
            };

            # Model download service
            systemd.user.services.blipply-assistant-models = mkIf cfg.downloadModels {
              description = "Download Blipply Assistant Models";
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
              };

              script = ''
                MODEL_DIR="$HOME/.local/share/blipply-assistant/models"
                mkdir -p "$MODEL_DIR/whisper" "$MODEL_DIR/piper"

                # Download Whisper base.en model
                if [ ! -f "$MODEL_DIR/whisper/base.en.bin" ]; then
                  echo "Downloading Whisper base.en model..."
                  ${pkgs.wget}/bin/wget -q --show-progress \
                    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin \
                    -O "$MODEL_DIR/whisper/base.en.bin"
                fi

                # Download Piper voice models
                if [ ! -f "$MODEL_DIR/piper/en_US-lessac-medium.onnx" ]; then
                  echo "Downloading Piper voice model..."
                  ${pkgs.wget}/bin/wget -q --show-progress \
                    https://github.com/rhasspy/piper/releases/download/v1.2.0/voice-en-us-lessac-medium.tar.gz \
                    -O- | ${pkgs.gnutar}/bin/tar xz -C "$MODEL_DIR/piper/"
                fi

                echo "Model download complete!"
              '';

              wantedBy = [ "default.target" ];
            };
          };
        };
    };
}
