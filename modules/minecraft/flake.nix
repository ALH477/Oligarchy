{
  description = "DeMoD LLC Production-grade Minecraft Suite (Java Prism + Bedrock mcpelauncher)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        javaRuntimes = with pkgs; [ jdk8 jdk17 jdk21 ];

        extraTools = with pkgs; [
          gamemode
          mangohud
          gnutar
          zip
          unzip
        ];

        runtimeLibs = with pkgs; [
          blas
          lapack
          libpulseaudio
          pipewire
          openal
          libGL
          libglvnd
          mesa
          vulkan-loader
          glfw
          wayland
          libxkbcommon
          libx11
          libxcursor
          libxrandr
          libxext
          libxxf86vm
          libxi
          udev
          stdenv.cc.cc.lib
          SDL2
          libusb1
          dbus
        ];

        # Bedrock: nixpkgs already source-builds github:minecraft-linux/mcpelauncher-manifest
        # (+ ui-manifest) with the clang/GLFW/no-FORTIFY recipe from the wiki.
        # Do not override src onto a newer tree — the glfw.cmake patch is
        # version-locked (1.6.4 here) and fails on current ng.
        mcpelauncherClient = pkgs.mcpelauncher-client;
        mcpelauncherUi = pkgs.mcpelauncher-ui-qt;

        prismLauncher = pkgs.symlinkJoin {
          name = "prism-launcher-optimized";
          paths = [ pkgs.prismlauncher ] ++ javaRuntimes ++ extraTools;
          buildInputs = [ pkgs.makeWrapper ];

          postBuild = ''
            wrapProgram $out/bin/prismlauncher \
              --prefix PATH : ${pkgs.lib.makeBinPath (javaRuntimes ++ extraTools)} \
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath runtimeLibs} \
              --set JAVA_HOME ${pkgs.jdk21.home} \
              --set SDL_VIDEODRIVER "wayland,x11" \
              --set GAMEMODERUNEXEC "env LD_PRELOAD=${pkgs.gamemode}/lib/libgamemodeauto.so"

            rm -f $out/share/applications/*.desktop
            cp ${pkgs.prismlauncher}/share/applications/*.desktop $out/share/applications/
            chmod +w $out/share/applications/*.desktop

            substituteInPlace $out/share/applications/*.desktop \
              --replace "Exec=prismlauncher" "Exec=$out/bin/prismlauncher" \
              --replace "Name=Prism Launcher" "Name=Minecraft (DeMoD Optimized)"
          '';
        };
      in
      {
        packages = {
          prism = prismLauncher;
          mcpelauncher-client = mcpelauncherClient;
          mcpelauncher-ui = mcpelauncherUi;
          default = pkgs.symlinkJoin {
            name = "demod-minecraft-suite";
            paths = [ prismLauncher mcpelauncherUi mcpelauncherClient ];
          };
        };

        apps = {
          default = {
            type = "app";
            program = "${prismLauncher}/bin/prismlauncher";
          };
          prism = {
            type = "app";
            program = "${prismLauncher}/bin/prismlauncher";
          };
          bedrock = {
            type = "app";
            program = "${mcpelauncherUi}/bin/mcpelauncher-ui-qt";
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            prismLauncher
            mcpelauncherClient
            mcpelauncherUi
          ];
          shellHook = ''
            echo "-------------------------------------------------------"
            echo " DeMoD LLC - Minecraft Production Environment"
            echo " Java:    prismlauncher"
            echo " Bedrock: mcpelauncher-ui-qt / mcpelauncher-client"
            echo "          src = github:minecraft-linux/*-manifest"
            echo "-------------------------------------------------------"
          '';
        };
      }
    );
}
