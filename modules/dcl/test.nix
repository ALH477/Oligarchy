# DCL Nix-integration test suite. Pure evaluation, no derivation, no KVM.
#   nix eval --impure --expr 'import ./modules/dcl/test.nix {}' --json
# `--impure` only because this imports <nixpkgs> for lib when none is passed.
{ lib ? (import <nixpkgs> { }).lib }:

let
  dcl = import ./dcl.nix { inherit lib; };
  fx = n: dcl.load (./test/fixtures + "/${n}");

  # a test is { name, pass, got } -- `got` is printed only on failure
  t = name: cond: got: { inherit name got; pass = cond; };

  hasErr = r: sub: builtins.any (e: lib.hasInfix sub e) r.errors;
  hasWarn = r: sub: builtins.any (e: lib.hasInfix sub e) r.warnings;

  tests = [
    # ---- §4.3 / blocker 3: absent values.json is not an error ----
    (let r = fx "empty"; in
      t "absent values.json loads as all-defaults" (r.ok && r.cfg."display.brightness" == 70) r.errors)
    (let r = fx "empty"; in
      t "absent values.json reports nothing changed" (r.changed == [ ]) r.changed)

    # ---- §4.2 sparse merge ----
    (let r = fx "ok"; in
      t "sparse: overridden key wins" (r.ok && r.cfg."voice.preset" == "doom") r.errors)
    (let r = fx "ok"; in
      t "sparse: untouched key falls back to default" (r.cfg."audio.input_gain_db" == 0.0) r.cfg)
    (let r = fx "ok"; in
      t "isDefault distinguishes set from unset"
        (!(r.isDefault "voice.preset") && r.isDefault "audio.input_gain_db") r.changed)

    # ---- §7.3 version policy: older accepted, newer fatal ----
    (let r = fx "stale"; in
      t "older schema_version is accepted" r.ok r.errors)
    (let r = fx "newer"; in
      t "newer schema_version is fatal" (!r.ok && hasErr r "written by a newer build") r.errors)

    # ---- gap: type check must precede comparison ----
    (let r = fx "wrongtype"; in
      t "string in a float field yields a readable error, not a Nix throw"
        (!r.ok && hasErr r "Output Level must be a number") r.errors)
    (let r = fx "badbool"; in
      t "string in a bool field is caught"
        (!r.ok && hasErr r "Silent Start must be true or false") r.errors)

    # ---- §5.3 readable messages carry label, bounds, unit ----
    (let r = fx "range"; in
      t "out-of-range names label, bounds and unit"
        (hasErr r "Output Level must be between -60 and 12 dB, found 40 dB") r.errors)

    # ---- §3.2 step is normative for the validator, not just the GUI ----
    (let r = fx "offgrid"; in
      t "off-grid value is rejected" (!r.ok && hasErr r "must be a multiple of 0.5") r.errors)
    (let r = fx "offgrid"; in
      t "off-grid error names the nearest accepted value" (hasErr r "Nearest accepted value: -3.5") r.errors)

    # ---- §3.3 / §3.4 ----
    (let r = fx "badenum"; in
      t "enum rejects a non-choice and lists the choices"
        (hasErr r "clean, crunch, doom, bell") r.errors)
    (let r = fx "badpat"; in
      t "string pattern is enforced" (!r.ok && hasErr r "Name must match the required format") r.errors)

    # ---- §4.4 unknown keys: warn, never leak into cfg ----
    (let r = fx "unknown"; in
      t "unknown key warns rather than failing the build" (r.ok && hasWarn r "voice.experimental") r.warnings)
    (let r = fx "unknown"; in
      t "unknown key never reaches cfg" (!(r.cfg ? "voice.experimental")) (builtins.attrNames r.cfg))
    (let r = fx "unknown"; in
      t "a valid key alongside an unknown one still applies" (r.cfg."display.brightness" == 45) r.cfg)

    # ---- §13 schema gate ----
    (let r = fx "ok"; in
      t "the shipped schema passes its own gate" (dcl.internal.schemaErrors r.schema == [ ])
        (dcl.internal.schemaErrors r.schema))

    # blocker 5: (max-min) not divisible by step must be a build error
    (let bad = { key = "a.b"; type = "float"; scope = "runtime"; group = "g"; label = "Bad";
                 default = 0.0; min = 0.0; max = 10.0; step = 4.0; };
         s = { dcl_version = 1; schema_version = 1; id = "t"; title = "t";
               groups = [ { id = "g"; label = "G"; order = 10; } ]; options = [ bad ]; };
     in t "schema gate rejects a max unreachable by the step grid"
          (builtins.any (e: lib.hasInfix "not a multiple of step" e) (dcl.internal.schemaErrors s))
          (dcl.internal.schemaErrors s))

    # §13: a default outside its own constraints cannot ship
    (let bad = { key = "a.b"; type = "int"; scope = "runtime"; group = "g"; label = "Bad";
                 default = 500; min = 0; max = 100; };
         s = { dcl_version = 1; schema_version = 1; id = "t"; title = "t";
               groups = [ { id = "g"; label = "G"; order = 10; } ]; options = [ bad ]; };
     in t "schema gate rejects a default outside its own range"
          (builtins.any (e: lib.hasInfix "Default for \"a.b\" is invalid" e) (dcl.internal.schemaErrors s))
          (dcl.internal.schemaErrors s))

    # §2.4: self-referential visible_if
    (let bad = { key = "a.b"; type = "bool"; scope = "runtime"; group = "g"; label = "Bad";
                 default = true; visible_if = { key = "a.b"; equals = true; }; };
         s = { dcl_version = 1; schema_version = 1; id = "t"; title = "t";
               groups = [ { id = "g"; label = "G"; order = 10; } ]; options = [ bad ]; };
     in t "schema gate rejects a self-referential visible_if"
          (builtins.any (e: lib.hasInfix "self-referential" e) (dcl.internal.schemaErrors s))
          (dcl.internal.schemaErrors s))

    # §3.6: reserved v2 types rejected, not ignored
    (let bad = { key = "a.b"; type = "list"; scope = "runtime"; group = "g"; label = "Bad"; default = [ ]; };
         s = { dcl_version = 1; schema_version = 1; id = "t"; title = "t";
               groups = [ { id = "g"; label = "G"; order = 10; } ]; options = [ bad ]; };
     in t "reserved v2 type is rejected by a v1 reader"
          (builtins.any (e: lib.hasInfix "does not implement" e) (dcl.internal.schemaErrors s))
          (dcl.internal.schemaErrors s))

    # ---- loadOrThrow surfaces every error at once ----
    (let r = fx "range"; in
      t "loadOrThrow throws on an invalid store"
        (!(builtins.tryEval (dcl.loadOrThrow (./test/fixtures + "/range"))).success) "did not throw")
    (let ok = builtins.tryEval (dcl.loadOrThrow (./test/fixtures + "/ok")); in
      t "loadOrThrow returns the config on a valid store" ok.success "threw")
  ];

  failed = builtins.filter (x: !x.pass) tests;
in
{
  total = builtins.length tests;
  passed = builtins.length tests - builtins.length failed;
  failures = map (f: { inherit (f) name got; }) failed;
  ok = failed == [ ];
}
