# Proves the NixOS module surface works, using lib.evalModules rather than a
# full NixOS evaluation -- this needs no system closure and runs in a second.
{ lib ? (import <nixpkgs> { }).lib }:

let
  evalWith = dir: lib.evalModules {
    modules = [
      ./nixos-module.nix
      # minimal stubs for the two option sets the module writes to
      ({ lib, ... }: {
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
        options.warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      })
      { custom.dcl = { enable = true; inherit dir; }; }
    ];
  };

  ok = (evalWith ./test/fixtures/ok).config;
  empty = (evalWith ./test/fixtures/empty).config;
  bad = (evalWith ./test/fixtures/range).config;
  unk = (evalWith ./test/fixtures/unknown).config;

  t = name: cond: got: { inherit name got; pass = cond; };

  tests = [
    (t "module exposes merged settings" (ok.custom.dcl.settings."voice.preset" == "doom") ok.custom.dcl.settings)
    (t "module merges defaults for untouched keys" (ok.custom.dcl.settings."audio.input_gain_db" == 0.0) null)
    (t "module reports only overridden keys as changed"
       (builtins.sort builtins.lessThan ok.custom.dcl.changed
        == [ "audio.output_gain_db" "display.brightness" "voice.preset" ]) ok.custom.dcl.changed)
    (t "absent values.json still yields settings" (empty.custom.dcl.settings."display.brightness" == 70) null)
    (t "absent values.json raises no assertion" (empty.assertions == [ ]) empty.assertions)
    (t "invalid value becomes a failed assertion with a readable message"
       (builtins.any (a: !a.assertion && lib.hasInfix "Output Level must be between -60 and 12 dB" a.message)
          bad.assertions) (map (a: a.message) bad.assertions))
    (t "unknown key becomes a warning, not an assertion"
       (unk.assertions == [ ] && builtins.any (w: lib.hasInfix "voice.experimental" w) unk.warnings)
       { inherit (unk) assertions warnings; })
  ];
  failed = builtins.filter (x: !x.pass) tests;
in
{ total = builtins.length tests;
  passed = builtins.length tests - builtins.length failed;
  failures = map (f: { inherit (f) name got; }) failed;
  ok = failed == [ ]; }
