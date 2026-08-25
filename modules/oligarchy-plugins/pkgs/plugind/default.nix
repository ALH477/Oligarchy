{ lib
, rustPlatform
, pkg-config
, cmake
, stdenv
, libseccomp
, bubblewrap
, luajit
, makeWrapper
, nix
, systemd
, withNativeTier ? true
, withLuaTier ? true
}:

rustPlatform.buildRustPackage {
  pname = "oligarchy-plugind";
  version = "0.1.0";

  # Narrower than the sibling sub-flakes' plain `src = ./.;` on purpose: this
  # flake's Nix files sit next to the crate, and without the filter every edit
  # to modules/plugins.nix would rebuild wasmtime.
  src = lib.cleanSourceWith {
    name = "oligarchy-plugind-src";
    src = ../../.;
    filter = path: _type:
      let rel = lib.removePrefix (toString ../../. + "/") (toString path);
      in lib.hasPrefix "host" rel || lib.hasPrefix "wit" rel;
  };

  # cleanSourceWith sets the store path name, so this cannot be hardcoded to
  # "source/host" — that only happens to work for unnamed sources.
  sourceRoot = "oligarchy-plugind-src/host";

  cargoLock.lockFile = ../../host/Cargo.lock;

  nativeBuildInputs = [ pkg-config cmake makeWrapper ];
  buildInputs = [ libseccomp ] ++ lib.optional withLuaTier luajit;

  buildNoDefaultFeatures = true;
  buildFeatures = lib.optional withNativeTier "native-tier"
    ++ lib.optional withLuaTier "lua-tier";

  # mlua vendors LuaJIT by default; point it at nixpkgs' instead so we get
  # the hardening flags and the security team's attention.
  LUA_LIB = lib.optionalString withLuaTier "${luajit}/lib";
  LUA_INC = lib.optionalString withLuaTier "${luajit}/include";

  # bindgen!(path: "../wit") resolves against CARGO_MANIFEST_DIR, which is
  # sourceRoot. The src filter already keeps wit/ alongside host/, so ../wit
  # exists and the previous copy step was redundant.

  postInstall = ''
    mkdir -p $out/share/oligarchy/wit $out/include
    cp -r ../wit/* $out/share/oligarchy/wit/
    cp include/*.h $out/include/

    # plugind shells out to nix (install), systemctl (enable) and bwrap
    # (tier 1). Wrapping rather than relying on the unit's path= means the
    # CLI works from an interactive shell too.
    wrapProgram $out/bin/plugind \
      --prefix PATH : ${lib.makeBinPath ([ nix systemd ]
        # Both tier 1 backends re-enter through bwrap, not just the native one.
        ++ lib.optional (withNativeTier || withLuaTier) bubblewrap)}
  '';

  # The seccomp selftest forks and calls mprotect, which the nix build
  # sandbox permits, so this is meaningful here.
  checkFlags = [
    "--skip=tiers::microvm" # needs KVM
  ];

  meta = with lib; {
    description = "Tiered sandboxed plugin runtime for Oligarchy";
    longDescription = ''
      One WIT ABI across WASM, native and Lua plugins, with three sandbox
      tiers selected per-plugin from a capability manifest, and per-instance
      W^X enforcement so a plugin that genuinely needs a JIT can have one
      without every other plugin inheriting the concession.
    '';
    homepage = "https://github.com/ALH477/Oligarchy";
    license = licenses.mpl20;
    maintainers = [ "ALH477" ];
    platforms = platforms.linux;
  };
}
