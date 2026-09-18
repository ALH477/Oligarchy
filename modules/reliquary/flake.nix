{
  description = "Reliquary — multi-medium data preservation (USB mirrors + CD-R blocks)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      tools = pkgs: with pkgs; [
        par2cmdline
        gnutar
        zstd
        xorriso
        gptfdisk
        parted
        e2fsprogs
        dosfstools
        util-linux
        rsync
        coreutils
        findutils
        gnused
        gnugrep
      ];
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          reliquary = pkgs.rustPlatform.buildRustPackage {
            pname = "reliquary";
            version = "0.1.0";
            src = ./.;
            cargoLock.lockFile = ./Cargo.lock;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            doCheck = false;
            postInstall = ''
              wrapProgram $out/bin/reliquary \
                --prefix PATH : ${pkgs.lib.makeBinPath (tools pkgs)}
            '';
            meta = with pkgs.lib; {
              description = "Tarball + checksum + PAR2 preservation across duplicated USB partitions and CD-R";
              license = licenses.mit;
              platforms = platforms.unix;
              mainProgram = "reliquary";
            };
          };
          default = reliquary;
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.reliquary}/bin/reliquary";
        };
      });

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.rustc
              pkgs.cargo
              pkgs.rustfmt
              pkgs.clippy
            ] ++ tools pkgs;
            shellHook = ''
              export RELIQUARY_STORE="''${RELIQUARY_STORE:-$PWD/.reliquary-work/store}"
              echo "Reliquary Rust shell. Try: cargo run -- status"
            '';
          };
        });

      nixosModules.default = import ./nix/module.nix { inherit self; };
      nixosModules.reliquary = self.nixosModules.default;

      overlays.default = final: prev: {
        reliquary = self.packages.${final.stdenv.hostPlatform.system}.reliquary;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
