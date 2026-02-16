{
  description = "DeMoD LLC Production-grade Minecraft Suite";

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
        
        # Tools available in the shell or to the wrapper
        extraTools = with pkgs; [ 
          gamemode 
          mangohud 
          gnutar 
          zip 
          unzip 
          # Optional: Controller testing tool (useful for debugging)
          # sdl2-jstest
        ];

        # LIBRARIES: The critical section for Controller Support & AI Mod
        runtimeLibs = with pkgs; [
          # --- AI-PLAYER / VECTOR DB SUPPORT ---
          # Fixes "libblas.so.3: cannot open shared object file"
          blas
          lapack

          # Sound
          libpulseaudio pipewire openal 
          
          # Graphics
          libGL libglvnd mesa vulkan-loader 
          
          # Windowing & Input
          glfw 
          wayland 
          libxkbcommon 
          
          # X11 Legacy
          xorg.libX11 xorg.libXcursor xorg.libXrandr 
          xorg.libXext xorg.libXxf86vm xorg.libXi
          
          # System
          udev 
          stdenv.cc.cc.lib
          
          # --- CONTROLLER SUPPORT ADDITIONS ---
          SDL2        # Primary library for gamepads (used by Controlify/MidnightControls)
          libusb1     # For direct USB device access
          dbus        # Often needed for device hotplug notifications
        ];

      in
      {
        packages.default = pkgs.symlinkJoin {
          name = "prism-launcher-optimized";
          paths = [ pkgs.prismlauncher ] ++ javaRuntimes ++ extraTools;
          buildInputs = [ pkgs.makeWrapper ];

          postBuild = ''
            # 1. Wrap the binary
            # We explicitly add SDL2, libusb, and BLAS/LAPACK to LD_LIBRARY_PATH.
            wrapProgram $out/bin/prismlauncher \
              --prefix PATH : ${pkgs.lib.makeBinPath (javaRuntimes ++ extraTools)} \
              --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath runtimeLibs} \
              --set JAVA_HOME ${pkgs.jdk21.home} \
              --set SDL_VIDEODRIVER "wayland,x11" \
              --set GAMEMODERUNEXEC "env LD_PRELOAD=${pkgs.gamemode}/lib/libgamemodeauto.so"

            # 2. Fix Desktop Integration
            rm -f $out/share/applications/*.desktop
            cp ${pkgs.prismlauncher}/share/applications/*.desktop $out/share/applications/
            chmod +w $out/share/applications/*.desktop

            substituteInPlace $out/share/applications/*.desktop \
              --replace "Exec=prismlauncher" "Exec=$out/bin/prismlauncher" \
              --replace "Name=Prism Launcher" "Name=Minecraft (DeMoD Optimized)"
          '';
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/prismlauncher";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ self.packages.${system}.default ];
          shellHook = ''
            echo "-------------------------------------------------------"
            echo " DeMoD LLC - Minecraft Production Environment"
            echo "-------------------------------------------------------"
            echo " AI Support: BLAS & LAPACK injected."
            echo " Controller Support: SDL2 & LibUSB injected."
            echo " To test controller: run 'sdl2-jstest --list'"
            echo "-------------------------------------------------------"
          '';
        };
      }
    );
}
