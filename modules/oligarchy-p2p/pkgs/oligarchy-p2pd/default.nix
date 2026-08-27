{ lib, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "oligarchy-p2pd";
  version = "0.1.0";

  # Narrower than a plain `src = ./.;` for the same reason
  # modules/oligarchy-plugins does it: the Nix files sit beside the crate, and
  # without this filter every edit to modules/p2p-cache.nix would rebuild
  # reqwest and rustls.
  src = lib.cleanSourceWith {
    name = "oligarchy-p2pd-src";
    src = ../../.;
    filter = path: _type:
      let rel = lib.removePrefix (toString ../../. + "/") (toString path);
      in lib.hasPrefix "host" rel;
  };

  sourceRoot = "oligarchy-p2pd-src/host";
  cargoLock.lockFile = ../../host/Cargo.lock;

  # THE POINT, and it is load-bearing rather than cosmetic. Stage 0 spike (b)
  # (docs/p2p-substituter-roadmap.md §2.3) established that reqwest's DEFAULT
  # features route TLS at openssl and drag it into the closure; the crate pins
  # `default-features = false, features = ["rustls-tls"]` so that the whole
  # dependency tree needs no C libraries at all. If this list ever stops being
  # empty, check what pulled openssl in before adding to it.
  nativeBuildInputs = [ ];
  buildInputs = [ ];

  # `cargo test` runs in checkPhase by default and every test here is
  # hermetic — no network, no store access, no sockets. Keep it that way: a
  # test that needs a peer belongs in a VM gate, not in checkPhase.
  doCheck = true;

  meta = with lib; {
    description = "Oligarchy P2P substituter — local Nix binary-cache adapter";
    longDescription = ''
      Presents a standard Nix binary cache on loopback so that Nix can obtain
      NARs through Oligarchy's peer-to-peer transport without Nix being patched
      or its trust model weakened. Stage 1 is a verifying pass-through proxy;
      the transport lands in later stages.
    '';
    license = licenses.mpl20;
    maintainers = [ "ALH477" ];
    platforms = platforms.linux;
    mainProgram = "oligarchy-p2pd";
  };
}
