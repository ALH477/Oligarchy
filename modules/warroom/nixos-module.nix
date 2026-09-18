# ═══════════════════════════════════════════════════════════════════════════════
# warroom — registration module
#
# Installs the `warroom` binary: the Oligarchy War Room, a Ratatui command
# center over DSP, mesh, perimeter, AI, forge and the `oligarchy-ctl` action
# registry. This is a normal, on-demand, READ-WRITE user tool (same category as
# dsp-ctl and oligarchy-forge) — NOT an MCP server, so it must never appear in
# .mcp.json: `nix build .#mcp-self-audit` fails the build if it does, and it
# carries none of the read-only allowlist obligations modules/mcp-servers/ has.
#
# It does not replace the bash control-center trio; it coexists with it and
# drives the same `oligarchy-ctl` dispatcher rather than forking it. See
# modules/warroom/README.md.
#
# Everything defaults OFF. With `enable = false` this module adds no package,
# no unit and no session variable, so — like modules/android-mirror — the ISO
# needs no `lib.mkForce` for it.
#
# The top-level flake adds the `warroom` sub-flake as an input; this module
# reaches its own package through `inputs.warroom`, exactly as
# modules/oligarchy-forge/nixos-module.nix does.
# ═══════════════════════════════════════════════════════════════════════════════
{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.custom.warroom;
  warroom = inputs.warroom;
  system = pkgs.stdenv.hostPlatform.system;
  defaultPackage = warroom.packages.${system}.default or (throw
    "warroom sub-flake has no package for system ${system}"
  );
in
{
  options.custom.warroom = {
    enable = mkEnableOption "Oligarchy War Room — unified Ratatui command center";

    package = mkOption {
      type = types.package;
      default = defaultPackage;
      defaultText = literalExpression "inputs.warroom.packages.\${system}.default";
      description = "The warroom package to install.";
    };

    splash = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Show the startup splash. Exported as WARROOM_SPLASH; `main.rs` treats
        "0" as off, and the `--no-splash` flag wins over either.
      '';
    };

    themeSync = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Read the active Oligarchy theme from
        `~/.config/oligarchy/themes/<id>/palette.json` instead of using only the
        built-in DeMoD palette. Opportunistic: a missing or malformed file falls
        back silently. Exported as WARROOM_THEME_SYNC; "0" disables.
      '';
    };

    defaultTui = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Point the greeter's War Room TUI launch at `warroom`.

        This sets `services.oligarchyGreeting.tui.launchCommand`, which
        configuration.nix otherwise sets to `oligarchy-control` with
        `mkDefault` — so this assignment (normal priority) wins without an
        explicit override. The greeting module is imported unconditionally by
        the top-level flake's `commonModules`, which is what makes referencing
        its option here safe.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      environment.systemPackages = [ cfg.package ];

      # Read by main.rs at startup; command-line flags override both.
      environment.sessionVariables = {
        WARROOM_SPLASH = if cfg.splash then "1" else "0";
        WARROOM_THEME_SYNC = if cfg.themeSync then "1" else "0";
      };
    }

    (mkIf cfg.defaultTui {
      services.oligarchyGreeting.tui.launchCommand =
        "${getExe cfg.package}";
    })
  ]);
}
