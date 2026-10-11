# Haven — the upstream Node server, packaged from an immutable release tag.
#
# AGPL-3.0. This is an UNMODIFIED build of ancsemi/Haven: the source is
# fetched at build time (never vendored), npm deps are pinned by upstream's
# package-lock.json via fetchNpmDeps, and only `server.js` + `src/` +
# `public/` + `themes/` are installed. Nothing is patched, so the AGPL §13
# source-offer obligation does not apply to a deployment of this package.
#
# Node 24: upstream's engines field is ">=22.0.0 <27.0.0". better-sqlite3 is
# a native addon and compiles under the normal Nix npm build (it is a
# prebuilt-binary-free dependency in nixpkgs' nodejs).
{
  lib,
  nodejs_24,
  fetchFromGitHub,
  fetchNpmDeps,
  buildNpmPackage,
  makeWrapper,
}:

buildNpmPackage rec {
  pname = "haven";
  version = "4.21.0";

  # Immutable release tag (commit b69bea7 on main). Bump this pin to update;
  # Haven's in-app one-click updater cannot work against an immutable
  # /nix/store install, so the pin is the update mechanism (README.md).
  src = fetchFromGitHub {
    owner = "ancsemi";
    repo = "Haven";
    rev = "v${version}";
    hash = "sha256-4FuSl2zTnBr1yWNvVC1F6vInzAMAXzocQgjLtXrJzpk=";
  };

  npmDepsHash = "sha256-pPt/2bV1jVYLEZi42G1Bg0EjtuOQ3UsLoEr6C8jj480=";

  nodejs = nodejs_24;

  # Upstream has no `build` step (main is server.js, scripts.start runs it
  # directly). dontNpmBuild skips the non-existent `npm run build` and keeps
  # only `npm install` for the production deps.
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  # Install the server plus the runtime assets it serves. `npm install` has
  # already populated node_modules in $out/lib/node_modules/haven; the server
  # resolves its own deps from there, so we place the app files beside it and
  # wrap `node server.js`.
  installPhase = ''
    runHook preInstall

    local app="$out/lib/node_modules/haven"
    mkdir -p "$app"
    cp -r server.js src public themes plugins node_modules package.json "$app/"

    makeWrapper "${nodejs_24}/bin/node" "$out/bin/haven" \
      --chdir "$app" \
      --add-flags "server.js"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Haven — self-hosted private chat: no cloud, no telemetry, no Big Tech";
    homepage = "https://haven-app.com";
    # The upstream licence, declared here so nixpkgs records it on the closure.
    # Our module glue (nixos-module.nix, this file's scaffolding) is BSD-3-Clause.
    license = licenses.agpl3Only;
    mainProgram = "haven";
    maintainers = with maintainers; [ ];
    platforms = platforms.linux;
  };
}
