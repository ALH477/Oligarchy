# DCL -> NixOS. Makes build-scoped DCL values readable by ordinary modules as
# `config.custom.dcl.settings."group.key"`, with the §13 gate enforced at
# eval time so a bad schema or a hand-edited values.json fails the rebuild
# with a message the person holding the laptop can act on.
#
# §7.2 is the reason `dir` has no default: build-scoped configuration lives in
# its own dedicated repository, never the one the user's own work is in. A
# default pointing into this flake would quietly reintroduce exactly the
# stage-and-commit trap that section rejects.
{ config, lib, ... }:

let
  cfg = config.custom.dcl;
  dcl = import ./dcl.nix { inherit lib; };
  loaded = if cfg.enable then dcl.load cfg.dir else null;
in
{
  options.custom.dcl = {
    enable = lib.mkEnableOption "the DeMoD Configuration Layer";

    dir = lib.mkOption {
      type = lib.types.path;
      description = ''
        Directory holding `schema.json` and, optionally, `values.json`.
        An absent `values.json` is the all-defaults state, not an error (§4.3).
      '';
      example = lib.literalExpression "inputs.guitar-config";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.unspecified;
      readOnly = true;
      default = if loaded == null then { } else loaded.cfg;
      defaultText = lib.literalExpression "schema defaults merged with values.json";
      description = ''
        Effective configuration, keyed by the schema's dotted keys. Defaults
        are already merged, so consumers never test for key presence (§4.2).
      '';
    };

    changed = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = if loaded == null then [ ] else loaded.changed;
      description = "Keys the user has actually overridden. Mirrors the sparse store.";
    };
  };

  config = lib.mkIf cfg.enable {
    # One assertion per error rather than a single concatenated blob, so the
    # rebuild names each problem on its own line.
    assertions = map (e: { assertion = false; message = "DCL: ${e}"; }) loaded.errors;

    # §4.4: an unknown key is quarantined on-device and ignored here. That is
    # a divergence the user should see, not a silent drop.
    warnings = map (w: "DCL: ${w}") loaded.warnings;
  };
}
