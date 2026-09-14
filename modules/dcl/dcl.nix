# DeMoD Configuration Layer — Nix consumption side.
#
# This is the §7.3 consumer from docs/demod-config-layer-spec.md, written to
# actually hold. The snippet in the spec does not: it readFiles values.json
# unguarded (contradicting §4.3 and the §14 checklist), compares before it
# type-checks (so a hand-edited string reaches `v >= o.min` and Nix throws
# "cannot compare a string with an integer" instead of the readable message
# §5.1 promises), and validates neither `step` -- which §3.2 calls normative
# for the validator, not just the GUI -- nor any string constraint.
#
# The rule this file exists to keep: Nix and libdmc must agree about whether a
# given values.json is acceptable. Any check libdmc makes and this does not is
# a file that passes the build and quarantines on the device.
#
# Pure. No IFD, no --impure, no derivation. `lib` is nixpkgs.lib.
{ lib }:

let
  inherit (builtins) isInt isFloat isString isBool isList isAttrs;

  abs = x: if x < 0 then -x else x;

  # Nix renders every float with six decimal places, so a bare toString gives
  # "Output Level must be between -60.000000 and 12.000000 dB". §5.3 requires
  # messages a non-technical reader can act on, and the spec's own example
  # reads "-60 and 12". Trim to the shortest exact form.
  stripZeros = s:
    if lib.hasInfix "." s
    then (let t = lib.removeSuffix "0" s; in if t == s then s else stripZeros t)
    else s;

  fmtNum = v:
    if isInt v then toString v
    else lib.removeSuffix "." (stripZeros (toString v));

  # §3.2: the step grid is anchored at `min`, NOT at zero. The spec does not
  # say which, and the two disagree whenever min is not itself on a zero-based
  # grid (min = -20, step = 0.3). Anchoring at min is what §8.4's `snap`
  # already does, so this matches the GUI; recorded here because it is the
  # kind of unstated assumption that silently splits two implementations.
  onGrid = o: v:
    if !(o ? step) || o.step == 0 then true
    else
      let
        n = (v - o.min) / o.step;
        nearest = builtins.floor (n + 0.5);
        # §3.2: tolerance step/1000, so a value that is on-grid but not
        # exactly representable in binary float is not rejected.
      in abs ((n - nearest) * o.step) <= (o.step / 1000.0);

  nearestOnGrid = o: v:
    o.min + (builtins.floor (((v - o.min) / o.step) + 0.5)) * o.step;

  typeName = v:
    if isBool v then "true/false"
    else if isInt v then "a whole number"
    else if isFloat v then "a number"
    else if isString v then "text"
    else if isList v then "a list"
    else if isAttrs v then "an object"
    else "unknown";

  # §5.3: messages are user-facing and built from label/unit/bounds, which are
  # all in the schema. "range check failed on audio.output_gain_db" is not
  # acceptable output.
  unitOf = o: if o ? unit then " ${o.unit}" else "";

  # Returns a list of human-readable error strings; [] means valid.
  checkValue = o: v:
    let
      wantNum = "${o.label} must be a number";
      numeric = o.type == "int" || o.type == "float";
    in
    # ---- type first. Everything below assumes the type already matched. ----
    if o.type == "bool" then
      (if isBool v then [ ]
       else [ "${o.label} must be true or false, found ${typeName v}." ])

    else if o.type == "int" then
      (if !(isInt v) then [ "${wantNum} (whole), found ${typeName v}." ]
       else checkNumeric o v)

    else if o.type == "float" then
      (if !(isFloat v || isInt v) then [ "${wantNum}, found ${typeName v}." ]
       else checkNumeric o v)

    else if o.type == "enum" then
      (if !(isString v) then [ "${o.label} must be one of the listed choices, found ${typeName v}." ]
       else if builtins.any (c: c.value == v) o.choices then [ ]
       else [ "${o.label} must be one of ${
                lib.concatStringsSep ", " (map (c: c.value) o.choices)
              }, found \"${v}\"." ])

    else if o.type == "string" then
      (if !(isString v) then [ "${o.label} must be text, found ${typeName v}." ]
       else checkString o v)

    else if o.type == "path" then
      (if !(isString v) then [ "${o.label} must be a path, found ${typeName v}." ]
       else [ ])   # §3.5: must_exist is checked at apply time, not here.

    # §3.6: reserved v2 types are REJECTED by a v1 reader, never ignored.
    else [ "${o.label} uses type \"${o.type}\", which this reader does not implement." ];

  checkNumeric = o: v:
    let
      range =
        if v >= o.min && v <= o.max then [ ]
        else [ "${o.label} must be between ${fmtNum o.min} and ${fmtNum o.max}${unitOf o}, found ${fmtNum v}${unitOf o}." ];
      grid =
        if onGrid o v then [ ]
        else [ "${o.label} must be a multiple of ${fmtNum o.step}${unitOf o}; ${fmtNum v} is not. Nearest accepted value: ${fmtNum (nearestOnGrid o v)}${unitOf o}." ];
    in range ++ grid;

  checkString = o: v:
    let
      maxLen = o.max_length or 256;
      lenErr =
        if builtins.stringLength v <= maxLen then [ ]
        else [ "${o.label} must be at most ${toString maxLen} characters, found ${toString (builtins.stringLength v)}." ];
      # §3.4: pattern is POSIX ERE, anchored implicitly -- builtins.match is
      # already whole-string, so it is the right primitive with no wrapping.
      patErr =
        if !(o ? pattern) then [ ]
        else if builtins.match o.pattern v != null then [ ]
        else [ "${o.label} must match the required format (${o.pattern}), found \"${v}\"." ];
    in lenErr ++ patErr;

  # ---- schema self-consistency (§13). Same checks the build gate runs. ----
  schemaErrors = schema:
    let
      opts = schema.options;
      keys = map (o: o.key) opts;
      groupIds = map (g: g.id) schema.groups;

      dupes =
        let seen = lib.groupBy (k: k) keys;
        in lib.mapAttrsToList (k: v: "Duplicate option key \"${k}\" (${toString (builtins.length v)} declarations).")
             (lib.filterAttrs (_: v: builtins.length v > 1) seen);

      keyPat = k:
        if builtins.match "[a-z0-9_]+(\\.[a-z0-9_]+)*" k != null then [ ]
        else [ "Option key \"${k}\" does not match the required pattern." ];

      perOption = o:
        (keyPat o.key)
        ++ (if builtins.elem o.group groupIds then [ ]
            else [ "Option \"${o.key}\" references undeclared group \"${o.group}\"." ])
        ++ (if builtins.elem o.scope [ "build" "runtime" ] then [ ]
            else [ "Option \"${o.key}\" has scope \"${o.scope}\"; must be \"build\" or \"runtime\"." ])
        # §13: every default validates against its OWN constraints.
        ++ (map (m: "Default for \"${o.key}\" is invalid: ${m}") (checkValue o o.default))
        # BLOCKER 5 from the review: without this, §8.4's snap rounds past max
        # and the user gets a validation error for dragging a slider to its own
        # maximum. Checking it here means no walker has to clamp.
        ++ (if !(o ? step) || o.step == 0 then [ ]
            else if onGrid o o.max then [ ]
            else [ "Option \"${o.key}\": (max - min) = ${fmtNum (o.max - o.min)} is not a multiple of step ${fmtNum o.step}, so the maximum is unreachable and snapping overshoots it." ])
        ++ (if o.type != "enum" then [ ]
            else if builtins.any (c: c.value == o.default) o.choices then [ ]
            else [ "Option \"${o.key}\": default \"${toString o.default}\" is not among its choices." ]);

      # §2.4: predicate cycles and self-reference are rejected at load.
      visErrors = o:
        if !(o ? visible_if) then [ ]
        else
          let p = o.visible_if; in
          (if p.key == o.key then [ "Option \"${o.key}\" has a self-referential visible_if." ] else [ ])
          ++ (if builtins.elem p.key keys then [ ]
              else [ "Option \"${o.key}\" has visible_if on unknown key \"${p.key}\"." ])
          ++ (let n = builtins.length (builtins.filter (f: p ? ${f}) [ "equals" "not_equals" "in" ]);
              in if n == 1 then [ ]
                 else [ "Option \"${o.key}\": visible_if needs exactly one of equals/not_equals/in, found ${toString n}." ]);

      cycleErrors =
        let
          byKey = lib.listToAttrs (map (o: lib.nameValuePair o.key o) opts);
          walk = k: seen:
            let o = byKey.${k} or null; in
            if o == null || !(o ? visible_if) then [ ]
            else if builtins.elem o.visible_if.key seen
              then [ "visible_if cycle through \"${k}\"." ]
              else walk o.visible_if.key (seen ++ [ k ]);
        in lib.unique (lib.concatMap (o: walk o.key [ ]) opts);

      dclErr =
        if (schema.dcl_version or 0) == 1 then [ ]
        else [ "schema dcl_version is ${toString (schema.dcl_version or 0)}; this reader implements 1." ];
    in
    dclErr ++ dupes ++ (lib.concatMap perOption opts)
    ++ (lib.concatMap visErrors opts) ++ cycleErrors;

  # ---- public entry point ----
  #
  # dir: a path containing schema.json and (optionally) values.json.
  load = dir:
    let
      schemaPath = dir + "/schema.json";
      valuesPath = dir + "/values.json";

      schema = builtins.fromJSON (builtins.readFile schemaPath);

      # §4.3 + BLOCKER 3: an absent values.json is NOT an error -- it is
      # exactly the all-defaults state under the sparse invariant. Unguarded
      # readFile is a hard eval failure, and under flake evaluation an
      # untracked file is indistinguishable from an absent one (§7.2), so both
      # land here.
      stored =
        if builtins.pathExists valuesPath
        then builtins.fromJSON (builtins.readFile valuesPath)
        else { inherit (schema) schema_version; dcl_version = 1; values = { }; };

      sErrs = schemaErrors schema;

      byKey = lib.listToAttrs (map (o: lib.nameValuePair o.key o) schema.options);
      defaults = lib.mapAttrs (_: o: o.default) byKey;

      storedValues = stored.values or { };

      # §4.4: a key the schema does not declare is quarantined on-device, not
      # dropped. Nix cannot write, so it reports and excludes -- it must never
      # let one through into cfg, or a module reads a value libdmc refused.
      unknownKeys = builtins.filter (k: !(byKey ? ${k})) (builtins.attrNames storedValues);
      knownStored = lib.filterAttrs (k: _: byKey ? ${k}) storedValues;

      cfg = defaults // knownStored;

      valueErrs = lib.concatMap
        (k: checkValue byKey.${k} cfg.${k})
        (builtins.attrNames byKey);

      # §7.3: older is the NORMAL state between a schema bump and the next
      # time the GUI is opened -- accept it. Only newer is fatal, because that
      # file genuinely holds keys and domains this build does not understand.
      versionErrs =
        let sv = stored.schema_version or schema.schema_version; in
        if sv <= schema.schema_version then [ ]
        else [ ("values.json is schema version ${toString sv} but this system expects "
                + "${toString schema.schema_version}. It was written by a newer build; "
                + "update the system or restore the previous values.json.") ];

      dclErrs =
        let dv = stored.dcl_version or 1; in
        if dv <= 1 then [ ]
        else [ "values.json declares dcl_version ${toString dv}; this reader implements 1." ];

      errors = sErrs ++ versionErrs ++ dclErrs ++ valueErrs;
      warnings = map (k: "values.json contains \"${k}\", which the schema does not declare. It is ignored here and quarantined on the device.") unknownKeys;
    in
    {
      inherit schema cfg errors warnings;
      inherit (stored) schema_version;
      ok = errors == [ ];
      isDefault = k: !(knownStored ? ${k});
      changed = builtins.attrNames knownStored;
    };

  # Throws with every error at once rather than one per rebuild.
  loadOrThrow = dir:
    let r = load dir; in
    if r.ok then r
    else throw ("DCL: ${toString (builtins.length r.errors)} configuration error(s):\n  - "
                + lib.concatStringsSep "\n  - " r.errors);
in
{
  inherit load loadOrThrow;
  # exported for the build gate and for unit tests
  internal = { inherit checkValue schemaErrors onGrid nearestOnGrid; };
}
